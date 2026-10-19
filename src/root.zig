// AMD FSR 3.1 temporal upscaling on `lenore-gpu`.
//
// `Upscaler` owns one FidelityFX upscaler context and the backend it calls
// into. A frame hands it the engine's render-resolution colour, depth and
// motion and an output image at the display resolution, and it records the
// upscaler's passes into the caller's command buffer.
//
// What the caller keeps: every image passed in, its layout before and after
// (`External`), and the frame slot discipline every per-frame resource in the
// engine follows. A slot passed to `dispatch` must not be in flight.

const std = @import("std");
const gpu = @import("lenore-gpu");

pub const ffx = @import("ffx.zig");
pub const shaders = @import("shaders.zig");
const backend = @import("backend.zig");

const vk = gpu.vk;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.fsr);

pub const Backend = backend.Backend;
pub const External = backend.External;
pub const Access = backend.Access;
pub const max_frames = backend.max_frames;
pub const supportsStorageWithoutFormat = backend.supportsStorageWithoutFormat;

// The upscaler's look, as FidelityFX names its configurable constants
// (`FfxFsr3UpscalerConfigureKey`). The defaults are the host's own.
pub const Tuning = struct {
    // How much a pixel's motion counts against its history, 0 to 1. Lower
    // keeps more history on moving surfaces: steadier and more smeared.
    velocity_factor: f32 = 1,
    // How strongly the reactive signals reduce history, 0 or more.
    reactiveness_scale: f32 = 1,
    // How strongly a detected change in shading reduces history, 0 or more.
    shading_change_scale: f32 = 1,
    // How much of the new frame a pixel accumulates per frame, 0 to 1.
    accumulation_added_per_frame: f32 = 1.0 / 3.0,
    // How much history survives a disocclusion; negative values discard it.
    min_disocclusion_accumulation: f32 = -1.0 / 3.0,
};

pub const Config = struct {
    // The largest extents the context is created for. A frame may use any
    // extent up to them; larger needs a new `Upscaler`.
    max_render: vk.Extent2D,
    max_output: vk.Extent2D,
    // How many frame slots the caller cycles through.
    frames: u32,
    // FidelityFX derives exposure from the colour itself. Without it the
    // colour is taken at an exposure of one (`Exposure()` in the shaders
    // treats the default zero as one), which suits colour already exposed.
    auto_exposure: bool = true,
    // Depth reaches the far plane at one rather than going on to infinity.
    depth_infinite: bool = false,
    // Logs the device time of each pass, as means over a few hundred
    // dispatches. Needs a queue that carries timestamps; ignored otherwise.
    profile: bool = false,
    // 16-bit arithmetic where FidelityFX has it, when the device enables it
    // (`Context.float16_int16_enabled`); 32-bit otherwise.
    fp16: bool = true,
    tuning: Tuning = .{},
};

// One frame's parameters, in FidelityFX's conventions.
pub const Frame = struct {
    render: vk.Extent2D,
    output: vk.Extent2D,
    // The sub-pixel offset the frame was rendered at, in render pixels
    // (`ffxFsr3UpscalerGetJitterOffset` gives the sequence).
    jitter: [2]f32,
    // What the motion texture is multiplied by to give, in render pixels, the
    // offset from a pixel to where it was last frame.
    motion_scale: [2]f32,
    // Milliseconds since the previous frame.
    delta_ms: f32,
    // Discard all history: a cut, a teleport, a resize.
    reset: bool,
    camera_near: f32,
    camera_far: f32,
    // Radians.
    camera_fov_y: f32,
    // Robust contrast-adaptive sharpening after the upscale, 0 to 1, or none.
    sharpness: ?f32 = null,
    // The exposure the colour was rendered with, when it changes per frame.
    pre_exposure: f32 = 1,
    // Metres per world unit.
    view_space_to_meters: f32 = 1,
    // Replaces the output with the upscaler's internal state.
    debug_view: bool = false,
};

pub const Inputs = struct {
    colour: *const External,
    depth: *const External,
    motion: *const External,
    // Written through its storage view.
    output: *const External,
};

pub const InitError = error{
    UnsupportedExtent,
    UnsupportedFormat,
    ContextCreationFailed,
} || backend.InitError || gpu.ImageInitError || gpu.ImageMipViewError || Allocator.Error;

pub const DispatchError = error{
    FrameSlotOutOfRange,
    ExtentExceedsContext,
    MissingStorageView,
    DispatchFailed,
};

// Three images the upscaler writes in one pass and reads in a later one, which
// FidelityFX leaves to the caller to own (`ffxFsr3UpscalerGetSharedResourceDescriptions`).
// Formats and extents are that function's.
const Shared = struct {
    image: gpu.Image,
    storage_view: vk.ImageView,
    external: External,

    const formats = [_]vk.Format{
        // Dilated depth, reconstructed previous nearest depth, dilated motion.
        .r32_sfloat,
        .r32_uint,
        .r16g16_sfloat,
    };
};

pub const Upscaler = struct {
    gpa: Allocator,
    context: *const gpu.Context,
    backend: Backend,
    fsr: *ffx.Fsr3UpscalerContext,
    max_render: vk.Extent2D,
    max_output: vk.Extent2D,
    shared: [Shared.formats.len]Shared,

    // On the heap: the host keeps a pointer to the backend, and the context
    // is a megabyte.
    pub fn init(
        gpa: Allocator,
        context: *const gpu.Context,
        memory_allocator: *gpu.MemoryAllocator,
        config: Config,
    ) InitError!*Upscaler {
        if (config.max_render.width == 0 or config.max_render.height == 0 or
            config.max_output.width < config.max_render.width or
            config.max_output.height < config.max_render.height)
            return error.UnsupportedExtent;

        const self = try gpa.create(Upscaler);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.context = context;
        self.max_render = config.max_render;
        self.max_output = config.max_output;

        try self.backend.init(gpa, context, memory_allocator, config.frames, .{
            .profile = config.profile,
            .fp16 = config.fp16,
        });
        if (config.fp16 and !self.backend.fp16) log.info("16-bit arithmetic not enabled on this device; 32-bit variants", .{});
        errdefer self.backend.deinit();

        var created: usize = 0;
        errdefer for (self.shared[0..created]) |*shared| releaseShared(context, shared);
        for (Shared.formats, &self.shared) |format, *shared| {
            shared.* = try createShared(context, memory_allocator, format, config.max_render);
            created += 1;
        }

        self.fsr = try gpa.create(ffx.Fsr3UpscalerContext);
        errdefer gpa.destroy(self.fsr);

        const description: ffx.Fsr3UpscalerContextDescription = .{
            .flags = .{
                .high_dynamic_range = true,
                .auto_exposure = config.auto_exposure,
                .depth_infinite = config.depth_infinite,
            },
            .max_render_size = .{ .width = config.max_render.width, .height = config.max_render.height },
            .max_upscale_size = .{ .width = config.max_output.width, .height = config.max_output.height },
            .fp_message = message,
            .backend_interface = self.backend.interface(),
        };
        const code = ffx.ffxFsr3UpscalerContextCreate(self.fsr, &description);
        if (code != ffx.ok) {
            log.err("ffxFsr3UpscalerContextCreate: {x}", .{@as(u32, @bitCast(code))});
            return error.ContextCreationFailed;
        }
        self.setTuning(config.tuning);
        return self;
    }

    // Vulkan specification, vkDestroy*: no submitted work may still use what
    // this owns, so the caller waits for its frames first.
    pub fn deinit(self: *Upscaler) void {
        const code = ffx.ffxFsr3UpscalerContextDestroy(self.fsr);
        if (code != ffx.ok) log.err("ffxFsr3UpscalerContextDestroy: {x}", .{@as(u32, @bitCast(code))});
        for (&self.shared) |*shared| releaseShared(self.context, shared);
        self.backend.deinit();
        self.gpa.destroy(self.fsr);
        self.gpa.destroy(self);
    }

    // Takes effect from the next dispatch. Values are clamped by the host to
    // the ranges `Tuning` states.
    pub fn setTuning(self: *Upscaler, tuning: Tuning) void {
        const keys = [_]struct { ffx.Fsr3UpscalerConfigureKey, f32 }{
            .{ .velocity_factor, tuning.velocity_factor },
            .{ .reactiveness_scale, tuning.reactiveness_scale },
            .{ .shading_change_scale, tuning.shading_change_scale },
            .{ .accumulation_added_per_frame, tuning.accumulation_added_per_frame },
            .{ .min_disocclusion_accumulation, tuning.min_disocclusion_accumulation },
        };
        for (keys) |entry| {
            var value = entry[1];
            // Fails only for a null context, which this never holds.
            _ = ffx.ffxFsr3UpscalerSetConstant(self.fsr, entry[0], &value);
        }
    }

    // Records the upscaler's passes. `frame_slot` selects the descriptor sets
    // and constant blocks the dispatch writes; it must not be in flight.
    pub fn dispatch(
        self: *Upscaler,
        command_buffer: vk.CommandBuffer,
        frame_slot: u32,
        inputs: Inputs,
        frame: Frame,
    ) DispatchError!void {
        if (frame.render.width > self.max_render.width or frame.render.height > self.max_render.height or
            frame.output.width > self.max_output.width or frame.output.height > self.max_output.height)
            return error.ExtentExceedsContext;
        if (inputs.output.storage_view == .null_handle) return error.MissingStorageView;
        if (frame_slot >= self.backend.frames) return error.FrameSlotOutOfRange;

        self.backend.beginDispatch(frame_slot);

        const description: ffx.Fsr3UpscalerDispatchDescription = .{
            .command_list = backend.commandList(command_buffer),
            .color = resource(inputs.colour, false),
            .depth = resource(inputs.depth, false),
            .motion_vectors = resource(inputs.motion, false),
            .exposure = null_resource,
            .reactive = null_resource,
            .transparency_and_composition = null_resource,
            .dilated_depth = resource(&self.shared[0].external, true),
            .dilated_motion_vectors = resource(&self.shared[2].external, true),
            .reconstructed_prev_nearest_depth = resource(&self.shared[1].external, true),
            .output = resource(inputs.output, true),
            .jitter_offset = .{ .x = frame.jitter[0], .y = frame.jitter[1] },
            .motion_vector_scale = .{ .x = frame.motion_scale[0], .y = frame.motion_scale[1] },
            .render_size = .{ .width = frame.render.width, .height = frame.render.height },
            .upscale_size = .{ .width = frame.output.width, .height = frame.output.height },
            .enable_sharpening = frame.sharpness != null,
            .sharpness = frame.sharpness orelse 0,
            .frame_time_delta = frame.delta_ms,
            .pre_exposure = frame.pre_exposure,
            .reset = frame.reset,
            .camera_near = frame.camera_near,
            .camera_far = frame.camera_far,
            .camera_fov_angle_vertical = frame.camera_fov_y,
            .view_space_to_meters_factor = frame.view_space_to_meters,
            .flags = .{ .draw_debug_view = frame.debug_view },
        };
        const code = ffx.ffxFsr3UpscalerContextDispatch(self.fsr, &description);
        if (code != ffx.ok) {
            log.err("ffxFsr3UpscalerContextDispatch: {x}", .{@as(u32, @bitCast(code))});
            return error.DispatchFailed;
        }

        // After their first dispatch the shared images stay in the layout the
        // upscaler leaves them in.
        for (&self.shared) |*shared| shared.external.before = shared.external.after;
    }
};

// How many frames the jitter sequence takes for a given ratio, and the offset
// of one of them in render pixels, as FidelityFX computes both (Halton 2,3).
pub fn jitterPhaseCount(render_width: u32, output_width: u32) u32 {
    const count = ffx.ffxFsr3UpscalerGetJitterPhaseCount(@intCast(render_width), @intCast(output_width));
    return @intCast(@max(count, 1));
}

pub fn jitterOffset(index: u32, phase_count: u32) [2]f32 {
    var x: f32 = 0;
    var y: f32 = 0;
    // Fails only for a phase count of zero, which `jitterPhaseCount` never returns.
    _ = ffx.ffxFsr3UpscalerGetJitterOffset(&x, &y, @intCast(index % phase_count), @intCast(phase_count));
    return .{ x, y };
}

const null_resource = std.mem.zeroes(ffx.Resource);

// The backend reads the image through `External`; the description is what the
// host itself reads, which is the extent and the type.
fn resource(external: *const External, writable: bool) ffx.Resource {
    var result = std.mem.zeroes(ffx.Resource);
    result.resource = @constCast(external);
    result.description = .{
        .type = .texture_2d,
        .format = surfaceFormat(external.format),
        .width = external.width,
        .height = external.height,
        .depth = 1,
        .mip_count = 1,
        .flags = .{},
        .usage = .{ .uav = writable },
    };
    result.state = if (writable) .unordered_access else .compute_read;
    return result;
}

fn surfaceFormat(format: vk.Format) ffx.SurfaceFormat {
    return switch (format) {
        .b10g11r11_ufloat_pack32 => .r11g11b10_float,
        .r16g16b16a16_sfloat => .r16g16b16a16_float,
        .r16g16_sfloat => .r16g16_float,
        .r32_sfloat, .d32_sfloat => .r32_float,
        .r32_uint => .r32_uint,
        .r8g8b8a8_unorm => .r8g8b8a8_unorm,
        else => .unknown,
    };
}

const shared_access: Access = .{
    .layout = .general,
    .stage = .{ .compute_shader_bit = true },
    .access = .{ .shader_storage_read_bit = true, .shader_storage_write_bit = true },
};

fn createShared(
    context: *const gpu.Context,
    memory_allocator: *gpu.MemoryAllocator,
    format: vk.Format,
    extent: vk.Extent2D,
) InitError!Shared {
    if (!backend.supportsStorageWithoutFormat(context, format)) return error.UnsupportedFormat;
    var image = try gpu.Image.init(context, memory_allocator, .{
        .width = extent.width,
        .height = extent.height,
        .format = format,
        .usage = .{ .sampled_bit = true, .storage_bit = true, .transfer_dst_bit = true },
    });
    errdefer image.deinit();
    const storage_view = try image.createMipView(0);
    return .{
        .image = image,
        .storage_view = storage_view,
        .external = .{
            .image = image.handle,
            .sampled_view = image.view,
            .storage_view = storage_view,
            .format = format,
            .width = extent.width,
            .height = extent.height,
            .before = .undefined_layout,
            .after = shared_access,
        },
    };
}

fn releaseShared(context: *const gpu.Context, shared: *Shared) void {
    context.device.destroyImageView(shared.storage_view, null);
    shared.image.deinit();
}

// The host's diagnostics. Its messages are wide strings of ASCII.
fn message(kind: ffx.MessageType, text: [*:0]const ffx.WChar) callconv(.c) void {
    var buffer: [256]u8 = undefined;
    var len: usize = 0;
    while (text[len] != 0 and len < buffer.len) : (len += 1) {
        const unit = text[len];
        buffer[len] = if (unit > 0 and unit < 128) @intCast(unit) else '?';
    }
    switch (kind) {
        .@"error" => log.err("{s}", .{buffer[0..len]}),
        else => log.warn("{s}", .{buffer[0..len]}),
    }
}

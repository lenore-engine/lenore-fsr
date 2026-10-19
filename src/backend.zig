const std = @import("std");
const gpu = @import("lenore-gpu");

const ffx = @import("ffx.zig");
const shaders = @import("shaders.zig");

const vk = gpu.vk;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.fsr);

// FidelityFX's backend interface (`FfxInterface`) on `lenore-gpu`, for the one
// effect built here: the upscaler.
//
// The host component plans each frame's passes and calls back into this to
// create what they need, register the caller's images, stage constants, and
// record the work. Every Vulkan object stays the engine's: images and buffers
// come from `lenore-gpu`'s allocator, pipelines from its pipeline helpers, and
// the synchronization is recorded here from tracked state rather than inferred
// by the SDK's own Vulkan backend, which is not compiled.
//
// Three choices part from that backend (`ffx_vk.cpp`), each to keep the frame
// free of allocation and of object creation:
//
// - A registered resource is not a raw `VkImage`. `FfxResource.resource` points
//   at an `External` the caller owns, which already carries the views, so
//   nothing is created per frame. Upstream creates and later destroys an image
//   view for every input on every dispatch.
// - A scheduled job is translated into a compact `Job` when it is scheduled.
//   `FfxGpuJobDescription` is tens of kilobytes, almost all of it binding
//   tables this backend wrote itself when it created the pipeline.
// - Constants are written by `stage_constant_buffer_data` straight into this
//   frame's slot of a uniform ring, so the job only records an offset.
//
// The caller's frame slot is what makes reuse safe, the same invariant
// `gpu.PerFrame` states: a slot's descriptor sets and constant blocks are
// rewritten only after that slot's previous submission has completed.

// What a registered image is, and the state it is in when the upscaler starts
// and must be in when it finishes. Owned by the caller and borrowed for the
// dispatch it is passed to.
pub const External = struct {
    image: vk.Image,
    sampled_view: vk.ImageView,
    // Null for an image the upscaler only reads.
    storage_view: vk.ImageView = .null_handle,
    format: vk.Format,
    aspect: vk.ImageAspectFlags = .{ .color_bit = true },
    width: u32,
    height: u32,
    // The layout the image is in on entry and the access that last touched
    // it, which the upscaler's first barrier waits for.
    before: Access,
    // The layout to leave it in and the access that will use it next.
    after: Access,
};

// One image's synchronization state, in Vulkan's terms.
pub const Access = struct {
    layout: vk.ImageLayout,
    stage: vk.PipelineStageFlags2,
    access: vk.AccessFlags2,

    pub const undefined_layout: Access = .{ .layout = .undefined, .stage = .{}, .access = .{} };
};

const sampled: Access = .{
    .layout = .shader_read_only_optimal,
    .stage = .{ .compute_shader_bit = true },
    .access = .{ .shader_sampled_read_bit = true },
};

const storage: Access = .{
    .layout = .general,
    .stage = .{ .compute_shader_bit = true },
    .access = .{ .shader_storage_read_bit = true, .shader_storage_write_bit = true },
};

const clear_target: Access = .{
    .layout = .transfer_dst_optimal,
    .stage = .{ .clear_bit = true },
    .access = .{ .transfer_write_bit = true },
};

const copy_target: Access = .{
    .layout = .transfer_dst_optimal,
    .stage = .{ .copy_bit = true },
    .access = .{ .transfer_write_bit = true },
};

fn writes(access: vk.AccessFlags2) bool {
    return access.shader_write_bit or
        access.shader_storage_write_bit or
        access.transfer_write_bit or
        access.color_attachment_write_bit or
        access.depth_stencil_attachment_write_bit or
        access.memory_write_bit;
}

// Index 0 is FidelityFX's null resource. Created resources take the indices
// after it; registered ones take a separate range, emptied after every
// dispatch. The counts are what the upscaler measured to need with room:
// 25 images and 4 upload buffers, and 11 registrations per dispatch.
const max_static_resources = 64;
const max_dynamic_resources = 16;
const max_resources = max_static_resources + max_dynamic_resources;

// The upscaler creates 11 pipelines and uses each at most once per dispatch.
const max_pipelines = 16;
const uses_per_frame = 2;
pub const max_frames = 4;

// The first dispatch schedules 4 initial-data copies, 5 clears and 9 passes.
const max_jobs = 48;

const max_mips = 16;
const max_samplers = 4;

// Constant blocks. A block is 256 bytes because that is the largest value
// `minUniformBufferOffsetAlignment` may take (Vulkan specification, Required
// Limits), so a block at any index starts at an offset every device accepts.
// The upscaler stages four per dispatch at most.
const constant_block_size = 256;
const constant_blocks_per_frame = 8;
const ConstantBlock = extern struct { words: [constant_block_size / 4]u32 };

const max_barriers = 2 * shaders.range + 4;

const Owned = struct {
    image: gpu.Image,
    // One per level for an image the passes write, empty otherwise.
    storage_views: [max_mips]vk.ImageView,
    storage_view_count: u32,
    description: ffx.ResourceDescription,
    state: Access,
};

const Registered = struct {
    external: *const External,
    description: ffx.ResourceDescription,
    state: Access,
};

const Resource = union(enum) {
    none,
    image: Owned,
    // Initial data for the image at the index before it, kept until the
    // context is destroyed because the copy reads it on the GPU.
    upload: gpu.Buffer,
    external: Registered,
};

const Slot = struct {
    binding: u32,
    resource: u32,
    mip: u32 = 0,
};

const ConstantSlot = struct {
    binding: u32,
    offset: u32,
    size: u32,
};

const Compute = struct {
    pipeline: *Pipeline,
    groups: [3]u32,
    srvs: [shaders.range]Slot,
    srv_count: u32,
    uavs: [shaders.range]Slot,
    uav_count: u32,
    constants: [ffx.max_num_const_buffers]ConstantSlot,
    constant_count: u32,
};

const Job = union(enum) {
    clear: struct { target: u32, color: [4]f32 },
    upload: struct { image: u32, source: u32 },
    compute: Compute,
};

const Pipeline = struct {
    set_layout: vk.DescriptorSetLayout,
    layout: vk.PipelineLayout,
    handle: vk.Pipeline,
    sets: [max_frames * uses_per_frame]vk.DescriptorSet,
    // The dispatch this pipeline was last bound in, and how many of the
    // frame's sets that dispatch has taken.
    serial: u64,
    uses: u32,
    live: bool,
    // Which compiled module it runs, for the profiler's report.
    variant: shaders.Variant,
};

// Per-pass device time, read back a frame slot later and reported as means.
//
// Two timestamps around each compute pass and two around the whole dispatch,
// in a run of queries per frame slot. A slot's results are read when the slot
// is next dispatched, which is after its fence by the caller's contract, so
// reading adds no wait. A slot whose recording never reached the device reads
// as not ready and is skipped.
//
// Which passes ran differs between frames (sharpening, the debug view), so
// the variant each pair measured is recorded beside it.
const timed_per_frame = 16;
const queries_per_frame = 2 + 2 * timed_per_frame;
const report_every = 240;

const Profiler = struct {
    pool: vk.QueryPool,
    support: gpu.GpuTimerSupport,
    variants: [max_frames][timed_per_frame]shaders.Variant,
    counts: [max_frames]u32,
    sum_ns: [shaders.all.len]u64,
    hits: [shaders.all.len]u32,
    total_ns: u64,
    dispatches: u32,

    fn duration(self: *const Profiler, begin: u64, end: u64) u64 {
        return gpu.gpuDurationNs(begin, end, self.support.valid_bits, self.support.period_ns);
    }
};

const SamplerEntry = struct {
    description: ffx.SamplerDescription,
    handle: vk.Sampler,
};

pub const InitError = error{
    UnsupportedFrameCount,
    StorageImageWithoutFormatUnsupported,
    QuadOperationsUnsupported,
} || shaders.ReflectionError ||
    vk.DeviceWrapper.CreateDescriptorPoolError ||
    vk.DeviceWrapper.CreateQueryPoolError ||
    gpu.PerFrameInitError || gpu.PerFrameLayoutError;

pub const Backend = struct {
    context: *const gpu.Context,
    memory_allocator: *gpu.MemoryAllocator,
    arena: std.heap.ArenaAllocator,
    bindings: [shaders.all.len]shaders.Bindings,
    frames: u32,

    // Set by `beginDispatch` for the work the host is about to schedule.
    frame: u32,
    serial: u64,

    // One effect context at a time, which is all the upscaler opens.
    active: bool,

    resources: [max_resources]Resource,
    static_count: u32,
    dynamic_count: u32,
    memory_usage: u64,

    pipelines: [max_pipelines]Pipeline,
    pipeline_count: u32,
    pool: vk.DescriptorPool,
    samplers: [max_samplers]SamplerEntry,
    sampler_count: u32,

    jobs: [max_jobs]Job,
    job_count: u32,

    constants: gpu.PerFrame(ConstantBlock),
    constant_cursor: u32,

    barriers: [max_barriers]vk.ImageMemoryBarrier2,
    barrier_count: u32,

    // Null unless asked for and the queue can carry timestamps.
    profiler: ?Profiler,
    // Whether the 16-bit variants are used.
    fp16: bool,

    pub const Options = struct {
        // Log each pass's device time (`Profiler`).
        profile: bool = false,
        // Use the 16-bit variants where the device enables 16-bit arithmetic.
        fp16: bool = true,
    };

    // In place, because the interface handed to the host points at it.
    pub fn init(
        self: *Backend,
        gpa: Allocator,
        context: *const gpu.Context,
        memory_allocator: *gpu.MemoryAllocator,
        frames: u32,
        options: Options,
    ) InitError!void {
        if (frames == 0 or frames > max_frames) return error.UnsupportedFrameCount;
        if (!context.storage_image_without_format_enabled)
            return error.StorageImageWithoutFormatUnsupported;
        if (!supportsComputeQuads(context)) return error.QuadOperationsUnsupported;

        self.* = .{
            .context = context,
            .memory_allocator = memory_allocator,
            .arena = .init(gpa),
            .bindings = undefined,
            .frames = frames,
            .frame = 0,
            .serial = 0,
            .active = false,
            .resources = @splat(.none),
            .static_count = 1,
            .dynamic_count = 0,
            .memory_usage = 0,
            .pipelines = undefined,
            .pipeline_count = 0,
            .pool = .null_handle,
            .samplers = undefined,
            .sampler_count = 0,
            .jobs = undefined,
            .job_count = 0,
            .constants = undefined,
            .constant_cursor = 0,
            .barriers = undefined,
            .barrier_count = 0,
            .profiler = null,
            .fp16 = options.fp16 and context.float16_int16_enabled,
        };
        errdefer self.arena.deinit();

        for (shaders.all, 0..) |shader, i| {
            self.bindings[i] = try shaders.parseBindings(self.arena.allocator(), shader.reflection);
        }

        const sets = max_pipelines * max_frames * uses_per_frame;
        const sizes = [_]vk.DescriptorPoolSize{
            .{ .type = .sampled_image, .descriptor_count = sets * shaders.range },
            .{ .type = .storage_image, .descriptor_count = sets * shaders.range },
            .{ .type = .uniform_buffer, .descriptor_count = sets * ffx.max_num_const_buffers },
            .{ .type = .sampler, .descriptor_count = sets * max_samplers },
        };
        self.pool = try context.device.createDescriptorPool(&.{
            .max_sets = sets,
            .pool_size_count = sizes.len,
            .p_pool_sizes = &sizes,
        }, null);
        errdefer context.device.destroyDescriptorPool(self.pool, null);

        self.constants = try .init(
            context,
            memory_allocator,
            frames,
            constant_blocks_per_frame,
            .{ .uniform_buffer_bit = true },
        );
        errdefer self.constants.deinit();

        const support = context.timestampSupport();
        if (options.profile and support.available()) {
            const pool = try context.device.createQueryPool(&.{
                .query_type = .timestamp,
                .query_count = frames * queries_per_frame,
            }, null);
            self.profiler = .{
                .pool = pool,
                .support = support,
                .variants = undefined,
                .counts = @splat(0),
                .sum_ns = @splat(0),
                .hits = @splat(0),
                .total_ns = 0,
                .dispatches = 0,
            };
        }
    }

    // Vulkan specification, vkDestroy*: every submission using these objects
    // must have completed. The host destroys its pipelines and resources in
    // `ffxFsr3UpscalerContextDestroy`; anything still alive here is released
    // too, so a context that failed half way through creation leaks nothing.
    pub fn deinit(self: *Backend) void {
        const device = &self.context.device;
        for (self.pipelines[0..self.pipeline_count]) |*pipeline| {
            if (pipeline.live) destroyPipelineObjects(device, pipeline);
        }
        for (&self.resources) |*resource| self.release(resource);
        for (self.samplers[0..self.sampler_count]) |entry| device.destroySampler(entry.handle, null);
        device.destroyDescriptorPool(self.pool, null);
        if (self.profiler) |profiler| device.destroyQueryPool(profiler.pool, null);
        self.constants.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn interface(self: *Backend) ffx.Interface {
        return .{
            .get_sdk_version = getSdkVersion,
            .get_effect_gpu_memory_usage = getEffectGpuMemoryUsage,
            .create_backend_context = createBackendContext,
            .get_device_capabilities = getDeviceCapabilities,
            .destroy_backend_context = destroyBackendContext,
            .create_resource = createResource,
            .register_resource = registerResource,
            .get_resource = null,
            .unregister_resources = unregisterResources,
            .register_static_resource = null,
            .get_resource_description = getResourceDescription,
            .destroy_resource = destroyResource,
            .map_resource = null,
            .unmap_resource = null,
            .stage_constant_buffer_data = stageConstantBufferData,
            .create_pipeline = createPipeline,
            .destroy_pipeline = destroyPipeline,
            .schedule_gpu_job = scheduleGpuJob,
            .execute_gpu_jobs = executeGpuJobs,
            .breadcrumbs_alloc_block = null,
            .breadcrumbs_free_block = null,
            .breadcrumbs_write = null,
            .breadcrumbs_print_device_info = null,
            .get_permutation_blob_by_index = null,
            .swap_chain_configure_frame_generation = null,
            .register_constant_buffer_allocator = null,
            .scratch_buffer = self,
            .scratch_buffer_size = @sizeOf(Backend),
            // The host only tests it for null, in
            // `ffxFsr3UpscalerContextGetGpuMemoryUsage`.
            .device = @ptrFromInt(@backingInt(self.context.device.handle)),
        };
    }

    // Before every call into the host that schedules work. The slot is
    // checked by the caller (`Upscaler.dispatch`), which returns an error for
    // one out of range.
    pub fn beginDispatch(self: *Backend, frame: u32) void {
        std.debug.assert(frame < self.frames);
        self.collect(frame);
        self.frame = frame;
        self.serial += 1;
        self.constant_cursor = 0;
    }

    // The slot's previous results, folded into the running means.
    fn collect(self: *Backend, frame: u32) void {
        const profiler = if (self.profiler) |*profiler| profiler else return;
        const count = profiler.counts[frame];
        if (count == 0) return;
        profiler.counts[frame] = 0;

        var ticks: [queries_per_frame]u64 = undefined;
        const queries = 2 + 2 * count;
        const result = self.context.device.getQueryPoolResults(
            profiler.pool,
            frame * queries_per_frame,
            queries,
            queries * @sizeOf(u64),
            &ticks,
            @sizeOf(u64),
            .{ .@"64_bit" = true },
        ) catch return;
        if (result != .success) return;

        profiler.total_ns += profiler.duration(ticks[0], ticks[1]);
        for (profiler.variants[frame][0..count], 0..) |variant, i| {
            const index = @backingInt(variant);
            profiler.sum_ns[index] += profiler.duration(ticks[2 + 2 * i], ticks[3 + 2 * i]);
            profiler.hits[index] += 1;
        }
        profiler.dispatches += 1;
        if (profiler.dispatches == report_every) report(profiler);
    }

    fn timestamp(self: *Backend, command_buffer: vk.CommandBuffer, query: u32) void {
        const profiler = &self.profiler.?;
        self.context.device.cmdWriteTimestamp2(
            command_buffer,
            .{ .all_commands_bit = true },
            profiler.pool,
            self.frame * queries_per_frame + query,
        );
    }

    fn release(self: *Backend, resource: *Resource) void {
        switch (resource.*) {
            .none, .external => {},
            .image => |*owned| {
                for (owned.storage_views[0..owned.storage_view_count]) |view|
                    self.context.device.destroyImageView(view, null);
                self.memory_usage -= owned.image.allocation.byte_len;
                owned.image.deinit();
            },
            .upload => |*buffer| buffer.deinit(),
        }
        resource.* = .none;
    }

    fn resourceAt(self: *Backend, index: i32) ?*Resource {
        if (index <= 0 or index >= max_resources) return null;
        const resource = &self.resources[@intCast(index)];
        return if (resource.* == .none) null else resource;
    }

    fn allocateStatic(self: *Backend) ?u32 {
        if (self.static_count >= max_static_resources) {
            log.err("more than {d} resources created", .{max_static_resources - 1});
            return null;
        }
        defer self.static_count += 1;
        return self.static_count;
    }

    fn pushJob(self: *Backend, job: Job) ffx.ErrorCode {
        if (self.job_count >= max_jobs) {
            log.err("more than {d} jobs scheduled in one dispatch", .{max_jobs});
            return ffx.error_out_of_range;
        }
        self.jobs[self.job_count] = job;
        self.job_count += 1;
        return ffx.ok;
    }

    // Synchronization

    // Brings `index` into `target`, adding a barrier to the batch when one is
    // needed: the layout changes, either side writes, or a read reaches a
    // stage the earlier dependency did not.
    //
    // Two reads in one layout share the state, so that a later write waits for
    // both. That is enough only when the stages and accesses already in the
    // state cover the new read: what made the image visible made it visible to
    // those alone. The main pass, for one, hands its colour over to the
    // fragment stage, and a compute read after it needs a barrier chained from
    // that stage (Vulkan specification, Synchronization and Cache Control,
    // "Execution and Memory Dependencies").
    fn require(self: *Backend, index: u32, target: Access) void {
        const state = self.stateOf(index);
        if (state.layout == target.layout and !writes(state.access) and !writes(target.access)) {
            if (state.stage.contains(target.stage) and state.access.contains(target.access)) return;
            const readers: Access = .{
                .layout = target.layout,
                .stage = state.stage.merge(target.stage),
                .access = state.access.merge(target.access),
            };
            self.transition(index, target);
            state.* = readers;
            return;
        }
        self.transition(index, target);
    }

    // Hands a registered image back in `target`. Unlike `require`, it adds a
    // barrier whenever the state is not exactly the target, even between two
    // reads in one layout: that execution dependency is what lets the caller
    // treat the image as last used at `target.stage`. Without it, a write the
    // caller orders after that stage would not wait for the upscaler's reads.
    fn settle(self: *Backend, index: u32, target: Access) void {
        if (std.meta.eql(self.stateOf(index).*, target)) return;
        self.transition(index, target);
    }

    fn stateOf(self: *Backend, index: u32) *Access {
        return switch (self.resources[index]) {
            .image => |*owned| &owned.state,
            .external => |*registered| &registered.state,
            .none, .upload => unreachable,
        };
    }

    fn transition(self: *Backend, index: u32, target: Access) void {
        const state = self.stateOf(index);
        const image, const aspect, const levels = switch (self.resources[index]) {
            .image => |*owned| .{ owned.image.handle, owned.image.kind.aspect(), owned.image.mip_levels },
            .external => |*registered| .{ registered.external.image, registered.external.aspect, 1 },
            .none, .upload => unreachable,
        };

        // The batch cannot overflow: one job touches at most one image per
        // binding, unregistering at most `max_dynamic_resources`, and the
        // batch is flushed before every command.
        std.debug.assert(self.barrier_count < max_barriers);
        self.barriers[self.barrier_count] = .{
            .src_stage_mask = state.stage,
            .src_access_mask = state.access,
            .dst_stage_mask = target.stage,
            .dst_access_mask = target.access,
            .old_layout = state.layout,
            .new_layout = target.layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{
                .aspect_mask = aspect,
                .base_mip_level = 0,
                .level_count = levels,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        self.barrier_count += 1;
        state.* = target;
    }

    fn flush(self: *Backend, command_buffer: vk.CommandBuffer) void {
        if (self.barrier_count == 0) return;
        self.context.device.cmdPipelineBarrier2(command_buffer, &.{
            .image_memory_barrier_count = self.barrier_count,
            .p_image_memory_barriers = &self.barriers,
        });
        self.barrier_count = 0;
    }

    // Recording

    fn recordClear(self: *Backend, command_buffer: vk.CommandBuffer, target: u32, color: [4]f32) void {
        self.require(target, clear_target);
        self.flush(command_buffer);
        const resource = &self.resources[target];
        const image, const levels = switch (resource.*) {
            .image => |*owned| .{ owned.image.handle, owned.image.mip_levels },
            .external => |*registered| .{ registered.external.image, 1 },
            .none, .upload => unreachable,
        };
        // The colour is given as floats whatever the format. For an integer
        // format Vulkan reads the same bits as integers (VkClearColorValue is
        // a union), and the host clears only with zeroes, whose bits are the
        // same either way.
        self.context.device.cmdClearColorImage(command_buffer, image, .transfer_dst_optimal, &.{ .float_32 = color }, &.{.{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = levels,
            .base_array_layer = 0,
            .layer_count = 1,
        }});
    }

    fn recordUpload(self: *Backend, command_buffer: vk.CommandBuffer, image_index: u32, source_index: u32) void {
        self.require(image_index, copy_target);
        self.flush(command_buffer);
        const owned = &self.resources[image_index].image;
        const source = &self.resources[source_index].upload;
        self.context.device.cmdCopyBufferToImage(command_buffer, source.handle, owned.image.handle, .transfer_dst_optimal, &.{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = owned.image.width, .height = owned.image.height, .depth = 1 },
        }});
    }

    fn recordCompute(self: *Backend, command_buffer: vk.CommandBuffer, job: *const Compute) ffx.ErrorCode {
        const pipeline = job.pipeline;
        if (pipeline.serial != self.serial) {
            pipeline.serial = self.serial;
            pipeline.uses = 0;
        }
        if (pipeline.uses >= uses_per_frame) {
            log.err("a pipeline was dispatched more than {d} times in one frame", .{uses_per_frame});
            return ffx.error_out_of_range;
        }
        const set = pipeline.sets[self.frame * uses_per_frame + pipeline.uses];
        pipeline.uses += 1;

        var image_infos: [2 * shaders.range]vk.DescriptorImageInfo = undefined;
        var buffer_infos: [ffx.max_num_const_buffers]vk.DescriptorBufferInfo = undefined;
        var writes_: [2 * shaders.range + ffx.max_num_const_buffers]vk.WriteDescriptorSet = undefined;
        var write_count: u32 = 0;

        // Storage images first, so that an image a pass also reads is in the
        // general layout for both of its descriptors rather than transitioned
        // twice into layouts the two disagree on.
        for (job.uavs[0..job.uav_count], 0..) |slot, i| {
            self.require(slot.resource, storage);
            const view = self.storageView(slot.resource, slot.mip) orelse {
                log.err("binding {d} writes an image registered without a storage view", .{slot.binding});
                return ffx.error_invalid_argument;
            };
            image_infos[i] = .{ .sampler = .null_handle, .image_view = view, .image_layout = .general };
            writes_[write_count] = imageWrite(set, slot.binding, .storage_image, &image_infos[i]);
            write_count += 1;
        }
        for (job.srvs[0..job.srv_count], @as(usize, job.uav_count)..) |slot, i| {
            const also_written = for (job.uavs[0..job.uav_count]) |uav| {
                if (uav.resource == slot.resource) break true;
            } else false;
            const layout: vk.ImageLayout = if (also_written) .general else blk: {
                self.require(slot.resource, sampled);
                break :blk .shader_read_only_optimal;
            };
            image_infos[i] = .{ .sampler = .null_handle, .image_view = self.sampledView(slot.resource), .image_layout = layout };
            writes_[write_count] = imageWrite(set, slot.binding, .sampled_image, &image_infos[i]);
            write_count += 1;
        }
        for (job.constants[0..job.constant_count], 0..) |slot, i| {
            buffer_infos[i] = .{
                .buffer = self.constants.handle(),
                .offset = slot.offset,
                .range = slot.size,
            };
            writes_[write_count] = .{
                .dst_set = set,
                .dst_binding = slot.binding,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .uniform_buffer,
                .p_image_info = &no_images,
                .p_buffer_info = @ptrCast(&buffer_infos[i]),
                .p_texel_buffer_view = &no_texel_buffers,
            };
            write_count += 1;
        }

        self.flush(command_buffer);
        const device = &self.context.device;
        device.updateDescriptorSets(writes_[0..write_count], null);
        device.cmdBindPipeline(command_buffer, .compute, pipeline.handle);
        device.cmdBindDescriptorSets(command_buffer, .compute, pipeline.layout, 0, &.{set}, &.{});
        device.cmdDispatch(command_buffer, job.groups[0], job.groups[1], job.groups[2]);
        return ffx.ok;
    }

    fn sampledView(self: *Backend, index: u32) vk.ImageView {
        return switch (self.resources[index]) {
            .image => |*owned| owned.image.view,
            .external => |*registered| registered.external.sampled_view,
            .none, .upload => unreachable,
        };
    }

    fn storageView(self: *Backend, index: u32, mip: u32) ?vk.ImageView {
        return switch (self.resources[index]) {
            .image => |*owned| if (mip < owned.storage_view_count) owned.storage_views[mip] else null,
            .external => |*registered| if (mip == 0 and registered.external.storage_view != .null_handle)
                registered.external.storage_view
            else
                null,
            .none, .upload => unreachable,
        };
    }

    fn samplerFor(self: *Backend, description: ffx.SamplerDescription) ?vk.Sampler {
        for (self.samplers[0..self.sampler_count]) |entry| {
            if (std.meta.eql(entry.description, description)) return entry.handle;
        }
        if (self.sampler_count >= max_samplers) return null;

        const filter: struct { vk.Filter, vk.SamplerMipmapMode } = switch (description.filter) {
            .minmagmip_point => .{ .nearest, .nearest },
            .minmagmip_linear => .{ .linear, .linear },
            .minmaglinearmip_point => .{ .linear, .nearest },
            _ => return null,
        };
        const handle = self.context.device.createSampler(&.{
            .mag_filter = filter[0],
            .min_filter = filter[0],
            .mipmap_mode = filter[1],
            .address_mode_u = addressMode(description.address_mode_u) orelse return null,
            .address_mode_v = addressMode(description.address_mode_v) orelse return null,
            .address_mode_w = addressMode(description.address_mode_w) orelse return null,
            .mip_lod_bias = 0,
            .anisotropy_enable = .false,
            .max_anisotropy = 1,
            .compare_enable = .false,
            .compare_op = .never,
            .min_lod = 0,
            .max_lod = vk.LOD_CLAMP_NONE,
            .border_color = .float_transparent_black,
            .unnormalized_coordinates = .false,
        }, null) catch return null;
        self.samplers[self.sampler_count] = .{ .description = description, .handle = handle };
        self.sampler_count += 1;
        return handle;
    }
};

fn imageWrite(
    set: vk.DescriptorSet,
    binding: u32,
    descriptor_type: vk.DescriptorType,
    info: *const vk.DescriptorImageInfo,
) vk.WriteDescriptorSet {
    return .{
        .dst_set = set,
        .dst_binding = binding,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = descriptor_type,
        .p_image_info = @ptrCast(info),
        .p_buffer_info = &no_buffers,
        .p_texel_buffer_view = &no_texel_buffers,
    };
}

// Vulkan specification, VkWriteDescriptorSet: the members not selected by
// descriptorType are ignored, but the pointers are not optional in the
// structure, so they are given something valid to point at.
const no_buffers = [_]vk.DescriptorBufferInfo{};
const no_images = [_]vk.DescriptorImageInfo{};
const no_texel_buffers = [_]vk.BufferView{};

// Clamp, wrap and mirror are what samplers here can be without a feature.
// Mirror-once needs `samplerMirrorClampToEdge`, which the context does not
// enable, and the upscaler asks for clamp alone.
fn addressMode(mode: ffx.AddressMode) ?vk.SamplerAddressMode {
    return switch (mode) {
        .wrap => .repeat,
        .mirror => .mirrored_repeat,
        .clamp => .clamp_to_edge,
        .border => .clamp_to_border,
        .mirror_once, _ => null,
    };
}

// The two pyramid passes reduce with quad operations, which `build.zig` names
// in the SPIR-V profile. Vulkan specification, VkPhysicalDeviceSubgroupProperties:
// support is reported per operation class and per stage.
fn supportsComputeQuads(context: *const gpu.Context) bool {
    var subgroup: vk.PhysicalDeviceSubgroupProperties = .{
        .subgroup_size = undefined,
        .supported_stages = undefined,
        .supported_operations = undefined,
        .quad_operations_in_all_stages = undefined,
    };
    var properties: vk.PhysicalDeviceProperties2 = .{
        .p_next = @ptrCast(&subgroup),
        .properties = undefined,
    };
    context.instance.getPhysicalDeviceProperties2(context.physical_device, &properties);
    return subgroup.supported_operations.quad_bit and subgroup.supported_stages.compute_bit;
}

// The formats the upscaler creates its images in. Anything else is refused at
// creation rather than guessed at.
pub fn vulkanFormat(format: ffx.SurfaceFormat) ?vk.Format {
    return switch (format) {
        .r8_unorm => .r8_unorm,
        .r8g8b8a8_unorm => .r8g8b8a8_unorm,
        .r16_float => .r16_sfloat,
        .r16_snorm => .r16_snorm,
        .r16g16_float => .r16g16_sfloat,
        .r16g16b16a16_float => .r16g16b16a16_sfloat,
        .r32_uint => .r32_uint,
        .r32_float => .r32_sfloat,
        .r32g32_float => .r32g32_sfloat,
        .r32g32b32a32_float => .r32g32b32a32_sfloat,
        .r11g11b10_float => .b10g11r11_ufloat_pack32,
        else => null,
    };
}

// Bytes per texel of the formats above, for checking initial data against the
// image it fills.
fn texelSize(format: vk.Format) u32 {
    return switch (format) {
        .r8_unorm => 1,
        .r16_sfloat, .r16_snorm => 2,
        .r8g8b8a8_unorm, .r16g16_sfloat, .r32_uint, .r32_sfloat, .b10g11r11_ufloat_pack32 => 4,
        .r16g16b16a16_sfloat, .r32g32_sfloat => 8,
        .r32g32b32a32_sfloat => 16,
        else => unreachable,
    };
}

// The passes read and write their storage images without a declared format,
// which the image's format has to admit (Vulkan specification, Formats,
// "Format Feature Flags": STORAGE_READ_WITHOUT_FORMAT and
// STORAGE_WRITE_WITHOUT_FORMAT).
pub fn supportsStorageWithoutFormat(context: *const gpu.Context, format: vk.Format) bool {
    var properties3: vk.FormatProperties3 = .{};
    var properties: vk.FormatProperties2 = .{
        .p_next = @ptrCast(&properties3),
        .format_properties = .{},
    };
    context.instance.getPhysicalDeviceFormatProperties2(context.physical_device, format, &properties);
    const features = properties3.optimal_tiling_features;
    return features.storage_image_bit and
        features.storage_read_without_format_bit and
        features.storage_write_without_format_bit;
}

fn destroyPipelineObjects(device: anytype, pipeline: *Pipeline) void {
    device.destroyPipeline(pipeline.handle, null);
    device.destroyPipelineLayout(pipeline.layout, null);
    device.destroyDescriptorSetLayout(pipeline.set_layout, null);
    pipeline.live = false;
}

fn widen(destination: *ffx.Name, ascii: []const u8) void {
    const len = @min(ascii.len, destination.len - 1);
    for (ascii[0..len], destination[0..len]) |byte, *unit| unit.* = byte;
    @memset(destination[len..], 0);
}

fn backendOf(interface: *ffx.Interface) *Backend {
    // `scratch_buffer` is set by `Backend.interface` and copied by the host
    // with the rest of the structure; nothing clears it.
    return @ptrCast(@alignCast(interface.scratch_buffer.?));
}

// The callbacks

fn getSdkVersion(_: *ffx.Interface) callconv(.c) u32 {
    // FFX_SDK_MAKE_VERSION(1, 1, 4): the host refuses any other.
    return (1 << 22) | (1 << 12) | 4;
}

fn getEffectGpuMemoryUsage(interface: *ffx.Interface, _: u32, out: *ffx.EffectMemoryUsage) callconv(.c) ffx.ErrorCode {
    out.* = .{ .total_usage_in_bytes = backendOf(interface).memory_usage, .aliasable_usage_in_bytes = 0 };
    return ffx.ok;
}

fn createBackendContext(
    interface: *ffx.Interface,
    effect: ffx.Effect,
    _: ?*ffx.EffectBindlessConfig,
    out_id: *u32,
) callconv(.c) ffx.ErrorCode {
    const self = backendOf(interface);
    if (effect != .fsr3upscaler or self.active) {
        log.err("a backend context for effect {d} refused: one upscaler context per backend", .{@backingInt(effect)});
        return ffx.error_invalid_argument;
    }
    self.active = true;
    out_id.* = 0;
    return ffx.ok;
}

fn destroyBackendContext(interface: *ffx.Interface, _: u32) callconv(.c) ffx.ErrorCode {
    backendOf(interface).active = false;
    return ffx.ok;
}

// What the host chooses its shader variants from, and nothing else: it reads
// these fields only in `getPipelinePermutationFlags`. They are therefore stated
// to select the variants `build.zig` compiled (`shaders.permutation`), not
// measured from the device. Lanes 32 to 64 select the lookup-table Lanczos; a
// shader model below 6.6 rules out forced wave64. FP16 is the one measured
// field: reported when the device enables 16-bit arithmetic and the caller
// asked for it, which selects the `_fp16` builds.
fn getDeviceCapabilities(interface: *ffx.Interface, out: *ffx.DeviceCapabilities) callconv(.c) ffx.ErrorCode {
    const self = backendOf(interface);
    out.* = .{
        .maximum_supported_shader_model = .@"6_2",
        .wave_lane_count_min = 32,
        .wave_lane_count_max = 64,
        .fp16_supported = self.fp16,
        .raytracing_supported = false,
        .device_coherent_memory_supported = false,
        .dedicated_allocation_supported = false,
        .buffer_marker_supported = false,
        .extended_synchronization_supported = false,
        .shader_storage_buffer_array_non_uniform_indexing = false,
    };
    return ffx.ok;
}

fn createResource(
    interface: *ffx.Interface,
    description: *const ffx.CreateResourceDescription,
    _: u32,
    out: *ffx.ResourceInternal,
) callconv(.c) ffx.ErrorCode {
    const self = backendOf(interface);
    const resource = description.resource_description;
    if (resource.type != .texture_2d or description.heap_type != .default) {
        log.err("only device-local 2D textures are created, not type {d} on heap {d}", .{ @backingInt(resource.type), @backingInt(description.heap_type) });
        return ffx.error_invalid_argument;
    }
    const format = vulkanFormat(resource.format) orelse {
        log.err("unsupported surface format {d}", .{@backingInt(resource.format)});
        return ffx.error_invalid_enum;
    };

    const largest = @max(resource.width, resource.height);
    if (largest == 0) return ffx.error_invalid_size;
    const mip_count: u32 = if (resource.mip_count == 0) @as(u32, std.math.log2_int(u32, largest)) + 1 else resource.mip_count;
    if (mip_count > max_mips) return ffx.error_invalid_size;

    const writable = resource.usage.uav;
    if (writable and !supportsStorageWithoutFormat(self.context, format)) {
        log.err("{t} cannot be a storage image without a declared format on this device", .{format});
        return ffx.error_backend_api_error;
    }

    const initial = description.init_data;
    const has_initial_data = switch (initial.type) {
        .uninitialized => false,
        .buffer, .value => true,
        .invalid, _ => return ffx.error_invalid_argument,
    };
    if (has_initial_data and initial.size != @as(usize, resource.width) * resource.height * texelSize(format)) {
        log.err("initial data of {d} bytes does not fill a {d}x{d} {t}", .{ initial.size, resource.width, resource.height, format });
        return ffx.error_invalid_size;
    }

    const index = self.allocateStatic() orelse return ffx.error_out_of_memory;

    var image = gpu.Image.init(self.context, self.memory_allocator, .{
        .width = resource.width,
        .height = resource.height,
        .format = format,
        .mip_levels = mip_count,
        .usage = .{
            .sampled_bit = true,
            .transfer_dst_bit = true,
            .storage_bit = writable,
        },
    }) catch |err| {
        log.err("creating a {d}x{d} {t}: {t}", .{ resource.width, resource.height, format, err });
        return ffx.error_backend_api_error;
    };

    var owned: Owned = .{
        .image = image,
        .storage_views = undefined,
        .storage_view_count = 0,
        .description = resource,
        .state = .undefined_layout,
    };
    owned.description.mip_count = mip_count;
    if (writable) {
        for (0..mip_count) |level| {
            owned.storage_views[level] = image.createMipView(@intCast(level)) catch |err| {
                for (owned.storage_views[0..owned.storage_view_count]) |view|
                    self.context.device.destroyImageView(view, null);
                image.deinit();
                log.err("creating a level view: {t}", .{err});
                return ffx.error_backend_api_error;
            };
            owned.storage_view_count += 1;
        }
    }
    self.resources[index] = .{ .image = owned };
    self.memory_usage += owned.image.allocation.byte_len;
    out.internal_index = @intCast(index);

    if (!has_initial_data) return ffx.ok;

    // The upload buffer takes the next index, which is where the host looks
    // for it when it releases the context (`ffxSafeReleaseCopyResource`).
    const source_index = self.allocateStatic() orelse return ffx.error_out_of_memory;
    var buffer = gpu.Buffer.init(self.context, self.memory_allocator, initial.size, .{ .transfer_src_bit = true }, .upload) catch |err| {
        log.err("creating an upload buffer: {t}", .{err});
        return ffx.error_backend_api_error;
    };
    const bytes = buffer.allocation.mappedBytes().?[0..initial.size];
    switch (initial.type) {
        .buffer => {
            const data: [*]const u8 = @ptrCast(initial.payload.buffer orelse {
                buffer.deinit();
                return ffx.error_invalid_pointer;
            });
            @memcpy(bytes, data[0..initial.size]);
        },
        .value => @memset(bytes, initial.payload.value),
        .uninitialized, .invalid, _ => unreachable,
    }
    self.resources[source_index] = .{ .upload = buffer };
    return self.pushJob(.{ .upload = .{ .image = index, .source = source_index } });
}

fn registerResource(
    interface: *ffx.Interface,
    resource: *const ffx.Resource,
    _: u32,
    out: *ffx.ResourceInternal,
) callconv(.c) ffx.ErrorCode {
    const self = backendOf(interface);
    const pointer = resource.resource orelse {
        out.internal_index = 0;
        return ffx.ok;
    };
    if (self.dynamic_count >= max_dynamic_resources) {
        log.err("more than {d} resources registered in one dispatch", .{max_dynamic_resources});
        return ffx.error_out_of_range;
    }

    const external: *const External = @ptrCast(@alignCast(pointer));
    const index = max_static_resources + self.dynamic_count;
    self.dynamic_count += 1;
    self.resources[index] = .{ .external = .{
        .external = external,
        .description = resource.description,
        .state = external.before,
    } };
    out.internal_index = @intCast(index);
    return ffx.ok;
}

fn unregisterResources(interface: *ffx.Interface, command_list: ffx.CommandList, _: u32) callconv(.c) ffx.ErrorCode {
    const self = backendOf(interface);
    const command_buffer = commandBufferOf(command_list) orelse return ffx.error_invalid_pointer;
    for (max_static_resources..max_static_resources + self.dynamic_count) |index| {
        self.settle(@intCast(index), self.resources[index].external.external.after);
    }
    self.flush(command_buffer);
    for (max_static_resources..max_static_resources + self.dynamic_count) |index| {
        self.resources[index] = .none;
    }
    self.dynamic_count = 0;
    return ffx.ok;
}

fn getResourceDescription(interface: *ffx.Interface, resource: ffx.ResourceInternal) callconv(.c) ffx.ResourceDescription {
    const self = backendOf(interface);
    const found = self.resourceAt(resource.internal_index) orelse return std.mem.zeroes(ffx.ResourceDescription);
    return switch (found.*) {
        .image => |*owned| owned.description,
        .external => |*registered| registered.description,
        .none, .upload => std.mem.zeroes(ffx.ResourceDescription),
    };
}

// A null, unknown or already released index is not an error: the host
// releases every identifier it has, including ones it never created.
fn destroyResource(interface: *ffx.Interface, resource: ffx.ResourceInternal, _: u32) callconv(.c) ffx.ErrorCode {
    const self = backendOf(interface);
    if (resource.internal_index >= max_static_resources) return ffx.ok;
    const found = self.resourceAt(resource.internal_index) orelse return ffx.ok;
    self.release(found);
    return ffx.ok;
}

fn stageConstantBufferData(
    interface: *ffx.Interface,
    data: ?*anyopaque,
    size: u32,
    out: *ffx.ConstantBuffer,
) callconv(.c) ffx.ErrorCode {
    const self = backendOf(interface);
    const source: [*]const u8 = @ptrCast(data orelse return ffx.error_invalid_pointer);
    if (size % 4 != 0 or size > constant_block_size) {
        log.err("a constant block of {d} bytes", .{size});
        return ffx.error_invalid_size;
    }
    if (self.constant_cursor >= constant_blocks_per_frame) {
        log.err("more than {d} constant blocks staged in one dispatch", .{constant_blocks_per_frame});
        return ffx.error_out_of_range;
    }
    const block = &self.constants.slice(self.frame)[self.constant_cursor];
    self.constant_cursor += 1;
    @memcpy(std.mem.asBytes(block)[0..size], source[0..size]);
    out.* = .{ .num_32bit_entries = size / 4, .data = &block.words };
    return ffx.ok;
}

fn createPipeline(
    interface: *ffx.Interface,
    effect: ffx.Effect,
    pass: ffx.Pass,
    permutation_bits: u32,
    description: *const ffx.PipelineDescription,
    _: u32,
    out: *ffx.PipelineState,
) callconv(.c) ffx.ErrorCode {
    const self = backendOf(interface);
    if (effect != .fsr3upscaler) return ffx.error_invalid_argument;
    const variant = shaders.forPass(@fromBackingInt(@intCast(pass)), permutation_bits) catch {
        log.err("no variant built for pass {d} with permutation {x}", .{ pass, permutation_bits });
        return ffx.error_invalid_argument;
    };
    if (self.pipeline_count >= max_pipelines) {
        log.err("more than {d} pipelines created", .{max_pipelines});
        return ffx.error_out_of_range;
    }

    const bindings = &self.bindings[@backingInt(variant)];
    const create = buildPipeline(self, bindings, shaders.shader(variant), description) catch |err| {
        log.err("creating the {t} pipeline: {t}", .{ variant, err });
        return ffx.error_backend_api_error;
    };
    const record = &self.pipelines[self.pipeline_count];
    record.* = create;
    record.variant = variant;
    self.pipeline_count += 1;

    // Zeroed in place: the structure is tens of kilobytes, and a zeroed value
    // built first would be a stack temporary of that size.
    @memset(std.mem.asBytes(out), 0);
    out.root_signature = record;
    out.pass_id = pass;
    out.pipeline = @ptrFromInt(@backingInt(record.handle));
    out.srv_texture_count = @intCast(bindings.srv_textures.len);
    out.uav_texture_count = @intCast(bindings.uav_textures.len);
    out.const_count = @intCast(bindings.constant_buffers.len);
    for (bindings.srv_textures, out.srv_texture_bindings[0..bindings.srv_textures.len]) |binding, *slot| {
        slot.slot_index = binding.binding;
        widen(&slot.name, binding.name);
    }
    for (bindings.uav_textures, out.uav_texture_bindings[0..bindings.uav_textures.len]) |binding, *slot| {
        slot.slot_index = binding.binding;
        widen(&slot.name, binding.name);
    }
    for (bindings.constant_buffers, out.constant_buffer_bindings[0..bindings.constant_buffers.len]) |binding, *slot| {
        slot.slot_index = binding.binding;
        widen(&slot.name, binding.name);
    }
    out.name = description.name;
    return ffx.ok;
}

const BuildError = error{
    TooManyBindings,
    UndescribedSampler,
    SamplerUnavailable,
} || vk.DeviceWrapper.CreateDescriptorSetLayoutError ||
    vk.DeviceWrapper.AllocateDescriptorSetsError ||
    gpu.Pipeline.CreateError;

fn buildPipeline(
    self: *Backend,
    bindings: *const shaders.Bindings,
    shader: shaders.Shader,
    description: *const ffx.PipelineDescription,
) BuildError!Pipeline {
    const device = &self.context.device;
    const compute: vk.ShaderStageFlags = .{ .compute_bit = true };

    if (bindings.constant_buffers.len > ffx.max_num_const_buffers or bindings.samplers.len > max_samplers)
        return error.TooManyBindings;

    // The immutable samplers: register `sN` is the host's `samplers[N]`.
    var immutable: [max_samplers]vk.Sampler = undefined;
    for (bindings.samplers, 0..) |binding, i| {
        const index = binding - shaders.sampler_base;
        const samplers = description.samplers orelse return error.UndescribedSampler;
        if (index >= description.sampler_count) return error.UndescribedSampler;
        immutable[i] = self.samplerFor(samplers[index]) orelse return error.SamplerUnavailable;
    }

    var layout_bindings: [2 * shaders.range + ffx.max_num_const_buffers + max_samplers]vk.DescriptorSetLayoutBinding = undefined;
    var count: u32 = 0;
    for (bindings.srv_textures) |binding| {
        layout_bindings[count] = .{ .binding = binding.binding, .descriptor_type = .sampled_image, .descriptor_count = 1, .stage_flags = compute };
        count += 1;
    }
    for (bindings.uav_textures) |binding| {
        layout_bindings[count] = .{ .binding = binding.binding, .descriptor_type = .storage_image, .descriptor_count = 1, .stage_flags = compute };
        count += 1;
    }
    for (bindings.constant_buffers) |binding| {
        layout_bindings[count] = .{ .binding = binding.binding, .descriptor_type = .uniform_buffer, .descriptor_count = 1, .stage_flags = compute };
        count += 1;
    }
    for (bindings.samplers, 0..) |binding, i| {
        layout_bindings[count] = .{
            .binding = binding,
            .descriptor_type = .sampler,
            .descriptor_count = 1,
            .stage_flags = compute,
            .p_immutable_samplers = @ptrCast(&immutable[i]),
        };
        count += 1;
    }

    const set_layout = try device.createDescriptorSetLayout(&.{
        .binding_count = count,
        .p_bindings = &layout_bindings,
    }, null);
    errdefer device.destroyDescriptorSetLayout(set_layout, null);

    const layout = try gpu.Pipeline.createLayout(self.context, .{ .descriptor_sets = &.{set_layout} });
    errdefer device.destroyPipelineLayout(layout, null);

    const module = try gpu.Pipeline.createModule(self.context, shader.spirv);
    defer device.destroyShaderModule(module, null);

    const handle = try gpu.Pipeline.createCompute(self.context, .{
        .layout = layout,
        .stage = .{ .module = module, .entry_point = "CS" },
    });
    errdefer device.destroyPipeline(handle, null);

    var record: Pipeline = .{
        .set_layout = set_layout,
        .layout = layout,
        .handle = handle,
        .sets = undefined,
        .serial = 0,
        .uses = 0,
        .live = true,
        .variant = undefined,
    };
    const set_count = self.frames * uses_per_frame;
    var layouts: [max_frames * uses_per_frame]vk.DescriptorSetLayout = @splat(set_layout);
    try device.allocateDescriptorSets(&.{
        .descriptor_pool = self.pool,
        .descriptor_set_count = set_count,
        .p_set_layouts = &layouts,
    }, &record.sets);
    return record;
}

// The pool's sets are not returned: the host creates its pipelines once per
// context, and a context is one backend's whole life.
fn destroyPipeline(interface: *ffx.Interface, state: ?*ffx.PipelineState, _: u32) callconv(.c) ffx.ErrorCode {
    const self = backendOf(interface);
    const pipeline_state = state orelse return ffx.ok;
    const record: *Pipeline = @ptrCast(@alignCast(pipeline_state.root_signature orelse return ffx.ok));
    if (record.live) destroyPipelineObjects(&self.context.device, record);
    pipeline_state.root_signature = null;
    pipeline_state.pipeline = null;
    return ffx.ok;
}

fn scheduleGpuJob(interface: *ffx.Interface, job: *const ffx.GpuJobDescription) callconv(.c) ffx.ErrorCode {
    const self = backendOf(interface);
    switch (job.job_type) {
        .clear_float => {
            const clear = job.job.clear;
            const target = self.resourceAt(clear.target.internal_index) orelse return ffx.error_invalid_argument;
            if (target.* == .upload) return ffx.error_invalid_argument;
            return self.pushJob(.{ .clear = .{ .target = @intCast(clear.target.internal_index), .color = clear.color } });
        },
        // A hint that a resource's contents may be dropped. Ignoring it
        // only keeps contents nothing reads.
        .discard => return ffx.ok,
        .compute => {
            var compute: Compute = undefined;
            const code = translateCompute(self, &job.job.compute, &compute);
            if (code != ffx.ok) return code;
            return self.pushJob(.{ .compute = compute });
        },
        .copy, .barrier, _ => {
            log.err("unsupported job type {d}", .{@backingInt(job.job_type)});
            return ffx.error_invalid_argument;
        },
    }
}

fn translateCompute(self: *Backend, job: *const ffx.ComputeJobDescription, out: *Compute) ffx.ErrorCode {
    const state = &job.pipeline;
    const pipeline: *Pipeline = @ptrCast(@alignCast(state.root_signature orelse return ffx.error_invalid_pointer));
    if (state.cmd_signature != null or state.srv_buffer_count != 0 or state.uav_buffer_count != 0)
        return ffx.error_invalid_argument;
    if (state.srv_texture_count > shaders.range or state.uav_texture_count > shaders.range or
        state.const_count > ffx.max_num_const_buffers)
        return ffx.error_out_of_range;

    out.pipeline = pipeline;
    out.groups = job.dimensions;
    out.srv_count = state.srv_texture_count;
    out.uav_count = state.uav_texture_count;
    out.constant_count = state.const_count;

    for (0..state.srv_texture_count) |i| {
        const index = job.srv_textures[i].resource.internal_index;
        const resource = self.resourceAt(index) orelse {
            log.err("a pass binds no resource to binding {d}", .{state.srv_texture_bindings[i].slot_index});
            return ffx.error_invalid_argument;
        };
        if (resource.* == .upload) return ffx.error_invalid_argument;
        out.srvs[i] = .{ .binding = state.srv_texture_bindings[i].slot_index, .resource = @intCast(index) };
    }
    for (0..state.uav_texture_count) |i| {
        const uav = job.uav_textures[i];
        const resource = self.resourceAt(uav.resource.internal_index) orelse {
            log.err("a pass binds no resource to binding {d}", .{state.uav_texture_bindings[i].slot_index});
            return ffx.error_invalid_argument;
        };
        if (resource.* == .upload) return ffx.error_invalid_argument;
        out.uavs[i] = .{
            .binding = state.uav_texture_bindings[i].slot_index,
            .resource = @intCast(uav.resource.internal_index),
            .mip = uav.mip,
        };
    }

    // Constants were staged into this frame's ring slot, so the job keeps the
    // offset from the ring's start, which is what the descriptor names.
    const ring = std.mem.sliceAsBytes(self.constants.slice(self.frame));
    const ring_start = @intFromPtr(ring.ptr) - self.constants.dynamicOffset(self.frame);
    for (0..state.const_count) |i| {
        const constant = job.cbs[i];
        const data = @intFromPtr(constant.data orelse return ffx.error_invalid_pointer);
        if (data < @intFromPtr(ring.ptr) or data >= @intFromPtr(ring.ptr) + ring.len) {
            log.err("constants not staged through this backend for this frame", .{});
            return ffx.error_invalid_argument;
        }
        out.constants[i] = .{
            .binding = state.constant_buffer_bindings[i].slot_index,
            .offset = @intCast(data - ring_start),
            .size = constant.num_32bit_entries * 4,
        };
    }
    return ffx.ok;
}

fn executeGpuJobs(interface: *ffx.Interface, command_list: ffx.CommandList, _: u32) callconv(.c) ffx.ErrorCode {
    const self = backendOf(interface);
    defer self.job_count = 0;
    const command_buffer = commandBufferOf(command_list) orelse return ffx.error_invalid_pointer;

    // Each pass is timed with the barriers recorded before it, so the passes
    // add up to the dispatch and the synchronisation is charged to whichever
    // pass waited for it.
    var timed: u32 = 0;
    if (self.profiler != null) {
        self.context.device.cmdResetQueryPool(
            command_buffer,
            self.profiler.?.pool,
            self.frame * queries_per_frame,
            queries_per_frame,
        );
        self.timestamp(command_buffer, 0);
    }

    for (self.jobs[0..self.job_count]) |*job| {
        switch (job.*) {
            .clear => |clear| self.recordClear(command_buffer, clear.target, clear.color),
            .upload => |upload| self.recordUpload(command_buffer, upload.image, upload.source),
            .compute => |*compute| {
                const timing = self.profiler != null and timed < timed_per_frame;
                if (timing) self.timestamp(command_buffer, 2 + 2 * timed);
                const code = self.recordCompute(command_buffer, compute);
                if (code != ffx.ok) return code;
                if (timing) {
                    self.timestamp(command_buffer, 3 + 2 * timed);
                    self.profiler.?.variants[self.frame][timed] = compute.pipeline.variant;
                    timed += 1;
                }
            },
        }
    }

    if (self.profiler) |*profiler| {
        self.timestamp(command_buffer, 1);
        profiler.counts[self.frame] = timed;
    }
    return ffx.ok;
}

fn report(profiler: *Profiler) void {
    var buffer: [768]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const dispatches: f64 = @floatFromInt(profiler.dispatches);
    writer.print("gpu ms over {d} dispatches: total {d:.2}", .{
        profiler.dispatches,
        @as(f64, @floatFromInt(profiler.total_ns)) / dispatches / 1e6,
    }) catch {};
    for (profiler.sum_ns, profiler.hits, 0..) |sum, hits, index| {
        if (hits == 0) continue;
        const variant: shaders.Variant = @fromBackingInt(@intCast(index));
        writer.print(", {t} {d:.2}", .{ variant, @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(hits)) / 1e6 }) catch {};
    }
    log.info("{s}", .{writer.buffered()});
    profiler.sum_ns = @splat(0);
    profiler.hits = @splat(0);
    profiler.total_ns = 0;
    profiler.dispatches = 0;
}

fn commandBufferOf(command_list: ffx.CommandList) ?vk.CommandBuffer {
    const pointer = command_list orelse return null;
    return @fromBackingInt(@intFromPtr(pointer));
}

pub fn commandList(command_buffer: vk.CommandBuffer) ffx.CommandList {
    return @ptrFromInt(@backingInt(command_buffer));
}

const std = @import("std");
const gpu = @import("lenore-gpu");

const ffx = @import("ffx.zig");

const Allocator = std.mem.Allocator;

// The upscaler's compute passes as `build.zig` compiled them, and what each
// one binds, read from Slang's reflection of the same compile.
//
// One variant per pass, plus `accumulate` with sharpening. Which variant the
// host asks for follows from the context's flags and from the capabilities the
// backend reports; `permutation` below is the one combination both produce, and
// a request for any other is refused rather than served with the wrong code.

pub const Shader = struct {
    spirv: []const u32,
    reflection: []const u8,
};

// The permutation the host asks for given the context flags `Upscaler` creates
// it with (HDR colour, motion at render resolution without jitter, depth not
// inverted) and the capabilities the backend reports (lanes 32 to 64, so the
// lookup-table Lanczos; no 16-bit arithmetic; no forced wave64). Sharpening is
// the one bit that varies, per dispatch.
pub const permutation: ffx.Fsr3UpscalerPermutation = .{
    .use_lanczos_type = true,
    .hdr_color_input = true,
    .low_res_motion_vectors = true,
};

// One per compiled module. The order is `all`'s. `_fp16` is the same pass
// built with `FFX_HALF=1`, for the passes upstream has a 16-bit build of.
pub const Variant = enum {
    prepare_inputs,
    luma_pyramid,
    shading_change_pyramid,
    shading_change,
    prepare_reactivity,
    luma_instability,
    accumulate,
    accumulate_sharpen,
    rcas,
    debug_view,
    autogen_reactive,
    shading_change_fp16,
    prepare_reactivity_fp16,
    accumulate_fp16,
    accumulate_sharpen_fp16,
    autogen_reactive_fp16,
};

// The host sets `allow_fp16` on every pass but RCAS when the backend reports
// 16-bit support, and `enable_sharpening` on the sharpened accumulate. Every
// other bit has to be `permutation`'s.
//
// `allow_fp16` selects a 16-bit build only where upstream's own selector does
// (`ffx_fsr3upscaler_shaderblobs.cpp`): prepare reactivity, shading change,
// accumulate and the reactive mask. For the rest it ignores the bit and loads
// the 32-bit build, and so does this. Their 16-bit sources are not meant to
// run: the luminance pyramid's `SpdLoadSourceImageH` returns zero and its
// `SpdStoreH` is empty, so a 16-bit pyramid writes nothing at all (measured:
// 0.01 ms against 0.14, and no storage writes in its SPIR-V).
pub fn forPass(pass: ffx.Fsr3UpscalerPass, permutation_bits: u32) error{UnsupportedPermutation}!Variant {
    const requested: ffx.Fsr3UpscalerPermutation = @bitCast(permutation_bits);
    var base = requested;
    base.enable_sharpening = false;
    base.allow_fp16 = false;
    if (@as(u32, @bitCast(base)) != @as(u32, @bitCast(permutation))) return error.UnsupportedPermutation;

    const half = requested.allow_fp16;
    return switch (pass) {
        .prepare_inputs => .prepare_inputs,
        .luma_pyramid => .luma_pyramid,
        .shading_change_pyramid => .shading_change_pyramid,
        .shading_change => if (half) .shading_change_fp16 else .shading_change,
        .prepare_reactivity => if (half) .prepare_reactivity_fp16 else .prepare_reactivity,
        .luma_instability => .luma_instability,
        .accumulate, .accumulate_sharpen => if (requested.enable_sharpening)
            (if (half) .accumulate_sharpen_fp16 else .accumulate_sharpen)
        else
            (if (half) .accumulate_fp16 else .accumulate),
        // Upstream has a 16-bit RCAS, but the host asks for it only on Xbox.
        .rcas => if (half) error.UnsupportedPermutation else .rcas,
        .debug_view => .debug_view,
        .generate_reactive => if (half) .autogen_reactive_fp16 else .autogen_reactive,
        .tcr_autogenerate, _ => error.UnsupportedPermutation,
    };
}

pub fn shader(variant: Variant) Shader {
    return all[@backingInt(variant)];
}

fn embedded(comptime name: []const u8) Shader {
    return .{
        .spirv = gpu.spirvWords(@embedFile(name)),
        .reflection = @embedFile(name ++ "_reflection"),
    };
}

pub const all = blk: {
    var shaders: [std.enums.values(Variant).len]Shader = undefined;
    for (std.enums.values(Variant), 0..) |variant, i| {
        shaders[i] = embedded("fsr3upscaler_" ++ @tagName(variant));
    }
    break :blk shaders;
};

// Where `build.zig` shifts each HLSL register class (`-fvk-*-shift`). A
// register `tN` is binding `srv_base + N`, and so on; the ranges are sixteen
// wide.
pub const srv_base = 0;
pub const uav_base = 16;
pub const cb_base = 32;
pub const sampler_base = 48;
pub const range = 16;

pub const Binding = struct {
    name: []const u8,
    binding: u32,
};

// One pass's interface, in reflection order: what its entry point uses.
//
// Used, not declared. The host looks every binding a pipeline reports up in
// its own name tables (`patchResourceBindings`) and fails the whole context on
// a name it does not know, and its tables list what upstream's compiler
// reports, which is the used set: `autogen_reactive` declares
// `rw_output_autocomposition` and never touches it, and no table names it.
pub const Bindings = struct {
    srv_textures: []const Binding,
    uav_textures: []const Binding,
    constant_buffers: []const Binding,
    // By sampler description index: register `sN` is the host's `samplers[N]`.
    samplers: []const u32,
};

pub const ReflectionError = error{
    MalformedReflection,
    UnsupportedBinding,
    BindingOutOfRange,
} || Allocator.Error;

// The part of Slang's `-reflection-json` this reads. Unknown fields are
// ignored: the file carries layouts and types beside these. Whether a
// parameter is used is reported per entry point, and every module here has
// one.
const Reflection = struct {
    entryPoints: []const struct {
        bindings: []const struct {
            name: []const u8,
            binding: struct { used: u32 },
        },
    },
    parameters: []const struct {
        name: []const u8,
        binding: ?struct {
            kind: []const u8,
            index: u32,
        } = null,
        type: struct {
            kind: []const u8,
            baseShape: ?[]const u8 = null,
        },
    },
};

// Every string in the result is owned by `arena`.
pub fn parseBindings(arena: Allocator, json: []const u8) ReflectionError!Bindings {
    const parsed = std.json.parseFromSliceLeaky(Reflection, arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedReflection,
    };

    var srvs: std.ArrayList(Binding) = .empty;
    var uavs: std.ArrayList(Binding) = .empty;
    var cbs: std.ArrayList(Binding) = .empty;
    var samplers: std.ArrayList(u32) = .empty;

    if (parsed.entryPoints.len != 1) return error.MalformedReflection;
    const usage = parsed.entryPoints[0].bindings;

    for (parsed.parameters) |parameter| {
        const binding = parameter.binding orelse return error.MalformedReflection;
        const used = for (usage) |entry| {
            if (std.mem.eql(u8, entry.name, parameter.name)) break entry.binding.used != 0;
        } else return error.MalformedReflection;
        if (!used) continue;
        const kind = binding.kind;
        if (std.mem.eql(u8, kind, "shaderResource")) {
            try requireTexture2D(parameter.type.kind, parameter.type.baseShape);
            try srvs.append(arena, .{ .name = parameter.name, .binding = try inRange(binding.index, srv_base) });
        } else if (std.mem.eql(u8, kind, "unorderedAccess")) {
            try requireTexture2D(parameter.type.kind, parameter.type.baseShape);
            try uavs.append(arena, .{ .name = parameter.name, .binding = try inRange(binding.index, uav_base) });
        } else if (std.mem.eql(u8, kind, "constantBuffer")) {
            try cbs.append(arena, .{ .name = parameter.name, .binding = try inRange(binding.index, cb_base) });
        } else if (std.mem.eql(u8, kind, "samplerState")) {
            _ = try inRange(binding.index, sampler_base);
            try samplers.append(arena, binding.index);
        } else {
            return error.UnsupportedBinding;
        }
    }

    return .{
        .srv_textures = srvs.items,
        .uav_textures = uavs.items,
        .constant_buffers = cbs.items,
        .samplers = samplers.items,
    };
}

// Every resource the upscaler binds is a 2D texture. A buffer or another shape
// would need a descriptor type and a view this backend does not make, so it is
// refused here, at startup, rather than bound wrongly.
fn requireTexture2D(kind: []const u8, shape: ?[]const u8) ReflectionError!void {
    if (!std.mem.eql(u8, kind, "resource")) return error.UnsupportedBinding;
    const base = shape orelse return error.UnsupportedBinding;
    if (!std.mem.eql(u8, base, "texture2D")) return error.UnsupportedBinding;
}

fn inRange(index: u32, base: u32) ReflectionError!u32 {
    if (index < base or index >= base + range) return error.BindingOutOfRange;
    return index;
}

const std = @import("std");
const fsr = @import("lenore-fsr");

const ffx = fsr.ffx;
const shaders = fsr.shaders;
const testing = std.testing;

test "every pass's reflection reads, inside the ranges the build shifted it into" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (shaders.all) |shader| {
        const bindings = try shaders.parseBindings(arena, shader.reflection);
        try testing.expect(bindings.constant_buffers.len > 0);
        for (bindings.srv_textures) |b| try testing.expect(b.binding < shaders.uav_base);
        for (bindings.uav_textures) |b| try testing.expect(b.binding >= shaders.uav_base and b.binding < shaders.cb_base);
        // The host describes two samplers, point then linear, and the passes
        // declare them as `s0` and `s1`.
        for (bindings.samplers) |binding| try testing.expect(binding - shaders.sampler_base < 2);
    }
}

test "the luminance pyramid binds each level it writes on its own" {
    // The host binds the pyramid's levels as six separate storage images, one
    // per mip, by name. That only works if the shader declares them that way.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const variant = try shaders.forPass(.luma_pyramid, @bitCast(shaders.permutation));
    const bindings = try shaders.parseBindings(arena_state.allocator(), shaders.shader(variant).reflection);
    var levels: usize = 0;
    for (bindings.uav_textures) |b| {
        if (std.mem.startsWith(u8, b.name, "rw_spd_mip")) levels += 1;
    }
    try testing.expectEqual(@as(usize, 6), levels);
}

test "only the built permutation is served, with sharpening as its one free bit" {
    const base: u32 = @bitCast(shaders.permutation);
    var sharpened = shaders.permutation;
    sharpened.enable_sharpening = true;

    try testing.expectEqual(shaders.Variant.accumulate, try shaders.forPass(.accumulate, base));
    try testing.expectEqual(shaders.Variant.accumulate_sharpen, try shaders.forPass(.accumulate_sharpen, @bitCast(sharpened)));
    // The host asks for the sharpened pass by its permutation bit, whichever
    // of the two pass identifiers it names.
    try testing.expectEqual(shaders.Variant.accumulate_sharpen, try shaders.forPass(.accumulate, @bitCast(sharpened)));

    var inverted = shaders.permutation;
    inverted.depth_inverted = true;
    try testing.expectError(error.UnsupportedPermutation, shaders.forPass(.prepare_inputs, @bitCast(inverted)));

    try testing.expectError(error.UnsupportedPermutation, shaders.forPass(.tcr_autogenerate, base));
}

test "the 16-bit bit selects the 16-bit build of the same pass" {
    var half = shaders.permutation;
    half.allow_fp16 = true;
    try testing.expectEqual(shaders.Variant.prepare_reactivity_fp16, try shaders.forPass(.prepare_reactivity, @bitCast(half)));
    // Where upstream has no 16-bit build the bit is ignored, as its own
    // selector ignores it: the 16-bit pyramid source writes nothing.
    try testing.expectEqual(shaders.Variant.luma_pyramid, try shaders.forPass(.luma_pyramid, @bitCast(half)));
    try testing.expectEqual(shaders.Variant.prepare_inputs, try shaders.forPass(.prepare_inputs, @bitCast(half)));
    half.enable_sharpening = true;
    try testing.expectEqual(shaders.Variant.accumulate_sharpen_fp16, try shaders.forPass(.accumulate, @bitCast(half)));
    // The host never asks for a 16-bit RCAS, and none is built.
    try testing.expectError(error.UnsupportedPermutation, shaders.forPass(.rcas, @bitCast(half)));
}

test "malformed reflection is an error, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.MalformedReflection, shaders.parseBindings(arena, "{"));
    // No entry point, so nothing says what is used.
    try testing.expectError(error.MalformedReflection, shaders.parseBindings(arena,
        \\{"parameters": [], "entryPoints": []}
    ));
    try testing.expectError(error.MalformedReflection, shaders.parseBindings(arena,
        \\{"parameters": [{"name": "x", "type": {"kind": "resource", "baseShape": "texture2D"}}],
        \\ "entryPoints": [{"bindings": [{"name": "x", "binding": {"used": 1}}]}]}
    ));
    try testing.expectError(error.UnsupportedBinding, shaders.parseBindings(arena,
        \\{"parameters": [{"name": "x", "binding": {"kind": "shaderResource", "index": 0},
        \\  "type": {"kind": "resource", "baseShape": "structuredBuffer"}}],
        \\ "entryPoints": [{"bindings": [{"name": "x", "binding": {"used": 1}}]}]}
    ));
    try testing.expectError(error.BindingOutOfRange, shaders.parseBindings(arena,
        \\{"parameters": [{"name": "x", "binding": {"kind": "unorderedAccess", "index": 3},
        \\  "type": {"kind": "resource", "baseShape": "texture2D"}}],
        \\ "entryPoints": [{"bindings": [{"name": "x", "binding": {"used": 1}}]}]}
    ));
}

test "an unused binding is left out" {
    // The case that failed the context on the device: declared, never read,
    // and named in none of the host's tables.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const variant = try shaders.forPass(.generate_reactive, @bitCast(shaders.permutation));
    const bindings = try shaders.parseBindings(arena_state.allocator(), shaders.shader(variant).reflection);
    for (bindings.uav_textures) |b| try testing.expect(!std.mem.eql(u8, b.name, "rw_output_autocomposition"));
    try testing.expectEqual(@as(usize, 1), bindings.uav_textures.len);
}

test "every used binding is one the host's tables name" {
    // `patchResourceBindings` in ffx_fsr3upscaler.cpp refuses any other. The
    // names below are its tables', copied for this check.
    const known = [_][]const u8{
        "r_input_color_jittered",   "r_input_opaque_only",                     "r_input_motion_vectors",
        "r_input_depth",            "r_input_exposure",                        "r_frame_info",
        "r_reactive_mask",          "r_transparency_and_composition_mask",     "r_reconstructed_previous_nearest_depth",
        "r_dilated_motion_vectors", "r_dilated_depth",                         "r_internal_upscaled_color",
        "r_accumulation",           "r_luma_history",                          "r_rcas_input",
        "r_lanczos_lut",            "r_spd_mips",                              "r_dilated_reactive_masks",
        "r_new_locks",              "r_farthest_depth",                        "r_farthest_depth_mip1",
        "r_shading_change",         "r_current_luma",                          "r_previous_luma",
        "r_luma_instability",       "rw_reconstructed_previous_nearest_depth", "rw_dilated_motion_vectors",
        "rw_dilated_depth",         "rw_internal_upscaled_color",              "rw_accumulation",
        "rw_luma_history",          "rw_upscaled_output",                      "rw_dilated_reactive_masks",
        "rw_frame_info",            "rw_spd_global_atomic",                    "rw_new_locks",
        "rw_output_autoreactive",   "rw_shading_change",                       "rw_farthest_depth",
        "rw_farthest_depth_mip1",   "rw_current_luma",                         "rw_luma_instability",
        "rw_spd_mip0",              "rw_spd_mip1",                             "rw_spd_mip2",
        "rw_spd_mip3",              "rw_spd_mip4",                             "rw_spd_mip5",
        "cbFSR3Upscaler",           "cbSPD",                                   "cbRCAS",
        "cbGenerateReactive",
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    for (shaders.all) |shader| {
        const bindings = try shaders.parseBindings(arena_state.allocator(), shader.reflection);
        for ([_][]const shaders.Binding{ bindings.srv_textures, bindings.uav_textures, bindings.constant_buffers }) |list| {
            for (list) |b| {
                for (known) |name| {
                    if (std.mem.eql(u8, name, b.name)) break;
                } else {
                    std.debug.print("{s} is in no table\n", .{b.name});
                    return error.UnknownBinding;
                }
            }
        }
    }
}

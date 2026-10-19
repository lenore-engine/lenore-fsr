const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("fidelityfx", .{});
    const overlay = patchedOverlay(b, upstream);

    // Forwarded with the same arguments the engine passes, so a build holding
    // both resolves one `lenore-gpu` and not two whose types differ.
    const shader_stats = b.option(
        bool,
        "shader-stats",
        "Create pipelines so their compiled statistics can be read back",
    ) orelse false;
    const gpu = b.dependency("lenore_gpu", .{
        .target = target,
        .optimize = optimize,
        .@"shader-stats" = shader_stats,
    });

    const mod = b.addModule("lenore-fsr", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lenore-gpu", .module = gpu.module("lenore-gpu") }},
    });
    addHost(b, mod, upstream, overlay);
    addShaders(b, mod, upstream, overlay);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = testRoot(b, "tests"),
            .imports = &.{.{ .name = "lenore-fsr", .module = mod }},
            .target = target,
            .optimize = optimize,
        }),
    });
    // The C++ compiler's layout of the types `src/ffx.zig` declares by hand,
    // compiled as the host is so that both see the same headers.
    unit_tests.root_module.addCSourceFile(.{
        .file = b.path("tests/ffx_layout.cpp"),
        .flags = hostFlags(b),
    });
    addHostIncludes(unit_tests.root_module, upstream, overlay);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // addTest collects test blocks from the root module of its compilation
    // only. The suite above imports this module rather than being it, so a
    // `test` written beside the code in src/ would never run and would stay
    // green forever. This second binary is that module.
    const module_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
}

// FidelityFX SDK files that are compiled from a rewritten copy. The package
// itself stays as pinned; each copy lands in a generated directory searched
// before the package's own, under the path its includers name, so the copy is
// what every `#include` of it finds.
const Patch = struct {
    // Path inside the package.
    source: []const u8,
    // Path inside the overlay, the one the includers spell.
    overlay: []const u8,
    edits: []const Edit,
};

const Edit = struct { from: []const u8, to: []const u8 };

const patches = [_]Patch{
    // The context is an opaque array of this many 32-bit words that the
    // private state is placed into, and that state holds names as `wchar_t`.
    // `wchar_t` is four bytes on Linux and two on Windows, which is what the
    // upstream size was chosen for: the private context measures 837 848 bytes
    // here against the 524 288 reserved. Twice the reservation fits it.
    .{
        .source = "sdk/include/FidelityFX/host/ffx_types.h",
        .overlay = "FidelityFX/host/ffx_types.h",
        .edits = &.{.{
            .from = "#define FFX_SDK_DEFAULT_CONTEXT_SIZE (1024 * 128)",
            .to = "#define FFX_SDK_DEFAULT_CONTEXT_SIZE (1024 * 256)",
        }},
    },
    // Both shader patches undo the same thing. Upstream compiles with DXC's
    // `-Wno-for-redefinition`, under which a `for` variable stays visible after
    // its loop and a second loop may declare it again. Slang scopes it to the
    // loop and reports the second declaration, so the first loop's variable is
    // renamed. Nothing after either loop reads the old name: had anything
    // relied on the leaked variable, the rename would leave it undeclared and
    // the build would fail.
    .{
        .source = "sdk/include/FidelityFX/gpu/fsr3upscaler/ffx_fsr3upscaler_upsample.h",
        .overlay = "fsr3upscaler/ffx_fsr3upscaler_upsample.h",
        .edits = &.{
            .{
                .from = "for (FfxInt32 row = 0; row < 3; row++) {",
                .to = "for (FfxInt32 iRow = 0; iRow < 3; iRow++) {",
            },
            .{
                .from = "iSampleColRow = FfxInt32x2(bFlipCol ? (3 - col) : col, bFlipRow ? (3 - row) : row);",
                .to = "iSampleColRow = FfxInt32x2(bFlipCol ? (3 - col) : col, bFlipRow ? (3 - iRow) : iRow);",
            },
        },
    },
    .{
        .source = "sdk/include/FidelityFX/gpu/fsr3upscaler/ffx_fsr3upscaler_prepare_reactivity.h",
        .overlay = "fsr3upscaler/ffx_fsr3upscaler_prepare_reactivity.h",
        .edits = &.{.{
            .from =
            \\    for (FfxInt32 iSampleIndex = 0; iSampleIndex < iSampleCount; ++iSampleIndex) {
            \\        const FfxInt32x2 iPxSamplePos = ClampLoad(iPxPos, iSampleOffsets[iSampleIndex], FfxInt32x2(RenderSize()));
            \\        fSamples[iSampleIndex]        = LoadCurrentLuma(iPxSamplePos) * Exposure();
            \\
            \\        fLumaMin = ffxMin(fLumaMin, fSamples[iSampleIndex]);
            \\        fLumaMax = ffxMax(fLumaMax, fSamples[iSampleIndex]);
            ,
            .to =
            \\    for (FfxInt32 iLoadIndex = 0; iLoadIndex < iSampleCount; ++iLoadIndex) {
            \\        const FfxInt32x2 iPxSamplePos = ClampLoad(iPxPos, iSampleOffsets[iLoadIndex], FfxInt32x2(RenderSize()));
            \\        fSamples[iLoadIndex]        = LoadCurrentLuma(iPxSamplePos) * Exposure();
            \\
            \\        fLumaMin = ffxMin(fLumaMin, fSamples[iLoadIndex]);
            \\        fLumaMax = ffxMax(fLumaMax, fSamples[iLoadIndex]);
            ,
        }},
    },
    // The 16-bit variants. `FFX_TO_FLOAT16(1.0)` is `asfloat16` of a float
    // literal: DXC reads the literal as a half and the call as the identity,
    // Slang finds two overloads and refuses. What is meant is a half one.
    .{
        .source = "sdk/include/FidelityFX/gpu/ffx_core_gpu_common_half.h",
        .overlay = "ffx_core_gpu_common_half.h",
        .edits = &.{
            .{
                .from = "FFX_TO_UINT16(FFX_TO_FLOAT16(1.0))",
                .to = "FFX_TO_UINT16(FfxFloat16(1.0))",
            },
            .{
                .from = "FfxUInt16x2(FFX_TO_FLOAT16(1.0), FFX_TO_FLOAT16(1.0))",
                .to = "FfxUInt16x2(FfxFloat16(1.0), FfxFloat16(1.0))",
            },
            .{
                .from = "FfxUInt16x3(FFX_TO_FLOAT16(1.0), FFX_TO_FLOAT16(1.0), FFX_TO_FLOAT16(1.0))",
                .to = "FfxUInt16x3(FfxFloat16(1.0), FfxFloat16(1.0), FfxFloat16(1.0))",
            },
            .{
                .from = "FfxUInt16x4(FFX_TO_FLOAT16(1.0), FFX_TO_FLOAT16(1.0), FFX_TO_FLOAT16(1.0), FFX_TO_FLOAT16(1.0))",
                .to = "FfxUInt16x4(FfxFloat16(1.0), FfxFloat16(1.0), FfxFloat16(1.0), FfxFloat16(1.0))",
            },
        },
    },
    // Unchanged. The header above is included as `"ffx_core_gpu_common_half.h"`
    // by this one, which sits in the same directory upstream, and a quoted
    // include looks beside its includer before the search path. A copy here
    // is what makes that look find the rewritten file. Everything that
    // includes this one does so from another directory, through the search
    // path, so it finds the copy first.
    .{
        .source = "sdk/include/FidelityFX/gpu/ffx_core.h",
        .overlay = "ffx_core.h",
        .edits = &.{},
    },
};

fn patchedOverlay(b: *std.Build, upstream: *std.Build.Dependency) std.Build.LazyPath {
    const replace = b.addExecutable(.{
        .name = "replace",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/replace.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });

    const overlay = b.addWriteFiles();
    for (patches) |patch| {
        const run = b.addRunArtifact(replace);
        run.addFileArg(upstream.path(patch.source));
        const patched = run.addOutputFileArg(std.fs.path.basename(patch.overlay));
        for (patch.edits) |edit| run.addArgs(&.{ edit.from, edit.to });
        _ = overlay.addCopyFile(patched, patch.overlay);
    }
    return overlay.getDirectory();
}

// The upscaler's host half: the component that plans each frame's passes and
// the shared helpers it calls. The breadcrumbs list in the same directory
// belongs to another effect and is not compiled.
fn addHost(
    b: *std.Build,
    mod: *std.Build.Module,
    upstream: *std.Build.Dependency,
    overlay: std.Build.LazyPath,
) void {
    mod.addCSourceFiles(.{
        .root = upstream.path("sdk/src"),
        .files = &.{
            "components/fsr3upscaler/ffx_fsr3upscaler.cpp",
            "shared/ffx_assert.cpp",
            "shared/ffx_message.cpp",
            "shared/ffx_object_management.cpp",
        },
        .flags = hostFlags(b),
    });
    addHostIncludes(mod, upstream, overlay);
    mod.addIncludePath(upstream.path("sdk/src/shared"));
    mod.link_libcpp = true;
}

// No exceptions and no RTTI: nothing upstream throws, and the component is
// reached through a C surface that could not carry either.
//
// `-fshort-wchar` would match the Windows size the context was laid out for,
// and is wrong: the objects then call musl's `wcscmp`, which reads four-byte
// units. The context size is patched instead.
//
// The forced include is named by its path, not found on the include path: the
// compiler's cache resolves a bare name against the working directory and fails
// before the compiler runs.
fn hostFlags(b: *std.Build) []const []const u8 {
    return b.allocator.dupe([]const u8, &.{
        "-std=c++17",
        "-fno-exceptions",
        "-fno-rtti",
        "-include",
        b.root.joinString(b.allocator, "src/compat/ffx_compat.h") catch @panic("OOM"),
    }) catch @panic("OOM");
}

// The overlay is searched first, so the patched `ffx_types.h` is the one every
// `<FidelityFX/host/ffx_types.h>` resolves to.
fn addHostIncludes(
    mod: *std.Build.Module,
    upstream: *std.Build.Dependency,
    overlay: std.Build.LazyPath,
) void {
    mod.addIncludePath(overlay);
    mod.addIncludePath(upstream.path("sdk/include"));
}

// The ten compute passes, by the stem of their upstream file
// (`ffx_fsr3upscaler_<stem>_pass.hlsl`).
const passes = [_][]const u8{
    "prepare_inputs",
    "luma_pyramid",
    "shading_change_pyramid",
    "shading_change",
    "prepare_reactivity",
    "luma_instability",
    "accumulate",
    "rcas",
    "debug_view",
    "autogen_reactive",
};

// Upstream compiles every pass for each combination of six options, times wave
// size and 16-bit arithmetic. The host component asks for one combination per
// pass, derived from the context's flags and the device capabilities the
// backend reports (`getPipelinePermutationFlags` in `ffx_fsr3upscaler.cpp`).
// The engine's inputs fix all but sharpening, and the backend fixes the rest
// by what it reports, so one variant per pass is built, plus `accumulate` with
// sharpening, which the component selects per dispatch; and `half_passes`
// again in 16-bit arithmetic, which the backend offers by the device and the
// caller's choice.
//
// Fixed by the engine's inputs: colour is HDR, motion vectors are at render
// resolution and carry no jitter, depth is not inverted.
//
// Fixed by the backend: no forced wave64 (shader model 6.2). It reports the device's 32-64 lane range, which is what makes the
// component choose the lookup-table Lanczos for reprojection.
const permutation_defines = [_][]const u8{
    "-DFFX_FSR3UPSCALER_OPTION_REPROJECT_USE_LANCZOS_TYPE=1",
    "-DFFX_FSR3UPSCALER_OPTION_HDR_COLOR_INPUT=1",
    "-DFFX_FSR3UPSCALER_OPTION_LOW_RESOLUTION_MOTION_VECTORS=1",
    "-DFFX_FSR3UPSCALER_OPTION_JITTERED_MOTION_VECTORS=0",
    "-DFFX_FSR3UPSCALER_OPTION_INVERTED_DEPTH=0",
};

// Upstream's base arguments (`CMakeCompileFSR3UpscalerShaders.txt`, and the
// shader-model and 16-bit ones from `CMakeCompileShaders.txt` for the wave32,
// 32-bit variant).
const base_defines = [_][]const u8{
    "-DFFX_GPU=1",
    "-DFFX_HLSL=1",
    "-DFFX_HLSL_SM=62",
    "-DFFX_FSR3UPSCALER_OPTION_UPSAMPLE_SAMPLERS_USE_DATA_HALF=0",
    "-DFFX_FSR3UPSCALER_OPTION_ACCUMULATE_SAMPLERS_USE_DATA_HALF=0",
    "-DFFX_FSR3UPSCALER_OPTION_REPROJECT_SAMPLERS_USE_DATA_HALF=1",
    "-DFFX_FSR3UPSCALER_OPTION_POSTPROCESSLOCKSTATUS_SAMPLERS_USE_DATA_HALF=0",
    "-DFFX_FSR3UPSCALER_OPTION_UPSAMPLE_USE_LANCZOS_TYPE=2",
};

// The passes are the HLSL ones: Slang reads HLSL, and the GLSL versions use
// separate sampler objects and `texelFetch` forms it rejects.
//
// HLSL registers are per class, so `t0`, `u0`, `b0` and `s0` would all become
// Vulkan binding 0 in set 0. Each class is shifted into its own range of
// sixteen; the highest registers any pass declares in this release are `t8`,
// `u8`, `b1` and `s1`. The bindings are read back from the reflection, not
// assumed.
//
// Quad subgroup operations are named in the profile because the two pyramid
// passes use them; the backend has to check the device supports them.
//
// The disabled warnings are upstream's and say nothing about this build: macros
// redefined between its own headers, preprocessor tests of Xbox-only names,
// implicit conversions, and unreachable code in SPD.
fn addShaders(
    b: *std.Build,
    mod: *std.Build.Module,
    upstream: *std.Build.Dependency,
    overlay: std.Build.LazyPath,
) void {
    for (passes) |pass| {
        addPass(b, mod, upstream, overlay, pass, false, false);
        if (std.mem.eql(u8, pass, "accumulate")) addPass(b, mod, upstream, overlay, pass, true, false);
    }
    for (half_passes) |pass| {
        addPass(b, mod, upstream, overlay, pass, false, true);
        if (std.mem.eql(u8, pass, "accumulate")) addPass(b, mod, upstream, overlay, pass, true, true);
    }
}

// The passes upstream builds in 16-bit arithmetic too, which are the only ones
// its selector loads that way (`ffx_fsr3upscaler_shaderblobs.cpp`); the others'
// 16-bit sources are not meant to run. RCAS has one upstream, but the host asks
// for it only on Xbox.
const half_passes = [_][]const u8{
    "shading_change",
    "prepare_reactivity",
    "accumulate",
    "autogen_reactive",
};

fn addPass(
    b: *std.Build,
    mod: *std.Build.Module,
    upstream: *std.Build.Dependency,
    overlay: std.Build.LazyPath,
    pass: []const u8,
    sharpen: bool,
    half: bool,
) void {
    const name = b.fmt("fsr3upscaler_{s}{s}{s}", .{
        pass,
        if (sharpen) "_sharpen" else "",
        if (half) "_fp16" else "",
    });

    const command = b.addSystemCommand(&.{
        "slangc",
        "-lang",
        "hlsl",
        "-stage",
        "compute",
        "-entry",
        "CS",
        "-target",
        "spirv",
        "-profile",
        "spirv_1_6+spvGroupNonUniformQuad",
        "-fvk-use-entrypoint-name",
        "-fvk-t-shift",
        "0",
        "0",
        "-fvk-u-shift",
        "16",
        "0",
        "-fvk-b-shift",
        "32",
        "0",
        "-fvk-s-shift",
        "48",
        "0",
        "-warnings-disable",
        "15205,15400,30081,41000",
    });
    command.addArgs(&base_defines);
    command.addArgs(&permutation_defines);
    command.addArg(if (sharpen) "-DFFX_FSR3UPSCALER_OPTION_APPLY_SHARPENING=1" else "-DFFX_FSR3UPSCALER_OPTION_APPLY_SHARPENING=0");
    command.addArg(if (half) "-DFFX_HALF=1" else "-DFFX_HALF=0");
    // The overlay first, so a pass including a patched header gets the copy.
    command.addPrefixedDirectoryArg("-I", overlay);
    command.addPrefixedDirectoryArg("-I", upstream.path("sdk/include/FidelityFX/gpu"));
    command.addPrefixedDirectoryArg("-I", upstream.path("sdk/include/FidelityFX/gpu/fsr3upscaler"));
    command.addFileArg(upstream.path(b.fmt("sdk/src/backends/dx12/shaders/fsr3upscaler/ffx_fsr3upscaler_{s}_pass.hlsl", .{pass})));
    command.addArg("-o");
    const spirv = command.addOutputFileArg(b.fmt("{s}.spv", .{name}));
    command.addArg("-reflection-json");
    const reflection = command.addOutputFileArg(b.fmt("{s}.json", .{name}));

    mod.addAnonymousImport(name, .{ .root_source_file = spirv });
    mod.addAnonymousImport(b.fmt("{s}_reflection", .{name}), .{ .root_source_file = reflection });
}

fn zigFilesIn(b: *std.Build, dir_path: []const u8) [][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    // The listing is configuration, and the build system reuses a configuration
    // while the inputs it recorded are unchanged. Declaring the directory as one
    // makes a file added or removed a cache miss rather than a stale list. A
    // directory that does not exist is recorded through its parent, whose
    // entries are what say so (std.Build.dependOnDirectoryContents).
    const io = b.graph.io;
    var dir = b.root.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            b.dependOnDirectoryContents(b.path(std.fs.path.dirname(dir_path) orelse "."));
            return names.items;
        },
        else => std.debug.panic("cannot open {s}/: {t}", .{ dir_path, err }),
    };
    defer dir.close(io);
    b.dependOnDirectoryContents(b.path(dir_path));

    var iterator = dir.iterate();
    while (iterator.next(io) catch @panic("cannot list the directory")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b_: []const u8) bool {
            return std.mem.order(u8, a, b_) == .lt;
        }
    }.lessThan);
    return names.items;
}

// Generates the test root by listing the directory, so a new test file needs no
// registration.
//
// This cannot be done at comptime: `@import` takes a string literal and there is
// no filesystem at comptime. Zig analyses lazily, so a test file nobody imports
// is silently not run.
fn testRoot(b: *std.Build, dir_path: []const u8) std.Build.LazyPath {
    var source: std.ArrayList(u8) = .empty;
    source.appendSlice(b.allocator, "// Generated by build.zig from the test directory. Do not edit.\ntest {\n") catch @panic("OOM");
    for (zigFilesIn(b, dir_path)) |name|
        source.print(b.allocator, "    _ = @import(\"{s}/{s}\");\n", .{ dir_path, name }) catch @panic("OOM");
    source.appendSlice(b.allocator, "}\n") catch @panic("OOM");

    const generated = b.addWriteFiles();
    _ = generated.addCopyDirectory(b.path(dir_path), dir_path, .{});
    return generated.add("test_root.zig", source.items);
}

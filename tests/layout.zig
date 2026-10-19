const std = @import("std");
const fsr = @import("lenore-fsr");

const ffx = fsr.ffx;
const testing = std.testing;

// The hand-declared FidelityFX types against the C++ compiler's layout of the
// real ones (`ffx_layout.cpp`, built into this test). Nothing else would catch
// a wrong declaration: the linker resolves a name and knows nothing of the
// types on either side of it.

const LayoutEntry = extern struct {
    name: [*:0]const u8,
    value: usize,
};

extern fn lenore_ffx_layout(count: *usize) [*]const LayoutEntry;

fn cValue(name: []const u8) ?usize {
    var count: usize = 0;
    const entries = lenore_ffx_layout(&count);
    for (entries[0..count]) |entry| {
        if (std.mem.eql(u8, std.mem.span(entry.name), name)) return entry.value;
    }
    return null;
}

const Expected = struct { []const u8, usize };

fn size(comptime name: []const u8, comptime T: type) Expected {
    return .{ name, @sizeOf(T) };
}

fn offset(comptime name: []const u8, comptime T: type, comptime field: []const u8) Expected {
    return .{ name, @offsetOf(T, field) };
}

const expected = [_]Expected{
    size("wchar_t", ffx.WChar),
    size("bool", bool),

    size("FfxEffectBindlessConfig", ffx.EffectBindlessConfig),

    size("FfxDeviceCapabilities", ffx.DeviceCapabilities),
    offset("FfxDeviceCapabilities.waveLaneCountMin", ffx.DeviceCapabilities, "wave_lane_count_min"),
    offset("FfxDeviceCapabilities.waveLaneCountMax", ffx.DeviceCapabilities, "wave_lane_count_max"),
    offset("FfxDeviceCapabilities.fp16Supported", ffx.DeviceCapabilities, "fp16_supported"),
    offset("FfxDeviceCapabilities.shaderStorageBufferArrayNonUniformIndexing", ffx.DeviceCapabilities, "shader_storage_buffer_array_non_uniform_indexing"),

    size("FfxResourceDescription", ffx.ResourceDescription),
    offset("FfxResourceDescription.format", ffx.ResourceDescription, "format"),
    offset("FfxResourceDescription.width", ffx.ResourceDescription, "width"),
    offset("FfxResourceDescription.height", ffx.ResourceDescription, "height"),
    offset("FfxResourceDescription.depth", ffx.ResourceDescription, "depth"),
    offset("FfxResourceDescription.mipCount", ffx.ResourceDescription, "mip_count"),
    offset("FfxResourceDescription.flags", ffx.ResourceDescription, "flags"),
    offset("FfxResourceDescription.usage", ffx.ResourceDescription, "usage"),

    size("FfxResource", ffx.Resource),
    offset("FfxResource.description", ffx.Resource, "description"),
    offset("FfxResource.state", ffx.Resource, "state"),
    offset("FfxResource.name", ffx.Resource, "name"),

    size("FfxEffectMemoryUsage", ffx.EffectMemoryUsage),
    size("FfxResourceInternal", ffx.ResourceInternal),

    size("FfxResourceInitData", ffx.ResourceInitData),
    offset("FfxResourceInitData.size", ffx.ResourceInitData, "size"),
    offset("FfxResourceInitData.buffer", ffx.ResourceInitData, "payload"),
    offset("FfxResourceInitData.value", ffx.ResourceInitData, "payload"),

    size("FfxResourceBinding", ffx.ResourceBinding),
    offset("FfxResourceBinding.arrayIndex", ffx.ResourceBinding, "array_index"),
    offset("FfxResourceBinding.resourceIdentifier", ffx.ResourceBinding, "resource_identifier"),
    offset("FfxResourceBinding.name", ffx.ResourceBinding, "name"),

    size("FfxPipelineState", ffx.PipelineState),
    offset("FfxPipelineState.passId", ffx.PipelineState, "pass_id"),
    offset("FfxPipelineState.cmdSignature", ffx.PipelineState, "cmd_signature"),
    offset("FfxPipelineState.pipeline", ffx.PipelineState, "pipeline"),
    offset("FfxPipelineState.uavTextureCount", ffx.PipelineState, "uav_texture_count"),
    offset("FfxPipelineState.srvTextureCount", ffx.PipelineState, "srv_texture_count"),
    offset("FfxPipelineState.srvBufferCount", ffx.PipelineState, "srv_buffer_count"),
    offset("FfxPipelineState.uavBufferCount", ffx.PipelineState, "uav_buffer_count"),
    offset("FfxPipelineState.constCount", ffx.PipelineState, "const_count"),
    offset("FfxPipelineState.uavTextureBindings", ffx.PipelineState, "uav_texture_bindings"),
    offset("FfxPipelineState.srvTextureBindings", ffx.PipelineState, "srv_texture_bindings"),
    offset("FfxPipelineState.srvBufferBindings", ffx.PipelineState, "srv_buffer_bindings"),
    offset("FfxPipelineState.uavBufferBindings", ffx.PipelineState, "uav_buffer_bindings"),
    offset("FfxPipelineState.constantBufferBindings", ffx.PipelineState, "constant_buffer_bindings"),
    offset("FfxPipelineState.name", ffx.PipelineState, "name"),

    size("FfxCreateResourceDescription", ffx.CreateResourceDescription),
    offset("FfxCreateResourceDescription.resourceDescription", ffx.CreateResourceDescription, "resource_description"),
    offset("FfxCreateResourceDescription.initialState", ffx.CreateResourceDescription, "initial_state"),
    offset("FfxCreateResourceDescription.name", ffx.CreateResourceDescription, "name"),
    offset("FfxCreateResourceDescription.id", ffx.CreateResourceDescription, "id"),
    offset("FfxCreateResourceDescription.initData", ffx.CreateResourceDescription, "init_data"),

    size("FfxSamplerDescription", ffx.SamplerDescription),
    size("FfxRootConstantDescription", ffx.RootConstantDescription),

    size("FfxPipelineDescription", ffx.PipelineDescription),
    offset("FfxPipelineDescription.samplers", ffx.PipelineDescription, "samplers"),
    offset("FfxPipelineDescription.samplerCount", ffx.PipelineDescription, "sampler_count"),
    offset("FfxPipelineDescription.rootConstants", ffx.PipelineDescription, "root_constants"),
    offset("FfxPipelineDescription.rootConstantBufferCount", ffx.PipelineDescription, "root_constant_buffer_count"),
    offset("FfxPipelineDescription.name", ffx.PipelineDescription, "name"),
    offset("FfxPipelineDescription.stage", ffx.PipelineDescription, "stage"),
    offset("FfxPipelineDescription.indirectWorkload", ffx.PipelineDescription, "indirect_workload"),
    offset("FfxPipelineDescription.backbufferFormat", ffx.PipelineDescription, "backbuffer_format"),

    size("FfxBarrierDescription", ffx.BarrierDescription),
    offset("FfxBarrierDescription.newState", ffx.BarrierDescription, "new_state"),

    size("FfxConstantBuffer", ffx.ConstantBuffer),
    offset("FfxConstantBuffer.data", ffx.ConstantBuffer, "data"),

    size("FfxTextureSRV", ffx.TextureSrv),
    size("FfxBufferSRV", ffx.BufferSrv),
    size("FfxTextureUAV", ffx.TextureUav),
    offset("FfxTextureUAV.resource", ffx.TextureUav, "resource"),
    size("FfxBufferUAV", ffx.BufferUav),

    size("FfxClearFloatJobDescription", ffx.ClearFloatJobDescription),
    offset("FfxClearFloatJobDescription.target", ffx.ClearFloatJobDescription, "target"),

    size("FfxComputeJobDescription", ffx.ComputeJobDescription),
    offset("FfxComputeJobDescription.dimensions", ffx.ComputeJobDescription, "dimensions"),
    offset("FfxComputeJobDescription.cmdArgument", ffx.ComputeJobDescription, "cmd_argument"),
    offset("FfxComputeJobDescription.srvTextures", ffx.ComputeJobDescription, "srv_textures"),
    offset("FfxComputeJobDescription.srvBuffers", ffx.ComputeJobDescription, "srv_buffers"),
    offset("FfxComputeJobDescription.uavTextures", ffx.ComputeJobDescription, "uav_textures"),
    offset("FfxComputeJobDescription.uavBuffers", ffx.ComputeJobDescription, "uav_buffers"),
    offset("FfxComputeJobDescription.cbs", ffx.ComputeJobDescription, "cbs"),

    size("FfxCopyJobDescription", ffx.CopyJobDescription),
    offset("FfxCopyJobDescription.dst", ffx.CopyJobDescription, "dst"),
    offset("FfxCopyJobDescription.size", ffx.CopyJobDescription, "size"),

    size("FfxGpuJobDescription", ffx.GpuJobDescription),
    offset("FfxGpuJobDescription.jobLabel", ffx.GpuJobDescription, "job_label"),
    offset("FfxGpuJobDescription.clearJobDescriptor", ffx.GpuJobDescription, "job"),
    offset("FfxGpuJobDescription.copyJobDescriptor", ffx.GpuJobDescription, "job"),
    offset("FfxGpuJobDescription.computeJobDescriptor", ffx.GpuJobDescription, "job"),
    offset("FfxGpuJobDescription.barrierDescriptor", ffx.GpuJobDescription, "job"),
    offset("FfxGpuJobDescription.discardJobDescriptor", ffx.GpuJobDescription, "job"),

    size("FfxInterface", ffx.Interface),
    offset("FfxInterface.fpGetSDKVersion", ffx.Interface, "get_sdk_version"),
    offset("FfxInterface.fpCreateBackendContext", ffx.Interface, "create_backend_context"),
    offset("FfxInterface.fpGetDeviceCapabilities", ffx.Interface, "get_device_capabilities"),
    offset("FfxInterface.fpCreateResource", ffx.Interface, "create_resource"),
    offset("FfxInterface.fpRegisterResource", ffx.Interface, "register_resource"),
    offset("FfxInterface.fpUnregisterResources", ffx.Interface, "unregister_resources"),
    offset("FfxInterface.fpGetResourceDescription", ffx.Interface, "get_resource_description"),
    offset("FfxInterface.fpDestroyResource", ffx.Interface, "destroy_resource"),
    offset("FfxInterface.fpStageConstantBufferDataFunc", ffx.Interface, "stage_constant_buffer_data"),
    offset("FfxInterface.fpCreatePipeline", ffx.Interface, "create_pipeline"),
    offset("FfxInterface.fpDestroyPipeline", ffx.Interface, "destroy_pipeline"),
    offset("FfxInterface.fpScheduleGpuJob", ffx.Interface, "schedule_gpu_job"),
    offset("FfxInterface.fpExecuteGpuJobs", ffx.Interface, "execute_gpu_jobs"),
    offset("FfxInterface.fpRegisterConstantBufferAllocator", ffx.Interface, "register_constant_buffer_allocator"),
    offset("FfxInterface.scratchBuffer", ffx.Interface, "scratch_buffer"),
    offset("FfxInterface.scratchBufferSize", ffx.Interface, "scratch_buffer_size"),
    offset("FfxInterface.device", ffx.Interface, "device"),

    size("FfxFsr3UpscalerContext", ffx.Fsr3UpscalerContext),

    size("FfxFsr3UpscalerContextDescription", ffx.Fsr3UpscalerContextDescription),
    offset("FfxFsr3UpscalerContextDescription.maxRenderSize", ffx.Fsr3UpscalerContextDescription, "max_render_size"),
    offset("FfxFsr3UpscalerContextDescription.maxUpscaleSize", ffx.Fsr3UpscalerContextDescription, "max_upscale_size"),
    offset("FfxFsr3UpscalerContextDescription.fpMessage", ffx.Fsr3UpscalerContextDescription, "fp_message"),
    offset("FfxFsr3UpscalerContextDescription.backendInterface", ffx.Fsr3UpscalerContextDescription, "backend_interface"),

    size("FfxFsr3UpscalerDispatchDescription", ffx.Fsr3UpscalerDispatchDescription),
    offset("FfxFsr3UpscalerDispatchDescription.color", ffx.Fsr3UpscalerDispatchDescription, "color"),
    offset("FfxFsr3UpscalerDispatchDescription.depth", ffx.Fsr3UpscalerDispatchDescription, "depth"),
    offset("FfxFsr3UpscalerDispatchDescription.motionVectors", ffx.Fsr3UpscalerDispatchDescription, "motion_vectors"),
    offset("FfxFsr3UpscalerDispatchDescription.exposure", ffx.Fsr3UpscalerDispatchDescription, "exposure"),
    offset("FfxFsr3UpscalerDispatchDescription.reactive", ffx.Fsr3UpscalerDispatchDescription, "reactive"),
    offset("FfxFsr3UpscalerDispatchDescription.transparencyAndComposition", ffx.Fsr3UpscalerDispatchDescription, "transparency_and_composition"),
    offset("FfxFsr3UpscalerDispatchDescription.dilatedDepth", ffx.Fsr3UpscalerDispatchDescription, "dilated_depth"),
    offset("FfxFsr3UpscalerDispatchDescription.dilatedMotionVectors", ffx.Fsr3UpscalerDispatchDescription, "dilated_motion_vectors"),
    offset("FfxFsr3UpscalerDispatchDescription.reconstructedPrevNearestDepth", ffx.Fsr3UpscalerDispatchDescription, "reconstructed_prev_nearest_depth"),
    offset("FfxFsr3UpscalerDispatchDescription.output", ffx.Fsr3UpscalerDispatchDescription, "output"),
    offset("FfxFsr3UpscalerDispatchDescription.jitterOffset", ffx.Fsr3UpscalerDispatchDescription, "jitter_offset"),
    offset("FfxFsr3UpscalerDispatchDescription.motionVectorScale", ffx.Fsr3UpscalerDispatchDescription, "motion_vector_scale"),
    offset("FfxFsr3UpscalerDispatchDescription.renderSize", ffx.Fsr3UpscalerDispatchDescription, "render_size"),
    offset("FfxFsr3UpscalerDispatchDescription.upscaleSize", ffx.Fsr3UpscalerDispatchDescription, "upscale_size"),
    offset("FfxFsr3UpscalerDispatchDescription.enableSharpening", ffx.Fsr3UpscalerDispatchDescription, "enable_sharpening"),
    offset("FfxFsr3UpscalerDispatchDescription.sharpness", ffx.Fsr3UpscalerDispatchDescription, "sharpness"),
    offset("FfxFsr3UpscalerDispatchDescription.frameTimeDelta", ffx.Fsr3UpscalerDispatchDescription, "frame_time_delta"),
    offset("FfxFsr3UpscalerDispatchDescription.preExposure", ffx.Fsr3UpscalerDispatchDescription, "pre_exposure"),
    offset("FfxFsr3UpscalerDispatchDescription.reset", ffx.Fsr3UpscalerDispatchDescription, "reset"),
    offset("FfxFsr3UpscalerDispatchDescription.cameraNear", ffx.Fsr3UpscalerDispatchDescription, "camera_near"),
    offset("FfxFsr3UpscalerDispatchDescription.cameraFar", ffx.Fsr3UpscalerDispatchDescription, "camera_far"),
    offset("FfxFsr3UpscalerDispatchDescription.cameraFovAngleVertical", ffx.Fsr3UpscalerDispatchDescription, "camera_fov_angle_vertical"),
    offset("FfxFsr3UpscalerDispatchDescription.viewSpaceToMetersFactor", ffx.Fsr3UpscalerDispatchDescription, "view_space_to_meters_factor"),
    offset("FfxFsr3UpscalerDispatchDescription.flags", ffx.Fsr3UpscalerDispatchDescription, "flags"),
};

test "every hand-declared size and offset matches the C++ layout" {
    for (expected) |entry| {
        const name, const zig_value = entry;
        const c_value = cValue(name) orelse {
            std.debug.print("{s}: not measured by ffx_layout.cpp\n", .{name});
            return error.MissingEntry;
        };
        if (c_value != zig_value) {
            std.debug.print("{s}: C++ {d}, Zig {d}\n", .{ name, c_value, zig_value });
            return error.LayoutMismatch;
        }
    }
}

test "every C++ measurement is checked here" {
    // The other direction: an entry added to the C++ side and forgotten here
    // would otherwise be a measurement nothing reads.
    var count: usize = 0;
    const entries = lenore_ffx_layout(&count);
    try testing.expectEqual(expected.len, count);
    for (entries[0..count]) |entry| {
        const name = std.mem.span(entry.name);
        for (expected) |candidate| {
            if (std.mem.eql(u8, candidate[0], name)) break;
        } else {
            std.debug.print("{s}: measured but not checked\n", .{name});
            return error.UncheckedEntry;
        }
    }
}

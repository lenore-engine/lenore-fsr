// The C++ compiler's own account of the FidelityFX layouts `src/ffx.zig`
// declares by hand. `layout.zig` looks every entry up by name and holds the Zig
// declaration against it.

#include <cstddef>
#include <cwchar>

#include <FidelityFX/host/ffx_fsr3upscaler.h>
#include <FidelityFX/host/ffx_interface.h>

struct LayoutEntry {
    const char* name;
    size_t value;
};

#define SIZE(T) {#T, sizeof(T)}
#define OFFSET(T, field) {#T "." #field, offsetof(T, field)}

static const LayoutEntry layout[] = {
    SIZE(wchar_t),
    SIZE(bool),

    SIZE(FfxEffectBindlessConfig),

    SIZE(FfxDeviceCapabilities),
    OFFSET(FfxDeviceCapabilities, waveLaneCountMin),
    OFFSET(FfxDeviceCapabilities, waveLaneCountMax),
    OFFSET(FfxDeviceCapabilities, fp16Supported),
    OFFSET(FfxDeviceCapabilities, shaderStorageBufferArrayNonUniformIndexing),

    SIZE(FfxResourceDescription),
    OFFSET(FfxResourceDescription, format),
    OFFSET(FfxResourceDescription, width),
    OFFSET(FfxResourceDescription, height),
    OFFSET(FfxResourceDescription, depth),
    OFFSET(FfxResourceDescription, mipCount),
    OFFSET(FfxResourceDescription, flags),
    OFFSET(FfxResourceDescription, usage),

    SIZE(FfxResource),
    OFFSET(FfxResource, description),
    OFFSET(FfxResource, state),
    OFFSET(FfxResource, name),

    SIZE(FfxEffectMemoryUsage),
    SIZE(FfxResourceInternal),

    SIZE(FfxResourceInitData),
    OFFSET(FfxResourceInitData, size),
    OFFSET(FfxResourceInitData, buffer),
    OFFSET(FfxResourceInitData, value),

    SIZE(FfxResourceBinding),
    OFFSET(FfxResourceBinding, arrayIndex),
    OFFSET(FfxResourceBinding, resourceIdentifier),
    OFFSET(FfxResourceBinding, name),

    SIZE(FfxPipelineState),
    OFFSET(FfxPipelineState, passId),
    OFFSET(FfxPipelineState, cmdSignature),
    OFFSET(FfxPipelineState, pipeline),
    OFFSET(FfxPipelineState, uavTextureCount),
    OFFSET(FfxPipelineState, srvTextureCount),
    OFFSET(FfxPipelineState, srvBufferCount),
    OFFSET(FfxPipelineState, uavBufferCount),
    OFFSET(FfxPipelineState, constCount),
    OFFSET(FfxPipelineState, uavTextureBindings),
    OFFSET(FfxPipelineState, srvTextureBindings),
    OFFSET(FfxPipelineState, srvBufferBindings),
    OFFSET(FfxPipelineState, uavBufferBindings),
    OFFSET(FfxPipelineState, constantBufferBindings),
    OFFSET(FfxPipelineState, name),

    SIZE(FfxCreateResourceDescription),
    OFFSET(FfxCreateResourceDescription, resourceDescription),
    OFFSET(FfxCreateResourceDescription, initialState),
    OFFSET(FfxCreateResourceDescription, name),
    OFFSET(FfxCreateResourceDescription, id),
    OFFSET(FfxCreateResourceDescription, initData),

    SIZE(FfxSamplerDescription),
    SIZE(FfxRootConstantDescription),

    SIZE(FfxPipelineDescription),
    OFFSET(FfxPipelineDescription, samplers),
    OFFSET(FfxPipelineDescription, samplerCount),
    OFFSET(FfxPipelineDescription, rootConstants),
    OFFSET(FfxPipelineDescription, rootConstantBufferCount),
    OFFSET(FfxPipelineDescription, name),
    OFFSET(FfxPipelineDescription, stage),
    OFFSET(FfxPipelineDescription, indirectWorkload),
    OFFSET(FfxPipelineDescription, backbufferFormat),

    SIZE(FfxBarrierDescription),
    OFFSET(FfxBarrierDescription, newState),

    SIZE(FfxConstantBuffer),
    OFFSET(FfxConstantBuffer, data),

    SIZE(FfxTextureSRV),
    SIZE(FfxBufferSRV),
    SIZE(FfxTextureUAV),
    OFFSET(FfxTextureUAV, resource),
    SIZE(FfxBufferUAV),

    SIZE(FfxClearFloatJobDescription),
    OFFSET(FfxClearFloatJobDescription, target),

    SIZE(FfxComputeJobDescription),
    OFFSET(FfxComputeJobDescription, dimensions),
    OFFSET(FfxComputeJobDescription, cmdArgument),
    OFFSET(FfxComputeJobDescription, srvTextures),
    OFFSET(FfxComputeJobDescription, srvBuffers),
    OFFSET(FfxComputeJobDescription, uavTextures),
    OFFSET(FfxComputeJobDescription, uavBuffers),
    OFFSET(FfxComputeJobDescription, cbs),

    SIZE(FfxCopyJobDescription),
    OFFSET(FfxCopyJobDescription, dst),
    OFFSET(FfxCopyJobDescription, size),

    SIZE(FfxGpuJobDescription),
    OFFSET(FfxGpuJobDescription, jobLabel),
    OFFSET(FfxGpuJobDescription, clearJobDescriptor),
    OFFSET(FfxGpuJobDescription, copyJobDescriptor),
    OFFSET(FfxGpuJobDescription, computeJobDescriptor),
    OFFSET(FfxGpuJobDescription, barrierDescriptor),
    OFFSET(FfxGpuJobDescription, discardJobDescriptor),

    SIZE(FfxInterface),
    OFFSET(FfxInterface, fpGetSDKVersion),
    OFFSET(FfxInterface, fpCreateBackendContext),
    OFFSET(FfxInterface, fpGetDeviceCapabilities),
    OFFSET(FfxInterface, fpCreateResource),
    OFFSET(FfxInterface, fpRegisterResource),
    OFFSET(FfxInterface, fpUnregisterResources),
    OFFSET(FfxInterface, fpGetResourceDescription),
    OFFSET(FfxInterface, fpDestroyResource),
    OFFSET(FfxInterface, fpStageConstantBufferDataFunc),
    OFFSET(FfxInterface, fpCreatePipeline),
    OFFSET(FfxInterface, fpDestroyPipeline),
    OFFSET(FfxInterface, fpScheduleGpuJob),
    OFFSET(FfxInterface, fpExecuteGpuJobs),
    OFFSET(FfxInterface, fpRegisterConstantBufferAllocator),
    OFFSET(FfxInterface, scratchBuffer),
    OFFSET(FfxInterface, scratchBufferSize),
    OFFSET(FfxInterface, device),

    SIZE(FfxFsr3UpscalerContext),

    SIZE(FfxFsr3UpscalerContextDescription),
    OFFSET(FfxFsr3UpscalerContextDescription, maxRenderSize),
    OFFSET(FfxFsr3UpscalerContextDescription, maxUpscaleSize),
    OFFSET(FfxFsr3UpscalerContextDescription, fpMessage),
    OFFSET(FfxFsr3UpscalerContextDescription, backendInterface),

    SIZE(FfxFsr3UpscalerDispatchDescription),
    OFFSET(FfxFsr3UpscalerDispatchDescription, color),
    OFFSET(FfxFsr3UpscalerDispatchDescription, depth),
    OFFSET(FfxFsr3UpscalerDispatchDescription, motionVectors),
    OFFSET(FfxFsr3UpscalerDispatchDescription, exposure),
    OFFSET(FfxFsr3UpscalerDispatchDescription, reactive),
    OFFSET(FfxFsr3UpscalerDispatchDescription, transparencyAndComposition),
    OFFSET(FfxFsr3UpscalerDispatchDescription, dilatedDepth),
    OFFSET(FfxFsr3UpscalerDispatchDescription, dilatedMotionVectors),
    OFFSET(FfxFsr3UpscalerDispatchDescription, reconstructedPrevNearestDepth),
    OFFSET(FfxFsr3UpscalerDispatchDescription, output),
    OFFSET(FfxFsr3UpscalerDispatchDescription, jitterOffset),
    OFFSET(FfxFsr3UpscalerDispatchDescription, motionVectorScale),
    OFFSET(FfxFsr3UpscalerDispatchDescription, renderSize),
    OFFSET(FfxFsr3UpscalerDispatchDescription, upscaleSize),
    OFFSET(FfxFsr3UpscalerDispatchDescription, enableSharpening),
    OFFSET(FfxFsr3UpscalerDispatchDescription, sharpness),
    OFFSET(FfxFsr3UpscalerDispatchDescription, frameTimeDelta),
    OFFSET(FfxFsr3UpscalerDispatchDescription, preExposure),
    OFFSET(FfxFsr3UpscalerDispatchDescription, reset),
    OFFSET(FfxFsr3UpscalerDispatchDescription, cameraNear),
    OFFSET(FfxFsr3UpscalerDispatchDescription, cameraFar),
    OFFSET(FfxFsr3UpscalerDispatchDescription, cameraFovAngleVertical),
    OFFSET(FfxFsr3UpscalerDispatchDescription, viewSpaceToMetersFactor),
    OFFSET(FfxFsr3UpscalerDispatchDescription, flags),
};

extern "C" const LayoutEntry* lenore_ffx_layout(size_t* count)
{
    *count = sizeof(layout) / sizeof(layout[0]);
    return layout;
}

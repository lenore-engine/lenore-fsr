const std = @import("std");

// The C surface of the FidelityFX SDK that the upscaler and its backend meet
// at: the types `ffx_types.h`, `ffx_interface.h`, `ffx_error.h` and
// `ffx_fsr3upscaler.h` declare, and the entry points of the upscaler.
//
// Declared by hand rather than translated. The headers are C++ (`bool` with no
// include, static member functions inside `FfxResourceInitData`) and do not
// pass `zig translate-c`. Nothing at link time checks that a declaration here
// matches the C one, so every size and every field offset declared here is
// held against the C++ compiler's own answer by `tests/layout.zig`.
//
// Names drop the `Ffx` prefix. Enums are non-exhaustive: their values arrive
// from C, and a switch over one has to say what an unnamed value does rather
// than leave it undefined.

pub const WChar = std.c.wchar_t;
pub const resource_name_size = 64;
pub const Name = [resource_name_size]WChar;

pub const max_num_srvs = 64;
pub const max_num_uavs = 64;
pub const max_num_const_buffers = 3;

pub const ErrorCode = i32;
pub const ok: ErrorCode = 0;
pub const error_invalid_pointer: ErrorCode = @bitCast(@as(u32, 0x80000000));
pub const error_invalid_size: ErrorCode = @bitCast(@as(u32, 0x80000002));
pub const error_out_of_memory: ErrorCode = @bitCast(@as(u32, 0x80000007));
pub const error_invalid_enum: ErrorCode = @bitCast(@as(u32, 0x80000009));
pub const error_invalid_argument: ErrorCode = @bitCast(@as(u32, 0x8000000a));
pub const error_out_of_range: ErrorCode = @bitCast(@as(u32, 0x8000000b));
pub const error_backend_api_error: ErrorCode = @bitCast(@as(u32, 0x8000000d));
pub const error_insufficient_memory: ErrorCode = @bitCast(@as(u32, 0x8000000e));

pub const SurfaceFormat = enum(c_int) {
    unknown = 0,
    r32g32b32a32_typeless = 1,
    r32g32b32a32_uint = 2,
    r32g32b32a32_float = 3,
    r16g16b16a16_float = 4,
    r32g32b32_float = 5,
    r32g32_float = 6,
    r8_uint = 7,
    r32_uint = 8,
    r8g8b8a8_typeless = 9,
    r8g8b8a8_unorm = 10,
    r8g8b8a8_snorm = 11,
    r8g8b8a8_srgb = 12,
    b8g8r8a8_typeless = 13,
    b8g8r8a8_unorm = 14,
    b8g8r8a8_srgb = 15,
    r11g11b10_float = 16,
    r10g10b10a2_unorm = 17,
    r16g16_float = 18,
    r16g16_uint = 19,
    r16g16_sint = 20,
    r16_float = 21,
    r16_uint = 22,
    r16_unorm = 23,
    r16_snorm = 24,
    r8_unorm = 25,
    r8g8_unorm = 26,
    r8g8_uint = 27,
    r32_float = 28,
    r9g9b9e5_sharedexp = 29,
    r16g16b16a16_typeless = 30,
    r32g32_typeless = 31,
    r10g10b10a2_typeless = 32,
    r16g16_typeless = 33,
    r16_typeless = 34,
    r8_typeless = 35,
    r8g8_typeless = 36,
    r32_typeless = 37,
    _,
};

// `FfxResourceUsage`, a set of bits.
pub const ResourceUsage = packed struct(u32) {
    render_target: bool = false,
    uav: bool = false,
    depth_target: bool = false,
    indirect: bool = false,
    array_view: bool = false,
    stencil_target: bool = false,
    _reserved_6: u9 = 0,
    dcc_render_target: bool = false,
    _reserved_16: u16 = 0,
};

// `FfxResourceStates`. Named as single values, including the two combinations
// the header names, because the host passes them as values and never builds
// other combinations.
pub const ResourceState = enum(c_int) {
    common = 1 << 0,
    unordered_access = 1 << 1,
    compute_read = 1 << 2,
    pixel_read = 1 << 3,
    pixel_compute_read = (1 << 3) | (1 << 2),
    copy_src = 1 << 4,
    copy_dest = 1 << 5,
    generic_read = (1 << 4) | (1 << 2),
    indirect_argument = 1 << 6,
    present = 1 << 7,
    render_target = 1 << 8,
    depth_attachment = 1 << 9,
    _,
};

// `FfxResourceFlags`, a set of bits.
pub const ResourceFlags = packed struct(u32) {
    aliasable: bool = false,
    undefined: bool = false,
    _reserved: u30 = 0,
};

pub const FilterType = enum(c_int) {
    minmagmip_point = 0,
    minmagmip_linear = 1,
    minmaglinearmip_point = 2,
    _,
};

pub const AddressMode = enum(c_int) {
    wrap = 0,
    mirror = 1,
    clamp = 2,
    border = 3,
    mirror_once = 4,
    _,
};

pub const ShaderModel = enum(c_int) {
    @"5_1" = 0,
    @"6_0" = 1,
    @"6_1" = 2,
    @"6_2" = 3,
    @"6_3" = 4,
    @"6_4" = 5,
    @"6_5" = 6,
    @"6_6" = 7,
    @"6_7" = 8,
    _,
};

pub const ResourceType = enum(c_int) {
    buffer = 0,
    texture_1d = 1,
    texture_2d = 2,
    texture_cube = 3,
    texture_3d = 4,
    _,
};

pub const HeapType = enum(c_int) {
    default = 0,
    upload = 1,
    readback = 2,
    _,
};

pub const GpuJobType = enum(c_int) {
    clear_float = 0,
    copy = 1,
    compute = 2,
    barrier = 3,
    discard = 4,
    _,
};

pub const BindStage = enum(c_int) {
    pixel = 1 << 0,
    vertex = 1 << 1,
    compute = 1 << 2,
    _,
};

pub const BarrierType = enum(c_int) {
    transition = 0,
    uav = 1,
    _,
};

pub const MessageType = enum(c_int) {
    @"error" = 0,
    warning = 1,
    _,
};

pub const Effect = enum(c_int) {
    fsr3upscaler = 17,
    _,
};

pub const Pass = u32;

pub const Device = ?*anyopaque;
pub const CommandList = ?*anyopaque;
pub const RootSignature = ?*anyopaque;
pub const CommandSignature = ?*anyopaque;
pub const Pipeline = ?*anyopaque;

pub const EffectBindlessConfig = extern struct {
    max_texture_srvs: u32,
    max_buffer_srvs: u32,
    max_texture_uavs: u32,
    max_buffer_uavs: u32,
};

pub const DeviceCapabilities = extern struct {
    maximum_supported_shader_model: ShaderModel,
    wave_lane_count_min: u32,
    wave_lane_count_max: u32,
    fp16_supported: bool,
    raytracing_supported: bool,
    device_coherent_memory_supported: bool,
    dedicated_allocation_supported: bool,
    buffer_marker_supported: bool,
    extended_synchronization_supported: bool,
    shader_storage_buffer_array_non_uniform_indexing: bool,
};

pub const Dimensions2D = extern struct {
    width: u32,
    height: u32,
};

pub const FloatCoords2D = extern struct {
    x: f32,
    y: f32,
};

// In C the three extents are unions with a buffer's size, stride and
// alignment. Every member is a `uint32_t` and the backend creates no buffer
// through a description, so each is named for its texture meaning.
pub const ResourceDescription = extern struct {
    type: ResourceType,
    format: SurfaceFormat,
    width: u32,
    height: u32,
    depth: u32,
    mip_count: u32,
    flags: ResourceFlags,
    usage: ResourceUsage,
};

pub const Resource = extern struct {
    resource: ?*anyopaque,
    description: ResourceDescription,
    state: ResourceState,
    name: Name,
};

pub const EffectMemoryUsage = extern struct {
    total_usage_in_bytes: u64,
    aliasable_usage_in_bytes: u64,
};

pub const ResourceInternal = extern struct {
    internal_index: i32,
};

pub const ResourceInitDataType = enum(c_int) {
    invalid = 0,
    uninitialized = 1,
    buffer = 2,
    value = 3,
    _,
};

pub const ResourceInitData = extern struct {
    type: ResourceInitDataType,
    size: usize,
    payload: extern union {
        buffer: ?*const anyopaque,
        value: u8,
    },
};

pub const ResourceBinding = extern struct {
    slot_index: u32,
    array_index: u32,
    resource_identifier: u32,
    name: Name,
};

pub const PipelineState = extern struct {
    root_signature: RootSignature,
    pass_id: u32,
    cmd_signature: CommandSignature,
    pipeline: Pipeline,
    uav_texture_count: u32,
    srv_texture_count: u32,
    srv_buffer_count: u32,
    uav_buffer_count: u32,
    static_texture_srv_count: u32,
    static_buffer_srv_count: u32,
    static_texture_uav_count: u32,
    static_buffer_uav_count: u32,
    const_count: u32,
    uav_texture_bindings: [max_num_uavs]ResourceBinding,
    srv_texture_bindings: [max_num_srvs]ResourceBinding,
    srv_buffer_bindings: [max_num_srvs]ResourceBinding,
    uav_buffer_bindings: [max_num_uavs]ResourceBinding,
    constant_buffer_bindings: [max_num_const_buffers]ResourceBinding,
    name: Name,
};

pub const CreateResourceDescription = extern struct {
    heap_type: HeapType,
    resource_description: ResourceDescription,
    initial_state: ResourceState,
    name: ?[*:0]const WChar,
    id: u32,
    init_data: ResourceInitData,
};

pub const SamplerDescription = extern struct {
    filter: FilterType,
    address_mode_u: AddressMode,
    address_mode_v: AddressMode,
    address_mode_w: AddressMode,
    stage: BindStage,
};

pub const RootConstantDescription = extern struct {
    // In 32-bit words.
    size: u32,
    stage: BindStage,
};

pub const PipelineDescription = extern struct {
    context_flags: u32,
    samplers: ?[*]const SamplerDescription,
    sampler_count: usize,
    root_constants: ?[*]const RootConstantDescription,
    root_constant_buffer_count: u32,
    name: Name,
    stage: BindStage,
    indirect_workload: u32,
    backbuffer_format: SurfaceFormat,
};

pub const BarrierDescription = extern struct {
    resource: ResourceInternal,
    barrier_type: BarrierType,
    current_state: ResourceState,
    new_state: ResourceState,
    sub_resource_id: u32,
};

pub const ConstantBuffer = extern struct {
    num_32bit_entries: u32,
    data: ?[*]u32,
};

pub const TextureSrv = extern struct {
    resource: ResourceInternal,
};

pub const BufferSrv = extern struct {
    offset: u32,
    size: u32,
    stride: u32,
    resource: ResourceInternal,
};

pub const TextureUav = extern struct {
    mip: u32,
    resource: ResourceInternal,
};

pub const BufferUav = extern struct {
    offset: u32,
    size: u32,
    stride: u32,
    resource: ResourceInternal,
};

pub const ClearFloatJobDescription = extern struct {
    color: [4]f32,
    target: ResourceInternal,
};

pub const ComputeJobDescription = extern struct {
    pipeline: PipelineState,
    dimensions: [3]u32,
    cmd_argument: ResourceInternal,
    cmd_argument_offset: u32,
    srv_textures: [max_num_srvs]TextureSrv,
    srv_buffers: [max_num_srvs]BufferSrv,
    uav_textures: [max_num_uavs]TextureUav,
    uav_buffers: [max_num_uavs]BufferUav,
    cbs: [max_num_const_buffers]ConstantBuffer,
};

pub const CopyJobDescription = extern struct {
    src: ResourceInternal,
    src_offset: u32,
    dst: ResourceInternal,
    dst_offset: u32,
    size: u32,
};

pub const DiscardJobDescription = extern struct {
    target: ResourceInternal,
};

// The C union also holds a raster job, which no effect built here schedules.
// It is smaller than the compute job and needs no stricter alignment, so
// leaving it out changes neither the size nor the offsets, and the layout test
// is what says so.
pub const GpuJobDescription = extern struct {
    job_type: GpuJobType,
    job_label: Name,
    job: extern union {
        clear: ClearFloatJobDescription,
        copy: CopyJobDescription,
        compute: ComputeJobDescription,
        barrier: BarrierDescription,
        discard: DiscardJobDescription,
    },
};

// The callbacks, in the order `FfxInterface` declares them. The ones nothing
// built here calls are opaque pointers: the upscaler reaches for none of them,
// and a null in their place is what it would find.
pub const Interface = extern struct {
    get_sdk_version: ?*const fn (*Interface) callconv(.c) u32,
    get_effect_gpu_memory_usage: ?*const fn (*Interface, u32, *EffectMemoryUsage) callconv(.c) ErrorCode,
    create_backend_context: ?*const fn (*Interface, Effect, ?*EffectBindlessConfig, *u32) callconv(.c) ErrorCode,
    get_device_capabilities: ?*const fn (*Interface, *DeviceCapabilities) callconv(.c) ErrorCode,
    destroy_backend_context: ?*const fn (*Interface, u32) callconv(.c) ErrorCode,
    create_resource: ?*const fn (*Interface, *const CreateResourceDescription, u32, *ResourceInternal) callconv(.c) ErrorCode,
    register_resource: ?*const fn (*Interface, *const Resource, u32, *ResourceInternal) callconv(.c) ErrorCode,
    get_resource: ?*const anyopaque,
    unregister_resources: ?*const fn (*Interface, CommandList, u32) callconv(.c) ErrorCode,
    register_static_resource: ?*const anyopaque,
    get_resource_description: ?*const fn (*Interface, ResourceInternal) callconv(.c) ResourceDescription,
    destroy_resource: ?*const fn (*Interface, ResourceInternal, u32) callconv(.c) ErrorCode,
    map_resource: ?*const anyopaque,
    unmap_resource: ?*const anyopaque,
    stage_constant_buffer_data: ?*const fn (*Interface, ?*anyopaque, u32, *ConstantBuffer) callconv(.c) ErrorCode,
    create_pipeline: ?*const fn (*Interface, Effect, Pass, u32, *const PipelineDescription, u32, *PipelineState) callconv(.c) ErrorCode,
    destroy_pipeline: ?*const fn (*Interface, ?*PipelineState, u32) callconv(.c) ErrorCode,
    schedule_gpu_job: ?*const fn (*Interface, *const GpuJobDescription) callconv(.c) ErrorCode,
    execute_gpu_jobs: ?*const fn (*Interface, CommandList, u32) callconv(.c) ErrorCode,
    breadcrumbs_alloc_block: ?*const anyopaque,
    breadcrumbs_free_block: ?*const anyopaque,
    breadcrumbs_write: ?*const anyopaque,
    breadcrumbs_print_device_info: ?*const anyopaque,
    get_permutation_blob_by_index: ?*const anyopaque,
    swap_chain_configure_frame_generation: ?*const anyopaque,
    register_constant_buffer_allocator: ?*const anyopaque,
    scratch_buffer: ?*anyopaque,
    scratch_buffer_size: usize,
    device: Device,
};

// The upscaler

// `FFX_FSR3UPSCALER_CONTEXT_SIZE` in 32-bit words, with the build's patch to
// `FFX_SDK_DEFAULT_CONTEXT_SIZE` applied.
pub const fsr3upscaler_context_size = 1024 * 256;

pub const Fsr3UpscalerContext = extern struct {
    data: [fsr3upscaler_context_size]u32,
};

pub const Fsr3UpscalerPass = enum(u32) {
    prepare_inputs = 0,
    luma_pyramid = 1,
    shading_change_pyramid = 2,
    shading_change = 3,
    prepare_reactivity = 4,
    luma_instability = 5,
    accumulate = 6,
    accumulate_sharpen = 7,
    rcas = 8,
    debug_view = 9,
    generate_reactive = 10,
    tcr_autogenerate = 11,
    _,
};

// `FfxFsr3UpscalerInitializationFlagBits`.
pub const Fsr3UpscalerFlags = packed struct(u32) {
    high_dynamic_range: bool = false,
    display_resolution_motion_vectors: bool = false,
    motion_vectors_jitter_cancellation: bool = false,
    depth_inverted: bool = false,
    depth_infinite: bool = false,
    auto_exposure: bool = false,
    dynamic_resolution: bool = false,
    texture1d_usage: bool = false,
    debug_checking: bool = false,
    _reserved: u23 = 0,
};

// The private `FSR3UPSCALER_SHADER_PERMUTATION_*` bits
// (`ffx_fsr3upscaler_private.h`), which the host passes to `create_pipeline`.
pub const Fsr3UpscalerPermutation = packed struct(u32) {
    use_lanczos_type: bool = false,
    hdr_color_input: bool = false,
    low_res_motion_vectors: bool = false,
    jitter_motion_vectors: bool = false,
    depth_inverted: bool = false,
    enable_sharpening: bool = false,
    force_wave64: bool = false,
    allow_fp16: bool = false,
    _reserved: u24 = 0,
};

pub const Fsr3UpscalerMessage = *const fn (MessageType, [*:0]const WChar) callconv(.c) void;

pub const Fsr3UpscalerContextDescription = extern struct {
    flags: Fsr3UpscalerFlags,
    max_render_size: Dimensions2D,
    max_upscale_size: Dimensions2D,
    fp_message: ?Fsr3UpscalerMessage,
    backend_interface: Interface,
};

// `FfxFsr3UpscalerDispatchFlags`.
pub const Fsr3UpscalerDispatchFlags = packed struct(u32) {
    draw_debug_view: bool = false,
    _reserved: u31 = 0,
};

pub const Fsr3UpscalerDispatchDescription = extern struct {
    command_list: CommandList,
    color: Resource,
    depth: Resource,
    motion_vectors: Resource,
    exposure: Resource,
    reactive: Resource,
    transparency_and_composition: Resource,
    dilated_depth: Resource,
    dilated_motion_vectors: Resource,
    reconstructed_prev_nearest_depth: Resource,
    output: Resource,
    jitter_offset: FloatCoords2D,
    motion_vector_scale: FloatCoords2D,
    render_size: Dimensions2D,
    upscale_size: Dimensions2D,
    enable_sharpening: bool,
    sharpness: f32,
    frame_time_delta: f32,
    pre_exposure: f32,
    reset: bool,
    camera_near: f32,
    camera_far: f32,
    camera_fov_angle_vertical: f32,
    view_space_to_meters_factor: f32,
    flags: Fsr3UpscalerDispatchFlags,
};

pub const Fsr3UpscalerConfigureKey = enum(c_int) {
    velocity_factor = 0,
    reactiveness_scale = 1,
    shading_change_scale = 2,
    accumulation_added_per_frame = 3,
    min_disocclusion_accumulation = 4,
    _,
};

pub extern fn ffxFsr3UpscalerContextCreate(
    context: *Fsr3UpscalerContext,
    description: *const Fsr3UpscalerContextDescription,
) ErrorCode;
pub extern fn ffxFsr3UpscalerContextDispatch(
    context: *Fsr3UpscalerContext,
    description: *const Fsr3UpscalerDispatchDescription,
) ErrorCode;
pub extern fn ffxFsr3UpscalerContextDestroy(context: *Fsr3UpscalerContext) ErrorCode;
pub extern fn ffxFsr3UpscalerSetConstant(
    context: *Fsr3UpscalerContext,
    key: Fsr3UpscalerConfigureKey,
    value: *anyopaque,
) ErrorCode;
pub extern fn ffxFsr3UpscalerGetJitterPhaseCount(render_width: i32, display_width: i32) i32;
pub extern fn ffxFsr3UpscalerGetJitterOffset(x: *f32, y: *f32, index: i32, phase_count: i32) ErrorCode;

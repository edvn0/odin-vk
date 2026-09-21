module bindless;

public static const uint sampler_2d_binding            = 0;
public static const uint sampled_2d_binding            = 1;
public static const uint storage_image_2d_binding      = 2;
public static const uint sampled_3d_binding            = 3;
public static const uint storage_image_3d_binding      = 4;
public static const uint sampler_3d_binding            = 5;
public static const uint comparison_sampler_binding    = 6;
public static const uint sampled_2d_depth_binding      = 7;

public [[vk::binding(sampler_2d_binding, 0)]]
SamplerState samplers_2d[];

public [[vk::binding(sampled_2d_binding, 0)]]
Texture2D<float4> sampled_2d[];

public [[vk::binding(storage_image_2d_binding, 0)]]
RWTexture2D<float4> storage_image_2d[];

public [[vk::binding(sampled_3d_binding, 0)]]
Texture3D<float4> sampled_3d[];

public [[vk::binding(storage_image_3d_binding, 0)]]
RWTexture3D<float4> storage_image_3d[];

public [[vk::binding(sampler_3d_binding, 0)]]
SamplerState samplers_3d[];

public [[vk::binding(comparison_sampler_binding, 0)]]
SamplerComparisonState comparison_samplers[];

public [[vk::binding(sampled_2d_depth_binding, 0)]]
Texture2D<float> sampled_2d_depth[];
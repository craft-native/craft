//! Private Vulkan ABI for native surface implementation.
//! Declarations derive from Khronos Vulkan-Headers vulkan-sdk-1.4.363.0,
//! commit 6802bb4733b63ed5efd3adb308a6c885ef180ea1.
//! Source: https://github.com/KhronosGroup/Vulkan-Headers
//! Copyright 2015-2026 The Khronos Group Inc. SPDX-License-Identifier: MIT
//! This boundary alone does not implement or advertise native presentation.
// MIT License
//
// Copyright (c) 2015-2023 The Khronos Group Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
const builtin = @import("builtin");
const api_call: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;
const std = @import("std");
comptime {
    if (@sizeOf(usize) != 8) @compileError("Craft's initial Vulkan ABI supports only 64-bit targets");
}

pub const VkStructureType = u32;

pub const VkApplicationInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    pApplicationName: [*c]const u8,
    applicationVersion: u32,
    pEngineName: [*c]const u8,
    engineVersion: u32,
    apiVersion: u32,
};

pub const VkFlags = u32;

pub const VkInstanceCreateFlags = VkFlags;

pub const VkInstanceCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkInstanceCreateFlags,
    pApplicationInfo: [*c]const VkApplicationInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: [*c]const [*c]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: [*c]const [*c]const u8,
};

pub const VkExtensionProperties = extern struct {
    extensionName: [256]u8,
    specVersion: u32,
};

pub const VkBool32 = u32;

pub const VkPhysicalDeviceFeatures = extern struct {
    robustBufferAccess: VkBool32,
    fullDrawIndexUint32: VkBool32,
    imageCubeArray: VkBool32,
    independentBlend: VkBool32,
    geometryShader: VkBool32,
    tessellationShader: VkBool32,
    sampleRateShading: VkBool32,
    dualSrcBlend: VkBool32,
    logicOp: VkBool32,
    multiDrawIndirect: VkBool32,
    drawIndirectFirstInstance: VkBool32,
    depthClamp: VkBool32,
    depthBiasClamp: VkBool32,
    fillModeNonSolid: VkBool32,
    depthBounds: VkBool32,
    wideLines: VkBool32,
    largePoints: VkBool32,
    alphaToOne: VkBool32,
    multiViewport: VkBool32,
    samplerAnisotropy: VkBool32,
    textureCompressionETC2: VkBool32,
    textureCompressionASTC_LDR: VkBool32,
    textureCompressionBC: VkBool32,
    occlusionQueryPrecise: VkBool32,
    pipelineStatisticsQuery: VkBool32,
    vertexPipelineStoresAndAtomics: VkBool32,
    fragmentStoresAndAtomics: VkBool32,
    shaderTessellationAndGeometryPointSize: VkBool32,
    shaderImageGatherExtended: VkBool32,
    shaderStorageImageExtendedFormats: VkBool32,
    shaderStorageImageMultisample: VkBool32,
    shaderStorageImageReadWithoutFormat: VkBool32,
    shaderStorageImageWriteWithoutFormat: VkBool32,
    shaderUniformBufferArrayDynamicIndexing: VkBool32,
    shaderSampledImageArrayDynamicIndexing: VkBool32,
    shaderStorageBufferArrayDynamicIndexing: VkBool32,
    shaderStorageImageArrayDynamicIndexing: VkBool32,
    shaderClipDistance: VkBool32,
    shaderCullDistance: VkBool32,
    shaderFloat64: VkBool32,
    shaderInt64: VkBool32,
    shaderInt16: VkBool32,
    shaderResourceResidency: VkBool32,
    shaderResourceMinLod: VkBool32,
    sparseBinding: VkBool32,
    sparseResidencyBuffer: VkBool32,
    sparseResidencyImage2D: VkBool32,
    sparseResidencyImage3D: VkBool32,
    sparseResidency2Samples: VkBool32,
    sparseResidency4Samples: VkBool32,
    sparseResidency8Samples: VkBool32,
    sparseResidency16Samples: VkBool32,
    sparseResidencyAliased: VkBool32,
    variableMultisampleRate: VkBool32,
    inheritedQueries: VkBool32,
};

pub const VkPhysicalDeviceFeatures2 = extern struct {
    sType: VkStructureType,
    pNext: ?*anyopaque,
    features: VkPhysicalDeviceFeatures,
};

pub const VkPhysicalDeviceType = u32;

pub const VkDeviceSize = u64;

pub const VkSampleCountFlags = VkFlags;

pub const VkPhysicalDeviceLimits = extern struct {
    maxImageDimension1D: u32,
    maxImageDimension2D: u32,
    maxImageDimension3D: u32,
    maxImageDimensionCube: u32,
    maxImageArrayLayers: u32,
    maxTexelBufferElements: u32,
    maxUniformBufferRange: u32,
    maxStorageBufferRange: u32,
    maxPushConstantsSize: u32,
    maxMemoryAllocationCount: u32,
    maxSamplerAllocationCount: u32,
    bufferImageGranularity: VkDeviceSize,
    sparseAddressSpaceSize: VkDeviceSize,
    maxBoundDescriptorSets: u32,
    maxPerStageDescriptorSamplers: u32,
    maxPerStageDescriptorUniformBuffers: u32,
    maxPerStageDescriptorStorageBuffers: u32,
    maxPerStageDescriptorSampledImages: u32,
    maxPerStageDescriptorStorageImages: u32,
    maxPerStageDescriptorInputAttachments: u32,
    maxPerStageResources: u32,
    maxDescriptorSetSamplers: u32,
    maxDescriptorSetUniformBuffers: u32,
    maxDescriptorSetUniformBuffersDynamic: u32,
    maxDescriptorSetStorageBuffers: u32,
    maxDescriptorSetStorageBuffersDynamic: u32,
    maxDescriptorSetSampledImages: u32,
    maxDescriptorSetStorageImages: u32,
    maxDescriptorSetInputAttachments: u32,
    maxVertexInputAttributes: u32,
    maxVertexInputBindings: u32,
    maxVertexInputAttributeOffset: u32,
    maxVertexInputBindingStride: u32,
    maxVertexOutputComponents: u32,
    maxTessellationGenerationLevel: u32,
    maxTessellationPatchSize: u32,
    maxTessellationControlPerVertexInputComponents: u32,
    maxTessellationControlPerVertexOutputComponents: u32,
    maxTessellationControlPerPatchOutputComponents: u32,
    maxTessellationControlTotalOutputComponents: u32,
    maxTessellationEvaluationInputComponents: u32,
    maxTessellationEvaluationOutputComponents: u32,
    maxGeometryShaderInvocations: u32,
    maxGeometryInputComponents: u32,
    maxGeometryOutputComponents: u32,
    maxGeometryOutputVertices: u32,
    maxGeometryTotalOutputComponents: u32,
    maxFragmentInputComponents: u32,
    maxFragmentOutputAttachments: u32,
    maxFragmentDualSrcAttachments: u32,
    maxFragmentCombinedOutputResources: u32,
    maxComputeSharedMemorySize: u32,
    maxComputeWorkGroupCount: [3]u32,
    maxComputeWorkGroupInvocations: u32,
    maxComputeWorkGroupSize: [3]u32,
    subPixelPrecisionBits: u32,
    subTexelPrecisionBits: u32,
    mipmapPrecisionBits: u32,
    maxDrawIndexedIndexValue: u32,
    maxDrawIndirectCount: u32,
    maxSamplerLodBias: f32,
    maxSamplerAnisotropy: f32,
    maxViewports: u32,
    maxViewportDimensions: [2]u32,
    viewportBoundsRange: [2]f32,
    viewportSubPixelBits: u32,
    minMemoryMapAlignment: usize,
    minTexelBufferOffsetAlignment: VkDeviceSize,
    minUniformBufferOffsetAlignment: VkDeviceSize,
    minStorageBufferOffsetAlignment: VkDeviceSize,
    minTexelOffset: i32,
    maxTexelOffset: u32,
    minTexelGatherOffset: i32,
    maxTexelGatherOffset: u32,
    minInterpolationOffset: f32,
    maxInterpolationOffset: f32,
    subPixelInterpolationOffsetBits: u32,
    maxFramebufferWidth: u32,
    maxFramebufferHeight: u32,
    maxFramebufferLayers: u32,
    framebufferColorSampleCounts: VkSampleCountFlags,
    framebufferDepthSampleCounts: VkSampleCountFlags,
    framebufferStencilSampleCounts: VkSampleCountFlags,
    framebufferNoAttachmentsSampleCounts: VkSampleCountFlags,
    maxColorAttachments: u32,
    sampledImageColorSampleCounts: VkSampleCountFlags,
    sampledImageIntegerSampleCounts: VkSampleCountFlags,
    sampledImageDepthSampleCounts: VkSampleCountFlags,
    sampledImageStencilSampleCounts: VkSampleCountFlags,
    storageImageSampleCounts: VkSampleCountFlags,
    maxSampleMaskWords: u32,
    timestampComputeAndGraphics: VkBool32,
    timestampPeriod: f32,
    maxClipDistances: u32,
    maxCullDistances: u32,
    maxCombinedClipAndCullDistances: u32,
    discreteQueuePriorities: u32,
    pointSizeRange: [2]f32,
    lineWidthRange: [2]f32,
    pointSizeGranularity: f32,
    lineWidthGranularity: f32,
    strictLines: VkBool32,
    standardSampleLocations: VkBool32,
    optimalBufferCopyOffsetAlignment: VkDeviceSize,
    optimalBufferCopyRowPitchAlignment: VkDeviceSize,
    nonCoherentAtomSize: VkDeviceSize,
};

pub const VkPhysicalDeviceSparseProperties = extern struct {
    residencyStandard2DBlockShape: VkBool32,
    residencyStandard2DMultisampleBlockShape: VkBool32,
    residencyStandard3DBlockShape: VkBool32,
    residencyAlignedMipSize: VkBool32,
    residencyNonResidentStrict: VkBool32,
};

pub const VkPhysicalDeviceProperties = extern struct {
    apiVersion: u32,
    driverVersion: u32,
    vendorID: u32,
    deviceID: u32,
    deviceType: VkPhysicalDeviceType,
    deviceName: [256]u8,
    pipelineCacheUUID: [16]u8,
    limits: VkPhysicalDeviceLimits,
    sparseProperties: VkPhysicalDeviceSparseProperties,
};

pub const VkMemoryPropertyFlags = VkFlags;

pub const VkMemoryType = extern struct {
    propertyFlags: VkMemoryPropertyFlags,
    heapIndex: u32,
};

pub const VkMemoryHeapFlags = VkFlags;

pub const VkMemoryHeap = extern struct {
    size: VkDeviceSize,
    flags: VkMemoryHeapFlags,
};

pub const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [32]VkMemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [16]VkMemoryHeap,
};

pub const VkQueueFlags = VkFlags;

pub const VkExtent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};

pub const VkQueueFamilyProperties = extern struct {
    queueFlags: VkQueueFlags,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: VkExtent3D,
};

pub const VkDeviceQueueCreateFlags = VkFlags;

pub const VkDeviceQueueCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkDeviceQueueCreateFlags,
    queueFamilyIndex: u32,
    queueCount: u32,
    pQueuePriorities: [*c]const f32,
};

pub const VkDeviceCreateFlags = VkFlags;

pub const VkDeviceCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkDeviceCreateFlags,
    queueCreateInfoCount: u32,
    pQueueCreateInfos: [*c]const VkDeviceQueueCreateInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: [*c]const [*c]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: [*c]const [*c]const u8,
    pEnabledFeatures: [*c]const VkPhysicalDeviceFeatures,
};

pub const VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*anyopaque,
    swapchainMaintenance1: VkBool32,
};

pub const VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT = VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR;

pub const VkExtent2D = extern struct {
    width: u32,
    height: u32,
};

pub const VkSurfaceTransformFlagsKHR = VkFlags;

pub const VkSurfaceTransformFlagBitsKHR = u32;

pub const VkCompositeAlphaFlagsKHR = VkFlags;

pub const VkImageUsageFlags = VkFlags;

pub const VkSurfaceCapabilitiesKHR = extern struct {
    minImageCount: u32,
    maxImageCount: u32,
    currentExtent: VkExtent2D,
    minImageExtent: VkExtent2D,
    maxImageExtent: VkExtent2D,
    maxImageArrayLayers: u32,
    supportedTransforms: VkSurfaceTransformFlagsKHR,
    currentTransform: VkSurfaceTransformFlagBitsKHR,
    supportedCompositeAlpha: VkCompositeAlphaFlagsKHR,
    supportedUsageFlags: VkImageUsageFlags,
};

pub const VkFormat = u32;

pub const VkColorSpaceKHR = u32;

pub const VkSurfaceFormatKHR = extern struct {
    format: VkFormat,
    colorSpace: VkColorSpaceKHR,
};

pub const VkSwapchainCreateFlagsKHR = VkFlags;

pub const VkSurfaceKHR = ?*opaque {};

pub const VkSharingMode = u32;

pub const VkCompositeAlphaFlagBitsKHR = u32;

pub const VkPresentModeKHR = u32;

pub const VkSwapchainKHR = ?*opaque {};

pub const VkSwapchainCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkSwapchainCreateFlagsKHR,
    surface: VkSurfaceKHR,
    minImageCount: u32,
    imageFormat: VkFormat,
    imageColorSpace: VkColorSpaceKHR,
    imageExtent: VkExtent2D,
    imageArrayLayers: u32,
    imageUsage: VkImageUsageFlags,
    imageSharingMode: VkSharingMode,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: [*c]const u32,
    preTransform: VkSurfaceTransformFlagBitsKHR,
    compositeAlpha: VkCompositeAlphaFlagBitsKHR,
    presentMode: VkPresentModeKHR,
    clipped: VkBool32,
    oldSwapchain: VkSwapchainKHR,
};

pub const VkFence = ?*opaque {};

pub const VkSwapchainPresentFenceInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    swapchainCount: u32,
    pFences: [*c]const VkFence,
};

pub const VkSwapchainPresentFenceInfoEXT = VkSwapchainPresentFenceInfoKHR;

pub const VkSemaphoreCreateFlags = VkFlags;

pub const VkSemaphoreCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkSemaphoreCreateFlags,
};

pub const VkFenceCreateFlags = VkFlags;

pub const VkFenceCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkFenceCreateFlags,
};

pub const VkBufferCreateFlags = VkFlags;

pub const VkBufferUsageFlags = VkFlags;

pub const VkBufferCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkBufferCreateFlags,
    size: VkDeviceSize,
    usage: VkBufferUsageFlags,
    sharingMode: VkSharingMode,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: [*c]const u32,
};

pub const VkMemoryRequirements = extern struct {
    size: VkDeviceSize,
    alignment: VkDeviceSize,
    memoryTypeBits: u32,
};

pub const VkMemoryAllocateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    allocationSize: VkDeviceSize,
    memoryTypeIndex: u32,
};

pub const VkDeviceMemory = ?*opaque {};

pub const VkMappedMemoryRange = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    memory: VkDeviceMemory,
    offset: VkDeviceSize,
    size: VkDeviceSize,
};

pub const VkCommandPoolCreateFlags = VkFlags;

pub const VkCommandPoolCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkCommandPoolCreateFlags,
    queueFamilyIndex: u32,
};

pub const VkCommandPool = ?*opaque {};

pub const VkCommandBufferLevel = u32;

pub const VkCommandBufferAllocateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    commandPool: VkCommandPool,
    level: VkCommandBufferLevel,
    commandBufferCount: u32,
};

pub const VkCommandBufferUsageFlags = VkFlags;

pub const VkRenderPass = ?*opaque {};

pub const VkFramebuffer = ?*opaque {};

pub const VkQueryControlFlags = VkFlags;

pub const VkQueryPipelineStatisticFlags = VkFlags;

pub const VkCommandBufferInheritanceInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    renderPass: VkRenderPass,
    subpass: u32,
    framebuffer: VkFramebuffer,
    occlusionQueryEnable: VkBool32,
    queryFlags: VkQueryControlFlags,
    pipelineStatistics: VkQueryPipelineStatisticFlags,
};

pub const VkCommandBufferBeginInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkCommandBufferUsageFlags,
    pInheritanceInfo: [*c]const VkCommandBufferInheritanceInfo,
};

pub const VkImageAspectFlags = VkFlags;

pub const VkImageSubresourceLayers = extern struct {
    aspectMask: VkImageAspectFlags,
    mipLevel: u32,
    baseArrayLayer: u32,
    layerCount: u32,
};

pub const VkOffset3D = extern struct {
    x: i32,
    y: i32,
    z: i32,
};

pub const VkBufferImageCopy = extern struct {
    bufferOffset: VkDeviceSize,
    bufferRowLength: u32,
    bufferImageHeight: u32,
    imageSubresource: VkImageSubresourceLayers,
    imageOffset: VkOffset3D,
    imageExtent: VkExtent3D,
};

pub const VkAccessFlags = VkFlags;

pub const VkBuffer = ?*opaque {};

pub const VkBufferMemoryBarrier = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    srcAccessMask: VkAccessFlags,
    dstAccessMask: VkAccessFlags,
    srcQueueFamilyIndex: u32,
    dstQueueFamilyIndex: u32,
    buffer: VkBuffer,
    offset: VkDeviceSize,
    size: VkDeviceSize,
};

pub const VkImageLayout = u32;

pub const VkImage = ?*opaque {};

pub const VkImageSubresourceRange = extern struct {
    aspectMask: VkImageAspectFlags,
    baseMipLevel: u32,
    levelCount: u32,
    baseArrayLayer: u32,
    layerCount: u32,
};

pub const VkImageMemoryBarrier = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    srcAccessMask: VkAccessFlags,
    dstAccessMask: VkAccessFlags,
    oldLayout: VkImageLayout,
    newLayout: VkImageLayout,
    srcQueueFamilyIndex: u32,
    dstQueueFamilyIndex: u32,
    image: VkImage,
    subresourceRange: VkImageSubresourceRange,
};

pub const VkMemoryBarrier = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    srcAccessMask: VkAccessFlags,
    dstAccessMask: VkAccessFlags,
};

pub const VkSemaphore = ?*opaque {};

pub const VkPipelineStageFlags = VkFlags;

pub const VkCommandBuffer = ?*opaque {};

pub const VkSubmitInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: [*c]const VkSemaphore,
    pWaitDstStageMask: [*c]const VkPipelineStageFlags,
    commandBufferCount: u32,
    pCommandBuffers: [*c]const VkCommandBuffer,
    signalSemaphoreCount: u32,
    pSignalSemaphores: [*c]const VkSemaphore,
};

pub const VkResult = i32;

pub const VkPresentInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: [*c]const VkSemaphore,
    swapchainCount: u32,
    pSwapchains: [*c]const VkSwapchainKHR,
    pImageIndices: [*c]const u32,
    pResults: [*c]VkResult,
};

pub const VkXlibSurfaceCreateFlagsKHR = VkFlags;

pub const Display = opaque {};

pub const VkXlibSurfaceCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkXlibSurfaceCreateFlagsKHR,
    dpy: ?*Display,
    window: c_ulong,
};

pub const VkWin32SurfaceCreateFlagsKHR = VkFlags;

pub const VkWin32SurfaceCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkWin32SurfaceCreateFlagsKHR,
    hinstance: ?*anyopaque,
    hwnd: ?*anyopaque,
};

pub const VkAndroidSurfaceCreateFlagsKHR = VkFlags;

pub const ANativeWindow = opaque {};

pub const VkAndroidSurfaceCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkAndroidSurfaceCreateFlagsKHR,
    window: ?*ANativeWindow,
};

pub const PFN_vkVoidFunction = ?*const fn () callconv(api_call) void;

pub const VkInstance = ?*opaque {};

pub const PFN_vkGetInstanceProcAddr = *const fn (instance: VkInstance, pName: [*c]const u8) callconv(api_call) PFN_vkVoidFunction;

pub const VkDevice = ?*opaque {};

pub const PFN_vkGetDeviceProcAddr = *const fn (device: VkDevice, pName: [*c]const u8) callconv(api_call) PFN_vkVoidFunction;

pub const PFN_vkEnumerateInstanceVersion = *const fn (pApiVersion: [*c]u32) callconv(api_call) VkResult;

pub const PFN_vkEnumerateInstanceExtensionProperties = *const fn (pLayerName: [*c]const u8, pPropertyCount: [*c]u32, pProperties: [*c]VkExtensionProperties) callconv(api_call) VkResult;

pub const VkAllocationCallbacks = opaque {};

pub const PFN_vkCreateInstance = *const fn (pCreateInfo: [*c]const VkInstanceCreateInfo, pAllocator: ?*const VkAllocationCallbacks, pInstance: [*c]VkInstance) callconv(api_call) VkResult;

pub const PFN_vkDestroyInstance = *const fn (instance: VkInstance, pAllocator: ?*const VkAllocationCallbacks) callconv(api_call) void;

pub const VkPhysicalDevice = ?*opaque {};

pub const PFN_vkEnumeratePhysicalDevices = *const fn (instance: VkInstance, pPhysicalDeviceCount: [*c]u32, pPhysicalDevices: [*c]VkPhysicalDevice) callconv(api_call) VkResult;

pub const PFN_vkGetPhysicalDeviceProperties = *const fn (physicalDevice: VkPhysicalDevice, pProperties: [*c]VkPhysicalDeviceProperties) callconv(api_call) void;

pub const PFN_vkGetPhysicalDeviceFeatures2 = *const fn (physicalDevice: VkPhysicalDevice, pFeatures: [*c]VkPhysicalDeviceFeatures2) callconv(api_call) void;

pub const PFN_vkGetPhysicalDeviceQueueFamilyProperties = *const fn (physicalDevice: VkPhysicalDevice, pQueueFamilyPropertyCount: [*c]u32, pQueueFamilyProperties: [*c]VkQueueFamilyProperties) callconv(api_call) void;

pub const PFN_vkGetPhysicalDeviceMemoryProperties = *const fn (physicalDevice: VkPhysicalDevice, pMemoryProperties: [*c]VkPhysicalDeviceMemoryProperties) callconv(api_call) void;

pub const PFN_vkEnumerateDeviceExtensionProperties = *const fn (physicalDevice: VkPhysicalDevice, pLayerName: [*c]const u8, pPropertyCount: [*c]u32, pProperties: [*c]VkExtensionProperties) callconv(api_call) VkResult;

pub const PFN_vkCreateDevice = *const fn (physicalDevice: VkPhysicalDevice, pCreateInfo: [*c]const VkDeviceCreateInfo, pAllocator: ?*const VkAllocationCallbacks, pDevice: [*c]VkDevice) callconv(api_call) VkResult;

pub const PFN_vkDestroyDevice = *const fn (device: VkDevice, pAllocator: ?*const VkAllocationCallbacks) callconv(api_call) void;

pub const VkQueue = ?*opaque {};

pub const PFN_vkGetDeviceQueue = *const fn (device: VkDevice, queueFamilyIndex: u32, queueIndex: u32, pQueue: [*c]VkQueue) callconv(api_call) void;

pub const PFN_vkCreateXlibSurfaceKHR = *const fn (instance: VkInstance, pCreateInfo: [*c]const VkXlibSurfaceCreateInfoKHR, pAllocator: ?*const VkAllocationCallbacks, pSurface: [*c]VkSurfaceKHR) callconv(api_call) VkResult;

pub const PFN_vkCreateWin32SurfaceKHR = *const fn (instance: VkInstance, pCreateInfo: [*c]const VkWin32SurfaceCreateInfoKHR, pAllocator: ?*const VkAllocationCallbacks, pSurface: [*c]VkSurfaceKHR) callconv(api_call) VkResult;

pub const PFN_vkCreateAndroidSurfaceKHR = *const fn (instance: VkInstance, pCreateInfo: [*c]const VkAndroidSurfaceCreateInfoKHR, pAllocator: ?*const VkAllocationCallbacks, pSurface: [*c]VkSurfaceKHR) callconv(api_call) VkResult;

pub const PFN_vkDestroySurfaceKHR = *const fn (instance: VkInstance, surface: VkSurfaceKHR, pAllocator: ?*const VkAllocationCallbacks) callconv(api_call) void;

pub const PFN_vkGetPhysicalDeviceSurfaceSupportKHR = *const fn (physicalDevice: VkPhysicalDevice, queueFamilyIndex: u32, surface: VkSurfaceKHR, pSupported: [*c]VkBool32) callconv(api_call) VkResult;

pub const PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR = *const fn (physicalDevice: VkPhysicalDevice, surface: VkSurfaceKHR, pSurfaceCapabilities: [*c]VkSurfaceCapabilitiesKHR) callconv(api_call) VkResult;

pub const PFN_vkGetPhysicalDeviceSurfaceFormatsKHR = *const fn (physicalDevice: VkPhysicalDevice, surface: VkSurfaceKHR, pSurfaceFormatCount: [*c]u32, pSurfaceFormats: [*c]VkSurfaceFormatKHR) callconv(api_call) VkResult;

pub const PFN_vkGetPhysicalDeviceSurfacePresentModesKHR = *const fn (physicalDevice: VkPhysicalDevice, surface: VkSurfaceKHR, pPresentModeCount: [*c]u32, pPresentModes: [*c]VkPresentModeKHR) callconv(api_call) VkResult;

pub const PFN_vkCreateSwapchainKHR = *const fn (device: VkDevice, pCreateInfo: [*c]const VkSwapchainCreateInfoKHR, pAllocator: ?*const VkAllocationCallbacks, pSwapchain: [*c]VkSwapchainKHR) callconv(api_call) VkResult;

pub const PFN_vkDestroySwapchainKHR = *const fn (device: VkDevice, swapchain: VkSwapchainKHR, pAllocator: ?*const VkAllocationCallbacks) callconv(api_call) void;

pub const PFN_vkGetSwapchainImagesKHR = *const fn (device: VkDevice, swapchain: VkSwapchainKHR, pSwapchainImageCount: [*c]u32, pSwapchainImages: [*c]VkImage) callconv(api_call) VkResult;

pub const PFN_vkAcquireNextImageKHR = *const fn (device: VkDevice, swapchain: VkSwapchainKHR, timeout: u64, semaphore: VkSemaphore, fence: VkFence, pImageIndex: [*c]u32) callconv(api_call) VkResult;

pub const PFN_vkCreateSemaphore = *const fn (device: VkDevice, pCreateInfo: [*c]const VkSemaphoreCreateInfo, pAllocator: ?*const VkAllocationCallbacks, pSemaphore: [*c]VkSemaphore) callconv(api_call) VkResult;

pub const PFN_vkDestroySemaphore = *const fn (device: VkDevice, semaphore: VkSemaphore, pAllocator: ?*const VkAllocationCallbacks) callconv(api_call) void;

pub const PFN_vkCreateFence = *const fn (device: VkDevice, pCreateInfo: [*c]const VkFenceCreateInfo, pAllocator: ?*const VkAllocationCallbacks, pFence: [*c]VkFence) callconv(api_call) VkResult;

pub const PFN_vkDestroyFence = *const fn (device: VkDevice, fence: VkFence, pAllocator: ?*const VkAllocationCallbacks) callconv(api_call) void;

pub const PFN_vkWaitForFences = *const fn (device: VkDevice, fenceCount: u32, pFences: [*c]const VkFence, waitAll: VkBool32, timeout: u64) callconv(api_call) VkResult;

pub const PFN_vkResetFences = *const fn (device: VkDevice, fenceCount: u32, pFences: [*c]const VkFence) callconv(api_call) VkResult;

pub const PFN_vkCreateBuffer = *const fn (device: VkDevice, pCreateInfo: [*c]const VkBufferCreateInfo, pAllocator: ?*const VkAllocationCallbacks, pBuffer: [*c]VkBuffer) callconv(api_call) VkResult;

pub const PFN_vkDestroyBuffer = *const fn (device: VkDevice, buffer: VkBuffer, pAllocator: ?*const VkAllocationCallbacks) callconv(api_call) void;

pub const PFN_vkGetBufferMemoryRequirements = *const fn (device: VkDevice, buffer: VkBuffer, pMemoryRequirements: [*c]VkMemoryRequirements) callconv(api_call) void;

pub const PFN_vkAllocateMemory = *const fn (device: VkDevice, pAllocateInfo: [*c]const VkMemoryAllocateInfo, pAllocator: ?*const VkAllocationCallbacks, pMemory: [*c]VkDeviceMemory) callconv(api_call) VkResult;

pub const PFN_vkFreeMemory = *const fn (device: VkDevice, memory: VkDeviceMemory, pAllocator: ?*const VkAllocationCallbacks) callconv(api_call) void;

pub const PFN_vkBindBufferMemory = *const fn (device: VkDevice, buffer: VkBuffer, memory: VkDeviceMemory, memoryOffset: VkDeviceSize) callconv(api_call) VkResult;

pub const VkMemoryMapFlags = VkFlags;

pub const PFN_vkMapMemory = *const fn (device: VkDevice, memory: VkDeviceMemory, offset: VkDeviceSize, size: VkDeviceSize, flags: VkMemoryMapFlags, ppData: [*c]?*anyopaque) callconv(api_call) VkResult;

pub const PFN_vkUnmapMemory = *const fn (device: VkDevice, memory: VkDeviceMemory) callconv(api_call) void;

pub const PFN_vkFlushMappedMemoryRanges = *const fn (device: VkDevice, memoryRangeCount: u32, pMemoryRanges: [*c]const VkMappedMemoryRange) callconv(api_call) VkResult;

pub const PFN_vkInvalidateMappedMemoryRanges = *const fn (device: VkDevice, memoryRangeCount: u32, pMemoryRanges: [*c]const VkMappedMemoryRange) callconv(api_call) VkResult;

pub const PFN_vkCreateCommandPool = *const fn (device: VkDevice, pCreateInfo: [*c]const VkCommandPoolCreateInfo, pAllocator: ?*const VkAllocationCallbacks, pCommandPool: [*c]VkCommandPool) callconv(api_call) VkResult;

pub const PFN_vkDestroyCommandPool = *const fn (device: VkDevice, commandPool: VkCommandPool, pAllocator: ?*const VkAllocationCallbacks) callconv(api_call) void;

pub const PFN_vkAllocateCommandBuffers = *const fn (device: VkDevice, pAllocateInfo: [*c]const VkCommandBufferAllocateInfo, pCommandBuffers: [*c]VkCommandBuffer) callconv(api_call) VkResult;

pub const VkCommandBufferResetFlags = VkFlags;

pub const PFN_vkResetCommandBuffer = *const fn (commandBuffer: VkCommandBuffer, flags: VkCommandBufferResetFlags) callconv(api_call) VkResult;

pub const PFN_vkBeginCommandBuffer = *const fn (commandBuffer: VkCommandBuffer, pBeginInfo: [*c]const VkCommandBufferBeginInfo) callconv(api_call) VkResult;

pub const PFN_vkEndCommandBuffer = *const fn (commandBuffer: VkCommandBuffer) callconv(api_call) VkResult;

pub const VkDependencyFlags = VkFlags;

pub const PFN_vkCmdPipelineBarrier = *const fn (commandBuffer: VkCommandBuffer, srcStageMask: VkPipelineStageFlags, dstStageMask: VkPipelineStageFlags, dependencyFlags: VkDependencyFlags, memoryBarrierCount: u32, pMemoryBarriers: [*c]const VkMemoryBarrier, bufferMemoryBarrierCount: u32, pBufferMemoryBarriers: [*c]const VkBufferMemoryBarrier, imageMemoryBarrierCount: u32, pImageMemoryBarriers: [*c]const VkImageMemoryBarrier) callconv(api_call) void;

pub const PFN_vkCmdCopyBufferToImage = *const fn (commandBuffer: VkCommandBuffer, srcBuffer: VkBuffer, dstImage: VkImage, dstImageLayout: VkImageLayout, regionCount: u32, pRegions: [*c]const VkBufferImageCopy) callconv(api_call) void;

pub const PFN_vkCmdCopyImageToBuffer = *const fn (commandBuffer: VkCommandBuffer, srcImage: VkImage, srcImageLayout: VkImageLayout, dstBuffer: VkBuffer, regionCount: u32, pRegions: [*c]const VkBufferImageCopy) callconv(api_call) void;

pub const PFN_vkQueueSubmit = *const fn (queue: VkQueue, submitCount: u32, pSubmits: [*c]const VkSubmitInfo, fence: VkFence) callconv(api_call) VkResult;

pub const PFN_vkQueuePresentKHR = *const fn (queue: VkQueue, pPresentInfo: [*c]const VkPresentInfoKHR) callconv(api_call) VkResult;

pub const VK_SUCCESS = 0;

pub const VK_NOT_READY = 1;

pub const VK_TIMEOUT = 2;

pub const VK_INCOMPLETE = 5;

pub const VK_SUBOPTIMAL_KHR = 1000001003;

pub const VK_ERROR_OUT_OF_DATE_KHR = -1000001004;

pub const VK_ERROR_SURFACE_LOST_KHR = -1000000000;

pub const VK_ERROR_DEVICE_LOST = -4;

pub const VK_ERROR_OUT_OF_HOST_MEMORY = -1;
pub const VK_ERROR_OUT_OF_DEVICE_MEMORY = -2;

pub const VK_ERROR_EXTENSION_NOT_PRESENT = -7;

pub const VK_ERROR_FEATURE_NOT_PRESENT = -8;

pub const VK_STRUCTURE_TYPE_APPLICATION_INFO = 0;

pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = 1;

pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO = 2;

pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO = 3;

pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 = 1000059000;

pub const VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT = 1000275000;

pub const VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT = 1000275001;

pub const VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR = 1000001000;

pub const VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO = 9;

pub const VK_STRUCTURE_TYPE_FENCE_CREATE_INFO = 8;

pub const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO = 12;

pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO = 5;

pub const VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE = 6;

pub const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO = 39;

pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO = 40;

pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO = 42;

pub const VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER = 44;

pub const VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER = 45;

pub const VK_STRUCTURE_TYPE_SUBMIT_INFO = 4;

pub const VK_STRUCTURE_TYPE_PRESENT_INFO_KHR = 1000001001;

pub const VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR = 1000004000;

pub const VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR = 1000009000;

pub const VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR = 1000008000;

pub const VK_QUEUE_GRAPHICS_BIT = 0x00000001;

pub const VK_IMAGE_USAGE_TRANSFER_SRC_BIT = 0x00000001;

pub const VK_IMAGE_USAGE_TRANSFER_DST_BIT = 0x00000002;

pub const VK_FORMAT_B8G8R8A8_UNORM = 44;

pub const VK_FORMAT_R8G8B8A8_UNORM = 37;

pub const VK_COLOR_SPACE_SRGB_NONLINEAR_KHR = 0;

pub const VK_PRESENT_MODE_FIFO_KHR = 2;

pub const VK_SHARING_MODE_EXCLUSIVE = 0;

pub const VK_BUFFER_USAGE_TRANSFER_SRC_BIT = 0x00000001;

pub const VK_BUFFER_USAGE_TRANSFER_DST_BIT = 0x00000002;

pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT = 0x00000002;

pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT = 0x00000004;

pub const VK_MEMORY_HEAP_DEVICE_LOCAL_BIT = 0x00000001;

pub const VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT = 0x00000002;

pub const VK_COMMAND_BUFFER_LEVEL_PRIMARY = 0;

pub const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT = 0x00000001;

pub const VK_IMAGE_LAYOUT_UNDEFINED = 0;

pub const VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL = 6;

pub const VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL = 7;

pub const VK_IMAGE_LAYOUT_PRESENT_SRC_KHR = 1000001002;

pub const VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT = 0x00000001;

pub const VK_PIPELINE_STAGE_TRANSFER_BIT = 0x00001000;

pub const VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT = 0x00002000;

pub const VK_PIPELINE_STAGE_HOST_BIT = 0x00004000;

pub const VK_ACCESS_TRANSFER_READ_BIT = 0x00000800;

pub const VK_ACCESS_TRANSFER_WRITE_BIT = 0x00001000;

pub const VK_ACCESS_HOST_READ_BIT = 0x00002000;

pub const VK_ACCESS_HOST_WRITE_BIT = 0x00004000;

pub const VK_IMAGE_ASPECT_COLOR_BIT = 0x00000001;

pub const VK_FENCE_CREATE_SIGNALED_BIT = 0x00000001;

pub const VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR = 0x00000001;

pub const VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR = 0x00000008;

pub const VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU = 2;

pub const VK_QUEUE_FAMILY_IGNORED = 0xffffffff;

pub const VK_WHOLE_SIZE: u64 = 0xffffffffffffffff;

pub const VK_KHR_SURFACE_EXTENSION_NAME = "VK_KHR_surface";

pub const VK_KHR_SWAPCHAIN_EXTENSION_NAME = "VK_KHR_swapchain";

pub const VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME = "VK_KHR_get_surface_capabilities2";

pub const VK_EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME = "VK_EXT_surface_maintenance1";

pub const VK_EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME = "VK_EXT_swapchain_maintenance1";

pub const VK_KHR_XLIB_SURFACE_EXTENSION_NAME = "VK_KHR_xlib_surface";

pub const VK_KHR_WIN32_SURFACE_EXTENSION_NAME = "VK_KHR_win32_surface";

pub const VK_KHR_ANDROID_SURFACE_EXTENSION_NAME = "VK_KHR_android_surface";

pub const VK_KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME = "VK_KHR_surface_maintenance1";
pub const VK_KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME = "VK_KHR_swapchain_maintenance1";

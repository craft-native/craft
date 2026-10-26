// Independent C++ probe of the actual Khronos SDK, never a Vulkan backend.
#include "vulkan_api_headers.h"
#include <string.h>

struct AbiField;
struct AbiValue {
    size_t size;
    size_t alignment;
    uint32_t kind;
    size_t arrayLength;
    const AbiValue *element;
    size_t fieldCount;
    const AbiField *fields;
};
struct AbiField { const char *name; size_t offset; AbiValue value; };
struct AbiType { const char *name; AbiValue value; };
struct AbiFunction { const char *name; AbiValue result; size_t count; const AbiValue *arguments; };
struct AbiConstant { const char *name; uint64_t value; };

template <typename T> struct Fields {
    static constexpr size_t count = 0;
    static constexpr const AbiField *data = nullptr;
};
extern const AbiField fields_VkApplicationInfo[];
template <> struct Fields<VkApplicationInfo> { static constexpr size_t count = 7; static constexpr const AbiField *data = fields_VkApplicationInfo; };
extern const AbiField fields_VkInstanceCreateInfo[];
template <> struct Fields<VkInstanceCreateInfo> { static constexpr size_t count = 8; static constexpr const AbiField *data = fields_VkInstanceCreateInfo; };
extern const AbiField fields_VkExtensionProperties[];
template <> struct Fields<VkExtensionProperties> { static constexpr size_t count = 2; static constexpr const AbiField *data = fields_VkExtensionProperties; };
extern const AbiField fields_VkPhysicalDeviceFeatures2[];
template <> struct Fields<VkPhysicalDeviceFeatures2> { static constexpr size_t count = 3; static constexpr const AbiField *data = fields_VkPhysicalDeviceFeatures2; };
extern const AbiField fields_VkPhysicalDeviceFeatures[];
template <> struct Fields<VkPhysicalDeviceFeatures> { static constexpr size_t count = 55; static constexpr const AbiField *data = fields_VkPhysicalDeviceFeatures; };
extern const AbiField fields_VkPhysicalDeviceProperties[];
template <> struct Fields<VkPhysicalDeviceProperties> { static constexpr size_t count = 9; static constexpr const AbiField *data = fields_VkPhysicalDeviceProperties; };
extern const AbiField fields_VkPhysicalDeviceLimits[];
template <> struct Fields<VkPhysicalDeviceLimits> { static constexpr size_t count = 106; static constexpr const AbiField *data = fields_VkPhysicalDeviceLimits; };
extern const AbiField fields_VkPhysicalDeviceSparseProperties[];
template <> struct Fields<VkPhysicalDeviceSparseProperties> { static constexpr size_t count = 5; static constexpr const AbiField *data = fields_VkPhysicalDeviceSparseProperties; };
extern const AbiField fields_VkPhysicalDeviceMemoryProperties[];
template <> struct Fields<VkPhysicalDeviceMemoryProperties> { static constexpr size_t count = 4; static constexpr const AbiField *data = fields_VkPhysicalDeviceMemoryProperties; };
extern const AbiField fields_VkMemoryType[];
template <> struct Fields<VkMemoryType> { static constexpr size_t count = 2; static constexpr const AbiField *data = fields_VkMemoryType; };
extern const AbiField fields_VkMemoryHeap[];
template <> struct Fields<VkMemoryHeap> { static constexpr size_t count = 2; static constexpr const AbiField *data = fields_VkMemoryHeap; };
extern const AbiField fields_VkQueueFamilyProperties[];
template <> struct Fields<VkQueueFamilyProperties> { static constexpr size_t count = 4; static constexpr const AbiField *data = fields_VkQueueFamilyProperties; };
extern const AbiField fields_VkExtent3D[];
template <> struct Fields<VkExtent3D> { static constexpr size_t count = 3; static constexpr const AbiField *data = fields_VkExtent3D; };
extern const AbiField fields_VkDeviceQueueCreateInfo[];
template <> struct Fields<VkDeviceQueueCreateInfo> { static constexpr size_t count = 6; static constexpr const AbiField *data = fields_VkDeviceQueueCreateInfo; };
extern const AbiField fields_VkDeviceCreateInfo[];
template <> struct Fields<VkDeviceCreateInfo> { static constexpr size_t count = 10; static constexpr const AbiField *data = fields_VkDeviceCreateInfo; };
extern const AbiField fields_VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR[];
template <> struct Fields<VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR> { static constexpr size_t count = 3; static constexpr const AbiField *data = fields_VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR; };
extern const AbiField fields_VkSurfaceCapabilitiesKHR[];
template <> struct Fields<VkSurfaceCapabilitiesKHR> { static constexpr size_t count = 10; static constexpr const AbiField *data = fields_VkSurfaceCapabilitiesKHR; };
extern const AbiField fields_VkExtent2D[];
template <> struct Fields<VkExtent2D> { static constexpr size_t count = 2; static constexpr const AbiField *data = fields_VkExtent2D; };
extern const AbiField fields_VkSurfaceFormatKHR[];
template <> struct Fields<VkSurfaceFormatKHR> { static constexpr size_t count = 2; static constexpr const AbiField *data = fields_VkSurfaceFormatKHR; };
extern const AbiField fields_VkSwapchainCreateInfoKHR[];
template <> struct Fields<VkSwapchainCreateInfoKHR> { static constexpr size_t count = 18; static constexpr const AbiField *data = fields_VkSwapchainCreateInfoKHR; };
extern const AbiField fields_VkSwapchainPresentFenceInfoKHR[];
template <> struct Fields<VkSwapchainPresentFenceInfoKHR> { static constexpr size_t count = 4; static constexpr const AbiField *data = fields_VkSwapchainPresentFenceInfoKHR; };
extern const AbiField fields_VkSemaphoreCreateInfo[];
template <> struct Fields<VkSemaphoreCreateInfo> { static constexpr size_t count = 3; static constexpr const AbiField *data = fields_VkSemaphoreCreateInfo; };
extern const AbiField fields_VkFenceCreateInfo[];
template <> struct Fields<VkFenceCreateInfo> { static constexpr size_t count = 3; static constexpr const AbiField *data = fields_VkFenceCreateInfo; };
extern const AbiField fields_VkBufferCreateInfo[];
template <> struct Fields<VkBufferCreateInfo> { static constexpr size_t count = 8; static constexpr const AbiField *data = fields_VkBufferCreateInfo; };
extern const AbiField fields_VkMemoryRequirements[];
template <> struct Fields<VkMemoryRequirements> { static constexpr size_t count = 3; static constexpr const AbiField *data = fields_VkMemoryRequirements; };
extern const AbiField fields_VkMemoryAllocateInfo[];
template <> struct Fields<VkMemoryAllocateInfo> { static constexpr size_t count = 4; static constexpr const AbiField *data = fields_VkMemoryAllocateInfo; };
extern const AbiField fields_VkMappedMemoryRange[];
template <> struct Fields<VkMappedMemoryRange> { static constexpr size_t count = 5; static constexpr const AbiField *data = fields_VkMappedMemoryRange; };
extern const AbiField fields_VkCommandPoolCreateInfo[];
template <> struct Fields<VkCommandPoolCreateInfo> { static constexpr size_t count = 4; static constexpr const AbiField *data = fields_VkCommandPoolCreateInfo; };
extern const AbiField fields_VkCommandBufferAllocateInfo[];
template <> struct Fields<VkCommandBufferAllocateInfo> { static constexpr size_t count = 5; static constexpr const AbiField *data = fields_VkCommandBufferAllocateInfo; };
extern const AbiField fields_VkCommandBufferBeginInfo[];
template <> struct Fields<VkCommandBufferBeginInfo> { static constexpr size_t count = 4; static constexpr const AbiField *data = fields_VkCommandBufferBeginInfo; };
extern const AbiField fields_VkCommandBufferInheritanceInfo[];
template <> struct Fields<VkCommandBufferInheritanceInfo> { static constexpr size_t count = 8; static constexpr const AbiField *data = fields_VkCommandBufferInheritanceInfo; };
extern const AbiField fields_VkBufferImageCopy[];
template <> struct Fields<VkBufferImageCopy> { static constexpr size_t count = 6; static constexpr const AbiField *data = fields_VkBufferImageCopy; };
extern const AbiField fields_VkImageSubresourceLayers[];
template <> struct Fields<VkImageSubresourceLayers> { static constexpr size_t count = 4; static constexpr const AbiField *data = fields_VkImageSubresourceLayers; };
extern const AbiField fields_VkOffset3D[];
template <> struct Fields<VkOffset3D> { static constexpr size_t count = 3; static constexpr const AbiField *data = fields_VkOffset3D; };
extern const AbiField fields_VkBufferMemoryBarrier[];
template <> struct Fields<VkBufferMemoryBarrier> { static constexpr size_t count = 9; static constexpr const AbiField *data = fields_VkBufferMemoryBarrier; };
extern const AbiField fields_VkImageMemoryBarrier[];
template <> struct Fields<VkImageMemoryBarrier> { static constexpr size_t count = 10; static constexpr const AbiField *data = fields_VkImageMemoryBarrier; };
extern const AbiField fields_VkImageSubresourceRange[];
template <> struct Fields<VkImageSubresourceRange> { static constexpr size_t count = 5; static constexpr const AbiField *data = fields_VkImageSubresourceRange; };
extern const AbiField fields_VkMemoryBarrier[];
template <> struct Fields<VkMemoryBarrier> { static constexpr size_t count = 4; static constexpr const AbiField *data = fields_VkMemoryBarrier; };
extern const AbiField fields_VkSubmitInfo[];
template <> struct Fields<VkSubmitInfo> { static constexpr size_t count = 9; static constexpr const AbiField *data = fields_VkSubmitInfo; };
extern const AbiField fields_VkPresentInfoKHR[];
template <> struct Fields<VkPresentInfoKHR> { static constexpr size_t count = 8; static constexpr const AbiField *data = fields_VkPresentInfoKHR; };
#if defined(__linux__) && !defined(__ANDROID__)
extern const AbiField fields_VkXlibSurfaceCreateInfoKHR[];
template <> struct Fields<VkXlibSurfaceCreateInfoKHR> { static constexpr size_t count = 5; static constexpr const AbiField *data = fields_VkXlibSurfaceCreateInfoKHR; };
#endif
#if defined(_WIN32)
extern const AbiField fields_VkWin32SurfaceCreateInfoKHR[];
template <> struct Fields<VkWin32SurfaceCreateInfoKHR> { static constexpr size_t count = 5; static constexpr const AbiField *data = fields_VkWin32SurfaceCreateInfoKHR; };
#endif
extern const AbiField fields_VkAndroidSurfaceCreateInfoKHR[];
template <> struct Fields<VkAndroidSurfaceCreateInfoKHR> { static constexpr size_t count = 4; static constexpr const AbiField *data = fields_VkAndroidSurfaceCreateInfoKHR; };
extern const AbiField fields_VkAllocationCallbacks[];
template <> struct Fields<VkAllocationCallbacks> { static constexpr size_t count = 6; static constexpr const AbiField *data = fields_VkAllocationCallbacks; };

template <typename T> struct Array;
template <typename T, size_t N> struct Array<T[N]> { using Element = T; static constexpr size_t count = N; };
template <typename T> constexpr AbiValue describe();
template <typename T> constexpr AbiValue storedValue = describe<T>();
template <typename T> constexpr AbiValue describe() {
    if constexpr (__is_same(T, void)) return {0, 1, 7, 0, nullptr, 0, nullptr};
    else if constexpr (__is_enum(T)) return describe<__underlying_type(T)>();
    else {
        if constexpr (__is_array(T)) return {sizeof(T), alignof(T), 5, Array<T>::count, &storedValue<typename Array<T>::Element>, 0, nullptr};
        else if constexpr (__is_pointer(T)) return {sizeof(T), alignof(T), 4, 0, nullptr, 0, nullptr};
        else if constexpr (__is_floating_point(T)) return {sizeof(T), alignof(T), 3, 0, nullptr, 0, nullptr};
        // Vulkan's text arrays contain bytes. Plain C char has target-specific
        // signedness; Zig represents C character strings with u8.
        else if constexpr (__is_same(T, char)) return {sizeof(T), alignof(T), 8, 0, nullptr, 0, nullptr};
        else if constexpr (__is_integral(T)) return {sizeof(T), alignof(T), T(-1) < T(0) ? 1U : 2U, 0, nullptr, 0, nullptr};
        else return {sizeof(T), alignof(T), 6, 0, nullptr, Fields<T>::count, Fields<T>::data};
    }
}
#define FIELD(T, F) {#F, offsetof(T, F), describe<decltype(((T *)nullptr)->F)>()}
const AbiField fields_VkApplicationInfo[] = {
    FIELD(VkApplicationInfo, sType),
    FIELD(VkApplicationInfo, pNext),
    FIELD(VkApplicationInfo, pApplicationName),
    FIELD(VkApplicationInfo, applicationVersion),
    FIELD(VkApplicationInfo, pEngineName),
    FIELD(VkApplicationInfo, engineVersion),
    FIELD(VkApplicationInfo, apiVersion),
};
const AbiField fields_VkInstanceCreateInfo[] = {
    FIELD(VkInstanceCreateInfo, sType),
    FIELD(VkInstanceCreateInfo, pNext),
    FIELD(VkInstanceCreateInfo, flags),
    FIELD(VkInstanceCreateInfo, pApplicationInfo),
    FIELD(VkInstanceCreateInfo, enabledLayerCount),
    FIELD(VkInstanceCreateInfo, ppEnabledLayerNames),
    FIELD(VkInstanceCreateInfo, enabledExtensionCount),
    FIELD(VkInstanceCreateInfo, ppEnabledExtensionNames),
};
const AbiField fields_VkExtensionProperties[] = {
    FIELD(VkExtensionProperties, extensionName),
    FIELD(VkExtensionProperties, specVersion),
};
const AbiField fields_VkPhysicalDeviceFeatures2[] = {
    FIELD(VkPhysicalDeviceFeatures2, sType),
    FIELD(VkPhysicalDeviceFeatures2, pNext),
    FIELD(VkPhysicalDeviceFeatures2, features),
};
const AbiField fields_VkPhysicalDeviceFeatures[] = {
    FIELD(VkPhysicalDeviceFeatures, robustBufferAccess),
    FIELD(VkPhysicalDeviceFeatures, fullDrawIndexUint32),
    FIELD(VkPhysicalDeviceFeatures, imageCubeArray),
    FIELD(VkPhysicalDeviceFeatures, independentBlend),
    FIELD(VkPhysicalDeviceFeatures, geometryShader),
    FIELD(VkPhysicalDeviceFeatures, tessellationShader),
    FIELD(VkPhysicalDeviceFeatures, sampleRateShading),
    FIELD(VkPhysicalDeviceFeatures, dualSrcBlend),
    FIELD(VkPhysicalDeviceFeatures, logicOp),
    FIELD(VkPhysicalDeviceFeatures, multiDrawIndirect),
    FIELD(VkPhysicalDeviceFeatures, drawIndirectFirstInstance),
    FIELD(VkPhysicalDeviceFeatures, depthClamp),
    FIELD(VkPhysicalDeviceFeatures, depthBiasClamp),
    FIELD(VkPhysicalDeviceFeatures, fillModeNonSolid),
    FIELD(VkPhysicalDeviceFeatures, depthBounds),
    FIELD(VkPhysicalDeviceFeatures, wideLines),
    FIELD(VkPhysicalDeviceFeatures, largePoints),
    FIELD(VkPhysicalDeviceFeatures, alphaToOne),
    FIELD(VkPhysicalDeviceFeatures, multiViewport),
    FIELD(VkPhysicalDeviceFeatures, samplerAnisotropy),
    FIELD(VkPhysicalDeviceFeatures, textureCompressionETC2),
    FIELD(VkPhysicalDeviceFeatures, textureCompressionASTC_LDR),
    FIELD(VkPhysicalDeviceFeatures, textureCompressionBC),
    FIELD(VkPhysicalDeviceFeatures, occlusionQueryPrecise),
    FIELD(VkPhysicalDeviceFeatures, pipelineStatisticsQuery),
    FIELD(VkPhysicalDeviceFeatures, vertexPipelineStoresAndAtomics),
    FIELD(VkPhysicalDeviceFeatures, fragmentStoresAndAtomics),
    FIELD(VkPhysicalDeviceFeatures, shaderTessellationAndGeometryPointSize),
    FIELD(VkPhysicalDeviceFeatures, shaderImageGatherExtended),
    FIELD(VkPhysicalDeviceFeatures, shaderStorageImageExtendedFormats),
    FIELD(VkPhysicalDeviceFeatures, shaderStorageImageMultisample),
    FIELD(VkPhysicalDeviceFeatures, shaderStorageImageReadWithoutFormat),
    FIELD(VkPhysicalDeviceFeatures, shaderStorageImageWriteWithoutFormat),
    FIELD(VkPhysicalDeviceFeatures, shaderUniformBufferArrayDynamicIndexing),
    FIELD(VkPhysicalDeviceFeatures, shaderSampledImageArrayDynamicIndexing),
    FIELD(VkPhysicalDeviceFeatures, shaderStorageBufferArrayDynamicIndexing),
    FIELD(VkPhysicalDeviceFeatures, shaderStorageImageArrayDynamicIndexing),
    FIELD(VkPhysicalDeviceFeatures, shaderClipDistance),
    FIELD(VkPhysicalDeviceFeatures, shaderCullDistance),
    FIELD(VkPhysicalDeviceFeatures, shaderFloat64),
    FIELD(VkPhysicalDeviceFeatures, shaderInt64),
    FIELD(VkPhysicalDeviceFeatures, shaderInt16),
    FIELD(VkPhysicalDeviceFeatures, shaderResourceResidency),
    FIELD(VkPhysicalDeviceFeatures, shaderResourceMinLod),
    FIELD(VkPhysicalDeviceFeatures, sparseBinding),
    FIELD(VkPhysicalDeviceFeatures, sparseResidencyBuffer),
    FIELD(VkPhysicalDeviceFeatures, sparseResidencyImage2D),
    FIELD(VkPhysicalDeviceFeatures, sparseResidencyImage3D),
    FIELD(VkPhysicalDeviceFeatures, sparseResidency2Samples),
    FIELD(VkPhysicalDeviceFeatures, sparseResidency4Samples),
    FIELD(VkPhysicalDeviceFeatures, sparseResidency8Samples),
    FIELD(VkPhysicalDeviceFeatures, sparseResidency16Samples),
    FIELD(VkPhysicalDeviceFeatures, sparseResidencyAliased),
    FIELD(VkPhysicalDeviceFeatures, variableMultisampleRate),
    FIELD(VkPhysicalDeviceFeatures, inheritedQueries),
};
const AbiField fields_VkPhysicalDeviceProperties[] = {
    FIELD(VkPhysicalDeviceProperties, apiVersion),
    FIELD(VkPhysicalDeviceProperties, driverVersion),
    FIELD(VkPhysicalDeviceProperties, vendorID),
    FIELD(VkPhysicalDeviceProperties, deviceID),
    FIELD(VkPhysicalDeviceProperties, deviceType),
    FIELD(VkPhysicalDeviceProperties, deviceName),
    FIELD(VkPhysicalDeviceProperties, pipelineCacheUUID),
    FIELD(VkPhysicalDeviceProperties, limits),
    FIELD(VkPhysicalDeviceProperties, sparseProperties),
};
const AbiField fields_VkPhysicalDeviceLimits[] = {
    FIELD(VkPhysicalDeviceLimits, maxImageDimension1D),
    FIELD(VkPhysicalDeviceLimits, maxImageDimension2D),
    FIELD(VkPhysicalDeviceLimits, maxImageDimension3D),
    FIELD(VkPhysicalDeviceLimits, maxImageDimensionCube),
    FIELD(VkPhysicalDeviceLimits, maxImageArrayLayers),
    FIELD(VkPhysicalDeviceLimits, maxTexelBufferElements),
    FIELD(VkPhysicalDeviceLimits, maxUniformBufferRange),
    FIELD(VkPhysicalDeviceLimits, maxStorageBufferRange),
    FIELD(VkPhysicalDeviceLimits, maxPushConstantsSize),
    FIELD(VkPhysicalDeviceLimits, maxMemoryAllocationCount),
    FIELD(VkPhysicalDeviceLimits, maxSamplerAllocationCount),
    FIELD(VkPhysicalDeviceLimits, bufferImageGranularity),
    FIELD(VkPhysicalDeviceLimits, sparseAddressSpaceSize),
    FIELD(VkPhysicalDeviceLimits, maxBoundDescriptorSets),
    FIELD(VkPhysicalDeviceLimits, maxPerStageDescriptorSamplers),
    FIELD(VkPhysicalDeviceLimits, maxPerStageDescriptorUniformBuffers),
    FIELD(VkPhysicalDeviceLimits, maxPerStageDescriptorStorageBuffers),
    FIELD(VkPhysicalDeviceLimits, maxPerStageDescriptorSampledImages),
    FIELD(VkPhysicalDeviceLimits, maxPerStageDescriptorStorageImages),
    FIELD(VkPhysicalDeviceLimits, maxPerStageDescriptorInputAttachments),
    FIELD(VkPhysicalDeviceLimits, maxPerStageResources),
    FIELD(VkPhysicalDeviceLimits, maxDescriptorSetSamplers),
    FIELD(VkPhysicalDeviceLimits, maxDescriptorSetUniformBuffers),
    FIELD(VkPhysicalDeviceLimits, maxDescriptorSetUniformBuffersDynamic),
    FIELD(VkPhysicalDeviceLimits, maxDescriptorSetStorageBuffers),
    FIELD(VkPhysicalDeviceLimits, maxDescriptorSetStorageBuffersDynamic),
    FIELD(VkPhysicalDeviceLimits, maxDescriptorSetSampledImages),
    FIELD(VkPhysicalDeviceLimits, maxDescriptorSetStorageImages),
    FIELD(VkPhysicalDeviceLimits, maxDescriptorSetInputAttachments),
    FIELD(VkPhysicalDeviceLimits, maxVertexInputAttributes),
    FIELD(VkPhysicalDeviceLimits, maxVertexInputBindings),
    FIELD(VkPhysicalDeviceLimits, maxVertexInputAttributeOffset),
    FIELD(VkPhysicalDeviceLimits, maxVertexInputBindingStride),
    FIELD(VkPhysicalDeviceLimits, maxVertexOutputComponents),
    FIELD(VkPhysicalDeviceLimits, maxTessellationGenerationLevel),
    FIELD(VkPhysicalDeviceLimits, maxTessellationPatchSize),
    FIELD(VkPhysicalDeviceLimits, maxTessellationControlPerVertexInputComponents),
    FIELD(VkPhysicalDeviceLimits, maxTessellationControlPerVertexOutputComponents),
    FIELD(VkPhysicalDeviceLimits, maxTessellationControlPerPatchOutputComponents),
    FIELD(VkPhysicalDeviceLimits, maxTessellationControlTotalOutputComponents),
    FIELD(VkPhysicalDeviceLimits, maxTessellationEvaluationInputComponents),
    FIELD(VkPhysicalDeviceLimits, maxTessellationEvaluationOutputComponents),
    FIELD(VkPhysicalDeviceLimits, maxGeometryShaderInvocations),
    FIELD(VkPhysicalDeviceLimits, maxGeometryInputComponents),
    FIELD(VkPhysicalDeviceLimits, maxGeometryOutputComponents),
    FIELD(VkPhysicalDeviceLimits, maxGeometryOutputVertices),
    FIELD(VkPhysicalDeviceLimits, maxGeometryTotalOutputComponents),
    FIELD(VkPhysicalDeviceLimits, maxFragmentInputComponents),
    FIELD(VkPhysicalDeviceLimits, maxFragmentOutputAttachments),
    FIELD(VkPhysicalDeviceLimits, maxFragmentDualSrcAttachments),
    FIELD(VkPhysicalDeviceLimits, maxFragmentCombinedOutputResources),
    FIELD(VkPhysicalDeviceLimits, maxComputeSharedMemorySize),
    FIELD(VkPhysicalDeviceLimits, maxComputeWorkGroupCount),
    FIELD(VkPhysicalDeviceLimits, maxComputeWorkGroupInvocations),
    FIELD(VkPhysicalDeviceLimits, maxComputeWorkGroupSize),
    FIELD(VkPhysicalDeviceLimits, subPixelPrecisionBits),
    FIELD(VkPhysicalDeviceLimits, subTexelPrecisionBits),
    FIELD(VkPhysicalDeviceLimits, mipmapPrecisionBits),
    FIELD(VkPhysicalDeviceLimits, maxDrawIndexedIndexValue),
    FIELD(VkPhysicalDeviceLimits, maxDrawIndirectCount),
    FIELD(VkPhysicalDeviceLimits, maxSamplerLodBias),
    FIELD(VkPhysicalDeviceLimits, maxSamplerAnisotropy),
    FIELD(VkPhysicalDeviceLimits, maxViewports),
    FIELD(VkPhysicalDeviceLimits, maxViewportDimensions),
    FIELD(VkPhysicalDeviceLimits, viewportBoundsRange),
    FIELD(VkPhysicalDeviceLimits, viewportSubPixelBits),
    FIELD(VkPhysicalDeviceLimits, minMemoryMapAlignment),
    FIELD(VkPhysicalDeviceLimits, minTexelBufferOffsetAlignment),
    FIELD(VkPhysicalDeviceLimits, minUniformBufferOffsetAlignment),
    FIELD(VkPhysicalDeviceLimits, minStorageBufferOffsetAlignment),
    FIELD(VkPhysicalDeviceLimits, minTexelOffset),
    FIELD(VkPhysicalDeviceLimits, maxTexelOffset),
    FIELD(VkPhysicalDeviceLimits, minTexelGatherOffset),
    FIELD(VkPhysicalDeviceLimits, maxTexelGatherOffset),
    FIELD(VkPhysicalDeviceLimits, minInterpolationOffset),
    FIELD(VkPhysicalDeviceLimits, maxInterpolationOffset),
    FIELD(VkPhysicalDeviceLimits, subPixelInterpolationOffsetBits),
    FIELD(VkPhysicalDeviceLimits, maxFramebufferWidth),
    FIELD(VkPhysicalDeviceLimits, maxFramebufferHeight),
    FIELD(VkPhysicalDeviceLimits, maxFramebufferLayers),
    FIELD(VkPhysicalDeviceLimits, framebufferColorSampleCounts),
    FIELD(VkPhysicalDeviceLimits, framebufferDepthSampleCounts),
    FIELD(VkPhysicalDeviceLimits, framebufferStencilSampleCounts),
    FIELD(VkPhysicalDeviceLimits, framebufferNoAttachmentsSampleCounts),
    FIELD(VkPhysicalDeviceLimits, maxColorAttachments),
    FIELD(VkPhysicalDeviceLimits, sampledImageColorSampleCounts),
    FIELD(VkPhysicalDeviceLimits, sampledImageIntegerSampleCounts),
    FIELD(VkPhysicalDeviceLimits, sampledImageDepthSampleCounts),
    FIELD(VkPhysicalDeviceLimits, sampledImageStencilSampleCounts),
    FIELD(VkPhysicalDeviceLimits, storageImageSampleCounts),
    FIELD(VkPhysicalDeviceLimits, maxSampleMaskWords),
    FIELD(VkPhysicalDeviceLimits, timestampComputeAndGraphics),
    FIELD(VkPhysicalDeviceLimits, timestampPeriod),
    FIELD(VkPhysicalDeviceLimits, maxClipDistances),
    FIELD(VkPhysicalDeviceLimits, maxCullDistances),
    FIELD(VkPhysicalDeviceLimits, maxCombinedClipAndCullDistances),
    FIELD(VkPhysicalDeviceLimits, discreteQueuePriorities),
    FIELD(VkPhysicalDeviceLimits, pointSizeRange),
    FIELD(VkPhysicalDeviceLimits, lineWidthRange),
    FIELD(VkPhysicalDeviceLimits, pointSizeGranularity),
    FIELD(VkPhysicalDeviceLimits, lineWidthGranularity),
    FIELD(VkPhysicalDeviceLimits, strictLines),
    FIELD(VkPhysicalDeviceLimits, standardSampleLocations),
    FIELD(VkPhysicalDeviceLimits, optimalBufferCopyOffsetAlignment),
    FIELD(VkPhysicalDeviceLimits, optimalBufferCopyRowPitchAlignment),
    FIELD(VkPhysicalDeviceLimits, nonCoherentAtomSize),
};
const AbiField fields_VkPhysicalDeviceSparseProperties[] = {
    FIELD(VkPhysicalDeviceSparseProperties, residencyStandard2DBlockShape),
    FIELD(VkPhysicalDeviceSparseProperties, residencyStandard2DMultisampleBlockShape),
    FIELD(VkPhysicalDeviceSparseProperties, residencyStandard3DBlockShape),
    FIELD(VkPhysicalDeviceSparseProperties, residencyAlignedMipSize),
    FIELD(VkPhysicalDeviceSparseProperties, residencyNonResidentStrict),
};
const AbiField fields_VkPhysicalDeviceMemoryProperties[] = {
    FIELD(VkPhysicalDeviceMemoryProperties, memoryTypeCount),
    FIELD(VkPhysicalDeviceMemoryProperties, memoryTypes),
    FIELD(VkPhysicalDeviceMemoryProperties, memoryHeapCount),
    FIELD(VkPhysicalDeviceMemoryProperties, memoryHeaps),
};
const AbiField fields_VkMemoryType[] = {
    FIELD(VkMemoryType, propertyFlags),
    FIELD(VkMemoryType, heapIndex),
};
const AbiField fields_VkMemoryHeap[] = {
    FIELD(VkMemoryHeap, size),
    FIELD(VkMemoryHeap, flags),
};
const AbiField fields_VkQueueFamilyProperties[] = {
    FIELD(VkQueueFamilyProperties, queueFlags),
    FIELD(VkQueueFamilyProperties, queueCount),
    FIELD(VkQueueFamilyProperties, timestampValidBits),
    FIELD(VkQueueFamilyProperties, minImageTransferGranularity),
};
const AbiField fields_VkExtent3D[] = {
    FIELD(VkExtent3D, width),
    FIELD(VkExtent3D, height),
    FIELD(VkExtent3D, depth),
};
const AbiField fields_VkDeviceQueueCreateInfo[] = {
    FIELD(VkDeviceQueueCreateInfo, sType),
    FIELD(VkDeviceQueueCreateInfo, pNext),
    FIELD(VkDeviceQueueCreateInfo, flags),
    FIELD(VkDeviceQueueCreateInfo, queueFamilyIndex),
    FIELD(VkDeviceQueueCreateInfo, queueCount),
    FIELD(VkDeviceQueueCreateInfo, pQueuePriorities),
};
const AbiField fields_VkDeviceCreateInfo[] = {
    FIELD(VkDeviceCreateInfo, sType),
    FIELD(VkDeviceCreateInfo, pNext),
    FIELD(VkDeviceCreateInfo, flags),
    FIELD(VkDeviceCreateInfo, queueCreateInfoCount),
    FIELD(VkDeviceCreateInfo, pQueueCreateInfos),
    FIELD(VkDeviceCreateInfo, enabledLayerCount),
    FIELD(VkDeviceCreateInfo, ppEnabledLayerNames),
    FIELD(VkDeviceCreateInfo, enabledExtensionCount),
    FIELD(VkDeviceCreateInfo, ppEnabledExtensionNames),
    FIELD(VkDeviceCreateInfo, pEnabledFeatures),
};
const AbiField fields_VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR[] = {
    FIELD(VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR, sType),
    FIELD(VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR, pNext),
    FIELD(VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR, swapchainMaintenance1),
};
const AbiField fields_VkSurfaceCapabilitiesKHR[] = {
    FIELD(VkSurfaceCapabilitiesKHR, minImageCount),
    FIELD(VkSurfaceCapabilitiesKHR, maxImageCount),
    FIELD(VkSurfaceCapabilitiesKHR, currentExtent),
    FIELD(VkSurfaceCapabilitiesKHR, minImageExtent),
    FIELD(VkSurfaceCapabilitiesKHR, maxImageExtent),
    FIELD(VkSurfaceCapabilitiesKHR, maxImageArrayLayers),
    FIELD(VkSurfaceCapabilitiesKHR, supportedTransforms),
    FIELD(VkSurfaceCapabilitiesKHR, currentTransform),
    FIELD(VkSurfaceCapabilitiesKHR, supportedCompositeAlpha),
    FIELD(VkSurfaceCapabilitiesKHR, supportedUsageFlags),
};
const AbiField fields_VkExtent2D[] = {
    FIELD(VkExtent2D, width),
    FIELD(VkExtent2D, height),
};
const AbiField fields_VkSurfaceFormatKHR[] = {
    FIELD(VkSurfaceFormatKHR, format),
    FIELD(VkSurfaceFormatKHR, colorSpace),
};
const AbiField fields_VkSwapchainCreateInfoKHR[] = {
    FIELD(VkSwapchainCreateInfoKHR, sType),
    FIELD(VkSwapchainCreateInfoKHR, pNext),
    FIELD(VkSwapchainCreateInfoKHR, flags),
    FIELD(VkSwapchainCreateInfoKHR, surface),
    FIELD(VkSwapchainCreateInfoKHR, minImageCount),
    FIELD(VkSwapchainCreateInfoKHR, imageFormat),
    FIELD(VkSwapchainCreateInfoKHR, imageColorSpace),
    FIELD(VkSwapchainCreateInfoKHR, imageExtent),
    FIELD(VkSwapchainCreateInfoKHR, imageArrayLayers),
    FIELD(VkSwapchainCreateInfoKHR, imageUsage),
    FIELD(VkSwapchainCreateInfoKHR, imageSharingMode),
    FIELD(VkSwapchainCreateInfoKHR, queueFamilyIndexCount),
    FIELD(VkSwapchainCreateInfoKHR, pQueueFamilyIndices),
    FIELD(VkSwapchainCreateInfoKHR, preTransform),
    FIELD(VkSwapchainCreateInfoKHR, compositeAlpha),
    FIELD(VkSwapchainCreateInfoKHR, presentMode),
    FIELD(VkSwapchainCreateInfoKHR, clipped),
    FIELD(VkSwapchainCreateInfoKHR, oldSwapchain),
};
const AbiField fields_VkSwapchainPresentFenceInfoKHR[] = {
    FIELD(VkSwapchainPresentFenceInfoKHR, sType),
    FIELD(VkSwapchainPresentFenceInfoKHR, pNext),
    FIELD(VkSwapchainPresentFenceInfoKHR, swapchainCount),
    FIELD(VkSwapchainPresentFenceInfoKHR, pFences),
};
const AbiField fields_VkSemaphoreCreateInfo[] = {
    FIELD(VkSemaphoreCreateInfo, sType),
    FIELD(VkSemaphoreCreateInfo, pNext),
    FIELD(VkSemaphoreCreateInfo, flags),
};
const AbiField fields_VkFenceCreateInfo[] = {
    FIELD(VkFenceCreateInfo, sType),
    FIELD(VkFenceCreateInfo, pNext),
    FIELD(VkFenceCreateInfo, flags),
};
const AbiField fields_VkBufferCreateInfo[] = {
    FIELD(VkBufferCreateInfo, sType),
    FIELD(VkBufferCreateInfo, pNext),
    FIELD(VkBufferCreateInfo, flags),
    FIELD(VkBufferCreateInfo, size),
    FIELD(VkBufferCreateInfo, usage),
    FIELD(VkBufferCreateInfo, sharingMode),
    FIELD(VkBufferCreateInfo, queueFamilyIndexCount),
    FIELD(VkBufferCreateInfo, pQueueFamilyIndices),
};
const AbiField fields_VkMemoryRequirements[] = {
    FIELD(VkMemoryRequirements, size),
    FIELD(VkMemoryRequirements, alignment),
    FIELD(VkMemoryRequirements, memoryTypeBits),
};
const AbiField fields_VkMemoryAllocateInfo[] = {
    FIELD(VkMemoryAllocateInfo, sType),
    FIELD(VkMemoryAllocateInfo, pNext),
    FIELD(VkMemoryAllocateInfo, allocationSize),
    FIELD(VkMemoryAllocateInfo, memoryTypeIndex),
};
const AbiField fields_VkMappedMemoryRange[] = {
    FIELD(VkMappedMemoryRange, sType),
    FIELD(VkMappedMemoryRange, pNext),
    FIELD(VkMappedMemoryRange, memory),
    FIELD(VkMappedMemoryRange, offset),
    FIELD(VkMappedMemoryRange, size),
};
const AbiField fields_VkCommandPoolCreateInfo[] = {
    FIELD(VkCommandPoolCreateInfo, sType),
    FIELD(VkCommandPoolCreateInfo, pNext),
    FIELD(VkCommandPoolCreateInfo, flags),
    FIELD(VkCommandPoolCreateInfo, queueFamilyIndex),
};
const AbiField fields_VkCommandBufferAllocateInfo[] = {
    FIELD(VkCommandBufferAllocateInfo, sType),
    FIELD(VkCommandBufferAllocateInfo, pNext),
    FIELD(VkCommandBufferAllocateInfo, commandPool),
    FIELD(VkCommandBufferAllocateInfo, level),
    FIELD(VkCommandBufferAllocateInfo, commandBufferCount),
};
const AbiField fields_VkCommandBufferBeginInfo[] = {
    FIELD(VkCommandBufferBeginInfo, sType),
    FIELD(VkCommandBufferBeginInfo, pNext),
    FIELD(VkCommandBufferBeginInfo, flags),
    FIELD(VkCommandBufferBeginInfo, pInheritanceInfo),
};
const AbiField fields_VkCommandBufferInheritanceInfo[] = {
    FIELD(VkCommandBufferInheritanceInfo, sType),
    FIELD(VkCommandBufferInheritanceInfo, pNext),
    FIELD(VkCommandBufferInheritanceInfo, renderPass),
    FIELD(VkCommandBufferInheritanceInfo, subpass),
    FIELD(VkCommandBufferInheritanceInfo, framebuffer),
    FIELD(VkCommandBufferInheritanceInfo, occlusionQueryEnable),
    FIELD(VkCommandBufferInheritanceInfo, queryFlags),
    FIELD(VkCommandBufferInheritanceInfo, pipelineStatistics),
};
const AbiField fields_VkBufferImageCopy[] = {
    FIELD(VkBufferImageCopy, bufferOffset),
    FIELD(VkBufferImageCopy, bufferRowLength),
    FIELD(VkBufferImageCopy, bufferImageHeight),
    FIELD(VkBufferImageCopy, imageSubresource),
    FIELD(VkBufferImageCopy, imageOffset),
    FIELD(VkBufferImageCopy, imageExtent),
};
const AbiField fields_VkImageSubresourceLayers[] = {
    FIELD(VkImageSubresourceLayers, aspectMask),
    FIELD(VkImageSubresourceLayers, mipLevel),
    FIELD(VkImageSubresourceLayers, baseArrayLayer),
    FIELD(VkImageSubresourceLayers, layerCount),
};
const AbiField fields_VkOffset3D[] = {
    FIELD(VkOffset3D, x),
    FIELD(VkOffset3D, y),
    FIELD(VkOffset3D, z),
};
const AbiField fields_VkBufferMemoryBarrier[] = {
    FIELD(VkBufferMemoryBarrier, sType),
    FIELD(VkBufferMemoryBarrier, pNext),
    FIELD(VkBufferMemoryBarrier, srcAccessMask),
    FIELD(VkBufferMemoryBarrier, dstAccessMask),
    FIELD(VkBufferMemoryBarrier, srcQueueFamilyIndex),
    FIELD(VkBufferMemoryBarrier, dstQueueFamilyIndex),
    FIELD(VkBufferMemoryBarrier, buffer),
    FIELD(VkBufferMemoryBarrier, offset),
    FIELD(VkBufferMemoryBarrier, size),
};
const AbiField fields_VkImageMemoryBarrier[] = {
    FIELD(VkImageMemoryBarrier, sType),
    FIELD(VkImageMemoryBarrier, pNext),
    FIELD(VkImageMemoryBarrier, srcAccessMask),
    FIELD(VkImageMemoryBarrier, dstAccessMask),
    FIELD(VkImageMemoryBarrier, oldLayout),
    FIELD(VkImageMemoryBarrier, newLayout),
    FIELD(VkImageMemoryBarrier, srcQueueFamilyIndex),
    FIELD(VkImageMemoryBarrier, dstQueueFamilyIndex),
    FIELD(VkImageMemoryBarrier, image),
    FIELD(VkImageMemoryBarrier, subresourceRange),
};
const AbiField fields_VkImageSubresourceRange[] = {
    FIELD(VkImageSubresourceRange, aspectMask),
    FIELD(VkImageSubresourceRange, baseMipLevel),
    FIELD(VkImageSubresourceRange, levelCount),
    FIELD(VkImageSubresourceRange, baseArrayLayer),
    FIELD(VkImageSubresourceRange, layerCount),
};
const AbiField fields_VkMemoryBarrier[] = {
    FIELD(VkMemoryBarrier, sType),
    FIELD(VkMemoryBarrier, pNext),
    FIELD(VkMemoryBarrier, srcAccessMask),
    FIELD(VkMemoryBarrier, dstAccessMask),
};
const AbiField fields_VkSubmitInfo[] = {
    FIELD(VkSubmitInfo, sType),
    FIELD(VkSubmitInfo, pNext),
    FIELD(VkSubmitInfo, waitSemaphoreCount),
    FIELD(VkSubmitInfo, pWaitSemaphores),
    FIELD(VkSubmitInfo, pWaitDstStageMask),
    FIELD(VkSubmitInfo, commandBufferCount),
    FIELD(VkSubmitInfo, pCommandBuffers),
    FIELD(VkSubmitInfo, signalSemaphoreCount),
    FIELD(VkSubmitInfo, pSignalSemaphores),
};
const AbiField fields_VkPresentInfoKHR[] = {
    FIELD(VkPresentInfoKHR, sType),
    FIELD(VkPresentInfoKHR, pNext),
    FIELD(VkPresentInfoKHR, waitSemaphoreCount),
    FIELD(VkPresentInfoKHR, pWaitSemaphores),
    FIELD(VkPresentInfoKHR, swapchainCount),
    FIELD(VkPresentInfoKHR, pSwapchains),
    FIELD(VkPresentInfoKHR, pImageIndices),
    FIELD(VkPresentInfoKHR, pResults),
};
#if defined(__linux__) && !defined(__ANDROID__)
const AbiField fields_VkXlibSurfaceCreateInfoKHR[] = {
    FIELD(VkXlibSurfaceCreateInfoKHR, sType),
    FIELD(VkXlibSurfaceCreateInfoKHR, pNext),
    FIELD(VkXlibSurfaceCreateInfoKHR, flags),
    FIELD(VkXlibSurfaceCreateInfoKHR, dpy),
    FIELD(VkXlibSurfaceCreateInfoKHR, window),
};
#endif
#if defined(_WIN32)
const AbiField fields_VkWin32SurfaceCreateInfoKHR[] = {
    FIELD(VkWin32SurfaceCreateInfoKHR, sType),
    FIELD(VkWin32SurfaceCreateInfoKHR, pNext),
    FIELD(VkWin32SurfaceCreateInfoKHR, flags),
    FIELD(VkWin32SurfaceCreateInfoKHR, hinstance),
    FIELD(VkWin32SurfaceCreateInfoKHR, hwnd),
};
#endif
const AbiField fields_VkAndroidSurfaceCreateInfoKHR[] = {
    FIELD(VkAndroidSurfaceCreateInfoKHR, sType),
    FIELD(VkAndroidSurfaceCreateInfoKHR, pNext),
    FIELD(VkAndroidSurfaceCreateInfoKHR, flags),
    FIELD(VkAndroidSurfaceCreateInfoKHR, window),
};
const AbiField fields_VkAllocationCallbacks[] = {
    FIELD(VkAllocationCallbacks, pUserData),
    FIELD(VkAllocationCallbacks, pfnAllocation),
    FIELD(VkAllocationCallbacks, pfnReallocation),
    FIELD(VkAllocationCallbacks, pfnFree),
    FIELD(VkAllocationCallbacks, pfnInternalAllocation),
    FIELD(VkAllocationCallbacks, pfnInternalFree),
};

template <typename T> struct Function;
template <typename R, typename... Args> struct Function<R (VKAPI_PTR *)(Args...)> {
    static constexpr AbiValue arguments[] = { describe<Args>()... };
    static constexpr AbiValue result = describe<R>();
    static constexpr size_t count = sizeof...(Args);
};
static constexpr AbiType types[] = {
    {"VkApplicationInfo", describe<VkApplicationInfo>()},
    {"VkStructureType", describe<VkStructureType>()},
    {"VkInstanceCreateInfo", describe<VkInstanceCreateInfo>()},
    {"VkInstanceCreateFlags", describe<VkInstanceCreateFlags>()},
    {"VkFlags", describe<VkFlags>()},
    {"VkExtensionProperties", describe<VkExtensionProperties>()},
    {"VkPhysicalDeviceFeatures2", describe<VkPhysicalDeviceFeatures2>()},
    {"VkPhysicalDeviceFeatures", describe<VkPhysicalDeviceFeatures>()},
    {"VkBool32", describe<VkBool32>()},
    {"VkPhysicalDeviceProperties", describe<VkPhysicalDeviceProperties>()},
    {"VkPhysicalDeviceType", describe<VkPhysicalDeviceType>()},
    {"VkPhysicalDeviceLimits", describe<VkPhysicalDeviceLimits>()},
    {"VkDeviceSize", describe<VkDeviceSize>()},
    {"VkSampleCountFlags", describe<VkSampleCountFlags>()},
    {"VkPhysicalDeviceSparseProperties", describe<VkPhysicalDeviceSparseProperties>()},
    {"VkPhysicalDeviceMemoryProperties", describe<VkPhysicalDeviceMemoryProperties>()},
    {"VkMemoryType", describe<VkMemoryType>()},
    {"VkMemoryPropertyFlags", describe<VkMemoryPropertyFlags>()},
    {"VkMemoryHeap", describe<VkMemoryHeap>()},
    {"VkMemoryHeapFlags", describe<VkMemoryHeapFlags>()},
    {"VkQueueFamilyProperties", describe<VkQueueFamilyProperties>()},
    {"VkQueueFlags", describe<VkQueueFlags>()},
    {"VkExtent3D", describe<VkExtent3D>()},
    {"VkDeviceQueueCreateInfo", describe<VkDeviceQueueCreateInfo>()},
    {"VkDeviceQueueCreateFlags", describe<VkDeviceQueueCreateFlags>()},
    {"VkDeviceCreateInfo", describe<VkDeviceCreateInfo>()},
    {"VkDeviceCreateFlags", describe<VkDeviceCreateFlags>()},
    {"VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT", describe<VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT>()},
    {"VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR", describe<VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR>()},
    {"VkSurfaceCapabilitiesKHR", describe<VkSurfaceCapabilitiesKHR>()},
    {"VkExtent2D", describe<VkExtent2D>()},
    {"VkSurfaceTransformFlagsKHR", describe<VkSurfaceTransformFlagsKHR>()},
    {"VkSurfaceTransformFlagBitsKHR", describe<VkSurfaceTransformFlagBitsKHR>()},
    {"VkCompositeAlphaFlagsKHR", describe<VkCompositeAlphaFlagsKHR>()},
    {"VkImageUsageFlags", describe<VkImageUsageFlags>()},
    {"VkSurfaceFormatKHR", describe<VkSurfaceFormatKHR>()},
    {"VkFormat", describe<VkFormat>()},
    {"VkColorSpaceKHR", describe<VkColorSpaceKHR>()},
    {"VkSwapchainCreateInfoKHR", describe<VkSwapchainCreateInfoKHR>()},
    {"VkSwapchainCreateFlagsKHR", describe<VkSwapchainCreateFlagsKHR>()},
    {"VkSurfaceKHR", describe<VkSurfaceKHR>()},
    {"VkSharingMode", describe<VkSharingMode>()},
    {"VkCompositeAlphaFlagBitsKHR", describe<VkCompositeAlphaFlagBitsKHR>()},
    {"VkPresentModeKHR", describe<VkPresentModeKHR>()},
    {"VkSwapchainKHR", describe<VkSwapchainKHR>()},
    {"VkSwapchainPresentFenceInfoEXT", describe<VkSwapchainPresentFenceInfoEXT>()},
    {"VkSwapchainPresentFenceInfoKHR", describe<VkSwapchainPresentFenceInfoKHR>()},
    {"VkFence", describe<VkFence>()},
    {"VkSemaphoreCreateInfo", describe<VkSemaphoreCreateInfo>()},
    {"VkSemaphoreCreateFlags", describe<VkSemaphoreCreateFlags>()},
    {"VkFenceCreateInfo", describe<VkFenceCreateInfo>()},
    {"VkFenceCreateFlags", describe<VkFenceCreateFlags>()},
    {"VkBufferCreateInfo", describe<VkBufferCreateInfo>()},
    {"VkBufferCreateFlags", describe<VkBufferCreateFlags>()},
    {"VkBufferUsageFlags", describe<VkBufferUsageFlags>()},
    {"VkMemoryRequirements", describe<VkMemoryRequirements>()},
    {"VkMemoryAllocateInfo", describe<VkMemoryAllocateInfo>()},
    {"VkMappedMemoryRange", describe<VkMappedMemoryRange>()},
    {"VkDeviceMemory", describe<VkDeviceMemory>()},
    {"VkCommandPoolCreateInfo", describe<VkCommandPoolCreateInfo>()},
    {"VkCommandPoolCreateFlags", describe<VkCommandPoolCreateFlags>()},
    {"VkCommandBufferAllocateInfo", describe<VkCommandBufferAllocateInfo>()},
    {"VkCommandPool", describe<VkCommandPool>()},
    {"VkCommandBufferLevel", describe<VkCommandBufferLevel>()},
    {"VkCommandBufferBeginInfo", describe<VkCommandBufferBeginInfo>()},
    {"VkCommandBufferUsageFlags", describe<VkCommandBufferUsageFlags>()},
    {"VkCommandBufferInheritanceInfo", describe<VkCommandBufferInheritanceInfo>()},
    {"VkRenderPass", describe<VkRenderPass>()},
    {"VkFramebuffer", describe<VkFramebuffer>()},
    {"VkQueryControlFlags", describe<VkQueryControlFlags>()},
    {"VkQueryPipelineStatisticFlags", describe<VkQueryPipelineStatisticFlags>()},
    {"VkBufferImageCopy", describe<VkBufferImageCopy>()},
    {"VkImageSubresourceLayers", describe<VkImageSubresourceLayers>()},
    {"VkImageAspectFlags", describe<VkImageAspectFlags>()},
    {"VkOffset3D", describe<VkOffset3D>()},
    {"VkBufferMemoryBarrier", describe<VkBufferMemoryBarrier>()},
    {"VkAccessFlags", describe<VkAccessFlags>()},
    {"VkBuffer", describe<VkBuffer>()},
    {"VkImageMemoryBarrier", describe<VkImageMemoryBarrier>()},
    {"VkImageLayout", describe<VkImageLayout>()},
    {"VkImage", describe<VkImage>()},
    {"VkImageSubresourceRange", describe<VkImageSubresourceRange>()},
    {"VkMemoryBarrier", describe<VkMemoryBarrier>()},
    {"VkSubmitInfo", describe<VkSubmitInfo>()},
    {"VkSemaphore", describe<VkSemaphore>()},
    {"VkPipelineStageFlags", describe<VkPipelineStageFlags>()},
    {"VkCommandBuffer", describe<VkCommandBuffer>()},
    {"VkPresentInfoKHR", describe<VkPresentInfoKHR>()},
    {"VkResult", describe<VkResult>()},
#if defined(__linux__) && !defined(__ANDROID__)
    {"VkXlibSurfaceCreateInfoKHR", describe<VkXlibSurfaceCreateInfoKHR>()},
#endif
#if defined(__linux__) && !defined(__ANDROID__)
    {"VkXlibSurfaceCreateFlagsKHR", describe<VkXlibSurfaceCreateFlagsKHR>()},
#endif
#if defined(_WIN32)
    {"VkWin32SurfaceCreateInfoKHR", describe<VkWin32SurfaceCreateInfoKHR>()},
#endif
#if defined(_WIN32)
    {"VkWin32SurfaceCreateFlagsKHR", describe<VkWin32SurfaceCreateFlagsKHR>()},
#endif
    {"VkAndroidSurfaceCreateInfoKHR", describe<VkAndroidSurfaceCreateInfoKHR>()},
    {"VkAndroidSurfaceCreateFlagsKHR", describe<VkAndroidSurfaceCreateFlagsKHR>()},
    {"VkInstance", describe<VkInstance>()},
    {"VkDevice", describe<VkDevice>()},
    {"VkPhysicalDevice", describe<VkPhysicalDevice>()},
    {"VkQueue", describe<VkQueue>()},
    {"VkMemoryMapFlags", describe<VkMemoryMapFlags>()},
    {"VkCommandBufferResetFlags", describe<VkCommandBufferResetFlags>()},
    {"VkDependencyFlags", describe<VkDependencyFlags>()},
};
static constexpr AbiFunction functions[] = {
    {"PFN_vkGetInstanceProcAddr", Function<PFN_vkGetInstanceProcAddr>::result, Function<PFN_vkGetInstanceProcAddr>::count, Function<PFN_vkGetInstanceProcAddr>::arguments},
    {"PFN_vkGetDeviceProcAddr", Function<PFN_vkGetDeviceProcAddr>::result, Function<PFN_vkGetDeviceProcAddr>::count, Function<PFN_vkGetDeviceProcAddr>::arguments},
    {"PFN_vkEnumerateInstanceVersion", Function<PFN_vkEnumerateInstanceVersion>::result, Function<PFN_vkEnumerateInstanceVersion>::count, Function<PFN_vkEnumerateInstanceVersion>::arguments},
    {"PFN_vkEnumerateInstanceExtensionProperties", Function<PFN_vkEnumerateInstanceExtensionProperties>::result, Function<PFN_vkEnumerateInstanceExtensionProperties>::count, Function<PFN_vkEnumerateInstanceExtensionProperties>::arguments},
    {"PFN_vkCreateInstance", Function<PFN_vkCreateInstance>::result, Function<PFN_vkCreateInstance>::count, Function<PFN_vkCreateInstance>::arguments},
    {"PFN_vkDestroyInstance", Function<PFN_vkDestroyInstance>::result, Function<PFN_vkDestroyInstance>::count, Function<PFN_vkDestroyInstance>::arguments},
    {"PFN_vkEnumeratePhysicalDevices", Function<PFN_vkEnumeratePhysicalDevices>::result, Function<PFN_vkEnumeratePhysicalDevices>::count, Function<PFN_vkEnumeratePhysicalDevices>::arguments},
    {"PFN_vkGetPhysicalDeviceProperties", Function<PFN_vkGetPhysicalDeviceProperties>::result, Function<PFN_vkGetPhysicalDeviceProperties>::count, Function<PFN_vkGetPhysicalDeviceProperties>::arguments},
    {"PFN_vkGetPhysicalDeviceFeatures2", Function<PFN_vkGetPhysicalDeviceFeatures2>::result, Function<PFN_vkGetPhysicalDeviceFeatures2>::count, Function<PFN_vkGetPhysicalDeviceFeatures2>::arguments},
    {"PFN_vkGetPhysicalDeviceQueueFamilyProperties", Function<PFN_vkGetPhysicalDeviceQueueFamilyProperties>::result, Function<PFN_vkGetPhysicalDeviceQueueFamilyProperties>::count, Function<PFN_vkGetPhysicalDeviceQueueFamilyProperties>::arguments},
    {"PFN_vkGetPhysicalDeviceMemoryProperties", Function<PFN_vkGetPhysicalDeviceMemoryProperties>::result, Function<PFN_vkGetPhysicalDeviceMemoryProperties>::count, Function<PFN_vkGetPhysicalDeviceMemoryProperties>::arguments},
    {"PFN_vkEnumerateDeviceExtensionProperties", Function<PFN_vkEnumerateDeviceExtensionProperties>::result, Function<PFN_vkEnumerateDeviceExtensionProperties>::count, Function<PFN_vkEnumerateDeviceExtensionProperties>::arguments},
    {"PFN_vkCreateDevice", Function<PFN_vkCreateDevice>::result, Function<PFN_vkCreateDevice>::count, Function<PFN_vkCreateDevice>::arguments},
    {"PFN_vkDestroyDevice", Function<PFN_vkDestroyDevice>::result, Function<PFN_vkDestroyDevice>::count, Function<PFN_vkDestroyDevice>::arguments},
    {"PFN_vkGetDeviceQueue", Function<PFN_vkGetDeviceQueue>::result, Function<PFN_vkGetDeviceQueue>::count, Function<PFN_vkGetDeviceQueue>::arguments},
#if defined(__linux__) && !defined(__ANDROID__)
    {"PFN_vkCreateXlibSurfaceKHR", Function<PFN_vkCreateXlibSurfaceKHR>::result, Function<PFN_vkCreateXlibSurfaceKHR>::count, Function<PFN_vkCreateXlibSurfaceKHR>::arguments},
#endif
#if defined(_WIN32)
    {"PFN_vkCreateWin32SurfaceKHR", Function<PFN_vkCreateWin32SurfaceKHR>::result, Function<PFN_vkCreateWin32SurfaceKHR>::count, Function<PFN_vkCreateWin32SurfaceKHR>::arguments},
#endif
    {"PFN_vkCreateAndroidSurfaceKHR", Function<PFN_vkCreateAndroidSurfaceKHR>::result, Function<PFN_vkCreateAndroidSurfaceKHR>::count, Function<PFN_vkCreateAndroidSurfaceKHR>::arguments},
    {"PFN_vkDestroySurfaceKHR", Function<PFN_vkDestroySurfaceKHR>::result, Function<PFN_vkDestroySurfaceKHR>::count, Function<PFN_vkDestroySurfaceKHR>::arguments},
    {"PFN_vkGetPhysicalDeviceSurfaceSupportKHR", Function<PFN_vkGetPhysicalDeviceSurfaceSupportKHR>::result, Function<PFN_vkGetPhysicalDeviceSurfaceSupportKHR>::count, Function<PFN_vkGetPhysicalDeviceSurfaceSupportKHR>::arguments},
    {"PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR", Function<PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR>::result, Function<PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR>::count, Function<PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR>::arguments},
    {"PFN_vkGetPhysicalDeviceSurfaceFormatsKHR", Function<PFN_vkGetPhysicalDeviceSurfaceFormatsKHR>::result, Function<PFN_vkGetPhysicalDeviceSurfaceFormatsKHR>::count, Function<PFN_vkGetPhysicalDeviceSurfaceFormatsKHR>::arguments},
    {"PFN_vkGetPhysicalDeviceSurfacePresentModesKHR", Function<PFN_vkGetPhysicalDeviceSurfacePresentModesKHR>::result, Function<PFN_vkGetPhysicalDeviceSurfacePresentModesKHR>::count, Function<PFN_vkGetPhysicalDeviceSurfacePresentModesKHR>::arguments},
    {"PFN_vkCreateSwapchainKHR", Function<PFN_vkCreateSwapchainKHR>::result, Function<PFN_vkCreateSwapchainKHR>::count, Function<PFN_vkCreateSwapchainKHR>::arguments},
    {"PFN_vkDestroySwapchainKHR", Function<PFN_vkDestroySwapchainKHR>::result, Function<PFN_vkDestroySwapchainKHR>::count, Function<PFN_vkDestroySwapchainKHR>::arguments},
    {"PFN_vkGetSwapchainImagesKHR", Function<PFN_vkGetSwapchainImagesKHR>::result, Function<PFN_vkGetSwapchainImagesKHR>::count, Function<PFN_vkGetSwapchainImagesKHR>::arguments},
    {"PFN_vkAcquireNextImageKHR", Function<PFN_vkAcquireNextImageKHR>::result, Function<PFN_vkAcquireNextImageKHR>::count, Function<PFN_vkAcquireNextImageKHR>::arguments},
    {"PFN_vkCreateSemaphore", Function<PFN_vkCreateSemaphore>::result, Function<PFN_vkCreateSemaphore>::count, Function<PFN_vkCreateSemaphore>::arguments},
    {"PFN_vkDestroySemaphore", Function<PFN_vkDestroySemaphore>::result, Function<PFN_vkDestroySemaphore>::count, Function<PFN_vkDestroySemaphore>::arguments},
    {"PFN_vkCreateFence", Function<PFN_vkCreateFence>::result, Function<PFN_vkCreateFence>::count, Function<PFN_vkCreateFence>::arguments},
    {"PFN_vkDestroyFence", Function<PFN_vkDestroyFence>::result, Function<PFN_vkDestroyFence>::count, Function<PFN_vkDestroyFence>::arguments},
    {"PFN_vkWaitForFences", Function<PFN_vkWaitForFences>::result, Function<PFN_vkWaitForFences>::count, Function<PFN_vkWaitForFences>::arguments},
    {"PFN_vkResetFences", Function<PFN_vkResetFences>::result, Function<PFN_vkResetFences>::count, Function<PFN_vkResetFences>::arguments},
    {"PFN_vkCreateBuffer", Function<PFN_vkCreateBuffer>::result, Function<PFN_vkCreateBuffer>::count, Function<PFN_vkCreateBuffer>::arguments},
    {"PFN_vkDestroyBuffer", Function<PFN_vkDestroyBuffer>::result, Function<PFN_vkDestroyBuffer>::count, Function<PFN_vkDestroyBuffer>::arguments},
    {"PFN_vkGetBufferMemoryRequirements", Function<PFN_vkGetBufferMemoryRequirements>::result, Function<PFN_vkGetBufferMemoryRequirements>::count, Function<PFN_vkGetBufferMemoryRequirements>::arguments},
    {"PFN_vkAllocateMemory", Function<PFN_vkAllocateMemory>::result, Function<PFN_vkAllocateMemory>::count, Function<PFN_vkAllocateMemory>::arguments},
    {"PFN_vkFreeMemory", Function<PFN_vkFreeMemory>::result, Function<PFN_vkFreeMemory>::count, Function<PFN_vkFreeMemory>::arguments},
    {"PFN_vkBindBufferMemory", Function<PFN_vkBindBufferMemory>::result, Function<PFN_vkBindBufferMemory>::count, Function<PFN_vkBindBufferMemory>::arguments},
    {"PFN_vkMapMemory", Function<PFN_vkMapMemory>::result, Function<PFN_vkMapMemory>::count, Function<PFN_vkMapMemory>::arguments},
    {"PFN_vkUnmapMemory", Function<PFN_vkUnmapMemory>::result, Function<PFN_vkUnmapMemory>::count, Function<PFN_vkUnmapMemory>::arguments},
    {"PFN_vkFlushMappedMemoryRanges", Function<PFN_vkFlushMappedMemoryRanges>::result, Function<PFN_vkFlushMappedMemoryRanges>::count, Function<PFN_vkFlushMappedMemoryRanges>::arguments},
    {"PFN_vkInvalidateMappedMemoryRanges", Function<PFN_vkInvalidateMappedMemoryRanges>::result, Function<PFN_vkInvalidateMappedMemoryRanges>::count, Function<PFN_vkInvalidateMappedMemoryRanges>::arguments},
    {"PFN_vkCreateCommandPool", Function<PFN_vkCreateCommandPool>::result, Function<PFN_vkCreateCommandPool>::count, Function<PFN_vkCreateCommandPool>::arguments},
    {"PFN_vkDestroyCommandPool", Function<PFN_vkDestroyCommandPool>::result, Function<PFN_vkDestroyCommandPool>::count, Function<PFN_vkDestroyCommandPool>::arguments},
    {"PFN_vkAllocateCommandBuffers", Function<PFN_vkAllocateCommandBuffers>::result, Function<PFN_vkAllocateCommandBuffers>::count, Function<PFN_vkAllocateCommandBuffers>::arguments},
    {"PFN_vkResetCommandBuffer", Function<PFN_vkResetCommandBuffer>::result, Function<PFN_vkResetCommandBuffer>::count, Function<PFN_vkResetCommandBuffer>::arguments},
    {"PFN_vkBeginCommandBuffer", Function<PFN_vkBeginCommandBuffer>::result, Function<PFN_vkBeginCommandBuffer>::count, Function<PFN_vkBeginCommandBuffer>::arguments},
    {"PFN_vkEndCommandBuffer", Function<PFN_vkEndCommandBuffer>::result, Function<PFN_vkEndCommandBuffer>::count, Function<PFN_vkEndCommandBuffer>::arguments},
    {"PFN_vkCmdPipelineBarrier", Function<PFN_vkCmdPipelineBarrier>::result, Function<PFN_vkCmdPipelineBarrier>::count, Function<PFN_vkCmdPipelineBarrier>::arguments},
    {"PFN_vkCmdCopyBufferToImage", Function<PFN_vkCmdCopyBufferToImage>::result, Function<PFN_vkCmdCopyBufferToImage>::count, Function<PFN_vkCmdCopyBufferToImage>::arguments},
    {"PFN_vkCmdCopyImageToBuffer", Function<PFN_vkCmdCopyImageToBuffer>::result, Function<PFN_vkCmdCopyImageToBuffer>::count, Function<PFN_vkCmdCopyImageToBuffer>::arguments},
    {"PFN_vkQueueSubmit", Function<PFN_vkQueueSubmit>::result, Function<PFN_vkQueueSubmit>::count, Function<PFN_vkQueueSubmit>::arguments},
    {"PFN_vkQueuePresentKHR", Function<PFN_vkQueuePresentKHR>::result, Function<PFN_vkQueuePresentKHR>::count, Function<PFN_vkQueuePresentKHR>::arguments},
};
static constexpr AbiConstant constants[] = {
    {"VK_SUCCESS", static_cast<uint64_t>(VK_SUCCESS)},
    {"VK_NOT_READY", static_cast<uint64_t>(VK_NOT_READY)},
    {"VK_TIMEOUT", static_cast<uint64_t>(VK_TIMEOUT)},
    {"VK_INCOMPLETE", static_cast<uint64_t>(VK_INCOMPLETE)},
    {"VK_SUBOPTIMAL_KHR", static_cast<uint64_t>(VK_SUBOPTIMAL_KHR)},
    {"VK_ERROR_OUT_OF_DATE_KHR", static_cast<uint64_t>(VK_ERROR_OUT_OF_DATE_KHR)},
    {"VK_ERROR_SURFACE_LOST_KHR", static_cast<uint64_t>(VK_ERROR_SURFACE_LOST_KHR)},
    {"VK_ERROR_DEVICE_LOST", static_cast<uint64_t>(VK_ERROR_DEVICE_LOST)},
    {"VK_ERROR_OUT_OF_HOST_MEMORY", static_cast<uint64_t>(VK_ERROR_OUT_OF_HOST_MEMORY)},
    {"VK_ERROR_OUT_OF_DEVICE_MEMORY", static_cast<uint64_t>(VK_ERROR_OUT_OF_DEVICE_MEMORY)},
    {"VK_ERROR_EXTENSION_NOT_PRESENT", static_cast<uint64_t>(VK_ERROR_EXTENSION_NOT_PRESENT)},
    {"VK_ERROR_FEATURE_NOT_PRESENT", static_cast<uint64_t>(VK_ERROR_FEATURE_NOT_PRESENT)},
    {"VK_STRUCTURE_TYPE_APPLICATION_INFO", static_cast<uint64_t>(VK_STRUCTURE_TYPE_APPLICATION_INFO)},
    {"VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO", static_cast<uint64_t>(VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO)},
    {"VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO", static_cast<uint64_t>(VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO)},
    {"VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO", static_cast<uint64_t>(VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO)},
    {"VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2", static_cast<uint64_t>(VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2)},
    {"VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT", static_cast<uint64_t>(VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT)},
    {"VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT", static_cast<uint64_t>(VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT)},
    {"VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR", static_cast<uint64_t>(VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR)},
    {"VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO", static_cast<uint64_t>(VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO)},
    {"VK_STRUCTURE_TYPE_FENCE_CREATE_INFO", static_cast<uint64_t>(VK_STRUCTURE_TYPE_FENCE_CREATE_INFO)},
    {"VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO", static_cast<uint64_t>(VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO)},
    {"VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO", static_cast<uint64_t>(VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO)},
    {"VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE", static_cast<uint64_t>(VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE)},
    {"VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO", static_cast<uint64_t>(VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO)},
    {"VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO", static_cast<uint64_t>(VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO)},
    {"VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO", static_cast<uint64_t>(VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO)},
    {"VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER", static_cast<uint64_t>(VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER)},
    {"VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER", static_cast<uint64_t>(VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER)},
    {"VK_STRUCTURE_TYPE_SUBMIT_INFO", static_cast<uint64_t>(VK_STRUCTURE_TYPE_SUBMIT_INFO)},
    {"VK_STRUCTURE_TYPE_PRESENT_INFO_KHR", static_cast<uint64_t>(VK_STRUCTURE_TYPE_PRESENT_INFO_KHR)},
#if defined(__linux__) && !defined(__ANDROID__)
    {"VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR", static_cast<uint64_t>(VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR)},
#endif
#if defined(_WIN32)
    {"VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR", static_cast<uint64_t>(VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR)},
#endif
    {"VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR", static_cast<uint64_t>(VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR)},
    {"VK_QUEUE_GRAPHICS_BIT", static_cast<uint64_t>(VK_QUEUE_GRAPHICS_BIT)},
    {"VK_IMAGE_USAGE_TRANSFER_SRC_BIT", static_cast<uint64_t>(VK_IMAGE_USAGE_TRANSFER_SRC_BIT)},
    {"VK_IMAGE_USAGE_TRANSFER_DST_BIT", static_cast<uint64_t>(VK_IMAGE_USAGE_TRANSFER_DST_BIT)},
    {"VK_FORMAT_B8G8R8A8_UNORM", static_cast<uint64_t>(VK_FORMAT_B8G8R8A8_UNORM)},
    {"VK_FORMAT_R8G8B8A8_UNORM", static_cast<uint64_t>(VK_FORMAT_R8G8B8A8_UNORM)},
    {"VK_COLOR_SPACE_SRGB_NONLINEAR_KHR", static_cast<uint64_t>(VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)},
    {"VK_PRESENT_MODE_FIFO_KHR", static_cast<uint64_t>(VK_PRESENT_MODE_FIFO_KHR)},
    {"VK_SHARING_MODE_EXCLUSIVE", static_cast<uint64_t>(VK_SHARING_MODE_EXCLUSIVE)},
    {"VK_BUFFER_USAGE_TRANSFER_SRC_BIT", static_cast<uint64_t>(VK_BUFFER_USAGE_TRANSFER_SRC_BIT)},
    {"VK_BUFFER_USAGE_TRANSFER_DST_BIT", static_cast<uint64_t>(VK_BUFFER_USAGE_TRANSFER_DST_BIT)},
    {"VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT", static_cast<uint64_t>(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)},
    {"VK_MEMORY_PROPERTY_HOST_COHERENT_BIT", static_cast<uint64_t>(VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)},
    {"VK_MEMORY_HEAP_DEVICE_LOCAL_BIT", static_cast<uint64_t>(VK_MEMORY_HEAP_DEVICE_LOCAL_BIT)},
    {"VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT", static_cast<uint64_t>(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT)},
    {"VK_COMMAND_BUFFER_LEVEL_PRIMARY", static_cast<uint64_t>(VK_COMMAND_BUFFER_LEVEL_PRIMARY)},
    {"VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT", static_cast<uint64_t>(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT)},
    {"VK_IMAGE_LAYOUT_UNDEFINED", static_cast<uint64_t>(VK_IMAGE_LAYOUT_UNDEFINED)},
    {"VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL", static_cast<uint64_t>(VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)},
    {"VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL", static_cast<uint64_t>(VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)},
    {"VK_IMAGE_LAYOUT_PRESENT_SRC_KHR", static_cast<uint64_t>(VK_IMAGE_LAYOUT_PRESENT_SRC_KHR)},
    {"VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT", static_cast<uint64_t>(VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT)},
    {"VK_PIPELINE_STAGE_TRANSFER_BIT", static_cast<uint64_t>(VK_PIPELINE_STAGE_TRANSFER_BIT)},
    {"VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT", static_cast<uint64_t>(VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT)},
    {"VK_PIPELINE_STAGE_HOST_BIT", static_cast<uint64_t>(VK_PIPELINE_STAGE_HOST_BIT)},
    {"VK_ACCESS_TRANSFER_READ_BIT", static_cast<uint64_t>(VK_ACCESS_TRANSFER_READ_BIT)},
    {"VK_ACCESS_TRANSFER_WRITE_BIT", static_cast<uint64_t>(VK_ACCESS_TRANSFER_WRITE_BIT)},
    {"VK_ACCESS_HOST_READ_BIT", static_cast<uint64_t>(VK_ACCESS_HOST_READ_BIT)},
    {"VK_ACCESS_HOST_WRITE_BIT", static_cast<uint64_t>(VK_ACCESS_HOST_WRITE_BIT)},
    {"VK_IMAGE_ASPECT_COLOR_BIT", static_cast<uint64_t>(VK_IMAGE_ASPECT_COLOR_BIT)},
    {"VK_FENCE_CREATE_SIGNALED_BIT", static_cast<uint64_t>(VK_FENCE_CREATE_SIGNALED_BIT)},
    {"VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR", static_cast<uint64_t>(VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)},
    {"VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR", static_cast<uint64_t>(VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR)},
    {"VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU", static_cast<uint64_t>(VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU)},
    {"VK_QUEUE_FAMILY_IGNORED", static_cast<uint64_t>(VK_QUEUE_FAMILY_IGNORED)},
    {"VK_WHOLE_SIZE", static_cast<uint64_t>(VK_WHOLE_SIZE)},
};
extern "C" const AbiType *craft_vk_abi_type(const char *name) {
    for (const auto &type : types) if (strcmp(type.name, name) == 0) return &type;
    return nullptr;
}
extern "C" const AbiFunction *craft_vk_abi_function(const char *name) {
    for (const auto &function : functions) if (strcmp(function.name, name) == 0) return &function;
    return nullptr;
}
extern "C" const AbiConstant *craft_vk_abi_constant(const char *name) {
    for (const auto &constant : constants) if (strcmp(constant.name, name) == 0) return &constant;
    return nullptr;
}
extern "C" uint32_t craft_vk_header_version() { return VK_HEADER_VERSION; }
extern "C" void craft_vk_abi_call_probe(PFN_vkCmdPipelineBarrier callback) {
    callback(reinterpret_cast<VkCommandBuffer>(uintptr_t(0x1000)), 0x11223344, 0x55667788, 0x99aabbcc,
        0x10203040, reinterpret_cast<const VkMemoryBarrier *>(uintptr_t(0x2000)),
        0x50607080, reinterpret_cast<const VkBufferMemoryBarrier *>(uintptr_t(0x3000)),
        0x90abcdef, reinterpret_cast<const VkImageMemoryBarrier *>(uintptr_t(0x4000)));
}

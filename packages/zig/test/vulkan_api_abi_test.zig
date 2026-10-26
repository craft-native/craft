//! Independently check Craft's Vulkan boundary against the pinned SDK.
//! This executes a C++ ABI probe, not a Vulkan loader or GPU.
const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan_api");
const Value = extern struct { size: usize, alignment: usize, kind: u32, arrayLength: usize, element: ?*const Value, fieldCount: usize, fields: ?[*]const Field };
const Field = extern struct { name: [*:0]const u8, offset: usize, value: Value };
const Type = extern struct { name: [*:0]const u8, value: Value };
const Function = extern struct { name: [*:0]const u8, result: Value, count: usize, arguments: [*]const Value };
const Constant = extern struct { name: [*:0]const u8, value: u64 };
extern fn craft_vk_abi_type(name: [*:0]const u8) callconv(.c) ?*const Type;
extern fn craft_vk_abi_function(name: [*:0]const u8) callconv(.c) ?*const Function;
extern fn craft_vk_abi_constant(name: [*:0]const u8) callconv(.c) ?*const Constant;
extern fn craft_vk_header_version() callconv(.c) u32;
extern fn craft_vk_abi_call_probe(callback: vk.PFN_vkCmdPipelineBarrier) callconv(.c) void;
const api_call: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;

fn require(ok: bool, comptime name: []const u8, reason: []const u8) !void {
    if (!ok) {
        std.debug.print("{s}: {s} differs from Khronos headers\n", .{ name, reason });
        return error.KhronosAbiMismatch;
    }
}
fn compare(comptime T: type, actual: Value, comptime name: []const u8) !void {
    try require(@sizeOf(T) == actual.size, name, "size");
    try require(@alignOf(T) == actual.alignment, name, "alignment");
    const info = @typeInfo(if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T);
    const kind: u32 = switch (info) {
        .int => |n| if (n.signedness == .signed) 1 else 2,
        .float => 3,
        .pointer => 4,
        .array => 5,
        .@"struct" => 6,
        .void => 7,
        else => @compileError("Unexpected Vulkan ABI type"),
    };
    try require(actual.kind == kind or (T == u8 and actual.kind == 8), name, "ABI class");
    switch (info) {
        .array => |array| {
            try require(actual.arrayLength == array.len and actual.element != null, name, "array length");
            try compare(array.child, actual.element.?.*, name ++ " element");
        },
        .@"struct" => |record| {
            try require(actual.fieldCount == record.field_names.len and actual.fields != null, name, "fields");
            inline for (record.field_names, 0..) |field, i| {
                const found = actual.fields.?[i];
                try require(std.mem.eql(u8, std.mem.span(found.name), field), name ++ "." ++ field, "field name");
                try require(@offsetOf(T, field) == found.offset, name ++ "." ++ field, "offset");
                try compare(@FieldType(T, field), found.value, name ++ "." ++ field);
            }
        },
        else => {},
    }
}
fn layout(comptime name: [:0]const u8) !void {
    const found = craft_vk_abi_type(name) orelse return error.MissingKhronosType;
    try compare(@field(vk, name), found.value, name);
}
fn function(comptime name: [:0]const u8) !void {
    const info = @typeInfo(@typeInfo(@field(vk, name)).pointer.child).@"fn";
    const found = craft_vk_abi_function(name) orelse return error.MissingKhronosFunction;
    const expected = @typeInfo(@typeInfo(*const fn () callconv(api_call) void).pointer.child).@"fn".attrs.@"callconv";
    try require(std.meta.eql(info.attrs.@"callconv", expected), name, "calling convention");
    try require(!info.attrs.varargs and info.param_types.len == found.count, name, "parameters");
    try compare(info.return_type.?, found.result, name ++ " result");
    inline for (info.param_types, 0..) |parameter, i| try compare(parameter.?, found.arguments[i], name ++ " argument " ++ std.fmt.comptimePrint("{d}", .{i}));
}
fn constant(comptime name: [:0]const u8) !void {
    const found = craft_vk_abi_constant(name) orelse return error.MissingKhronosConstant;
    const expected: u64 = if (@field(vk, name) < 0) @bitCast(@as(i64, @field(vk, name))) else @intCast(@field(vk, name));
    try require(expected == found.value, name, "value");
}

test "native Vulkan layouts, scalar classes, signatures and values match Khronos SDK 1.4.363" {
    try std.testing.expectEqual(@as(u32, 363), craft_vk_header_version());
    try layout("VkApplicationInfo");
    try layout("VkStructureType");
    try layout("VkInstanceCreateInfo");
    try layout("VkInstanceCreateFlags");
    try layout("VkFlags");
    try layout("VkExtensionProperties");
    try layout("VkPhysicalDeviceFeatures2");
    try layout("VkPhysicalDeviceFeatures");
    try layout("VkBool32");
    try layout("VkPhysicalDeviceProperties");
    try layout("VkPhysicalDeviceType");
    try layout("VkPhysicalDeviceLimits");
    try layout("VkDeviceSize");
    try layout("VkSampleCountFlags");
    try layout("VkPhysicalDeviceSparseProperties");
    try layout("VkPhysicalDeviceMemoryProperties");
    try layout("VkMemoryType");
    try layout("VkMemoryPropertyFlags");
    try layout("VkMemoryHeap");
    try layout("VkMemoryHeapFlags");
    try layout("VkQueueFamilyProperties");
    try layout("VkQueueFlags");
    try layout("VkExtent3D");
    try layout("VkDeviceQueueCreateInfo");
    try layout("VkDeviceQueueCreateFlags");
    try layout("VkDeviceCreateInfo");
    try layout("VkDeviceCreateFlags");
    try layout("VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT");
    try layout("VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR");
    try layout("VkSurfaceCapabilitiesKHR");
    try layout("VkExtent2D");
    try layout("VkSurfaceTransformFlagsKHR");
    try layout("VkSurfaceTransformFlagBitsKHR");
    try layout("VkCompositeAlphaFlagsKHR");
    try layout("VkImageUsageFlags");
    try layout("VkSurfaceFormatKHR");
    try layout("VkFormat");
    try layout("VkColorSpaceKHR");
    try layout("VkSwapchainCreateInfoKHR");
    try layout("VkSwapchainCreateFlagsKHR");
    try layout("VkSurfaceKHR");
    try layout("VkSharingMode");
    try layout("VkCompositeAlphaFlagBitsKHR");
    try layout("VkPresentModeKHR");
    try layout("VkSwapchainKHR");
    try layout("VkSwapchainPresentFenceInfoEXT");
    try layout("VkSwapchainPresentFenceInfoKHR");
    try layout("VkFence");
    try layout("VkSemaphoreCreateInfo");
    try layout("VkSemaphoreCreateFlags");
    try layout("VkFenceCreateInfo");
    try layout("VkFenceCreateFlags");
    try layout("VkBufferCreateInfo");
    try layout("VkBufferCreateFlags");
    try layout("VkBufferUsageFlags");
    try layout("VkMemoryRequirements");
    try layout("VkMemoryAllocateInfo");
    try layout("VkMappedMemoryRange");
    try layout("VkDeviceMemory");
    try layout("VkCommandPoolCreateInfo");
    try layout("VkCommandPoolCreateFlags");
    try layout("VkCommandBufferAllocateInfo");
    try layout("VkCommandPool");
    try layout("VkCommandBufferLevel");
    try layout("VkCommandBufferBeginInfo");
    try layout("VkCommandBufferUsageFlags");
    try layout("VkCommandBufferInheritanceInfo");
    try layout("VkRenderPass");
    try layout("VkFramebuffer");
    try layout("VkQueryControlFlags");
    try layout("VkQueryPipelineStatisticFlags");
    try layout("VkBufferImageCopy");
    try layout("VkImageSubresourceLayers");
    try layout("VkImageAspectFlags");
    try layout("VkOffset3D");
    try layout("VkBufferMemoryBarrier");
    try layout("VkAccessFlags");
    try layout("VkBuffer");
    try layout("VkImageMemoryBarrier");
    try layout("VkImageLayout");
    try layout("VkImage");
    try layout("VkImageSubresourceRange");
    try layout("VkMemoryBarrier");
    try layout("VkSubmitInfo");
    try layout("VkSemaphore");
    try layout("VkPipelineStageFlags");
    try layout("VkCommandBuffer");
    try layout("VkPresentInfoKHR");
    try layout("VkResult");
    if (builtin.os.tag == .linux and builtin.abi != .android) try layout("VkXlibSurfaceCreateInfoKHR");
    if (builtin.os.tag == .linux and builtin.abi != .android) try layout("VkXlibSurfaceCreateFlagsKHR");
    if (builtin.os.tag == .windows) try layout("VkWin32SurfaceCreateInfoKHR");
    if (builtin.os.tag == .windows) try layout("VkWin32SurfaceCreateFlagsKHR");
    try layout("VkAndroidSurfaceCreateInfoKHR");
    try layout("VkAndroidSurfaceCreateFlagsKHR");
    try layout("VkInstance");
    try layout("VkDevice");
    try layout("VkPhysicalDevice");
    try layout("VkQueue");
    try layout("VkMemoryMapFlags");
    try layout("VkCommandBufferResetFlags");
    try layout("VkDependencyFlags");
    try function("PFN_vkGetInstanceProcAddr");
    try function("PFN_vkGetDeviceProcAddr");
    try function("PFN_vkEnumerateInstanceVersion");
    try function("PFN_vkEnumerateInstanceExtensionProperties");
    try function("PFN_vkCreateInstance");
    try function("PFN_vkDestroyInstance");
    try function("PFN_vkEnumeratePhysicalDevices");
    try function("PFN_vkGetPhysicalDeviceProperties");
    try function("PFN_vkGetPhysicalDeviceFeatures2");
    try function("PFN_vkGetPhysicalDeviceQueueFamilyProperties");
    try function("PFN_vkGetPhysicalDeviceMemoryProperties");
    try function("PFN_vkEnumerateDeviceExtensionProperties");
    try function("PFN_vkCreateDevice");
    try function("PFN_vkDestroyDevice");
    try function("PFN_vkGetDeviceQueue");
    if (builtin.os.tag == .linux and builtin.abi != .android) try function("PFN_vkCreateXlibSurfaceKHR");
    if (builtin.os.tag == .windows) try function("PFN_vkCreateWin32SurfaceKHR");
    try function("PFN_vkCreateAndroidSurfaceKHR");
    try function("PFN_vkDestroySurfaceKHR");
    try function("PFN_vkGetPhysicalDeviceSurfaceSupportKHR");
    try function("PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR");
    try function("PFN_vkGetPhysicalDeviceSurfaceFormatsKHR");
    try function("PFN_vkGetPhysicalDeviceSurfacePresentModesKHR");
    try function("PFN_vkCreateSwapchainKHR");
    try function("PFN_vkDestroySwapchainKHR");
    try function("PFN_vkGetSwapchainImagesKHR");
    try function("PFN_vkAcquireNextImageKHR");
    try function("PFN_vkCreateSemaphore");
    try function("PFN_vkDestroySemaphore");
    try function("PFN_vkCreateFence");
    try function("PFN_vkDestroyFence");
    try function("PFN_vkWaitForFences");
    try function("PFN_vkResetFences");
    try function("PFN_vkCreateBuffer");
    try function("PFN_vkDestroyBuffer");
    try function("PFN_vkGetBufferMemoryRequirements");
    try function("PFN_vkAllocateMemory");
    try function("PFN_vkFreeMemory");
    try function("PFN_vkBindBufferMemory");
    try function("PFN_vkMapMemory");
    try function("PFN_vkUnmapMemory");
    try function("PFN_vkFlushMappedMemoryRanges");
    try function("PFN_vkInvalidateMappedMemoryRanges");
    try function("PFN_vkCreateCommandPool");
    try function("PFN_vkDestroyCommandPool");
    try function("PFN_vkAllocateCommandBuffers");
    try function("PFN_vkResetCommandBuffer");
    try function("PFN_vkBeginCommandBuffer");
    try function("PFN_vkEndCommandBuffer");
    try function("PFN_vkCmdPipelineBarrier");
    try function("PFN_vkCmdCopyBufferToImage");
    try function("PFN_vkCmdCopyImageToBuffer");
    try function("PFN_vkQueueSubmit");
    try function("PFN_vkQueuePresentKHR");
    try constant("VK_SUCCESS");
    try constant("VK_NOT_READY");
    try constant("VK_TIMEOUT");
    try constant("VK_INCOMPLETE");
    try constant("VK_SUBOPTIMAL_KHR");
    try constant("VK_ERROR_OUT_OF_DATE_KHR");
    try constant("VK_ERROR_SURFACE_LOST_KHR");
    try constant("VK_ERROR_DEVICE_LOST");
    try constant("VK_ERROR_OUT_OF_HOST_MEMORY");
    try constant("VK_ERROR_OUT_OF_DEVICE_MEMORY");
    try constant("VK_ERROR_EXTENSION_NOT_PRESENT");
    try constant("VK_ERROR_FEATURE_NOT_PRESENT");
    try constant("VK_STRUCTURE_TYPE_APPLICATION_INFO");
    try constant("VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO");
    try constant("VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO");
    try constant("VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO");
    try constant("VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2");
    try constant("VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT");
    try constant("VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT");
    try constant("VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR");
    try constant("VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO");
    try constant("VK_STRUCTURE_TYPE_FENCE_CREATE_INFO");
    try constant("VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO");
    try constant("VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO");
    try constant("VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE");
    try constant("VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO");
    try constant("VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO");
    try constant("VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO");
    try constant("VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER");
    try constant("VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER");
    try constant("VK_STRUCTURE_TYPE_SUBMIT_INFO");
    try constant("VK_STRUCTURE_TYPE_PRESENT_INFO_KHR");
    if (builtin.os.tag == .linux and builtin.abi != .android) try constant("VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR");
    if (builtin.os.tag == .windows) try constant("VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR");
    try constant("VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR");
    try constant("VK_QUEUE_GRAPHICS_BIT");
    try constant("VK_IMAGE_USAGE_TRANSFER_SRC_BIT");
    try constant("VK_IMAGE_USAGE_TRANSFER_DST_BIT");
    try constant("VK_FORMAT_B8G8R8A8_UNORM");
    try constant("VK_FORMAT_R8G8B8A8_UNORM");
    try constant("VK_COLOR_SPACE_SRGB_NONLINEAR_KHR");
    try constant("VK_PRESENT_MODE_FIFO_KHR");
    try constant("VK_SHARING_MODE_EXCLUSIVE");
    try constant("VK_BUFFER_USAGE_TRANSFER_SRC_BIT");
    try constant("VK_BUFFER_USAGE_TRANSFER_DST_BIT");
    try constant("VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT");
    try constant("VK_MEMORY_PROPERTY_HOST_COHERENT_BIT");
    try constant("VK_MEMORY_HEAP_DEVICE_LOCAL_BIT");
    try constant("VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT");
    try constant("VK_COMMAND_BUFFER_LEVEL_PRIMARY");
    try constant("VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT");
    try constant("VK_IMAGE_LAYOUT_UNDEFINED");
    try constant("VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL");
    try constant("VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL");
    try constant("VK_IMAGE_LAYOUT_PRESENT_SRC_KHR");
    try constant("VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT");
    try constant("VK_PIPELINE_STAGE_TRANSFER_BIT");
    try constant("VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT");
    try constant("VK_PIPELINE_STAGE_HOST_BIT");
    try constant("VK_ACCESS_TRANSFER_READ_BIT");
    try constant("VK_ACCESS_TRANSFER_WRITE_BIT");
    try constant("VK_ACCESS_HOST_READ_BIT");
    try constant("VK_ACCESS_HOST_WRITE_BIT");
    try constant("VK_IMAGE_ASPECT_COLOR_BIT");
    try constant("VK_FENCE_CREATE_SIGNALED_BIT");
    try constant("VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR");
    try constant("VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR");
    try constant("VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU");
    try constant("VK_QUEUE_FAMILY_IGNORED");
    try constant("VK_WHOLE_SIZE");
}
var callback_matches = false;
fn pipelineProbe(command: vk.VkCommandBuffer, src: u32, dst: u32, dependency: u32, memory_count: u32, memories: [*c]const vk.VkMemoryBarrier, buffer_count: u32, buffers: [*c]const vk.VkBufferMemoryBarrier, image_count: u32, images: [*c]const vk.VkImageMemoryBarrier) callconv(api_call) void {
    callback_matches = @intFromPtr(command) == 0x1000 and src == 0x11223344 and dst == 0x55667788 and dependency == 0x99aabbcc and memory_count == 0x10203040 and @intFromPtr(memories) == 0x2000 and buffer_count == 0x50607080 and @intFromPtr(buffers) == 0x3000 and image_count == 0x90abcdef and @intFromPtr(images) == 0x4000;
}
test "the SDK's largest used command signature calls Zig across the native C ABI" {
    callback_matches = false;
    craft_vk_abi_call_probe(pipelineProbe);
    try std.testing.expect(callback_matches);
}

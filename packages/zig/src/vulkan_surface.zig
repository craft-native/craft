//! Presentation of the shared CPU frame on an owned native Vulkan window.
//! Xlib and Win32 adapters share the same frame and resource ownership rules.
//! The Android adapter remains unavailable.
//! The caller serializes calls on the creating thread and keeps its window alive
//! until deinit succeeds. A timeout retains resources; retry disposal later.
const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan_api.zig");

pub const supported = (builtin.os.tag == .windows or (builtin.os.tag == .linux and builtin.abi != .android)) and @sizeOf(usize) == 8 and builtin.cpu.arch.endian() == .little;
pub const Error = error{ Unavailable, MissingEntryPoint, EnumerationLimit, InvalidWindow, InvalidSize, InvalidConfig, BufferLimitExceeded, AllocationFailed, WrongThread, Disposed, Suspended, InvalidFrame, DrawableUnavailable, OutOfDate, SurfaceLost, DeviceLost, GPUFailed, GPUTimeout, NoFrame };
pub const NativeWindow = union(enum) {
    xlib: struct { display: ?*anyopaque, window: usize },
    win32: struct { instance: ?*anyopaque, window: ?*anyopaque },
    android: ?*anyopaque,
};
pub const Config = struct {
    /// Actual native pixel extent; fixed surface extents take precedence.
    width: u32,
    height: u32,
    /// Sum of actual upload/readback VkDeviceMemory allocations. Driver-owned
    /// swapchain images are separately bounded by extent and image count.
    max_buffer_bytes: usize = 64 * 1024 * 1024,
    command_timeout_ms: u32 = 1000,
};
pub const Metrics = struct { width: u32 = 0, height: u32 = 0 };
pub const Layout = struct {
    bytes: usize,
    pub fn init(width: u32, height: u32, budget: usize) Error!Layout {
        if (width == 0 or height == 0 or width > 8192 or height > 8192) return error.InvalidSize;
        const pixels = std.math.mul(usize, width, height) catch return error.BufferLimitExceeded;
        const bytes = std.math.mul(usize, pixels, 4) catch return error.BufferLimitExceeded;
        if (bytes > budget / 2) return error.BufferLimitExceeded;
        return .{ .bytes = bytes };
    }
};
pub const Surface = if (supported) VulkanSurface else UnavailableSurface;
const UnavailableSurface = struct {
    pub fn init(_: NativeWindow, _: Config) Error!@This() {
        return error.Unavailable;
    }
    pub fn resize(_: *@This(), _: u32, _: u32) Error!Metrics {
        return error.Unavailable;
    }
    pub fn present(_: *@This(), _: []const u32) Error!void {
        return error.Unavailable;
    }
    pub fn readPixels(_: *@This(), _: []u32) Error!void {
        return error.Unavailable;
    }
    pub fn setSuspended(_: *@This(), _: bool) Error!void {
        return error.Unavailable;
    }
    pub fn deinit(_: *@This()) Error!void {
        return error.Unavailable;
    }
};
fn info(comptime T: type, comptime kind: u32) T {
    var value = std.mem.zeroes(T);
    value.sType = kind;
    return value;
}
fn result(code: vk.VkResult) Error!void {
    return switch (code) {
        vk.VK_SUCCESS => {},
        vk.VK_TIMEOUT, vk.VK_NOT_READY => error.GPUTimeout,
        vk.VK_INCOMPLETE => error.EnumerationLimit,
        vk.VK_ERROR_OUT_OF_DATE_KHR => error.OutOfDate,
        vk.VK_ERROR_SURFACE_LOST_KHR => error.SurfaceLost,
        vk.VK_ERROR_DEVICE_LOST => error.DeviceLost,
        vk.VK_ERROR_OUT_OF_HOST_MEMORY, vk.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.AllocationFailed,
        vk.VK_ERROR_EXTENSION_NOT_PRESENT, vk.VK_ERROR_FEATURE_NOT_PRESENT => error.Unavailable,
        else => error.GPUFailed,
    };
}
fn hasExtension(properties: []const vk.VkExtensionProperties, name: []const u8) bool {
    for (properties) |property| if (std.mem.eql(u8, std.mem.sliceTo(&property.extensionName, 0), name)) return true;
    return false;
}
// This compiler snapshot has no Windows std.DynLib adapter. Keep loader
// ownership here. Windows accepts the system loader or an application-bundled
// Vulkan loader, excluding the current directory and arbitrary PATH entries.
const Loader = struct {
    handle: if (builtin.os.tag == .windows) ?*anyopaque else std.DynLib,
    extern "kernel32" fn LoadLibraryExA([*:0]const u8, ?*anyopaque, u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(?*anyopaque) callconv(.winapi) i32;
    fn open() Error!Loader {
        if (builtin.os.tag == .windows) {
            const trusted_directories: u32 = 0x00000800 | 0x00000200;
            return .{ .handle = LoadLibraryExA("vulkan-1.dll", null, trusted_directories) orelse return error.Unavailable };
        }
        return .{ .handle = std.DynLib.open(if (builtin.abi == .android) "libvulkan.so" else "libvulkan.so.1") catch return error.Unavailable };
    }
    fn lookup(self: *Loader, comptime T: type, name: [:0]const u8) ?T {
        if (builtin.os.tag == .windows) return @ptrCast(GetProcAddress(self.handle, name.ptr));
        return self.handle.lookup(T, name);
    }
    fn close(self: *Loader) void {
        if (builtin.os.tag == .windows) {
            _ = FreeLibrary(self.handle);
        } else self.handle.close();
    }
};
const GlobalFns = struct {
    vkGetInstanceProcAddr: vk.PFN_vkGetInstanceProcAddr,
    vkEnumerateInstanceExtensionProperties: vk.PFN_vkEnumerateInstanceExtensionProperties,
    vkCreateInstance: vk.PFN_vkCreateInstance,
    vkDestroyInstance: vk.PFN_vkDestroyInstance,
    fn load(library: *Loader) Error!@This() {
        var self: @This() = undefined;
        const fields = @typeInfo(@This()).@"struct";
        inline for (fields.field_names, fields.field_types) |name, Field| @field(self, name) = library.lookup(Field, name) orelse return error.MissingEntryPoint;
        return self;
    }
};
const InstanceFns = struct {
    vkEnumeratePhysicalDevices: vk.PFN_vkEnumeratePhysicalDevices,
    vkGetPhysicalDeviceFeatures2: vk.PFN_vkGetPhysicalDeviceFeatures2,
    vkGetPhysicalDeviceQueueFamilyProperties: vk.PFN_vkGetPhysicalDeviceQueueFamilyProperties,
    vkGetPhysicalDeviceMemoryProperties: vk.PFN_vkGetPhysicalDeviceMemoryProperties,
    vkEnumerateDeviceExtensionProperties: vk.PFN_vkEnumerateDeviceExtensionProperties,
    vkCreateDevice: vk.PFN_vkCreateDevice,
    vkDestroySurfaceKHR: vk.PFN_vkDestroySurfaceKHR,
    vkGetPhysicalDeviceSurfaceSupportKHR: vk.PFN_vkGetPhysicalDeviceSurfaceSupportKHR,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: vk.PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR,
    vkGetPhysicalDeviceSurfaceFormatsKHR: vk.PFN_vkGetPhysicalDeviceSurfaceFormatsKHR,
};
const PlatformFns = if (builtin.os.tag == .windows) struct {
    vkCreateWin32SurfaceKHR: vk.PFN_vkCreateWin32SurfaceKHR,
} else struct {
    vkCreateXlibSurfaceKHR: vk.PFN_vkCreateXlibSurfaceKHR,
};
const DeviceFns = struct {
    vkDestroyDevice: vk.PFN_vkDestroyDevice,
    vkGetDeviceQueue: vk.PFN_vkGetDeviceQueue,
    vkCreateSwapchainKHR: vk.PFN_vkCreateSwapchainKHR,
    vkDestroySwapchainKHR: vk.PFN_vkDestroySwapchainKHR,
    vkGetSwapchainImagesKHR: vk.PFN_vkGetSwapchainImagesKHR,
    vkAcquireNextImageKHR: vk.PFN_vkAcquireNextImageKHR,
    vkCreateSemaphore: vk.PFN_vkCreateSemaphore,
    vkDestroySemaphore: vk.PFN_vkDestroySemaphore,
    vkCreateFence: vk.PFN_vkCreateFence,
    vkDestroyFence: vk.PFN_vkDestroyFence,
    vkWaitForFences: vk.PFN_vkWaitForFences,
    vkResetFences: vk.PFN_vkResetFences,
    vkCreateBuffer: vk.PFN_vkCreateBuffer,
    vkDestroyBuffer: vk.PFN_vkDestroyBuffer,
    vkGetBufferMemoryRequirements: vk.PFN_vkGetBufferMemoryRequirements,
    vkAllocateMemory: vk.PFN_vkAllocateMemory,
    vkFreeMemory: vk.PFN_vkFreeMemory,
    vkBindBufferMemory: vk.PFN_vkBindBufferMemory,
    vkMapMemory: vk.PFN_vkMapMemory,
    vkUnmapMemory: vk.PFN_vkUnmapMemory,
    vkFlushMappedMemoryRanges: vk.PFN_vkFlushMappedMemoryRanges,
    vkInvalidateMappedMemoryRanges: vk.PFN_vkInvalidateMappedMemoryRanges,
    vkCreateCommandPool: vk.PFN_vkCreateCommandPool,
    vkDestroyCommandPool: vk.PFN_vkDestroyCommandPool,
    vkAllocateCommandBuffers: vk.PFN_vkAllocateCommandBuffers,
    vkResetCommandBuffer: vk.PFN_vkResetCommandBuffer,
    vkBeginCommandBuffer: vk.PFN_vkBeginCommandBuffer,
    vkEndCommandBuffer: vk.PFN_vkEndCommandBuffer,
    vkCmdPipelineBarrier: vk.PFN_vkCmdPipelineBarrier,
    vkCmdCopyBufferToImage: vk.PFN_vkCmdCopyBufferToImage,
    vkCmdCopyImageToBuffer: vk.PFN_vkCmdCopyImageToBuffer,
    vkQueueSubmit: vk.PFN_vkQueueSubmit,
    vkQueuePresentKHR: vk.PFN_vkQueuePresentKHR,
};
fn loadInstance(comptime T: type, get: vk.PFN_vkGetInstanceProcAddr, instance: vk.VkInstance) Error!T {
    var value: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names) |name| @field(value, name) = @ptrCast(get(instance, name.ptr) orelse return error.MissingEntryPoint);
    return value;
}
const Buffer = struct { handle: vk.VkBuffer = null, memory: vk.VkDeviceMemory = null, mapped: ?*anyopaque = null, allocation_bytes: u64 = 0, coherent: bool = false };
const max_images = 8;
const VulkanSurface = struct {
    library: ?Loader = null,
    global: GlobalFns = undefined,
    functions: InstanceFns = undefined,
    platform_functions: PlatformFns = undefined,
    device_functions: DeviceFns = undefined,
    instance: vk.VkInstance = null,
    surface: vk.VkSurfaceKHR = null,
    physical: vk.VkPhysicalDevice = null,
    device: vk.VkDevice = null,
    queue: vk.VkQueue = null,
    queue_family: u32 = 0,
    config: Config,
    khr_maintenance: bool = false,
    ext_maintenance: bool = false,
    owner: std.Thread.Id,
    memory: vk.VkPhysicalDeviceMemoryProperties = undefined,
    metrics: Metrics = .{},
    format: vk.VkFormat = vk.VK_FORMAT_B8G8R8A8_UNORM,
    swapchain: vk.VkSwapchainKHR = null,
    images: [max_images]vk.VkImage = @splat(null),
    image_count: u32 = 0,
    upload: Buffer = .{},
    readback: Buffer = .{},
    pool: vk.VkCommandPool = null,
    command: vk.VkCommandBuffer = null,
    acquired: vk.VkFence = null,
    submitted: vk.VkFence = null,
    presented: vk.VkFence = null,
    ready: vk.VkSemaphore = null,
    pending_acquire: bool = false,
    pending_submit: bool = false,
    pending_present: bool = false,
    device_lost: bool = false,
    needs_resize: bool = false,
    suspended: bool = false,
    disposed: bool = false,
    has_frame: bool = false,

    pub fn init(window: NativeWindow, config: Config) Error!VulkanSurface {
        _ = try Layout.init(config.width, config.height, config.max_buffer_bytes);
        if (config.command_timeout_ms == 0 or config.command_timeout_ms > 5000) return error.InvalidConfig;
        try validateWindow(window);
        var self: VulkanSurface = .{ .config = config, .owner = std.Thread.getCurrentId() };
        errdefer self.destroyInitial();
        self.library = try Loader.open();
        self.global = try GlobalFns.load(&self.library.?);
        var extensions: [256]vk.VkExtensionProperties = undefined;
        var count: u32 = extensions.len;
        try result(self.global.vkEnumerateInstanceExtensionProperties(null, &count, &extensions));
        if (count > extensions.len) return error.EnumerationLimit;
        var names: [5][*c]const u8 = undefined;
        const platform_extension = if (builtin.os.tag == .windows) vk.VK_KHR_WIN32_SURFACE_EXTENSION_NAME else vk.VK_KHR_XLIB_SURFACE_EXTENSION_NAME;
        const required = [_][*c]const u8{ vk.VK_KHR_SURFACE_EXTENSION_NAME, platform_extension, vk.VK_KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME };
        for (required, 0..) |name, index| {
            if (!hasExtension(extensions[0..count], std.mem.span(name))) return error.Unavailable;
            names[index] = name;
        }
        var name_count: u32 = required.len;
        self.khr_maintenance = hasExtension(extensions[0..count], vk.VK_KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME);
        self.ext_maintenance = hasExtension(extensions[0..count], vk.VK_EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME);
        if (!self.khr_maintenance and !self.ext_maintenance) return error.Unavailable;
        if (self.khr_maintenance) {
            names[name_count] = vk.VK_KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME;
            name_count += 1;
        }
        if (self.ext_maintenance) {
            names[name_count] = vk.VK_EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME;
            name_count += 1;
        }
        var app = info(vk.VkApplicationInfo, vk.VK_STRUCTURE_TYPE_APPLICATION_INFO);
        app.pApplicationName = "Craft native surface";
        app.apiVersion = (1 << 22) | (1 << 12); // Vulkan1.1 provides features2.
        var instance_info = info(vk.VkInstanceCreateInfo, vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO);
        instance_info.pApplicationInfo = &app;
        instance_info.enabledExtensionCount = name_count;
        instance_info.ppEnabledExtensionNames = &names;
        try result(self.global.vkCreateInstance(&instance_info, null, &self.instance));
        self.functions = try loadInstance(InstanceFns, self.global.vkGetInstanceProcAddr, self.instance);
        self.platform_functions = try loadInstance(PlatformFns, self.global.vkGetInstanceProcAddr, self.instance);
        // Resolve all device operations before creating a device, so every
        // successfully created object always has its destruction operation.
        self.device_functions = try loadInstance(DeviceFns, self.global.vkGetInstanceProcAddr, self.instance);
        try self.createNativeSurface(window);
        try self.selectDevice();
        try self.createSwapchain(config.width, config.height);
        return self;
    }

    fn validateWindow(window: NativeWindow) Error!void {
        if (builtin.os.tag == .windows) {
            const native = switch (window) {
                .win32 => |value| value,
                else => return error.Unavailable,
            };
            if (native.instance == null or native.window == null) return error.InvalidWindow;
        } else {
            const native = switch (window) {
                .xlib => |value| value,
                else => return error.Unavailable,
            };
            if (native.display == null or native.window == 0) return error.InvalidWindow;
        }
    }

    fn createNativeSurface(self: *VulkanSurface, window: NativeWindow) Error!void {
        if (builtin.os.tag == .windows) {
            var native = info(vk.VkWin32SurfaceCreateInfoKHR, vk.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR);
            native.hinstance = window.win32.instance;
            native.hwnd = window.win32.window;
            try result(self.platform_functions.vkCreateWin32SurfaceKHR(self.instance, &native, null, &self.surface));
        } else {
            var native = info(vk.VkXlibSurfaceCreateInfoKHR, vk.VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR);
            native.dpy = @ptrCast(window.xlib.display);
            native.window = @intCast(window.xlib.window);
            try result(self.platform_functions.vkCreateXlibSurfaceKHR(self.instance, &native, null, &self.surface));
        }
    }

    fn selectDevice(self: *VulkanSurface) Error!void {
        var devices: [16]vk.VkPhysicalDevice = undefined;
        var count: u32 = devices.len;
        try result(self.functions.vkEnumeratePhysicalDevices(self.instance, &count, &devices));
        if (count > devices.len) return error.EnumerationLimit;
        for (devices[0..count]) |physical| {
            var properties: [256]vk.VkExtensionProperties = undefined;
            var property_count: u32 = properties.len;
            try result(self.functions.vkEnumerateDeviceExtensionProperties(physical, null, &property_count, &properties));
            if (property_count > properties.len) return error.EnumerationLimit;
            if (!hasExtension(properties[0..property_count], vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME)) continue;
            const maintenance_name: [*c]const u8 = if (self.khr_maintenance and hasExtension(properties[0..property_count], vk.VK_KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME)) vk.VK_KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME else if (self.ext_maintenance and hasExtension(properties[0..property_count], vk.VK_EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME)) vk.VK_EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME else continue;
            const names = [_][*c]const u8{ vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME, maintenance_name };
            var maintenance = info(vk.VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT, vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT);
            var features = info(vk.VkPhysicalDeviceFeatures2, vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2);
            features.pNext = &maintenance;
            self.functions.vkGetPhysicalDeviceFeatures2(physical, &features);
            if (maintenance.swapchainMaintenance1 == 0) continue;
            var families: [64]vk.VkQueueFamilyProperties = undefined;
            var family_count: u32 = 0;
            self.functions.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, null);
            if (family_count > families.len) return error.EnumerationLimit;
            self.functions.vkGetPhysicalDeviceQueueFamilyProperties(physical, &family_count, &families);
            for (families[0..family_count], 0..) |family, index| {
                if (family.queueCount == 0 or family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT == 0) continue;
                var present_support: u32 = 0;
                try result(self.functions.vkGetPhysicalDeviceSurfaceSupportKHR(physical, @intCast(index), self.surface, &present_support));
                if (present_support == 0) continue;
                const priority: f32 = 1;
                var queue_info = info(vk.VkDeviceQueueCreateInfo, vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO);
                queue_info.queueFamilyIndex = @intCast(index);
                queue_info.queueCount = 1;
                queue_info.pQueuePriorities = &priority;
                var device_info = info(vk.VkDeviceCreateInfo, vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO);
                device_info.pNext = &maintenance;
                device_info.queueCreateInfoCount = 1;
                device_info.pQueueCreateInfos = &queue_info;
                device_info.enabledExtensionCount = names.len;
                device_info.ppEnabledExtensionNames = &names;
                try result(self.functions.vkCreateDevice(physical, &device_info, null, &self.device));
                self.physical = physical;
                self.queue_family = @intCast(index);
                self.device_functions.vkGetDeviceQueue(self.device, self.queue_family, 0, &self.queue);
                self.functions.vkGetPhysicalDeviceMemoryProperties(physical, &self.memory);
                return;
            }
        }
        return error.Unavailable;
    }

    fn createBuffer(self: *VulkanSurface, buffer: *Buffer, bytes: usize, usage: u32, remaining: usize) Error!void {
        var buffer_info = info(vk.VkBufferCreateInfo, vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO);
        buffer_info.size = bytes;
        buffer_info.usage = usage;
        buffer_info.sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
        try result(self.device_functions.vkCreateBuffer(self.device, &buffer_info, null, &buffer.handle));
        var requirements: vk.VkMemoryRequirements = undefined;
        self.device_functions.vkGetBufferMemoryRequirements(self.device, buffer.handle, &requirements);
        if (requirements.size < bytes) return error.GPUFailed;
        if (requirements.size > remaining) return error.BufferLimitExceeded;
        var memory_type: ?u32 = null;
        for (0..@min(self.memory.memoryTypeCount, 32)) |index| {
            const flags = self.memory.memoryTypes[index].propertyFlags;
            if (requirements.memoryTypeBits & (@as(u32, 1) << @intCast(index)) == 0 or flags & vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT == 0) continue;
            memory_type = @intCast(index);
            buffer.coherent = flags & vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT != 0;
            if (buffer.coherent) break;
        }
        var allocate = info(vk.VkMemoryAllocateInfo, vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO);
        allocate.allocationSize = requirements.size;
        allocate.memoryTypeIndex = memory_type orelse return error.Unavailable;
        try result(self.device_functions.vkAllocateMemory(self.device, &allocate, null, &buffer.memory));
        buffer.allocation_bytes = requirements.size;
        try result(self.device_functions.vkBindBufferMemory(self.device, buffer.handle, buffer.memory, 0));
        try result(self.device_functions.vkMapMemory(self.device, buffer.memory, 0, vk.VK_WHOLE_SIZE, 0, &buffer.mapped));
    }

    fn createSwapchain(self: *VulkanSurface, width: u32, height: u32) Error!void {
        errdefer self.destroyFrameResources();
        var capabilities: vk.VkSurfaceCapabilitiesKHR = undefined;
        try result(self.functions.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical, self.surface, &capabilities));
        const extent = if (capabilities.currentExtent.width != std.math.maxInt(u32)) capabilities.currentExtent else vk.VkExtent2D{ .width = std.math.clamp(width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width), .height = std.math.clamp(height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height) };
        const layout = try Layout.init(extent.width, extent.height, self.config.max_buffer_bytes);
        const usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        if (capabilities.supportedUsageFlags & usage != usage) return error.Unavailable;
        var formats: [64]vk.VkSurfaceFormatKHR = undefined;
        var count: u32 = formats.len;
        try result(self.functions.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical, self.surface, &count, &formats));
        if (count > formats.len) return error.EnumerationLimit;
        var selected: ?vk.VkSurfaceFormatKHR = null;
        for (formats[0..count]) |format| {
            if (format.colorSpace != vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) continue;
            if (format.format != vk.VK_FORMAT_B8G8R8A8_UNORM and format.format != vk.VK_FORMAT_R8G8B8A8_UNORM) continue;
            selected = format;
            if (format.format == vk.VK_FORMAT_B8G8R8A8_UNORM) break;
        }
        const format = selected orelse return error.Unavailable;
        const image_count = @max(capabilities.minImageCount, 2);
        if (image_count > max_images or (capabilities.maxImageCount != 0 and image_count > capabilities.maxImageCount)) return error.Unavailable;
        const alpha: u32 = if (capabilities.supportedCompositeAlpha & vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR != 0) vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR else if (capabilities.supportedCompositeAlpha & vk.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR != 0) vk.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR else return error.Unavailable;
        var swap_info = info(vk.VkSwapchainCreateInfoKHR, vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR);
        swap_info.surface = self.surface;
        swap_info.minImageCount = image_count;
        swap_info.imageFormat = format.format;
        swap_info.imageColorSpace = format.colorSpace;
        swap_info.imageExtent = extent;
        swap_info.imageArrayLayers = 1;
        swap_info.imageUsage = usage;
        swap_info.imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
        swap_info.preTransform = capabilities.currentTransform;
        swap_info.compositeAlpha = alpha;
        swap_info.presentMode = vk.VK_PRESENT_MODE_FIFO_KHR;
        swap_info.clipped = 1;
        try result(self.device_functions.vkCreateSwapchainKHR(self.device, &swap_info, null, &self.swapchain));
        self.image_count = max_images;
        try result(self.device_functions.vkGetSwapchainImagesKHR(self.device, self.swapchain, &self.image_count, &self.images));
        if (self.image_count == 0 or self.image_count > max_images) return error.EnumerationLimit;
        try self.createBuffer(&self.upload, layout.bytes, vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, self.config.max_buffer_bytes);
        try self.createBuffer(&self.readback, layout.bytes, vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT, self.config.max_buffer_bytes - @as(usize, @intCast(self.upload.allocation_bytes)));
        var pool_info = info(vk.VkCommandPoolCreateInfo, vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO);
        pool_info.queueFamilyIndex = self.queue_family;
        pool_info.flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        try result(self.device_functions.vkCreateCommandPool(self.device, &pool_info, null, &self.pool));
        var allocate = info(vk.VkCommandBufferAllocateInfo, vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO);
        allocate.commandPool = self.pool;
        allocate.level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocate.commandBufferCount = 1;
        try result(self.device_functions.vkAllocateCommandBuffers(self.device, &allocate, &self.command));
        const fence_info = info(vk.VkFenceCreateInfo, vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO);
        for ([_]*vk.VkFence{ &self.acquired, &self.submitted, &self.presented }) |fence| try result(self.device_functions.vkCreateFence(self.device, &fence_info, null, fence));
        const semaphore_info = info(vk.VkSemaphoreCreateInfo, vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO);
        try result(self.device_functions.vkCreateSemaphore(self.device, &semaphore_info, null, &self.ready));
        self.metrics = .{ .width = extent.width, .height = extent.height };
        self.format = format.format;
        self.needs_resize = false;
    }

    fn check(self: *VulkanSurface) Error!void {
        if (self.disposed) return error.Disposed;
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        if (self.device_lost) return error.DeviceLost;
    }
    fn wait(self: *VulkanSurface, fence: vk.VkFence, pending: *bool) Error!void {
        if (!pending.*) return;
        const code = self.device_functions.vkWaitForFences(self.device, 1, &fence, 1, @as(u64, self.config.command_timeout_ms) * std.time.ns_per_ms);
        if (code == vk.VK_ERROR_DEVICE_LOST) {
            self.device_lost = true;
            pending.* = false;
            return error.DeviceLost;
        }
        try result(code);
        pending.* = false;
    }
    fn drain(self: *VulkanSurface) Error!void {
        if (self.device_lost) return;
        try self.wait(self.acquired, &self.pending_acquire);
        try self.wait(self.submitted, &self.pending_submit);
        try self.wait(self.presented, &self.pending_present);
    }
    pub fn resize(self: *VulkanSurface, width: u32, height: u32) Error!Metrics {
        try self.check();
        _ = try Layout.init(width, height, self.config.max_buffer_bytes);
        try self.drain();
        self.destroyFrameResources();
        try self.createSwapchain(width, height);
        return self.metrics;
    }
    pub fn setSuspended(self: *VulkanSurface, suspended: bool) Error!void {
        try self.check();
        self.suspended = suspended;
    }
    pub fn present(self: *VulkanSurface, pixels: []const u32) Error!void {
        try self.check();
        if (self.suspended) return error.Suspended;
        if (self.swapchain == null or self.needs_resize) return error.OutOfDate;
        const length = @as(usize, self.metrics.width) * self.metrics.height;
        if (pixels.len != length) return error.InvalidFrame;
        for (pixels) |pixel| if (pixel >> 24 != 255) return error.InvalidFrame;
        try self.drain();
        const destination: [*]u32 = @ptrCast(@alignCast(self.upload.mapped.?));
        for (pixels, 0..) |pixel, index| destination[index] = if (self.format == vk.VK_FORMAT_R8G8B8A8_UNORM) swapRedBlue(pixel) else pixel;
        if (!self.upload.coherent) {
            var range = info(vk.VkMappedMemoryRange, vk.VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE);
            range.memory = self.upload.memory;
            range.size = vk.VK_WHOLE_SIZE;
            try result(self.device_functions.vkFlushMappedMemoryRanges(self.device, 1, &range));
        }
        try result(self.device_functions.vkResetFences(self.device, 1, &self.acquired));
        var index: u32 = 0;
        const acquire = self.device_functions.vkAcquireNextImageKHR(self.device, self.swapchain, @as(u64, self.config.command_timeout_ms) * std.time.ns_per_ms, null, self.acquired, &index);
        if (acquire == vk.VK_TIMEOUT or acquire == vk.VK_NOT_READY) return error.DrawableUnavailable;
        if (acquire != vk.VK_SUCCESS and acquire != vk.VK_SUBOPTIMAL_KHR) {
            if (acquire == vk.VK_ERROR_DEVICE_LOST) self.device_lost = true;
            return result(acquire);
        }
        self.pending_acquire = true;
        self.needs_resize = true; // An acquired image must be presented or retired.
        try self.wait(self.acquired, &self.pending_acquire);
        if (index >= self.image_count) return error.GPUFailed;
        try self.record(self.images[index]);
        try result(self.device_functions.vkResetFences(self.device, 1, &self.submitted));
        try result(self.device_functions.vkResetFences(self.device, 1, &self.presented));
        var submit = info(vk.VkSubmitInfo, vk.VK_STRUCTURE_TYPE_SUBMIT_INFO);
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &self.command;
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores = &self.ready;
        const submitted = self.device_functions.vkQueueSubmit(self.queue, 1, &submit, self.submitted);
        if (submitted == vk.VK_ERROR_DEVICE_LOST) self.device_lost = true;
        try result(submitted);
        self.pending_submit = true;
        self.has_frame = false;
        var completion = info(vk.VkSwapchainPresentFenceInfoEXT, vk.VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT);
        completion.swapchainCount = 1;
        completion.pFences = &self.presented;
        var present_info = info(vk.VkPresentInfoKHR, vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR);
        present_info.pNext = &completion;
        present_info.waitSemaphoreCount = 1;
        present_info.pWaitSemaphores = &self.ready;
        present_info.swapchainCount = 1;
        present_info.pSwapchains = &self.swapchain;
        present_info.pImageIndices = &index;
        const presented = self.device_functions.vkQueuePresentKHR(self.queue, &present_info);
        // Out-of-date and surface-lost presents still enqueue their waits.
        // Only allocation failure guarantees that no present work was queued.
        self.pending_present = presented != vk.VK_ERROR_OUT_OF_HOST_MEMORY and presented != vk.VK_ERROR_OUT_OF_DEVICE_MEMORY and presented != vk.VK_ERROR_DEVICE_LOST;
        if (presented == vk.VK_ERROR_DEVICE_LOST) {
            self.device_lost = true;
            return error.DeviceLost;
        }
        try self.drain();
        if (presented != vk.VK_SUCCESS and presented != vk.VK_SUBOPTIMAL_KHR) return result(presented);
        self.needs_resize = acquire == vk.VK_SUBOPTIMAL_KHR or presented == vk.VK_SUBOPTIMAL_KHR;
        self.has_frame = true;
    }
    fn record(self: *VulkanSurface, image: vk.VkImage) Error!void {
        try result(self.device_functions.vkResetCommandBuffer(self.command, 0));
        var begin = info(vk.VkCommandBufferBeginInfo, vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO);
        begin.flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try result(self.device_functions.vkBeginCommandBuffer(self.command, &begin));
        const subresource: vk.VkImageSubresourceRange = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        var barrier = info(vk.VkImageMemoryBarrier, vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER);
        barrier.srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange = subresource;
        barrier.oldLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
        self.device_functions.vkCmdPipelineBarrier(self.command, vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);
        const copy: vk.VkBufferImageCopy = .{ .bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0, .imageSubresource = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 }, .imageOffset = .{ .x = 0, .y = 0, .z = 0 }, .imageExtent = .{ .width = self.metrics.width, .height = self.metrics.height, .depth = 1 } };
        self.device_functions.vkCmdCopyBufferToImage(self.command, self.upload.handle, image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        barrier.oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = vk.VK_ACCESS_TRANSFER_READ_BIT;
        self.device_functions.vkCmdPipelineBarrier(self.command, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);
        self.device_functions.vkCmdCopyImageToBuffer(self.command, image, vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.readback.handle, 1, &copy);
        barrier.oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.newLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        barrier.srcAccessMask = vk.VK_ACCESS_TRANSFER_READ_BIT;
        barrier.dstAccessMask = 0;
        self.device_functions.vkCmdPipelineBarrier(self.command, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 1, &barrier);
        var host = info(vk.VkBufferMemoryBarrier, vk.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER);
        host.srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
        host.dstAccessMask = vk.VK_ACCESS_HOST_READ_BIT;
        host.srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED;
        host.dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED;
        host.buffer = self.readback.handle;
        host.size = vk.VK_WHOLE_SIZE;
        self.device_functions.vkCmdPipelineBarrier(self.command, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_HOST_BIT, 0, 0, null, 1, &host, 0, null);
        try result(self.device_functions.vkEndCommandBuffer(self.command));
    }
    pub fn readPixels(self: *VulkanSurface, destination: []u32) Error!void {
        try self.check();
        if (!self.has_frame) return error.NoFrame;
        const length = @as(usize, self.metrics.width) * self.metrics.height;
        if (destination.len != length) return error.InvalidFrame;
        if (!self.readback.coherent) {
            var range = info(vk.VkMappedMemoryRange, vk.VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE);
            range.memory = self.readback.memory;
            range.size = vk.VK_WHOLE_SIZE;
            try result(self.device_functions.vkInvalidateMappedMemoryRanges(self.device, 1, &range));
        }
        const source: [*]const u32 = @ptrCast(@alignCast(self.readback.mapped.?));
        for (destination, 0..) |*pixel, index| pixel.* = if (self.format == vk.VK_FORMAT_R8G8B8A8_UNORM) swapRedBlue(source[index]) else source[index];
    }
    fn destroyBuffer(self: *VulkanSurface, buffer: *Buffer) void {
        if (buffer.mapped != null) self.device_functions.vkUnmapMemory(self.device, buffer.memory);
        if (buffer.handle != null) self.device_functions.vkDestroyBuffer(self.device, buffer.handle, null);
        if (buffer.memory != null) self.device_functions.vkFreeMemory(self.device, buffer.memory, null);
        buffer.* = .{};
    }
    fn destroyFrameResources(self: *VulkanSurface) void {
        if (self.device == null) return;
        for ([_]vk.VkFence{ self.acquired, self.submitted, self.presented }) |fence| if (fence != null) self.device_functions.vkDestroyFence(self.device, fence, null);
        self.acquired = null;
        self.submitted = null;
        self.presented = null;
        if (self.ready != null) self.device_functions.vkDestroySemaphore(self.device, self.ready, null);
        self.ready = null;
        if (self.pool != null) self.device_functions.vkDestroyCommandPool(self.device, self.pool, null);
        self.pool = null;
        self.command = null;
        self.destroyBuffer(&self.upload);
        self.destroyBuffer(&self.readback);
        if (self.swapchain != null) self.device_functions.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.swapchain = null;
        self.image_count = 0;
        self.metrics = .{};
        self.has_frame = false;
        self.needs_resize = true;
    }
    // Initialization never submits work, so partial allocations can be released.
    fn destroyInitial(self: *VulkanSurface) void {
        self.destroyFrameResources();
        if (self.device != null) self.device_functions.vkDestroyDevice(self.device, null);
        self.device = null;
        if (self.surface != null) self.functions.vkDestroySurfaceKHR(self.instance, self.surface, null);
        self.surface = null;
        if (self.instance != null) self.global.vkDestroyInstance(self.instance, null);
        self.instance = null;
        if (self.library) |*library| library.close();
        self.library = null;
    }
    pub fn deinit(self: *VulkanSurface) Error!void {
        if (self.disposed) return error.Disposed;
        if (self.owner != std.Thread.getCurrentId()) return error.WrongThread;
        // No device-idle substitution: presentation owns objects after the
        // render submission completes. Keep them if its fence has not signaled.
        self.drain() catch |err| if (err != error.DeviceLost) return err;
        self.destroyInitial();
        self.disposed = true;
    }
};
fn swapRedBlue(pixel: u32) u32 {
    return (pixel & 0xff00ff00) | ((pixel & 0x00ff0000) >> 16) | ((pixel & 0x000000ff) << 16);
}

test "Vulkan layout validates the actual two staging buffers before driver calls" {
    try std.testing.expectEqual(@as(usize, 256 * 192 * 4), (try Layout.init(256, 192, 256 * 192 * 8)).bytes);
    try std.testing.expectError(error.BufferLimitExceeded, Layout.init(256, 192, 256 * 192 * 8 - 1));
    try std.testing.expectError(error.InvalidSize, Layout.init(0, 192, std.math.maxInt(usize)));
    try std.testing.expectError(error.InvalidSize, Layout.init(8193, 1, std.math.maxInt(usize)));
}
test "Vulkan RGBA conversion preserves alpha and reverses without pixel loss" {
    for ([_]u32{ 0xffe02040, 0xff20c060, 0xff2040e0, 0xffd0a020 }) |pixel| try std.testing.expectEqual(pixel, swapRedBlue(swapRedBlue(pixel)));
    try std.testing.expectEqual(@as(u32, 0xff4020e0), swapRedBlue(0xffe02040));
}
test "Vulkan failures never become successful presentation" {
    try std.testing.expectError(error.OutOfDate, result(vk.VK_ERROR_OUT_OF_DATE_KHR));
    try std.testing.expectError(error.SurfaceLost, result(vk.VK_ERROR_SURFACE_LOST_KHR));
    try std.testing.expectError(error.DeviceLost, result(vk.VK_ERROR_DEVICE_LOST));
    try std.testing.expectError(error.GPUTimeout, result(vk.VK_TIMEOUT));
    try std.testing.expectError(error.AllocationFailed, result(-2));
}

// These dispatch probes exercise the production ownership methods. They do not
// stand in for Vulkan pixel or window acceptance, which requires a real driver.
const DisposalProbe = struct {
    const native_call: std.builtin.CallingConvention = if (builtin.os.tag == .windows) .winapi else .c;
    var wait_code: vk.VkResult = vk.VK_TIMEOUT;
    var waits: usize = 0;
    var destroyed: usize = 0;
    fn wait(_: vk.VkDevice, _: u32, _: [*c]const vk.VkFence, _: u32, _: u64) callconv(native_call) vk.VkResult {
        waits += 1;
        return wait_code;
    }
    fn fence(_: vk.VkDevice, _: vk.VkFence, _: ?*const vk.VkAllocationCallbacks) callconv(native_call) void {
        destroyed += 1;
    }
    fn swapchain(_: vk.VkDevice, _: vk.VkSwapchainKHR, _: ?*const vk.VkAllocationCallbacks) callconv(native_call) void {
        destroyed += 1;
    }
    fn device(_: vk.VkDevice, _: ?*const vk.VkAllocationCallbacks) callconv(native_call) void {
        destroyed += 1;
    }
    fn surface() VulkanSurface {
        wait_code = vk.VK_TIMEOUT;
        waits = 0;
        destroyed = 0;
        var value: VulkanSurface = .{ .config = .{ .width = 1, .height = 1 }, .owner = std.Thread.getCurrentId() };
        value.device = @ptrFromInt(1);
        value.presented = @ptrFromInt(2);
        value.swapchain = @ptrFromInt(3);
        value.metrics = .{ .width = 1, .height = 1 };
        value.pending_present = true;
        // This probe owns only one fence, one swapchain and one device. It never
        // creates or submits work and never accesses the other dispatch fields.
        value.device_functions.vkWaitForFences = &wait;
        value.device_functions.vkDestroyFence = &fence;
        value.device_functions.vkDestroySwapchainKHR = &swapchain;
        value.device_functions.vkDestroyDevice = &device;
        return value;
    }
};
test "render completion cannot substitute for outstanding presentation disposal" {
    var surface = DisposalProbe.surface();
    try std.testing.expectError(error.GPUTimeout, surface.deinit());
    try std.testing.expectEqual(@as(usize, 1), DisposalProbe.waits);
    try std.testing.expectEqual(@as(usize, 0), DisposalProbe.destroyed);
    try std.testing.expect(surface.device != null and surface.swapchain != null and surface.pending_present and !surface.disposed);
    DisposalProbe.wait_code = vk.VK_SUCCESS;
    try surface.deinit();
    try std.testing.expectEqual(@as(usize, 3), DisposalProbe.destroyed);
    try std.testing.expect(surface.disposed and surface.device == null and surface.swapchain == null);
    try std.testing.expectError(error.Disposed, surface.deinit());
    try std.testing.expectEqual(@as(usize, 3), DisposalProbe.destroyed);
}
test "timed out resize retains the existing native resources and their extent" {
    var surface = DisposalProbe.surface();
    try std.testing.expectError(error.GPUTimeout, surface.resize(160, 120));
    try std.testing.expectEqual(@as(usize, 0), DisposalProbe.destroyed);
    try std.testing.expectEqual(@as(u32, 1), surface.metrics.width);
    try std.testing.expectEqual(@as(u32, 1), surface.metrics.height);
    try std.testing.expect(surface.pending_present and surface.swapchain != null);
    DisposalProbe.wait_code = vk.VK_SUCCESS;
    try surface.deinit();
}
test "device loss permits owned teardown while timeouts retain ownership" {
    var surface = DisposalProbe.surface();
    DisposalProbe.wait_code = vk.VK_ERROR_DEVICE_LOST;
    try surface.deinit();
    try std.testing.expect(surface.device_lost and surface.disposed);
    try std.testing.expectEqual(@as(usize, 3), DisposalProbe.destroyed);
}
test "a foreign thread cannot wait on or release the creating thread's resources" {
    var surface = DisposalProbe.surface();
    surface.owner += 1;
    try std.testing.expectError(error.WrongThread, surface.deinit());
    try std.testing.expectEqual(@as(usize, 0), DisposalProbe.waits);
    try std.testing.expectEqual(@as(usize, 0), DisposalProbe.destroyed);
    surface.owner = std.Thread.getCurrentId();
    DisposalProbe.wait_code = vk.VK_SUCCESS;
    try surface.deinit();
}
test "invalid frames and suspension do not touch queues or the last retained frame" {
    var surface = DisposalProbe.surface();
    surface.has_frame = true;
    try std.testing.expectError(error.InvalidFrame, surface.present(&.{}));
    try std.testing.expectError(error.InvalidFrame, surface.present(&.{0x80ffffff}));
    try surface.setSuspended(true);
    try std.testing.expectError(error.Suspended, surface.present(&.{0xffffffff}));
    try std.testing.expect(surface.has_frame and surface.pending_present);
    try std.testing.expectEqual(@as(usize, 0), DisposalProbe.waits);
    try std.testing.expectEqual(@as(usize, 0), DisposalProbe.destroyed);
    try surface.setSuspended(false);
    surface.needs_resize = true;
    try std.testing.expectError(error.OutOfDate, surface.present(&.{0xffffffff}));
    DisposalProbe.wait_code = vk.VK_SUCCESS;
    try surface.deinit();
}
test "invalid native configuration fails before opening a driver" {
    try std.testing.expectError(error.InvalidSize, VulkanSurface.init(.{ .xlib = .{ .display = null, .window = 0 } }, .{ .width = 0, .height = 1 }));
    try std.testing.expectError(error.InvalidConfig, VulkanSurface.init(.{ .xlib = .{ .display = null, .window = 0 } }, .{ .width = 1, .height = 1, .command_timeout_ms = 0 }));
    const invalid: NativeWindow = if (builtin.os.tag == .windows) .{ .win32 = .{ .instance = null, .window = null } } else .{ .xlib = .{ .display = null, .window = 0 } };
    try std.testing.expectError(error.InvalidWindow, VulkanSurface.init(invalid, .{ .width = 1, .height = 1 }));
    try std.testing.expectError(error.Unavailable, VulkanSurface.init(.{ .android = null }, .{ .width = 1, .height = 1 }));
}

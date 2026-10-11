/// libmpv 原生内核加载状态标记。
///
/// Android API 24-27 的系统 Vulkan loader 仅导出 1.0 符号，当前 libmpv
/// 构建链入了 Vulkan 1.1 符号（vkGetPhysicalDeviceProperties2 等），
/// 在这些设备上 dlopen 失败。main 捕获 MediaKit.ensureInitialized 的
/// 异常后置位本标记，应用继续启动（浏览等功能可用）；播放路径据此
/// 给出明确的降级提示，而不是静默失败。
bool mediaKitLoadFailed = false;

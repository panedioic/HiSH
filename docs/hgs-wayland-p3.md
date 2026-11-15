# HiSH Wayland P3 可行性验证

用 Waypipe 0.9.2 的源码做了 ARM64 OHOS SDK 交叉编译验证。此版本用于确认
C 实现和工具链的兼容性，集成版本待选定。最小构建关闭了 DMA-BUF、视频、压缩和
security-context 功能，产出了可执行文件和只依赖 OHOS `libc.so` 的共享库。
共享库将 `main` 改名为 `hish_waypipe_main`，用于后续验证原生子进程入口。

采用共享内存路径时，来宾中的 Waypipe server 提供应用的本地 Wayland socket。
宿主的 Waypipe client 连接 HGS。两端通过单一字节流复制缓冲区和文件描述符对应的
资源。所需的是 Waypipe 协议传输，现有 X11 字节转发无法直接连接 Wayland 应用与 HGS。
参见 [Waypipe 源码的运行说明](https://sources.debian.org/src/waypipe/0.9.2-1/waypipe.scd)。

下一步先验证 OHOS 原生子进程能调用共享库入口，测试 `memfd_create`、
`SCM_RIGHTS` 和子进程退出。首个探针用非重连的单连接模式，验证
`wl_shm` 首帧与键盘输入。Waypipe 的常驻 client 路径会为连接调用
`fork()`，需要按 OHOS 沙箱能力单独验证。来宾进程仍由 HiSH 管理。当前验证只涉及
交叉编译和 ELF 依赖检查，Wayland 代理尚未接入 HAP。

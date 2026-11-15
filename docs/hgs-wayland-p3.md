# HiSH Wayland P3 可行性验证

用 Waypipe 0.9.2 的源码做了 ARM64 OHOS SDK 交叉编译验证。此版本用于确认
C 实现和工具链的兼容性，集成版本待选定。最小构建关闭了 DMA-BUF、视频、压缩和
security-context 功能，产出了可执行文件和只依赖 OHOS `libc.so` 的共享库。
共享库将 `main` 改名为 `hish_waypipe_main`，用于后续验证原生子进程入口。

采用共享内存路径时，来宾中的 Waypipe server 提供应用的本地 Wayland socket。
宿主的 Waypipe client 连接 HGS。两端通过单一字节流复制缓冲区和文件描述符对应的
资源。所需的是 Waypipe 协议传输，现有 X11 字节转发无法直接连接 Wayland 应用与 HGS。
参见 [Waypipe 源码的运行说明](https://sources.debian.org/src/waypipe/0.9.2-1/waypipe.scd)。

## 构建并运行原生子进程探针

用解包后的 Waypipe 0.9.2 源码和本机 OHOS SDK 构建共享库：

```sh
python3 scripts/build_waypipe_probe.py "$WAYPIPE_SOURCE" "$OHOS_NATIVE_SDK" \
  feature/hish_main/libs/arm64-v8a/libhish_waypipe.so
```

在本地 `feature/hish_main/build-profile.json5` 的 CMake `arguments` 中加入
`-DHISH_BUILD_WAYPIPE_PROBE=ON`。构建和签名 ARM64 平板包，安装并从已停止状态启动：

```sh
hdc shell aa start -a EntryAbility -b dev.hackeris.hish -m tablet --ps hish.waypipe.probe 1
hdc shell hilog -x -T HiSH-Waypipe
```

子进程加载共享库并调用 `--version`，然后分别从 memfd 和应用缓存目录中的临时文件
创建样本。它通过 Unix socket 的 `SCM_RIGHTS` 把描述符发给 HiSH 主进程。主进程
用 `MAP_SHARED` 和 `PROT_READ | PROT_WRITE`映射并比较样本内容。
探针结束后释放描述符，临时文件在发送前已解除目录链接。

ARM64 真机上两种样本的 `SCM_RIGHTS`、共享读写映射和内容校验均通过。
主进程对收到的 memfd 调用 `fstat` 返回 `EACCES`，映射仍成功。来自应用缓存目录的
临时文件可正常查询大小。移植时应检查 Waypipe 哪些路径依赖接收方查询 fd 元数据。

后续端到端探针使用非重连的单连接模式验证 `wl_shm` 首帧和键盘输入。
Waypipe 的常驻 client 路径会为连接调用 `fork()`，需要按 OHOS 沙箱能力单独验证。
当前 HAP 可运行原生探针，尚未接入 VM 到 HGS 的 Wayland 数据通道。

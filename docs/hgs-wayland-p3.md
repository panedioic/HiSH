# HiSH Wayland P3 可行性验证

用 Waypipe 0.9.2 的源码做了 ARM64 OHOS SDK 交叉编译验证。宿主和来宾探针使用同一版本。
最小构建关闭了 DMA-BUF、视频、压缩和
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

## 运行平板 Wayland 实验

构建 ARM64 平板包之前，用 `--guest-output` 同时构建静态 Linux ARM64 端。
在构建主机上安装 `aarch64-linux-gnu-gcc` 和对应的静态 libc。

```sh
python3 scripts/build_waypipe_probe.py "$WAYPIPE_SOURCE" "$OHOS_NATIVE_SDK" \
  feature/hish_main/libs/arm64-v8a/libhish_waypipe.so \
  --guest-output feature/hish_main/src/main/resources/rawfile/hish-waypipe-linux-arm64
```

仍需在 CMake 参数中启用 `HISH_BUILD_WAYPIPE_PROBE`。安装签名包后，从应用停止状态启动。

```sh
hdc shell aa start -a EntryAbility -b dev.hackeris.hish -m tablet --ps hish.wayland 1
hdc shell hilog -x -T HiSH-Waypipe
```

QEMU 将专用 virtio-serial 端口连接到应用私有 Unix socket。实验只启动一个 Wayland
应用连接。宿主可以在收齐握手前接受新的串口连接，避免来宾启动阶段的断连耗尽这次会话。
来宾通过只读 9p 挂载获取匹配版本，复制到 `/run` 后启动。以下命令需在来宾中以 root 执行，
并预先安装 `socat` 和一个支持 Wayland 的 GTK 应用。

```sh
mkdir -p /run/hishwaypipe /run/hishwaypipe-app
chmod 700 /run/hishwaypipe-app
mount -t 9p -o trans=virtio,version=9p2000.L,ro hishwaypipe /run/hishwaypipe
cp /run/hishwaypipe/waypipe /run/hish-waypipe
chmod 700 /run/hish-waypipe
socat UNIX-LISTEN:/run/hish-waypipe.sock,unlink-early \
  OPEN:/dev/virtio-ports/org.hish.waypipe.0 &
unset DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET
XDG_RUNTIME_DIR=/run/hishwaypipe-app GDK_BACKEND=wayland \
  /run/hish-waypipe --no-gpu --oneshot --compress=none \
  --socket /run/hish-waypipe.sock server gtk3-demo
```

应用退出后，重启 HiSH 实验会话可重新验证。Waypipe 的常驻 client 路径会为连接调用
`fork()`，需单独验证其在 OHOS 沙箱中的行为。

ARM64 平板真机上，Alpine 来宾的 GTK 3 应用已通过 `wl_shm` 在独立 HGS 窗口显示。
点击按钮可改变标签，物理键盘事件可在输入框产生文本。关闭窗口后，HGS 移除窗口，
Waypipe client 以状态 0 退出。宿主对部分文件描述符仍报告 `fstat` 权限错误，
需继续验证其他应用和共享缓冲区场景。

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

仍需在 CMake 参数中启用 `HISH_BUILD_WAYPIPE_PROBE`。安装签名平板包后，在
「设置 → Linux 应用窗口」中打开「启用 Wayland 窗口（实验）」，然后重启 HiSH。
同时启用 X11 时，普通启动优先尝试 Wayland。Wayland 宿主启动失败时尝试 X11。
缺少 Waypipe 支持的构建会禁用 Wayland 开关，并按原有 X11 偏好启动。

调试时也可在应用停止状态下通过启动参数直接启用 Wayland。

```sh
hdc shell aa start -a EntryAbility -b dev.hackeris.hish -m tablet --ps hish.wayland 1
hdc shell hilog -x -T HiSH-Waypipe
```

QEMU 将专用 virtio-serial 端口连接到应用私有 Unix socket。宿主保留监听端点，
为每次应用启动建立独立的 HGS 和 Waypipe 连接。来宾 Waypipe 直接打开 virtio 设备，
等待 QEMU 连接就绪后再启动应用。同一时间可运行一个 Wayland 应用连接。
来宾启动后，QEMU Guest Agent 会短暂挂载只读 9p，将匹配版本和启动脚本安装到 `/run`。
日志出现 `Guest launcher ready` 后，在来宾中以 root 运行：

```sh
/run/hish-wayland status
/run/hish-wayland run gtk3-demo  # 也可以传入其他已安装的 Wayland 程序及其参数
```

应用退出后可以直接再次运行 `/run/hish-wayland run`。宿主以串行方式处理连接，
每次连接结束后回到监听状态。

ARM64 平板真机上，Alpine 来宾的 GTK 3 应用已通过 `wl_shm` 在独立 HGS 窗口显示。
启动命令能在来宾开机后自动安装。传入不存在的应用会报错，并保留可用连接。
点击按钮可改变标签，物理键盘事件可在输入框产生文本。关闭窗口后，HGS 移除窗口，
同一虚拟机内连续启动并关闭了三个 GTK 3 测试窗口，第三个窗口也通过了点击和键盘验证。

OHOS 上，Waypipe 会在应用私有运行目录中创建用于重建来宾共享缓冲区的普通文件。
HGS 在私有运行目录中用同样的方式生成 XKB 键盘映射。两处均在传递文件描述符前解除目录链接。
ARM64 平板连续运行三个 GTK 3 窗口并最大化、恢复第三个窗口，两条路径均未再出现 `fstat` 权限错误。

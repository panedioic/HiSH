# HiSH X11 P0

P0 在 ARM64 HarmonyOS 平板上使用 HGS 的 X11 子窗口。来宾通过 QEMU 用户态网络的
`10.0.2.2` 访问 HiSH 的回环监听。HiSH 将每条连接转发到本次 HGS 会话的 abstract
Unix socket。Xwayland 校验来宾的 Xauthority cookie。

## 准备测试包

1. 按 HiSH README 准备 QEMU 库、Linux 内核和默认 Alpine 镜像，初始化子模块。
2. 准备与 HGS 当前版本匹配的 OHOS ARM64 X11 SDK，包含 wlroots 0.20.2 和
   Xwayland 24.1.13。可以使用 WineHua 的构建产物。按
   [HGS X11 文档](../hgs/docs/integration/x11.md) 准备依赖闭包，放入
   `hgs/libs/arm64-v8a/`。在本地 `hgs/build-profile.json5` 的 CMake
   `arguments` 中加入 `-DHGS_BUILD_X11=ON -DHGS_X11_DEPS_ROOT=<SDK目录>`。
3. 用 HGS 的 `scripts/x11/pack_resources.sh` 生成 `hgs-x11-res.zip`，
   放入 `feature/hish_main/src/main/resources/rawfile/`。
4. 从 `build-profile.template.json5` 准备本地配置并执行 `ohpm install --all`。
   构建 `tablet@default`，使用与 HiSH 测试包名和设备匹配的调试签名。

## 在设备上复现

从已停止的应用启动测试入口。以下命令对应仓库默认的开发包名。

```sh
hdc shell aa start -a EntryAbility -b dev.hackeris.hish -m tablet --ps hish.x11 1
```

在默认 Alpine 镜像的 root 终端中执行以下命令。P0 依赖来宾的 QEMU Guest Agent
和 `guest-exec`。首次启动请等 HiLog 中的 `HiSH-X11` 标签报出 `Ready`。

```sh
apk add xmessage xdpyinfo
. /run/hish-x11.env
xdpyinfo | head
xmessage -geometry 420x180+850+640 -buttons OK:0 -default OK 'Hello from HiSH'
```

应看到 OHOS 子窗口。窗口聚焦时按 Enter，确认来宾进程正常退出，再运行一次
`xmessage`。同时检查 HiLog 中的窗口事件和 `frame=true`。
验证认证时可运行 `XAUTHORITY=/dev/null xdpyinfo`，应连接失败。

P0 的配置通过启动参数生效。环境文件适用于默认镜像的 root 终端。X11 监听只绑定
宿主回环地址，来宾认证文件位于 `/run` 的私有目录。

## 真机验证

ARM64 测试包已使用 `dev.hackeris.hish` 的调试签名在连接的 HarmonyOS 设备上安装。
来宾的 `xdpyinfo` 能访问 Xwayland 24.1.13，无 cookie 时返回退出码 1。
使用上面的几何参数后，HGS 在同一会话内多次建窗并报告 `frame=true`。
已验证关闭按钮和窗口聚焦时按 Enter 均可关闭窗口，之后可以重新启动应用。
默认尺寸的 `xmessage` 曾创建一个过小的子窗口，未呈现首帧，P0 的复现命令显式指定大小和位置。

## 从设置启用 X11

包含 X11 后端的构建可在「设置 → Linux 应用窗口 → 启用 X11 窗口」开启服务。
退出并重新打开 HiSH 后，设置页会显示服务状态。默认 Alpine 的 root 终端可直接运行：

```sh
/run/hish-gui status
/run/hish-gui run xdpyinfo
/run/hish-gui run xmessage -geometry 420x180+850+640 -buttons OK:0 -default OK 'HiSH X11'
```

`status` 显示来宾配置的地址，`run xdpyinfo` 验证连接。
启动工具由 Guest Agent 写入 `/run`，每个新 VM 会话重新配置。原来的
`/run/hish-x11.env` 仍可供脚本使用。也可以保留原来的调试启动参数来复现 P0。

ARM64 真机已验证设置可以跨 HiSH 重启保存，普通启动可以发布来宾环境。
`xmessage` 可以接收 Enter 并以状态码 0 退出。`xterm` 和 Qt 的 `qterminal`
也同时创建了子窗口并呈现首帧。默认 Alpine 镜像的 Qt 字形显示和 GTK 窗口布局
仍需验证。测试中 `gtk3-demo` 创建了异常狭长的子窗口，HGS 未能呈现它的首帧。

# OHOS Emulator 与 hdc 排障记录

更新时间：2026-09-02

## 已修复的启动问题

SSH `dev` 上 SDK Emulator 的实际文件名是 `emulator/Emulator`。其自带的
`emulator/lib/libQt5Core.so.5` 是带 `PT_INTERP` 的异常共享库，直接启动会报：

```text
error while loading shared libraries: libQt5Core.so.5: cannot open shared object file
```

远端已有可加载的 PyQt5 Qt5Core，因此使用它作为预加载库即可启动 Emulator；不要
覆盖 SDK 内的 Qt 文件：

```sh
SDK=$HOME/ohos-sdk/command-line-tools
QT=$HOME/.local/pipx/venvs/gns3-gui/lib/python3.10/site-packages/PyQt5/Qt5/lib
export LD_LIBRARY_PATH="$SDK/emulator/lib:$QT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_PRELOAD="$QT/libQt5Core.so.5"
```

该版本安装镜像时必须使用完整版本字符串，而不是 API 数字：

```sh
"$SDK/emulator/Emulator" -install \
  -deviceType phone -osVersion 'HarmonyOS 6.1.1(24)'
```

若下载包只解出部分文件，需在同一目录解出 `info.json` 和 `system.img`：

```sh
IMAGE=$HOME/Library/Huawei/Sdk/system-image/HarmonyOS-6.1.1/phone_all_x86
unzip -o "$IMAGE/system-image-phone_all-x86.zip" -d "$IMAGE"
"$SDK/emulator/Emulator" -create PiliPlusX \
  -deviceType phone -osVersion 'HarmonyOS 6.1.1(24)'
```

## 当前仍存在的 hdc 阻塞

实例可以冷启动，内核也能完成 `boot.completed`；但是该远端容器中的系统日志为：

```text
hdcDisable=1
Create directory '/config/usb_gadget/g1/functions/ffs.hdc' failed
Failed to mount for /dev/usb-ffs/hdc
```

因此 `hdc list targets` 仍为 `[Empty]`。切换 `OHOS_HDC_SERVER_PORT`、显式指定
`hdc -s`、重启旧 hdc server 或切换 `-noWindow` 都不能绕过这个限制；容器没有可用
的 USB gadget/configfs 运行能力。此环境目前只能证明 Emulator 能启动和系统能引导，
不能完成 HAP 安装、Flutter 启动或播放验收。

完整运行验收需要在带真实 USB gadget/configfs 能力的宿主机、DevEco Studio 本机
环境或 OHOS 真机上执行：

```sh
export OHOS_HDC_SERVER_PORT=8710
hdc list targets
hdc install /path/to/entry-default-unsigned.hap
hdc shell aa start -a EntryAbility -b com.piliplusx
```

在 `hdc list targets` 出现在线设备前，不得把 OHOS 的 HAP 安装、SDR 播放或 HDR
能力写成运行验收通过。

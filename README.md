# DJIMicTray

在 macOS 菜单栏里控制 DJI Mic Mini 系列的小工具，不需要手机上的 DJI Mimo。

协议移植自 [usokawa/dji-mic-mo](https://github.com/usokawa/dji-mic-mo)（BSD 2-Clause，基线 commit `7c2dd5b`），
用 Swift 原生实现：USB 走 IOUSBHost，蓝牙走 CoreBluetooth，不依赖 Python、libusb 或浏览器。

## 功能

- **USB（接收器）**：插上接收器后自动连接，可同时控制接收器和所有已配对的发射器。
- **蓝牙（发射器直连）**：扫描并直连单个发射器。
- 显示各设备电量、充电、输入电平、内录剩余量、固件版本；正在内录时菜单栏图标变为录音标记。
- 可修改的设置与上游一致：声道（单声道 / 立体声 / 四声道）、安全音轨、增益、降噪、低切、自适应增益、
  音色、32-bit 浮点录音、自动录音、循环录音、振动、指示灯、自动关机等。界面只显示当前机型支持的项。
- 发射器格式化需要二次确认（上游网页版是一键执行）。
- “复制状态 JSON”导出与上游 CLI 相同结构的状态，方便排查问题。

## 构建

需要 Xcode（macOS 14 及以上）。

```sh
./build.sh          # 产出 build/DJIMicTray.app（ad-hoc 签名）
open build/DJIMicTray.app
```

首次蓝牙扫描时系统会请求蓝牙权限。

## 已知限制

- 协议来自上游的抓包逆向，固件版本以上游 README 为准（Mini / Mini 2 为 V02，Mini 2S 为 V30）。
- 内录剩余 / 总量的单位上游没有注明，界面原样显示数值。
- 多个接收器同时插入时不会自动选择，需要只保留一个。
- 电量只有 7 个档位，界面上的百分比按档位折算；DJI Mic Mini 2 接收器不上报自身电量。
- 接收器的控制接口同一时间只能被一个程序打开，和上游网页版（Chrome）不能同时使用。

## 许可

本项目中的协议实现源自 dji-mic-mo，Copyright (c) 2026 usokawa_，按 BSD 2-Clause 许可再分发，
许可全文见 `LICENSE-dji-mic-mo.md`（打包时一并放入 app 的 Resources 目录）。

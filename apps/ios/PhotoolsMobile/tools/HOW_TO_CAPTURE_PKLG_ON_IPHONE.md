# 📱 iPhone 获取蓝牙抓包 (.pklg) 实战教程

本文档介绍如何在 iPhone 上捕获官方 SnapBridge 与尼康相机通信的蓝牙底层数据包（`.pklg`），并通过本项目脚本一键提取真机认证密钥（
`DeviceID` 与 `Nonce`），永久赋予本项目 App 纯 BLE 免配对直连与持续高精 GPS 注入能力。

---

## 💡 为什么只需抓包一次？

- 尼康现代微单（Z 6III、Z 8、Z 9、Z 50II、Z f 等）在首次配对时走系统底层认证；
- **但只要您的 iPhone 曾通过官方 SnapBridge 成功绑定过相机一次，相机机身 NVRAM 闪存中就已经永久记录了该 iPhone
  的合法凭据**（4 字节 `DeviceID` 与 4 字节 `Nonce`）；
- 从抓包提取出该凭据后，日常开机重连 **100% 仅走标准 BLE 通信**。本 App 载入凭据后即可完全取代 SnapBridge，实现秒级开机直连与后台长效
  GPS 注入！

---

## 🛠️ 方案 A：Mac + 数据线实时抓包（推荐 · 最快最稳）

如果您有一台 Mac 电脑，这是最直观、几秒钟即可完成的方案。

### 1. 下载苹果官方 PacketLogger 工具

1. 访问苹果开发者下载中心：[Apple Developer Downloads](https://developer.apple.com/download/all/?q=Additional%20Tools)；
2. 搜索并下载对应您 macOS/Xcode 版本的 **Additional Tools for Xcode**（DMG 镜像）；
3. 打开 DMG，进入 `Hardware/` 目录，将 **PacketLogger.app** 拖入 Applications 或直接双击打开。

### 2. 开始实时捕获

1. 使用 Lightning 或 USB-C 数据线将 iPhone 连接到 Mac，手机弹出提示时选择「信任此电脑」；
2. 打开 Mac 上的 **PacketLogger.app**；
3. 点击顶部菜单栏：`File` -> `New iOS PacketLog...`；
4. 在设备列表中选择您的 iPhone，点击右下角 **Start Capture**（此时窗口开始实时滚动蓝牙数据）。

### 3. 复现 SnapBridge 握手

1. 打开尼康相机并处于正常开机取景画面（确保相机蓝牙已开启）；
2. 在 iPhone 上打开官方 **SnapBridge** App；
3. 观察 SnapBridge 界面显示与相机已连接（相机屏幕出现蓝牙图标）；
4. 保持连接 5~10 秒（此时完整的 BLE 握手与凭据通信已被 PacketLogger 实时捕获）。

### 4. 保存抓包文件

1. 回到 Mac 的 PacketLogger 窗口，点击工具栏的 **Stop** 停止捕获；
2. 点击菜单栏 `File` -> `Save As...`；
3. 将文件保存为 `extract_pklg_credentials.pklg`（或您自拟的文件名，如 `my_camera.pklg`）。

---

## 📱 方案 B：纯 iPhone 无线独立抓包（无需 Xcode 工具）

如果您身边没有数据线，可以直接在 iPhone 上通过苹果官方调试描述文件生成系统级诊断包（`sysdiagnose`）。

### 1. 安装苹果官方 Bluetooth Profile

1. 在 iPhone Safari 浏览器中访问苹果官方日志配置页面：  
   👉 [Apple Bug Reporting Profiles and Logs](https://developer.apple.com/bug-reporting/profiles-and-logs/)
2. 找到 **Bluetooth (iOS)**，轻点下载描述文件；
3. 打开 iPhone【设置】-> 顶部提示【已下载描述文件】-> 点击【安装】并输入锁屏密码；
4. 重启 iPhone 以激活系统级蓝牙数据包记录模式。

### 2. 复现通信

1. 相机开机，打开 iPhone 上的 **SnapBridge**；
2. 等待 SnapBridge 正常连通相机。

### 3. 触发 iOS 系统级诊断采集 (Sysdiagnose)

1. 同时长按 iPhone 的 **【音量加】+【音量减】+【侧边电源键】约 1~1.5 秒**；
2. 手机会发出一次短暂的 **触觉振动**，表示系统诊断采集已在后台静默启动；
3. 等待约 3~5 分钟（系统正在将全系统日志与蓝牙 HCI 数据打包压缩为 `.tar.gz`）。

### 4. 导出抓包并提取 `.pklg`

1. 打开 iPhone【设置】->【隐私与安全性】-> 滚动到底部【分析与改进】->【分析数据】；
2. 在顶部搜索框输入 `sysdiagnose`；
3. 找到最新生成的条目（如 `sysdiagnose_2026.10.12_...tar.gz`）；
4. 点击该条目，右上角轻点分享图标，通过 **AirDrop（隔空投送）** 发送给您的 Mac；
5. 在 Mac 上双击解压该 `.tar.gz` 归档包；
6. 进入解压目录下的 `Bluetooth/` 文件夹，即可找到名为 `bluetooth_xxx.pklg` 或类似名称的 PacketLogger 数据文件。

---

## 🚀 步骤三：一键提取并注入工程

拿到 `.pklg` 文件后，将其重命名为 `extract_pklg_credentials.pklg` 放置在 `apps/ios/PhotoolsMobile/tools/captures/`
，在终端执行本项目专属的提取工具：

```bash
# 自动解析抓包、现场 100% 闭环算法验真，并一键写入 App 配置文件
python3 apps/ios/PhotoolsMobile/tools/extract_pklg_credentials.py apps/ios/PhotoolsMobile/tools/captures/extract_pklg_credentials.pklg --update-config --verbose
```

### 终端输出验证：

```text
====================================================================
🎉 成功提取尼康 SnapBridge 真机配对凭据！
====================================================================
📷 侦测相机名称   : Z6_3_1234567
📱 控制器设备名称 : iPhone_NikonGPS
🔑 DeviceID (Hex) : 0x12345678 (十进制: 305419896)
🎲 Nonce    (Hex) : 0x87654321 (十进制: 2271560481)
📡 GATT 特征通道  : 0x0042
🔄 检测到有效握手 : 2 组
🛡️ 闭环验真结果   : [100% VERIFIED] 现场重算匹配 Salt [2]，Stage 3 响应 100% 逐字节一致！
====================================================================
✅ 凭据已成功写入软件配置文件: apps/ios/PhotoolsMobile/Sources/PhotoolsMobileCore/Resources/camera_credentials.json
```

---

## 🎯 验证与日常使用

配置文件更新后：

1. 运行单元测试验证配置解析：
   ```bash
   swift test --package-path apps/ios/PhotoolsMobile
   ```
2. 在 Xcode 中将 `PhotoolsMobile` App 安装至您的 iPhone；
3. **日常使用模式**：
    - 相机处于正常取景拍摄界面（无需进入菜单）；
    - 打开 iPhone 的 Nikon GPS App，轻点主界面的「一键巡航」或列表中您的相机「免配对直连」；
    - App 瞬间通过纯 BLE 握手连通相机，在后台持续长效下发高精 WGS-84 经纬度与海拔！

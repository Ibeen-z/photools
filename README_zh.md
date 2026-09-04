# 📸 photools 摄影资产地理信息与归档工具箱

<p align="center">
  <img src="img/AppIcon.png" width="128" height="128" alt="photools App Icon" style="border-radius: 28px; box-shadow: 0 12px 30px rgba(0,0,0,0.35);" />
</p>

<p align="center">
  <b>让 GPX 轨迹一键化为带有精准 GPS 坐标、中文地名与拍摄日期的摄影作品库</b><br/>
  <i>专为摄影师打造的自动化 GPX 轨迹对齐、GPS 智能邻近推算、离线高精中文逆地理打标与拍摄日期原子归档工具箱</i>
</p>

<p align="center">
  <a href="README.md"><b>English</b></a> | <a href="README_zh.md"><b>简体中文</b></a>
</p>

<p align="center">
  <a href="https://github.com/vincentchyu/photools/releases/latest"><img src="https://img.shields.io/badge/立即下载-macOS%20客户端%20(.dmg)-blue?style=flat-square&logo=apple" alt="下载 macOS 客户端" /></a>
  <img src="https://img.shields.io/badge/平台-macOS%20%7C%20Linux-black?style=flat-square&logo=apple" alt="Platform" />
  <img src="https://img.shields.io/badge/RAW%20全格式支持-尼康%20%7C%20索尼%20%7C%20佳能%20%7C%20富士%20%7C%20徕卡-darkred?style=flat-square" alt="RAW Support" />
  <img src="https://img.shields.io/badge/Go%20版本-1.21+-00ADD8?style=flat-square&logo=go" alt="Go Version" />
  <img src="https://img.shields.io/badge/开源协议-MIT-green?style=flat-square" alt="License" />
</p>

---

## 💡 真实痛点与设计初衷

作为同时双持多台相机的摄影师与开发者，在真实的旅行与户外风光拍摄中，我们长期面临着 **前期现场打点难、后期归档整理烦**的割裂痛点：

> *“去川西与新疆长途徒步，手持两台尼康相机（如 Z8 长焦 + Z50 II / Z6 III 广角双持）。在 **拍摄现场**，官方 SnapBridge
极其臃肿，锁屏几分钟就被 iOS 杀后台导致 GPS 彻底断连；手机发烫且电量断崖式暴跌；强行抢占 Wi-Fi 导致微信断网；最致命的是 **官方
App 限制只能连接一台相机**，双持摄影师的副机永远分不到 GPS，两台相机的机身时钟对不齐。*  
> *而到了 **后期导入阶段**，面对存储卡里的 4,000 多张 RAW 照片，单反/微单机身缺失 GPS，又面临着如何把手表/手机的 GPX
轨迹精准对齐照片、如何在峡谷/室内弱信号断点处进行智能大圆推算、如何把‘赛里木湖/喀拉峻’等五级规范中文地名写入
EXIF，并按拍摄日期自动化归档——且 **绝不把摄影资产上传到任何商业云端**？”*

**photools** 正是为串联起这套“前期现场 ➔ 后期归档”的无缝闭环而生：

```text
【前期现场拍摄 · 手机端】
 iPhone (NikonGPS) 纯 BLE 极速秒连 ──▶ 并发向双持多台相机注入高精 GPS / UTC 时钟 + 巡航后台无感记录 GPX
                                                         │
                                                         ▼ (拍摄完毕，存储卡插上电脑)
【后期资产处理 · 桌面端】
 SD卡 RAW/JPG 照片 + 现场 GPX 轨迹 ──▶ photools 桌面端/CLI ──▶ 球面大圆推算 + 离线中文逆地理 + 按日期原子归档
```

---

## ✨ 效果实测对比 (Before vs After)

### 📱 1. 前期现场拍摄与相机同步 (On-Field Capture)

<table width="100%">
<tr>
<th width="50%">❌ 使用前 (官方 SnapBridge / 传统痛点)</th>
<th width="50%">✅ 使用后 (NikonGPS for iOS)</th>
</tr>
<tr>
<td>

- ❌ **锁屏被杀后台**：手机锁屏放入口袋 5 分钟即被 iOS 杀掉，再按快门相机 GPS 图标熄灭，拍完全是无坐标照片；
- ❌ **单机位限制**：双持摄影师（如 Z8 + Z50 II）只能无奈二选一，副机永远没有 GPS，两台相机时钟误差数十秒；
- ❌ **发热与电量雪崩**：后台维持臃肿 Wi-Fi 与图像传输通道，手机发烫，半天耗尽 iPhone 电池；抢占 Wi-Fi 导致手机断网；
- ❌ **死循环唤醒相机**：原地休整时手机频繁盲连，相机测光表无法休眠，相机电池从 100% 暴跌。

</td>
<td>

- ✅ **系统级后台保活 (State Restoration)**：首毫秒注册恢复标识符，App 即使被系统回收杀掉，相机开机也能在后台瞬间被动复活并注入
  GPS；
- ✅ **多机位并发同步**：单台 iPhone 同时并发连接多台就绪相机，双持机位同步注入高精 WGS-84 坐标，所有相机时钟纳秒级对齐；
- ✅ **纯 BLE 极致轻量与零断网**：移除全部无用 Wi-Fi 与传输代码，手机完全不发烫，不影响蜂窝移动网络；
- ✅ **四维待机保鲜仲裁**：结合运动协处理器，原地休整时 100% 保持静默节电 98%，半按快门 1.2 秒秒连，快门 0 毫秒即拍即有。

</td>
</tr>
</table>

### 🖥️ 2. 后期资产整理与地名清洗 (Post-Processing & Archiving)

<table width="100%">
<tr>
<th width="50%">❌ 使用前 (手动凌乱整理)</th>
<th width="50%">✅ 使用后 (photools macOS / CLI)</th>
</tr>
<tr>
<td>

```text
📁 待处理目录 (Inbox)/
├── DSC_8123.NEF  (尼康 RAW)
├── DSC_8123.JPG
├── DSC_8124.NEF
└── DSC_8125.NEF

元数据状态:
• GPS 坐标: 无 (0, 0)
• 峡谷/断点: 坐标完全缺失
• 地理名称: 无
• 文件名: 混乱的相机默认编号
```

</td>
<td>

```text
📁 归档库 (Processed/2026/0516/)/
├── 2026-05-16-DSC_8123.NEF
├── 2026-05-16-DSC_8123.JPG
├── 2026-05-16-DSC_8124.NEF
└── 2026-05-16-DSC_8125.NEF

元数据状态 (智能分层写入 EXIF / IPTC / XMP):
• GPS 坐标: 44.5912° N, 81.1684° E
• 漏点修补: 15分钟窗口球面大圆时间加权平滑推算
• 地理名称: 中国 / 新疆 / 伊犁 / 赛里木湖
• 在 Lightroom、Apple Photos、Capture One 中可直接按地名搜大片！
```

</td>
</tr>
</table>

---

## 🔄 摄影全生命周期地理信息工作流 (两大核心板块)

photools 打通了户外旅行与风光摄影从 **前期现场机位打点**到 **后期导入、中文逆地理打标与拍摄日期归档**的全生命周期：

```text
                          📸 摄影师全生命周期地理信息工作流
                                        │
         ┌──────────────────────────────┴──────────────────────────────┐
         │                                                             │
    【第一大板块：前期现场拍摄篇】                               【第二大板块：后期资产处理篇】
    📱 移动端伴侣 (NikonGPS for iOS)                             🖥️ 桌面端与终端 (photools macOS & CLI)
         │                                                             │
    • 手机纯 BLE 极速秒连 (免开 Wi-Fi / 免进配对向导)             • RAW/JPG 伴随文件全景发现与双格式同步
    • 实时向相机注入高精 WGS-84 坐标与 UTC 时间                   • GPX 轨迹精准时间轴自动匹配
    • 多机位并发同步 (双持 Z8 + Z50 II 摄影师福音)               • 球面大圆智能邻近推算 (填补室内/峡谷漏点)
    • 四维保鲜仲裁引擎 (自适应滑动窗口/原地休整节电)               • 离线高精 3D KD-Tree 五级中文地名打标
    • CoreBluetooth 系统级后台保活 (State Restoration)           • 智能元数据分层模型 (RAW 只读 / 智能分层)
    • 户外巡航后台持续记录 GPX 轨迹与系统分享导出                 • MapLibre 3D 真实高程地形与透视视锥渲染
         │                                                             │
         └──────────────────────────────┬──────────────────────────────┘
                                        ↓
                      🌟 完美闭环：前期现场精准打点 ➔ 后期一键智能归档
```

---

## 📱 第一大板块：前期现场拍摄篇 · 移动端 (NikonGPS for iOS)

位于 `apps/ios/PhotoolsMobile`，专为 iPhone / iPad 设计的尼康微单/单反相机专属轻量化纯 BLE (Bluetooth Low Energy) GPS
与时钟持续同步中枢（全面支持 Z9、Z8、Z6 III、Z50 II、Zf、D850 等主流机型）。

### 🌟 为什么选择 NikonGPS 而非官方 SnapBridge？

> [!NOTE]
> **【仅供学习交流与自力更生声明】**  
> 本工具 **仅供个人学习与技术交流**。项目源于对尼康官方颓败的 SnapBridge 长期不思进取、后台常被杀、发热耗电高的极度失望；加之新买的
Z6 III 机身使用不到半年手柄蒙皮便大面积开胶，官方售后却匪夷所思地坚称“非质量问题，系用户个人使用所致”并强行收费维修。官方的傲慢与软硬件摆烂彻底倒逼摄影师只能自力更生——既然售后指望不上，那就自己动手买胶换蒙皮；既然官方
App 难用至极，那就自己逆向协议写出真正好用、省电、支持双持多机位并发的纯粹同步工具！

- **零内存膨胀、0 发热、不抢占 Wi-Fi**：彻底移除官方 App 繁重臃肿的照片传输和云同步逻辑，专注 10 字节 `TIME` 时钟同步与 41
  字节 `GEO` (WGS-84) 注入通道；
- **多机位并发同步（双持摄影师福音）**：官方 App 强行限制单设备连接；本项目底层采用多会话并发架构，单台 iPhone 获取到的 GPS
  坐标可 **同时分发注入双持或多台处于就绪状态的尼康相机**；
- **四维待机保鲜仲裁引擎 (`StandbyFreshnessArbiter`)**：
    - **运动协处理器自适应滑动窗口**：结合 `CoreMotion`，徒步移动缩短至 5m 窗口，原地休整放宽至 20m 窗口；
    - **原地休整深度省电**：停步到达新机位瞬态优先授权刷新，原地静止时绝对保持静默，拒绝盲目重连休眠中的相机；
    - **30m 显著位移重连**与 **25m 弱 GPS 拦截**，杜绝漂移坐标污染；
    - **快门唤醒 1.2 秒秒连**：半按快门捕获广播到完成坐标注入收执仅需 1.2 秒；
- **顺应相机原生休眠与智能长连接架构**：
    - 相机待机 1~2 分钟无快门操作会自动发送 `0x13` 自然休眠，手机端绝不过度设计主动掐断，摄影师半按快门 0 毫秒即拍即有；
- **CoreBluetooth 系统级后台状态恢复 (State Restoration · 首毫秒法则)**：
    - 在 `App.init()` 启动首毫秒向系统提交固定恢复标识符 `com.vincentchyu.photools.mobile.ble`；
    - App 即使被 iOS 系统内存回收杀掉，相机开机也能在后台瞬间被动复活并注入最新 GPS；
- **后台巡航模式 (Cruise Mode) 持续录制 GPX 轨迹与系统原生导出**：
    - 自动过滤静止漂移点与弱信号杂点，支持一键导出符合 GPX 1.1 规范的标准轨迹，集成系统原生分享面板。

---

### 📸 移动端应用界面与机身实测一览

#### 1. 核心控制台、长效巡航与通信事件流

> 零多余 Wi-Fi/传输负担，专注 WGS-84 高精定位与微秒级 UTC 时钟注入；集成 CoreMotion 运动感知、原地深度休眠保鲜与毫秒级底层通信事件审计。

<table width="100%">
<tr>
<td width="33.3%" align="center"><b>📱 主控仪表盘</b></td>
<td width="33.3%" align="center"><b>🔴 巡航守护与运动感知</b></td>
<td width="33.3%" align="center"><b>⚡️ BLE 握手与通信日志</b></td>
</tr>
<tr>
<td><img src="img/ios/1dashboard.jpeg" alt="主控仪表盘" style="border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.15);" /></td>
<td><img src="img/ios/3recording.jpeg" alt="巡航守护与运动感知" style="border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.15);" /></td>
<td><img src="img/ios/2log.jpeg" alt="通信事件日志" style="border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.15);" /></td>
</tr>
<tr>
<td align="center"><sub>四项后台权限就绪 · 实时 WGS-84 坐标与相机连接状态</sub></td>
<td align="center"><sub>CoreMotion 运动感知 · 20m 深度休眠与 GPX 轨迹录制</sub></td>
<td align="center"><sub>毫秒级 0x1C 唤醒响应 · Stage 1~3 认证挑战逐字节验真</sub></td>
</tr>
</table>

#### 2. iOS 系统级后台长效保活与整夜待机功耗/坐标实测

> **【真实整夜野外待机续航实测】** 相机保持开机待机，iPhone 开启「一键巡航模式」+ 后台持续保活整整一整夜：  
> • **相机电池 (Z 6III)**：从 80% 仅下降到 69%（一整晚耗电仅 ~11%，彻底解决官方 App 频繁盲唤醒测光表导致的相机电池雪崩！）；  
> • **手机电池 (iPhone)**：从 90% 仅下降到 70%（长效运动感知 + 后台高精 GPS 守护 + GPX 录制一整晚仅耗电 20%）；  
> • **机身位置注入**：清晨轻触快门瞬间秒连，机身屏幕回显高精经纬度、海拔与毫秒级 UTC 时钟，GPS 卫星图标常亮点亮！ *(
经纬度数值已按隐私保护规约平滑高斯模糊处理)*

<table width="100%">
<tr>
<td width="28%" align="center"><b>🛡️ iOS 系统后台长效守护</b></td>
<td width="36%" align="center"><b>🔋 整夜待机微安级超低功耗</b></td>
<td width="36%" align="center"><b>📍 相机机身位置数据直读 (Z 6III)</b></td>
</tr>
<tr>
<td valign="top"><img src="img/ios/5backend.jpeg" alt="iOS 系统级后台长效守护" style="border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.15);" /></td>
<td valign="top"><img src="img/ios/7-1Camera.jpeg" alt="相机整夜开机待机低功耗验证" style="border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.15);" /></td>
<td valign="top"><img src="img/ios/7-2Camera.jpeg" alt="尼康微单机身位置数据直读实测" style="border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.15);" /></td>
</tr>
<tr>
<td align="center"><sub>灵动岛位置守护 · 40+ 分钟持续运行不杀后台</sub></td>
<td align="center"><sub>整夜开机待机测试：相机 80%➔69%，手机 90%➔70%</sub></td>
<td align="center"><sub>清晨唤醒瞬间写入：经纬度/海拔/UTC 时钟，GPS 图标常亮</sub></td>
</tr>
</table>

---

### 🚀 移动端实战操作指引：配对密钥获取与蓝牙自动监听

只需简单配置一次，后续拍摄即可享受 **打开相机 ➔ 半按快门秒连 ➔ 自动点亮 GPS** 的极致丝滑体验。

#### 1. 配对密钥原理解密：为什么无需重新走繁琐的相机菜单？

* 尼康现代微单（Z 6III、Z 8、Z 9、Z 50II、Z f 等）在与官方 SnapBridge 首次绑定时，机身内部 NVRAM 闪存已
  **永久写入了该手机的合法凭据**（4 字节 `DeviceID` 与 4 字节随机种子 `Nonce`）；
* 只要提取出这对凭据，后续与相机通信 **100% 走纯 BLE 数据交互**。App 携带该合法凭据发起 Stage 1
  认证挑战，相机即刻秒级放行，完全无需重新进入相机的“连接至智能设备”配对向导！

#### 2. 第一步：获取蓝牙抓包文件 (`.pklg`)（二选一）

##### 方案 A：Mac + 数据线实时抓包（推荐 · 10 秒搞定）

1. **打开抓包工具**：在 Mac 上打开 **PacketLogger.app**
   （苹果官方 [Additional Tools for Xcode](https://developer.apple.com/download/all/?q=Additional%20Tools) 镜像中的
   `Hardware/` 目录下）；
2. **连接设备**：用数据线将 iPhone 连接至 Mac，在 PacketLogger 菜单栏点击 `File` -> `New iOS PacketLog...`，选中手机并点击
   **Start Capture**；
3. **连通相机 5 秒**：打开相机取景，打开 iPhone 上的官方 **SnapBridge**，观察相机屏幕出现蓝牙图标并成功同步；
4. **保存抓包**：点击 PacketLogger 工具栏的 **Stop**，将文件保存为 `extract_pklg_credentials.pklg`。

##### 方案 B：纯 iPhone 无线抓包（无需 Mac 数据线）

1. **安装 Profile**：在 iPhone Safari
   访问 [Apple Bug Reporting Profiles](https://developer.apple.com/bug-reporting/profiles-and-logs/)，下载并安装
   **Bluetooth (iOS)** 调试描述文件，重启手机；
2. **复现通信**：打开相机，用官方 SnapBridge 连通相机；
3. **触发诊断采集**：同时长按 iPhone **【音量加】+【音量减】+【侧边电源键】约 1.5 秒**，触发短震动后后台开始采集 Sysdiagnose；
4. **导出文件**：3~5 分钟后在【设置】->【隐私与安全性】->【分析与改进】->【分析数据】中搜索 `sysdiagnose`，通过 AirDrop 隔空投送至
   Mac，解压其中的 `Bluetooth/` 目录即可找到 `.pklg` 文件。

#### 3. 第二步：凭据提取与工程自动注入

本项目已接入 Xcode 自动化编译管道，支持零代码配置：

* **方式一：自动构建注入（最便捷）**  
  将提取出的抓包文件直接重命名为 `extract_pklg_credentials.pklg`，放入工程目录：  
  `apps/ios/PhotoolsMobile/tools/captures/extract_pklg_credentials.pklg`  
  👉 **在 Xcode 中直接编译或打包运行工程，Xcode 会在 Pre-Build 阶段全自动解析抓包、完成 Blowfish 现场验真，并自动更新
  `camera_credentials.json`！**

* **方式二：终端命令行一键解析**
  ```bash
  # 自动探测抓包文件、现场 100% 闭环算法验真，并一键写入 App 配置文件
  python3 apps/ios/PhotoolsMobile/tools/extract_pklg_credentials.py --update-config --verbose
  ```
  终端将输出校验成功的相机名称（如 `Z6_3_12****7`）与 100% 逐字节一致的验真结果：
  ```text
  🎉 成功提取尼康 SnapBridge 真机配对凭据！
  📷 侦测相机名称   : Z6_3_12****7
  🔑 DeviceID (Hex) : 0x12345678 | 🎲 Nonce (Hex) : 0x87654321
  🛡️ 闭环验真结果   : [100% VERIFIED] 现场重算匹配 Salt，Stage 3 响应 100% 逐字节一致！
  ✅ 凭据已成功写入软件配置文件: camera_credentials.json
  ```

#### 4. 第三步：日常拍摄连接与蓝牙监听流程

编译并安装 App 到 iPhone 后，拍摄流程极度轻快：

1. **权限设置**：首次启动 App 时，系统定位权限请务必授权为**「始终允许」**（以激活系统级后台保活中枢与息屏高精注入）；
2. **激活一键巡航**：
    - 轻点主仪表盘的 **「一键巡航模式 🔴」** 大按钮；
    - 此时后台保活中枢与 CoreMotion 运动感知引擎全部就绪，手机在后台持续监听附近的尼康相机广播；
3. **半按快门秒连**：
    - 相机处于正常开机取景状态（开启机身蓝牙）；
    - **手指半按相机快门**，相机机身立即发出唤醒广播（`0x1C`）；
    - iPhone 在 **1.2 秒内瞬间完成握手并注入 WGS-84 GPS 经纬度、海拔与 UTC 时钟**，相机屏幕上的 GPS 卫星图标常亮点亮 📍；
4. **四维待机静默与无感重连**：
    - 相机静置 1~2 分钟进入休眠时，App 智能顺应相机状态并保持待机，绝不胡乱唤醒测光表，极度省电；
    - 徒步移动中，CoreMotion 感知到位移自动拉起高精位置；原地停步休整时自动进入深度休眠保鲜；再次半按快门即可 0 毫秒即拍即有！

> 📖 **移动端与蓝牙协议专项技术指引**：
> - 📘 [尼康蓝牙协议逆向、多机位并发与 State Restoration 架构指南](docs/NIKON_IOS_BLUETOOTH_SYNC_AND_STATE_RESTORATION.md)
> - 🧭 [尼康机身 GPS 硬件协议与电子罗盘规格剖析](docs/NIKON_HARDWARE_GPS_AND_COMPASS_SPECIFICATION.md)
> -
🔍 [iPhone 蓝牙抓包提取真机合法配对凭据保姆级实战教程](apps/ios/PhotoolsMobile/tools/HOW_TO_CAPTURE_PKLG_ON_IPHONE.md)

---

## 🖥️ 第二大板块：后期资产处理篇 · 桌面与命令行端 (photools macOS & CLI / TUI)

位于 `apps/macos/PhotoolsApp`，专为 Mac 摄影师设计的后期资产处理工作台，提供照片导入电脑后的自动化 GPX
轨迹匹配、智能推算、离线高精逆地理中文打标与按拍摄日期规范归档。

photools 为 Mac 摄影师提供了基于 SwiftUI 打造的原生桌面应用。底层直接通过进程内 C-Shared FFI（`libphotools.dylib`
）直通核心能力，响应时间仅需 ~0.1ms， **支持无需重启即时在偏好设置中切换简体中文与 English**：

- 🏔️ **MapLibre 3D 真实高程地形与贴地透视视锥**：基于 AWS Terrarium DEM 高程切片与 MapLibre WebGL
  实时呈现真实山川起伏与山体立体阴影，结合相机焦距与物理对焦距离在 3D 地表投射真实等比例贴地摄影视锥；
- 🌍 **全免 Key 多图源切片引擎 (Google / 高德 / ESRI)**：完全无需申请商业 API Key。支持一键秒切 Google 纯卫星、Google
  混合地球、高德遥感卫星与 ESRI 全球遥感，自适应坐标系映射（Google/ESRI 原生 WGS-84 零偏移物理对齐 vs 高德 GCJ-02 自动纠偏）；
- 🖐️ **触控板双指自由旋转与摄影姿态解耦**：Mac 触控板双指旋转自由转动地图东南西北（Camera
  Bearing），照片本身朝向（Heading）严格受滑杆与精调按钮控制，视距与俯仰配备自适应物理步长精调按钮组；
- ⌨️ **全键盘极速看图与挑图**：选中照片按 **`空格键 (Space)`** 瞬间唤起 macOS 系统级 QuickLook 高清大图浮层，按 **
  `↑ / ↓`** 上下键连续平滑切图，背后列表自动居中平滑跟焦；
- 📁 **历史归档层级下探与极地冰蓝冻结保护**：支持 `Processed/YYYY/MMDD/` 目录树下探（带面包屑路径条）与全局平铺打平，已归档照片采用“极地冰蓝”只读冻结体系，严防误触误删；
- 🛡️ **常驻底部写入策略防呆中枢与系统代理内核**：窗口底部常驻展示当前元数据写入策略（智能分层 / 纯 XMP / 双写同步 /
  纯内嵌），原图保护级别全透明呈现；统一调度系统代理穿透 WebKit、Go 核心引擎 FFI 与子进程；
- ⚡️ **五大高性能支柱与双质量分级缓存**：单遍递归合并扫描与系统属性批量预取（I/O 耗时降低 50%~70%）；双质量缩略图（列表 160px
  内嵌微缩图 <1ms 齐刷 + 详情展台 2.5x 超采样原图高保真解码，彻底告别马赛克）；EXIF 元数据 600 条容量 LRU 纳秒级缓存与 80ms
  日志批量节流推送，彻底消除卡顿与重绘风暴。

<p align="center">
  <a href="https://github.com/vincentchyu/photools/releases/latest">
    <img src="https://img.shields.io/badge/点击下载-photools--macOS.dmg-blue?style=for-the-badge&logo=apple" alt="下载 macOS 客户端" />
  </a>
</p>

### 📸 客户端界面一览

#### 1. 多阶段流水线控制台与实时日志
> 直观配置工作区目录、自由勾选处理能力，并实时查看每张照片的打标与推算进度。

<p align="center">
  <img src="img/zh/1-Work-Pipeline-Steps.png" alt="多阶段流水线执行全景" width="95%" />
</p>

#### 2. 照片图库与实时 EXIF 元数据检查器
> 浏览待处理照片，深度检查光学曝光参数（快门、光圈、ISO、镜头型号），支持 3D KD-Tree 离线坐标反查实时测试。

<p align="center">
  <img src="img/zh/2-Results-And-Pending.png" alt="处理完成汇总与待处理诊断清单" width="95%" />
</p>

#### 3. 离线高精地理数据包与内置使用文档
> 离线地理数据包管理，免联网极速查询任意经纬度对应的中文地名。

<p align="center">
  <img src="img/zh/3-Guide-And-Geocoding.png" alt="工作区引导与离线逆地理反查工具" width="95%" />
</p>

---

## ⚡ 四步自动化摄影工作流 (The 4-Step Workflow)

```
[待处理 RAW/JPG] ──▶ 1. GPX 轨迹对齐 ──▶ 2. GPS 智能推算 ──▶ 3. 离线地名打标 ──▶ 4. 拍摄日期归档 ──▶ [归档库/YYYY/MMDD/]
```

1. **🗺️ GPX 轨迹精准对齐 (`gpx_matching`)**
   - 自动匹配照片拍摄时间戳与多个 `.gpx` 轨迹文件，支持亚秒级精度与时间偏移补偿（`--geosync`）；
   - 优先写入 RAW 主文件（`.NEF`、`.ARW`、`.CR2/.CR3`、`.RAF`、`.DNG`）并无污染同步到伴随 `.JPG` 与 `.XMP`。
2. **🧠 GPS 智能邻近推算 (`gps_interpolate`)**
   - 高速连拍、室内穿行或峡谷遮挡导致部分照片未记录 GPS？
   - photools 采用大圆球面时间权重插值与同机位近邻继承算法，自动利用前后锚点照片平滑补齐缺失坐标。
3. **📍 离线五级高精中文逆地理 (`reverse_geocode`)**
   - 基于 3D KD-Tree 离线空间索引与本土化地名库（覆盖 71.5 万+ POI 点位）；
   - 毫秒级写入国家、省份、城市、区县及风景区 POI 中文地名至 IPTC/XMP 标签， **100% 离线运行，严守隐私**；
   - **绝对幂等性与历史脏标签清洗**：彻底废除无脑追加（`+=`），采用单次原子置空与全量重写；自动剥离旧地理层级树（`中国|` /
     `China|`）， **100% 完整保护摄影师自定义业务标签（如题材/人像/扫街）**，杜绝跨机位缝合怪与重复堆叠。
4. **📅 按拍摄日期原子归档 (`date_archive`)**
   - 读取真实 `DateTimeOriginal`，规范重命名为 `YYYY-MM-DD-原文件名`，并将同组配套文件原子安全移动至 `Processed/YYYY/MMDD/` 归档目录。

---

## 🛡️ 智能元数据分层模型与写入策略 (Smart Metadata Tiering)

不同于传统工具“粗暴全部修改 RAW”或“纯外挂侧车导致看图软件无 GPS”的两个极端，**photools** 创新性地提出了 **按元数据性质分层（Metadata Tiering & Intent Model）** 写入架构：

```
                    摄影元数据 (Metadata)
                              │
         ┌────────────────────┼────────────────────┐
         ↓                    ↓                    ↓
  第一层: 原始摄影事实   第二层: 修正摄影事实    第三层: 派生地理 & 第四层: 工作流
   (Original Fact)     (Corrected Fact)       (Derived / Workflow)
         │                    │                    │
   相机参数/快门/光圈      GPX匹配GPS/插值GPS       离线逆地理中文地名/POI
   原始拍摄时间/内建GPS    时区偏差/时间补偿        Lightroom分层关键词树/评分
         │                    │                    │
         ↓                    ↓                    ↓
      RAW 严格保留          RAW EXIF 头部          NEF.XMP 侧车
                          伴随 JPG 内嵌           伴随 JPG 内嵌
                          NEF.XMP 同步           (绝不触碰 RAW)
```

### ⚙️ 四档元数据写入策略 (`--sidecar-policy`)

| 策略名称 | CLI 标识 | 修正事实 (GPS 坐标) | 派生信息 (中文地名/分层标签) | 设计哲学与适用场景 |
| :--- | :--- | :--- | :--- | :--- |
| **智能分层模式** *(默认推荐)* | `smart` | **RAW EXIF + JPG 内嵌 + XMP 同步** | **RAW 严格只读写 XMP + JPG 内嵌** | **黄金平衡点**：RAW 获得永久标准 GPS，尼康 NX Studio/相册即开即读；地名由 XMP 承载不污染 RAW；JPG 全平台即开即看。 |
| **纯 XMP 侧车模式** | `sidecar_only` | 仅输出 `.xmp` 侧车 | 仅输出 `.xmp` 侧车 | 零触碰 RAW 与 JPG 二进制原图，适合严苛归档要求。 |
| **原图与 XMP 双写同步** | `embed_and_sidecar` | RAW/JPG 双写内嵌 | RAW/JPG 双写内嵌 + 同步 XMP | 全量双重镜像备份。 |
| **纯原图内嵌模式** | `embed_only` | RAW/JPG 双写内嵌 | RAW/JPG 双写内嵌 (不产生 XMP) | 极简模式，无需管理侧车文件。 |

### 🔍 Photools 专属可追溯性审计指纹 (Provenance)
当 photools 匹配或算法推算坐标时，自动在 XMP 侧车中注入审计指纹，明确区分“相机原始自带”与“算法推算补全”：
```xml
<rdf:Description rdf:about=""
  xmlns:photools="http://ns.photools.app/1.0/"
  photools:GPSSource="gpx"
  photools:GPSMatchMethod="time_proximity"
  photools:InterpolateWindow="15m"
  photools:Processor="photools v1.2.0"
  photools:ProcessedDate="2026-08-29T14:30:00+08:00" />
```

### 📂 伴随文件扩展名白名单 (`--companion-exts`)
- 自动拓扑发现与跟踪配套的伴随文件（如 `wav` 录音、`acr` 调色配置、`exf`、`xmp` 等）；
- 归档重命名时完整保留复合后缀（如 `DSC_2948.nef.xmp` $\rightarrow$ `2026-01-01-DSC_2948.nef.xmp`）。

---

## 🚀 快速安装与上手 (Quick Start)

### 🍺 Homebrew 一键安装（推荐开发者与全键盘终端用户）

对于习惯终端命令与键盘流的高级用户，一行 `brew install` 即可获得最极致的开箱即用体验：

```bash
# 1. 安装 CLI 命令行与 Bubble Tea 交互式 TUI 工作台（自动装配 exiftool 依赖与 Shell 自动补全）
brew install vincentchyu/tap/photools

# 2. （可选）安装 macOS 原生桌面客户端 (.app)
brew install --cask vincentchyu/tap/photools
```

> **💡 为什么推荐 Homebrew 接入？**
> * ⚡ **核心依赖自动解决**：Homebrew 会自动检测并安装核心底层工具 `exiftool`，彻底免除手动安装配置的麻烦；
> * ⌨️ **全功能中文补全开箱即用**：自动静默注入 Zsh、Bash、Fish 的 Shell Tab 自动补全，敲 `photools <Tab>` 即可查看全部指令与中文注释；
> * 🖥️ **交互式 TUI 随时拉起**：终端直接输入 `photools` 或 `photools tui`，立刻呈现全键盘操作的可视化流水线工作台。

---

### 方式 A：macOS 原生桌面应用（直接下载 DMG 安装）
1. 前往 [Releases](https://github.com/vincentchyu/photools/releases/latest) 下载 `photools-macOS.dmg`；
2. 双击打开，将 `photoolsApp.app` 拖入 `/Applications` 应用程序文件夹；
3. 打开应用，选择照片与 GPX 目录，点击 **开始执行** 即可。

### 方式 B：CLI 命令行自动化
```bash
# 执行完整自动化流水线 (默认启用 Smart 智能分层模式)
photools pipeline

# 显式指定写入策略 (smart / sidecar_only / embed_and_sidecar / embed_only)
photools pipeline --sidecar-policy=smart

# 指定伴随文件白名单 (支持同时流转归档录音与调色文件)
photools pipeline --companion-exts="wav,acr,exf"

# 开启 GPS 智能时间权重插值推算 (例如设置 30 分钟推算窗口)
photools pipeline --interpolate=true --interpolate-window=30m

# 扁平原地模式（在原目录就地逆地理打标并原地规范化重命名）
photools pipeline --flat=true --in-place=true

# 软降级容错模式（无 GPS 照片跳过地名打标直接按日期安全归档）
photools pipeline --allow-no-gps=true
```

### 方式 C：交互式终端 TUI 工作台
针对终端极客与键盘流用户，photools 内置了基于 Bubble Tea 的交互式终端界面：

```bash
photools tui
```
- **`[1/2/3/4]` 或 `[空格]`**：自由勾选或关闭特定插件；
- **`[O]`**：打开当前插件的专属自描述配置弹窗（如推算窗口、时间偏移）；
- **`[S]`**：全局设置弹窗（支持 `[空格]` 循环切换 4 档策略，`[Tab]` 路径智能补全）；
- **`[Enter]`**：进入 Dry-Run 预检，再次回车即刻执行。

---

## 🛠️ 开发者与高级进阶 (Architecture & Benchmarks)

photools 在工程设计上追求极致的性能、模块化解耦与零内存泄漏。

### 🏗️ 技术架构与底层亮点
* **ExifTool Stay-Open 常驻守护池**：消除重复 `fork/exec` 外部子进程开销（`exiftool -stay_open True -@ -`），元数据单次读取耗时从 ~30ms 骤降至 **1.2ms/op**；
* **$O(\log K)$ 球面 `AnchorIndex`**：内存按拍摄日期分桶的时间有序二分查找索引，**205 ns/op** 定位前后最邻近机位；
* **3D KD-Tree 离线空间索引**：将经纬度映射至三维笛卡尔坐标系（地球半径 $R = 6371	ext{ km}$），毫秒级完成最近邻地名检索，杜绝网络 I/O 开销；
* **Go C-Shared FFI 极速直通**：SwiftUI 原生调用 Go 核心能力，严格保证内存指针生命周期与安全释放（`defer { fnFreeString(ptr) }`）。

### 📊 性能基准测试 (Apple M1 Max, `arm64`)

```bash
go test -run=^$ -bench=. -benchmem ./internal/capabilities/gpsinterpolate/...
```

| 评测目标 | 单次延迟 (Latency) | 吞吐量 (Throughput) | 内存分配 | 说明 |
| :--- | :---: | :---: | :---: | :--- |
| **`AnchorIndex` 二分查找 (10,000 锚点)** | **`205 ns/op`** | `4,870,000 ops/sec` | `0 B/op` | 零堆内存分配 |
| **`AnchorIndex` 批量建树 (1,000 资产)** | **`0.52 ms/op`** | `1,920 batches/sec` | `24 KB/op` | 日期分桶轻量索引 |
| **`ExecuteProcess` 单图推算与动态合入** | **`0.11 ms/op`** | `8,880 photos/sec` | `1.2 KB/op` | 大圆加权计算 |
| **`ExifTool` Stay-Open 守护进程池** | **`1.2 ms/op`** | `830 reads/sec` | 0 fork 开销 | 进程崩溃自动自愈 |

---

### 📦 从源码构建与打包 (Building from Source)

#### 环境依赖
- **Go 语言**: `1.21+`
- **Swift / Xcode 命令行工具**: `Swift 5.9+` (构建 macOS 原生应用)
- **ExifTool**: `12.0+` (`brew install exiftool`)

#### 1. 编译 Go 核心二进制与动态库
```bash
# 1. 编译 Go C-Shared 动态库 (供 Swift GUI 调用)
go build -buildmode=c-shared -o dist/libphotools.dylib ./cmd/photools-cshared

# 2. 编译独立 CLI & TUI 二进制程序
go build -ldflags="-s -w" -o dist/photools ./cmd/photools
```

#### 2. 安装离线高精地理数据包
```bash
# 安装中国高精离线地名库 (71.5 万+ POI，保存至 ~/.config/photools/geodata/)
./dist/photools geodata install china

# 可选：按需安装其他大洲数据包
./dist/photools geodata install asia
./dist/photools geodata install europe
./dist/photools geodata install north-america
```

#### 3. 构建 macOS 原生 App Bundle 与 DMG 安装包
```bash
# 一键构建自包含 App Bundle 并封装为标准 macOS .dmg 磁盘镜像
./script/build_and_run.sh --dmg
```

---

## 📚 深度技术设计文档 (Architecture Design Docs)

更详尽的架构设计与实现细节，请参阅各专项技术文档：

### 📱 1. 移动端与相机蓝牙同步专题 (前期现场机位打点)

- 📘
  **[尼康蓝牙协议逆向、多机位并发与 State Restoration 架构指南](docs/NIKON_IOS_BLUETOOTH_SYNC_AND_STATE_RESTORATION.md)**
  ：深入剖析尼康 BLE 握手认证流程、多会话并发架构、四维滑动窗口保鲜仲裁与 iOS 后台状态恢复机制。
- 🧭 **[尼康机身 GPS 硬件协议与电子罗盘规格剖析](docs/NIKON_HARDWARE_GPS_AND_COMPASS_SPECIFICATION.md)**：深入解析 Expeed
  7 微单的 GPS 硬件注入报文与机身电子罗盘姿态通信。
- 🔍 **[iPhone 蓝牙抓包提取真机合法配对凭据保姆级实战教程](apps/ios/NikonGPS/tools/HOW_TO_CAPTURE_PKLG_ON_IPHONE.md)**
  ：零依赖 Python 脚本一键解析 PacketLogger 抓包并自动闭环验真 Blowfish 密钥。

### 🍏 2. 桌面端与 3D 高程地形专题 (后期导入与空间可视化)

- 🍏 **[macOS 原生客户端与跨语言 C-Shared FFI 设计](docs/MACOS_CLIENT_TECHNICAL_DESIGN.md)**：SwiftUI 极速架构、AppKit 原生
  QuickLook 全局键盘事件拦截、纳秒级 LRU 缓存与 Go C-Shared 动态库直通设计。
- 🏔️ **[MapLibre 3D 真实高程地形与贴地摄影视锥架构](docs/PERSPECTIVE_3D_TERRAIN_ARCHITECTURE.md)**：基于 AWS Terrarium
  DEM 的 WebGL 真实地貌渲染、全免 Key 多卫星图源热切换与 3D 贴地摄影视锥算法。

### ⚙️ 3. 核心调度引擎与元数据标准专题

- 📖 **[系统分阶段调度器与插件化架构设计](docs/ARCHITECTURE_AND_DESIGN.md)**：四阶段流水线编排、Dry-Run 预检屏障与软降级容错机制。
- 🏷️ **[ExifTool 元数据写入清单与跨软件兼容性全景规范](docs/EXIFTOOL_METADATA_SPECIFICATION.md)**：智能元数据分层模型、标签绝对幂等性清洗与
  Lightroom/Capture One 跨软件兼容性规范。
- 🛡️ **[ExifTool 常驻守护池与数据安全防污染设计](docs/EXIFTOOL_IO_AND_SAFETY_DESIGN.md)**：彻底根除子进程频繁 fork
  开销，单张读取性能达到 1.2ms。
- 🗺️ **[GeoNames 离线数据包与 3D KD-Tree 空间索引设计](docs/GEONAMES_AND_GEOCODING_DESIGN.md)**
  ：基于球面笛卡尔坐标的毫秒级离线高精逆地理编码与五级中文地名清洗。
- ⚙️ **[动态配置 Schema 与设置面板自描述设计](docs/CONFIGURATION_AND_SETTINGS_DESIGN.md)**：自描述能力插件配置契约与运行时会话覆盖。

### 📦 4. 打包构建与 Homebrew 分发专题

- 🍺 **[Homebrew 预编译二进制分发与发布指引 SOP](docs/HOMEBREW_RELEASE_GUIDE.md)**：跨平台 CLI 交叉编译、自包含 macOS DMG
  镜像自动打包与 Tap 仓库全自动推送。

---

## 📄 开源许可证 (License)

本项目采用 [MIT License](LICENSE) 开源许可证。

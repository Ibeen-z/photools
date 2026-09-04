# 📷 NikonGPS for iOS (尼康相机轻量化 GPS 同步中枢)

本项目基于对 [hurui200320/nsg](https://github.com/hurui200320/nsg)
和 [天空 Blond 协议逆向成果](https://skyblond.info/archives/1115.html) 的深度解析，专为 **iOS 平台（iPhone / iPad）**
重新设计与实现的 **尼康相机专属纯 GPS / 时间同步工具**。

旨在彻底解决官方 SnapBridge **“后台常被杀、发热耗电高、多机位（如双持 Z8 + Z50 II）无法同时同步 GPS”** 的核心痛点。

> [!NOTE]
> **【仅供学习交流与自力更生声明】**  
> 本工具 **仅供个人学习与技术交流**。项目源于对尼康官方颓败的 SnapBridge 长期不思进取、后台常被杀、发热耗电高的极度失望；加之新买的
Z6 III 机身使用不到半年手柄蒙皮便大面积开胶，官方售后却匪夷所思地坚称“非质量问题，系用户个人使用所致”并强行收费维修。官方的傲慢与软硬件摆烂彻底倒逼摄影师只能自力更生——既然售后指望不上，那就自己动手买胶换蒙皮；既然官方
App 难用至极，那就自己逆向协议写出真正好用、省电、支持双持多机位并发的纯粹同步工具！

---

## 🌟 核心特性

1. **专注 GPS 与时钟同步，极致轻量**：
    - 移除官方 App 繁重臃肿的照片传输、Wi-Fi 切换和云同步逻辑；
    - 仅保留 BLE 握手认证、10 字节 `TIME` 同步与 41 字节 `GEO` (WGS-84) 注入通道。
2. **多机位并发同步（双持摄影师福音）**：
    - 官方 SnapBridge 限制单设备连接；本项目底层采用多会话并发架构，单台 iPhone 获取到的 GPS 坐标可
      **同时分发注入多台处于就绪状态的尼康相机**。
3. **四维待机保鲜仲裁引擎 (`StandbyFreshnessArbiter`)**：
    - **消除死循环唤醒**：引入 120s 刚断开冷静期，拒绝盲目重连休眠中的相机；
    - **四级自适应滑动窗口**：结合 `CoreMotion` 运动协处理器，徒步/移动缩短至 5m 窗口，原地休整放宽至 20m 窗口；
    - **动转静瞬态捕获**：停步到达新机位瞬态直接优先授权刷新；
    - **30m 显著位移重连**与 **25m 弱 GPS 拦截**，杜绝漂移坐标污染。
4. **极速写入即断开机制 (Disconnect-on-Completion)**：
    - 待机保鲜坐标注入后延迟 600ms 主动断开，尼康相机从唤醒到重返深睡耗时从官方的 120s 骤降至 1~2s，省电高达 98%。
5. **系统级后台状态恢复 (CoreBluetooth State Restoration)**：
    - 采用 `App.init()` 首毫秒激活法则与固定恢复标识符（`com.vincentchyu.photools.mobile.ble`），App 即使被 iOS
      内存回收杀掉，相机开机也能在后台瞬间被动复活并注入 GPS；
    - 巡航状态与定位引擎持久化自愈。
6. **严格遵循相机协议防拒写纪律**：
    - **先时钟，后坐标**：每次建立连接或更新前必先写入 `TIME` 保证时钟同步，避免相机固件拒写 `GEO`；
    - **无效定位单次保护**：丢失卫星信号（如进入隧道/室内）时，仅下发一次 `0x00` 标记，彻底杜绝连续发送无效数据导致相机异常断连。
7. **100% 单元测试闭环**：
    - 核心库 `NikonGPSCore` 基于 Apple CommonCrypto 实现标准 Blowfish 算法；
    - 包含握手报文、Blowfish 加密、保鲜仲裁器、时区与 WGS-84 格式共 34 项单元测试。

---

## 📐 系统分层架构

```
ios/
├── Package.swift                    // SPM 跨平台包配置
├── App/                             // iOS 目标文件
│   ├── NikonGPSAppMain.swift        // SwiftUI @main 启动入口
│   └── Info.plist                   // 后台蓝牙/定位模式与权限说明
├── Sources/NikonGPSCore/            // 核心库
│   ├── Resources/                   // 外部配置文件
│   │   └── camera_credentials.json  // 自动装载的真机配对密钥 (由 extract_pklg_credentials.py 提取)
│   ├── Crypto/                      // 加密与认证
│   │   ├── Blowfish.swift           // 基于 CommonCrypto 的标准 Blowfish 加密器
│   │   └── NikonSecurityEngine.swift// 8 组 Salt 碰撞校验与 Stage 3 挑战生成
│   ├── Protocol/                    // 报文编码解码
│   │   ├── NikonUUIDs.swift         // 尼康 BLE 服务与特征 UUIDs
│   │   ├── PairingMessage.swift     // 17 字节 Stage 1~4 握手报文
│   │   ├── TimePayload.swift        // 10 字节时间与时区同步报文 (UTC)
│   │   └── GeoPayload.swift         // 41 字节 WGS-84 地理位置报文
│   ├── Models/                      // 领域模型
│   │   ├── CameraDevice.swift       // 相机配置与状态
│   │   └── SyncStats.swift          // 日志与位置快照
│   ├── State/                       // 状态机
│   │   └── CameraStateMachine.swift // 单相机握手状态机
│   ├── Services/                    // 平台后台服务
│   │   ├── CameraConfigLoader.swift    // 配置文件装载器 (多环境定位容错)
│   │   ├── NikonBluetoothManager.swift // 纯 CoreBluetooth BLE 调度与后台恢复
│   │   ├── LocationProvider.swift      // CoreLocation 高精定位与节电调度
│   │   ├── MotionActivityTracker.swift // CoreMotion 运动协处理器低功耗追踪
│   │   ├── StandbyFreshnessArbiter.swift // 四维待机保鲜仲裁引擎
│   │   ├── GPXRecorderService.swift    // 巡航轨迹后台持续记录
│   │   ├── GPXExporter.swift           // 标准 GPX 1.1 导出器
│   │   └── CameraSyncCoordinator.swift // 业务与 UI 调度中枢
│   └── Views/                       // 现代化 SwiftUI 界面
│       ├── MainDashboardView.swift  // 主仪表盘 (巡航控制、坐标、运动状态、相机卡片、日志)
│       ├── PairingGuideView.swift   // 相机配对向导
│       └── NikonGPSMainAppView.swift// 统一视图入口
├── tools/                           // 抓包与凭据提取工具箱
│   ├── extract_pklg_credentials.py  // 零依赖 PacketLogger 抓包解析与 100% 闭环验真工具
│   ├── HOW_TO_CAPTURE_PKLG_ON_IPHONE.md // iPhone 蓝牙抓包教程 (Sysdiagnose / PacketLogger)
│   └── captures/                    // 真实机型离线抓包样本库 (*.pklg)
└── Tests/NikonGPSCoreTests/         // 自动化单元测试
    ├── BlowfishTests.swift          // Blowfish 加密算法验证
    ├── HandshakeTests.swift         // 真实 Z6 III / Z50 II 抓包握手向量 100% 断言
    ├── StandbyFreshnessArbiterTests.swift // 冷静期、位移与自适应窗口断言
    ├── GPXRecorderTests.swift       // 漂移与弱信号过滤断言
    ├── CameraConfigLoaderTests.swift// 配置文件读取与十六进制转换测试
    ├── TimePayloadTests.swift       // 时间编码测试
    ├── GeoPayloadTests.swift        // 经纬度/海拔/WGS-84 格式拆解测试
    └── PairingMessageTests.swift    // 序列化与边界测试
```

> 📖 **详细技术规约**：参见完整设计文档 [
`docs/NIKON_IOS_BLUETOOTH_SYNC_AND_STATE_RESTORATION.md`](../docs/NIKON_IOS_BLUETOOTH_SYNC_AND_STATE_RESTORATION.md)。

---

## 🧪 核心单元测试验证

项目底层库支持直接在终端中进行秒级测试：

```bash
cd ios
swift test
```

测试覆盖范围包括：

- `BlowfishTests`：验证块加密正确性与确定性；
- `HandshakeTests`：通过真实相机握手捕获数据，验证从 Stage 1 到 Stage 2 成功命中 Salt 6，并生成字节完全一致的 Stage 3 报文；
- `TimePayloadTests`：验证小端序年份、时区偏移与夏令时；
- `GeoPayloadTests`：验证度、分、百分位、海拔正负及 `WGS-84` 报文结构；
- `PairingMessageTests`：验证新配对设备 ID 的 LSB 强制 0x01 等协议边界。

---

## 📲 在 iPhone 上编译与真机运行

1. 使用 **Xcode**（支持 Xcode 15+ / iOS 16+）打开项目：
    - 方式 A：在 Xcode 中选择 `File -> Open`，打开 `ios` 目录（Xcode 将自动识别为 Swift Package）；
    - 方式 B：创建一个新的 iOS App 项目（如 `NikonGPS`），将 `ios` 作为 Local Swift Package 添加为依赖，主入口引用
      `NikonGPSMainAppView`。
2. 确保在 Xcode 的 **Signing & Capabilities** 中：
    - 勾选 **Background Modes**：
        - `Uses Bluetooth LE accessories`
        - `Location updates`
3. 连接 iPhone，选择真机作为目标设备并点击 **Run (⌘R)**。

---

## 📷 相机端配对操作指南

首次使用前，需在尼康相机上完成一次配对：

1. 打开相机，按 `MENU` 进入 **网络菜单 (小天线图标)**；
2. 选择 **连接至智能设备** -> **配对 (Bluetooth)** -> **开始配对**；
3. 相机屏幕将提示「正在搜索智能设备」；
4. 在 iPhone App 中点击右上角 **「配对新相机」**；
5. 在列表中找到您的相机点击 **「连接配对」**；
6. App 会自动完成 Blowfish 握手并在相机中注册控制器名称（`iPhone_NikonGPS`）；
7. 相机屏幕显示「已连接到智能设备」，配对记录自动永久保存；
8. 之后日常使用无需重新配对：只要开启 App 内的 **「摄影巡航模式」**，相机开机或唤醒时会自动连接并注入 GPS！

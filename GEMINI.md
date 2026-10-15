# 📸 photools 项目持久化记忆与核心架构规约 (GEMINI.md)

本文档作为 AI Agent 在本工作区（photools 代码库根目录）的**唯一核心持久化记忆、技术规范与架构约束文件（Single Source of Truth）**。后续所有新增功能、架构演进、代码重构或测试均必须严格遵守本文档。

---

## 1. 核心定位与用户画像

- **用户画像**：Golang 程序员与尼康单反/微单摄影师；
- **系统核心定位**：专注于相机 RAW/JPG 照片导入电脑后的 **GPS 轨迹匹配、智能时间插值推算、离线高精逆地理编码中文地名清洗与规范化拍摄日期归档**；
- **语言规约**：所有交互、思维推理、终端输出、用户日志与异常提示**统一强制使用简体中文**；
- **系统边界与非目标**：
  - 本系统不是完整 DAM，不管理全部摄影资产生命周期；
  - 本系统不是后期调色软件，不承担 Lightroom/Capture One 等工具的职责；
  - 默认不包含云同步、评分筛选、非 ExifTool 独立 Exif 写入等脱离核心定位的功能。

---

## 2. 摄影资产模型与元数据写入规则

- **资产主文件优先模型 (Primary Asset Model)**：
  - 同 basename 的配套文件是一个独立的拍摄单元；
  - 核心操作遵循 **“主文件优先（PrimaryPath）”** 抽象：若存在 `RAW`，以 `RAW` 为主决策源并自动同步至伴随的 `JPG` 与 `XMP`；若仅有单 `JPG` 或单 `RAW`，该文件本身即作为完整主文件，平等享受 GPX 匹配、GPS 插值、逆地理与归档能力；
  - 若存在同 basename 的伴随文件（`XMP`、`ACR`、`WAV` 等），作为伴随文件整体同步维护并一同归档。
- **时间与轨迹匹配**：
  - 默认信任照片内的 `DateTimeOriginal` 与 `OffsetTimeOriginal`；
  - 默认 `geosync=0`，但必须支持显式时间偏移补偿；
  - 多个 `GPX` 文件必须逐个传参，禁止拼接成无效字符串。
- **写入顺序与二次校验**：
  - 双格式时必须先写主文件 `RAW`，再同步至 `JPG` 和 `XMP`；单文件时直接写入主文件并同步 `XMP`；
  - 写入成功判定**绝不能仅依赖 ExifTool 退出码**，必须包含二次读取校验，至少确认主文件上存在有效 `GPSPosition`。

---

## 3. 四大能力插件与分阶段屏障调度器 (Capability Architecture)

系统采用接口解耦的插件化架构，严禁将 GPX 匹配、推算、逆地理、归档杂糅在同一个单体函数中。

### 3.1 四大核心能力插件
1. **`gpx_matching` (Priority 10 · 阶段 1)**:
   - 依赖 ExifTool 进行 GPX 轨迹时间轴精准匹配；
   - 写入 RAW 经纬度并二次校验，无污染同步至伴随 JPG/XMP。
2. **`gps_interpolate` (Priority 15 · 阶段 2)** ✨:
   - **极速时间分桶与二分查找索引 (`AnchorIndex`)**：
     - 内存按拍摄日期 `YYYY-MM-DD` 分桶维护时间有序锚点切片，通过 `sort.Search` 二分查找在 $O(\log K)$ 纳秒级（~200ns）定位前后最邻近机位；
     - 批次首轮统一提取拍摄时间与坐标，彻底杜绝在检索循环中重复启动外部 ExifTool 子进程；
     - 双向锚点采用球面大圆时间权重线性插值，单向锚点采用同机位近邻继承，推算后动态合入索引供同批次后序照片自愈继承；
     - 默认推算窗口 15m（支持 `--interpolate-window` 自定义），开启 `--allow-no-gps` 时超出窗口安全跳过而不阻断流水线。
3. **`reverse_geocode` (Priority 20 · 阶段 3)**:
   - 基于 3D KD-Tree 离线高精空间索引；
   - 写入国家、省份、城市、区县、风景区 POI 中文元数据（IPTC/XMP），支持 IPTC Extension 完整结构化位置模型 (`LocationCreated` / `LocationShown`) 与 Lightroom 分层关键词标签树 (`XMP-lr:HierarchicalSubject`)；
   - **绝对幂等性与标签清洗铁律 (Idempotency & Clean-Merge)** ✨：
       - 严禁使用破坏幂等性的无脑追加（`+=`），必须采用 ExifTool 官方标准的“单次指令内原子置空并全量重写”模式（先置空
         `-XMP-lr:HierarchicalSubject=` 再重新赋值）；
       - 必须通过 `domain.CleanAndMergeLocationTags` 精准剥离旧地理层级树（`中国|` / `China|`），同时 **100%
         完整保护摄影师自定义业务标签与题材关键词**（如 `题材|人像|户外`、`扫街` 等），并使用 Set 机制保序去重；
       - 坐标缺失区县/POI 时必须显式置空相关标签，彻底杜绝跨机位纠偏时产生的“历史地名缝合怪”；
       - 写入后必须通过 `VerifyLocationTags` 进行二次回读断言，确认标签真实落盘且绝无重复项。
   - **离线地理数据包终端安装规约**：为保证地理数据库来源准确性、网络完整性与数据源校验，离线数据包严禁在 GUI 客户端内隐式下载安装，必须由使用者在终端（CLI）中显式执行 `photools geodata install <target>` 安装。GUI 仅负责状态探测、命令复制与 3D KD-Tree 坐标反查测试。
4. **`date_archive` (Priority 100 · 阶段 4)**:
   - 依据原始拍摄日期规范化重命名；
   - 原子安全归档至 `Processed/YYYY/MMDD/`（破坏性移动插件，必须具备最低优先级），完整保留 `.nef.xmp` / `.jpg.xmp` 复合侧车后缀。

### 3.2 阶段流转、调度器与性能契约
- **多阶段平滑交接与就绪判定**：
  - Dry-Run 预检判定：前序插件良性跳过（如已有 GPS 跳过插值）绝不阻断后序插件（如逆地理写入），只要整条链路无阻塞 Warning 且包含有效执行阶段，资产即判定为 `ReadyCount` 就绪；
  - 阶段 1 未命中 GPX 轨迹时，若流水线配置了阶段 2 插值插件，编排器平滑交接，严禁提前硬熔断。
- **全生命周期 `sync.Once` 与零冗余进程机制**：
  - 各插件 `Init()` 强制采用 `sync.Once` 缓存环境自检与 ExifTool 探针结果，预检与执行阶段毫秒级直通；
  - 离线地理数据包与 KD-Tree 建树全局单例装载一次，杜绝重复 I/O 与建树开销；
  - **ExifTool Stay-Open 常驻守护进程池 (`DefaultRunner`)**：生产环境默认启用常驻进程池（`StayOpenPool`），通过 `exiftool -stay_open True -@ -` 消除重复 `fork/exec` 子进程开销，单次读取开销从 ~30ms 骤降至 1~2ms，并具备进程崩溃自愈与优雅退出能力。
- **软降级容错 (`--allow-no-gps`)**：彻底无 GPS 照片在逆地理阶段良性跳过（不产生阻塞 Issue），安全进入阶段 4 按拍摄日期规范归档；
- **并发与待处理报告**：按 basename 资产组并发处理，处理中断或待补资产自动生成详尽的 Markdown 原因清单（默认 `~/.logs/photools/inbox_pending_report_latest.md`）；
- **全量实时中文日志流落盘 (Real-Time Log Streaming)**：
  - 流水线执行期间产生的全部中文实时事件流（含插件自检、阶段流转、每张照片推算/打标/归档进度与异常）强制实时流式落盘至用户主目录全局日志中心 `~/.logs/photools/photools_latest.log` 与带时间戳的 `~/.logs/photools/photools_YYYYMMDD_HHMMSS.log`，彻底杜绝在照片工作区目录产生 `Logs/` 垃圾文件；
  - 采用毫秒级带时区时间戳格式（`[HH:MM:SS.mmm] [LEVEL] [阶段] 消息`），并在任务结算时自动追加 Execution Summary 与异常清单；
- **直接扫描与扁平原地模式 (Direct Scan & Flat Mode)**：扫描范围与输出策略必须解耦。直接扫描模式递归处理所选源目录及其子目录（自动屏蔽
  `Processed`、备份、GPX、日志与隐藏目录），默认归档至该源目录的 `Processed/YYYY/MMDD/`
  ；扁平原地模式才忽略归档分层，就地逆地理/打标签并原地规范化重命名，且同一目录下重命名严格免自冲突；
- **智能元数据分层模型与四档策略 (`SidecarPolicy` · `--sidecar-policy`)** ✨：
  1. `smart`（默认/推荐 · 智能分层模式）：
     - **第二层修正事实 (GPS/时间修正)**：写入 RAW EXIF 头部 + 伴随 JPG 内嵌 + 同步 `.xmp` 侧车（附带 Photools 溯源指纹）；
     - **第三层派生信息 (中文地名/分层标签)**：RAW 严格只读仅写 `.nef.xmp` 侧车，JPG 交付格式直接内嵌写入；
     - 黄金平衡点：RAW 永久拥有标准 GPS 事实，地名由 XMP 承载，JPG 跨设备即开即看。
  2. `sidecar_only`（纯 XMP 侧车模式）：RAW 与 JPG 均不触碰原图，所有修正与派生元数据严格输出为独立 `{file}.xmp` 侧车；
  3. `embed_and_sidecar`（双写同步模式）：直接修改原图内嵌 EXIF，同时维护配套的 `.xmp` 侧车文件；
  4. `embed_only`（纯原图内嵌模式）：直接修改原图内嵌 EXIF，不产生或更新任何 `.xmp` 侧车文件。
- **伴随文件扩展名白名单 (`CompanionExtensions` · `--companion-exts`)** ✨：支持针对 RAW/JPG 主文件配套的伴随文件（如 `wav` 录音、`acr` 调色、`exf`、`xmp` 等）进行拓扑发现、原子同步流转与规范重命名归档；
- **统一设置抽象与会话覆盖 (Session & Plugin Settings)**：
  - 核心配置由 `internal/config/schema.go` 统一定义，全局参数与插件专属参数清晰正交解耦；
  - TUI 中按 `[s]` 调出全局设置，光标选中插件按 `[o]` 调出插件专属设置，输入路径支持 `[Tab]` 智能补全与多候选轮转；
  - 运行时基于 `SessionConfig` 动态覆盖，支持 `Enter` 会话生效与 `Ctrl+S` 持久化写入 `~/.config/photools/plugins.json`。
- **插件自描述与自配置契约 (Self-Describing & Configurable Capability)**：
  - 插件接口强制实现 `SupportedOptions() []OptionSpec` 与 `Configure(opts map[string]any) error`；
  - 插件自身完全内聚掌管自己的可配置选项、默认值、说明与预设候选值（Choices）；
  - TUI 界面与 Pipeline 构建器基于元数据纯动态驱动，彻底杜绝针对具体插件的外部硬编码 `switch-case`。

---

## 4. 核心工具包单元测试 100% 闭环规范 (AI 必遵)

所有核心底层工具包（`internal/exiftool`、`pkg/geocoding`、`internal/engine`、`pkg/geodata`、`internal/pipeline` 等）必须提供 **100% 完整的对外接口测试闭环**：

1. **导出函数全覆盖**：所有首字母大写的 Exported 函数必须在 `*_test.go` 中有直接对应的单元测试，严禁只测辅助函数漏测核心业务函数；
2. **测试隔离性与 Mock**：外部系统调用（如 `exiftool` 二进制执行、网络下载）必须通过 Runner/Client 抽象注入 Mock，`go test ./...` 必须在纯净环境中秒级通过；
3. **元数据防污染断言**：
   - GPS 写入/同步函数必须断言**仅操作 `-GPS:*`**，绝不能混入 IPTC/Photoshop 地名标签；
   - 逆地理地名写入函数必须断言**仅操作地名标签**，绝不能混入 GPS 坐标标签。
4. **全分支边界覆盖**：覆盖成功路径、空入参安全返回、格式畸变、错误分类（`ClassifyFailure`）等全部分支。

---

## 5. 主动式零技术债务与工程纪律 (AI 必遵)

1. **严禁硬编码魔法值 (No Magic Values/Strings)**：
   - 严禁在业务代码、插件逻辑或测试中散落硬编码字符串（如插件 ID、GPS 来源、推算算法、侧车策略、阶段名称、日志级别、默认扩展名等）；
   - **全局枚举与通用常量必须统一定义在根目录的 `common` 包中**（`common/enums.go`），其他模块（如 `internal/domain`、各能力插件等）通过引用或类型别名（Type Alias）使用，保证全局唯一事实源；
2. **禁止被动等待发现**：AI 助手在每次架构调整或功能演进时，必须主动全库扫描死代码、过时包与残留引用，主动清理与重构；
3. **历史废弃包物理移除**：一旦新架构方案落地并验证无误，被替代的旧包必须立即物理删除；
4. **CLI 与 Shell Tab 自动补全 100% 同步**：新增、修改或弃用任何 CLI 命令或参数时，必须同步增量维护 `internal/completion/`
   ，确保 Zsh、Bash、Fish 补全脚本与 CLI 保持一致；
5. **严禁泄露与提交用户敏感数据 (Strict Privacy & Zero Leakage Discipline) 🛡️**：
    - **绝对红线**：严禁将任何用户个人真实相机硬件信息、真实机身序列号（如 `801209` 等真实 7~8 位硬件号）、真实蓝牙配对凭据（如
      `DeviceID`、`Nonce`、通信密钥哈希）、蓝牙物理 MAC 地址、真实个人控制器设备名（如 `iPhone14_GPS`）、个人真机抓包文件（
      `*.pklg`、`sysdiagnose`）硬编码或写入代码、单元测试、技术文档、Git 暂存区或示例配置中；
    - **配置文件脱敏规范**：本地私有配置文件（如 `camera_credentials.json`）必须由 `.gitignore` 严格忽略，外部仅提供脱敏的占位/示例文件（如
      `camera_credentials.example.json`）；
    - **抓包文件隔离规范**：所有 `*.pklg` 抓包文件由 `.gitignore` 全局拦截，抓包目录（`captures/`）仅允许提交说明文档（如
      `README.md`），严禁提交任何真实抓包或空二进制占位文件；
    - **代码与单测规范**：业务代码兜底与单元测试用例中的机身名称、序列号与配对凭据，一律使用通用合法 Mock/Demo 占位（如
      `Z6_3_1234567`、`12****7`、`0x12345678`、`0x87654321`、`iPhone_NikonGPS`），杜绝绑定任何真实私有设备；
    - **UI 与日志脱敏**：所有界面卡片展示和控制台输出的相机序列号必须强制经过 `CameraDevice.maskText` / `maskName` /
      `maskSerialNumber` 脱敏过滤；
    - **AI 变更自检义务**：AI Agent 在执行任何改动、提交建议或创建文档前，必须主动审查是否存在真实硬件凭据或设备标识泄漏。

---

## 6. 未来新增/重构能力插件标准开发闭环规范 (Plugin Development SOP)

未来任何时候为 photools 扩展或重构能力插件，AI Agent **必须无条件、按序且 100% 完整执行以下 7 步闭环流程**：

1. **`common/enums.go` & `internal/domain/capability.go`**：在 `common` 注册 `CapabilityID` 常量并实现 `Capability` 接口（包含 `SupportedOptions()` 与 `Configure()`）；
2. **`internal/capabilities/<plugin>/`**：在能力包内部实现业务逻辑、自描述配置契约 `SupportedOptions()` 与 `Configure()`，并提供独立单元测试；
3. **`internal/config/plugins.go`**：在 `defaultMetas` 注册并实现 `~/.config/photools/plugins.json` 自动自愈迁移逻辑，同步更新 `plugins_test.go`；
4. **`internal/pipeline/`**：在 `builder.go` 接入 `PipelineOptions`，并在 `orchestrator.go` 编排阶段流转与降级容错；
5. **`cmd/photools/` & `internal/completion/`**：增加 CLI 选项，并**100% 同步维护 Zsh / Bash / Fish Tab 自动补全脚本**；
6. **`internal/tui/`**：在 TUI 注册插件项、分配快捷键（如 `[1/2/3/4]`）、光标空格勾选，由自描述 Schema 自动渲染专属设置面板，同步更新 `model_test.go`；
7. **规约与持久化文档同步**：同步更新 `GEMINI.md` 与 `README.md`。

---

## 7. macOS 原生客户端与跨语言 (C-Shared FFI) 开发规约

1. **架构文档**：所有 macOS 相关的系统分层、C ABI 导出符号、内存管理契约、EXIF 解析流水线与 UI/UX 规范统一维护在 [`docs/MACOS_CLIENT_TECHNICAL_DESIGN.md`](docs/MACOS_CLIENT_TECHNICAL_DESIGN.md)；
2. **双引擎直通与降级**：
   - 优先通过 `libphotools.dylib` 进行进程内 C-Shared FFI 极速直通（~0.1ms，单例常驻）；
   - 缺失动态库时必须平滑无缝降级至 CLI 异步子进程模式，严禁界面崩溃；
3. **C-ABI 内存安全绝对纪律**：
   - 所有 Go 端 `C.CString` 返回给 Swift 的指针，Swift 端必须通过 `defer { fnFreeString?(ptr) }` 释放，严禁内存泄漏或野指针重复释放；
4. **主资产与排序**：
   - 资产列表必须以 `PhotoAssetGroup`（配套单元组）为核心展示单位；
   - 扫描阶段必须提取主文件 `fileModificationDate`，默认提供时间升序/降序及文件名升序/降序多维排序。
5. **已归档资产 (Processed) 层级下探与极地冰蓝冻结 UI 体系** ✨：
    - 必须提供子目录层级下探（`ProcessedFolderItem` + 面包屑导航 `Processed > 2026 > 0101`）与全局递归平铺双重浏览架构；
    - 已归档资产全面采用极地冰蓝（`Cyan / Frost Blue`）冻结只读视觉语义，列表卡片配备安全锁盾徽章与雪花图标，详情面板常驻只读横幅，严禁提供删除等破坏性操作；
    - 资产统计口径必须严格遵从 Primary Asset Model，统一显示资产组数（`processedAssetGroupCount`），杜绝与底层物理碎文件总数产生认知分歧；
6. **全键盘极速看图与系统原生 QuickLook 浮层联动** ✨：
    - 在待选（Inbox）与归档（Processed）列表中，按空格键（Space）瞬间唤起/关闭系统原生 QuickLook 大图浮层；
    - 必须接入进程级 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 拦截，彻底规避 QuickLook 浮层夺焦成为 Key
      Window 后导致列表方向键失效的 AppKit 系统级难题；
    - 按 `↑ / ↓ / ← / →` 方向键切图时，同步刷新 `selectedAssetID` 并向底层发送 `QLPreviewPanel.shared().reloadData()`
      强制刷新大图，配合 `ScrollViewReader` 自动平滑居中滚动跟随；输入框打字通过 `@FocusState` 深度防误触；
7. **全局常驻底部状态栏防呆中枢与专业时间排版** ✨：
    - 底部全局常驻四档色彩策略徽章（智能分层/纯XMP/双写同步/纯内嵌），采用原生带 checkmark 的 Button 列表规避 Menu 嵌套
      Picker 导致的 Label 丢失 Bug，确立为全应用唯一的执行策略确认与保护中枢；
    - 照片核心拍摄时间（`DateTimeOriginal`）统一采用高亮等宽半加粗蓝色（`Color.blue`）展示，强化关键时间事实的可读性与专业质感。
8. **MapLibre 3D 真实高程地形与全免 Key 多图源架构** ✨：
    - 独立技术设计详见 [`docs/PERSPECTIVE_3D_TERRAIN_ARCHITECTURE.md`](docs/PERSPECTIVE_3D_TERRAIN_ARCHITECTURE.md)；
    - 基于 AWS Terrarium DEM 高程切片与 MapLibre WebGL 呈现真实地貌起伏与山体阴影，在 3D 地形表面实时计算并投射真实等比例贴地视锥多边形（GeoJSON
      Polygon）；
    - 内置 **Google 纯卫星、Google 混合地球、高德遥感卫星与 ESRI 全球遥感** 四大图源， **100% 免 API Key**；
    - **坐标系自适应零污染铁律**：Google 与 ESRI 切片采用纯正 WGS-84，直接以原始真实物理坐标落点， **实现 0
      偏移物理级绝对贴合**；高德切片自动施加 GCJ-02 纠偏（国内东南偏移 630 米）；原图 EXIF 物理事实绝对不被污染；
    - 离线前端资源（MapLibre JS/CSS）内联打包至 App Bundle，野外断网 0ms 瞬间加载。
9. **触控板双指自由旋转与摄影姿态解耦铁律** ✨：
    - 接入 WebKit 原生 Mac 触控板 `gesturechange` 旋转手势，双指轻旋即可自由平滑旋转地图的东南西北（Camera Bearing）；
    - **严格解耦**：地图无论如何旋转，视锥在地理经纬度保持不动， **绝对严禁覆盖照片的拍摄朝向（Heading）**
      ；照片朝向仅受底栏滑杆、正八向预设（北/东/南/西）与精调按钮控制；
   - **摄影参数三维精调控制系统**：对数视距上限全面扩展至 $150\text{km}$（$15\text{m}\sim150\text{km}$
     ，充分覆盖乌鲁木齐遥望博格达峰 $\sim60\text{km}$
     、四姑娘山、川西及西藏雪山群峰极限远眺），提供多阶自适应物理尺度精调（$<100\text{m}$
     步长 $\pm10\text{m}$；$100\text{m}\sim500\text{m}$ 步长 $\pm25\text{m}$；$500\text{m}\sim2000\text{m}$
     步长 $\pm100\text{m}$；$2\text{km}\sim10\text{km}$ 步长 $\pm250\text{m}$；$10\text{km}\sim30\text{km}$
     步长 $\pm1\text{km}$；$>30\text{km}$ 步长 $\pm5\text{km}$
     ）与主体对焦距离一键锁定；俯仰角提供 $\pm 5^\circ / \pm 1^\circ$ 连续精调。
10. **全链路系统代理内核调度中枢 (`NetworkProxyManager`)** ✨：
    - 集中管理系统代理与 HTTP/SOCKS5 代理配置，实现 POSIX 环境变量、WebKit/URLSession 网络栈与 Go 核心引擎 FFI
      三层统一调度穿透，兼容无 TUN 虚拟网卡环境；
    - 单一事实源持久化写入 `~/.config/photools/plugins.json`。
11. **客户端五大高性能支柱与高频日志节流规约** ✨：
    - **单遍扫描与属性预取**：`WorkspaceScanner` 采用单遍递归（`scanAssetGroupsWithCount`）合并资产组与碎文件统计，利用
      `includingPropertiesForKeys` 预取属性，磁盘 I/O 耗时降低 50%~70%；
    - **纳秒级 LRU 元数据缓存**：`ExifMetadataReader` 维护 600 条 `NSCache`，快速切图时 $<0.01\text{ms}$ 直出，跳过跨语言开销；
    - **80ms 日志批量节流**：`WorkspaceStore` 对高频爆发日志聚合在 80ms 窗口推送，并于状态切换时即时清空，抑制主线程重绘风暴；
    - **视图排序记忆化**：`AssetListView` 借助 `AssetFilterCache` 消除无参变动时的 $O (N \log N)$ 重复排序；
    - **3D 地图容器防抖**：`PhotoPerspective3DMapView` 借助 `lastBoundsSize` 脏检查阻断无意义跨进程 IPC。
12. **双质量缩略图分级与隔离缓存铁律 (`ThumbnailQuality`)** ✨：
    - **画质严格分级解耦**：列表（`ThumbnailQuality.list`）优先读取相机 160px 内嵌小图（<1ms 极速齐刷）；详情（
      `ThumbnailQuality.detail`）强制禁用低清内嵌图，走 ImageIO 原图 2.5x 超采样高保真解码（0.92 JPEG
      质量），彻底根除详情大图拉伸模糊（马赛克）；
    - **物理隔离磁盘缓存**：统一落地至 `~/Library/Caches/photools/thumbnails/v2/`，Key 携带 quality 标识，互不覆盖污染；
    - **Scoped Lock 与零警告编译**：使用 `SendableImageResult` 容器封装，Scoped Lock 任务去重，彻底消除 Sendable 与 async
      lock 警告；`.task(id:)` 绑定修改时间自愈刷新；
    - **未选中照片原生空状态防呆**：`selectedAssetID == nil` 时严格返回 `nil`，无选中时右侧展示原生 `EmptyDetailStateView`
      ，严禁强行展示未经排序的第一张物理文件。
13. **GPX 轨迹 3D 真实高程渲染与流式抽稀规约** ✨：
    - **多维直达交互**：GPX 轨迹列表右键菜单首项提供 `[ 🗺️ 在 3D 地图中查看轨迹 ]`，行尾配备 `[ 🏔️ 3D 漫游 ]`
      按钮并支持双击直达，单击联动右侧专业空间档案看板（里程/海拔/爬升/起止）；
    - **立体发光与黄金俯瞰**：基于 MapLibre 3D DEM 呈现高对比度双层/三层立体轨迹（底层加重玄武黑防撞色保护边 `#090d16` +
      核心高饱和户外活力亮橙主线 `#ff7a00` 🟠）与极光绿起点 / 珊瑚红终点地标，以 55° 俯瞰角自适应铺展（`fitBounds`）；
    - **免 Key 多图源热切换与纠偏**：无缝支持 Google 纯卫星、Google 混合地球、高德卫星（GCJ-02 纠偏贴地）与 ESRI 全球遥感；
    - **流式解析与智能抽稀**：苹果原生 `XMLParser` 流式解析，超长轨迹自动采样至 2000 点，兼顾细腻走向与 WebGL 60fps 极限丝滑；
    - **全链路 3D 地图与轨迹加载 HUD 体系** ✨：窗口毫秒级即时响应弹出，集成 Cyber
      科技感加载遮罩、动态双环雷达脉冲、发光渐变进度条与等宽数字百分比（0%~100%），流式动态汇报三维航点解析、高程剖面计算、DEM
      数字地形网格载入与遥感卫星拉取全阶段，彻底根除白等与黑屏盲等焦虑；
    - **航迹与打卡航点物理隔离与对标 GPXSee 独立渲染 (Waypoints & Track Isolation)** ✨：
        - GPX 规范严格区分连续运动轨迹（`<trkpt>`）与离散地理打卡点（`<wpt>`）；
        - 严禁将离散 `<wpt>` 打卡点混入连续轨迹折线数组，彻底根除首尾打卡点与徒步起点相连引发的数十公里横穿山脉大飞线，以及总里程翻倍暴增与起点海拔
          `--m` 致命缺陷；
        - 轨迹折线纯净由 `<trkpt>` 构成，离散打卡点独立提取为 `GPXWaypoint`，在 3D 地形表面以独立发光青蓝圆点（`#06b6d4`）、带
          1.8px 玄武黑轮廓保护的地名文本标签（防雪山地貌撞色）与悬浮磨砂气泡 Popup 呈现，完美对标并超越 GPXSee 专业体验。
14. **GPX 真实爬升抗噪算法与海拔/心率双轴剖面看板** ✨：
    - **滞后门限抗噪爬升算法 (Hysteresis Thresholding)**：高频采样轨迹（如 1Hz 步长 <1m）单步高程变化微小（0.1~
      0.3m），传统固定步长阈值（`diff > 0.5m`）会导致长距离缓坡累计爬升被当成噪点全部吞噬（如喀拉峻 34km 仅算得
      +18m）；系统重构为移动平均滑动平滑 + 滞后门限（2.0m）波峰波谷波形算法，在科学剔除 GPS 垂向抖动噪点的同时，100%
      完整捕捉真实爬升（喀拉峻小环线精准测算为 `+1529m`）；
    - **心率流式提取与空间档案**：支持 `<gpxtpx:hr>`、`<hr>`、`<heartrate>` 多厂商格式解析，并在右侧空间档案与 3D
      漫游视窗中展示平均/最高心率统计；
    - **双轴剖面看板与 3D 光标联动**：在 3D 地图窗口底栏集成 Canvas 60fps 高清渲染的悬浮磨砂 HUD，双 Y 轴呈现海拔面积图（户外活力亮橙发光填充
      `#ff7a00`）与心率折线图（珊瑚红发光曲线 `#ef4444`），支持鼠标十字准线 Tooltip、3D 地形光标在山峦间实时跟随滑行，以及单击剖面图镜头平滑飞跃（Fly
      to）至对应地理机位；
    - **两步路 & Strava 标杆级 3D 循迹与漫游体系 (Avatar Puck & Traversed Trail)** ✨：
        - **专业放大版 3D 运动人物主体 (Avatar Puck)**：放大至 52px 醒目规格，集成亮橙脉冲扩散环、24px 纯白实心核与 3.5px
          加重黑边、 **放大版（14px×15px）自适应指向前进航向的亮橙罗盘三角锐箭**与伴随常驻的悬浮空间气泡（`🚩 里程 · 🏔️ 海拔`
          ），人物在山峦峡谷中穿行位置与朝向一目了然；地图旋转时罗盘箭头实时校准前进角；
        - **已走轨迹动态生长橙黑流光线 (Dynamic Traversed Trail)**：三层渲染（底层 9.5px 加重玄武黑保护边 `#090d16` + 中层
          7.0px 亮橙辉光过渡 `#ff7a00` + 顶层 4.5px 高饱和实体亮橙核心），彻底根除雪山与卫星底图撞色发虚隐形，随巡航或拖拽实时向前延伸生长；
        - **彻底告别瞎转：前方 200m 宏观切线 + 8° 死区 + 0.04 强阻尼滤波**：抛弃局部微观锯齿计算，基于前方 200m
          宏观前瞻矢量提取山脉走向，直道微弯镜头稳如磐石，仅在大弯道时极缓平顺转向；
        - **两步路经典双视角模式**：默认提供 **【🧭 正北鸟瞰（最清晰稳健不眩晕）】** 与 **【🎬 平滑追随（沿山势极缓跟转）】**
          一键自由切换，支持 1x/2x 巡航倍速与随时拖拽接管；
        - **动态视口安全区避让 (Dynamic Viewport Padding) 杜绝 UI 遮挡** ✨：
            - 全景总览强制接入 `getOverviewPadding()`，注入非对称安全区（`left: 240, top: 110, bottom: 220`），彻底避开左上角
              380px 浮动 HUD 看板与底栏，整条轨迹自然居中于右下方未遮挡区，根除西北段终点被卡片遮挡；
            - 相机跟随 (Camera Follow)、巡航漫游 (Auto Cruise) 与单点飞跃 (Fly to) 强制接入 `getCameraPadding()`，将运动主体
              (Avatar Puck) 严格对齐保持在未被遮挡的可视净空中心；
            - 全景总览与人物随行状态明确互斥：退回全景自动解散跟随激活态，开启随行或点击巡航瞬间以 900ms 丝滑平滑推进至人物第一机位（Fly
              to Zoom 15.0）。
        - **右侧 3D 姿态云台控制台中枢 (Gimbal & Compass Cockpit)** ✨：
            - 右侧悬浮磨砂玻璃面板，集成 **东西南北方位角水平横杆 (Bearing 0°~360°)** 与 **俯仰角调节拉杆 (Pitch
              0°~80°)**；
            - 提供正八向快捷预设（【北 N】带高亮红针一键瞬间 0° 回正正北，【东 E】/【南 S】/【西 W】一键转向）与俯仰角黄金预设（【0°
              上帝顶视】用于宏观走线核对，【50° 直升机鸟瞰】默认推荐呈现震撼雪山起伏，【75° 贴地平视】用于峡谷穿行沉浸大片）；
            - 双向 60fps 实时同步：触控板旋转手势或右键倾斜地图时，右侧滑杆与实时角度数值反向自动跟随，拖拽滑杆时地图无延迟丝滑响应，解决触控板手势不便难题。
        - **剖面图三层意图分工与摄影师姿态绝对保护 (Profile Intent Decoupling & Attitude Guard)** ✨：
            - **悬停纯预览 (Hover Preview)**：鼠标/触控板在剖面图上悬停滑动仅更新垂直红线标尺与 HUD 海拔/心率/里程数值，联动
              3D 地形光标在山脊上滑行， **严禁拉扯移动相机画面**，让摄影师心无旁骛对照数据；
            - **点按/拖拽切入随行 (Click & Drag Scrubbing)**
              ：仅在触控板点按（Click）或按住沿剖面图横向拖拽（Scrubbing）时，才瞬间切入轨迹随行（Follow）并同步生长已走流光轨迹线；
            - **摄影师姿态绝对保护铁律**：手动点按机位或拖拽随行时，镜头中心平滑跟随至地理坐标，
              **但方位角（Bearing）与俯仰角（Pitch）严格保持摄影师在云台控制台或触控板确立的手动构图角度**（直接继承
              `map.getBearing()` 与 `map.getPitch()`），彻底杜绝系统擅自重置或覆盖摄影师视角；
            - **剖面图折叠防死锁与安全视口夹紧规约 (Profile Collapse Resilience & Clamping)** ✨：
                - **全生命周期拖拽锁释放**：在折叠/展开或 DOM 突变瞬间，无条件强制复位 `isDragging = false`，并通过
                  `window` 级别 `mouseup` / `pointerup` / `pointercancel` / `blur` 多重监听彻底斩断 WebKit 拖拽捕获死锁；
                - **数学级安全边界夹紧 (`clampPadding`)**：相机避让与全景视口强制受限于容器高宽的 65%（
                  `top + bottom <= height * 0.65`），折叠态使用 44px 安全基准，彻底根除 MapLibre
                  `padding is greater than canvas size` 致命异常；
                - **Canvas 0x0 渲染保护与异常隔离**：折叠态跳过 Canvas 绘制并强制隐藏 Tooltip，所有相机运动与滑杆输入全量包裹
                  `try-catch` 防御网，确保整屏交互 100% 稳健流畅；
                - **剖面图物理里程二分查找对齐铁律 (Distance-Based Binary Search Alignment)** ✨：
                    - 剖面图 X 轴是按物理累计里程（`dist`，单位 km）线性绘制的；
                    - 严禁将鼠标横向比例（`ratio`）直接乘以数组下标点数（`ratio * (length - 1)`
                      ）！户外徒步爬坡慢停顿多点密集、下坡快平路点稀疏，点密度分布严重非线性；
                    - 必须通过 `targetDist = ratio * maxD` 结合 $O (\log N)$ 二分查找（`findClosestIndexByDist`
                      ）精准定位距离最接近的数据点，实现鼠标十字指针（crosshair）与垂直标尺线、白芯高亮点、气泡及 3D
                      地图机位 <0.5px 的绝对严丝合缝重合，彻底根除波峰高点与指示线左右上下错位的致命缺陷。
            - **3D 轨迹全链路高性能优化与业务交互隔离规约 (Performance & Isolation Protocol)** ✨：
                - **底图热切换零重构**：严禁在 `GPXTrackPerspectiveSheet` 外层使用包含图源变量的 `.id`，统一放通
                  `updateNSView` 中的 `window.switchTileProvider` 实现 0 闪烁底图毫秒级平滑热更新；
                - **WebKit 全生命周期资源释放 (`dismantleNSView`)**：退出视图时强制调用 `window.destroyMap` 执行
                  `map.remove()` 清理 WebGL 显存纹理与停止全部定时器/RAF，调用 `removeAllScriptMessageHandlers`
                  彻底斩断强引用环，根除显存泄漏；
                - **Canvas Framebuffer 显存零抖动**：`canvas.width/height` 仅在真实 resize 时更新，常规帧渲染仅执行
                  `clearRect`，显存缓冲区重分配降为 0；
                - **流光线与地图拾取双重 RAF 节流**：巡航流光线更新（`updateTraversedLine`）与地图悬停拾取（
                  `findClosestIndexFast`）全面接入 `requestAnimationFrame` 调度，局部 $\pm150$ 点小窗口收敛，彻底杜绝 CPU
                  争抢；
                - **静态资源内存单例直出**：1.2MB MapLibre JS 与 CSS 采用全局单例常驻内存，弹窗唤起 0ms 磁盘 I/O；
            - **3D 照片视角与 GPX 轨迹地图切片加载与生命周期铁律 (3D Map HUD & Lifecycle Guard)** ✨：
                - **首屏冷启动 HUD 确定性事件驱动**：首屏全屏加载遮罩采用纯确定性阶段事件驱动（引擎启动 25% -> 视锥/轨迹构建
                  60% -> DEM网格 65% -> 卫星切片 95% -> 100% 就绪），利用 CSS `transition: width` 原生硬件加速平滑过渡，严禁堆砌
                  `setInterval` 累加轮询、自制版本号与嵌套定时器；
                - **彻底废除 `map.once('idle')` 假空闲误判**：MapLibre GL 实例化第一帧本地空闲时会派发假 `idle`
                  ，严禁直接绑定关闭遮罩；必须通过 `isSatelliteLoaded` 与 `map.areTilesLoaded()`
                  组合断言，确认远程卫星遥感切片真实到达且图层构建就绪后才允许淡出，并配以 3.5s 兜底定时器平滑消隐，绝不卡死；
                - **底图热切换 (switchTileProvider) 纯静默流式换源铁律**
                  ：卫星图源切换（Google/高德/ESRI）属于运行时局部切片热替换，严禁重新拉起全屏黑色模态遮罩打断用户操作；MapLibre
                  在后台流式拉取并自动渐变替换切片，彻底根除换图源时遮罩死锁在 100% 的架构硬伤；
                - **3D 地貌相机防穿透安全包络铁律 (Terrain Collision Envelope)** ✨：在启用 3D DEM 真实地形时，相机的渲染俯仰角强制夹紧至安全上限
                  `min(pitch, 60.0°)`，地图初始化 `maxPitch` 限制为 62°。长焦仰拍照片（如仰角 75° ~82°、海拔 2650m）UI 界面
                  100% 保真显示原始物理参数，但渲染相机始终居高临下（55°~60°）俯瞰机位与视锥，从物理几何上彻底杜绝相机沉入地层触发
                  WebGL 背面剔除导致的纯黑屏现象；JS 端更新锁设 350ms 兜底复位，彻底杜绝按钮操作锁死。

---

## 8. Homebrew Tap 双通道分发与维护规约 (vincentchyu/tap)

1. **双通道架构与分工**：
   - **默认通道 (`Formula/photools.rb`)**：`brew install vincentchyu/tap/photools`，面向开发者与全键盘终端用户。声明 `depends_on "exiftool"` 自动解决核心底层依赖，在 `install` 阶段自动生成并注入 Zsh、Bash、Fish 自动补全脚本；
   - **桌面通道 (`Casks/photools.rb`)**：`brew install --cask vincentchyu/tap/photools`，面向桌面摄影师。自动拉取 `photools-macOS.dmg` 并将 `PhotoolsApp.app` 安装至 `/Applications`；
2. **本地自动化发布闭环**：
    - 本地预编译并打包各平台产物后，执行 `./script/release_homebrew.sh <tag> --push` 自动计算本地二进制与 DMG 镜像的
      SHA256，更新 Formula/Cask 并秒级同步推送至 `vincentchyu/homebrew-tap` 仓库；
   - **动态 Git Tag 注入与 BuildInfo 兜底**：编译期通过 `-ldflags "-s -w -X 'github.com/vincentchyu/photools/common.CurrentVersion=$(git describe --tags --always)' -X 'main.Version=$(git describe --tags --always)'"` 动态注入版本，结合 `runtime/debug.ReadBuildInfo()` 智能兜底。

---

## 9. 全局多语言 (i18n) 统一字典与运行时规约

详细架构与开发规约见独立技术文档：[`docs/I18N_ARCHITECTURE_GUIDE.md`](docs/I18N_ARCHITECTURE_GUIDE.md)。

1. **单一事实源 (Single Source of Truth) JSON**：
   - 全局字典统一定义在 `locales/zh-CN.json`（简体中文）与 `locales/en-US.json`（英文）中；
   - Go 端通过 `locales/locales.go` 的 `//go:embed *.json` 静态内嵌，运行时零额外 I/O 损耗；
   - Swift macOS 端共用相同键名模型并由 `LanguageManager.swift` 维护；
2. **全链路运行时事件与控制台日志 100% 本地化**：
   - 流水线调度器、阶段屏障流转、四大能力插件内部执行日志、异常诊断建议与落盘日志（`~/.logs/photools/photools_latest.log`）全部基于 `i18n.T` 动态本地化；
   - 阶段名称通过 `domain.StageDisplayName` 动态投影，彻底杜绝日志中硬编码中文字符；
3. **默认中文优先、热切换与自动化守卫测试**：
   - 默认模式符合核心摄影师用户画像（`zh-CN` 优先），支持 CLI `--lang [zh|en]`、TUI 快捷键 `[l]`、macOS 设置面板无缝热切换；
   - 强制运行 `internal/i18n/i18n_guard_test.go` 验证中英文字典 100% 镜像对称与纯英文模式下零中文字符泄漏。

---

## 10. 本地开发环境与 Go 工具链执行规约 (asdf & Go Runtime Protocol)

1. **Golang 版本管理体系 (asdf)**：
    - 使用者的 Go 环境通过 `asdf` 进行多版本管理；
    - 当前项目活跃使用的 Go 版本为 `1.27.1`（二进制路径：`/Users/vincent/.asdf/installs/golang/1.27.1/go/bin/go`）；
    - 可用版本池包括：`1.24.3`、`1.25.1`、`1.26.2`、`1.27.1`；
2. **沙盒与终端命令执行要求**：
    - 默认沙盒环境下直接调用系统 PATH 中的 `go` 可能会因沙盒文件访问隔离提示无权限（`Operation not permitted`）；
    - AI Agent 在执行 `go test`、`go build`、`go mod` 等 Go 相关命令时，知晓宿主机的真实 Go 二进制位于
      `/Users/vincent/.asdf/installs/golang/1.27.1/go/bin/go`，并在需要外部 Go 工具链时显式请求沙盒穿透（
      `BypassSandbox: true`）或使用绝对路径。
3. **Modern Go 现代语法规范守卫 (`use-modern-go`)**：
    - 凡是涉及编写、修改或重构 Golang 后端代码，AI Agent 必须主动在当前会话中读取并严格遵从 `use-modern-go` 技能（Modern Go
      Guidelines），编写符合目标 Go 版本的现代、地道 Go 代码（优先使用 `slices.Contains`、`slices.Index`、`maps`、`cmp.Or`、
      `min/max`、`clear` 等），坚决禁止手写传统低效冗长循环与落后过时模式。

---

## 11. 元数据分层写入调度器与职责边界架构铁律 (AI 必遵)

详细架构与边界规约见独立技术文档：

- [**`docs/EXIF_VISUAL_PIPELINE_END_TO_END_SPEC.md`**](docs/EXIF_VISUAL_PIPELINE_END_TO_END_SPEC.md)（ExifTool
  数据解析、视觉三维构造与元数据分层写回全流程技术规范）；
- [`docs/METADATA_POLICY_DISPATCHER_ARCHITECTURE.md`](docs/METADATA_POLICY_DISPATCHER_ARCHITECTURE.md)（元数据分层写入调度器策略设计）。

1. **严禁各家各写一套策略调度 (No Scattered Policy Logic)**：
    - 严禁在任何能力插件（如 `gpx_matching`、`gps_interpolate`、`reverse_geocode`）或客户端操作中单独手写针对
      `SidecarPolicy` 的 `switch` 分支；
    - 全库所有 GPS 写入必须统一步调调用 `exiftool.WriteGPS`，所有地名写入必须统一步调调用 `exiftool.WriteLocation`；
2. **原子能力与策略编排彻底解耦 (Primitives vs Dispatcher)**：
    - **下层 (`internal/exiftool`)**：保持绝对纯净，仅提供单一职责的原子工具函数（如 `WriteCoordinates`、
      `CloneAllGPSMetadata`、`WriteLocationToMedia`、`WriteLocationToXMP`、`VerifyGPSTags` 等），严禁掺杂业务策略；
    - **中层 (`internal/exiftool/dispatcher.go`)**：统领拍摄单元资产组（`domain.AssetGroup`）在四档策略（`smart`、
      `sidecar_only`、`embed_and_sidecar`、`embed_only`）下的物理调度，并集中保证二次读取回验；
3. **全场景元数据写入职责边界矩阵 (Writing Boundary Matrix)**：
    - **第二层修正事实 (`gpx_matching` / `gps_interpolate` / 快捷键手动写入)**：仅操作 GPS 经纬度、海拔与时间戳，
      **绝对严禁写入或触碰任何中文地名/IPTC 标签**；手动拷贝优先无损克隆全部 13+ 项物理机身字段；强制注入 `XMP-photools`
      溯源指纹；
    - **第三层派生信息 (`reverse_geocode`)**：仅写入中文地名与分层标签， **绝对严禁重写或篡改既有 GPS 坐标**；`smart` 模式下
      RAW 保持只读仅写 XMP，JPG 直接内嵌；
4. **强制二次读取校验 (Secondary Read Verification)**：
    - 任何写入操作必须在底层读回 `GPSPosition` 或地名标签确认真实落盘，读空或失败坚决阻断并返回错误诊断，严禁仅依赖子进程退出码冒充成功；
5. **专业工具非黑盒原则 (Transparent Professional Principle)**：
    - 桌面端与 TUI 界面展示 GPS 时必须全透明呈现所有待写入的 13+ 项机身物理字段；执行写入时必须明确告知当前遵循的策略模式与写入文件范围；底层失败必须将
      ExifTool 真实错误诊断向上传递呈现，严禁黑盒猜疑。

---

## 12. iOS 尼康相机低功耗同步与后台状态恢复规约 (NikonGPS for iOS) ✨

详细技术规约见独立技术文档：[
`docs/NIKON_IOS_BLUETOOTH_SYNC_AND_STATE_RESTORATION.md`](docs/NIKON_IOS_BLUETOOTH_SYNC_AND_STATE_RESTORATION.md)。

1. **尼康 BLE 广播状态字节 (Status Byte) 协议解析与模式分流**：
    - 尼康 Manufacturer Specific Data (`0x0399`) 包含 7 字节，末字节为状态标志位（Status Byte）：
        - **`0x1D` (`Bit 0 == 1`)**： **相机待机休眠深睡心跳 (Standby Sleeping)**。相机以 2.4s 超低频发射心跳。
          **此时严禁盲目连接**，全权由 `StandbyFreshnessArbiter` 仲裁，原地静止时绝对保持静默，彻底根除电池雪崩；
        - **`0x1C` (`Bit 0 == 0`)**： **相机开机 / 快门唤醒就绪 (Awake & Ready)**。相机以 100~200ms 高频广播。手机脱离 5s
          防抖冷静期后， **立即以长效拍摄会话 (`isStandbyMaintenance = false`) 发起极速秒连**，不主动掐断，相机测光表超时自行休眠；
2. **四维待机保鲜仲裁引擎 (`StandbyFreshnessArbiter`)**：
    - 刚断开 5s 防抖冷静期拦截瞬态残余包，5s 后随时允许快门唤醒；
    - 结合 `CoreMotion` 协处理器：徒步移动缩短至 5m 滑动窗口，原地休整放宽至 20m 窗口，停步到达新机位瞬态优先授权刷新；
    - 显著物理位移 $\ge 30\text{m}$ 触发保鲜更新；GPS 精度 $> 25\text{m}$ 弱信号安全拦截；
3. **凭据动态热注入与循环握手防熔断架构 (Authentication Robustness)**：
    - **状态机热注入 (`updateCredentials`)**：在 `CameraStateMachine` 与 `CameraPeripheralSession` 支持运行时热更新凭据，会话复用时无条件刷新
      `savedDeviceID`，确保 Stage 1 100% 采用相机真实硬件凭据（如 `0x12345678`），彻底根除以 `0x01` 随机临时 ID 握手被相机秒踢（
      `HCI Disconnect, 0x5F`）导致的循环握手；
    - **全局凭据自动广播 (`syncCredentialsToActiveSessions`)**：`savedCameras` 变动时即刻同步热注入至所有活跃会话，根除持久化读取与蓝牙恢复的时序竞态；
    - **连续握手失败熔断保护 (Circuit Breaker)**：若外设连续 3 次握手未完成即断开，触发 15 秒安全熔断冷静期，并物理销毁未配对的污染会话；
4. **快门唤醒 1.2 秒秒连实测闭环 (Wake-up Benchmark)**：
    - 基于尼康 Z6 III 真机 PacketLogger 实测：半按快门捕获广播 ➔ 特征检索 ➔ Stage 1~4 认证 ➔ 写入控制器名 ➔ 下发高精
      WGS-84 坐标并收执确认， **全链路总耗时仅 1.2 秒**，拍摄全程连接稳定零掉线；
5. **前端 UI 状态与底层会话多维解耦 (`isCameraConnected`)**：
    - 在 `CameraSyncCoordinator` 维护 `@Published activeSessionStates`，提供 UUID + 模糊包含名称 + Device ID
      三维匹配，彻底解决相机名称 `"Nikon "` 前缀差异导致卡片状态脱节问题，秒连成功 1 秒内视图即时变绿显示「同步就绪 🟢」；
6. **CoreBluetooth 系统级状态恢复 (State Restoration · 首毫秒法则)**：
    - `App.init()` 启动首毫秒内必须实例化 `CameraSyncCoordinator.shared`，向系统提交固定恢复标识符
      `com.vincentchyu.photools.mobile.ble`；
    - `willRestoreState` 自动识别并恢复外设会话，若底层物理已连通立即主动触发 `startDiscovery()`；
    - 巡航模式与定位引擎持久化自愈，保障后台冷启动唤醒后 0 延迟注入 GPS；
7. **顺应相机原生休眠与智能长连接架构 (Natural Lifecycle & Smart Keep-Alive)** ✨：
    - **尼康相机固件原生节电铁证 (0x13 Remote User Terminated)**：实测真机抓包证实，尼康相机在待机黑屏下完全支持稳定长连接；若无快门操作约
      1~2 分钟后，相机固件为了节电会自动向手机发送 `0x13` 主动断开并转入深睡；
    - **严禁手机端过度设计主动掐断 (No Host-Initiated Disconnect)**：手机端严禁在写入坐标后调用
      `cancelPeripheralConnection`（`0x16`），避免粗暴破坏相机固件原本自然的节奏、引发 25 秒残余广播与 5
      秒冷静期冲突导致的反复伪唤醒与二次重连；
    - **快门 0 毫秒即拍即有**：只要相机开机/待机连通，手机按需持续注入最新 GPS 坐标，摄影师半按快门无需经历 1.5~3 秒重新认证等待，0
      毫秒延时即刻出片；
    - **相机休眠优雅接纳**：当相机自主断开（`0x13` 或 `CBError 7: peripheralDisconnected`）时，系统优雅记录为正常休眠待命（
      `相机完成同步并自然转入休眠 💤`），绝不触发异常告警，并在摄影师按快门或机位显著变动时极速秒连。

16. **Apple 客户端应用矩阵统一架构 (`apps/`) 与 iOS/macOS 规范化包管理** ✨：
    - **全端收纳与职责解耦**：根目录保留纯粹的 Go 核心引擎、CLI、TUI 与 C-Shared FFI 动态库；所有 Apple 平台客户端应用统一收归至
      `apps/`（`apps/macos/PhotoolsApp` 桌面中枢与 `apps/ios/PhotoolsMobile` 现场伴侣），并于根目录建立 `app`
      快捷符号链接以保证全链路兼容；
    - **iOS 现代化 SPM 模块化包管理 (对齐 macOS 标准)**：
        - 彻底摒弃源码堆砌，将蓝牙通信、Blowfish 加密、握手状态机、四维保鲜仲裁与 GPX 录制纯粹封装于 `Package.swift`
          (`NikonGPSCore`)；
        - 命令行通过 `swift test --package-path apps/ios/NikonGPS` 可脱离 Xcode 极速跑通全部自动化测试；
        - iOS 宿主工程 (`App/`) 保持极简，仅保留生命周期入口与 Info.plist 权限声明，由 `project.yml` (XcodeGen) 通过标准
          `packages` 节点将 `NikonGPSCore` 作为 SPM Package 依赖注入，一键生成干净开箱即用的 `.xcodeproj`；
    - **抓包工具与临时资产收归**：抓包分析脚本与样本库统一归纳于 `tools/` 与 `tools/captures/`，保持工程根目录零垃圾污染。


## iOS 个人安装版修正（2026-10-15）

- iPhone 已配对相机需要真实配对凭据；禁止将 Android PRNG 的首个候选 Nonce 当作认证成功。
- 在“配对新相机”中通过系统文件选择器导入相机凭据 JSON；整份校验通过才保存到本机，不上传凭据。
- 导入保留 controllerName，移除示例相机。断开前未就绪时明确显示认证未完成，不再显示同步完成。
- 无就绪相机会话时不增加定位下发计数；计数表示下发请求，不代替照片 EXIF 检查。
- 认证日志隐藏私有凭据和握手载荷。Z6 II 兼容性仍需使用真实凭据与照片检查确认。

- 握手在写入应答后延迟补读 PAIR，兼容通知缺失；忽略通知/读取重复报文，超时与写入拒绝显式失败。
- Stage 4 后优先等待设备名称写入应答，随后才标记就绪。抓包导入支持 ATT read/indication 与 ACL 分片，只接受本机目标相机完整且加密校验通过的四阶段流程。
- 本分支为实验修复，不宣称已在用户 Z6 II 上验证成功。

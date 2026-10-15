import SwiftUI
import UniformTypeIdentifiers

/// 尼康相机配对向导视图
public struct PairingGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var coordinator = CameraSyncCoordinator.shared

    @State private var showingCredentialImporter = false
    @State private var importResult = ""
    @State private var showingImportResult = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundColor(.blue)
                            Text("纯 BLE 凭据驱动直连机制")
                                .font(.subheadline.bold())
                                .foregroundColor(.blue)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• 首次使用请先导入此相机的真实配对凭据；")
                            Text("• 摆脱 SnapBridge：日常连接无需进入相机配对菜单，更无需跳转系统蓝牙设置；")
                            Text("• 相机处于正常取景拍摄界面时，轻点下方「免配对直连」即可瞬间完成 Blowfish 认证！")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.green)
                            Text("摄影巡航模式：开机即连")
                                .font(.subheadline.bold())
                                .foregroundColor(.green)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• 在主界面开启「一键巡航模式」，App 将在后台持续守护；")
                            Text("• 拍摄中相机开机或半按快门唤醒，iPhone 将在 1 秒内自动重连并注入高精 WGS-84 坐标！")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("相机配对凭据") {
                    Text("iPhone 的 SnapBridge 凭据需要从本人蓝牙通信记录中提取。只扫描到相机不代表认证通过。")
                        .font(.caption)
                    Button("导入凭据 JSON／蓝牙抓包") { showingCredentialImporter = true }
                    Text("支持 JSON 或 PacketLogger .pklg。导入抓包前只开启目标相机并等待扫描到它。文件只在本机处理。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("附近扫描到的尼康设备 (\(coordinator.discoveredCameras.count))") {
                    if coordinator.discoveredCameras.isEmpty {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("正在全频段扫描附近的尼康相机广播...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(coordinator.discoveredCameras) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.displayName)
                                            .font(.subheadline.bold())
                                        if item.isPrePaired {
                                            Text("发现配对记录")
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.green.opacity(0.15))
                                                .foregroundColor(.green)
                                                .cornerRadius(6)
                                        } else {
                                            Text("待导入凭据")
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.blue.opacity(0.15))
                                                .foregroundColor(.blue)
                                                .cornerRadius(6)
                                        }
                                    }
                                    Text("信号强度 RSSI: \(item.rssi) dBm\(item.discoveredDeviceID != nil ? " • DeviceID: 0x\(String(item.discoveredDeviceID!, radix: 16).uppercased())" : "")")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(item.isPrePaired ? "免配对直连" : "发起配对") {
                                    coordinator.connectDiscoveredCamera(item)
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(item.isPrePaired ? .green : .blue)
                                .font(.caption.bold())
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("配对新相机")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("刷新") {
                        coordinator.discoveredCameras.removeAll()
                        coordinator.bluetoothManager.startScanning()
                    }
                }
            }
            .fileImporter(isPresented: $showingCredentialImporter, allowedContentTypes: [.json, .data]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    let credentials: Data
                    if url.pathExtension.lowercased() == "pklg" {
                        guard coordinator.discoveredCameras.count == 1,
                              let target = coordinator.discoveredCameras.first,
                              let deviceID = target.discoveredDeviceID else {
                            throw CredentialImportError.invalid("请仅开启目标相机并扫描到它，再导入 .pklg 文件")
                        }
                        let item = try NikonCaptureCredentials.extract(from: data, cameraName: target.name, deviceID: deviceID)
                        credentials = try JSONEncoder().encode(CameraCredentialsContainer(cameras: [item]))
                    } else {
                        credentials = data
                    }
                    let count = try coordinator.importCameraCredentials(from: credentials)
                    importResult = "已导入 \(count) 台相机凭据。请返回相机列表尝试连接；导入成功不代表认证通过。"
                } catch {
                    importResult = "未导入：\(error.localizedDescription)"
                }
                showingImportResult = true
            }
            .alert("凭据导入", isPresented: $showingImportResult) {
                Button("好", role: .cancel) { }
            } message: {
                Text(importResult)
            }
            .onAppear {
                coordinator.bluetoothManager.startScanning()
            }
        }
    }
}

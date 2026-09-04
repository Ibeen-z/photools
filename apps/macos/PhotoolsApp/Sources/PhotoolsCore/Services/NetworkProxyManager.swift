import Foundation

/// 网络代理连通性测试结果
public struct ProxyTestResult: Sendable, Equatable {
    public let success: Bool
    public let latencyMs: Int
    public let message: String

    public init(success: Bool, latencyMs: Int, message: String) {
        self.success = success
        self.latencyMs = latencyMs
        self.message = message
    }
}

/// 常用代理客户端快速预设
public struct ProxyPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let host: String
    public let port: Int

    public init(id: String, name: String, type: String = "http", host: String = "127.0.0.1", port: Int) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port
    }

    public static let commonPresets: [ProxyPreset] = [
        ProxyPreset(id: "clash", name: "Clash / Mihomo", type: "http", port: 7890),
        ProxyPreset(id: "v2ray", name: "V2Ray / Xray", type: "http", port: 10809),
        ProxyPreset(id: "surge", name: "Surge", type: "http", port: 6152),
        ProxyPreset(id: "shadowsocks", name: "SS (SOCKS5)", type: "socks5", port: 1080),
        ProxyPreset(id: "singbox", name: "sing-box (Mixed)", type: "http", port: 2080),
    ]
}

/// 全链路网络代理调度管理器
/// 统一管理 POSIX 环境变量、Go 核心引擎 FFI、Swift URLSession 网络栈与 WebKit 的代理设置
public final class NetworkProxyManager: ObservableObject, @unchecked Sendable {
    public static let shared = NetworkProxyManager()

    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var proxyType: String = "http"
    @Published public private(set) var proxyHost: String = "127.0.0.1"
    @Published public private(set) var proxyPort: Int = 7890
    @Published public private(set) var isTesting: Bool = false
    @Published public private(set) var lastTestResult: ProxyTestResult? = nil

    private let lock = NSLock()

    private init() {}

    /// 应用网络代理全链路配置 (POSIX 环境变量 + Go 引擎 + Swift URLSession)
    public func applyProxy(enabled: Bool, type: String, host: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }

        self.isEnabled = enabled
        self.proxyType = type
        self.proxyHost = host
        self.proxyPort = port

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedType = type.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let pType = normalizedType.isEmpty ? "http" : normalizedType

        if enabled && !trimmedHost.isEmpty && port > 0 {
            let proxyURLString = "\(pType)://\(trimmedHost):\(port)"

            // 1. POSIX 环境变量注入 (涵盖 curl / 系统进程 / 外部子进程 / WebKit 网络栈)
            setenv("HTTP_PROXY", proxyURLString, 1)
            setenv("HTTPS_PROXY", proxyURLString, 1)
            setenv("ALL_PROXY", proxyURLString, 1)
            setenv("http_proxy", proxyURLString, 1)
            setenv("https_proxy", proxyURLString, 1)
            setenv("all_proxy", proxyURLString, 1)

            // 2. 调度通知 Go 核心引擎 (保证离线地理包 geodata 下载、KD-Tree 在线反查走用户指定代理)
            PhotoolsEngine.shared.applyProxy(enabled: true, type: pType, host: trimmedHost, port: port)
        } else {
            // 清理环境变量
            unsetenv("HTTP_PROXY")
            unsetenv("HTTPS_PROXY")
            unsetenv("ALL_PROXY")
            unsetenv("http_proxy")
            unsetenv("https_proxy")
            unsetenv("all_proxy")

            // 通知 Go 引擎关闭代理
            PhotoolsEngine.shared.applyProxy(enabled: false, type: pType, host: trimmedHost, port: port)
        }
    }

    /// 生成适配当前代理策略的 URLSessionConfiguration
    public func makeSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30

        if isEnabled && !proxyHost.isEmpty && proxyPort > 0 {
            var proxyDict: [AnyHashable: Any] = [:]
            if proxyType.lowercased() == "socks5" {
                proxyDict[kCFNetworkProxiesSOCKSEnable as String] = 1
                proxyDict[kCFNetworkProxiesSOCKSProxy as String] = proxyHost
                proxyDict[kCFNetworkProxiesSOCKSPort as String] = proxyPort
            } else {
                proxyDict[kCFNetworkProxiesHTTPEnable as String] = 1
                proxyDict[kCFNetworkProxiesHTTPProxy as String] = proxyHost
                proxyDict[kCFNetworkProxiesHTTPPort as String] = proxyPort
                proxyDict[kCFNetworkProxiesHTTPSEnable as String] = 1
                proxyDict[kCFNetworkProxiesHTTPSProxy as String] = proxyHost
                proxyDict[kCFNetworkProxiesHTTPSPort as String] = proxyPort
            }
            config.connectionProxyDictionary = proxyDict
        }

        return config
    }

    /// 针对指定代理配置发起即时网络连通性与时延测试
    public func testConnection(type: String, host: String, port: Int) async -> ProxyTestResult {
        await MainActor.run {
            self.isTesting = true
        }
        defer {
            Task { @MainActor in
                self.isTesting = false
            }
        }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, port > 0, port <= 65535 else {
            let res = ProxyTestResult(success: false, latencyMs: 0, message: "代理主机地址或端口号不合法")
            await MainActor.run { self.lastTestResult = res }
            return res
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5

        var proxyDict: [AnyHashable: Any] = [:]
        if type.lowercased() == "socks5" {
            proxyDict[kCFNetworkProxiesSOCKSEnable as String] = 1
            proxyDict[kCFNetworkProxiesSOCKSProxy as String] = trimmedHost
            proxyDict[kCFNetworkProxiesSOCKSPort as String] = port
        } else {
            proxyDict[kCFNetworkProxiesHTTPEnable as String] = 1
            proxyDict[kCFNetworkProxiesHTTPProxy as String] = trimmedHost
            proxyDict[kCFNetworkProxiesHTTPPort as String] = port
            proxyDict[kCFNetworkProxiesHTTPSEnable as String] = 1
            proxyDict[kCFNetworkProxiesHTTPSProxy as String] = trimmedHost
            proxyDict[kCFNetworkProxiesHTTPSPort as String] = port
        }
        config.connectionProxyDictionary = proxyDict

        let session = URLSession(configuration: config)
        let testEndpoints = [
            URL(string: "https://www.google.com/generate_204")!,
            URL(string: "https://github.com")!,
            URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!
        ]

        let start = CFAbsoluteTimeGetCurrent()
        var lastErr: Error?

        for testURL in testEndpoints {
            do {
                var request = URLRequest(url: testURL)
                request.httpMethod = "HEAD"
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                let (_, response) = try await session.data(for: request)
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

                if let httpResponse = response as? HTTPURLResponse, (200...399).contains(httpResponse.statusCode) || httpResponse.statusCode == 204 {
                    let res = ProxyTestResult(
                        success: true,
                        latencyMs: max(1, elapsedMs),
                        message: "代理连接畅通 (往返延迟 \(max(1, elapsedMs))ms)"
                    )
                    await MainActor.run { self.lastTestResult = res }
                    return res
                }
            } catch {
                lastErr = error
            }
        }

        let errMsg = lastErr?.localizedDescription ?? "代理连接超时或不可达"
        let res = ProxyTestResult(success: false, latencyMs: 0, message: "探测失败: \(errMsg)")
        await MainActor.run { self.lastTestResult = res }
        return res
    }
}

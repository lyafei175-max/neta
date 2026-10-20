import Foundation
import CryptoKit

/// 会话管理：登录、token 刷新、401 自动重试。
///
/// 原 APK 流程（中文文案已确认）：
/// ```
/// 获取验证码 → 验证码已发送 → 输入手机号+验证码 → 登录 → 获取 token
/// 后续 401 → /customer/account/info/refreshApiToken 刷新
/// ```
///
/// 文案佐证：
/// `请输入正确的手机号`、`验证码发送失败`、`验证码已发送`、`登录失败`、
/// `登录已过期`、`需要重新登录`、`退出登录`、`登录状态已变化`
enum AuthError: Error, LocalizedError {
    case invalidPhone
    case codeNotRequested
    case codeExpired
    case credentialMissing
    case sessionExpired
    case serverRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidPhone:      return "请输入正确的手机号"
        case .codeNotRequested:  return "请先获取验证码"
        case .codeExpired:       return "验证码已过期"
        case .credentialMissing: return "登录失败"
        case .sessionExpired:    return "登录已过期，需要重新登录"
        case .serverRejected(let m): return m.isEmpty ? "登录失败" : m
        }
    }
}

/// 登录会话。
///
/// 短信由**云端网关**发送（原 APK 无 SEND_SMS 权限），App 只调用接口。
actor AuthService {

    static let shared = AuthService()

    private let api: NetaAPIClient
    private let store = CredentialStore.shared

    /// 登录态。发送前先刷新，失败则清除会话。
    private var loggedIn = false

    /// 是否已登录（供 UI 绑定）
    private(set) var isLoggedIn = false

    private init() {
        api = NetaAPIClient()
    }

    // MARK: - 验证码

    /// 发送短信验证码。
    ///
    /// ⚠️ 端点为推断，需抓包确认。
    func requestSMSCode(phone: String) async throws {
        guard Self.isValidPhone(phone) else { throw AuthError.invalidPhone }

        let response = try await api.post(
            path: Endpoint.requestSMSCode,
            parameters: ["mobile": phone]
        )

        guard response.isSuccess else {
            throw AuthError.serverRejected(response.message ?? "")
        }

        // 验证码已发送
    }

    // MARK: - 登录

    /// 提交手机号 + 验证码登录。
    func login(phone: String, code: String) async throws {
        guard Self.isValidPhone(phone) else { throw AuthError.invalidPhone }
        guard !code.isEmpty else { throw AuthError.codeNotRequested }

        let response = try await api.post(
            path: Endpoint.login,
            parameters: [
                "mobile": phone,
                "verifyCode": code,
                "login_channel": String(NetaAPIConfig.default.loginChannel)
            ]
        )

        guard response.isSuccess, let payload = response.data?.asDictionary else {
            throw AuthError.serverRejected(response.message ?? "")
        }

        guard let accessToken = payload["access_token"]?.asString ?? payload["accessToken"]?.asString,
              let refreshToken = payload["refresh_token"]?.asString ?? payload["refreshToken"]?.asString
        else {
            throw AuthError.credentialMissing
        }

        try store.saveSession(accessToken: accessToken, refreshToken: refreshToken)
        loggedIn = true
        isLoggedIn = true
    }

    // MARK: - 退出

    func logout() {
        store.clearSession()
        loggedIn = false
        isLoggedIn = false
        lastRefreshAt = nil
    }

    /// 是否持有本地会话。供 UI 门禁判断是否显示登录页。
    var isAuthenticated: Bool {
        store.accessToken != nil && store.refreshToken != nil
    }

    /// 校验本地会话是否仍然有效。
    ///
    /// ⚠️ 端点与响应结构待抓包校准。
    func verifySession() async -> Bool {
        guard isAuthenticated else { return false }
        do {
            let response = try await NetaAPIClient().post(
                path: Endpoint.accountInfo,
                parameters: [:]
            )
            return response.isSuccess
        } catch {
            return false
        }
    }

    /// 供已登录接口调用：确保有可用 token，必要时刷新。
    ///
    /// 对应文案「登录状态已变化」「需要重新登录刷新钥匙」。
    func ensureValidSession() async throws {
        if !loggedIn, store.accessToken != nil {
            loggedIn = true   // App 重启后本地仍有 token
        }

        guard loggedIn else { throw AuthError.sessionExpired }

        do {
            try await refreshIfNeeded()
        } catch {
            store.clearSession()
            loggedIn = false
            throw AuthError.sessionExpired
        }
    }

    // MARK: - Token 刷新

    /// 距上次刷新超过阈值时主动刷新（默认 5 分钟）。
    private var lastRefreshAt: Date?
    private let refreshThreshold: TimeInterval = 300

    private func refreshIfNeeded() async throws {
        if let last = lastRefreshAt,
           Date().timeIntervalSince(last) < refreshThreshold {
            return
        }
        _ = try await refresh()
    }

    @discardableResult
    func refresh() async throws -> String {
        guard let refreshToken = store.refreshToken else {
            throw AuthError.sessionExpired
        }

        let response = try await api.post(
            path: Endpoint.refreshToken,
            parameters: ["refresh_token": refreshToken]
        )

        guard response.isSuccess, let payload = response.data?.asDictionary else {
            throw AuthError.sessionExpired
        }

        guard let token = payload["access_token"]?.asString ?? payload["accessToken"]?.asString else {
            throw AuthError.credentialMissing
        }

        try store.saveSession(
            accessToken: token,
            refreshToken: payload["refresh_token"]?.asString ?? refreshToken
        )
        lastRefreshAt = Date()
        return token
    }

    /// 服务端返回未授权时调用，刷新后重试一次。
    ///
    /// 对应文案「登录已过期」→ 刷新 → 若仍失败则「需要重新登录」。
    func retryAfterUnauthorized<T>(_ operation: () async throws -> T) async throws -> T {
        _ = try await refresh()
        return try await operation()
    }

    // MARK: - 校验

    /// 中国大陆手机号：1 开头 11 位。
    static func isValidPhone(_ phone: String) -> Bool {
        phone.count == 11 && phone.hasPrefix("1") && phone.allSatisfy(\.isNumber)
    }
}

// MARK: - 响应辅助

extension NetaResponse {
    /// 业务状态判断。
    ///
    /// ⚠️ 成功码取值（0 / 200 / "0"）需抓包确认，此处宽松处理。
    /// `status` 在 Codable 中声明为 Int?，但服务端可能返回字符串，
    /// 因此这里先归一化成字符串再比较，避免类型不匹配。
    var isSuccess: Bool {
        guard let status else {
            // 无 status 字段时按 HTTP 层已通过、body 有 data 视为成功
            return data != nil
        }

        switch String(describing: status) {
        case "0", "200", "success", "SUCCESS":
            return true
        default:
            return false
        }
    }

    /// 提取需要重新登录的错误。
    var requiresRelogin: Bool {
        guard let status else { return false }
        let text = String(describing: status)
        return ["401", "40101", "403"].contains(text)
    }
}

extension Endpoint {
    /// 发送短信验证码（推断端点）
    static let requestSMSCode = "/api/account/sendSmsCode"
    /// 登录（推断端点）
    static let login = "/api/account/login"
    /// 账户信息，用于校验会话（推断端点）
    static let accountInfo = "/api/account/info"
}
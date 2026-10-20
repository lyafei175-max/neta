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
    /// 端点与参数已确认（`LA1/s0;->a`）：POST 表单，唯一字段 `phone`。
    func requestSMSCode(phone: String) async throws {
        guard Self.isValidPhone(phone) else { throw AuthError.invalidPhone }

        let response = try await api.post(
            path: Endpoint.sendCode,
            parameters: ["phone": phone]
        )

        guard response.isSuccess else {
            // 服务端把失败原因放在 description（如 40911「获取验证码过于频繁」、
            // 40505「短信验证码发送错误」），message 常为 null，
            // 必须用 failureText 才能把真实原因显示给用户
            throw AuthError.serverRejected(response.failureText)
        }

        // 验证码已发送
    }

    // MARK: - 登录

    /// 提交手机号 + 验证码登录。
    ///
    /// 请求体已确认（`LA1/e0;->a`，JSON）：
    /// `{ phone, code, appVersion, seriesNo, deviceType, pushToken }`
    ///
    /// 响应结构已确认（`Ly1/j;->h` 解析）：
    /// ```
    /// { "code": 0, "data": {
    ///     "token":    { "access_token", "refresh_token", "expires_in" },
    ///     "customer": { "id", "phone", "nickName", "name", "profilePhoto" },
    ///     "vin": "..."
    /// } }
    /// ```
    /// 注意 token 在 `data.token` 下，不是 `data` 根层（安卓用 `getString`，缺字段即抛异常）。
    func login(phone: String, code: String) async throws {
        guard Self.isValidPhone(phone) else { throw AuthError.invalidPhone }
        guard !code.isEmpty else { throw AuthError.codeNotRequested }

        let seriesNo = try CredentialStore.shared.deviceSeriesNo()

        let response = try await api.postJSON(
            path: Endpoint.login,
            jsonBody: [
                "phone": phone,
                "code": code,
                "appVersion": NetaAPIConfig.default.appVersion,
                "seriesNo": seriesNo,
                "deviceType": NetaAPIConfig.default.deviceType,
                "pushToken": NetaAPIConfig.default.pushToken
            ]
        )

        guard response.isSuccess else {
            throw AuthError.serverRejected(response.failureText)
        }

        // data.token.{access_token, refresh_token}
        let token = response.data?["token"]
        guard let accessToken = token?["access_token"]?.asString ?? response.data?["access_token"]?.asString,
              let refreshToken = token?["refresh_token"]?.asString ?? response.data?["refresh_token"]?.asString
        else {
            throw AuthError.serverRejected("登录响应缺少 token 字段：\(response.rawPreview)")
        }

        try store.saveSession(accessToken: accessToken, refreshToken: refreshToken)

        // 顺手记下默认车辆 VIN 与账号信息，供车控/账户页使用
        if let vin = response.data?["vin"]?.asString, !vin.isEmpty {
            try? store.saveVin(vin)
        }
        if let customer = response.data?["customer"],
           let nick = customer["nickName"]?.asString {
            UserDefaults.standard.set(nick, forKey: "neta.nickName")
        }

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
    /// 通过刷新 token 验证（会话失效时刷新必然失败）。
    func verifySession() async -> Bool {
        guard isAuthenticated else { return false }
        do {
            _ = try await refresh()
            return true
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

        guard response.isSuccess else {
            throw AuthError.sessionExpired
        }

        // 与登录同构：data.token.access_token，兼容扁平结构
        let token = response.data?["token"]
        guard let accessToken = token?["access_token"]?.asString
                ?? response.data?["access_token"]?.asString
                ?? response.data?["accessToken"]?.asString
        else {
            throw AuthError.serverRejected("刷新响应缺少 token：\(response.rawPreview)")
        }

        try store.saveSession(
            accessToken: accessToken,
            refreshToken: token?["refresh_token"]?.asString
                ?? response.data?["refresh_token"]?.asString
                ?? refreshToken
        )
        lastRefreshAt = Date()
        return accessToken
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
    /// 业务成功码集合，来自 `Ly1/m;-><clinit>`：`{200, 20000, 0, 1001, 42528}`。
    /// 已确认（静态 Set 常量）。
    static let successCodes: Set<Int> = [0, 200, 1001, 20000, 42528]

    var isSuccess: Bool {
        guard let code else {
            // 无 code 字段时按 HTTP 层已通过、body 有 data 视为成功
            return data != nil
        }
        return Self.successCodes.contains(code)
    }

    /// 需要重新登录的业务码。
    var requiresRelogin: Bool {
        guard let code else { return false }
        return [401, 40101, 403].contains(code)
    }

    /// 面向用户的失败描述：错误码 + 服务端文案。
    var failureText: String {
        var parts: [String] = []
        if let code { parts.append("错误码 \(code)") }
        let text = [message, description]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        parts.append(text.isEmpty ? "服务未返回原因" : text)
        return parts.joined(separator: "：")
    }

    /// 原始 JSON 预览（诊断用，截断到 300 字符）。
    var rawPreview: String {
        guard let data else { return "(空)" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(data),
              let s = String(data: encoded, encoding: .utf8) else { return "(无法序列化)" }
        return s.count > 2000 ? String(s.prefix(2000)) + "…" : s
    }
}

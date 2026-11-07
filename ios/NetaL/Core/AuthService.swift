import Foundation
import CryptoKit

/// ????:???token ???401 ?????
///
/// ? APK ??(???????):
/// ```
/// ????? ? ?????? ? ?????+??? ? ?? ? ?? token
/// ?? 401 ? /customer/account/info/refreshApiToken ??
/// ```
///
/// ????:
/// `?????????`?`???????`?`??????`?`????`?
/// `?????`?`??????`?`????`?`???????`
enum AuthError: Error, LocalizedError {
    case invalidPhone
    case codeNotRequested
    case codeExpired
    case credentialMissing
    case sessionExpired
    case serverRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidPhone:      return "?????????"
        case .codeNotRequested:  return "???????"
        case .codeExpired:       return "??????"
        case .credentialMissing: return "????"
        case .sessionExpired:    return "?????,??????"
        case .serverRejected(let m): return m.isEmpty ? "????" : m
        }
    }
}

/// ?????
///
/// ???**????**??(? APK ? SEND_SMS ??),App ??????
actor AuthService {

    static let shared = AuthService()

    private let api: NetaAPIClient
    private let store = CredentialStore.shared

    /// ??????????,????????
    private var loggedIn = false

    /// ?????(? UI ??)
    private(set) var isLoggedIn = false

    private init() {
        api = NetaAPIClient()
    }

    // MARK: - ???

    /// ????????
    ///
    /// ????????(`LA1/s0;->a`):POST ??,???? `phone`?
    func requestSMSCode(phone: String) async throws {
        guard Self.isValidPhone(phone) else { throw AuthError.invalidPhone }

        let response = try await api.post(
            path: Endpoint.sendCode,
            parameters: ["phone": phone]
        )

        guard response.isSuccess else {
            // ?????????? description(? 40911????????????
            // 40505???????????),message ?? null,
            // ??? failureText ????????????
            throw AuthError.serverRejected(response.failureText)
        }

        // ??????
    }

    // MARK: - ??

    /// ????? + ??????
    ///
    /// ??????(`LA1/e0;->a`,JSON):
    /// `{ phone, code, appVersion, seriesNo, deviceType, pushToken }`
    ///
    /// ???????(`Ly1/j;->h` ??):
    /// ```
    /// { "code": 0, "data": {
    ///     "token":    { "access_token", "refresh_token", "expires_in" },
    ///     "customer": { "id", "phone", "nickName", "name", "profilePhoto" },
    ///     "vin": "..."
    /// } }
    /// ```
    /// ?? token ? `data.token` ?,?? `data` ??(??? `getString`,???????)?
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
            throw AuthError.serverRejected("?????? token ??:\(response.rawPreview)")
        }

        try store.saveSession(accessToken: accessToken, refreshToken: refreshToken)

        // ???????? VIN ?????,???/?????
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

    // MARK: - ??

    func logout() {
        store.clearSession()
        loggedIn = false
        isLoggedIn = false
        lastRefreshAt = nil
    }

    /// ?????????? UI ????????????
    var isAuthenticated: Bool {
        store.accessToken != nil && store.refreshToken != nil
    }

    /// ?????????????
    ///
    /// ???? token ??(???????????)?
    func verifySession() async -> Bool {
        guard isAuthenticated else { return false }
        do {
            _ = try await refresh()
            return true
        } catch {
            return false
        }
    }

    /// ????????:????? token,??????
    ///
    /// ??????????????????????????
    func ensureValidSession() async throws {
        if !loggedIn, store.accessToken != nil {
            loggedIn = true   // App ??????? token
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

    // MARK: - Token ??

    /// ??????????????(?? 5 ??)?
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

        // DEX `w1/z.f` ??????????(?????????):
        // 1. ???????? `refreshToken`(?? refresh_token)
        // 2. Authorization ???? refreshToken ???(? Bearer ??)
        // 3. ???? "refreshtoken:<?>" ?(????????,RequestSigner ???)
        let noAuth = NetaAPIClient(injectAuth: false, rawAuthorization: refreshToken)
        let response = try await noAuth.post(
            path: Endpoint.refreshToken,
            parameters: ["refreshToken": refreshToken]
        )

        guard response.isSuccess else {
            throw AuthError.sessionExpired
        }

        // ?????:data.token.access_token,??????
        let token = response.data?["token"]
        guard let accessToken = token?["access_token"]?.asString
                ?? response.data?["access_token"]?.asString
                ?? response.data?["accessToken"]?.asString
        else {
            throw AuthError.serverRejected("?????? token:\(response.rawPreview)")
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

    /// ???????????,????????
    ///
    /// ???????????? ?? ? ??????????????
    func retryAfterUnauthorized<T>(_ operation: () async throws -> T) async throws -> T {
        _ = try await refresh()
        return try await operation()
    }

    // MARK: - ??

    /// ???????:1 ?? 11 ??
    static func isValidPhone(_ phone: String) -> Bool {
        phone.count == 11 && phone.hasPrefix("1") && phone.allSatisfy(\.isNumber)
    }
}

// MARK: - ????

extension NetaResponse {
    /// ???????,?? `Ly1/m;-><clinit>`:`{200, 20000, 0, 1001, 42528}`?
    /// ???(?? Set ??)?
    static let successCodes: Set<Int> = [0, 200, 1001, 20000, 42528]

    var isSuccess: Bool {
        guard let code else {
            // ? code ???? HTTP ?????body ? data ????
            return data != nil
        }
        return Self.successCodes.contains(code)
    }

    /// ??????(????)?????
    ///
    /// 30219?Token ?????? 2026-11 ????;30229 ?????????
    /// ??????,???????????????
    var requiresRelogin: Bool {
        guard let code else { return false }
        if [401, 40101, 403, 30219, 30229].contains(code) { return true }
        let text = ((message ?? "") + " " + (description ?? "")).lowercased()
        if text.contains("???") || text.contains("?????") || text.contains("???") { return true }
        if text.contains("token") && (text.contains("??") || text.contains("??") || text.contains("invalid")) { return true }
        return false
    }

    /// ?????????:??? + ??????
    var failureText: String {
        var parts: [String] = []
        if let code { parts.append("??? \(code)") }
        let text = [message, description]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        parts.append(text.isEmpty ? "???????" : text)
        return parts.joined(separator: ":")
    }

    /// ?? JSON ??(???,??? 300 ??)?
    var rawPreview: String {
        guard let data else { return "(?)" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(data),
              let s = String(data: encoded, encoding: .utf8) else { return "(?????)" }
        return s.count > 2000 ? String(s.prefix(2000)) + "." : s
    }
}

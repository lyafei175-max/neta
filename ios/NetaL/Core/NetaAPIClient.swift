import Foundation

/// 云端车控客户端。
///
/// 请求规范来自 APK `Ly1/m;->a`（通用请求构造器），已确认：
/// - POST
/// - 公共字段放 **header**：appId / appKey / appVersion / login_channel /
///   channel / nonce / timestamp / sign / Accept / Authorization(空)
/// - body 二选一：`application/x-www-form-urlencoded` 表单（验证码）或
///   `application/json` JSON（登录）
/// - 响应包装：`{ "code": Int, "message": String, "description": String?, "data": ... }`
struct NetaAPIClient {

    let config: NetaAPIConfig
    let session: URLSession

    /// 是否自动注入 accessToken。登录/注册/刷新接口应设为 false。
    var injectAuth: Bool = true

    init(config: NetaAPIConfig = .default,
         session: URLSession = .shared,
         injectAuth: Bool = true) {
        self.config = config
        self.session = session
        self.injectAuth = injectAuth
    }

    // MARK: - 底层请求

    /// 发送带签名的表单请求（原 `sendCodeAndSignCheck` 走此通道）。
    func post(path: String, parameters: [String: String]) async throws -> NetaResponse {
        let response = try await performPost(path: path, formParams: parameters.sorted { $0.key < $1.key })

        // 业务层未授权 → 刷新 token 后自动重试一次
        if response.requiresRelogin, injectAuth {
            _ = try await AuthService.shared.refresh()
            return try await performPost(path: path, formParams: parameters.sorted { $0.key < $1.key })
        }

        return response
    }

    /// 发送带签名的 JSON 请求（原 `registerOrLoginUncheck` 走此通道）。
    func postJSON(path: String, jsonBody: [String: Any]) async throws -> NetaResponse {
        let data = try JSONSerialization.data(withJSONObject: jsonBody)
        let bodyString = String(data: data, encoding: .utf8) ?? "{}"
        return try await performPost(path: path, jsonBody: bodyString)
    }

    /// 单次请求，不含重试。
    private func performPost(path: String,
                             formParams: [(String, String)] = [],
                             jsonBody: String? = nil) async throws -> NetaResponse {
        guard let url = URL(string: config.baseURL + path) else {
            throw APIError.invalidURL
        }

        let isJSON = jsonBody != nil
        var headers = RequestSigner.commonHeaders(
            config: config, path: path,
            formParams: formParams, jsonBody: jsonBody
        )
        headers["Content-Type"] = isJSON
            ? "application/json"
            : "application/x-www-form-urlencoded;charset=utf-8"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        // ⚠️ 不要在这里补发全小写别名（曾导致 30256「第三方主体密钥已失效」）。
        // HTTP header 名不区分大小写，URLSession 会把 `appId` 和 `appid` 合并成
        // 一行逗号分隔的值（appId: HOZON-..., HOZON-...），服务端读到的 appId
        // 就不再是合法主体。只发这一套驼峰 header 即可（已实测服务端认可）。

        if isJSON {
            request.httpBody = jsonBody?.data(using: .utf8)
        } else {
            // 表单体：k=v&k2=v2（v 需 URL 编码）
            var comps = URLComponents()
            comps.queryItems = formParams.map { URLQueryItem(name: $0.0, value: $0.1) }
            request.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode)
        }

        return try JSONDecoder().decode(NetaResponse.self, from: data)
    }

    // MARK: - 业务方法

    /// 下发车控指令（网络通道）。
    func sendCommand(_ command: VehicleCommand) async throws -> NetaResponse {
        try requireLogin()

        var p = command.cloudPayload
        for (k,v) in vehicleParams([:]) { p[k] = v }
        let response = try await post(
            path: Endpoint.rvcSend,
            parameters: p
        )
        guard response.isSuccess else {
            throw APIError.serverDetail("车控下发失败 code=\(response.code ?? -1) desc=\(response.description ?? "-") body=\(response.rawPreview)")
        }
        return response
    }

    /// 把本地已存的 VIN 塞进业务请求（参数名试常见三种，服务端自取）。
    private func vehicleParams(_ base: [String:String]) -> [String:String] {
        var p = base
        if let vin = CredentialStore.shared.defaultVin, !vin.isEmpty {
            p["vin"] = vin
            p["vinNo"] = vin
            p["vehicleVin"] = vin
        }
        return p
    }

    /// 查询车况。
    func fetchVehicleState() async throws -> VehicleState {
        try requireLogin()

        let response = try await post(
            path: Endpoint.vehicleStatus,
            parameters: vehicleParams([:])
        )

        guard let data = response.data else {
            throw APIError.serverDetail("车况无数据 code=\(response.code ?? -1) desc=\(response.description ?? "-") vin=\(CredentialStore.shared.defaultVin ?? "nil") body=\(response.rawPreview)")
        }

        // data 可能是嵌套的 data 字符串，也可能直接是对象
        let cloud: CloudVehicleData
        if let nestedString = data as? String,
           let decoded = try? JSONDecoder().decode(CloudVehicleData.self,
                                                    from: Data(nestedString.utf8)) {
            cloud = decoded
        } else {
            cloud = try JSONDecoder().decode(CloudVehicleData.self,
                                             from: JSONSerialization.data(withJSONObject: data))
        }

        return cloud.toVehicleState()
    }

    /// 刷新 token（端点 `/customer/account/info/refreshApiToken`，已确认）。
    ///
    /// 响应与登录同构：`data.token.access_token`。请求参数名未从 APK 提取到
    /// （刷新逻辑在 SDK 内部），先按 `refresh_token` 表单字段发送。
    func refreshAccessToken() async throws -> String {
        guard let refreshToken = CredentialStore.shared.refreshToken else {
            throw APIError.notLoggedIn
        }

        let response = try await post(
            path: Endpoint.refreshToken,
            parameters: ["refresh_token": refreshToken]
        )

        let token = response.data?["token"]
        guard let accessToken = token?["access_token"]?.asString
                ?? response.data?["access_token"]?.asString
        else {
            throw APIError.tokenRefreshFailed
        }

        try CredentialStore.shared.saveSession(
            accessToken: accessToken,
            refreshToken: token?["refresh_token"]?.asString ?? refreshToken
        )
        return accessToken
    }

    // MARK: - 内部

    private func requireLogin() throws {
        guard CredentialStore.shared.accessToken != nil else {
            throw APIError.notLoggedIn
        }
    }
}

// MARK: - 响应模型

/// 统一响应包装，对应 APK `Ly1/m;->a` 的解析逻辑：
/// `code`（Int）、`message`、`description`、`data`（对象或数组）。
///
/// `code` 做容错解码：服务端可能返回数字或字符串（安卓用 `optInt` 兼容）。
struct NetaResponse: Codable {
    var code: Int?
    var message: String?
    var description: String?
    var data: JSONValue?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case description
        case data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if let intCode = try? c.decodeIfPresent(Int.self, forKey: .code) {
            code = intCode
        } else if let strCode = try? c.decodeIfPresent(String.self, forKey: .code) {
            code = Int(strCode)
        } else {
            code = nil
        }

        message = try? c.decodeIfPresent(String.self, forKey: .message)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        data = try? c.decodeIfPresent(JSONValue.self, forKey: .data)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(data, forKey: .data)
    }
}

/// 灵活 JSON 值，处理 data 字段可能是对象/字符串/数组的多种情况。
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Double.self) {
            self = .number(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解析 JSON 值")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v):   try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v):  try container.encode(v)
        case .null:          try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }
}

extension JSONValue {
    var asDictionary: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

extension Optional where Wrapped == JSONValue {
    var stringValue: String? { self?.stringValue }
    var asDictionary: [String: JSONValue]? { self?.asDictionary }
}

// MARK: - 错误

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case missingPayload
    case notLoggedIn
    case tokenRefreshFailed
    case serverDetail(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:        return "地址无效"
        case .invalidResponse:   return "响应无法解析"
        case .httpStatus(let s): return "服务返回 \(s)"
        case .missingPayload:    return "响应缺少数据"
        case .notLoggedIn:       return "登录后才能下发车控指令"
        case .tokenRefreshFailed: return "登录已过期，需要重新登录"
        case .serverDetail(let s): return s
        }
    }
}

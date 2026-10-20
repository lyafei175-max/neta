import Foundation

/// 云端车控客户端。
///
/// 原 APK 使用原生 `HttpURLConnection`（无 OkHttp/Retrofit），
/// POST 表单，响应包装为 `NetaResponse(status=...)`。
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

    /// 发送带签名的表单请求。
    func post(path: String, parameters: [String: String]) async throws -> NetaResponse {
        let response = try await performPost(path: path, parameters: parameters)

        // 业务层未授权 → 刷新 token 后自动重试一次
        if response.requiresRelogin, injectAuth {
            _ = try await AuthService.shared.refresh()
            return try await performPost(path: path, parameters: parameters)
        }

        return response
    }

    /// 单次请求，不含重试。
    private func performPost(path: String, parameters: [String: String]) async throws -> NetaResponse {
        let nonce = RequestSigner.generateNonce()
        let signature = RequestSigner.sign(
            appId: config.appId,
            appKey: config.appKey,
            appSecret: config.appSecret,
            nonce: nonce
        )

        var allParams = RequestSigner.commonFields(
            config: config, nonce: nonce, signature: signature
        )
        allParams.append(contentsOf: parameters.map(URLQueryItem.init))

        // 已登录接口需带 token
        if injectAuth, let token = CredentialStore.shared.accessToken {
            allParams.append(URLQueryItem(name: "access_token", value: token))
        }

        guard let url = URL(string: config.baseURL + path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded;charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )

        // body 与 query 同时携带，覆盖两种可能的服务端读取方式
        var components = URLComponents()
        components.queryItems = allParams
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

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
    ///
    /// ⚠️ 指令下发端点在静态分析中未提取到，此处按常见命名占位，
    /// 需抓包后替换为真实路径。
    func sendCommand(_ command: VehicleCommand) async throws -> NetaResponse {
        try requireLogin()

        return try await post(
            path: Endpoint.rvcSend,
            parameters: command.cloudPayload
        )
    }

    /// 查询车况。
    func fetchVehicleState() async throws -> VehicleState {
        try requireLogin()

        let response = try await post(
            path: Endpoint.vehicleStatus,
            parameters: [:]
        )

        guard let data = response.data else { throw APIError.missingPayload }

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

    /// 刷新 token。
    ///
    /// 端点 `refreshApiToken` 已确认（APK 内明文）。
    func refreshAccessToken() async throws -> String {
        guard let refreshToken = CredentialStore.shared.refreshToken else {
            throw APIError.notLoggedIn
        }

        let response = try await post(
            path: Endpoint.refreshToken,
            parameters: ["refresh_token": refreshToken]
        )

        guard let token = response.data?["access_token"] as? String else {
            throw APIError.tokenRefreshFailed
        }

        try CredentialStore.shared.saveSession(
            accessToken: token,
            refreshToken: response.data?["refresh_token"] as? String ?? refreshToken
        )
        return token
    }

    // MARK: - 内部

    private func requireLogin() throws {
        guard CredentialStore.shared.accessToken != nil else {
            throw APIError.notLoggedIn
        }
    }
}

// MARK: - 响应模型

/// 统一响应包装，对应 APK 内 `NetaResponse(status=...)`。
struct NetaResponse: Codable {
    var status: Int?
    var message: String?
    var data: JSONValue?

    enum CodingKeys: String, CodingKey {
        case status
        case message = "msg"
        case data
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

    var errorDescription: String? {
        switch self {
        case .invalidURL:        return "地址无效"
        case .invalidResponse:   return "响应无法解析"
        case .httpStatus(let s): return "服务返回 \(s)"
        case .missingPayload:    return "响应缺少数据"
        case .notLoggedIn:       return "登录后才能下发车控指令"
        case .tokenRefreshFailed: return "登录已过期，需要重新登录"
        }
    }
}

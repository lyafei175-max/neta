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
    /// 最近一次车况接口原始返回（调试用）
    static var lastRawVehicleSnapshot: String = ""

    /// 是否自动注入 accessToken。登录/注册/刷新接口应设为 false。
    var injectAuth: Bool = true

    /// 直接作为 Authorization 头的原始值。
    /// 刷新接口把 refreshToken 放进 Authorization（APK `w1/z.f` 确认，无 Bearer 前缀）。
    var rawAuthorization: String? = nil

    init(config: NetaAPIConfig = .default,
         session: URLSession = .shared,
         injectAuth: Bool = true,
         rawAuthorization: String? = nil) {
        self.config = config
        self.session = session
        self.injectAuth = injectAuth
        self.rawAuthorization = rawAuthorization
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

    /// 发送带签名的 JSON 请求（原 `registerOrLoginUncheck` / `getAppVehicleData` 走此通道）。
    /// 业务码未授权时（如 30219「Token 已过期」）自动刷新令牌并重试一次。
    func postJSON(path: String, jsonBody: [String: Any]) async throws -> NetaResponse {
        let data = try JSONSerialization.data(withJSONObject: jsonBody)
        let bodyString = String(data: data, encoding: .utf8) ?? "{}"
        let response = try await performPost(path: path, jsonBody: bodyString)
        if response.requiresRelogin, injectAuth {
            _ = try await AuthService.shared.refresh()
            return try await performPost(path: path, jsonBody: bodyString)
        }
        return response
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

        // 30229 修复：业务请求必须带 accessToken。登录/刷新接口 injectAuth=false。
        // rawAuthorization 优先：刷新接口直接放 refreshToken 原始值（APK `w1/z.f`）。
        // Authorization = token 原始值，无 Bearer 前缀（APK D1/u.b 第7参数直传，
        // 全库无 "Bearer" 字样；带前缀会被服务端判 67520「信息不匹配」）。
        if let raw = rawAuthorization, !raw.isEmpty {
            headers["Authorization"] = raw
        } else if injectAuth, let token = CredentialStore.shared.accessToken, !token.isEmpty {
            headers["Authorization"] = token
        }

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

    /// 最近一次指令下发的尝试日志（诊断用）
    static var lastCommandAttemptLog: String = ""

    /// 下发车控指令（网络通道）。
    ///
    /// DEX + 真机实测（v0.1.8 定版）：
    /// - **opr = tag（功能组号）**，不是指令序号！真机实证：opr=3 服务端执行了
    ///   天窗（tag 3=天窗组），而非序号 3 的后备箱。value 首字节即 tag（十六进制）
    /// - **params 必填** = [六位 hex 值]，值本身决定组内具体动作
    ///   （如 090101=后备箱开、010100=门锁闭），不带 params 时组内动作有歧义
    /// - body 不含 accessToken；token 仅走 Authorization 头（原始值）
    /// - rvcAll = 表单 {vin, opr, params}；rvcCombined = JSON {vin, combinedCmd:[...]}
    func sendCommand(_ command: VehicleCommand) async throws -> NetaResponse {
        try requireLogin()
        guard let vin = CredentialStore.shared.defaultVin, !vin.isEmpty else {
            throw APIError.serverDetail("缺少 VIN，请重新登录获取车辆信息")
        }
        var log: [String] = []
        let opr = Int(command.tag)
        let paramsJSON = "[\"" + command.value + "\"]"

        // 通道1: rvcAll 表单 {vin, opr=tag, params=[value]}
        do {
            let r = try await post(path: Endpoint.rvcAll,
                                   parameters: ["vin": vin, "opr": String(opr), "params": paramsJSON])
            log.append("[rvcAll tag+params] " + Self.attemptText(r))
            if r.isSuccess {
                NetaAPIClient.lastCommandAttemptLog = log.joined(separator: "\n")
                return r
            }
        } catch { log.append("[rvcAll tag+params] 异常 " + error.localizedDescription) }

        // 通道2: rvcCombined JSON {vin, combinedCmd:[{opr=tag, params:[value]}]}
        do {
            let body: [String: Any] = ["vin": vin,
                                       "combinedCmd": [["opr": opr, "params": [command.value]]]]
            let r = try await postJSON(path: Endpoint.rvcSend, jsonBody: body)
            log.append("[combined tag+params] " + Self.attemptText(r))
            if r.isSuccess {
                NetaAPIClient.lastCommandAttemptLog = log.joined(separator: "\n")
                return r
            }
        } catch { log.append("[combined tag+params] 异常 " + error.localizedDescription) }

        // 兜底: rvcAll 用指令序号（万一服务端两种语义并存）
        do {
            let r = try await post(path: Endpoint.rvcAll,
                                   parameters: ["vin": vin, "opr": String(Int(command.rawValue)), "params": paramsJSON])
            log.append("[rvcAll 序号+params] " + Self.attemptText(r))
            if r.isSuccess {
                NetaAPIClient.lastCommandAttemptLog = log.joined(separator: "\n")
                return r
            }
        } catch { log.append("[rvcAll 序号+params] 异常 " + error.localizedDescription) }

        NetaAPIClient.lastCommandAttemptLog = log.joined(separator: "\n")
        throw APIError.serverDetail("车控下发失败，3 种格式均被拒绝：\n" + log.joined(separator: "\n"))
    }

    private static func attemptText(_ r: NetaResponse) -> String {
        let desc = r.description ?? r.message ?? "-"
        return "code=\(r.code ?? -1) desc=\(desc) body=\(r.rawPreview.count > 160 ? String(r.rawPreview.prefix(160)) + "…" : r.rawPreview)"
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
    ///
    /// DEX `J1/G0.smali` 完整还原（v0.1.6 修正）：
    /// - 请求为**表单**（u.b 第5参数 jsonBody=null → form），不是 JSON
    /// - 表单字段恰好两个：`vin`、`types="0,1,2,3,4,5,7,8,9,10,11,12"`（无 accessToken）
    /// - Authorization 头 = accessToken 原始值（无 Bearer）
    /// 版本轨迹：v0.1.4 缺 types → 响应 body=(空)；v0.1.5 误用 JSON → 67520「信息不匹配」
    func fetchVehicleState() async throws -> VehicleState {
        try requireLogin()

        var params: [String: String] = ["types": "0,1,2,3,4,5,7,8,9,10,11,12"]
        if let vin = CredentialStore.shared.defaultVin, !vin.isEmpty {
            params["vin"] = vin
        }
        let response = try await post(
            path: Endpoint.vehicleStatus,
            parameters: params
        )

        guard let data = response.data else {
            throw APIError.serverDetail("车况无数据 code=\(response.code ?? -1) desc=\(response.description ?? "-") vin=\(CredentialStore.shared.defaultVin ?? "nil") body=\(response.rawPreview)")
        }

        NetaAPIClient.lastRawVehicleSnapshot = response.rawPreview

        // data 是 JSONValue enum，不能直接喂给 JSONSerialization.data(withJSONObject:)
        // （那会因 NSInvalidArgumentException 直接 crash）。正确做法：用 JSONEncoder
        // 把 JSONValue 编成 Data，再解成 CloudVehicleData。
        let cloud: CloudVehicleData
        if let nestedString = data.stringValue,
           let decoded = try? JSONDecoder().decode(CloudVehicleData.self,
                                                    from: Data(nestedString.utf8)) {
            cloud = decoded
        } else if let encoded = try? JSONEncoder().encode(data),
                  let decoded = try? JSONDecoder().decode(CloudVehicleData.self, from: encoded) {
            cloud = decoded
        } else {
            throw APIError.serverDetail("车况解析失败: " + response.rawPreview)
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
    /// 数字钥匙接口的信封字段（实测 {businessObj, code, message}）
    var businessObj: JSONValue?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case description
        case data
        case businessObj
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
        businessObj = try? c.decodeIfPresent(JSONValue.self, forKey: .businessObj)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(code, forKey: .code)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(data, forKey: .data)
        try c.encodeIfPresent(businessObj, forKey: .businessObj)
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

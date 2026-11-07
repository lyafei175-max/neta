import Foundation

/// ????????
///
/// ?????? APK `Ly1/m;->a`(???????),???:
/// - POST
/// - ????? **header**:appId / appKey / appVersion / login_channel /
///   channel / nonce / timestamp / sign / Accept / Authorization(?)
/// - body ???:`application/x-www-form-urlencoded` ??(???)?
///   `application/json` JSON(??)
/// - ????:`{ "code": Int, "message": String, "description": String?, "data": ... }`
struct NetaAPIClient {

    let config: NetaAPIConfig
    let session: URLSession
    /// ????????????(???)
    static var lastRawVehicleSnapshot: String = ""

    /// ?????? accessToken???/??/??????? false?
    var injectAuth: Bool = true

    /// ???? Authorization ??????
    /// ????? refreshToken ?? Authorization(APK `w1/z.f` ??,? Bearer ??)?
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

    // MARK: - ????

    /// ??????????(? `sendCodeAndSignCheck` ????)?
    func post(path: String, parameters: [String: String]) async throws -> NetaResponse {
        let response = try await performPost(path: path, formParams: parameters.sorted { $0.key < $1.key })

        // ?????? ? ?? token ???????
        if response.requiresRelogin, injectAuth {
            _ = try await AuthService.shared.refresh()
            return try await performPost(path: path, formParams: parameters.sorted { $0.key < $1.key })
        }

        return response
    }

    /// ?????? JSON ??(? `registerOrLoginUncheck` / `getAppVehicleData` ????)?
    /// ???????(? 30219?Token ????)????????????
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

    /// ????,?????
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

        // 30229 ??:??????? accessToken???/???? injectAuth=false?
        // rawAuthorization ??:??????? refreshToken ???(APK `w1/z.f`)?
        // Authorization = token ???,? Bearer ??(APK D1/u.b ?7????,
        // ??? "Bearer" ??;????????? 67520???????)?
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
        // ?? ????????????(??? 30256????????????)?
        // HTTP header ???????,URLSession ?? `appId` ? `appid` ???
        // ????????(appId: HOZON-..., HOZON-...),?????? appId
        // ???????????????? header ??(????????)?

        if isJSON {
            request.httpBody = jsonBody?.data(using: .utf8)
        } else {
            // ???:k=v&k2=v2(v ? URL ??)
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

    // MARK: - ????

    /// ??????(????)?
    func sendCommand(_ command: VehicleCommand) async throws -> NetaResponse {
        try requireLogin()

        // DEX ??? LC1/T;->f ?? rvcCombined ?????:
        // {
        //   "vin": "...",
        //   "accessToken": "...",
        //   "combinedCmd": [{"opr": <??1-46>, "params": "<??hex>"}]
        // }
        var body: [String: Any] = [
            "combinedCmd": [
                ["opr": Int(command.rawValue), "params": command.value]
            ]
        ]
        if let vin = CredentialStore.shared.defaultVin, !vin.isEmpty {
            body["vin"] = vin
        }
        if let token = CredentialStore.shared.accessToken, !token.isEmpty {
            body["accessToken"] = token
        }
        let response = try await postJSON(path: Endpoint.rvcSend, jsonBody: body)
        guard response.isSuccess else {
            throw APIError.serverDetail("?????? code=\(response.code ?? -1) desc=\(response.description ?? "-") body=\(response.rawPreview)")
        }
        return response
    }

    /// ?????? VIN ??????(????????,?????)?
    private func vehicleParams(_ base: [String:String]) -> [String:String] {
        var p = base
        if let vin = CredentialStore.shared.defaultVin, !vin.isEmpty {
            p["vin"] = vin
            p["vinNo"] = vin
            p["vehicleVin"] = vin
        }
        return p
    }

    /// ?????
    ///
    /// DEX `J1/G0.smali` ????(v0.1.6 ??):
    /// - ???**??**(u.b ?5?? jsonBody=null ? form),?? JSON
    /// - ????????:`vin`?`types="0,1,2,3,4,5,7,8,9,10,11,12"`(? accessToken)
    /// - Authorization ? = accessToken ???(? Bearer)
    /// ????:v0.1.4 ? types ? ?? body=(?);v0.1.5 ?? JSON ? 67520???????
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
            throw APIError.serverDetail("????? code=\(response.code ?? -1) desc=\(response.description ?? "-") vin=\(CredentialStore.shared.defaultVin ?? "nil") body=\(response.rawPreview)")
        }

        NetaAPIClient.lastRawVehicleSnapshot = response.rawPreview

        // data ? JSONValue enum,?????? JSONSerialization.data(withJSONObject:)
        // (??? NSInvalidArgumentException ?? crash)?????:? JSONEncoder
        // ? JSONValue ?? Data,??? CloudVehicleData?
        let cloud: CloudVehicleData
        if let nestedString = data.stringValue,
           let decoded = try? JSONDecoder().decode(CloudVehicleData.self,
                                                    from: Data(nestedString.utf8)) {
            cloud = decoded
        } else if let encoded = try? JSONEncoder().encode(data),
                  let decoded = try? JSONDecoder().decode(CloudVehicleData.self, from: encoded) {
            cloud = decoded
        } else {
            throw APIError.serverDetail("??????: " + response.rawPreview)
        }

        return cloud.toVehicleState()
    }

    /// ?? token(?? `/customer/account/info/refreshApiToken`,???)?
    ///
    /// ???????:`data.token.access_token`???????? APK ???
    /// (????? SDK ??),?? `refresh_token` ???????
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

    // MARK: - ??

    private func requireLogin() throws {
        guard CredentialStore.shared.accessToken != nil else {
            throw APIError.notLoggedIn
        }
    }
}

// MARK: - ????

/// ??????,?? APK `Ly1/m;->a` ?????:
/// `code`(Int)?`message`?`description`?`data`(?????)?
///
/// `code` ?????:?????????????(??? `optInt` ??)?
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

/// ?? JSON ?,?? data ???????/???/????????
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
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "???? JSON ?")
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

// MARK: - ??

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
        case .invalidURL:        return "????"
        case .invalidResponse:   return "??????"
        case .httpStatus(let s): return "???? \(s)"
        case .missingPayload:    return "??????"
        case .notLoggedIn:       return "???????????"
        case .tokenRefreshFailed: return "?????,??????"
        case .serverDetail(let s): return s
        }
    }
}

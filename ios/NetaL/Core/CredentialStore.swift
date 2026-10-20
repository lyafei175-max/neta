import Foundation
import Security
import UIKit

/// 设备证书与密钥材料管理。
///
/// 原 APK 流程（中文文案已确认）：
/// ```
/// 1. 本地生成设备 ECC 密钥对
/// 2. 上传公钥 mobilePubkey → 云端
/// 3. POST /pivot/security-api/pki/cert/1.0/applyCert 申请设备证书
/// 4. 云端下发证书 → 组装 X.509 链（用 hozon-ca.pem 验签）
/// 5. 申请车主钥匙 → 车端下载钥匙原文
/// 6. 车端返回 vehiclePubkey → 与本地密钥材料比对
/// 7. 激活钥匙
/// ```
///
/// 原实现用 Google Tink + androidx.security-crypto，iOS 端用
/// CryptoKit + Security.framework 替代，无需第三方密码库。
final class CredentialStore {

    static let shared = CredentialStore()

    private let session = URLSession(configuration: .default)
    private let config = NetaAPIConfig.default

    private init() {}

    // MARK: - 密钥材料

    /// 生成设备 ECC 密钥对（P-256，对应 SHA256withECDSA）。
    func generateDeviceKeyPair() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: deviceTag
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error?.takeRetainedValue() as Error?
                ?? CredentialError.keyGenerationFailed
        }
        return key
    }

    func publicKeyBase64(_ privateKey: SecKey) -> String? {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
          let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
        return nil
        }
        return data.base64EncodedString()
    }

    /// 加载设备私钥。
    func loadDevicePrivateKey() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: deviceTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let key = item as! SecKey? else {
            throw CredentialError.privateKeyUnavailable
        }
        return key
    }

    private var deviceTag: Data {
        Data("com.neta.l.devicekey".utf8)
    }

    // MARK: - 设备证书

    struct DeviceCredentials {
        var certificatePem: String
        var privateKeyPem: String
    }

    /// 申请设备证书。
    ///
    /// 上传公钥后调用 `applyCert`，服务端返回 PEM。
    ///
    /// ⚠️ 该端点的请求字段未从 APK 提取到，按常见命名占位，需抓包校准。
    func applyDeviceCertificate(publicKeyPem: String) async throws -> String {
        let path = Endpoint.applyCert
        let headers = RequestSigner.commonHeaders(config: config, path: path)

        guard let url = URL(string: config.baseURL + path) else {
            throw CredentialError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.setValue(
            "application/x-www-form-urlencoded;charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )

        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "pubkey", value: publicKeyPem),
            URLQueryItem(name: "device_id", value: DeviceInfo.current.deviceID),
            URLQueryItem(name: "device_model", value: DeviceInfo.current.deviceModel),
            URLQueryItem(name: "device_sys_version", value: DeviceInfo.current.systemVersion)
        ]
        request.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CredentialError.requestFailed
        }

        // 响应结构需抓包确认，此处按最可能的证书字段解析
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let payload = json?["data"] as? [String: Any] ?? json ?? [:]
        guard let cert = payload["certificate"] as? String ?? payload["certificatePem"] as? String else {
            throw CredentialError.certificateMissing
        }
        return cert
    }

    /// 校验证书链是否由哪吒根 CA 签发。
    ///
    /// 根证书 `hozon-ca.pem`：`CN=HOZON Root CA`，ECDSA P-256，SHA-384。
    func verifyCertificateChain(leafPem: String, rootPem: String) -> Bool {
        guard let rootData = Self.pemToData(rootPem),
              let rootCert = SecCertificateCreateWithData(nil, rootData as CFData),
              let leafData = Self.pemToData(leafPem),
              let leafCert = SecCertificateCreateWithData(nil, leafData as CFData)
        else { return false }

        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            leafCert,
            SecPolicyCreateBasicX509(),
            &trust
        )
        guard status == errSecSuccess, let trust else { return false }

        // 只信任哪吒根 CA，忽略系统与用户根证书
        SecTrustSetAnchorCertificates(trust, [rootCert] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var cfError: CFError?
        return SecTrustEvaluateWithError(trust, &cfError)
    }

    // MARK: - 会话凭据

    /// 保存会话 token。
    ///
    /// ⚠️ token 与私钥必须存 Keychain，不能放 UserDefaults。
    /// 原 APK 存储键：neta_session / neta_device / neta_device_cert / neta_tboe_key
    func saveSession(accessToken: String, refreshToken: String) throws {
        try KeychainHelper.set(accessToken, account: "accessToken")
        try KeychainHelper.set(refreshToken, account: "refreshToken")
    }

    var accessToken: String? {
        try? KeychainHelper.get(account: "accessToken")
    }

    var refreshToken: String? {
        try? KeychainHelper.get(account: "refreshToken")
    }

    func clearSession() {
        KeychainHelper.delete(account: "accessToken")
        KeychainHelper.delete(account: "refreshToken")
    }

    /// 设备序列号（登录请求体 `seriesNo` 字段）。
    ///
    /// 原 APK 由 `Ls1/a;->a()` 生成设备串。iOS 端首次生成随机 UUID
    /// 后持久化到 Keychain，保证同一设备稳定。
    func deviceSeriesNo() throws -> String {
        if let existing = try KeychainHelper.get(account: "seriesNo") {
            return existing
        }
        let series = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try KeychainHelper.set(series, account: "seriesNo")
        return series
    }

    // MARK: - PEM 工具

    static func pemToData(_ pem: String) -> Data? {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(base64Encoded: stripped)
    }

    enum CredentialError: Error {
        case keyGenerationFailed
        case privateKeyUnavailable
        case invalidURL
        case requestFailed
        case certificateMissing
    }
}

// MARK: - Keychain

enum KeychainHelper {

    private static let service = "com.neta.l.credentials"

    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // 令牌在设备解锁后即可用，无需每次验证用户
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.writeFailed(status) }
    }

    static func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error {
        case writeFailed(OSStatus)
    }
}

// MARK: - 设备信息

struct DeviceInfo {
    var deviceID: String
    var deviceModel: String
    var systemVersion: String
    var deviceType: String

    static var current: DeviceInfo {
        #if targetEnvironment(simulator)
        let model = "iPhone Simulator"
        #else
        let model = UIDevice.current.model
        #endif

        return DeviceInfo(
            deviceID: UIDevice.current.identifierForVendor?.uuidString ?? "",
            deviceModel: model,
            systemVersion: UIDevice.current.systemVersion,
            deviceType: "ios"
        )
    }
}
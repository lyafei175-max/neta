import Foundation
import CryptoKit

/// 服务端接入配置。
///
/// 全部字段来自 APK 内 `NetaApiConfig` 的明文 toString，已确认。
/// ⚠️ 这些凭据在原 APK 中明文分发，等同于公开密钥。移植时不要认为它们是安全的。
struct NetaAPIConfig {

    let baseURL: String
    let appId: String
    let appKey: String
    let appSecret: String
    let appVersion: String
    let channel: String
    let loginChannel: Int

    /// 从 `哪吒L.apk.1` 提取的原始配置。
    static let `default` = NetaAPIConfig(
        baseURL: "https://appapi-pki.chehezhi.cn:18443",
        appId: "HOZON-B-xKrgEvMt",
        appKey: "e0ae89fb37b6151889c6de3ba6b84e0d3a67f52cd5767758d4186fefff8f763c",
        appSecret: "8b53846c4eb40e3f58df334a2f2ca0af6fba86f7999afd0b2ba794edc450b937",
        appVersion: "6.4.2",
        channel: "ios",
        loginChannel: 1
    )

    /// 原 APK 中 `channel` 为 "android"。iOS 端是否需要独立取值待确认，
    /// 若服务端只认 android，改为 `NetaAPIConfig.default` 保持原值即可。
    static let usesAndroidChannel = true
}

// MARK: - 请求签名

enum RequestSigner {

    /// 生成 nonce。原 APK 使用 `nonce:` 参数，具体算法未提取到（可能是 UUID 或时间戳+随机）。
    static func generateNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// 签名原串。格式由 APK 明文确认——各段之间**无分隔符**：
    ///
    ///     cappid:HOZON-B-xKrgEvMtappkey:e0ae...763cnonce:<nonce>
    ///
    /// 注意 `appkey:` 与前段之间没有 `&`，容易写错。
    static func signatureBase(appId: String, appKey: String, nonce: String) -> String {
        "cappid:\(appId)appkey:\(appKey)nonce:\(nonce)"
    }

    /// 计算请求签名。
    ///
    /// ⚠️ 【待验证】算法是推断的。原 APK 使用 Google Tink 且被 R8 混淆，
    /// 未提取到确切的派生方式。两种最可能的实现都已提供，
    /// 请通过 MITM 抓包（APK 已信任用户 CA，可直接代理）比对后选用。
    ///
    /// 方案 A：HMAC-SHA256(appSecret, base) 十六进制
    /// 方案 B：SHA256(appSecret + base) 十六进制
    static func sign(appId: String, appKey: String, appSecret: String,
                     nonce: String, algorithm: Algorithm = .hmacSHA256) -> String {
        let base = signatureBase(appId: appId, appKey: appKey, nonce: nonce)
        let message = Data(base.utf8)

        switch algorithm {
        case .hmacSHA256:
            let key = SymmetricKey(data: Data(appSecret.utf8))
            let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
            return mac.map { String(format: "%02x", $0) }.joined()
        case .sha256Concat:
            let salted = Data(appSecret.utf8) + message
            return SHA256.hash(data: salted).map { String(format: "%02x", $0) }.joined()
        }
    }

    enum Algorithm {
        case hmacSHA256
        case sha256Concat
    }

    /// 组装公共请求头 / 参数。
    static func commonFields(config: NetaAPIConfig, nonce: String,
                             signature: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "cappid", value: config.appId),
            URLQueryItem(name: "appkey", value: config.appKey),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "signature", value: signature),
            URLQueryItem(name: "version", value: config.appVersion),
            URLQueryItem(name: "channel", value: config.channel)
        ]
    }
}

// MARK: - 已知端点
//
// 全部端点已从 APK 字符串池提取完毕，见 `Endpoint.swift`。
// 路径规则：`/pivot/<域>/<版本>/<方法>`，共 14 个。
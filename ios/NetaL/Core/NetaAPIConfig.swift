import Foundation
import CryptoKit

/// 服务端接入配置。
///
/// 全部字段来自 APK 内明文常量（`LC0/q;->k` / `Ly1/m;->a`），已确认。
/// ⚠️ 这些凭据在原 APK 中明文分发，等同于公开密钥。移植时不要认为它们是安全的。
struct NetaAPIConfig {

    let baseURL: String
    let appId: String
    let appKey: String
    let appSecret: String
    let appVersion: String
    let channel: String
    let loginChannel: String
    let deviceType: String
    let pushToken: String

    /// 从 `哪吒L.apk.1` 提取的原始配置（值均已在字节码中确认）。
    static let `default` = NetaAPIConfig(
        baseURL: "https://appapi-pki.chehezhi.cn:18443",
        appId: "HOZON-B-xKrgEvMt",
        appKey: "e0ae89fb37b6151889c6de3ba6b84e0d3a67f52cd5767758d4186fefff8f763c",
        appSecret: "8b53846c4eb40e3f58df334a2f2ca0af6fba86f7999afd0b2ba794edc450b937",
        appVersion: "6.4.2",
        channel: "android",      // 原样保留，最大程度模拟 APK
        loginChannel: "1",
        deviceType: "2",
        pushToken: "app.netal"
    )
}

// MARK: - 请求签名（已从 APK 字节码完整还原）

///
/// 来源方法：`Ly1/u;->a(String path, List params, String json, String nonce, J timestamp)`。
///
/// 签名原串（各段**直接拼接，无分隔符**）：
///
///     POST
///     <端点路径>
///     appid:<appId>appkey:<appKey>nonce:<nonce>
///     timestamp:<毫秒时间戳>
///     ── 二选一 ──
///     json:<JSON body 字符串>                     ← JSON 请求（登录）
///     <key小写>:<value><key小写>:<value>...        ← 表单请求（发送验证码）
///     <appSecret>
///
/// 计算：`sign = SHA256_hex_lower( JavaURLEncode(原串) )`
///
/// 注意是先 URL 编码**整个原串**再哈希（Java `URLEncoder.encode(s, "UTF-8")`），
/// 不是先哈希再编码。Java 编码规则与 Swift 默认不同：空格→`+`，
/// 保留 `A-Za-z0-9 . - * _`，其余（含 `~`）→ `%XX` 大写。
enum RequestSigner {

    /// 生成 nonce。原 APK 的生成逻辑在 SDK 内部（`Lf2/a;->a()` 提供方），
    /// 静态分析无法还原其取值来源；服务端只校验「sign 与提交的 nonce 一致」，
    /// 因此任意随机串均可。
    static func generateNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// 复刻 Java `URLEncoder.encode(s, "UTF-8")`。
    static func javaURLEncode(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for byte in s.utf8 {
            let c = Character(UnicodeScalar(byte))
            switch c {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "-", "*", "_":
                out.append(c)
            case " ":
                out.append("+")
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    /// 签名原串。
    /// - Parameters:
    ///   - path: 端点路径，如 `/pivot/account/2.0/sendCodeAndSignCheck`
    ///   - formParams: 表单参数对（JSON 请求时传空）
    ///   - jsonBody: JSON 请求体字符串（表单请求时传 nil）
    ///   - nonce: 随机串
    ///   - timestampMillis: 毫秒时间戳
    static func signatureBase(config: NetaAPIConfig,
                              path: String,
                              formParams: [(String, String)] = [],
                              jsonBody: String? = nil,
                              nonce: String,
                              timestampMillis: Int64) -> String {
        var s = "POST"
        s += path
        s += "appid:\(config.appId)appkey:\(config.appKey)nonce:"
        s += nonce
        s += "timestamp:\(timestampMillis)"
        if let json = jsonBody {
            s += "json:\(json)"
        } else {
            for (k, v) in formParams {
                s += k.lowercased() + ":" + v
            }
        }
        s += config.appSecret
        return s
    }

    /// 计算请求签名：SHA256( URLEncode(原串) )，小写十六进制。
    ///
    /// ⚠️ 摘要的十六进制大小写沿用通用惯例（小写）。若实测签名错误，
    /// 依次尝试：大写 hex → Base64。
    static func sign(config: NetaAPIConfig,
                     path: String,
                     formParams: [(String, String)] = [],
                     jsonBody: String? = nil,
                     nonce: String,
                     timestampMillis: Int64) -> String {
        let raw = signatureBase(config: config, path: path,
                                formParams: formParams, jsonBody: jsonBody,
                                nonce: nonce, timestampMillis: timestampMillis)
        let encoded = javaURLEncode(raw)
        let digest = SHA256.hash(data: Data(encoded.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 公共请求头（与 `Ly1/m;->a` 组装的 header 完全一致）。
    static func commonHeaders(config: NetaAPIConfig,
                              path: String,
                              formParams: [(String, String)] = [],
                              jsonBody: String? = nil) -> [String: String] {
        let nonce = generateNonce()
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let sign = sign(config: config, path: path,
                        formParams: formParams, jsonBody: jsonBody,
                        nonce: nonce, timestampMillis: ts)
        return [
            "appId": config.appId,
            "appKey": config.appKey,
            "appVersion": config.appVersion,
            "login_channel": config.loginChannel,
            "channel": config.channel,
            "nonce": nonce,
            "timestamp": String(ts),
            "sign": sign,
            "Accept": "application/json",
            "Authorization": ""
        ]
    }
}

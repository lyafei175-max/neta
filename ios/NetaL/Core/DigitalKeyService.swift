import Foundation
import CryptoKit
import Security
import UIKit

/// 数字钥匙云同步。协议逆向自 APK `y1/J.smali`（作者调试日志①–⑤步骤）：
///
/// ① eccPubkeyUpload      POST {userName, deviceID, deviceModel, deviceSysVer, eccPubkey}
///    → 110217 = 公钥已登记，等待车端确认后重试（/5）
/// ② getKeyListByUserName POST {userName, deviceID}
///    → 钥匙列表（keyID/状态/版本）
///    ownerKeyRequest       POST {deviceID, userName, VIN, startTime, endTime, offlineCount}
///    activeKeyByID         POST {deviceID, userName, keyID}
/// ③ downloadKeyRawDataByKeyIDList POST {userName, deviceID, keyIDList:[...]}
///    → 钥匙原文（与上传的本机 ECC 公钥绑定，需本机私钥解密）
/// ⑤ getWhiteListByVINList POST {userName, deviceID, VINList:[...]}
///
/// ⚠️ 钥匙原文的解密/解析格式（Ingeek 私有）未知，v0.3.0 先原样落盘供分析。
@MainActor
final class DigitalKeyService: ObservableObject {

    static let shared = DigitalKeyService()

    @Published var busy = false
    @Published var logText: String = ""
    @Published var keyListRaw: String?
    @Published var keyRawData: String?
    @Published var publicKeyUploaded = false

    private let api = NetaAPIClient()

    private init() {
        publicKeyUploaded = (try? KeychainHelper.get(account: "dk_public_uploaded")) == "1"
        keyRawData = try? KeychainHelper.get(account: "dk_keyraw")
    }

    private func append(_ line: String) {
        logText += line + "\n"
        DiagnosticLog.shared.log("KeySync", line)
    }

    /// 稳定设备 ID = 登录时的 seriesNo。
    /// ⚠️ 必须与登录请求发的 seriesNo 完全一致（含大小写）：
    /// 服务端按字符串精确匹配校验「最后登录设备」。v0.3.10 曾误加
    /// lowercased()（想对齐安卓小写习惯），而 iOS 本地 seriesNo 是
    /// 大写 UUID，导致所有数字钥匙接口 110516（2026-11-08 diag7 实测，
    /// 旧会话发大写时 ②③⑤ 全部 200）。
    var deviceID: String {
        (try? CredentialStore.shared.deviceSeriesNo()) ?? ""
    }

    /// userName = customer.id（实测抓包，非手机号）。
    /// 缺失说明登录会话早于 v0.3.1，需要重新登录补存。
    var userName: String {
        CredentialStore.shared.customerId ?? ""
    }

    /// 同步前校验：账号 ID 缺失时提示重新登录，避免拿手机号盲打 400
    private func requireUserName() -> String? {
        let u = userName
        if u.isEmpty {
            append("⚠️ 缺少账号 ID（customer.id）：请「账户 → 退出登录」后重新登录一次，再执行同步")
        }
        return u.isEmpty ? nil : u
    }

    /// 服务端业务错误的人话提示
    private func hint(_ resp: NetaResponse) -> String {
        if resp.code == 110516 {
            return "（110516：deviceID 与登录绑定不一致——v0.3.11 已修复大小写问题；若仍出现请退出登录后重新登录再同步）"
        }
        return ""
    }

    /// 实测安卓 SDK 在数字钥匙请求上携带 request-id 头
    private var requestIdHeader: [String: String] {
        ["request-id": "Android-SDK-\(userName)-\(Int64(Date().timeIntervalSince1970 * 1000))"]
    }

    // MARK: ① 上传公钥
    //
    // 实测：SPKI/裸点位 × 完整/主版本号 四种组合一次跑完，哪个组合被接受即固化
    // （安卓实测 body：deviceModel=JLH-AN00, deviceSysVer="12"（仅主版本）, eccPubkey=SPKI base64）

    func uploadPublicKey() async {
        busy = true
        defer { busy = false }
        guard let user = requireUserName() else { return }
        do {
            let raw = try localPublicKeyRaw()
            let spki = spkiBase64(fromRaw: raw)
            let rawB64 = raw.base64EncodedString()
            let full = DeviceInfo.current.systemVersion
            let major = full.split(separator: ".").first.map(String.init) ?? full

            let variants: [(String, [String: Any])] = [
                ("裸点位+完整版本号", [
                    "userName": user, "deviceID": deviceID,
                    "deviceModel": DeviceInfo.current.deviceModel,
                    "deviceSysVer": full, "eccPubkey": rawB64]),
                ("SPKI+完整版本号", [
                    "userName": user, "deviceID": deviceID,
                    "deviceModel": DeviceInfo.current.deviceModel,
                    "deviceSysVer": full, "eccPubkey": spki ?? rawB64]),
                ("SPKI+主版本号", [
                    "userName": user, "deviceID": deviceID,
                    "deviceModel": DeviceInfo.current.deviceModel,
                    "deviceSysVer": major, "eccPubkey": spki ?? rawB64]),
                ("裸点位+主版本号", [
                    "userName": user, "deviceID": deviceID,
                    "deviceModel": DeviceInfo.current.deviceModel,
                    "deviceSysVer": major, "eccPubkey": rawB64]),
            ]

            for (label, body) in variants {
                append("① 尝试 \(label)：body=\(Self.bodyString(body))")
                do {
                    let resp = try await api.postJSON(path: Endpoint.eccPubkeyUpload, jsonBody: body,
                                                      extraHeaders: requestIdHeader)
                    append("① [\(label)] code=\(resp.code ?? -1) desc=\(resp.description ?? resp.message ?? "-") body=\(resp.rawPreview)\(hint(resp))")
                    if resp.isSuccess {
                        publicKeyUploaded = true
                        try? KeychainHelper.set("1", account: "dk_public_uploaded")
                        append("✅ 公钥上传成功（格式=\(label)）")
                        return
                    }
                    if resp.code == 110217 || resp.code == 110201 {
                        // 110217 公钥已登记；110201 = 同一公钥已在云端（diag9 实测：
                        // v0.3.11 二次同步时 SPKI 变体全返 110201，属正常，勿再重传）
                        publicKeyUploaded = true
                        try? KeychainHelper.set("1", account: "dk_public_uploaded")
                        append("✅ 公钥已在云端（code=\(resp.code!)，格式=\(label)），无需重复上传")
                        return
                    }
                } catch {
                    // 单个变体失败（如 HTTP 400）继续试下一个
                    append("① [\(label)] 异常 " + error.localizedDescription)
                }
            }
            append("❌ 四种公钥格式均被拒（HTTP 400）——需对照安卓请求逐字段排查")
        } catch {
            append("① 异常 " + error.localizedDescription)
        }
    }

    private static func bodyString(_ body: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "?" }
        return s.count > 400 ? String(s.prefix(400)) + "…" : s
    }

    private func localPublicKeyRaw() throws -> Data {
        let key: SecKey
        do {
            key = try CredentialStore.shared.loadDevicePrivateKey()
        } catch {
            key = try CredentialStore.shared.generateDeviceKeyPair()
        }
        guard let b64 = CredentialStore.shared.publicKeyBase64(key),
              let raw = Data(base64Encoded: b64), raw.count == 65, raw[0] == 0x04 else {
            throw APIError.serverDetail("公钥导出失败")
        }
        return raw
    }

    private func spkiBase64(fromRaw raw: Data) -> String? {
        // P-256 SPKI 固定头（26 字节）+ X9.63 非压缩点位
        let header: [UInt8] = [
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
        ]
        return (Data(header) + raw).base64EncodedString()
    }

    // MARK: ② 钥匙列表

    func fetchKeyList() async {
        busy = true
        defer { busy = false }
        do {
            append("② 取钥匙列表…")
            guard let user = requireUserName() else { return }
            let body: [String: Any] = ["userName": user, "deviceID": deviceID]
            let resp = try await api.postJSON(path: Endpoint.keyList, jsonBody: body,
                                              extraHeaders: requestIdHeader)
            append("② code=\(resp.code ?? -1) desc=\(resp.description ?? resp.message ?? "-")\(hint(resp))")
            // 钥匙接口信封是 {businessObj, code, message}（实测），data 兜底
            keyListRaw = Self.jsonToString(resp.businessObj ?? resp.data)
            if let k = keyListRaw { append(k) }
            // 持久化首个 keyID —— TBOE 握手的认证串就是 MD5(keyID)（实测样本验证）
            let ids = extractKeyIDs()
            if let first = ids.first {
                try? KeychainHelper.set(first, account: "dk_keyid")
                append("（keyID 已存 Keychain：\(first)）")
            }
        } catch {
            append("② 异常 " + error.localizedDescription)
        }
    }

    // MARK: ③ 下载钥匙原文

    /// keyIDs 由 ② 的列表解析而来；先手动输入或从列表 JSON 提取。
    func downloadKeyRawData(keyIDs: [String]) async {
        busy = true
        defer { busy = false }
        do {
            append("③ 下载钥匙原文 keyIDList=\(keyIDs)…")
            guard let user = requireUserName() else { return }
            let body: [String: Any] = [
                "userName": user,
                "deviceID": deviceID,
                "keyIDList": keyIDs,
            ]
            let resp = try await api.postJSON(path: Endpoint.downloadKeyRaw, jsonBody: body,
                                              extraHeaders: requestIdHeader)
            append("③ code=\(resp.code ?? -1) desc=\(resp.description ?? resp.message ?? "-")")
            append(resp.rawPreview)
            if let payload = resp.businessObj ?? resp.data,
               let encoded = try? JSONEncoder().encode(payload),
               let raw = String(data: encoded, encoding: .utf8) {
                keyRawData = raw
                try? KeychainHelper.set(raw, account: "dk_keyraw")
                append("（钥匙原文已存 Keychain，待解密分析）")
            }
        } catch {
            append("③ 异常 " + error.localizedDescription)
        }
    }

    /// ③ 主流程：激活钥匙（activeKeyByID）→ 响应直接带 keyRawData（keyDataVer +1）。
    /// 实测安卓流程走激活；downloadKeyRawDataByKeyIDList 是激活失败时的兜底，
    /// 未激活的 key 走下载会返回空（iOS v0.3.3 实测）。
    func activateAndDownloadKey(keyID: String) async {
        busy = true
        defer { busy = false }
        guard let user = requireUserName() else { return }
        do {
            append("③ 激活钥匙 keyID=\(keyID)…")
            let body: [String: Any] = ["userName": user, "deviceID": deviceID, "keyID": keyID]
            let resp = try await api.postJSON(path: Endpoint.activeKey, jsonBody: body,
                                              extraHeaders: requestIdHeader)
            append("③ code=\(resp.code ?? -1) desc=\(resp.description ?? resp.message ?? "-")\(hint(resp))")
            append(resp.rawPreview)
            if let payload = resp.businessObj ?? resp.data,
               let encoded = try? JSONEncoder().encode(payload),
               let raw = String(data: encoded, encoding: .utf8),
               raw.contains("keyRawData") {
                keyRawData = raw
                try? KeychainHelper.set(raw, account: "dk_keyraw")
                // 完整钥匙原文落诊断日志（rawPreview 不含 businessObj，v0.3.10 及
                // 之前从未落盘——TBOE 编解码开发需要这份 ASN.1 样本）
                append("✅ 钥匙原文已存 Keychain（含 keyRawData）")
                append("keyRawData 全文=" + raw)
            } else {
                // 没拿到原文也把 businessObj 原样落日志，便于排查
                if let payload = resp.businessObj ?? resp.data,
                   let encoded = try? JSONEncoder().encode(payload),
                   let raw = String(data: encoded, encoding: .utf8) {
                    append("③ businessObj=" + raw)
                }
                append("（激活未返回钥匙原文，回退下载接口…）")
                await downloadKeyRawData(keyIDs: [keyID])
            }
        } catch {
            append("③ 异常 " + error.localizedDescription + "，回退下载接口…")
            await downloadKeyRawData(keyIDs: [keyID])
        }
    }

    private static func jsonToString(_ j: JSONValue?) -> String? {
        guard let j, let d = try? JSONEncoder().encode(j) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// 从钥匙列表原始 JSON 里尽力提取 keyID（递归收集）
    func extractKeyIDs() -> [String] {
        guard let raw = keyListRaw, let d = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        var found: [String] = []
        func walk(_ any: Any) {
            if let dict = any as? [String: Any] {
                for (k, v) in dict {
                    if k == "keyID" {
                        if let s = v as? String { found.append(s) }
                        else if let n = v as? NSNumber { found.append(n.stringValue) }
                    }
                    walk(v)
                }
            } else if let arr = any as? [Any] {
                arr.forEach(walk)
            }
        }
        walk(obj)
        return found
    }

    // MARK: ⑤ 白名单

    func fetchWhitelist(vin: String) async {
        busy = true
        defer { busy = false }
        do {
            append("⑤ 取白名单 VIN=\(vin)…")
            guard let user = requireUserName() else { return }
            let body: [String: Any] = [
                "userName": user,
                "deviceID": deviceID,
                "VINList": [vin],
            ]
            let resp = try await api.postJSON(path: Endpoint.whiteList, jsonBody: body,
                                              extraHeaders: requestIdHeader)
            append("⑤ code=\(resp.code ?? -1) desc=\(resp.description ?? resp.message ?? "-")\(hint(resp))")
            append(resp.rawPreview)
        } catch {
            append("⑤ 异常 " + error.localizedDescription)
        }
    }

    func clearLog() { logText = "" }
}

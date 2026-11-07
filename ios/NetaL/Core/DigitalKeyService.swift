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
    }

    /// 稳定设备 ID（对应安卓 deviceID），首次生成后持久化。
    var deviceID: String {
        if let v = try? KeychainHelper.get(account: "dk_deviceID"), !v.isEmpty { return v }
        let v = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try? KeychainHelper.set(v, account: "dk_deviceID")
        return v
    }

    /// userName 即登录账号（手机号）
    private var userName: String {
        CredentialStore.shared.phone ?? ""
    }

    /// 本机 ECC P-256 公钥（X9.63 非压缩 65 字节 base64），私钥留在 Secure Enclave。
    private func ensureLocalKeyPair() throws -> String {
        let key: SecKey
        do {
            key = try CredentialStore.shared.loadDevicePrivateKey()
        } catch {
            key = try CredentialStore.shared.generateDeviceKeyPair()
        }
        guard let b64 = CredentialStore.shared.publicKeyBase64(key) else {
            throw APIError.serverDetail("公钥导出失败")
        }
        return b64
    }

    // MARK: ① 上传公钥

    func uploadPublicKey() async {
        busy = true
        defer { busy = false }
        do {
            append("① 上传公钥…")
            let pub = try ensureLocalKeyPair()
            let body: [String: Any] = [
                "userName": userName,
                "deviceID": deviceID,
                "deviceModel": DeviceInfo.current.deviceModel,
                "deviceSysVer": DeviceInfo.current.systemVersion,
                "eccPubkey": pub,
            ]
            let resp = try await api.postJSON(path: Endpoint.eccPubkeyUpload, jsonBody: body)
            append("① code=\(resp.code ?? -1) desc=\(resp.description ?? resp.message ?? "-")")
            append(resp.rawPreview)
            if resp.isSuccess {
                publicKeyUploaded = true
                try? KeychainHelper.set("1", account: "dk_public_uploaded")
            } else if resp.code == 110217 {
                append("（公钥已登记，等待车端确认，稍后重试）")
            }
        } catch {
            append("① 异常 " + error.localizedDescription)
        }
    }

    // MARK: ② 钥匙列表

    func fetchKeyList() async {
        busy = true
        defer { busy = false }
        do {
            append("② 取钥匙列表…")
            let body: [String: Any] = ["userName": userName, "deviceID": deviceID]
            let resp = try await api.postJSON(path: Endpoint.keyList, jsonBody: body)
            append("② code=\(resp.code ?? -1) desc=\(resp.description ?? resp.message ?? "-")")
            keyListRaw = resp.rawPreview
            append(resp.rawPreview)
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
            let body: [String: Any] = [
                "userName": userName,
                "deviceID": deviceID,
                "keyIDList": keyIDs,
            ]
            let resp = try await api.postJSON(path: Endpoint.downloadKeyRaw, jsonBody: body)
            append("③ code=\(resp.code ?? -1) desc=\(resp.description ?? resp.message ?? "-")")
            append(resp.rawPreview)
            if let data = resp.data,
               let encoded = try? JSONEncoder().encode(data),
               let raw = String(data: encoded, encoding: .utf8) {
                keyRawData = raw
                try? KeychainHelper.set(raw, account: "dk_keyraw")
                append("（钥匙原文已存 Keychain，待解密分析）")
            }
        } catch {
            append("③ 异常 " + error.localizedDescription)
        }
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
            let body: [String: Any] = [
                "userName": userName,
                "deviceID": deviceID,
                "VINList": [vin],
            ]
            let resp = try await api.postJSON(path: Endpoint.whiteList, jsonBody: body)
            append("⑤ code=\(resp.code ?? -1) desc=\(resp.description ?? resp.message ?? "-")")
            append(resp.rawPreview)
        } catch {
            append("⑤ 异常 " + error.localizedDescription)
        }
    }

    func clearLog() { logText = "" }
}

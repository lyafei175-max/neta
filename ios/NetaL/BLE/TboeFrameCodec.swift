import Foundation
import CryptoKit

/// TBOE 协议实现（链路层 + 消息层）。
///
/// 协议已从 APK Ingeek SDK smali 完整逆向，并经 3 组安卓握手样本离线验证
/// （ECDSA 验签 + MD5 逐字节比对全部通过，2026-11-08）：
///
/// **链路层**（GATT 读写载荷 = 8 字节头 + protobuf，可分片）：
/// ```
/// [0]     = 0x00
/// [1]     = (resp ? 0x40 : 0) | (more ? 0x80 : 0) | (msgId & 0x1f)
/// [2]     = 总包数（单包 = 0）
/// [3]     = 包序号 0 基（单包 = 0）
/// [4..5]  = rid 小端 16 位（请求流水号，每会话从 1 递增）
/// [6..7]  = 本包数据长度 小端 16 位
/// [8..]   = protobuf 分片
/// ```
/// msgId：0 = 挑战响应，1 = 会话确认/心跳，2 = 车控指令。
///
/// **消息层**（签名字段 = ECDSA-SHA256 DER base64，签名输入 = field1 原始字节）：
/// ```
/// 挑战响应   {1:{1:29, 2:ts毫秒, 3:挑战码, 4:MD5(keyID+挑战码)大写hex,
///                5:deviceID, 6:机型, 7:256}, 2:签名}
/// 会话确认   {1:{1:4095, 2:ts毫秒, 3:MD5(keyID)大写hex}, 2:签名}
/// 心跳(5s)   = 会话确认
/// 车控指令   {1:{1:cmd, 2:ts毫秒, 3:params, 4:MD5(keyID)大写hex}, 2:签名}
/// ```
/// 实测样本：解锁 = cmd 1 / params 12（`IngeekCommandDoorUnlock`，sdk 枚举 2）。
enum TboeProtocol {

    // MARK: - 链路层

    struct LinkFrame {
        let msgId: UInt8
        let rid: Int
        let totalPkts: Int
        let pktIndex: Int
        let body: Data
    }

    /// 按链路层格式编码（自动分片）。chunkSize = maximumWriteValueLength − 8（头长）。
    static func encode(
        msgId: UInt8, rid: Int, body: Data, isResponse: Bool = false, chunkSize: Int
    ) -> [Data] {
        let size = max(chunkSize, 16)
        let total = max(1, (body.count + size - 1) / size)
        var packets: [Data] = []
        for i in 0..<total {
            let offset = i * size
            let end = min(offset + size, body.count)
            let chunk = body.subdata(in: offset..<end)

            var flags: UInt8 = msgId & 0x1f
            if isResponse { flags |= 0x40 }
            if total > 1 { flags |= 0x80 }

            var head = Data()
            head.append(0x00)
            head.append(flags)
            head.append(UInt8(total > 1 ? total : 0))
            head.append(UInt8(total > 1 ? i : 0))
            head.appendLE16(rid)
            head.appendLE16(chunk.count)
            packets.append(head + chunk)
        }
        return packets
    }

    /// 解析链路层帧；长度校验失败返回 nil（对应安卓「rx invalid」分支）。
    static func decode(_ raw: Data) -> LinkFrame? {
        guard raw.count >= 8 else { return nil }
        let bytes = [UInt8](raw)
        let declared = Int(bytes[6]) | (Int(bytes[7]) << 8)
        guard declared == raw.count - 8 else { return nil }

        let flags = bytes[1]
        let total = bytes[2] == 0 ? 1 : Int(bytes[2])
        let index = Int(bytes[3])
        let rid = Int(bytes[4]) | (Int(bytes[5]) << 8)
        return LinkFrame(
            msgId: flags & 0x1f,
            rid: rid,
            totalPkts: total,
            pktIndex: index,
            body: raw.subdata(in: 8..<raw.count)
        )
    }

    // MARK: - protobuf 最小编解码

    static func varintBytes(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var b = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    static func fieldVarint(_ field: Int, _ value: UInt64) -> Data {
        varintBytes(UInt64(field << 3)) + varintBytes(value)
    }

    static func fieldBytes(_ field: Int, _ value: Data) -> Data {
        varintBytes(UInt64(field << 3 | 2)) + varintBytes(UInt64(value.count)) + value
    }

    /// 解析出的字段：varint 与 length-delim 分开存。
    struct ProtoFields {
        var varints: [Int: UInt64] = [:]
        var blobs: [Int: Data] = [:]
        var blobList: [Int: [Data]] = [:]

        func string(_ field: Int) -> String? {
            guard let d = blobs[field] else { return nil }
            return String(data: d, encoding: .utf8)
        }
    }

    /// 单层字段扫描（本协议全部为一层 + 嵌套 message，够用）。
    static func parseFields(_ data: Data) -> ProtoFields {
        var f = ProtoFields()
        var i = 0
        let bytes = [UInt8](data)
        func readVarint(_ start: Int) -> (UInt64, Int)? {
            var v: UInt64 = 0
            var shift = 0
            var j = start
            while j < bytes.count {
                let b = bytes[j]
                v |= UInt64(b & 0x7f) << shift
                j += 1
                if b & 0x80 == 0 { return (v, j) }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < bytes.count {
            guard let (tag, next) = readVarint(i) else { break }
            i = next
            let field = Int(tag >> 3)
            let wire = Int(tag & 7)
            switch wire {
            case 0:
                guard let (v, next) = readVarint(i) else { return f }
                f.varints[field] = v
                i = next
            case 2:
                guard let (len, next) = readVarint(i) else { return f }
                i = next
                let end = i + Int(len)
                guard end <= bytes.count else { return f }
                let blob = data.subdata(in: i..<end)
                f.blobs[field] = blob
                f.blobList[field, default: []].append(blob)
                i = end
            default:
                return f
            }
        }
        return f
    }

    // MARK: - 认证素材

    /// MD5 大写 hex（Ingeek `b2.b`：MD5 → 大写 hex；三组样本逐字节验证一致）。
    static func md5Upper(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    /// 挑战响应里的认证串：MD5(keyID + 挑战码)
    static func challengeToken(keyID: String, code: String) -> String {
        md5Upper(keyID + code)
    }

    /// 会话 ID / 指令帧身份串：MD5(keyID)（实测 = EA30B62B… 样本吻合）。
    static func sessionToken(keyID: String) -> String {
        md5Upper(keyID)
    }

    /// 签名：ECDSA-SHA256（DER）→ base64。与安卓 `SHA256withECDSA` 完全一致。
    /// 签名输入 = 消息 field1 的原始字节（smali: toByteArray() 后直接 sign）。
    static func sign(payload: Data, privateKey: SecKey) throws -> String {
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            payload as CFData,
            &error
        ) else {
            throw APIError.serverDetail("TBOE 签名失败：\(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return (sig as Data).base64EncodedString()
    }

    // MARK: - 消息构造（外层 = {1: payload, 2: 签名 base64}）

    static func outerMessage(payload: Data, signature: String) -> Data {
        fieldBytes(1, payload) + fieldBytes(2, Data(signature.utf8))
    }

    /// 挑战响应：{1:29, 2:ts, 3:挑战码, 4:MD5(keyID+码), 5:deviceID, 6:机型, 7:256}
    static func challengeResponse(
        code: String, tsMs: Int64, keyID: String, deviceID: String, model: String,
        privateKey: SecKey
    ) throws -> Data {
        var p = Data()
        p += fieldVarint(1, 29)
        p += fieldVarint(2, UInt64(tsMs))
        p += fieldBytes(3, Data(code.utf8))
        p += fieldBytes(4, Data(challengeToken(keyID: keyID, code: code).utf8))
        p += fieldBytes(5, Data(deviceID.utf8))
        p += fieldBytes(6, Data(model.utf8))
        p += fieldVarint(7, 256)
        let sig = try sign(payload: p, privateKey: privateKey)
        return outerMessage(payload: p, signature: sig)
    }

    /// 会话确认 / 心跳：{1:4095, 2:ts, 3:MD5(keyID)}
    static func sessionConfirm(tsMs: Int64, keyID: String, privateKey: SecKey) throws -> Data {
        var p = Data()
        p += fieldVarint(1, 4095)
        p += fieldVarint(2, UInt64(tsMs))
        p += fieldBytes(3, Data(sessionToken(keyID: keyID).utf8))
        let sig = try sign(payload: p, privateKey: privateKey)
        return outerMessage(payload: p, signature: sig)
    }

    /// 车控指令：{1:cmd, 2:ts, 3:params, 4:MD5(keyID)}。实测解锁 = cmd 1 / params 12。
    static func command(
        cmd: UInt8, params: Int64, tsMs: Int64, keyID: String, privateKey: SecKey
    ) throws -> Data {
        var p = Data()
        p += fieldVarint(1, UInt64(cmd))
        p += fieldVarint(2, UInt64(tsMs))
        p += fieldVarint(3, UInt64(params))
        p += fieldBytes(4, Data(sessionToken(keyID: keyID).utf8))
        let sig = try sign(payload: p, privateKey: privateKey)
        return outerMessage(payload: p, signature: sig)
    }

    // MARK: - 消息解析

    /// 车端挑战：{1:{1:挑战码 ASCII, 2:ts}}
    static func parseChallenge(_ body: Data) -> (code: String, ts: Int64)? {
        let outer = parseFields(body)
        guard let inner = outer.blobs[1] else { return nil }
        let f = parseFields(inner)
        guard let code = f.string(1) else { return nil }
        return (code, Int64(f.varints[2] ?? 0))
    }

    /// 连接结果：{1:{1:status, 2:whiteListDataVer, 3:?, 4:ts, 5:keyDataVer, 6:model}}
    /// status = 4096 为成功（实测样本）。
    static func parseConnectResult(_ body: Data) -> (status: Int64, whiteListVer: Int64, keyVer: Int64)? {
        let outer = parseFields(body)
        guard let inner = outer.blobs[1] else { return nil }
        let f = parseFields(inner)
        guard let status = f.varints[1] else { return nil }
        return (Int64(status), Int64(f.varints[2] ?? 0), Int64(f.varints[5] ?? 0))
    }

    /// ack / 心跳应答：{3:ts}
    static func parseAck(_ body: Data) -> Int64? {
        let f = parseFields(body)
        return f.varints[3].map(Int64.init)
    }
}

// MARK: - 小工具

extension Data {
    mutating func appendLE16(_ v: Int) {
        append(UInt8(v & 0xff))
        append(UInt8((v >> 8) & 0xff))
    }
}

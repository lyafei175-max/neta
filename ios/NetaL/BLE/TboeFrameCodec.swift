import Foundation

/// TBOE 帧编解码器。
///
/// ## 状态：配置驱动的骨架，等待抓包校准
///
/// 协议规格中标为 `[未知]` 的部分（帧头魔数、长度字段位置、序号、校验算法）
/// 全部收敛到 `FrameLayout` 里。跑 `Analysis/analyze_tboe.py` 分析抓包后，
/// 改 `FrameLayout` 的常量即可，不需要动编解码逻辑本身。
///
/// ## 用法
/// ```swift
/// var codec = TboeFrameCodec()
/// let packet = codec.encode(type: .command, payload: cmdBytes)
/// transport.send(packet)
///
/// // 收到帧
/// if let frame = codec.decode(raw) {
///     switch frame.type {
///     case .challenge: handleChallenge(frame.payload)
///     case .status:   handleStatus(frame.payload)   // 408 字节
///     case .ack:      handleAck(frame.payload)
///     default:        break
///     }
/// }
/// ```
///
/// ## 待校准清单（跑完抓包逐项确认）
///
/// 1. `magic` —— 帧头魔数，脚本会提示「疑似 AA AA 帧头」
/// 2. `lengthOffset` / `lengthBytes` —— 长度字段位置与宽度
/// 3. `sequenceOffset` —— 序号位置，若无则设 nil
/// 4. `checksum` —— 校验算法，脚本会自动检验异或/累加和
/// 5. `typeOffset` —— 帧类型字段位置
struct TboeFrameCodec {

    // MARK: - 帧布局（待校准）

    struct FrameLayout {
        /// 帧头魔数。脚本提示「疑似 AA AA」时填 [0xAA, 0xAA]
        var magic: [UInt8] = [0xAA, 0xAA]

        /// 魔数之后是否跳过一个固定字段（如版本号）
        var magicSkip: Int = 0

        /// 长度字段偏移与宽度。-1 表示无长度字段
        var lengthOffset: Int = 2
        var lengthBytes: Int = 1

        /// 长度字段的编码：是否包含自身与帧头
        var lengthIncludesHeader: Bool = true

        /// 序号偏移，nil 表示无序号
        var sequenceOffset: Int?

        /// 帧类型字段偏移
        var typeOffset: Int = 3
        var typeBytes: Int = 1

        /// 校验方式
        var checksum: Checksum = .xor

        /// 校验码偏移，-1 表示在帧尾
        var checksumOffset: Int = -1
        var checksumBytes: Int = 1

        enum Checksum {
            case none
            /// 全部字节异或
            case xor
            /// 从 magicSkip 之后开始异或
            case xorFromBody
            /// 累加和 mod 256
            case sum
            /// CRC16（多项式待定）
            case crc16
            /// 未知/密文，无校验
            case unknown
        }
    }

    /// 帧类型。偏移值待抓包校准。
    enum FrameType: UInt8 {
        case challenge = 0x01      // 车端 → 主机：挑战码
        case challengeResponse = 0x02  // 主机 → 车端：挑战码响应
        case connectResponse = 0x03    // 车端 → 主机：连接应答
        case command = 0x10         // 主机 → 车端：车控指令
        case ack = 0x11             // 车端 → 主机：指令应答
        case status = 0x20          // 车端 → 主机：车况推送
        case whitelist = 0x30       // 白名单同步
        case disconnect = 0x40

        init?(raw: UInt8) { self.init(rawValue: raw) }
    }

    // MARK: - 解码结果

    struct Frame {
        let type: FrameType
        let sequence: UInt8?
        let payload: Data
        let raw: Data

        /// 车况推送直接解析（408 字节）
        func vehicleState(using parser: VehicleStatusParser = VehicleStatusParser()) throws -> VehicleState {
            try parser.parse(payload)
        }
    }

    enum CodecError: Error, LocalizedError {
        case tooShort(actual: Int, expected: Int)
        case badMagic(found: [UInt8])
        case unknownType(UInt8)
        case lengthMismatch(declared: Int, actual: Int)
        case checksumMismatch(expected: UInt8, actual: UInt8)

        var errorDescription: String? {
            switch self {
            case .tooShort(let a, let e):
                return "收到不合法帧：\(a) 字节，应为 \(e)"
            case .badMagic(let f):
                return "帧头错误：" + f.map { String(format: "%02X", $0) }.joined(separator: " ")
            case .unknownType(let t):
                return String(format: "未知帧类型 0x%02X", t)
            case .lengthMismatch(let d, let a):
                return "长度不符：声明 \(d) 实际 \(a)"
            case .checksumMismatch(let e, let a):
                return String(format: "校验失败：期望 0x%02X 实际 0x%02X", e, a)
            }
        }
    }

    // MARK: - 布局

    var layout = FrameLayout()

    // MARK: - 编码

    /// 构造一帧。
    func encode(type: FrameType, payload: Data, sequence: UInt8? = nil) -> Data {
        var frame = Data()
        frame.append(contentsOf: layout.magic)

        if layout.magicSkip > 0 {
            frame.append(contentsOf: [UInt8](repeating: 0, count: layout.magicSkip))
        }

        let headerSize = layout.magic.count + layout.magicSkip
        let fixedPart = (layout.sequenceOffset.map { _ in 1 } ?? 0)
            + layout.typeBytes
            + layout.checksumBytes
        let declaredLength = headerSize + layout.lengthBytes + fixedPart + payload.count

        // 长度字段
        if layout.lengthBytes > 0 && layout.lengthOffset >= 0 {
            let value = layout.lengthIncludesHeader ? declaredLength : payload.count
            frame.append(contentsOf: uintBytes(value, width: layout.lengthBytes))
        }

        // 预留类型与序号位置，按偏移填入
        var frameWithHoles = frame
        let needed = layout.typeOffset + layout.typeBytes
        while frameWithHoles.count < needed { frameWithHoles.append(0x00) }

        if let seqOffset = layout.sequenceOffset,
           seqOffset >= 0,
           seqOffset < frameWithHoles.count {
            frameWithHoles[seqOffset] = sequence ?? 0
        }

        if layout.typeOffset >= 0,
           layout.typeOffset < frameWithHoles.count {
            frameWithHoles[layout.typeOffset] = type.rawValue
        }

        frame = frameWithHoles
        frame.append(contentsOf: payload)

        // 校验
        if layout.checksum != .none && layout.checksum != .unknown {
            let sum = computeChecksum(frame, excludingLast: true)
            frame.append(contentsOf: uintBytes(sum, width: layout.checksumBytes))
        }

        return frame
    }

    /// 构造一条指令帧。载荷格式待抓包确认（当前假设为 tag+编码）。
    func encodeCommand(_ command: VehicleCommand) -> Data {
        // ⚠️ 待校准：指令在帧内的载荷布局。
        // 当前假设为 [tag(1) | hex编码(3)]
        // 抓包后用差分法确认真正的动作码位置。
        var payload = Data()
        payload.append(command.tag)
        payload.append(contentsOf: Array(command.value.utf8))
        return encode(type: .command, payload: payload)
    }

    /// 构造挑战码响应帧。
    func encodeChallengeResponse(signature: Data, sequence: UInt8? = nil) -> Data {
        encode(type: .challengeResponse, payload: signature, sequence: sequence)
    }

    // MARK: - 解码

    func decode(_ raw: Data) throws -> Frame {
        let minLength = layout.magic.count + max(1, layout.typeOffset + layout.typeBytes)
        guard raw.count >= minLength else {
            throw CodecError.tooShort(actual: raw.count, expected: minLength)
        }

        // 帧头校验
        let magicBytes = [UInt8](raw.prefix(layout.magic.count))
        if magicBytes != layout.magic {
            throw CodecError.badMagic(found: magicBytes)
        }

        // 长度校验
        if layout.lengthBytes > 0, layout.lengthOffset >= 0 {
            let lengthEnd = layout.lengthOffset + layout.lengthBytes
            if lengthEnd <= raw.count {
                let declared = readUInt(raw, offset: layout.lengthOffset, width: layout.lengthBytes)
                let expected = layout.lengthIncludesHeader ? raw.count : raw.count - layout.magic.count - layout.lengthBytes
                if declared != expected {
                    throw CodecError.lengthMismatch(declared: Int(declared), actual: Int(expected))
                }
            }
        }

        // 校验码
        if layout.checksum != .none && layout.checksum != .unknown && layout.checksumBytes > 0 {
            let body = dropLast(raw, count: layout.checksumBytes)
            let expected = computeChecksum(body, excludingLast: false)
            let actual = readUInt(body, offset: body.count - layout.checksumBytes,
                                  width: layout.checksumBytes)
            if expected != actual {
                throw CodecError.checksumMismatch(expected: expected, actual: actual)
            }
        }

        // 帧类型
        guard layout.typeOffset + layout.typeBytes <= raw.count else {
            throw CodecError.tooShort(actual: raw.count, expected: layout.typeOffset + layout.typeBytes)
        }
        let rawType = readUInt(raw, offset: layout.typeOffset, width: layout.typeBytes)
        guard let type = FrameType(raw: UInt8(truncatingIfNeeded: rawType)) else {
            throw CodecError.unknownType(UInt8(truncatingIfNeeded: rawType))
        }

        // 序号
        var sequence: UInt8?
        if let seqOffset = layout.sequenceOffset, seqOffset < raw.count {
            sequence = raw[seqOffset]
        }

        // 载荷：跳过帧头 + 长度 + 类型 + 序号 + 校验
        var payloadStart = layout.magic.count + layout.magicSkip + layout.lengthBytes
        payloadStart = max(payloadStart, layout.typeOffset + layout.typeBytes)
        if let seqOffset = layout.sequenceOffset {
            payloadStart = max(payloadStart, seqOffset + 1)
        }

        var payloadEnd = raw.count - layout.checksumBytes
        if layout.checksum == .none || layout.checksum == .unknown {
            payloadEnd = raw.count
        }
        payloadEnd = max(payloadStart, min(payloadEnd, raw.count))

        let payload = payloadStart <= payloadEnd
            ? raw.subdata(in: payloadStart..<payloadEnd)
            : Data()

        return Frame(type: type, sequence: sequence, payload: payload, raw: raw)
    }

    /// 尝试解码，失败返回 nil（用于日志密集的 notify 回调）。
    func decodeIfPossible(_ raw: Data) -> Frame? {
        try? decode(raw)
    }

    // MARK: - 分片重组

    /// 分片重组器。
    ///
    /// APK 中文文案有「车端报文分片丢失」，说明存在分片机制，
    /// 但切分规则未知，需抓包确认（分析脚本的帧长度直方图会给出线索）。
    final class Reassembler {
        private var buffer = Data()
        private var expectedTotal = 0

        /// 加入一段数据，返回重组后的完整帧（未完成则返回 nil）。
        func append(_ chunk: Data) -> Data? {
            buffer.append(chunk)

            // 依赖长度字段判断是否完整
            guard codec.layout.lengthBytes > 0, codec.layout.lengthOffset >= 0,
                  buffer.count >= codec.layout.lengthOffset + codec.layout.lengthBytes else {
                return nil
            }

            let declared = Int(codec.readUInt(buffer,
                                              offset: codec.layout.lengthOffset,
                                              width: codec.layout.lengthBytes))
            if codec.layout.lengthIncludesHeader {
                expectedTotal = declared
            } else {
                expectedTotal = declared + codec.layout.magic.count + codec.layout.lengthBytes
            }

            guard buffer.count >= expectedTotal else { return nil }

            let frame = buffer.prefix(expectedTotal)
            buffer.removeAll(keepingCapacity: true)
            expectedTotal = 0
            return Data(frame)
        }

        func reset() {
            buffer.removeAll()
            expectedTotal = 0
        }

        var hasPartial: Bool { !buffer.isEmpty }

        private let codec: TboeFrameCodec

        init(codec: TboeFrameCodec) {
            self.codec = codec
        }
    }

    // MARK: - 内部工具

    /// 计算校验值。
    ///
    /// ⚠️ 校验范围（从哪个字节开始、是否含帧头）必须抓包确认，
    /// 这里提供三种常见范围供切换。
    private func computeChecksum(_ data: Data, excludingLast: Bool) -> UInt8 {
        let body = excludingLast ? dropLast(data, count: 1) : data

        switch layout.checksum {
        case .xor:
            return body.reduce(0) { $0 ^ $1 }
        case .xorFromBody:
            let start = layout.magic.count + layout.magicSkip
            guard start < body.count else { return 0 }
            return body[start...].reduce(0) { $0 ^ $1 }
        case .sum:
            return UInt8(body.reduce(0) { ($0 &+ Int($1)) } & 0xFF)
        case .crc16:
            return UInt8(crc16(body) & 0xFF)
        case .none, .unknown:
            return 0
        }
    }

    /// CRC16（Modbus 多项式 0xA001），多项式需抓包确认。
    private func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    func readUInt(_ data: Data, offset: Int, width: Int) -> UInt8 {
        guard offset >= 0, offset + width <= data.count else { return 0 }
        var value: UInt8 = 0
        for i in 0..<width {
            value = (value << 8) | data[offset + i]
        }
        return value
    }

    private func uintBytes(_ value: Int, width: Int) -> [UInt8] {
        guard width > 0 else { return [] }
        var result = [UInt8](repeating: 0, count: width)
        var v = value
        for i in stride(from: width - 1, through: 0, by: -1) {
            result[i] = UInt8(v & 0xFF)
            v >>= 8
        }
        return result
    }

    private func dropLast(_ data: Data, count: Int) -> Data {
        guard count > 0, data.count > count else { return data }
        return data.prefix(data.count - count)
    }
}
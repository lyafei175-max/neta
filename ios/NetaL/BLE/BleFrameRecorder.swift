import Foundation
import CoreBluetooth

/// BLE 抓包录制工具。
///
/// **这是解掉移植最大阻塞点的工具。** 协议规格里标为 `[未知]` 的
/// 帧格式、分片规则、挑战码签名、白名单结构，全部要靠它录出来。
///
/// 用法：
/// 1. 在真机（不能用模拟器）上运行本工具
/// 2. 扫描并连接车机 BLE
/// 3. 自动订阅 fff1 / fff2 的 notify
/// 4. 所有收发帧按时间戳记录，可导出 JSON
/// 5. 用 macOS 上的 `Analysis/` 脚本解析
///
/// 录制时的操作顺序很重要（帧之间靠时间戳对齐）：
/// ```
/// 录制开始 → 连接 →（车端下发挑战码）→ 原 APK 侧操作 →
/// 解锁/上电等指令 → 白名单同步 → 断开
/// ```
final class BleFrameRecorder: NSObject {

    static let shared = BleFrameRecorder()

    // MARK: 录制帧模型

    struct Frame {
        enum Direction: String {
            case tx = "TX"   // 主机 → 车端
            case rx = "RX"   // 车端 → 主机
        }

        let timestamp: TimeInterval
        let relativeTime: TimeInterval
        let direction: Direction
        let characteristic: String
        let payload: Data

        var hex: String {
            payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        }

        /// 可读预览。不可打印字节用 `.` 代替，便于快速肉眼识别协议字段。
        var asciiPreview: String {
            String(payload.map { byte -> Character in
                (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
            })
        }
    }

    // MARK: 状态

    private(set) var frames: [Frame] = []
    private(set) var isRecording = false
    private(set) var discoveredPeripherals: [(id: UUID, name: String, rssi: Int)] = []

    var startTime: Date?

    /// 录制日志回调（供 UI 实时显示）
    var onFrame: ((Frame) -> Void)?
    /// 设备发现回调
    var onPeripheralDiscovered: (() -> Void)?
    /// 状态变化回调
    var onStateChange: ((String) -> Void)?

    // MARK: CoreBluetooth

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var subscribedCharacteristics: [CBCharacteristic] = []
    private var notifyCount = 0
    private var writeCount = 0

    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 录制控制

    func startRecording() {
        frames.removeAll()
        discoveredPeripherals.removeAll()
        subscribedCharacteristics.removeAll()
        notifyCount = 0
        writeCount = 0
        startTime = Date()
        isRecording = true
        onStateChange?("录制已开始")
    }

    func stopRecording() -> URL? {
        isRecording = false
        stopScan()
        guard let startTime else { return nil }

        let export = FrameLog(
            exportedAt: Date(),
            device: DeviceInfo.current.deviceModel,
            systemVersion: DeviceInfo.current.systemVersion,
            peer: connectedPeripheral?.name ?? "unknown",
            peerIdentifier: connectedPeripheral?.identifier.uuidString ?? "unknown",
            totalFrames: frames.count,
            frames: frames.map {
                FrameRecord(
                    index: frames.firstIndex(of: $0) ?? 0,
                    timestamp: $0.timestamp,
                    relativeTime: $0.relativeTime,
                    direction: $0.direction.rawValue,
                    characteristic: $0.characteristic,
                    hex: $0.payload.map { String(format: "%02X", $0) }.joined(),
                    ascii: $0.asciiPreview
                )
            }
        )

        return FrameLogWriter.write(export)
    }

    private func record(_ payload: Data, direction: Frame.Direction, characteristic: CBCharacteristic) {
        guard isRecording else { return }

        let now = Date()
        let start = startTime ?? now
        let frame = Frame(
            timestamp: now.timeIntervalSince1970,
            relativeTime: now.timeIntervalSince(start),
            direction: direction,
            characteristic: characteristic.uuid.uuidString,
            payload: payload
        )

        frames.append(frame)
        onFrame?(frame)
    }

    // MARK: - 扫描

    /// 扫描所有广播设备（不按 service 过滤，确保不漏掉车机）。
    func startScan() {
        guard centralManager.state == .poweredOn else {
            onStateChange?("蓝牙未开启")
            return
        }

        centralManager.scanForPeripherals(
            withServices: nil,
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true,
                CBCentralManagerScanOptionShowPowerLevelKey: true
            ]
        )
        onStateChange?("扫描中")
    }

    func stopScan() {
        centralManager.stopScan()
        onStateChange?("扫描已停止")
    }

    func connect(to id: UUID) {
        guard let peripheral = centralManager
            .retrievePeripherals(withIdentifiers: [id])
            .first else {
            onStateChange?("找不到该设备")
            return
        }

        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionEnableAutoReconnect: false
        ])
        onStateChange?("连接中 → \(peripheral.name ?? id.uuidString)")
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - 主动发送

    /// 向已订阅特征写入原始数据。
    ///
    /// 用这个方法手工试探协议：填入猜测的帧格式，观察车端响应。
    func sendRaw(hexString: String, usePrimary: Bool = true) {
        let hex = hexString
            .replacingOccurrences(of: " ", with: "")
            .filter { $0.isHexDigit }

        guard !hex.isEmpty, hex.count % 2 == 0 else {
            onStateChange?("HEX 格式无效")
            return
        }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<next], radix: 16) {
                data.append(byte)
            }
            index = next
        }

        guard let peripheral = connectedPeripheral,
              let characteristic = subscribedCharacteristics.first(where: {
                  usePrimary
                      ? $0.uuid == TboeUUID.primaryService
                      : $0.uuid == TboeUUID.secondaryService
              })
        else {
            onStateChange?("目标特征未就绪")
            return
        }

        // 按 MTU 分片发送（协议分片规则未知，先朴素切分）
        let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
        var offset = 0
        while offset < data.count {
            let end = min(offset + mtu, data.count)
            peripheral.writeValue(data.subdata(in: offset..<end),
                                  for: characteristic, type: .withResponse)
            record(data.subdata(in: offset..<end), direction: .tx, characteristic: characteristic)
            offset = end
        }
    }

    /// 读取当前 MTU。
    func currentMTU() -> Int? {
        connectedPeripheral?.maximumWriteValueLength(for: .withResponse)
    }
}

// MARK: - CBCentralManagerDelegate

extension BleFrameRecorder: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            onStateChange?("蓝牙已就绪")
        case .poweredOff:
            onStateChange?("请在系统设置里打开蓝牙")
        case .unauthorized:
            onStateChange?("蓝牙扫描车辆需要定位权限")
        case .unsupported:
            onStateChange?("本机没有可用的蓝牙适配器")
        case .resetting:
            onStateChange?("蓝牙正在重置")
        case .unknown:
            onStateChange?("蓝牙状态未知")
        @unknown default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "未命名"

        // 按 id 去重，保留最新 RSSI
        discoveredPeripherals.removeAll { $0.id == peripheral.identifier }
        discoveredPeripherals.append((peripheral.identifier, name, RSSI.intValue))
        discoveredPeripherals.sort { $0.rssi > $1.rssi }
        onPeripheralDiscovered?()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onStateChange?("已连接 \(peripheral.name ?? "设备")")
        // 发现所有服务，不做 UUID 过滤 —— 车机可能用非标准 service
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        onStateChange?("连接失败：\(error?.localizedDescription ?? "未知原因")")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        subscribedCharacteristics.removeAll()
        onStateChange?("已断开：\(error?.localizedDescription ?? "正常断开")")
    }

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        onStateChange?("状态已恢复")
    }
}

// MARK: - CBPeripheralDelegate

extension BleFrameRecorder: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            onStateChange?("服务发现失败：\(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            onStateChange?("未发现任何服务")
            return
        }

        onStateChange?("发现 \(services.count) 个服务，发现全部特征")
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            onStateChange?("特征发现失败：\(error.localizedDescription)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            let supportsNotify = characteristic.properties.contains(.notify) ||
                                 characteristic.properties.contains(.indicate)

            if supportsNotify {
                peripheral.setNotifyValue(true, for: characteristic)
                if !subscribedCharacteristics.contains(where: { $0.uuid == characteristic.uuid }) {
                    subscribedCharacteristics.append(characteristic)
                }
            }

            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }

            let rw = characteristic.properties.contains(.write) ||
                     characteristic.properties.contains(.writeWithoutResponse)
            let props = [supportsNotify ? "notify" : nil,
                         rw ? "write" : nil,
                         characteristic.properties.contains(.read) ? "read" : nil]
                .compactMap { $0 }
                .joined(separator: "/")

            onStateChange?("特征 \(characteristic.uuid) [\(props.isEmpty ? "无属性" : props)]")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            onStateChange?("读取失败：\(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }

        notifyCount += 1
        record(data, direction: .rx, characteristic: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        writeCount += 1
        if let error {
            onStateChange?("写入失败：\(error.localizedDescription)")
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {}

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil {
            onStateChange?("RSSI: \(RSSI.intValue) dBm")
        }
    }
}

// MARK: - 导出模型

struct FrameRecord: Codable {
    let index: Int
    let timestamp: TimeInterval
    let relativeTime: TimeInterval
    let direction: String
    let characteristic: String
    let hex: String
    let ascii: String
}

struct FrameLog: Codable {
    let exportedAt: Date
    let device: String
    let systemVersion: String
    let peer: String
    let peerIdentifier: String
    let totalFrames: Int
    let frames: [FrameRecord]
}

enum FrameLogWriter {

    /// 导出到 Documents 目录，返回文件 URL。
    static func write(_ log: FrameLog) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(log) else { return nil }

        let filename = "tboe-capture-\(Int(Date().timeIntervalSince1970)).json"
        let url = FileManager.default
            .documentsDirectory
            .appendingPathComponent(filename)

        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// 便捷读取（供 Analysis 脚本生成器使用）。
    static func captureDirectory() -> URL {
        FileManager.default.documentsDirectory
    }
}
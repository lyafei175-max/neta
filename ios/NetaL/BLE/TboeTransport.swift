import Foundation
import CoreBluetooth

/// BLE GATT 常量。v0.3.1 按安卓实测日志校准（TBOE校准-2026-11-07.md）：
/// 「GATT 特征 write=0000fff2 properties=0x0C notify=0000fff1 properties=0x10」
enum TboeUUID {

    /// notify 特征（车 → 手机，含 CCCD 2902）
    static let notify = CBUUID(string: "0000fff1-0000-1000-8000-00805f9b34fb")
    /// write 特征（手机 → 车）
    static let write = CBUUID(string: "0000fff2-0000-1000-8000-00805f9b34fb")
    /// CCCD（订阅通知）
    static let cccd = CBUUID(string: "00002902-0000-1000-8000-00805f9b34fb")

    /// 实测 MTU=247（安卓主动请求；iOS 自动协商，写之前查 maximumWriteValueLength）
    static let preferredMTU: Int = 247

    /// 车机广播名前缀：HOZON_KEY_<VIN 尾 5 位>（实测 HOZON_KEY_00946）。
    /// 车机用随机轮换地址，必须按名字匹配。
    static let advertisePrefix = "HOZON_KEY_"
}

/// TBOE 会话状态机。
///
/// 状态流转由 APK 中文文案还原（已确认），帧格式未确认（需抓包）。
enum TboeSessionState: Equatable {
    case idle
    /// 已连接 GATT，等待服务发现
    case connecting
    /// 连接请求已写入，等车端挑战码
    case awaitingChallenge
    /// 挑战码已收到，等回送响应
    case sendingResponse
    /// 连接应答已发送，等验签结果
    case verifyingResponse
    /// 白名单同步中
    case syncingWhitelist
    /// 可控状态
    case ready
    case failed(String)

    var isUsable: Bool { self == .ready }
}

/// TBOE 近场通道。
///
/// 原 APK 对应 `app.netal.ble.tboe.TboeBleTransport` + `TboeSession`
/// （日志标签 `NetaTboe`、`NetaTboeLink`）。
///
/// ⚠️ 【待抓包补全】以下部分仅有状态机骨架，帧编解码未知：
///   - 帧头格式（魔数 / 版本 / 长度 / 序号）
///   - 分片与重组规则
///   - 挑战码编码与 ECDSA 签名字节序
///   - 白名单数据结构
///
/// 定位方法：用 nRF Connect 订阅 `0000fff2` 的 notify，录制完整握手过程。
final class TboeTransport: NSObject {

    static let shared = TboeTransport()

    // MARK: 状态

    private(set) var state: TboeSessionState = .idle {
        didSet { onStateChange?(state) }
    }

    /// 车况回调
    var onVehicleState: ((VehicleState) -> Void)?
    /// 指令执行结果回调（true = 车端确认执行）
    var onCommandResult: ((VehicleCommand, Bool) -> Void)?
    /// 状态机变化回调
    var onStateChange: ((TboeSessionState) -> Void)?
    /// 原始帧回调（调试用）
    var onRawFrame: ((Data) -> Void)?
    /// 扫描发现回调（全部 FFF1 广播设备，供手动选择连接）
    var onDiscovered: ((CBPeripheral, String?, Int) -> Void)?
    /// RSSI 回调（靠近解锁用）
    var onRSSIUpdate: ((Int) -> Void)?
    /// 收到车端挑战码
    var onChallenge: ((Data) -> Void)?
    /// 收到连接应答
    var onConnectResponse: ((Data) -> Void)?

    // MARK: CoreBluetooth

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?    // FFF2（手机→车）
    private var notifyCharacteristic: CBCharacteristic?   // FFF1（车→手机）

    /// 重组缓冲区
    private var reassemblyBuffer = Data()
    private var pendingCommand: VehicleCommand?

    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 扫描

    func startScan(timeout: TimeInterval = 10) {
        guard centralManager.state == .poweredOn else {
            state = .failed("系统蓝牙未开启")
            return
        }
        // 实测车端广播靠名字匹配（随机地址），不按服务 UUID 过滤
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.stopScan()
        }
    }

    func stopScan() {
        centralManager.stopScan()
    }

    // MARK: - 连接

    func connect(to peripheral: CBPeripheral) {
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        state = .connecting

        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    func disconnect() {
        guard let peripheral else { return }
        // 原 APK 有「发送断开请求失败」错误分支，说明断开前会先发协议层断开帧。
        // ⚠️ 断开帧格式未知，此处直接断开。
        centralManager.cancelPeripheralConnection(peripheral)
        self.peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        state = .idle
    }

    // MARK: - 指令下发

    /// 帧编解码器。
    ///
    /// ⚠️ `TboeFrameCodec.layout` 的默认值是猜测的，必须用抓包结果校准。
    /// 校准前发出的帧车端不会正确响应。
    let codec = TboeFrameCodec()

    /// 分片重组器
    private lazy var reassembler = TboeFrameCodec.Reassembler(codec: codec)

    /// 车况解析器（408 字节），偏移表待校准
    private let statusParser = VehicleStatusParser()

    /// 通过近场下发指令。
    func send(_ command: VehicleCommand, timeout: TimeInterval? = nil) {
        guard state == .ready else {
            // 原 APK 文案：「蓝牙已连接时优先使用」「未连接或下发失败时走网络」
            onCommandResult?(command, false)
            return
        }

        pendingCommand = command

        // ⚠️ 指令载荷布局待抓包确认，当前为 codec 的占位实现
        let packet = codec.encodeCommand(command)
        write(packet)

        // 超时对应 car_config.json 中的 per-command timeout
        let wait = timeout ?? command.timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.pendingCommand == command else { return }
            self.pendingCommand = nil
            self.onCommandResult?(command, false)
        }
    }

    private func write(_ data: Data) {
        guard let peripheral, let characteristic = writeCharacteristic else { return }
        // 原 APK 存在分片逻辑（`车端报文分片丢失`）。
        // 分片规则待抓包确认，此处按协商 MTU 朴素切分。
        let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
        let chunkSize = max(mtu > 0 ? mtu : TboeUUID.preferredMTU - 3, 20)
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            peripheral.writeValue(data.subdata(in: offset..<end),
                                  for: characteristic, type: .withResponse)
            offset = end
        }
    }

    // MARK: - 帧解析

    private func handleReceived(_ data: Data) {
        onRawFrame?(data)

        // 分片重组（若 FrameLayout 配了长度字段）
        let frameData: Data
        if codec.layout.lengthBytes > 0, codec.layout.lengthOffset >= 0 {
            guard let complete = reassembler.append(data) else { return }
            frameData = complete
        } else {
            frameData = data
        }

        guard let frame = codec.decodeIfPossible(frameData) else {
            // 对应文案「收到不合法帧」
            return
        }

        switch frame.type {
        case .challenge:
            // 等待中收到挑战码 → 验签后回送
            state = .sendingResponse
            handleChallenge(frame)

        case .connectResponse:
            // 挑战码回送后收到连接应答 → 验签
            state = .verifyingResponse
            handleConnectResponse(frame)

        case .ack:
            // 指令应答
            if let pending = pendingCommand {
                pendingCommand = nil
                // 应答载荷判定成功/失败，需抓包确认状态码位置
                onCommandResult?(pending, true)
            }

        case .status:
            // 408 字节车况推送
            do {
                let vehicleState = try frame.vehicleState(using: statusParser)
                onVehicleState?(vehicleState)
            } catch {
                // 对应文案「车况解析失败」「结构不符合预期」
                return
            }

        case .whitelist:
            state = .ready

        case .disconnect:
            disconnect()

        default:
            break
        }
    }

    /// 处理车端挑战码。
    ///
    /// ⚠️ 签名算法与字节序待抓包确认。
    /// 原 APK 用 `SHA256withECDSA`，密钥为本地 ECC 私钥。
    private func handleChallenge(_ frame: TboeFrameCodec.Frame) {
        onChallenge?(frame.payload)

        // TODO: 用 CredentialStore 的设备私钥对挑战码签名后回送
        //   签名算法：.ecdsaSignatureMessageX962SHA256
        //   注意字节序：SecKey 的 DER 输出 vs 车端期望的 R||S 拼接，需抓包确认
    }

    private func handleConnectResponse(_ frame: TboeFrameCodec.Frame) {
        // TODO: 用车端公钥验签
        //   成功后进入白名单同步，失败则对应文案「连接应答验签失败」
        onConnectResponse?(frame.payload)

        state = .syncingWhitelist
    }
}

// MARK: - CBCentralManagerDelegate

extension TboeTransport: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            break
        case .poweredOff:
            state = .failed("系统蓝牙未开启")
        case .unauthorized:
            state = .failed("缺少蓝牙权限")
        case .unsupported:
            state = .failed("这台设备没有可用的蓝牙适配器")
        case .resetting:
            state = .failed("蓝牙未连接")
        case .unknown:
            break
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
        onRSSIUpdate?(RSSI.intValue)
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        // 全部广播设备上报（含车机与钥匙相关外设），由 UI 层选择连接
        onDiscovered?(peripheral, name, RSSI.intValue)
        // 实测车机广播名 = HOZON_KEY_<VIN尾5位>（随机地址，按名字匹配）
        if let name, name.hasPrefix(TboeUUID.advertisePrefix) {
            connect(to: peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connecting
        peripheral.delegate = self
        // 实测车端有 5 个服务，特征按 UUID 匹配，服务 UUID 未枚举 → 全量发现
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        state = .failed(error?.localizedDescription ?? "连接抛异常")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        state = .idle
        writeCharacteristic = nil
        notifyCharacteristic = nil
    }
}

// MARK: - CBPeripheralDelegate

extension TboeTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            state = .failed("连接请求写入失败：\(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else {
            state = .failed("开始发现服务失败")
            return
        }

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
            state = .failed("连接或订阅通知失败：\(error.localizedDescription)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case TboeUUID.write:
                writeCharacteristic = characteristic
            case TboeUUID.notify:
                notifyCharacteristic = characteristic
            default:
                continue
            }

            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else {
            state = .failed("收到不合法帧")
            return
        }
        handleReceived(data)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            state = .failed("写特征失败：\(error.localizedDescription)")
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // 透传模组可能使用 Write Without Response，需要等待此回调再发下一片。
        // ⚠️ 分片调度逻辑需抓包后完善。
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil {
            onRSSIUpdate?(RSSI.intValue)
        }
    }
}
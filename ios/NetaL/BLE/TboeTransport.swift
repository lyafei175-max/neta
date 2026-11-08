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
enum TboeSessionState: Equatable {
    case idle
    /// 已连接 GATT，等待服务发现
    case connecting
    /// 订阅完成，等车端挑战码
    case awaitingChallenge
    /// 挑战响应已回送，等 connect_result
    case sendingResponse
    /// 会话确认已发送，等 ack
    case verifyingResponse
    /// 可控状态（心跳保活中）
    case ready
    case failed(String)

    var isUsable: Bool { self == .ready }
}

/// TBOE 近场通道（协议实现见 `TboeProtocol`，已按 Ingeek smali 逆向 + 样本验证）。
///
/// 会话时序（实测抓包）：连接 → 订阅 FFF1 → 车端推 challenge → 回 challenge-response(msgId 0)
/// → 车 connect_result(4096) → 回 session-confirm(msgId 1) → 车 ack → ready（5s 心跳）。
final class TboeTransport: NSObject {

    static let shared = TboeTransport()

    // MARK: 状态

    private(set) var state: TboeSessionState = .idle {
        didSet {
            onStateChange?(state)
            DiagnosticLog.shared.log("NetaTboe", "state=\(state)")
            // 会话就绪时缓存外设标识——后台围栏唤醒后可免扫描直连
            if case .ready = state, let p = peripheral {
                UserDefaults.standard.set(p.identifier.uuidString, forKey: "last_peripheral_id")
            }
        }
    }

    /// 车况回调（云端 408 字节帧，BLE 通道暂不产出）
    var onVehicleState: ((VehicleState) -> Void)?
    /// 指令执行结果回调（true = 车端确认执行）
    var onCommandResult: ((VehicleCommand, Bool) -> Void)?
    /// 状态机变化回调
    var onStateChange: ((TboeSessionState) -> Void)?
    /// 原始帧回调（调试用）
    var onRawFrame: ((Data) -> Void)?
    /// 扫描发现回调（供手动选择连接）
    var onDiscovered: ((CBPeripheral, String?, Int) -> Void)?
    /// RSSI 回调（靠近解锁用）
    var onRSSIUpdate: ((Int) -> Void)?
    /// 收到车端挑战码
    var onChallenge: ((String) -> Void)?

    // MARK: CoreBluetooth

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?    // FFF2（手机→车）
    private var notifyCharacteristic: CBCharacteristic?   // FFF1（车→手机）

    /// 多包重组缓冲（按到达顺序拼接）
    private var reassemblyBuffer = Data()
    private var reassemblyExpect = 0
    private var pendingCommand: VehicleCommand?

    /// 心跳定时器（5s，与会话确认同构帧）
    private var heartbeatTimer: DispatchSourceTimer?
    /// RSSI 轮询（1s，连接期间保持距离判定有新鲜样本）
    private var rssiPollTimer: DispatchSourceTimer?
    private var rid = 0
    private var lastHeartbeatAck = true
    /// 已发出挑战响应、等待 connect_result（独立标志，不依赖状态枚举——
    /// v0.3.11 曾因广播风暴踩状态导致 connect_result 被拒收，diag9 实测）
    private var sentChallengeResponse = false

    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 会话素材

    /// 数字钥匙 keyID（② 同步成功时写入）
    private var keyID: String? {
        if let v = try? KeychainHelper.get(account: "dk_keyid"), !v.isEmpty { return v }
        // 兜底：从已存的钥匙原文 JSON 里提取
        if let raw = try? KeychainHelper.get(account: "dk_keyraw"),
           let d = raw.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            var found: String?
            func walk(_ any: Any) {
                if let dict = any as? [String: Any] {
                    for (k, v) in dict {
                        if k == "keyID", let s = v as? String, found == nil { found = s }
                        walk(v)
                    }
                } else if let arr = any as? [Any] {
                    arr.forEach(walk)
                }
            }
            walk(obj)
            return found
        }
        return nil
    }

    private var privateKey: SecKey? {
        try? CredentialStore.shared.loadDevicePrivateKey()
    }

    private var deviceID: String {
        (try? CredentialStore.shared.deviceSeriesNo()) ?? ""
    }

    private var tsMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// 可否发起新连接（空闲或失败态）。failed 带关联值，
    /// 不能直接 `state == .failed` 比较，用模式匹配。
    private var isIdleOrFailed: Bool {
        switch state {
        case .idle, .failed: return true
        default: return false
        }
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

    // MARK: 自动扫描循环（v0.3.14）

    /// 后台围栏唤醒用：免扫描直连上次会话的外设（bluetooth-central 后台模式合法）。
    /// 无缓存标识时退回短扫描（仅前台有效）。
    func reconnectCachedPeripheral() {
        guard centralManager.state == .poweredOn else {
            DiagnosticLog.shared.log("NetaTboe", "后台重连失败：蓝牙未开")
            return
        }
        guard isIdleOrFailed else { return }
        if let idStr = UserDefaults.standard.string(forKey: "last_peripheral_id"),
           let uuid = UUID(uuidString: idStr) {
            let targets = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let p = targets.first {
                DiagnosticLog.shared.log("NetaTboe", "后台直连缓存外设 \(idStr)")
                connect(to: p)
                return
            }
        }
        DiagnosticLog.shared.log("NetaTboe", "无缓存外设，退回扫描")
        startScan(timeout: 4)
    }

    /// 靠近自动连接：空闲时周期性开扫描（扫 4s / 停 8s 占空比省电），
    /// 连上后自动静默，断开后自动恢复。手动扫描页不受影响。
    private var autoScanEnabled = false
    private var autoScanTimer: DispatchSourceTimer?

    func setAutoScan(_ enabled: Bool) {
        autoScanEnabled = enabled
        if enabled {
            startAutoScanLoop()
        } else {
            autoScanTimer?.cancel()
            autoScanTimer = nil
            if centralManager.state == .poweredOn, state != .ready {
                stopScan()
            }
        }
    }

    private func startAutoScanLoop() {
        guard autoScanTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 8)
        t.setEventHandler { [weak self] in
            guard let self, self.autoScanEnabled, self.isIdleOrFailed else { return }
            guard self.centralManager.state == .poweredOn else { return }
            self.startScan(timeout: 4)
        }
        t.resume()
        autoScanTimer = t
    }

    // MARK: - 连接

    func connect(to peripheral: CBPeripheral) {
        // v0.3.12：车端广播会持续被扫到，重复 connect 会把状态机反复踩回
        // .connecting，导致 connect_result 到达时状态守卫失配（diag9 实测：
        // 挑战响应已发、车端已回 4096，却被踩掉）。非空闲/失败态一律忽略。
        guard isIdleOrFailed else { return }
        stopScan()
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        state = .connecting

        centralManager.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ])
    }

    func disconnect() {
        guard let peripheral else { return }
        stopHeartbeat()
        sentChallengeResponse = false
        centralManager.cancelPeripheralConnection(peripheral)
        self.peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        state = .idle
    }

    // MARK: - 指令下发

    /// BLE 通道指令映射（smali 方法 Q 全分支 + 实车验证 2026-11-08）：
    /// - 门锁：params=4=解锁、12=落锁（实车确认）；后备箱 cmd=3 已实车验证
    /// - 天窗/车窗 cmd=2；空调 cmd=0；寻车 cmd=8；充电 cmd=11
    /// - 分窗指令（topLeft 等）与空调制冷/制热不在 BLE 开关里 → 走云端
    private func bleParams(for command: VehicleCommand) -> (cmd: UInt8, params: Int64)? {
        switch command {
        case .doorUnlock:            return (1, 4)
        case .doorLock:              return (1, 12)
        case .trunkUnlock:           return (3, 0x640000000)
        case .trunkLock:             return (3, 0x650000000)
        case .sunroofOpen:           return (2, 0x32000000000)
        case .sunroofClose:          return (2, 0x32800000000)
        case .sunroofVentilate:      return (2, 0x33800000000)
        case .windowOpen:            return (2, 0x64)
        case .windowClose:           return (2, 0x65)
        case .ventOpen:              return (2, 0x67)
        case .ventilateClose:        return (2, 0x65)
        case .airConditionerOpen:    return (0, 1)
        case .airConditionerClose:   return (0, 0)
        case .carSearch:             return (8, 0)
        case .startCharge:           return (11, 401)
        case .stopCharge:            return (11, 0)
        default:                     return nil
        }
    }

    func send(_ command: VehicleCommand, timeout: TimeInterval? = nil) {
        guard state == .ready, let ble = bleParams(for: command) else {
            onCommandResult?(command, false)
            return
        }
        guard let keyID, let key = privateKey, !deviceID.isEmpty else {
            DiagnosticLog.shared.log("NetaTboe", "缺钥匙素材 keyID/\(privateKey != nil ? "有" : "无私钥")，走云端")
            onCommandResult?(command, false)
            return
        }

        pendingCommand = command
        do {
            let body = try TboeProtocol.command(
                cmd: ble.cmd, params: ble.params, tsMs: tsMs, keyID: keyID, privateKey: key)
            sendLinked(body: body, msgId: 2)
            DiagnosticLog.shared.log("NetaTboe", "车控 cmd=\(ble.cmd) params=\(ble.params) \(command)")
        } catch {
            pendingCommand = nil
            DiagnosticLog.shared.log("NetaTboe", "指令构造失败 \(error.localizedDescription)")
            onCommandResult?(command, false)
            return
        }

        let wait = timeout ?? command.timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.pendingCommand == command else { return }
            self.pendingCommand = nil
            self.onCommandResult?(command, false)
        }
    }

    // MARK: - 链路收发

    private func sendLinked(body: Data, msgId: UInt8) {
        guard let peripheral, let characteristic = writeCharacteristic else { return }
        rid += 1
        let maxWrite = peripheral.maximumWriteValueLength(for: .withResponse)
        let chunk = max((maxWrite > 8 ? maxWrite : TboeUUID.preferredMTU - 3) - 8, 16)
        let packets = TboeProtocol.encode(msgId: msgId, rid: rid, body: body, chunkSize: chunk)
        for p in packets {
            peripheral.writeValue(p, for: characteristic, type: .withResponse)
            DiagnosticLog.shared.log("NetaTboeLink", "tx msgId=\(msgId) rid=\(rid) len=\(p.count) body=\(DiagnosticLog.hex(p))")
        }
    }

    private func handleReceived(_ data: Data) {
        onRawFrame?(data)
        DiagnosticLog.shared.log("NetaTboeLink", "rx len=\(data.count) body=\(DiagnosticLog.hex(data))")

        guard let frame = TboeProtocol.decode(data) else {
            DiagnosticLog.shared.log("NetaTboeLink", "rx invalid（头长度校验不过）")
            return
        }

        // 多包重组
        if frame.totalPkts > 1 {
            reassemblyBuffer.append(frame.body)
            reassemblyExpect = frame.totalPkts
            if frame.pktIndex + 1 < frame.totalPkts { return }
            let body = reassemblyBuffer
            reassemblyBuffer = Data()
            reassemblyExpect = 0
            dispatch(body: body, frame: frame)
        } else {
            reassemblyBuffer = Data()
            dispatch(body: frame.body, frame: frame)
        }
    }

    private func dispatch(body: Data, frame: TboeProtocol.LinkFrame) {
        // 车端 msgId 是它自己的序号空间（实测 challenge 的 rx msgId=2），
        // 不能按号分发 —— 按消息结构识别
        dispatchByStructure(body: body, frame: frame)
    }

    /// 按结构分发（比 msgId 更可靠：车端 msgId 是它自己的序号空间）。
    private func dispatchByStructure(body: Data, frame: TboeProtocol.LinkFrame) {
        // 1) connect_result / control_result：{1:{1:status,…}} —— 只在挑战响应后等它
        if sentChallengeResponse, let cr = TboeProtocol.parseConnectResult(body) {
            sentChallengeResponse = false
            handleConnectResult(cr)
            return
        }
        // 2) challenge：{1:{1:ASCII码,2:ts}} —— ready 时车端也可能重新挑战（重握手）
        if let ch = TboeProtocol.parseChallenge(body), ch.code.count == 8,
           state == .awaitingChallenge || state == .ready || state == .connecting {
            handleChallenge(ch.code)
            return
        }
        // 3) ack / 心跳应答：{3:ts}（实测 len=7）
        if let ts = TboeProtocol.parseAck(body), body.count <= 12 {
            lastHeartbeatAck = true
            DiagnosticLog.shared.log("NetaTboeLink", "ack ts=\(ts)")
            if state == .verifyingResponse {
                state = .ready
                startHeartbeat()
            }
            if let pending = pendingCommand, state == .ready {
                pendingCommand = nil
                onCommandResult?(pending, true)
            }
            return
        }
        // 4) 其余帧（车况 delta/snapshot、control_result 等）：记录待逐帧固化。
        //    指令待回执窗口内收到的小帧按 control_result 处理（实测指令后有
        //    control_result 回报；大帧是车况推送，不算）。
        DiagnosticLog.shared.log("NetaTboeLink", "未识别帧 msgId=\(frame.msgId) rid=\(frame.rid) len=\(body.count) body=\(DiagnosticLog.hex(body))")
        if let pending = pendingCommand, state == .ready, body.count <= 40 {
            pendingCommand = nil
            DiagnosticLog.shared.log("NetaTboeLink", "（按 control_result 处理）\(pending) 成功")
            onCommandResult?(pending, true)
        }
    }

    private func handleChallenge(_ code: String) {
        onChallenge?(code)
        guard let keyID, let key = privateKey, !deviceID.isEmpty else {
            state = .failed("缺钥匙素材（keyID/私钥），请先完成数字钥匙同步")
            return
        }
        state = .sendingResponse
        do {
            let body = try TboeProtocol.challengeResponse(
                code: code, tsMs: tsMs, keyID: keyID,
                deviceID: deviceID, model: DeviceInfo.current.deviceModel,
                privateKey: key)
            sentChallengeResponse = true
            sendLinked(body: body, msgId: 0)
        } catch {
            state = .failed("挑战响应构造失败：\(error.localizedDescription)")
        }
    }

    private func handleConnectResult(_ cr: (status: Int64, whiteListVer: Int64, keyVer: Int64)) {
        guard cr.status == 4096 else {
            state = .failed("车端拒绝（status=\(cr.status)）")
            return
        }
        guard let keyID, let key = privateKey else {
            state = .failed("缺钥匙素材，无法确认会话")
            return
        }
        DiagnosticLog.shared.log("NetaTboeLink", "connect_result ok whiteListVer=\(cr.whiteListVer) keyVer=\(cr.keyVer)")
        state = .verifyingResponse
        do {
            let body = try TboeProtocol.sessionConfirm(tsMs: tsMs, keyID: keyID, privateKey: key)
            sendLinked(body: body, msgId: 1)
        } catch {
            state = .failed("会话确认构造失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 心跳

    private func startHeartbeat() {
        stopHeartbeat()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self, self.state == .ready,
                  let keyID = self.keyID, let key = self.privateKey else { return }
            do {
                let body = try TboeProtocol.sessionConfirm(
                    tsMs: self.tsMs, keyID: keyID, privateKey: key)
                self.sendLinked(body: body, msgId: 1)
            } catch {
                DiagnosticLog.shared.log("NetaTboe", "心跳构造失败 \(error.localizedDescription)")
            }
        }
        t.resume()
        heartbeatTimer = t

        // v0.3.15：连接期间每秒读一次 RSSI，喂给距离判定
        // （否则手动指令的距离门控没有新鲜样本）
        let r = DispatchSource.makeTimerSource(queue: .main)
        r.schedule(deadline: .now() + 1, repeating: 1)
        r.setEventHandler { [weak self] in
            guard let self, self.state == .ready, let p = self.peripheral else { return }
            p.readRSSI()
        }
        r.resume()
        rssiPollTimer = r
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        rssiPollTimer?.cancel()
        rssiPollTimer = nil
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
        // v0.3.12：仅空闲/失败时自动连接——广播风暴曾把握手状态踩掉（diag9）
        if let name, name.hasPrefix(TboeUUID.advertisePrefix), isIdleOrFailed {
            DiagnosticLog.shared.log("NetaTboeLink", "扫到车机 name=\(name) rssi=\(RSSI)")
            connect(to: peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connecting
        peripheral.delegate = self
        // 实测车端有 5 个服务，特征按 UUID 匹配 → 全量发现
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
        stopHeartbeat()
        sentChallengeResponse = false
        state = .idle
        writeCharacteristic = nil
        notifyCharacteristic = nil
    }
}

// MARK: - CBPeripheralDelegate

extension TboeTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            state = .failed("发现服务失败：\(error.localizedDescription)")
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
            state = .failed("发现特征失败：\(error.localizedDescription)")
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
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil else {
            state = .failed("订阅通知失败：\(error?.localizedDescription ?? "?")")
            return
        }
        if characteristic.uuid == TboeUUID.notify {
            // 订阅完成，等车端推 challenge（实测连接后 ~1.7s 推送）
            state = .awaitingChallenge
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // 车端每 ~1.5s 推帧：借每次通知读一次 RSSI 喂距离判定。
        // 后台被围栏唤醒时定时器不跑，通知驱动的采样是唯一距离来源。
        peripheral.readRSSI()
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
            DiagnosticLog.shared.log("NetaTboeLink", "写特征失败：\(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil {
            onRSSIUpdate?(RSSI.intValue)
        }
    }
}

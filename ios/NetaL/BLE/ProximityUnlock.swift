import Foundation
import CoreLocation

/// 靠近自动解锁策略。
///
/// 对应 APK 内的数据模型（DEX 明文，已确认）：
/// ```
/// BleProximityMeasurement(averageRssi=..., ...)
/// BleProximityPolicy(enterThresholdDbm=..., ...)
/// NotificationSnapshot(isBluetoothConnected=...)
/// ```
///
/// ⚠️ iOS 平台限制（移植最大障碍）：
/// Android 上 `ProximityUnlockService` 是常驻前台服务 + `BOOT_COMPLETED` 自启，
/// iOS **不存在**这种模型。iOS 17+ 默认禁用 `allowsBackgroundUpdates`，
/// 后台持续 BLE 扫描会被系统挂起。
///
/// 可行替代方案：
///   1. 地理围栏（Geofence）到达车辆位置后启动有限时扫描
///   2. 本地通知 + 用户点击后短时扫描
///   3. 若车机支持 CarPlay 数字钥匙，走系统原生路径
final class ProximityUnlockPolicy: NSObject {

    // MARK: 配置

    struct Policy {
        /// 进入解锁的 RSSI 阈值（dBm，越接近 0 越近）
        var enterThresholdDbm: Int = -55
        /// 退出解锁的 RSSI 阈值（滞后，避免抖动）
        var exitThresholdDbm: Int = -65
        /// 采样窗口时长（秒）
        var sampleWindow: TimeInterval = 5
        /// 采样次数下限（样本不足不下结论，对应文案「距离未知时的后续动作失败」）
        var minSamples: Int = 3
        /// 触发解锁后的冷却时间
        var cooldown: TimeInterval = 30
    }

    // MARK: 状态

    private(set) var policy = Policy()

    /// 用户可调靠近门限（设置页档位 → RSSI 阈值）。RSSI 与真实距离强环境相关，档位为近似值。
    func updateThresholds(enter: Int, exit: Int) {
        policy.enterThresholdDbm = enter
        policy.exitThresholdDbm = exit
        evaluate()
    }

    /// 滑动窗口采样
    private var samples: [Int] = []
    private var lastTriggerAt: Date?

    /// 当前判定结果
    enum Proximity {
        case far          // 距驻车位置超过门限
        case near
        case unknown      // 距离未知（样本不足）

        var displayName: String {
            switch self {
            case .far:     return "较远"
            case .near:    return "已靠近"
            case .unknown: return "距离未知"
            }
        }
    }

    private(set) var proximity: Proximity = .unknown

    /// 当前滑动窗口平均 RSSI（无样本时 0）。手动指令的距离门控使用。
    var currentAverageRssi: Int {
        guard !samples.isEmpty else { return 0 }
        let recent = Array(samples.suffix(Int(policy.sampleWindow * 4)))
        return recent.reduce(0, +) / recent.count
    }

    /// 用户设置的进入阈值（dBm）
    var enterThresholdDbm: Int { policy.enterThresholdDbm }

    /// 距离已明确判定为「较远」——手动 BLE 指令应被门控
    /// （unknown/样本不足不拦，避免刚连上时误伤）
    var isFarBySamples: Bool { proximity == .far }

    /// 触发解锁时回调
    var onUnlock: (() -> Void)?
    /// 状态变化回调（用于 UI 展示）
    var onProximityChange: ((Proximity, Int) -> Void)?

    /// 蓝牙连接状态快照（对应 NotificationSnapshot.isBluetoothConnected）
    var isBluetoothConnected = false {
        didSet { evaluate() }
    }

    // MARK: 输入

    /// 输入一次 RSSI 采样。
    func ingest(rssi: Int) {
        samples.append(rssi)

        // 只保留采样窗口内的样本
        // （Android 侧是滑动平均，Swift 端用等效窗口实现）
        if samples.count > 32 {
            samples.removeFirst(samples.count - 32)
        }

        evaluate()
    }

    // MARK: 判定

    private func evaluate() {
        guard samples.count >= policy.minSamples else {
            update(.unknown, rssi: samples.last ?? 0)
            return
        }

        let recent = Array(samples.suffix(Int(policy.sampleWindow * 4)))
        let average = recent.reduce(0, +) / recent.count

        // 滞回：已靠近时用更低阈值维持，避免边界抖动
        let threshold = (proximity == .near) ? policy.exitThresholdDbm
                                            : policy.enterThresholdDbm
        let result: Proximity = average >= threshold ? .near : .far

        update(result, rssi: average)

        if result == .near {
            triggerUnlockIfNeeded()
        }
    }

    private func update(_ result: Proximity, rssi: Int) {
        DiagnosticLog.shared.log("Proximity", "判定=\(result) rssi=\(rssi) 样本=\(samples.count)")
        guard result != proximity else { return }
        proximity = result
        onProximityChange?(result, rssi)
    }

    private func triggerUnlockIfNeeded() {
        if let last = lastTriggerAt,
           Date().timeIntervalSince(last) < policy.cooldown {
            return
        }

        lastTriggerAt = Date()

        // 原 APK 文案：「此操作将解锁所有车门」「注意人身及车辆安全」
        // iOS 侧建议改为先通知用户确认，而非静默解锁。
        onUnlock?()
    }

    func reset() {
        samples.removeAll()
        proximity = .unknown
        lastTriggerAt = nil
    }
}

// MARK: - 地理围栏（后台解锁的合规通道）

/// 以驻车点为圆心的系统围栏。iOS 不允许后台无差别 BLE 扫描，
/// 但围栏触发可唤醒 App；配合 bluetooth-central 后台模式可重连
/// 已知外设并完成握手，实现「靠近车辆后台自动解锁」。
/// 围栏为系统级持久：杀 App / 重启后仍然生效。
final class GeofenceUnlockCoordinator: NSObject, CLLocationManagerDelegate {

    static let shared = GeofenceUnlockCoordinator()
    static let regionID = "neta-parking"

    /// 围栏半径（米）。iOS 地理围栏最小有效半径约 100m。
    static let fenceRadius: CLLocationDistance = 150

    private let manager = CLLocationManager()
    private var region: CLCircularRegion?

    /// 进入围栏（系统唤醒回调）
    var onEnter: (() -> Void)?
    /// 离开围栏
    var onExit: (() -> Void)?

    override private init() {
        super.init()
        manager.delegate = self
    }

    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    /// 以驻车点立围栏。驻车点变化时重复调用会自动换栏。
    func configure(lat: Double, lng: Double) {
        let r = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            radius: Self.fenceRadius,
            identifier: Self.regionID
        )
        r.notifyOnEntry = true
        r.notifyOnExit = true
        if let old = region { manager.stopMonitoring(for: old) }
        region = r
        manager.startMonitoring(for: r)
        DiagnosticLog.shared.log("Geo", String(format: "围栏已设：%.5f,%.5f r=%.0fm", lat, lng, Self.fenceRadius))
    }

    func stop() {
        if let r = region {
            manager.stopMonitoring(for: r)
            region = nil
            DiagnosticLog.shared.log("Geo", "围栏已移除")
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == Self.regionID else { return }
        DiagnosticLog.shared.log("Geo", "进入围栏 → 唤醒连接车辆")
        onEnter?()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.regionID else { return }
        DiagnosticLog.shared.log("Geo", "离开围栏")
        onExit?()
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        DiagnosticLog.shared.log("Geo", "围栏失败：\(error.localizedDescription)")
    }
}
}
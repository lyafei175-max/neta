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

// MARK: - 地理围栏桥接

/// 用地理围栏替代常驻扫描的可行性验证器。
///
/// iOS 上唯一能在后台感知「接近车辆」的合规方案是地理围栏：
/// 系统在地理围栏触发时唤醒 App，此时做有限时 BLE 扫描即可。
final class GeofenceUnlockCoordinator {

    private let manager = CLLocationManager()

    /// 围栏半径（米）。iOS 地理围栏最小有效半径约 100m。
    static let fenceRadius: CLLocationDistance = 150

    /// 围栏触发后允许的扫描时长
    static let scanDuration: TimeInterval = 30

    var onFenceEntered: (() -> Void)?
    var onFenceExited: (() -> Void)?

    func requestAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    /// 设置以车辆驻车位置为中心的围栏。
    func configureFence(latitude: Double, longitude: Double, identifier: String) {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let region = CLCircularRegion(
            center: center,
            radius: Self.fenceRadius,
            identifier: identifier
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true

        manager.startMonitoring(for: region)

        // 调用方需通过 CLLocationManagerDelegate 接收
        // locationManager(_:didEnterRegion:) / didExitRegion
    }

    static func currentRegionStatus(_ manager: CLLocationManager,
                                    identifier: String) -> CLRegionState {
        manager.monitoredRegions
            .first { $0.identifier == identifier }
            .map { manager.regionState(for: $0) } ?? .unknown
    }
}
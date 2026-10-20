import SwiftUI

@main
struct NetaLApp: App {

    @StateObject private var controller = CarController()

    init() {
        // 原 APK 使用 theme @7F0A000D（Material 主题，Compose）。
        // iOS 端直接用系统默认外观。
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controller)
        }
    }
}

// MARK: - 生命周期

/// 原 APK 的 `ProximityUnlockBootReceiver` 在开机后拉起前台服务。
/// iOS 无「开机自启」概念，只能通过地理围栏或用户主动启动。
///
/// 此处演示在 App 启动时初始化 BLE 与围栏的逻辑：
///
/// ```swift
/// func bootstrap() {
///     TboeTransport.shared.onRawFrame = { data in
///         // 408 字节车况报文
///         controller.handleBleStatus(data)
///     }
///     GeofenceUnlockCoordinator().configureFence(
///         latitude: <驻车纬度>, longitude: <驻车经度>, identifier: "vehicle"
///     )
/// }
/// ```
///
/// 驻车坐标需在车辆绑定后从云端获取（原 APK 有「解析驻车地址」「导航去驻车位置」）。
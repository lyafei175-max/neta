import Foundation
import SwiftUI
import Combine
import CoreLocation

/// 车控协调器：按通道策略在 BLE 与网络之间路由指令。
///
/// 对应 APK 文案（已确认）：
/// - 「蓝牙已连接时优先使用」
/// - 「未连接或下发失败时走网络」
/// - 「已按设置只走蓝牙」
/// - 「该动作仅支持网络通道」
@MainActor
final class CarController: ObservableObject {

    // MARK: 发布状态

    @Published private(set) var state = VehicleState()
    @Published private(set) var channel: ControlChannel = .automatic
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastResult: String?
    @Published var lastRawVehicleData: String?
    /// 驻车地址（CLGeocoder 逆地理，坐标缓存防重复请求）
    @Published private(set) var parkingAddress: String?
    /// BLE 会话状态镜像（v0.3.13）：TboeTransport.state 是普通属性，
    /// SwiftUI 观察不到——不镜像的话首页蓝牙状态永远不刷新
    @Published private(set) var bleSessionState: TboeSessionState = .idle

    // MARK: 依赖

    private let api = NetaAPIClient()
    private let tboe = TboeTransport.shared
    private let proximity = ProximityUnlockPolicy()
    private let geocoder = CLGeocoder()
    private var lastGeocodeKey = ""

    /// 离开自动锁车（v0.3.16）：near→far 后延时 5 秒仍 far 才执行
    private var walkAwayLockTask: DispatchWorkItem?
    /// 自动锁车进行中——onCommandResult 不做网络兜底（远处车端本来就 asleep）
    private var isWalkAwayLocking = false

    /// 靠近解锁档位（RSSI 与真实距离强环境相关，为近似映射）
    struct ProximityRange: Identifiable {
        let label: String
        let meters: Int
        let dbm: Int
        var id: Int { dbm }
    }
    static let proximityRanges: [ProximityRange] = [
        ProximityRange(label: "约 3 米", meters: 3, dbm: -60),
        ProximityRange(label: "约 5 米", meters: 5, dbm: -70),
        ProximityRange(label: "约 8 米", meters: 8, dbm: -80),
    ]

    // MARK: 初始化

    init() {
        // 用户档位持久化（默认 约 3 米 / -60 dBm）
        let savedDbm = UserDefaults.standard.object(forKey: "proximity_dbm") as? Int ?? -60
        proximity.updateThresholds(enter: savedDbm, exit: savedDbm - 10)

        // v0.3.14：前台自动扫描循环——靠近车自动连接，无需手动进钥匙页扫描
        tboe.setAutoScan(true)

        proximity.onUnlock = { [weak self] in
            Task { await self?.performUnlock() }
        }

        tboe.onVehicleState = { [weak self] newState in
            Task { @MainActor in self?.state = newState }
        }

        tboe.onCommandResult = { [weak self] command, success in
            Task { @MainActor in
                // 离开自动锁车：不做网络兜底（用户已离开，车端 TBOX 多半休眠）
                if self?.isWalkAwayLocking == true, command == .doorLock {
                    self?.isWalkAwayLocking = false
                    self?.lastResult = success ? "离开自动锁车 成功" : "离开自动锁车 未获车端回执"
                    return
                }
                if success {
                    self?.lastResult = "\(command.displayName) 成功"
                } else {
                    // 近场失败 → 自动通道回退网络（原文案：未连接或下发失败时走网络）
                    if self?.channel == .automatic, command.supportsNearField {
                        self?.lastResult = "\(command.displayName) 蓝牙未回执，转网络下发…"
                        await self?.sendViaNetwork(command)
                        return
                    }
                    self?.lastError = "\(command.displayName) 车端未回执执行结果"
                }
            }
        }

        // 离开自动锁车（v0.3.16）：靠近判定 near→far（滞回，约比触发档远 3~4 米）
        // 持续 5 秒仍 far 且蓝牙在线 → BLE 锁车
        // （v0.3.19 重写：显式 controller 命名，避免 guard let self 双重遮蔽的编译歧义）
        proximity.onProximityChange = { [weak self] p, _ in
            Task { @MainActor in
                guard let controller = self else { return }
                switch p {
                case .near:
                    controller.walkAwayLockTask?.cancel()
                    controller.walkAwayLockTask = nil
                case .far:
                    guard controller.bleSessionState.isUsable,
                          UserDefaults.standard.object(forKey: "walkaway_lock") as? Bool ?? true
                    else { return }
                    controller.walkAwayLockTask?.cancel()
                    let work = DispatchWorkItem { [weak controller] in
                        Task { @MainActor in
                            controller?.performWalkAwayLockIfNeeded()
                        }
                    }
                    controller.walkAwayLockTask = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
                case .unknown:
                    break
                }
            }
        }

        // 靠近解锁数据源补线：RSSI 采样 + 会话就绪状态（v0.3.2）
        tboe.onRSSIUpdate = { [weak self] rssi in
            Task { @MainActor in self?.proximity.ingest(rssi: rssi) }
        }
        tboe.onStateChange = { [weak self] s in
            Task { @MainActor in
                self?.bleSessionState = s
                self?.proximity.isBluetoothConnected = s.isUsable
            }
        }
    }

    /// 设置页调用：更新靠近解锁阈值并持久化
    func setProximityThreshold(_ dbm: Int) {
        proximity.updateThresholds(enter: dbm, exit: dbm - 10)
        UserDefaults.standard.set(dbm, forKey: "proximity_dbm")
    }

    var proximityThresholdDbm: Int {
        UserDefaults.standard.object(forKey: "proximity_dbm") as? Int ?? -60
    }

    // MARK: 通道

    func setChannel(_ newChannel: ControlChannel) {
        channel = newChannel
    }

    /// 当前可用的近场通道（对应 `NotificationSnapshot.isBluetoothConnected`）
    /// v0.3.13：改读 @Published 镜像，保证状态变化能驱动 UI 刷新
    var nearFieldAvailable: Bool {
        bleSessionState.isUsable
    }

    // MARK: 指令下发

    /// 下发一条车控指令。
    func send(_ command: VehicleCommand) async {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        // 该动作没有近场命令 → 只能走网络
        guard command.supportsNearField || channel != .bluetoothOnly else {
            await sendViaNetwork(command)
            return
        }

        switch channel {
        case .automatic:
            if nearFieldAvailable {
                // 手动指令 = 用户明确意图，蓝牙在线直接走 BLE。
                // v0.3.15 的距离门控撤除：RSSI 受人体遮挡影响可达 -80s（站车旁），
                // 硬门控会出现「在车旁也解不了锁」。距离语义只用于
                // 自动解锁/离开锁车（无人值守动作，阈值可调档）。
                sendViaBluetooth(command)
            } else {
                await sendViaNetwork(command)
            }

        case .bluetoothOnly:
            guard command.supportsNearField else {
                lastError = "该动作仅支持网络通道"
                return
            }
            sendViaBluetooth(command)

        case .networkOnly:
            await sendViaNetwork(command)
        }
    }

    private var lastResultIsSuccess: Bool {
        lastResult?.hasSuffix("成功") == true
    }

    private func sendViaBluetooth(_ command: VehicleCommand) {
        guard TboeTransport.shared.state.isUsable else {
            lastError = "尚未连接到车辆蓝牙"
            return
        }
        TboeTransport.shared.send(command)
        lastResult = "正在下发 \(command.displayName)"
    }

    private func sendViaNetwork(_ command: VehicleCommand) async {
        do {
            _ = try await api.sendCommand(command)
            lastResult = "\(command.displayName) 已提交"
            DiagnosticLog.shared.log("NetaCar", "\(command.displayName) 已提交（网络）")
        } catch {
            let raw = error.localizedDescription
            // 42500「云服务异常」实测 = 车端 TBOX 休眠离线，云端指令到不了车
            // （车醒着时同一请求成功过）。给人话提示，不再甩三种格式的原始报错。
            if raw.contains("42500") || raw.contains("云服务异常") {
                lastError = "\(command.displayName)：车辆当前离线（可能休眠），远程指令无法送达。请走近车辆用蓝牙，或车辆唤醒后（行驶/开过门）再试。"
                DiagnosticLog.shared.log("NetaCar", "\(command.displayName) 失败 42500（车端离线）")
            } else {
                lastError = raw
                DiagnosticLog.shared.log("NetaCar", "\(command.displayName) 失败 \(raw.prefix(200))")
            }
        }
    }

    // MARK: 靠近解锁

    private func performUnlock() async {
        await send(.doorUnlock)
    }

    /// 离开自动锁车：直走 BLE（距离门控对它豁免——它本来就由「已离开」触发）
    private func performWalkAwayLockIfNeeded() {
        guard bleSessionState.isUsable, proximity.isFarBySamples else { return }
        performWalkAwayLock()
    }

    private func performWalkAwayLock() {
        guard !isBusy else { return }
        isWalkAwayLocking = true
        DiagnosticLog.shared.log("NetaCar", "已离开车辆，自动锁车")
        lastResult = "已离开，自动锁车…"
        tboe.send(.doorLock)
    }

    // MARK: 车况

    func refreshState() async {
        do {
            state = try await api.fetchVehicleState()
            lastRawVehicleData = NetaAPIClient.lastRawVehicleSnapshot
            lastError = nil
            resolveParkingAddress()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 驻车坐标 → 地址。与安卓 ParkingGeocoder 同策略：
    /// 配置了高德 key → restapi.amap.com regeo（街道级）；否则系统逆地理（省市级）。
    private func resolveParkingAddress() {
        guard let lat = state.latitude, let lng = state.longitude,
              lat != 0, lng != 0 else { return }
        let key = String(format: "%.3f,%.3f", lat, lng)
        guard key != lastGeocodeKey else { return }
        lastGeocodeKey = key

        let amapKey = UserDefaults.standard.string(forKey: "amap_key") ?? ""
        if !amapKey.isEmpty {
            amapRegeo(key: amapKey, lat: lat, lng: lng) { [weak self] addr in
                Task { @MainActor in
                    if let addr, !addr.isEmpty {
                        self?.parkingAddress = addr
                    } else {
                        // 高德失败 → 系统逆地理兜底
                        self?.systemRegeo(lat: lat, lng: lng)
                    }
                }
            }
        } else {
            systemRegeo(lat: lat, lng: lng)
        }
    }

    /// 高德逆地理（GET，与安卓同端点同参数）
    private func amapRegeo(key: String, lat: Double, lng: Double,
                           completion: @escaping (String?) -> Void) {
        let loc = String(format: "%.6f,%.6f", lng, lat)
        var comps = URLComponents(string: "https://restapi.amap.com/v3/geocode/regeo")!
        comps.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "location", value: loc),
            URLQueryItem(name: "extensions", value: "base"),
            URLQueryItem(name: "output", value: "JSON"),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("neta-l-control", forHTTPHeaderField: "User-Agent")
        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["status"] as? String) == "1",
                      let regeocode = obj["regeocode"] as? [String: Any],
                      let addr = regeocode["formatted_address"] as? String,
                      !addr.isEmpty else {
                    completion(nil)
                    return
                }
                completion(addr)
            } catch {
                completion(nil)
            }
        }
    }

    /// 系统逆地理（省市区县路号全带）。
    /// Apple 地图在国内农村区域常只有省市区三级（无街道字段）——
    /// 拿不到街道时再试 OSM 逆地理补细节，仍不行则附坐标兜底。
    private func systemRegeo(lat: Double, lng: Double) {
        geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lng)) { [weak self] placemarks, _ in
            var appleAddr: String?
            var hasStreet = false
            if let pm = placemarks?.first {
                var parts: [String] = []
                if let d = pm.administrativeArea { parts.append(d) }
                if let c = pm.locality { parts.append(c) }
                if let s = pm.subLocality, !parts.contains(s) { parts.append(s) }
                if let t = pm.thoroughfare { parts.append(t); hasStreet = true }
                if let n = pm.subThoroughfare { parts.append(n) }
                var addr = parts.joined(separator: "")
                if let nm = pm.name, nm.count > addr.count { addr = nm }
                appleAddr = addr
            }
            Task { @MainActor in
                if let a = appleAddr, hasStreet {
                    self?.parkingAddress = a
                } else {
                    // Apple 数据粗（乡镇级）→ OSM 兜底补街道，仍粗则附坐标
                    self?.osmRegeo(lat: lat, lng: lng, fallback: appleAddr)
                }
            }
        }
    }

    /// OSM Nominatim 逆地理（免 key，尽力而为；不可达时回退 Apple 结果+坐标）
    private func osmRegeo(lat: Double, lng: Double, fallback: String?) {
        var comps = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        comps.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lng)),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "accept-language", value: "zh-CN"),
            URLQueryItem(name: "zoom", value: "18"),
        ]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 6
        req.setValue("neta-l-control/1.0", forHTTPHeaderField: "User-Agent")
        Task { [weak self] in
            var detailed: String?
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = obj["display_name"] as? String {
                // display_name 顺序小→大："路名, 乡镇, 杞县, 开封市, 河南省, 中国"
                // 取前 3 段倒序拼接成中文阅读顺序（县+乡+路）
                let parts = name.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if parts.count >= 3 {
                    detailed = parts.prefix(3).reversed().joined()
                }
            }
            let base = (detailed?.count ?? 0) > (fallback?.count ?? 0) ? detailed : fallback
            let out: String
            if let b = base, b.count >= 12 {
                out = b
            } else {
                out = String(format: "%@ (%.5f, %.5f)", base ?? "未知位置", lat, lng)
            }
            await MainActor.run { self?.parkingAddress = out }
        }
    }

    /// 处理 BLE 推送的 408 字节车况报文。
    func handleBleStatus(_ data: Data) {
        do {
            let parsed = try VehicleStatusParser().parse(data)
            Task { @MainActor in self.state = parsed }
        } catch {
            Task { @MainActor in self.lastError = "车况解析失败" }
        }
    }
}

// MARK: - 界面

/// 应用根视图。
///
/// 登录门禁：未登录时展示 `LoginView`，登录后才进入车控主界面。
/// 对应原 APK 文案「登录后才能下发车控指令」「登录后管理车辆与车控」。
struct RootView: View {

    @State private var isAuthenticated: Bool?
    @State private var isChecking = true

    var body: some View {
        Group {
            if isChecking {
                // 检查本地会话中
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在检查登录状态")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if isAuthenticated == true {
                ContentView()
            } else {
                LoginView {
                    // 登录成功回调
                    isAuthenticated = true
                }
            }
        }
        .task {
            await checkSession()
        }
    }

    private func checkSession() async {
        let auth = AuthService.shared
        // 只要 Keychain 里有 accessToken + refreshToken 就直接进主界面，
        // 不启动时强制刷新（refresh 接口参数名未校准，强制校验会误登出）。
        // 真正请求 401 时由 NetaAPIClient 自动刷新重试。
        isAuthenticated = await auth.isAuthenticated
        isChecking = false
    }
}

struct ContentView: View {
    @StateObject private var controller = CarController()
    @State private var showSettings = false
    @State private var showLogin = false
    @State private var showRawData = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {

                    statusHeroCard

                    if let error = controller.lastError {
                        errorBanner(error)
                    }

                    if let result = controller.lastResult {
                        resultLine(result)
                    }

                    if hasTireData {
                        tireCard
                    }

                    energyCard

                    groupCard(title: "车锁与寻车", icon: "lock.fill", accent: .blue) {
                        commandButton(.doorUnlock, icon: "lock.open", accent: .blue)
                        commandButton(.doorLock, icon: "lock", accent: .blue)
                        commandButton(.carSearch, icon: "magnifyingglass", accent: .blue)
                        commandButton(.trunkUnlock, icon: "car.rear.open", accent: .blue)
            commandButton(.trunkLock, icon: "car.rear", accent: .blue)
                    }

                    groupCard(title: "空调与温度", icon: "wind", accent: .teal) {
                        commandButton(.airConditionerOpen, icon: "fan", accent: .teal)
                        commandButton(.airConditionerClose, icon: "fan.fill", accent: .teal)
                        commandButton(.airConditionerRefrigeration, icon: "snowflake", accent: .cyan)
                        commandButton(.airConditionerHeating, icon: "flame", accent: .orange)
                    }

                    groupCard(title: "车窗", icon: "rectangle.split.2x1", accent: .indigo) {
                        commandButton(.windowOpen, icon: "arrow.up.square", accent: .indigo)
                        commandButton(.windowClose, icon: "arrow.down.square", accent: .indigo)
                        commandButton(.topLeftWindowOpen, icon: "arrow.up.left.square", accent: .indigo)
                        commandButton(.topLeftWindowClose, icon: "arrow.down.left.square", accent: .indigo)
                    }

                    groupCard(title: "充电与电池", icon: "bolt.fill", accent: .green) {
                        commandButton(.startCharge, icon: "bolt.fill", accent: .green)
                        commandButton(.stopCharge, icon: "bolt.slash", accent: .green)
                    }

                    groupCard(title: "电源", icon: "power", accent: .orange) {
                        commandButton(.powerOn, icon: "power", accent: .orange)
                        commandButton(.powerOff, icon: "poweroff", accent: .orange)
                    }

                    debugCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("哪吒车控")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showLogin = true
                    } label: {
                        Label("账户", systemImage: "person.crop.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }
            }
            .refreshable { await controller.refreshState() }
            .task { await controller.refreshState() }
            .sheet(isPresented: $showSettings) {
                SettingsView(controller: controller)
            }
            .sheet(isPresented: $showLogin) {
                AccountView()
            }
        }
    }

    // MARK: 主状态卡（渐变 + 大电量）

    private var socText: String {
        controller.state.batterySOC.map { "\(Int($0))" } ?? "--"
    }

    private var batteryIcon: String {
        guard let soc = controller.state.batterySOC else { return "battery.0percent" }
        switch soc {
        case 90...: return "battery.100"
        case 70..<90: return "battery.75"
        case 40..<70: return "battery.50"
        case 15..<40: return "battery.25"
        default: return "battery.0percent"
        }
    }

    private var mileageText: String {
        controller.state.totalMileage.map { "\(Int($0)) km" } ?? "--"
    }

    private var tempText: String {
        controller.state.outdoorTemperature.map { String(format: "%.1f℃", $0) } ?? "--"
    }

    private var lockText: String {
        controller.state.doorsLock.rawValue
    }

    private var electricRangeText: String {
        controller.state.availableMileage.map { "\(Int($0)) km" } ?? "--"
    }

    private var fuelRangeText: String {
        controller.state.fuelRangeKm.map { "\(Int($0)) km" } ?? "--"
    }

    private var statusHeroCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(
                    controller.nearFieldAvailable ? "蓝牙已连接" : "未连接 · 走网络通道",
                    systemImage: controller.nearFieldAvailable ? "dot.radiowaves.left.and.right" : "wifi"
                )
                .font(.caption)

                Spacer()

                Text(controller.channel.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.22))
                    .clipShape(Capsule())
            }

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(socText)
                            .font(.system(size: 54, weight: .bold, design: .rounded))
                        Text("%")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                    }
                    Text("动力电池 SOC")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                Image(systemName: batteryIcon)
                    .font(.system(size: 44, weight: .light))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                heroChip(value: mileageText, label: "总里程")
                heroChip(value: electricRangeText, label: "纯电续航")
                heroChip(value: fuelRangeText, label: "油续航")
                heroChip(value: tempText, label: "车外温度")
                heroChip(value: lockText, label: "门锁")
            }

            if let addr = controller.parkingAddress {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.caption2)
                    Text("驻车：\(addr)")
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [Color.blue, Color.teal],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(color: Color.blue.opacity(0.25), radius: 8, y: 4)
    }

    private func heroChip(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.white.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 胎压卡（换算公式来自官方 APK J1/j0.1.smali）

    private var hasTireData: Bool {
        [controller.state.frontLeftTire,
         controller.state.frontRightTire,
         controller.state.rearLeftTire,
         controller.state.rearRightTire]
            .contains { $0.pressure != nil }
    }

    private var tireCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("胎压监测", systemImage: "speedometer")
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 14) {
                    TireGaugeView(name: "左前",
                                  pressure: controller.state.frontLeftTire.pressure,
                                  temperature: controller.state.frontLeftTire.temperature)
                    TireGaugeView(name: "左后",
                                  pressure: controller.state.rearLeftTire.pressure,
                                  temperature: controller.state.rearLeftTire.temperature)
                }
                VStack {
                    Spacer(minLength: 10)
                    // 双通道加载：先按名（asset/bundle），失败直读文件路径；
                    // 都失败退回 SF 图标，保证中间列一定有车
                    if let ui = CarTopImage.load() {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 170)
                            .accessibilityLabel("车辆俯视图")
                    } else {
                        Image(systemName: "car.side.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Color(.systemGray3))
                            .frame(height: 170)
                    }
                    Spacer(minLength: 10)
                }
                .frame(maxHeight: .infinity)
                VStack(spacing: 14) {
                    TireGaugeView(name: "右前",
                                  pressure: controller.state.frontRightTire.pressure,
                                  temperature: controller.state.frontRightTire.temperature)
                    TireGaugeView(name: "右后",
                                  pressure: controller.state.rearRightTire.pressure,
                                  temperature: controller.state.rearRightTire.temperature)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: 能源卡（电量 + 油量，增程版）

    private var energyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("能源状态", systemImage: "bolt.fill")
                .font(.subheadline.weight(.semibold))

            if controller.state.batterySOC != nil || controller.state.fuelPercent != nil {
                EnergyRowView(icon: "bolt.fill", color: .blue, label: "电量",
                              percent: controller.state.batterySOC,
                              note: controller.state.availableMileage.map { String(format: "纯电续航 %.0f km", $0) })
                EnergyRowView(icon: "fuelpump.fill", color: .orange, label: "油量",
                              percent: controller.state.fuelPercent,
                              note: controller.state.fuelRangeKm.map { String(format: "油续航 %.0f km", $0) })
            } else {
                Text("暂无能源数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: 结果 / 错误 / 调试

    private func resultLine(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.green.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var debugCard: some View {
        DisclosureGroup("调试数据", isExpanded: $showRawData) {
            VStack(alignment: .leading, spacing: 8) {
                if let raw = controller.lastRawVehicleData, !raw.isEmpty {
                    Text(raw)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("暂无")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
        .font(.subheadline)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(message).font(.caption)
            Spacer()
        }
        .padding(10)
        .foregroundStyle(.red)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func groupCard<Content: View>(
        title: String,
        icon: String,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(accent)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func commandButton(_ command: VehicleCommand, icon: String, accent: Color) -> some View {
        Button {
            Task { await controller.send(command) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.callout)
                Text(command.displayName)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
        .background(accent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .disabled(controller.isBusy)
        .opacity(controller.isBusy ? 0.55 : 1)
    }
}

/// 车辆俯视图加载：named（asset/bundle）→ 文件路径直读 → nil（调用方退回 SF 图标）
enum CarTopImage {
    static func load() -> UIImage? {
        if let ui = UIImage(named: "car_topview") { return ui }
        if let p = Bundle.main.path(forResource: "car_topview", ofType: "png"),
           let ui = UIImage(contentsOfFile: p) {
            return ui
        }
        return nil
    }
}

// MARK: - 账户页

/// 工具栏左上角入口。查看登录状态、退出登录。
struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoggedIn = false
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("账户") {
                    if isLoggedIn {
                        LabeledContent("状态", value: "已登录")
                        Button("退出登录", role: .destructive) {
                            Task {
                                await AuthService.shared.logout()
                                isLoggedIn = false
                                status = "已退出登录"
                            }
                        }
                    } else {
                        LabeledContent("状态", value: "未登录")
                        Text("登录后才能下发车控指令")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !status.isEmpty {
                    Section {
                        Text(status).font(.caption)
                    }
                }
            }
            .navigationTitle("账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                isLoggedIn = await AuthService.shared.isAuthenticated
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: CarController
    @Environment(\.dismiss) private var dismiss
    @State private var showKeyManager = false
    @State private var amapKey = UserDefaults.standard.string(forKey: "amap_key") ?? ""
    @AppStorage("walkaway_lock") private var walkawayLock = true

    var body: some View {
        NavigationStack {
            Form {
                Section("车控通道") {
                    Picker("通道", selection: Binding(
                        get: { controller.channel },
                        set: { controller.setChannel($0) }
                    )) {
                        ForEach(ControlChannel.allCases, id: \.self) { ch in
                            Text(ch.displayName).tag(ch)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("自动：蓝牙已连接时优先使用，未连接或下发失败时走网络")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("靠近解锁 / 离开锁车（蓝牙）") {
                    Picker("解锁触发距离", selection: Binding(
                        get: { controller.proximityThresholdDbm },
                        set: { controller.setProximityThreshold($0) }
                    )) {
                        ForEach(CarController.proximityRanges) { r in
                            Text(r.label).tag(r.dbm)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("离开自动锁车", isOn: $walkawayLock)

                    Text("蓝牙会话就绪后，RSSI 持续高于阈值（滑动窗口采样）且处于冷却期之外时自动解锁；离开（低于退出阈值，约为触发档再远 3~4 米）持续 5 秒后自动锁车。RSSI 与实际距离受环境影响，档位为近似值；iOS 后台无法常驻扫描，常驻感知需配合地理围栏。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("驻车地址") {
                    TextField("高德 Web 服务 key（可选）", text: $amapKey)
                        .font(.footnote)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("配置高德 Web 服务 key 后，驻车地址显示街道级（与安卓一致）；未配置时使用系统逆地理（省市级）。key 在高德开放平台创建「Web 服务」类型应用获得。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("协议") {
                    LabeledContent("服务端", value: "chehezhi.cn:18443")
                    LabeledContent("云端协议", value: "已对齐官方 6.4.2")
                    LabeledContent("BLE 状态", value: bleStateText)
                }

                Section("工具") {
                    Button {
                        showKeyManager = true
                    } label: {
                        Label("数字钥匙与蓝牙", systemImage: "key.fill")
                    }
                    BleCaptureEntry()
                }

                Section("诊断") {
                    LabeledContent("日志大小", value: DiagnosticLog.shared.sizeText)
                    ShareLink(item: DiagnosticLog.shared.fileURL) {
                        Label("导出诊断日志", systemImage: "square.and.arrow.up")
                    }
                    Button("清空日志", role: .destructive) {
                        DiagnosticLog.shared.clear()
                    }
                    Text("记录云端请求、蓝牙原始帧与靠近判定。文件含 VIN 与钥匙材料，请只发给自己或可信的分析者。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("车况报文偏移、TBOE 帧格式、签名算法均需通过抓包补全，详见随附的协议规格文档。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showKeyManager) {
                KeyManagerView()
            }
            .onChange(of: amapKey) { newValue in
                UserDefaults.standard.set(newValue, forKey: "amap_key")
            }
        }
    }

    private var bleStateText: String {
        // 设置页打开时的快照显示（实时刷新由首页的 bleSessionState 镜像负责）
        switch TboeTransport.shared.state {
        case .ready: return "已连接"
        case .idle: return "未连接"
        case .connecting, .awaitingChallenge, .sendingResponse,
             .verifyingResponse:
            return "握手中"
        case .failed: return "异常"
        }
    }
}

/// 能源条目：图标 + 标签 + 渐变进度条（进场填充动画）+ 百分比/备注。
struct EnergyRowView: View {

    let icon: String
    let color: Color
    let label: String
    let percent: Double?
    let note: String?

    @State private var progress: CGFloat = 0

    private var percentText: String {
        percent.map { "\(Int($0))%" } ?? "--"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                if let note, !note.isEmpty {
                    // 剩余续航等补充信息（v0.3.7 之前算了没画出来）
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray5))
                    Capsule()
                        .fill(
                            LinearGradient(colors: [color.opacity(0.65), color],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(0, geo.size.width * progress))
                        .shadow(color: color.opacity(0.35), radius: 3)
                }
            }
            .frame(height: 12)

            Text(percentText)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
        .onAppear(perform: animateIn)
        .onChange(of: percent) { _ in animateIn() }
    }

    private func animateIn() {
        progress = 0
        withAnimation(.easeOut(duration: 1.1)) {
            progress = CGFloat((percent ?? 0) / 100.0)
        }
    }
}
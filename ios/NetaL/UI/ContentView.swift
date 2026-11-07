import Foundation
import SwiftUI
import Combine

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

    // MARK: 依赖

    private let api = NetaAPIClient()
    private let tboe = TboeTransport.shared
    private let proximity = ProximityUnlockPolicy()

    // MARK: 初始化

    init() {
        proximity.isBluetoothConnected = false

        proximity.onUnlock = { [weak self] in
            Task { await self?.performUnlock() }
        }

        tboe.onVehicleState = { [weak self] newState in
            Task { @MainActor in self?.state = newState }
        }

        tboe.onCommandResult = { [weak self] command, success in
            Task { @MainActor in
                self?.lastResult = success
                    ? "\(command.displayName) 成功"
                    : "\(command.displayName) 车端未回报执行结果"
            }
        }
    }

    // MARK: 通道

    func setChannel(_ newChannel: ControlChannel) {
        channel = newChannel
    }

    /// 当前可用的近场通道（对应 `NotificationSnapshot.isBluetoothConnected`）
    var nearFieldAvailable: Bool {
        TboeTransport.shared.state.isUsable
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
                sendViaBluetooth(command)
                // 若近场下发失败，回退网络
                if channel == .automatic && !lastResultIsSuccess {
                    await sendViaNetwork(command)
                }
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
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: 靠近解锁

    private func performUnlock() async {
        await send(.doorUnlock)
    }

    // MARK: 车况

    func refreshState() async {
        do {
            state = try await api.fetchVehicleState()
            lastRawVehicleData = NetaAPIClient.lastRawVehicleSnapshot
            lastError = nil
        } catch {
            lastError = error.localizedDescription
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

                    groupCard(title: "车锁与寻车", icon: "lock.fill", accent: .blue) {
                        commandButton(.doorUnlock, icon: "lock.open", accent: .blue)
                        commandButton(.doorLock, icon: "lock", accent: .blue)
                        commandButton(.carSearch, icon: "magnifyingglass", accent: .blue)
                        commandButton(.trunkUnlock, icon: "car.rear.open", accent: .blue)
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

            HStack(spacing: 8) {
                heroChip(value: mileageText, label: "总里程")
                heroChip(value: tempText, label: "车外温度")
                heroChip(value: lockText, label: "门锁")
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
                    Spacer(minLength: 20)
                    Image(systemName: "car.side.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color(.systemGray3))
                    Spacer(minLength: 20)
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

                Section("协议") {
                    LabeledContent("服务端", value: "chehezhi.cn:18443")
                    LabeledContent("云端协议", value: "已对齐官方 6.4.2")
                    LabeledContent("BLE 状态", value: bleStateText)
                }

                Section("工具") {
                    BleCaptureEntry()
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
        }
    }

    private var bleStateText: String {
        switch TboeTransport.shared.state {
        case .ready: return "已连接"
        case .idle: return "未连接"
        case .connecting, .awaitingChallenge, .sendingResponse,
             .verifyingResponse, .syncingWhitelist:
            return "握手中"
        case .failed: return "异常"
        }
    }
}
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    statusCard

                    if let error = controller.lastError {
                        errorBanner(error)
                    }

                    groupCard(title: "车锁与寻车") {
                        commandButton(.doorUnlock, icon: "lock.open")
                        commandButton(.doorLock, icon: "lock")
                        commandButton(.carSearch, icon: "magnifyingglass")
                        commandButton(.trunkUnlock, icon: "car.rear.open")
                    }

                    groupCard(title: "空调与温度") {
                        commandButton(.airConditionerOpen, icon: "fan")
                        commandButton(.airConditionerClose, icon: "fan.fill")
                        commandButton(.airConditionerRefrigeration, icon: "snowflake")
                        commandButton(.airConditionerHeating, icon: "flame")
                    }

                    groupCard(title: "车窗") {
                        commandButton(.windowOpen, icon: "arrow.up.square")
                        commandButton(.windowClose, icon: "arrow.down.square")
                        commandButton(.topLeftWindowOpen, icon: "rectangle.split.2x1")
                        commandButton(.topLeftWindowClose, icon: "rectangle.split.2x1.fill")
                    }

                    groupCard(title: "充电与电池") {
                        commandButton(.startCharge, icon: "bolt.fill")
                        commandButton(.stopCharge, icon: "bolt.slash")
                    }

                    groupCard(title: "电源") {
                        commandButton(.powerOn, icon: "power")
                        commandButton(.powerOff, icon: "poweroff")
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("哪吒L")
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
            .sheet(isPresented: $showSettings) {
                SettingsView(controller: controller)
            }
            .sheet(isPresented: $showLogin) {
                AccountView()
            }
        }
    }

    // MARK: 子视图

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    controller.nearFieldAvailable ? "蓝牙已连接" : "未连接或下发失败时走网络",
                    systemImage: controller.nearFieldAvailable ? "dot.radiowaves.left.and.right" : "icloud.slash"
                )
                .font(.caption)
                .foregroundStyle(controller.nearFieldAvailable ? .green : .secondary)

                Spacer()

                Text(controller.channel.displayName)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }

            Divider()

            // 只列当前数据源已给出取值的信号
            if let soc = controller.state.batterySOC {
                statusRow("电量", "\(Int(soc))%")
            }
            if let temp = controller.state.outdoorTemperature {
                statusRow("车外温度", "\(String(format: "%.1f", temp))℃")
            }
            if let mileage = controller.state.totalMileage {
                statusRow("总行驶里程", "\(Int(mileage)) km")
            }
            if controller.state.doorsLock != .unknown {
                statusRow("门锁", controller.state.doorsLock.rawValue)
            }
            if controller.state.driverSeatHeating != .unknown {
                statusRow("主驾加热", controller.state.driverSeatHeating.rawValue)
            }

            if controller.state.isEmpty {
                Text("当前数据源没有可显示的其余车辆状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let raw = controller.lastRawVehicleData, !raw.isEmpty {
                Divider()
                Text("原始返回: " + raw)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let result = controller.lastResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.weight(.medium))
        }
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
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.medium))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                content()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func commandButton(_ command: VehicleCommand, icon: String) -> some View {
        Button {
            Task { await controller.send(command) }
        } label: {
            Label(command.displayName, systemImage: icon)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .disabled(controller.isBusy)
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
                    LabeledContent("签名状态", value: "待抓包校验")
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
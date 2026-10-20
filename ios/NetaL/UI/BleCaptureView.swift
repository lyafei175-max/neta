import SwiftUI

/// BLE 抓包界面。
///
/// 这是**协议逆向工具**，不是车控界面。必须真机运行（模拟器无 BLE）。
///
/// 录制流程：
/// 1. 点「开始录制」→ 「扫描」找到车机设备
/// 2. 点设备名连接，等待自动订阅 fff1/fff2
/// 3. 用原 APK 或本 App 下发指令（开后备箱、寻车等）
/// 4. 点「停止」导出 JSON
/// 5. 电脑上运行 `python analyze_tboe.py <导出文件>`
struct BleCaptureView: View {

    @StateObject private var model = CaptureModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // 状态栏
                statusBar

                Divider()

                if model.isRecording {
                    controlPanel
                } else {
                    deviceList
                }

                Divider()

                // 帧日志
                frameLog
            }
            .navigationTitle("BLE 抓包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(model.isRecording ? "停止录制" : "开始录制") {
                        model.toggleRecording()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isRecording, let url = model.exportedURL {
                        ShareLink(item: url) {
                            Label("导出", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    // MARK: 状态栏

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.statusColor)
                .frame(width: 8, height: 8)
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("帧 \(model.frames.count)")
                .font(.caption.monospacedDigit())
            if model.isRecording, let start = model.startTime {
                Text(timerInterval: start...Date(), countsDown: false)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: 设备列表

    private var deviceList: some View {
        VStack(spacing: 0) {
            if model.devices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("未发现设备")
                        .font(.headline)
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.devices, id: \.id) { device in
                    Button {
                        model.connect(to: device.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name).font(.subheadline)
                                Text(device.id.uuidString)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(device.rssi) dBm")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(rssiColor(device.rssi))
                        }
                    }
                }
            }
        }
        .frame(height: 240)
    }

    private func rssiColor(_ rssi: Int) -> Color {
        switch rssi {
        case (-50)...:
            return .green
        case (-70)...(-51):
            return .orange
        default:
            return .red
        }
    }

    // MARK: 控制面板

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.isConnected {
                HStack {
                    ProgressView()
                    Text("正在连接并订阅特征…").font(.caption)
                }
            } else {
                Text("已连接 \(model.peerName ?? "设备")")
                    .font(.caption.weight(.medium))

                // 手工发送探测帧
                HStack {
                    TextField("输入 HEX，如 AA AA 00 06 01", text: $model.hexInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("发送") { model.sendRaw(model.hexInput) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                HStack {
                    Toggle("发主特征 fff1", isOn: $model.usePrimary)
                        .font(.caption)
                    if let mtu = model.mtu {
                        Text("MTU \(mtu)").font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .padding()
        .frame(height: 120, alignment: .top)
    }

    // MARK: 帧日志

    private var frameLog: some View {
        ScrollViewReader { proxy in
            List(model.frames) { frame in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(frame.direction.rawValue)
                            .font(.caption2.bold())
                            .foregroundStyle(frame.direction == .tx ? .blue : .green)
                        Text(frame.relativeTime, format: .number.precision(.fractionLength(3)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(frame.payload.count)B")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(shortUUID(frame.characteristic))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(frame.hex)
                        .font(.caption2.monospaced())
                        .lineLimit(2)
                    if !frame.asciiPreview.hasPrefix("...") {
                        Text(frame.asciiPreview)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
                .id(frame.id)
            }
            .listStyle(.plain)
            .onChange(of: model.frames.count) { _ in
                if let last = model.frames.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func shortUUID(_ uuid: String) -> String {
        if uuid.hasPrefix(UUID_PRIMARY_PREFIX) { return "fff1" }
        if uuid.hasPrefix(UUID_SECONDARY_PREFIX) { return "fff2" }
        return String(uuid.prefix(8))
    }
}

// MARK: - 视图模型

@MainActor
final class CaptureModel: ObservableObject {

    @Published var devices: [DiscoveredDevice] = []
    @Published var frames: [DisplayFrame] = []
    @Published var statusText = "准备就绪"
    @Published var isRecording = false
    @Published var isConnected = false
    @Published var peerName: String?
    @Published var startTime: Date?
    @Published var exportedURL: URL?
    @Published var mtu: Int?
    @Published var hexInput = ""
    @Published var usePrimary = true

    private let recorder = BleFrameRecorder.shared

    init() {
        recorder.onPeripheralDiscovered = { [weak self] in
            guard let self else { return }
            self.devices = self.recorder.discoveredPeripherals.map {
                DiscoveredDevice(id: $0.id, name: $0.name, rssi: $0.rssi)
            }
        }
        recorder.onStateChange = { [weak self] text in
            guard let self else { return }
            self.statusText = text
            if text.hasPrefix("已连接") {
                self.isConnected = true
                self.peerName = self.recorder.discoveredPeripherals.first?.name
            } else if text.contains("断开") || text.contains("失败") {
                self.isConnected = false
            }
        }
        recorder.onFrame = { [weak self] frame in
            guard let self else { return }
            self.frames.append(DisplayFrame(frame: frame))
            if self.frames.count > 2000 {
                self.frames.removeFirst(self.frames.count - 2000)
            }
            self.mtu = self.recorder.currentMTU()
        }
    }

    func toggleRecording() {
        if isRecording {
            exportedURL = recorder.stopRecording()
            isRecording = false
            if let url = exportedURL {
                statusText = "已导出 \(url.lastPathComponent)"
            }
        } else {
            recorder.startRecording()
            recorder.startScan()
            isRecording = true
            startTime = Date()
            frames.removeAll()
            statusText = "录制中，正在扫描…"
        }
    }

    func connect(to id: UUID) {
        recorder.connect(to: id)
    }

    func sendRaw(_ hex: String) {
        recorder.sendRaw(hexString: hex, usePrimary: usePrimary)
    }

    var statusColor: Color {
        if !isRecording { return .secondary }
        return isConnected ? .green : .orange
    }

    struct DiscoveredDevice: Identifiable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    struct DisplayFrame: Identifiable {
        let id = UUID()
        let raw: BleFrameRecorder.Frame

        var direction: BleFrameRecorder.Frame.Direction { raw.direction }
        var relativeTime: TimeInterval { raw.relativeTime }
        var characteristic: String { raw.characteristic }
        var payload: Data { raw.payload }
        var hex: String { raw.hex }
        var asciiPreview: String { raw.asciiPreview }
    }
}

private let UUID_PRIMARY_PREFIX = "0000FFF1"
private let UUID_SECONDARY_PREFIX = "0000FFF2"

/// 设置页里的抓包入口。
///
/// 单独抽出来是因为 `BleCaptureView` 的私有扩展跨文件不可见，
/// 用独立 View 让 ContentView 能直接引用。
struct BleCaptureEntry: View {
    var body: some View {
        NavigationLink {
            BleCaptureView()
        } label: {
            Label("BLE 抓包工具", systemImage: "waveform.path.ecg")
        }
    }
}
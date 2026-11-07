import SwiftUI
import CoreBluetooth

/// 数字钥匙同步 + 蓝牙连接调试页（协议逆向自 APK y1/J.smali ①–⑤ 步骤）。
struct KeyManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dk = DigitalKeyService.shared
    @State private var keyIDInput = ""
    @State private var vinInput = CredentialStore.shared.defaultVin ?? ""
    @State private var discovered: [DiscoveredDevice] = []

    struct DiscoveredDevice: Identifiable {
        let peripheral: CBPeripheral
        var name: String?
        var rssi: Int
        var id: UUID { peripheral.identifier }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("数字钥匙同步（①→②→③→⑤）") {
                    LabeledContent("userName", value: dk.userName.isEmpty ? "（未获取：请退出后重新登录）" : dk.userName)
                    LabeledContent("deviceID", value: dk.deviceID)
                    LabeledContent("公钥已上传", value: dk.publicKeyUploaded ? "是" : "否")

                    Button("① 上传本机 ECC 公钥") {
                        Task { await dk.uploadPublicKey() }
                    }
                    .disabled(dk.busy)

                    Button("② 取钥匙列表") {
                        Task { await dk.fetchKeyList() }
                    }
                    .disabled(dk.busy)

                    HStack {
                        TextField("keyID（空=自动提取）", text: $keyIDInput)
                            .font(.footnote)
                        Button("③ 激活并下载钥匙") {
                            let manual = keyIDInput
                                .trimmingCharacters(in: .whitespaces)
                            let ids = manual.isEmpty ? dk.extractKeyIDs() : [manual]
                            if let first = ids.first {
                                Task { await dk.activateAndDownloadKey(keyID: first) }
                            } else {
                                Task { await dk.downloadKeyRawData(keyIDs: []) }
                            }
                        }
                        .disabled(dk.busy)
                    }

                    HStack {
                        TextField("VIN", text: $vinInput)
                            .font(.footnote)
                        Button("⑤ 取白名单") {
                            Task { await dk.fetchWhitelist(vin: vinInput) }
                        }
                        .disabled(dk.busy)
                    }

                    if dk.busy { ProgressView() }
                }

                if let raw = dk.keyRawData, !raw.isEmpty {
                    Section("钥匙原文（已存 Keychain，可复制发给我分析）") {
                        ScrollView {
                            Text(raw)
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                    }
                }

                Section("蓝牙扫描（车机名 HOZON_KEY_<VIN尾5位>）") {
                    Button("扫描 10 秒") {
                        discovered.removeAll()
                        TboeTransport.shared.onDiscovered = { p, n, r in
                            // 过滤无名设备噪音；车机广播名固定为 HOZON_KEY_<VIN尾5位>
                            guard let n, !n.isEmpty else { return }
                            if let idx = discovered.firstIndex(where: { $0.peripheral.identifier == p.identifier }) {
                                discovered[idx].rssi = r
                                discovered[idx].name = n
                            } else {
                                discovered.append(DiscoveredDevice(peripheral: p, name: n, rssi: r))
                            }
                        }
                        TboeTransport.shared.startScan(timeout: 10)
                    }
                    .disabled(dk.busy)

                    ForEach(discovered) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "（无名设备）")
                                    .font(.footnote)
                                Text(item.peripheral.identifier.uuidString)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(item.rssi) dBm")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(item.rssi > -70 ? .green : .secondary)
                            Button("连接") {
                                TboeTransport.shared.connect(to: item.peripheral)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    LabeledContent("通道状态", value: stateText)
                }

                Section("同步日志") {
                    ScrollView {
                        Text(dk.logText.isEmpty ? "（空）" : dk.logText)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                    ShareLink(item: DiagnosticLog.shared.fileURL) {
                        Label("导出诊断日志（含蓝牙原始帧）", systemImage: "square.and.arrow.up")
                    }
                    Button("清空日志", role: .destructive) { dk.clearLog() }
                }

                Section {
                    Text("提示：握手帧格式未校准前，连接后不会进入 ready 状态。可在连接后用「调试-抓帧」记录车端下发的原始帧，或从安卓版 App 导出日志（NetaTboe 标签）对照。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("数字钥匙")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var stateText: String {
        switch TboeTransport.shared.state {
        case .idle: return "未连接"
        case .connecting: return "连接中"
        case .awaitingChallenge: return "等待挑战码"
        case .sendingResponse: return "回送响应中"
        case .verifyingResponse: return "验签中"
        case .syncingWhitelist: return "白名单同步"
        case .ready: return "已就绪"
        case .failed(let e): return "失败：" + e
        }
    }
}

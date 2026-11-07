import Foundation

/// 诊断日志：与安卓版对齐（写文件默认开启、1 MB 上限、可导出分享）。
/// 内容包含 NetHttp 请求摘要、TBOE 原始帧（rx/tx hex）、靠近判定、钥匙同步。
/// ⚠️ 文件含 VIN 与钥匙材料，导出后请只发给自己/可信的分析者。
final class DiagnosticLog {

    static let shared = DiagnosticLog()

    private let url: URL
    private let capBytes = 1_000_000

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("diagnostics.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url)
        }
    }

    var fileURL: URL { url }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    var sizeBytes: Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    static func ms() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    func log(_ tag: String, _ message: String) {
        let line = "\(Self.ms()) \(tag) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(data)
        }
        trimIfNeeded()
    }

    func clear() {
        try? Data().write(to: url)
    }

    /// 超过上限时丢弃较早的一半（安卓同策略）
    private func trimIfNeeded() {
        let size = sizeBytes
        guard size > capBytes, let content = try? Data(contentsOf: url) else { return }
        try? content.subdata(in: size / 2..<content.count).write(to: url)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

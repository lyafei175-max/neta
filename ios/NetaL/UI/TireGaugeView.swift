import SwiftUI

/// 单只轮胎的环形仪表：进场填充动画 + 数字滚动 + 呼吸光晕。
/// 胎压数值单位 bar（换算见 CloudVehicleData.tirePressureBar，公式来自官方 APK）。
struct TireGaugeView: View {

    let name: String
    let pressure: Double?      // bar
    let temperature: Double?   // ℃

    @State private var fill: CGFloat = 0
    @State private var shown: Double = 0
    @State private var pulse = false

    /// 满环 = 3.0 bar
    private var ratio: CGFloat {
        guard let p = pressure else { return 0 }
        return min(max(CGFloat(p) / 3.0, 0.06), 1.0)
    }

    /// 颜色分级：<1.8 过低 / 1.8–2.1 偏低 / 2.1–2.9 正常 / >2.9 偏高
    private var color: Color {
        guard let p = pressure else { return .gray }
        switch p {
        case ..<1.8: return .red
        case 1.8..<2.1: return .orange
        case 2.1..<2.9: return .green
        default: return .orange
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color(.systemGray5), lineWidth: 6)

                Circle()
                    .trim(from: 0, to: min(fill * ratio, 1.0))
                    .stroke(color.opacity(pulse ? 0.95 : 0.7),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(pulse ? 0.5 : 0.12),
                            radius: pulse ? 7 : 3)

                VStack(spacing: 0) {
                    if pressure != nil {
                        Color.clear
                            .frame(width: 56, height: 20)
                            .modifier(CountingValue(value: shown))
                    } else {
                        Text("--")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(height: 20)
                    }
                    Text("bar")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 82, height: 82)

            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Group {
                if let t = temperature {
                    Text("\(Int(t))℃")
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .onAppear(perform: animateIn)
        .onChange(of: pressure) { _ in animateIn() }
    }

    private func animateIn() {
        shown = 0
        fill = 0
        withAnimation(.easeOut(duration: 1.3)) {
            fill = 1
            shown = pressure ?? 0
        }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            pulse.toggle()
        }
    }
}

/// 数字滚动：利用 AnimatableModifier 的逐帧插值驱动 Text 重绘。
private struct CountingValue: AnimatableModifier {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(0)
            .overlay(
                Text(String(format: "%.2f", value))
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            )
    }
}

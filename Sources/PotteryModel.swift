import SwiftUI

/// 陶器的資料：從底到口每一層的外半徑（公尺）與釉色
@Observable
final class PotteryModel {
    static let sliceCount = 32
    static let height: Float = 0.3
    static let minRadius: Float = 0.05
    static let maxRadius: Float = 0.2

    var radii: [Float] = Preset.clay.radii
    var glaze: Glaze = .clay

    /// 手指推到某個高度與半徑，周圍幾層會跟著平滑變形
    func sculpt(atHeight y: Float, radius: Float) {
        let n = Self.sliceCount
        let center = y / Self.height * Float(n - 1)
        let target = min(max(radius, Self.minRadius), Self.maxRadius)
        var next = radii
        for i in 0..<n {
            let d = Float(i) - center
            let weight = exp(-d * d / 8)   // 影響範圍約 ±3 層
            if weight > 0.02 {
                next[i] = radii[i] + (target - radii[i]) * weight
            }
        }
        radii = next
    }

    func apply(_ preset: Preset) {
        radii = preset.radii
    }

    enum Preset: CaseIterable, Identifiable {
        case clay, cup, bowl, vase

        var id: Self { self }

        var title: String {
            switch self {
            case .clay: "泥團"
            case .cup: "杯子"
            case .bowl: "碗"
            case .vase: "花瓶"
            }
        }

        var symbol: String {
            switch self {
            case .clay: "circle.fill"
            case .cup: "cup.and.saucer.fill"
            case .bowl: "fork.knife"
            case .vase: "drop.fill"
            }
        }

        var radii: [Float] {
            let n = PotteryModel.sliceCount
            return (0..<n).map { i in
                let t = Float(i) / Float(n - 1)
                switch self {
                case .clay:
                    return 0.10
                case .cup:
                    return 0.08 + 0.02 * t
                case .bowl:
                    return 0.07 + 0.13 * pow(t, 0.6)
                case .vase:
                    let belly = 0.09 * (1 + 0.6 * sin(.pi * t))
                    let neck = smoothstep(0.7, 0.95, t)
                    return belly * (1 - 0.55 * neck)
                }
            }
        }

        private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
    }

    enum Glaze: CaseIterable, Identifiable {
        case clay, red, blue, green, yellow, white

        var id: Self { self }

        var color: UIColor {
            switch self {
            case .clay: UIColor(red: 0.72, green: 0.45, blue: 0.30, alpha: 1)
            case .red: UIColor(red: 0.85, green: 0.22, blue: 0.20, alpha: 1)
            case .blue: UIColor(red: 0.20, green: 0.42, blue: 0.80, alpha: 1)
            case .green: UIColor(red: 0.25, green: 0.65, blue: 0.40, alpha: 1)
            case .yellow: UIColor(red: 0.96, green: 0.78, blue: 0.20, alpha: 1)
            case .white: UIColor(red: 0.95, green: 0.93, blue: 0.88, alpha: 1)
            }
        }

        /// 上釉後比較光滑發亮
        var roughness: Float { self == .clay ? 0.9 : 0.25 }
    }
}

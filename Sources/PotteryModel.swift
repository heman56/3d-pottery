import SwiftUI

/// 陶器的資料：從底到口每一層的外半徑（公尺）、底面形狀、扭轉角度與釉色。
/// 「半徑」一律指底面的外接圓半徑（正多邊形的中心到頂點，正方形就是對角線的一半）
@Observable
final class PotteryModel {
    static let sliceCount = 48
    static let height: Float = 0.3
    static let minRadius: Float = 0.01
    static let maxRadius: Float = 0.3
    /// 從底到口最多扭轉的角度（弧度），正負各一圈
    static let maxTwist: Float = 2 * .pi

    var radii: [Float] = Preset.clay.radii
    private(set) var glaze: Glaze = .clay
    private(set) var baseShape: BaseShape = .circle
    private(set) var twist: Float = 0

    /// 重新擠出陶器所需的全部資料
    var spec: VesselSpec { VesselSpec(radii: radii, sides: baseShape.sides, twist: twist) }
    var mode: Mode = .sculpt
    var showWireframe = false
    var camera = CameraPose.start

    enum Mode { case sculpt, look }

    // MARK: 復原 / 重做

    private struct Snapshot {
        var radii: [Float]
        var glaze: Glaze
        var baseShape: BaseShape
        var twist: Float
    }

    private static let historyLimit = 60
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// 一次拖曳（一筆）開始時的樣子，第一次真的改到形狀時才存進復原紀錄
    @ObservationIgnored private var strokeStart: Snapshot?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private var snapshot: Snapshot {
        Snapshot(radii: radii, glaze: glaze, baseShape: baseShape, twist: twist)
    }

    private func restore(_ s: Snapshot) {
        radii = s.radii
        glaze = s.glaze
        baseShape = s.baseShape
        twist = s.twist
    }

    private func record(_ before: Snapshot) {
        undoStack.append(before)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }

    func setGlaze(_ newGlaze: Glaze) {
        guard newGlaze != glaze else { return }
        record(snapshot)
        glaze = newGlaze
    }

    func setBaseShape(_ shape: BaseShape) {
        guard shape != baseShape else { return }
        record(snapshot)
        baseShape = shape
    }

    /// 扭轉滑桿：拖一次算一步
    func setTwist(_ value: Float) {
        commitStrokeStart()
        twist = min(max(value, -Self.maxTwist), Self.maxTwist)
    }

    func beginStroke() { strokeStart = snapshot }
    func endStroke() { strokeStart = nil }

    /// 這一筆第一次真的改到東西時，才把筆畫開始前的樣子存進復原紀錄
    private func commitStrokeStart() {
        if let start = strokeStart {
            record(start)
            strokeStart = nil
        }
    }

    // MARK: 相機

    /// 檢視模式：單指拖曳轉動相機（dx、dy 為螢幕上移動的點數）
    func orbit(dx: CGFloat, dy: CGFloat) {
        camera.yaw -= Float(dx) * 0.008
        camera.pitch = min(max(camera.pitch + Float(dy) * 0.006, 0), CameraPose.maxPitch)
    }

    func zoom(to distance: Float) {
        camera.distance = min(max(distance, 0.45), 2.0)
    }

    func setView(_ preset: CameraPose.Preset) {
        var pose = preset.pose
        // 轉最短的方向
        var delta = (pose.yaw - camera.yaw).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi } else if delta < -.pi { delta += 2 * .pi }
        pose.yaw = camera.yaw + delta
        camera = pose
    }

    // MARK: 塑形

    /// 手指推到某個高度與半徑，周圍幾層會跟著平滑變形
    func sculpt(atHeight y: Float, radius: Float) {
        commitStrokeStart()
        let n = Self.sliceCount
        let center = y / Self.height * Float(n - 1)
        let target = min(max(radius, Self.minRadius), Self.maxRadius)
        var next = radii
        for i in 0..<n {
            // 層數改變時，筆刷的實際寬度（約 ±3 公分）維持不變
            let d = (Float(i) - center) * 31 / Float(n - 1)
            let weight = exp(-d * d / 8)
            if weight > 0.02 {
                next[i] = radii[i] + (target - radii[i]) * weight
            }
        }
        radii = next
    }

    func apply(_ preset: Preset) {
        record(snapshot)
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

    /// 底面的形狀。sides = 0 代表圓，其餘是正多邊形的邊數
    enum BaseShape: CaseIterable, Identifiable {
        case circle, triangle, square, hexagon

        var id: Self { self }

        var sides: Int {
            switch self {
            case .circle: 0
            case .triangle: 3
            case .square: 4
            case .hexagon: 6
            }
        }

        var title: String {
            switch self {
            case .circle: "圓形"
            case .triangle: "三角"
            case .square: "四方"
            case .hexagon: "六角"
            }
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

        /// 上釉後表面光滑發亮
        var isGlazed: Bool { self != .clay }
    }
}

/// 擠出一件陶器所需的資料（相同就不用重建）
struct VesselSpec: Equatable {
    var radii: [Float]
    var sides: Int
    var twist: Float
}

/// 相機繞著陶器轉：yaw 水平角、pitch 仰角（往下看為正）、distance 距離（公尺）
struct CameraPose: Equatable {
    var yaw: Float
    var pitch: Float
    var distance: Float

    static let maxPitch: Float = 1.5   // 約 86°，再高就和向上的方向重疊
    static let start = CameraPose(yaw: 0, pitch: 0.5, distance: 1.0)

    enum Preset: CaseIterable, Identifiable {
        case front, side, top, solid

        var id: Self { self }

        var title: String {
            switch self {
            case .front: "前視"
            case .side: "側視"
            case .top: "上視"
            case .solid: "立體"
            }
        }

        var symbol: String {
            switch self {
            case .front: "rectangle.portrait"
            case .side: "rectangle.portrait.rotate"
            case .top: "circle.dashed"
            case .solid: "cube"
            }
        }

        var pose: CameraPose {
            switch self {
            case .front: CameraPose(yaw: 0, pitch: 0, distance: 1.0)
            case .side: CameraPose(yaw: .pi / 2, pitch: 0, distance: 1.0)
            case .top: CameraPose(yaw: 0, pitch: maxPitch, distance: 1.0)
            case .solid: CameraPose(yaw: 0.6, pitch: 0.5, distance: 1.0)
            }
        }
    }
}

extension UIColor {
    /// 乘上係數讓顏色變暗（係數 < 1）
    func shaded(by factor: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
    }
}

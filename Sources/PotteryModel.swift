import SwiftUI
import UIKit

/// 陶器的資料：從底到口每一層的外半徑（公尺）、底面形狀、扭轉角度與釉色。
/// 「半徑」一律指底面的外接圓半徑（正多邊形的中心到頂點，正方形就是對角線的一半）
@Observable
final class PotteryModel {
    static let sliceCount = 48
    static let height: Float = 0.3
    static let minRadius: Float = 0.01
    static let maxRadius: Float = 0.28
    /// 轉盤的半徑：比陶器最大的半徑再寬一點點，畫面才不會被空蕩蕩的轉盤佔滿
    static let turntableRadius: Float = 0.30
    /// 從底到口最多扭轉的角度（弧度），正負各一圈
    static let maxTwist: Float = 2 * .pi

    var radii: [Float] = Preset.clay.radii
    private(set) var glaze: Glaze = .clay
    private(set) var baseShape: BaseShape = .circle
    private(set) var twist: Float = 0
    private(set) var pattern: Pattern = .stripes
    private(set) var finish: Finish = .matte
    /// 貼滿陶器外面的照片（只有「照片」花紋會用到）。照片會被縮放成「繞一圈 tilesAround 張、
    /// 從底到口 tilesUp 張」，張數都是整數，所以四方連續的圖案接得起來
    private(set) var photo: UIImage?
    private(set) var tilesAround = 4
    private(set) var tilesUp = 2

    /// 重新擠出陶器所需的全部資料
    var spec: VesselSpec {
        let tiles = (pattern == .photo && photo != nil) ? TileSpec(around: tilesAround, up: tilesUp) : nil
        return VesselSpec(radii: radii, sides: baseShape.sides, twist: twist, tiles: tiles)
    }
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
        var pattern: Pattern
        var finish: Finish
        var tilesAround: Int
        var tilesUp: Int
    }

    private static let historyLimit = 60
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// 一次拖曳（一筆）開始時的樣子，第一次真的改到形狀時才存進復原紀錄
    @ObservationIgnored private var strokeStart: Snapshot?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private var snapshot: Snapshot {
        Snapshot(radii: radii, glaze: glaze, baseShape: baseShape, twist: twist, pattern: pattern, finish: finish,
                 tilesAround: tilesAround, tilesUp: tilesUp)
    }

    private func restore(_ s: Snapshot) {
        radii = s.radii
        glaze = s.glaze
        baseShape = s.baseShape
        twist = s.twist
        pattern = s.pattern
        finish = s.finish
        tilesAround = s.tilesAround
        tilesUp = s.tilesUp
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

    /// 選了照片就自動切到「照片」花紋（照片本身不進復原紀錄，太大）
    func setPhoto(_ image: UIImage?) {
        if image != nil, pattern != .photo {
            record(snapshot)
            pattern = .photo
        }
        photo = image
        if image != nil {
            tilesAround = 4
            refitTiles()
        }
    }

    static let maxTiles = 12

    func setTilesAround(_ value: Int) {
        commitStrokeStart()
        tilesAround = min(max(value, 1), Self.maxTiles)
    }

    func setTilesUp(_ value: Int) {
        commitStrokeStart()
        tilesUp = min(max(value, 1), Self.maxTiles)
    }

    /// 「自動比例」按鈕：依目前的陶器形狀，挑上下的張數，讓每一張的長寬比最接近照片原本的比例
    func fitTilesToPhoto() {
        record(snapshot)
        refitTiles()
    }

    private func refitTiles() {
        guard let photo, photo.size.height > 0 else { return }
        let aspect = Float(photo.size.width / photo.size.height)
        let sides = baseShape.sides
        let perimeterUnit: Float = sides == 0 ? 2 * .pi : Float(sides) * 2 * sin(.pi / Float(sides))
        let meanCircumference = radii.reduce(0, +) / Float(radii.count) * perimeterUnit
        var profileLength: Float = 0
        for i in 1..<radii.count {
            let dr = radii[i] - radii[i - 1]
            let dy = Self.height / Float(radii.count - 1)
            profileLength += (dr * dr + dy * dy).squareRoot()
        }
        let tileWidth = meanCircumference / Float(tilesAround)
        let tileHeight = tileWidth / aspect
        tilesUp = min(max(Int((profileLength / tileHeight).rounded()), 1), Self.maxTiles)
    }

    func setFinish(_ newFinish: Finish) {
        guard newFinish != finish else { return }
        record(snapshot)
        finish = newFinish
    }

    func setPattern(_ newPattern: Pattern) {
        guard newPattern != pattern else { return }
        record(snapshot)
        pattern = newPattern
    }

    func setBaseShape(_ shape: BaseShape) {
        guard shape != baseShape else { return }
        record(snapshot)
        baseShape = shape
    }

    /// 「歸零」按鈕：算一步，可以退回
    func resetTwist() {
        guard twist != 0 else { return }
        record(snapshot)
        twist = 0
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

    /// 這一筆開始時，陶壁與手指的距離。之後手指移到哪，陶壁就保持這個距離跟著走，
    /// 所以剛點下去、還沒移動時形狀不會變
    @ObservationIgnored private var grabOffset: Float = 0
    /// 上一個事件的位置，用來補齊手指快速移動時漏掉的中間軌跡
    @ObservationIgnored private var lastBrush: (height: Float, radius: Float)?

    func surfaceRadius(atHeight y: Float) -> Float {
        let position = min(max(y / Self.height, 0), 1) * Float(Self.sliceCount - 1)
        let lower = Int(position)
        let upper = min(lower + 1, Self.sliceCount - 1)
        return radii[lower] + (radii[upper] - radii[lower]) * (position - Float(lower))
    }

    /// 手指剛碰到陶器（高度 y、離轉軸 fingerRadius）：只記下距離，不改形狀
    func beginSculpt(atHeight y: Float, fingerRadius: Float) {
        grabOffset = surfaceRadius(atHeight: y) - fingerRadius
        lastBrush = nil
    }

    /// 手指移動到高度 y、離轉軸 fingerRadius：沿著手指的軌跡把陶壁推過去
    func sculpt(atHeight y: Float, fingerRadius: Float) {
        commitStrokeStart()
        let target = min(max(fingerRadius + grabOffset, Self.minRadius), Self.maxRadius)
        let from = lastBrush ?? (y, target)
        lastBrush = (y, target)

        let layerHeight = Self.height / Float(Self.sliceCount - 1)
        let steps = max(1, Int((abs(y - from.height) / (layerHeight * 0.5)).rounded(.up)))
        var next = radii
        for step in 1...steps {
            let f = Float(step) / Float(steps)
            paint(&next, atHeight: from.height + (y - from.height) * f, radius: from.radius + (target - from.radius) * f)
        }
        radii = next
    }

    /// 筆刷是一個「帽子形」：正中央那一層完全跟到手指，離開不到一層就不再影響。
    /// 這樣手指軌跡上比一層還細的轉折也不會被前後的事件抹平，造型才會貼著畫出的曲線
    private func paint(_ values: inout [Float], atHeight y: Float, radius: Float) {
        let n = Self.sliceCount
        let center = y / (Self.height / Float(n - 1))
        for i in max(0, Int(center))...min(n - 1, Int(center) + 1) {
            let distance = abs(Float(i) - center)
            let weight = min(max(1.6 * (1 - distance), 0), 1)
            values[i] += (radius - values[i]) * weight
        }
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

    /// 釉面上的花紋。貼圖由程式畫出，再乘上釉色
    enum Pattern: CaseIterable, Identifiable, Hashable {
        case stripes, checker, dots, waves, photo

        var id: Self { self }

        var title: String {
            switch self {
            case .stripes: "條紋"
            case .checker: "方格"
            case .dots: "圓點"
            case .waves: "波浪"
            case .photo: "照片"
            }
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
    }
}

/// 擠出一件陶器所需的資料（相同就不用重建）
struct VesselSpec: Equatable {
    var radii: [Float]
    var sides: Int
    var twist: Float
    var tiles: TileSpec?
}

/// 照片拼貼：繞一圈、從底到口各幾張（整數）。張數改變時，網格的 UV 要重算
struct TileSpec: Equatable {
    var around: Int
    var up: Int
}

/// 相機繞著陶器轉：yaw 水平角、pitch 仰角（往下看為正）、distance 距離（公尺）
struct CameraPose: Equatable {
    var yaw: Float
    var pitch: Float
    var distance: Float

    static let maxPitch: Float = 1.5   // 約 86°，再高就和向上的方向重疊
    /// 預設的相機距離（公尺）。轉盤縮小之後，可以靠得比較近，預設的陶器在畫面裡就比較大
    static let defaultDistance: Float = 0.82
    static let start = CameraPose(yaw: 0, pitch: 0.5, distance: defaultDistance)

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
            case .front: CameraPose(yaw: 0, pitch: 0, distance: defaultDistance)
            case .side: CameraPose(yaw: .pi / 2, pitch: 0, distance: defaultDistance)
            case .top: CameraPose(yaw: 0, pitch: maxPitch, distance: defaultDistance)
            case .solid: CameraPose(yaw: 0.6, pitch: 0.5, distance: defaultDistance)
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

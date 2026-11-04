import RealityKit
import Foundation
import CoreGraphics
import simd
#if canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformColor = NSColor
#endif

/// 質感：同一個釉色可以有不同的表面。
/// 材質屬性對照教材 6-7c 的 PhysicallyBasedMaterial 表：roughness、metallic、clearcoat、specular、
/// blending、emissiveColor／emissiveIntensity、triangleFillMode
enum Finish: String, Codable, CaseIterable, Identifiable, Hashable {
    case matte, glossy, metallic, glass, glow

    var id: Self { self }

    var title: String {
        switch self {
        case .matte: "啞光"
        case .glossy: "亮釉"
        case .metallic: "金屬"
        case .glass: "琉璃"
        case .glow: "發光"
        }
    }
}

enum PotteryMaterial {
    /// 窯火的顏色：heat 0…1，暗紅 → 橘 → 黃白
    static func heatColor(_ heat: Float) -> PlatformColor {
        let h = CGFloat(min(max(heat, 0), 1))
        if h < 0.5 {
            let t = h / 0.5
            return PlatformColor(red: 0.55 + 0.45 * t, green: 0.08 + 0.37 * t, blue: 0.02 + 0.03 * t, alpha: 1)
        }
        let t = (h - 0.5) / 0.5
        return PlatformColor(red: 1, green: 0.45 + 0.4 * t, blue: 0.05 + 0.4 * t, alpha: 1)
    }

    /// 依釉色（color）、質感（finish）做出材質。texture 是花紋或照片，會和 color 相乘。
    /// PhysicallyBasedMaterial 是 struct，指定時會複製一份，所以下面每種質感都是在同一份基本設定上改幾個屬性
    static func make(color: PlatformColor, finish: Finish, wireframe: Bool, texture: TextureResource?, normalMap: TextureResource? = nil, heat: Float = 0) -> any Material {
        #if targetEnvironment(simulator)
        // Intel 模擬器編譯光照材質會當機，改用不受光照影響的 UnlitMaterial，並用顏色與透明度做近似
        var material: UnlitMaterial
        switch finish {
        case .matte, .glossy, .metallic:
            material = UnlitMaterial(color: color)
        case .glass:
            material = UnlitMaterial(color: color)
            material.blending = .transparent(opacity: .init(floatLiteral: 0.45))
        case .glow:
            material = UnlitMaterial(color: color.lightened(by: 0.45))
        }
        if heat > 0 {
            // 入窯：整件往燒紅的顏色靠（不受光照的版本直接換色，花紋與照片也一併蓋掉）
            material = UnlitMaterial(color: color.mixed(with: Self.heatColor(heat), by: CGFloat(min(heat * 1.2, 1))))
        } else if let texture {
            let tint = finish == .glow ? color.lightened(by: 0.45) : color
            material.color = .init(tint: tint, texture: .init(texture))
        }
        if wireframe { material.triangleFillMode = .lines }
        return material
        #else
        var material = PhysicallyBasedMaterial()
        if let texture {
            material.baseColor = .init(tint: color, texture: .init(texture))
        } else {
            material.baseColor = .init(tint: color)
        }
        // 法線貼圖（拉坯紋）：只改變受光的方向，不改幾何；需要網格提供 tangents
        // 沒有法線貼圖時也要明確指定：RealityKit 換材質時，沒設的屬性會殘留上一個材質的值（拉坯紋關不掉）
        material.normal = normalMap.map { .init(texture: .init($0)) } ?? .init()
        material.metallic = .init(floatLiteral: 0)
        material.roughness = .init(floatLiteral: 0.95)
        // 明確關掉自發光：RealityKit 換材質時，沒設的 emissive 會殘留上一個材質的值（發光切不回來）
        material.emissiveColor = .init(color: .black)
        material.emissiveIntensity = 0

        switch finish {
        case .matte:
            break
        case .glossy:
            // 亮釉：表面有一層透明的清漆，會反出環境的光
            material.roughness = .init(floatLiteral: 0.35)
            material.clearcoat = .init(floatLiteral: 1)
            material.clearcoatRoughness = .init(floatLiteral: 0.06)
            material.specular = .init(floatLiteral: 0.7)
        case .metallic:
            // 金屬釉：金屬性 1，粗糙度低才反得出環境（沒有環境光時看起來會很暗）
            material.metallic = .init(floatLiteral: 1)
            material.roughness = .init(floatLiteral: 0.28)
        case .glass:
            // 琉璃：半透明加很光滑的表面
            material.roughness = .init(floatLiteral: 0.08)
            material.specular = .init(floatLiteral: 1)
            material.clearcoat = .init(floatLiteral: 1)
            material.clearcoatRoughness = .init(floatLiteral: 0.03)
            material.blending = .transparent(opacity: .init(floatLiteral: 0.45))
        case .glow:
            // 發光釉：自己發光，花紋和照片也跟著亮
            material.roughness = .init(floatLiteral: 0.6)
            if let texture {
                material.emissiveColor = .init(color: color, texture: .init(texture))
            } else {
                material.emissiveColor = .init(color: color)
            }
            // 有貼圖（尤其照片是白色色調）時 2.0 會過曝成一片白，降低一些
            material.emissiveIntensity = texture == nil ? 2.0 : 0.45
        }
        if heat > 0 {
            // 入窯：自發光，顏色隨溫度由暗紅、橘紅到黃白；沿用原本的釉色、花紋、質感當底
            material.emissiveColor = .init(color: Self.heatColor(heat))
            material.emissiveIntensity = heat * 1.8
        }
        if wireframe { material.triangleFillMode = .lines }
        return material
        #endif
    }

    /// 拉坯紋的法線貼圖。seed 決定這件陶器的紋路，同一個 seed 一定畫出同一張；seed 0 是最早版本固定的紋路（舊作品檔用）。
    ///
    /// 貼圖縱向（v）對應從底到口，橫向（u）對應繞一圈。法線 = 高度的斜率換成顏色（0.5 代表不偏）；
    /// 斜率直接寫成傾斜量（約 0.3 ≈ 17°），不隨頻率變大。
    /// 隨機的 seed：粗、細兩組紋路，各自有隨機的圈數、強弱、螺旋圈數（繞一圈上升幾圈，取整數才接得起來，最多十幾圈，傾斜就看得出來），
    /// 再加上紋路間距的緩慢起伏與整體強弱的漲落，所以看起來像手拉的，每件都不一樣
    static func ridgeNormalImage(seed: UInt32 = 0) -> CGImage? {
        let width = seed == 0 ? 8 : 512, height = 1024
        let twoPi = 2 * Float.pi
        var rng = SeededRandom(seed: seed)
        func range(_ r: ClosedRange<Float>) -> Float { r.lowerBound + (r.upperBound - r.lowerBound) * rng.next() }
        let coarse = range(16...60), fine = range(60...150)
        let coarseAmp = range(0.15...0.45), fineAmp = range(0.06...0.24)
        let coarseTurns = Float(Int(range(-12.99...12.99))), fineTurns = Float(Int(range(-14.99...14.99)))
        let warpAmp = range(0.3...3.5), warpCycles = Float(2 + Int(range(0...5.99))), warpPhase = range(0...twoPi)
        let wobbleAmp = range(0.2...6.0), wobbleCycles = Float(1 + Int(range(0...3.99))), wobblePhase = range(0...twoPi)
        let swellCycles = Float(1 + Int(range(0...2.99))), swellPhase = range(0...twoPi)
        let jitterCycles = range(7...19), jitterPhase = range(0...twoPi), finePhase = range(0...twoPi)
        // 表面性格：拉坯紋之外，再疊上細砂（顆粒）或刷痕（細的直紋），或把拉坯紋減弱。
        // 依序是（拉坯紋強度、細砂強度、刷痕強度）；放在上面那些抽籤之後，不影響它們
        let personalities: [(ridge: Float, sand: Float, brush: Float)] = [
            (1, 0, 0), (1, 0.22, 0), (1, 0, 0.25), (0.35, 0.3, 0), (0.55, 0.15, 0.2),
        ]
        let personality = seed == 0 ? personalities[0] : personalities[Int(range(0...4.99))]
        let sandSeed = range(0...1), brushCells = Int(range(90...220)), brushPhase = range(0...twoPi)
        let brushBands = Float(2 + Int(range(0...2.99))), brushDrift = range(0.005...0.03)
        let sand = personality.sand > 0 ? Self.sandSlopes(width: width, height: height, seed: sandSeed, amount: personality.sand) : nil
        let brush = personality.brush > 0
            ? Self.brushSlopes(width: width, height: height, cells: brushCells, phase: brushPhase, bands: brushBands, drift: brushDrift, amount: personality.brush)
            : nil
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let v = Float(y) / Float(height)
            for x in 0..<width {
                let u = Float(x) / Float(width)
                let tilt: Float
                if seed == 0 {
                    tilt = 0.3 * cos(twoPi * 40 * v) + 0.18 * cos(twoPi * 103 * v + 1)
                } else {
                    let warp = warpAmp * sin(twoPi * warpCycles * v + warpPhase)
                    let wobble = wobbleAmp * sin(twoPi * wobbleCycles * u + wobblePhase)
                    let swell = 0.45 + 0.55 * sin(twoPi * swellCycles * v + swellPhase)
                    let jitter = 0.75 + 0.25 * sin(twoPi * jitterCycles * v + jitterPhase)
                    let first = coarseAmp * jitter * cos(twoPi * (coarse * v + coarseTurns * u) + warp + wobble)
                    let second = fineAmp * cos(twoPi * (fine * v + fineTurns * u) + 1.7 * warp + finePhase)
                    tilt = min(max(swell * (first + second), -0.6), 0.6)
                }
                var slopeU: Float = 0, slopeV = tilt * personality.ridge
                if let sand {
                    slopeU += sand.u[y * width + x]
                    slopeV += sand.v[y * width + x]
                }
                if let brush { slopeU += brush[y * width + x] }
                let n = simd_normalize(SIMD3<Float>(-slopeU, -slopeV, 1))
                let i = (y * width + x) * 4
                pixels[i] = UInt8((n.x * 0.5 + 0.5) * 255)
                pixels[i + 1] = UInt8((n.y * 0.5 + 0.5) * 255)
                pixels[i + 2] = UInt8((n.z * 0.5 + 0.5) * 255)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

extension PotteryMaterial {
    /// 隨機格點上的平滑雜訊（u 方向首尾相接，v 方向不接）。cellsU × (cellsV + 1) 個隨機值，之間用 smoothstep 內插
    private struct ValueNoise {
        let cellsU: Int, cellsV: Int
        private let values: [Float]

        init(cellsU: Int, cellsV: Int, rng: inout SeededRandom) {
            self.cellsU = cellsU
            self.cellsV = cellsV
            values = (0..<(cellsU * (cellsV + 1))).map { _ in rng.next() * 2 - 1 }
        }

        func sample(u: Float, v: Float) -> Float {
            let x = u * Float(cellsU), y = min(max(v, 0), 0.9999) * Float(cellsV)
            let xi = Int(x.rounded(.down)), yi = Int(y)
            func smooth(_ f: Float) -> Float { f * f * (3 - 2 * f) }
            let fx = smooth(x - Float(xi)), fy = smooth(y - Float(yi))
            let x0 = ((xi % cellsU) + cellsU) % cellsU, x1 = (x0 + 1) % cellsU
            func value(_ cx: Int, _ cy: Int) -> Float { values[cy * cellsU + cx] }
            let top = value(x0, yi) * (1 - fx) + value(x1, yi) * fx
            let bottom = value(x0, yi + 1) * (1 - fx) + value(x1, yi + 1) * fx
            return top * (1 - fy) + bottom * fy
        }
    }

    /// 把一組數字縮放到指定的均方根大小
    private static func normalized(_ values: inout [Float], rms target: Float) {
        let mean = values.reduce(0) { $0 + $1 * $1 } / Float(max(values.count, 1))
        let scale = mean > 0 ? target / mean.squareRoot() : 0
        for i in values.indices { values[i] *= scale }
    }

    /// 細砂：兩層顆粒雜訊（一粗一細）當高度，取兩個方向的斜率。
    /// 貼圖橫向約 0.6 公尺、縱向約 0.3 公尺，格數照比例 2:1 取，顆粒在陶器上才是圓的
    fileprivate static func sandSlopes(width: Int, height: Int, seed: Float, amount: Float) -> (u: [Float], v: [Float]) {
        var rng = SeededRandom(seed: UInt32(seed * 1_000_000) &+ 77)
        let coarse = ValueNoise(cellsU: 256, cellsV: 128, rng: &rng)
        let fine = ValueNoise(cellsU: 384, cellsV: 192, rng: &rng)
        var h = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let v = Float(y) / Float(height)
            for x in 0..<width {
                let u = Float(x) / Float(width)
                h[y * width + x] = coarse.sample(u: u, v: v) + 0.6 * fine.sample(u: u, v: v)
            }
        }
        var du = [Float](repeating: 0, count: width * height), dv = du
        for y in 0..<height {
            for x in 0..<width {
                let left = h[y * width + (x + width - 1) % width], right = h[y * width + (x + 1) % width]
                let up = h[max(y - 1, 0) * width + x], down = h[min(y + 1, height - 1) * width + x]
                du[y * width + x] = (right - left) / (2 * 0.6 / Float(width))   // 每公尺的高度差
                dv[y * width + x] = (down - up) / (2 * 0.3 / Float(height))
            }
        }
        normalized(&du, rms: amount)
        normalized(&dv, rms: amount)
        return (du, dv)
    }

    /// 刷痕：只沿圓周方向變化的一維雜訊（一條條直紋），略微飄移，並隨高度一段強一段弱
    fileprivate static func brushSlopes(width: Int, height: Int, cells: Int, phase: Float, bands: Float, drift: Float, amount: Float) -> [Float] {
        var rng = SeededRandom(seed: UInt32(cells) &* 7919 &+ 13)
        let main = ValueNoise(cellsU: cells, cellsV: 1, rng: &rng)
        let fine = ValueNoise(cellsU: Int(Float(cells) * 2.3), cellsV: 1, rng: &rng)
        let delta = 0.5 / Float(width)
        var slopes = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let v = Float(y) / Float(height)
            let shift = drift * sin(2 * .pi * (2 * v) + phase)
            let band = 0.4 + 0.6 * (0.5 + 0.5 * sin(2 * .pi * bands * v + phase))
            for x in 0..<width {
                let u = Float(x) / Float(width) + shift
                func h(_ u: Float) -> Float { main.sample(u: u, v: 0) + 0.5 * fine.sample(u: u, v: 0) }
                slopes[y * width + x] = (h(u + delta) - h(u - delta)) * band
            }
        }
        normalized(&slopes, rms: amount)
        return slopes
    }
}

/// 固定 seed 就固定結果的亂數（SplitMix64），next() 回傳 0..<1
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt32) { state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }
}

extension PlatformColor {
    /// 兩色之間混合：factor 0 是自己，1 是 other
    func mixed(with other: PlatformColor, by factor: CGFloat) -> PlatformColor {
        func parts(_ c: PlatformColor) -> (CGFloat, CGFloat, CGFloat) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            #if canImport(UIKit)
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            #else
            (c.usingColorSpace(.sRGB) ?? c).getRed(&r, green: &g, blue: &b, alpha: &a)
            #endif
            return (r, g, b)
        }
        let (r1, g1, b1) = parts(self), (r2, g2, b2) = parts(other)
        return PlatformColor(red: r1 + (r2 - r1) * factor, green: g1 + (g2 - g1) * factor, blue: b1 + (b2 - b1) * factor, alpha: 1)
    }

    /// 往白色混：factor 0 不變，1 全白
    func lightened(by factor: CGFloat) -> PlatformColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        (usingColorSpace(.sRGB) ?? self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return PlatformColor(red: r + (1 - r) * factor, green: g + (1 - g) * factor, blue: b + (1 - b) * factor, alpha: a)
    }
}

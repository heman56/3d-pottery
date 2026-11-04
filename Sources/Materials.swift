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
    /// 隨機的 seed：粗、細兩組紋路，各自有隨機的圈數、強弱、螺旋圈數（繞一圈上升幾圈，取整數才接得起來），
    /// 再加上紋路間距的緩慢起伏與整體強弱的漲落，所以看起來像手拉的，每件都不一樣
    static func ridgeNormalImage(seed: UInt32 = 0) -> CGImage? {
        let width = seed == 0 ? 8 : 128, height = 1024
        let twoPi = 2 * Float.pi
        var rng = SeededRandom(seed: seed)
        func range(_ r: ClosedRange<Float>) -> Float { r.lowerBound + (r.upperBound - r.lowerBound) * rng.next() }
        let coarse = range(26...50), fine = range(70...130)
        let coarseAmp = range(0.20...0.40), fineAmp = range(0.10...0.22)
        let coarseTurns = Float(Int(range(-2.99...2.99))), fineTurns = Float(Int(range(-3.99...3.99)))
        let warpAmp = range(0.2...1.4), warpCycles = Float(2 + Int(range(0...3.99))), warpPhase = range(0...twoPi)
        let wobbleAmp = range(0.1...0.7), wobbleCycles = Float(1 + Int(range(0...2.99))), wobblePhase = range(0...twoPi)
        let swellCycles = Float(1 + Int(range(0...2.99))), swellPhase = range(0...twoPi)
        let jitterCycles = range(7...19), jitterPhase = range(0...twoPi), finePhase = range(0...twoPi)
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
                    let swell = 0.7 + 0.3 * sin(twoPi * swellCycles * v + swellPhase)
                    let jitter = 0.75 + 0.25 * sin(twoPi * jitterCycles * v + jitterPhase)
                    let first = coarseAmp * jitter * cos(twoPi * (coarse * v + coarseTurns * u) + warp + wobble)
                    let second = fineAmp * cos(twoPi * (fine * v + fineTurns * u) + 1.7 * warp + finePhase)
                    tilt = min(max(swell * (first + second), -0.6), 0.6)
                }
                let n = simd_normalize(SIMD3<Float>(0, -tilt, 1))
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

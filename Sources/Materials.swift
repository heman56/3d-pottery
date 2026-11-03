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
enum Finish: CaseIterable, Identifiable, Hashable {
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

    /// 拉坯紋的法線貼圖：一圈圈水平的細紋（沿 v 方向起伏、沿 u 方向不變），
    /// 兩個不同頻率疊在一起，看起來不會太整齊。頻率取整數，v 從 0 到 1 剛好接得起來。
    /// 法線 = 高度的斜率換成顏色（0.5 代表不偏）；斜率直接寫成傾斜量（約 0.3 ≈ 17°），不隨頻率變大
    static func ridgeNormalImage() -> CGImage? {
        let width = 8, height = 1024
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let v = Float(y) / Float(height)
            let twoPi = 2 * Float.pi
            let tilt = 0.3 * cos(twoPi * 40 * v) + 0.18 * cos(twoPi * 103 * v + 1)
            let n = simd_normalize(SIMD3<Float>(0, -tilt, 1))
            for x in 0..<width {
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

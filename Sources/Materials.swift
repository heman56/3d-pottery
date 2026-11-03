import RealityKit
import Foundation
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
    /// 依釉色（color）、質感（finish）做出材質。texture 是花紋或照片，會和 color 相乘。
    /// PhysicallyBasedMaterial 是 struct，指定時會複製一份，所以下面每種質感都是在同一份基本設定上改幾個屬性
    static func make(color: PlatformColor, finish: Finish, wireframe: Bool, texture: TextureResource?) -> any Material {
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
        if let texture {
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
        material.metallic = .init(floatLiteral: 0)
        material.roughness = .init(floatLiteral: 0.95)

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
            material.emissiveIntensity = 2.0
        }
        if wireframe { material.triangleFillMode = .lines }
        return material
        #endif
    }
}

extension PlatformColor {
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

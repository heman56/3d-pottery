import RealityKit
import ImageIO
import Foundation

/// 環境光：用一張攝影棚的 HDRI（等距長方投影的環景照片）當作反射與打光的來源。
/// 教材 6-7c 是用 .skybox() 同時當背景；這裡只拿來當光，背景維持原本的米色
enum StudioLighting {
    static let resourceName = "brown_photostudio_03_1k"

    static func load() async -> EnvironmentResource? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "hdr") else { return nil }
        return await load(url: url)
    }

    static func load(url: URL) async -> EnvironmentResource? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return try? await EnvironmentResource(equirectangular: image, withName: "studio")
    }
}

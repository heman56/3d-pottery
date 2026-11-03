import UIKit
import simd

/// 把陶器匯出成 glTF 二進位（.glb），可以直接拖進 Blender。
/// 單位公尺、Y 軸朝上、逆時針為正面，和畫面上的座標一致；外側、內壁、內底是三個材質（三個 primitive）。
/// 材質對照：baseColor＝釉色×花紋貼圖，roughness／metallic 依質感，亮釉加 KHR_materials_clearcoat，
/// 發光用 emissive，琉璃用 alphaMode BLEND，拉坯紋是 normalTexture。
/// 和畫面不一樣的地方：glTF 的 v 軸朝下（貼圖左上是原點），所以 v 要換成 1 - v；顏色因子要轉成線性色彩空間
@MainActor
enum GLBExport {
    struct Input {
        var spec: VesselSpec
        var glaze: PotteryModel.Glaze
        var pattern: PotteryModel.Pattern
        var finish: Finish
        var ridges: Bool
        var photo: UIImage?
    }

    static func make(_ input: Input) -> Data? {
        let geometry = PotteryScene.makeGeometry(input.spec)
        var binary = BinaryBuilder()

        // 頂點屬性（三個 primitive 共用）
        // SIMD3<Float> 在記憶體裡佔 16 位元組（有補位），glTF 要緊密的 12 位元組，所以先攤平成 Float
        func flat(_ values: [SIMD3<Float>]) -> [Float] { values.flatMap { [$0.x, $0.y, $0.z] } }
        let flippedUVs = geometry.uvs.flatMap { [$0.x, 1 - $0.y] }
        let positionAccessor = binary.addAccessor(flat(geometry.positions), type: "VEC3", target: 34962, bounds: true)
        let normalAccessor = binary.addAccessor(flat(geometry.normals), type: "VEC3", target: 34962)
        let uvAccessor = binary.addAccessor(flippedUVs, type: "VEC2", target: 34962)

        // 貼圖
        var images: [[String: Any]] = []
        func addImage(_ cgImage: CGImage?) -> Int? {
            guard let cgImage, let png = UIImage(cgImage: cgImage).pngData() else { return nil }
            images.append(["bufferView": binary.addBytes(png, target: nil), "mimeType": "image/png"])
            return images.count - 1
        }
        let usePhoto = input.pattern == .photo && input.photo != nil
        let colorImage = addImage(usePhoto ? input.photo.flatMap(PotteryScene.photoImage) : PotteryScene.patternImage(input.pattern))
        let normalImage = input.ridges ? addImage(PotteryMaterial.ridgeNormalImage()) : nil
        // textures: 0 = 顏色，1 = 法線（沒有的就不存在）
        var textures: [[String: Any]] = []
        var colorTexture: Int?, normalTexture: Int?
        if let colorImage { textures.append(["source": colorImage, "sampler": 0]); colorTexture = textures.count - 1 }
        if let normalImage { textures.append(["source": normalImage, "sampler": 0]); normalTexture = textures.count - 1 }

        // 材質：0 外側、1 內壁、2 內底
        let glaze = input.glaze.color
        let outerColor = usePhoto ? UIColor.white : glaze
        let interiorColor = glaze.shaded(by: 0.5)
        var extensionsUsed: Set<String> = []
        func material(name: String, color: UIColor, finish: Finish, colorTexture: Int?, normalTexture: Int?) -> [String: Any] {
            var base: [String: Any] = ["baseColorFactor": linear(color, alpha: finish == .glass ? 0.45 : 1)]
            if let colorTexture { base["baseColorTexture"] = ["index": colorTexture] }
            var roughness = 0.95, metallic = 0.0
            var result: [String: Any] = ["name": name]
            var extensions: [String: Any] = [:]
            switch finish {
            case .matte: break
            case .glossy:
                roughness = 0.35
                extensions["KHR_materials_clearcoat"] = ["clearcoatFactor": 1.0, "clearcoatRoughnessFactor": 0.06]
            case .metallic:
                roughness = 0.28; metallic = 1
            case .glass:
                roughness = 0.08
                result["alphaMode"] = "BLEND"
                extensions["KHR_materials_clearcoat"] = ["clearcoatFactor": 1.0, "clearcoatRoughnessFactor": 0.03]
            case .glow:
                roughness = 0.6
                result["emissiveFactor"] = Array(linear(color, alpha: 1).prefix(3))
                if let colorTexture { result["emissiveTexture"] = ["index": colorTexture] }
                extensions["KHR_materials_emissive_strength"] = ["emissiveStrength": 2.0]
            }
            base["roughnessFactor"] = roughness
            base["metallicFactor"] = metallic
            result["pbrMetallicRoughness"] = base
            if let normalTexture { result["normalTexture"] = ["index": normalTexture] }
            if !extensions.isEmpty {
                result["extensions"] = extensions
                extensionsUsed.formUnion(extensions.keys)
            }
            return result
        }
        let materials = [
            material(name: "Glaze", color: outerColor, finish: input.finish, colorTexture: colorTexture, normalTexture: normalTexture),
            material(name: "Interior", color: interiorColor, finish: .matte, colorTexture: nil, normalTexture: normalTexture),
            material(name: "InteriorFloor", color: interiorColor, finish: .matte, colorTexture: nil, normalTexture: nil),
        ]

        // 依材質把三角形分組，每組一個 primitive
        var primitives: [[String: Any]] = []
        for materialIndex in 0..<3 {
            var indices: [UInt32] = []
            for face in 0..<geometry.faceMaterials.count where geometry.faceMaterials[face] == UInt32(materialIndex) {
                indices += geometry.indices[(3 * face)..<(3 * face + 3)]
            }
            guard !indices.isEmpty else { continue }
            let indexAccessor = binary.addAccessor(indices, type: "SCALAR", target: 34963)
            primitives.append([
                "attributes": ["POSITION": positionAccessor, "NORMAL": normalAccessor, "TEXCOORD_0": uvAccessor],
                "indices": indexAccessor,
                "material": materialIndex,
                "mode": 4,
            ])
        }

        var root: [String: Any] = [
            "asset": ["version": "2.0", "generator": "製陶大師"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["name": "Pottery", "mesh": 0]],
            "meshes": [["name": "Pottery", "primitives": primitives]],
            "materials": materials,
            "accessors": binary.accessors,
            "bufferViews": binary.bufferViews,
            "buffers": [["byteLength": binary.data.count]],
        ]
        if !images.isEmpty {
            root["images"] = images
            root["textures"] = textures
            // 10497 = REPEAT：照片拼貼的 UV 超過 0…1，要重複
            root["samplers"] = [["magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497]]
        }
        if !extensionsUsed.isEmpty { root["extensionsUsed"] = extensionsUsed.sorted() }

        guard var json = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return nil }
        while json.count % 4 != 0 { json.append(0x20) }
        var bin = binary.data
        while bin.count % 4 != 0 { bin.append(0) }

        var out = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        append(0x4654_6C67)                                   // "glTF"
        append(2)
        append(UInt32(12 + 8 + json.count + 8 + bin.count))
        append(UInt32(json.count)); append(0x4E4F_534A); out.append(json)   // JSON
        append(UInt32(bin.count)); append(0x004E_4942); out.append(bin)     // BIN
        return out
    }

    /// sRGB 的 UIColor → glTF 用的線性色彩 [r, g, b, a]
    private static func linear(_ color: UIColor, alpha: CGFloat) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func convert(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return [convert(r), convert(g), convert(b), Double(alpha)]
    }
}

/// 組 glb 的二進位區塊：每塊資料 4 位元組對齊，記下 bufferView 與 accessor 的 JSON
private struct BinaryBuilder {
    var data = Data()
    var bufferViews: [[String: Any]] = []
    var accessors: [[String: Any]] = []

    mutating func addBytes(_ bytes: Data, target: Int?) -> Int {
        while data.count % 4 != 0 { data.append(0) }
        var view: [String: Any] = ["buffer": 0, "byteOffset": data.count, "byteLength": bytes.count]
        if let target { view["target"] = target }
        data.append(bytes)
        bufferViews.append(view)
        return bufferViews.count - 1
    }

    /// values 是攤平的數值（Float 或 UInt32）；type 決定幾個一組
    mutating func addAccessor<T>(_ values: [T], type: String, target: Int, bounds: Bool = false) -> Int {
        let components = ["SCALAR": 1, "VEC2": 2, "VEC3": 3][type] ?? 1
        let bytes = values.withUnsafeBytes { Data($0) }
        let view = addBytes(bytes, target: target)
        var accessor: [String: Any] = ["bufferView": view, "componentType": T.self == UInt32.self ? 5125 : 5126,
                                       "count": values.count / components, "type": type]
        if bounds, let floats = values as? [Float], components == 3, floats.count >= 3 {
            var low = [floats[0], floats[1], floats[2]], high = low
            for i in stride(from: 0, to: floats.count, by: 3) {
                for k in 0..<3 { low[k] = min(low[k], floats[i + k]); high[k] = max(high[k], floats[i + k]) }
            }
            accessor["min"] = low
            accessor["max"] = high
        }
        accessors.append(accessor)
        return accessors.count - 1
    }
}

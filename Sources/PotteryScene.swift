import SwiftUI
import RealityKit

/// 3D 場景：轉盤、陶器、相機與燈光
@MainActor
final class PotteryScene {
    let root = Entity()
    private let turntable = Entity()
    private let pot = ModelEntity()
    private let base = ModelEntity()
    private var material: any RealityKit.Material = PotteryScene.makeMaterial(color: .brown, roughness: 0.9)
    private var spin: EventSubscription?
    private var content: RealityViewCameraContent?

    private var pending: [Float]?
    private var isBuilding = false

    private static let baseThickness: Float = 0.012

    init() {
        // 背景（iOS 的 RealityView 不能直接設背景色）
        let backdrop = ModelEntity(
            mesh: .generatePlane(width: 6, height: 4),
            materials: [UnlitMaterial(color: UIColor(red: 0.98, green: 0.92, blue: 0.80, alpha: 1))]
        )
        backdrop.position = [0, 0.5, -0.8]
        root.addChild(backdrop)

        // 轉盤
        let disc = ModelEntity(
            mesh: .generateCylinder(height: 0.03, radius: 0.28),
            materials: [Self.makeMaterial(color: UIColor(white: 0.35, alpha: 1), roughness: 0.6)]
        )
        disc.position.y = -0.015
        turntable.addChild(disc)

        // 擠出的方向是 Z 軸，轉成朝上（Y 軸）
        pot.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        turntable.addChild(pot)
        turntable.addChild(base)
        root.addChild(turntable)

        let camera = PerspectiveCamera()
        camera.look(at: [0, 0.14, 0], from: [0, 0.3, 0.85], relativeTo: nil)
        root.addChild(camera)

        #if !targetEnvironment(simulator)
        let sun = DirectionalLight()
        sun.light.intensity = 3000
        sun.look(at: .zero, from: [0.5, 1, 1], relativeTo: nil)
        root.addChild(sun)

        let fill = PointLight()
        fill.light.intensity = 60000
        fill.position = [-0.6, 0.4, 0.6]
        root.addChild(fill)
        #endif
    }

    /// 模擬器（Intel Mac）的 RealityKit 編譯 PBR 材質會當機，模擬器上改用無光照材質
    static func makeMaterial(color: UIColor, roughness: Float) -> any RealityKit.Material {
        #if targetEnvironment(simulator)
        UnlitMaterial(color: color)
        #else
        SimpleMaterial(color: color, roughness: .float(roughness), isMetallic: false)
        #endif
    }

    /// 手指位置 → 陶器剖面（z=0 平面）上的 x、y 座標（公尺）
    func profilePoint(at point: CGPoint) -> SIMD3<Float>? {
        // unproject 的平面是變換後的 X-Z 平面，轉 90° 讓它變成 X-Y 平面
        let plane = Transform(rotation: simd_quatf(angle: .pi / 2, axis: [1, 0, 0])).matrix
        return content?.unproject(point, from: .local, to: .scene, ontoPlane: plane)
    }

    func startSpinning(in content: RealityViewCameraContent) {
        self.content = content
        spin = content.subscribe(to: SceneEvents.Update.self) { [turntable] event in
            let step = simd_quatf(angle: Float(event.deltaTime) * 1.2, axis: [0, 1, 0])
            turntable.orientation = step * turntable.orientation
        }
    }

    func setGlaze(_ glaze: PotteryModel.Glaze) {
        material = Self.makeMaterial(color: glaze.color, roughness: glaze.roughness)
        pot.model?.materials = [material]
        base.model?.materials = [material]
    }

    /// 重新擠出陶器。連續拖曳時只保留最新的一份，避免排隊
    func rebuild(radii: [Float]) async {
        pending = radii
        guard !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }

        while let next = pending {
            pending = nil
            guard let mesh = try? await Self.makeVessel(radii: next) else { continue }
            pot.model = ModelComponent(mesh: mesh, materials: [material])
            let bottom = MeshResource.generateCylinder(height: Self.baseThickness, radius: next[0])
            base.model = ModelComponent(mesh: bottom, materials: [material])
            base.position.y = Self.baseThickness / 2
        }
    }

    /// 擠出成型：同心圓(空心)沿 Z 軸一層層串起來，每層用縮放決定半徑
    private static func makeVessel(radii: [Float]) async throws -> MeshResource {
        let wall: CGFloat = 0.88   // 內圓半徑 / 外圓半徑
        var shape = Path()
        shape.addEllipse(in: CGRect(x: -1, y: -1, width: 2, height: 2))
        shape.addEllipse(in: CGRect(x: -wall, y: -wall, width: 2 * wall, height: 2 * wall))

        let n = radii.count
        let matrices = (0..<n).map { i -> simd_float4x4 in
            let z = Float(i) / Float(n - 1) * PotteryModel.height
            return Transform(scale: [radii[i], radii[i], 1], translation: [0, 0, z]).matrix
        }
        var options = MeshResource.ShapeExtrusionOptions()
        options.extrusionMethod = .traceTransforms(matrices)
        return try await MeshResource(extruding: shape, extrusionOptions: options)
    }
}

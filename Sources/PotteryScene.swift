import SwiftUI
import RealityKit

/// 3D 場景：轉盤、陶器、相機與燈光
@MainActor
final class PotteryScene {
    let root = Entity()
    private let turntable = Entity()
    private let pot = ModelEntity()
    private let base = ModelEntity()
    private var material: any RealityKit.Material = PotteryScene.makeMaterial(color: .brown, glazed: false)
    private var spin: EventSubscription?
    private var content: RealityViewCameraContent?

    private var pending: [Float]?
    private var isBuilding = false

    private static let baseThickness: Float = 0.012
    private static let wall: Float = 0.88   // 內圓半徑 / 外圓半徑

    /// 只在模擬器使用（見 rebuild）
    private let cavity = ModelEntity()
    private var cavityMaterial = UnlitMaterial(color: UIColor.black)

    init() {
        // 背景（iOS 的 RealityView 不能直接設背景色）
        let backdrop = ModelEntity(
            mesh: .generatePlane(width: 12, height: 12),
            materials: [UnlitMaterial(color: UIColor(red: 0.98, green: 0.92, blue: 0.80, alpha: 1))]
        )
        backdrop.position = [0, 0, -0.8]
        root.addChild(backdrop)

        // 轉盤
        let disc = ModelEntity(
            mesh: .generateCylinder(height: 0.03, radius: 0.28),
            materials: [Self.makeMaterial(color: UIColor(white: 0.35, alpha: 1), glazed: false)]
        )
        disc.position.y = -0.015
        turntable.addChild(disc)

        // 擠出的方向是 Z 軸，轉成朝上（Y 軸）
        pot.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        turntable.addChild(pot)
        turntable.addChild(base)
        root.addChild(turntable)

        // 相機抬高、往下看，才看得到碗與花瓶的內側
        let camera = PerspectiveCamera()
        camera.look(at: [0, 0.1, 0], from: [0, 0.55, 0.8], relativeTo: nil)
        root.addChild(camera)

        #if targetEnvironment(simulator)
        cavity.position.y = PotteryModel.height - 0.002
        turntable.addChild(cavity)
        #else
        // 主光：從右上前方打來，產生柔和的陰影
        let sun = DirectionalLight()
        sun.light.intensity = 2500
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 2, depthBias: 2)
        sun.look(at: [0, 0.1, 0], from: [0.6, 1.2, 0.8], relativeTo: nil)
        root.addChild(sun)

        // 補光：從左側照亮暗部，避免陰影太黑
        let fill = DirectionalLight()
        fill.light.intensity = 900
        fill.look(at: [0, 0.1, 0], from: [-0.8, 0.5, 0.6], relativeTo: nil)
        root.addChild(fill)
        #endif
    }

    /// 模擬器（Intel Mac）的 RealityKit 編譯 PBR 材質會當機，模擬器上改用無光照材質。
    /// 真機：未上釉的陶土粗糙無光；上釉後有透明的亮面塗層，會反光
    static func makeMaterial(color: UIColor, glazed: Bool) -> any RealityKit.Material {
        #if targetEnvironment(simulator)
        UnlitMaterial(color: color)
        #else
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.metallic = .init(floatLiteral: 0)
        material.roughness = .init(floatLiteral: glazed ? 0.35 : 0.95)
        if glazed {
            material.clearcoat = .init(floatLiteral: 1)
            material.clearcoatRoughness = .init(floatLiteral: 0.06)
            material.specular = .init(floatLiteral: 0.7)
        }
        return material
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
        material = Self.makeMaterial(color: glaze.color, glazed: glaze.isGlazed)
        pot.model?.materials = [material]
        base.model?.materials = [material]
        cavityMaterial = UnlitMaterial(color: glaze.color.shaded(by: 0.45))
        cavity.model?.materials = [cavityMaterial]
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

            #if targetEnvironment(simulator)
            // 模擬器沒有光影，用一片深色圓盤假裝容器開口的陰暗內側
            let opening = next[next.count - 1] * Self.wall * 0.98
            cavity.model = ModelComponent(
                mesh: .generateCylinder(height: 0.0005, radius: opening),
                materials: [cavityMaterial]
            )
            #endif
        }
    }

    /// 擠出成型：同心圓(空心)沿 Z 軸一層層串起來，每層用縮放決定半徑
    private static func makeVessel(radii: [Float]) async throws -> MeshResource {
        let wall = CGFloat(Self.wall)
        // 外圓與內圓繞行方向相反，不論用哪種填色規則，中間都會是空的
        var shape = Path()
        shape.addArc(center: .zero, radius: 1, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        shape.addArc(center: .zero, radius: wall, startAngle: .zero, endAngle: .degrees(360), clockwise: true)

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

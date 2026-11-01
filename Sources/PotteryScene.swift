import SwiftUI
import RealityKit

/// 3D 場景：轉盤、陶器、相機與燈光
@MainActor
final class PotteryScene {
    let root = Entity()
    private let turntable = Entity()
    private let pot = ModelEntity()
    private let base = ModelEntity()
    private let camera = PerspectiveCamera()
    /// 永遠面向相機的背景（iOS 的 RealityView 不能直接設背景色）
    private let backdrop = ModelEntity(
        mesh: .generatePlane(width: 12, height: 12),
        materials: [UnlitMaterial(color: UIColor(red: 0.98, green: 0.92, blue: 0.80, alpha: 1))]
    )

    private var glaze = PotteryModel.Glaze.clay
    private var wireframe = false
    private var material: any RealityKit.Material = PotteryScene.makeMaterial(color: .brown, glazed: false, wireframe: false)
    private var spin: EventSubscription?
    private var content: RealityViewCameraContent?

    /// 目前畫面上的相機姿態會慢慢追上目標姿態，轉視角時有滑順的動畫
    private var currentPose = CameraPose.start
    private var targetPose = CameraPose.start

    private var pending: [Float]?
    private var isBuilding = false

    private static let baseThickness: Float = 0.012
    private static let wall: Float = 0.88   // 內圓半徑 / 外圓半徑
    private static let lookAt: SIMD3<Float> = [0, 0.12, 0]

    /// 只在模擬器使用（見 rebuild）
    private let cavity = ModelEntity()
    private var cavityMaterial = UnlitMaterial(color: UIColor.black)

    init() {
        root.addChild(backdrop)

        // 轉盤
        let disc = ModelEntity(
            mesh: .generateCylinder(height: 0.03, radius: 0.28),
            materials: [Self.makeMaterial(color: UIColor(white: 0.72, alpha: 1), glazed: false, wireframe: false)]
        )
        disc.position.y = -0.015
        turntable.addChild(disc)

        // 擠出的方向是 Z 軸，轉成朝上（Y 軸）
        pot.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        turntable.addChild(pot)
        turntable.addChild(base)
        root.addChild(turntable)

        root.addChild(camera)
        applyCamera()

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
    static func makeMaterial(color: UIColor, glazed: Bool, wireframe: Bool) -> any RealityKit.Material {
        #if targetEnvironment(simulator)
        var material = UnlitMaterial(color: color)
        if wireframe { material.triangleFillMode = .lines }
        return material
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
        if wireframe { material.triangleFillMode = .lines }
        return material
        #endif
    }

    // MARK: 相機

    func setCamera(_ pose: CameraPose) {
        targetPose = pose
    }

    /// 以螢幕的短邊為準固定視角，直立的 iPhone 與橫放的 iPad 看到的陶器大小才差不多
    func setViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        camera.camera.fieldOfViewOrientation = size.width < size.height ? .horizontal : .vertical
        camera.camera.fieldOfViewInDegrees = 44
    }

    /// 手指位置 → 陶器剖面上的 x、y、z 座標（公尺）。
    /// 剖面是通過轉軸、面向相機的垂直平面，所以從任何水平角度都能塑形
    func profilePoint(at point: CGPoint) -> SIMD3<Float>? {
        // unproject 的平面是變換後的 X-Z 平面：先轉 90° 變成 X-Y 平面，再依相機水平角轉向相機
        let facing = simd_quatf(angle: currentPose.yaw, axis: [0, 1, 0]) * simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        return content?.unproject(point, from: .local, to: .scene, ontoPlane: Transform(rotation: facing).matrix)
    }

    /// 目前的相機是不是太陡（從正上方看），陡到無法塑形
    var isTooSteepToSculpt: Bool { currentPose.pitch > 1.2 }

    private func applyCamera() {
        let pose = currentPose
        let direction = SIMD3<Float>(sin(pose.yaw) * cos(pose.pitch), sin(pose.pitch), cos(pose.yaw) * cos(pose.pitch))
        camera.look(at: Self.lookAt, from: Self.lookAt + direction * pose.distance, relativeTo: nil)

        let backdropPosition = Self.lookAt - direction * 1.8
        backdrop.look(at: backdropPosition - direction, from: backdropPosition, relativeTo: nil)
    }

    private func tick(_ dt: Float) {
        turntable.orientation = simd_quatf(angle: dt * 1.2, axis: [0, 1, 0]) * turntable.orientation

        let k = min(1, dt * 10)
        currentPose.yaw += (targetPose.yaw - currentPose.yaw) * k
        currentPose.pitch += (targetPose.pitch - currentPose.pitch) * k
        currentPose.distance += (targetPose.distance - currentPose.distance) * k
        applyCamera()
    }

    func start(in content: RealityViewCameraContent) {
        self.content = content
        spin = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.tick(Float(event.deltaTime)) }
        }
    }

    // MARK: 外觀

    func setGlaze(_ glaze: PotteryModel.Glaze) {
        self.glaze = glaze
        refreshMaterials()
    }

    func setWireframe(_ on: Bool) {
        wireframe = on
        refreshMaterials()
    }

    private func refreshMaterials() {
        // 線框用較深的顏色，才不會和米色背景混在一起
        let color = wireframe ? glaze.color.shaded(by: 0.55) : glaze.color
        material = Self.makeMaterial(color: color, glazed: glaze.isGlazed, wireframe: wireframe)
        pot.model?.materials = [material]
        base.model?.materials = [material]

        cavityMaterial = UnlitMaterial(color: glaze.color.shaded(by: 0.45))
        cavity.model?.materials = [cavityMaterial]
        cavity.isEnabled = !wireframe
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

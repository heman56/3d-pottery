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

    private var pending: VesselSpec?
    private var isBuilding = false

    private static let baseThickness: Float = 0.012
    private static let wall: Float = 0.88   // 內框 / 外框 的大小比例
    private static let lookAt: SIMD3<Float> = [0, 0.12, 0]

    /// 只在模擬器使用（見 rebuild）
    private let cavity = ModelEntity()
    private var cavityMaterial = UnlitMaterial(color: UIColor.black)

    init() {
        root.addChild(backdrop)

        // 轉盤
        let disc = ModelEntity(
            mesh: .generateCylinder(height: 0.03, radius: 0.34),
            materials: [Self.makeMaterial(color: UIColor(white: 0.72, alpha: 1), glazed: false, wireframe: false)]
        )
        disc.position.y = -0.015
        turntable.addChild(disc)

        // 擠出的方向是 Z 軸，轉成朝上（Y 軸）
        pot.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        turntable.addChild(pot)
        pot.addChild(base)   // 底板和陶器共用同一個「Z 軸朝上」的座標
        base.position.z = Self.baseThickness / 2   // 線性擠出是以原點為中心，上移後底面剛好貼在轉盤上
        root.addChild(turntable)

        root.addChild(camera)
        applyCamera()

        #if targetEnvironment(simulator)
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
    func rebuild(_ spec: VesselSpec) async {
        pending = spec
        guard !isBuilding else { return }
        isBuilding = true
        defer { isBuilding = false }

        while let next = pending {
            pending = nil
            guard let mesh = try? await Self.makeVessel(next) else { continue }
            pot.model = ModelComponent(mesh: mesh, materials: [material])

            if let bottom = try? await Self.makeBase(next) {
                base.model = ModelComponent(mesh: bottom, materials: [material])
            }

            #if targetEnvironment(simulator)
            // 模擬器沒有光影，用一片深色的同形狀薄片假裝容器開口的陰暗內側
            if let cap = Self.makeCap(next) {
                cavity.model = ModelComponent(mesh: cap, materials: [cavityMaterial])
            }
            #endif
        }
    }

    // MARK: 幾何

    /// 第 k 個頂點的角度。圓（sides = 0）取 count 個點；
    /// 多邊形讓底邊朝下、三角形尖角朝上，四方形的邊與座標軸平行
    private static func vertexAngle(_ k: Int, sides: Int, count: Int) -> Double {
        let n = Double(count)
        if sides == 0 { return 2 * .pi * Double(k) / n }
        return 2 * .pi * Double(k) / n + .pi / n - .pi / 2
    }

    /// 以「外接圓半徑」為準的底面輪廓；reversed 代表反向繞行，用來挖出空心
    private static func outline(sides: Int, radius: CGFloat, reversed: Bool) -> Path {
        var path = Path()
        if sides == 0 {
            path.addArc(center: .zero, radius: radius, startAngle: .zero, endAngle: .degrees(360), clockwise: reversed)
            return path
        }
        let points = (0..<sides).map { k -> CGPoint in
            let a = vertexAngle(k, sides: sides, count: sides)
            return CGPoint(x: radius * cos(a), y: radius * sin(a))
        }
        path.addLines(reversed ? points.reversed() : points)
        path.closeSubpath()
        return path
    }

    /// 擠出成型：外框與內框（反向繞行，所以中間是空的）沿 Z 軸一層層串起來，
    /// 每層用位移決定高度、縮放決定半徑、繞 Z 軸旋轉決定扭轉
    private static func makeVessel(_ spec: VesselSpec) async throws -> MeshResource {
        var shape = outline(sides: spec.sides, radius: 1, reversed: false)
        shape.addPath(outline(sides: spec.sides, radius: CGFloat(wall), reversed: true))

        let n = spec.radii.count
        let matrices = (0..<n).map { i -> simd_float4x4 in
            let t = Float(i) / Float(n - 1)
            return Transform(
                scale: [spec.radii[i], spec.radii[i], 1],
                rotation: simd_quatf(angle: spec.twist * t, axis: [0, 0, 1]),
                translation: [0, 0, t * PotteryModel.height]
            ).matrix
        }
        var options = MeshResource.ShapeExtrusionOptions()
        options.extrusionMethod = .traceTransforms(matrices)
        return try await MeshResource(extruding: shape, extrusionOptions: options)
    }

    /// 封住底部的薄板（形狀與最底層相同）
    private static func makeBase(_ spec: VesselSpec) async throws -> MeshResource {
        var options = MeshResource.ShapeExtrusionOptions()
        options.extrusionMethod = .linear(depth: baseThickness)
        let path = outline(sides: spec.sides, radius: CGFloat(spec.radii[0]), reversed: false)
        return try await MeshResource(extruding: path, extrusionOptions: options)
    }

    /// 模擬器專用：蓋在開口上的深色薄片（世界座標，已含頂層的扭轉角度）
    private static func makeCap(_ spec: VesselSpec) -> MeshResource? {
        let count = spec.sides == 0 ? 48 : spec.sides
        let radius = spec.radii[spec.radii.count - 1] * wall * 0.98
        let y = PotteryModel.height - 0.002
        var positions: [SIMD3<Float>] = [[0, y, 0]]
        var indices: [UInt32] = []
        for k in 0..<count {
            // 陶器節點繞 X 軸轉了 -90°，所以局部的 (x, y) 對應世界的 (x, -z)
            let a = Float(vertexAngle(k, sides: spec.sides, count: count)) + spec.twist
            positions.append([radius * cos(a), y, -radius * sin(a)])
            indices += [0, UInt32(1 + k), UInt32(1 + (k + 1) % count)]
        }
        var descriptor = MeshDescriptor(name: "cap")
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }
}

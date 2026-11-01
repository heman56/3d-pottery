import SwiftUI
import RealityKit

/// 3D 場景：轉盤、陶器、相機與燈光
@MainActor
final class PotteryScene {
    let root = Entity()
    private let turntable = Entity()
    private let pot = ModelEntity()
    private let camera = PerspectiveCamera()
    /// 永遠面向相機的背景（iOS 的 RealityView 不能直接設背景色）
    private let backdrop = ModelEntity(
        mesh: .generatePlane(width: 12, height: 12),
        materials: [UnlitMaterial(color: UIColor(red: 0.98, green: 0.92, blue: 0.80, alpha: 1))]
    )

    private var glaze = PotteryModel.Glaze.clay
    private var pattern = PotteryModel.Pattern.stripes
    private var wireframe = false
    private var material: any RealityKit.Material = PotteryScene.makeMaterial(color: .brown, glazed: false, wireframe: false, texture: nil)
    private var textures: [PotteryModel.Pattern: TextureResource] = [:]
    private var spin: EventSubscription?
    private var content: RealityViewCameraContent?

    /// 目前畫面上的相機姿態會慢慢追上目標姿態，轉視角時有滑順的動畫
    private var currentPose = CameraPose.start
    private var targetPose = CameraPose.start

    /// 垂直視角（弧度）、畫面高度，以及標題與控制面板各蓋住的高度，用來把陶器移到可視區域的正中央
    private var verticalFov: Float = 44 * .pi / 180
    private var viewHeight: Float = 0
    private var topInset: Float = 0
    private var bottomInset: Float = 0

    private static let baseThickness: Float = 0.012
    private static let wall: Float = 0.88   // 內壁 / 外壁 的大小比例
    private static let lookAt: SIMD3<Float> = [0, 0.12, 0]

    /// 只在模擬器使用（見 rebuild）
    private let cavity = ModelEntity()
    private var cavityMaterial = UnlitMaterial(color: UIColor.black)

    init() {
        root.addChild(backdrop)

        // 轉盤
        let disc = ModelEntity(
            mesh: .generateCylinder(height: 0.03, radius: 0.34),
            materials: [Self.makeMaterial(color: UIColor(white: 0.72, alpha: 1), glazed: false, wireframe: false, texture: nil)]
        )
        disc.position.y = -0.015
        turntable.addChild(disc)

        turntable.addChild(pot)
        root.addChild(turntable)

        for pattern in PotteryModel.Pattern.allCases {
            if let image = Self.patternImage(pattern),
               let texture = try? TextureResource.generate(from: image, options: .init(semantic: .color)) {
                textures[pattern] = texture
            }
        }

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
    static func makeMaterial(color: UIColor, glazed: Bool, wireframe: Bool, texture: TextureResource?) -> any RealityKit.Material {
        #if targetEnvironment(simulator)
        var material = UnlitMaterial(color: color)
        if let texture { material.color = .init(tint: color, texture: .init(texture)) }
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

    /// 以螢幕的短邊為準固定視角（44°），直立的 iPhone 與橫放的 iPad 看到的陶器大小才差不多。
    /// 一律用「垂直」視角，由長寬比換算：unproject（手指位置轉成 3D 座標）只認垂直視角，
    /// 若改用水平視角，畫面和手勢會對不上，手指點到的半徑會偏小
    func setViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let shortSide: Float = 44 * .pi / 180
        let aspect = Float(size.height / size.width)   // 直立時 > 1
        let vertical = size.width < size.height ? 2 * atan(tan(shortSide / 2) * aspect) : shortSide
        camera.camera.fieldOfViewOrientation = .vertical
        camera.camera.fieldOfViewInDegrees = vertical * 180 / .pi
        verticalFov = vertical
        viewHeight = Float(size.height)
    }

    /// 畫面上方（標題）與下方（控制面板）各蓋住多少點。面板比標題高時，陶器要往上移
    func setInsets(top: CGFloat, bottom: CGFloat) {
        topInset = Float(top)
        bottomInset = Float(bottom)
    }

    /// 手指位置 → 陶器剖面上的 x、y、z 座標（公尺）。
    /// 剖面是通過轉軸、面向相機的垂直平面，所以從任何水平角度都能塑形。
    /// towardCamera：把平面往相機方向平移的距離。畫面上看到的陶器外緣是圓柱的切點，
    /// 位在轉軸平面前方約 r²/D 處，相機俯視時不修正，高度會差約一公分
    func profilePoint(at point: CGPoint, towardCamera offset: Float = 0) -> SIMD3<Float>? {
        // unproject 的平面是變換後的 X-Z 平面：先轉 90° 變成 X-Y 平面，再依相機水平角轉向相機
        let facing = simd_quatf(angle: currentPose.yaw, axis: [0, 1, 0]) * simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        let toward = SIMD3<Float>(sin(currentPose.yaw), 0, cos(currentPose.yaw)) * offset
        return content?.unproject(point, from: .local, to: .scene, ontoPlane: Transform(rotation: facing, translation: toward).matrix)
    }

    /// 相機看一根半徑 r 的圓柱時，外緣切點在轉軸平面前方多遠
    func tangentDepth(radius r: Float) -> Float {
        let horizontalDistance = max(currentPose.distance * cos(currentPose.pitch), r * 1.01)
        return r * r / horizontalDistance
    }

    /// 目前的相機是不是太陡（從正上方看），陡到無法塑形
    var isTooSteepToSculpt: Bool { currentPose.pitch > 1.2 }

    private func applyCamera() {
        let pose = currentPose
        let direction = SIMD3<Float>(sin(pose.yaw) * cos(pose.pitch), sin(pose.pitch), cos(pose.yaw) * cos(pose.pitch))
        var target = Self.lookAt
        var position = Self.lookAt + direction * pose.distance

        // 相機與觀看目標一起沿相機的「上」方向平移：畫面上的陶器就整個移動，透視與手勢對應都不受影響
        let forward = simd_normalize(target - position)
        let right = simd_cross(forward, [0, 1, 0])
        if viewHeight > 0, simd_length(right) > 1e-4 {
            let up = simd_cross(simd_normalize(right), forward)
            let fraction = (bottomInset - topInset) / (2 * viewHeight)
            let shift = fraction * 2 * pose.distance * tan(verticalFov / 2)
            target -= up * shift
            position -= up * shift
        }
        camera.look(at: target, from: position, relativeTo: nil)

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

    func setPattern(_ pattern: PotteryModel.Pattern) {
        self.pattern = pattern
        refreshMaterials()
    }

    func setWireframe(_ on: Bool) {
        wireframe = on
        refreshMaterials()
    }

    private func refreshMaterials() {
        // 線框用較深的顏色，才不會和米色背景混在一起
        let color = wireframe ? glaze.color.shaded(by: 0.55) : glaze.color
        material = Self.makeMaterial(color: color, glazed: glaze.isGlazed, wireframe: wireframe,
                                     texture: wireframe ? nil : textures[pattern])
        pot.model?.materials = [material]

        cavityMaterial = UnlitMaterial(color: glaze.color.shaded(by: 0.45))
        cavity.model?.materials = [cavityMaterial]
        cavity.isEnabled = !wireframe
    }

    /// 重新產生陶器網格。連續拖曳時只保留最新的一份，避免排隊
    func rebuild(_ spec: VesselSpec) {
        guard let mesh = Self.makeVessel(spec) else { return }
        pot.model = ModelComponent(mesh: mesh, materials: [material])

        #if targetEnvironment(simulator)
        // 模擬器沒有光影，用一片深色的同形狀薄片假裝容器開口的陰暗內側
        if let cap = Self.makeCap(spec) {
            cavity.model = ModelComponent(mesh: cap, materials: [cavityMaterial])
        }
        #endif
    }

    // MARK: 幾何

    /// 第 k 個頂點的角度。圓（sides = 0）取 count 個點；
    /// 多邊形讓底邊朝下、三角形尖角朝上，四方形的邊與座標軸平行
    private static func vertexAngle(_ k: Int, sides: Int, count: Int) -> Double {
        let n = Double(count)
        if sides == 0 { return 2 * .pi * Double(k) / n }
        return 2 * .pi * Double(k) / n + .pi / n - .pi / 2
    }

    /// 底面輪廓上的「直線」（欄）：每欄是一條從底到口的頂點線，相鄰的欄之間成一片牆。
    /// 圓：65 欄，欄與欄共用（最後一欄與第一欄位置相同，但 u 是 1 與 0，所以貼圖接縫不會被拉伸）；
    /// 多邊形：每個面各自 2 欄，頂點不共用，所以每個面有自己的法線（平面）；
    /// 每個面只用貼圖的一小段 u（約 16 / 邊數 格），格子才不會被拉成細長條
    private struct Column {
        var angle: Float
        var u: Float
    }

    private static func columns(sides: Int) -> (columns: [Column], strips: [(Int, Int)]) {
        if sides == 0 {
            let segments = 64
            let columns = (0...segments).map {
                Column(angle: 2 * .pi * Float($0) / Float(segments), u: Float($0) / Float(segments))
            }
            return (columns, (0..<segments).map { ($0, $0 + 1) })
        }
        var columns: [Column] = []
        var strips: [(Int, Int)] = []
        let cellsPerFace = max(1, Int((16 / Double(sides)).rounded()))
        let faceU = Float(cellsPerFace) / 16
        for f in 0..<sides {
            columns.append(Column(angle: Float(vertexAngle(f, sides: sides, count: sides)), u: 0))
            columns.append(Column(angle: Float(vertexAngle(f + 1, sides: sides, count: sides)), u: faceU))
            strips.append((2 * f, 2 * f + 1))
        }
        return (columns, strips)
    }

    /// 用 MeshDescriptor 自己組出整件陶器：外壁、內壁、口沿、外底面、內底面。
    /// 頂點、法線、UV 三個陣列必須一一對應（多一筆或少一筆，整個網格就會消失）。
    /// 座標：Y 軸朝上，高度 0 在轉盤上；半徑是外接圓半徑；每層依扭轉角度繞 Y 軸轉
    private static func makeVessel(_ spec: VesselSpec) -> MeshResource? {
        let layers = spec.radii.count
        let height = PotteryModel.height
        let (columns, strips) = columns(sides: spec.sides)

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        func point(_ column: Int, _ layer: Int, scale: Float) -> SIMD3<Float> {
            let t = Float(layer) / Float(layers - 1)
            let angle = columns[column].angle + spec.twist * t
            let r = spec.radii[layer] * scale
            // 與先前的擠出做法相同：局部的 (x, y) 對應世界的 (x, -z)
            return [r * cos(angle), t * height, -r * sin(angle)]
        }

        /// 三角形的順序依「想朝向的方向」自動決定（逆時針為正面）
        func addTriangle(_ a: Int, _ b: Int, _ c: Int, facing n: SIMD3<Float>) {
            let g = cross(positions[b] - positions[a], positions[c] - positions[a])
            if dot(g, n) >= 0 {
                indices += [UInt32(a), UInt32(b), UInt32(c)]
            } else {
                indices += [UInt32(a), UInt32(c), UInt32(b)]
            }
        }

        /// 一面牆（外壁或內壁）：每個頂點的法線由相鄰頂點的差分算出，朝外壁的外側或內壁的軸心側
        func addWall(scale: Float, facingOutward: Bool) {
            let first = positions.count
            func index(_ column: Int, _ layer: Int) -> Int { first + column * layers + layer }

            for c in columns.indices {
                for i in 0..<layers {
                    let p = point(c, i, scale: scale)
                    let along = point(c, min(i + 1, layers - 1), scale: scale) - point(c, max(i - 1, 0), scale: scale)
                    let around: SIMD3<Float>
                    if spec.sides == 0 {
                        around = point(min(c + 1, columns.count - 1), i, scale: scale) - point(max(c - 1, 0), i, scale: scale)
                    } else {
                        let face = c / 2
                        around = point(2 * face + 1, i, scale: scale) - point(2 * face, i, scale: scale)
                    }
                    var n = cross(around, along)
                    let length = simd_length(n)
                    n = length > 1e-9 ? n / length : [0, 0, 1]
                    let radial = SIMD3<Float>(p.x, 0, p.z)
                    if (dot(n, radial) >= 0) != facingOutward { n = -n }
                    positions.append(p)
                    normals.append(n)
                    uvs.append([columns[c].u, Float(i) / Float(layers - 1)])
                }
            }
            for (c0, c1) in strips {
                for i in 0..<(layers - 1) {
                    let a = index(c0, i), b = index(c1, i), c = index(c1, i + 1), d = index(c0, i + 1)
                    addTriangle(a, b, c, facing: normals[a])
                    addTriangle(a, c, d, facing: normals[a])
                }
            }
        }

        addWall(scale: 1, facingOutward: true)
        addWall(scale: wall, facingOutward: false)

        // 口沿：頂層外壁與內壁之間的一圈平面，朝上
        for (c0, c1) in strips {
            let top = layers - 1
            let corners = [
                point(c0, top, scale: 1), point(c1, top, scale: 1),
                point(c1, top, scale: wall), point(c0, top, scale: wall),
            ]
            let first = positions.count
            for corner in corners {
                positions.append(corner)
                normals.append([0, 1, 0])
                uvs.append([(columns[c0].u + columns[c1].u) / 2, 1])
            }
            addTriangle(first, first + 1, first + 2, facing: [0, 1, 0])
            addTriangle(first, first + 2, first + 3, facing: [0, 1, 0])
        }

        /// 平面的一圈（外底面朝下、內底面朝上）：以中心點為扇形的頂點，UV 用俯視的位置
        func addDisc(scale: Float, y: Float, facing: SIMD3<Float>) {
            let first = positions.count
            let extent = max(spec.radii[0] * scale, 0.001)
            positions.append([0, y, 0])
            normals.append(facing)
            uvs.append([0.5, 0.5])
            for c in columns.indices {
                var p = point(c, 0, scale: scale)
                p.y = y
                positions.append(p)
                normals.append(facing)
                uvs.append([0.5 + 0.5 * p.x / extent, 0.5 + 0.5 * p.z / extent])
            }
            for (c0, c1) in strips {
                addTriangle(first, first + 1 + c0, first + 1 + c1, facing: facing)
            }
        }

        addDisc(scale: 1, y: 0, facing: [0, -1, 0])
        addDisc(scale: wall * 0.999, y: baseThickness, facing: [0, 1, 0])

        var descriptor = MeshDescriptor(name: "pot")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// 模擬器專用：蓋在開口上的深色薄片（世界座標，已含頂層的扭轉角度）
    private static func makeCap(_ spec: VesselSpec) -> MeshResource? {
        let count = spec.sides == 0 ? 48 : spec.sides
        let radius = spec.radii[spec.radii.count - 1] * wall * 0.98
        let y = PotteryModel.height - 0.002
        var positions: [SIMD3<Float>] = [[0, y, 0]]
        var indices: [UInt32] = []
        for k in 0..<count {
            let a = Float(vertexAngle(k, sides: spec.sides, count: count)) + spec.twist
            positions.append([radius * cos(a), y, -radius * sin(a)])
            indices += [0, UInt32(1 + k), UInt32(1 + (k + 1) % count)]
        }
        var descriptor = MeshDescriptor(name: "cap")
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    // MARK: 花紋貼圖

    /// 程式畫出的貼圖：白底、灰色圖案，之後乘上釉色。
    /// 貼圖橫向對應繞陶器一圈（u），縱向對應從底到口（v）；2:1 的長寬約等於一圈的長度與高度比
    private static func patternImage(_ pattern: PotteryModel.Pattern) -> CGImage? {
        let width: CGFloat = 1024, height: CGFloat = 512
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let ink = UIColor(white: 0.66, alpha: 1)
            ink.setFill()
            ink.setStroke()
            let cell: CGFloat = 64   // 16 × 8 格，橫向剛好接得起來
            switch pattern {
            case .stripes:
                for column in stride(from: 0, to: 16, by: 2) {
                    context.fill(CGRect(x: CGFloat(column) * cell, y: 0, width: cell, height: height))
                }
            case .checker:
                for row in 0..<8 {
                    for column in 0..<16 where (row + column) % 2 == 0 {
                        context.fill(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                    }
                }
            case .dots:
                for row in 0..<8 {
                    for column in 0..<16 {
                        context.cgContext.fillEllipse(in: CGRect(x: CGFloat(column) * cell + 12, y: CGFloat(row) * cell + 12, width: cell - 24, height: cell - 24))
                    }
                }
            case .waves:
                let path = UIBezierPath()
                path.lineWidth = 14
                for row in 0..<8 {
                    let baseline = CGFloat(row) * cell + cell / 2
                    path.move(to: CGPoint(x: 0, y: baseline))
                    for x in stride(from: CGFloat(4), through: width, by: 4) {
                        // 整圈剛好 8 個波，頭尾接得起來
                        path.addLine(to: CGPoint(x: x, y: baseline + 14 * sin(x / width * 2 * .pi * 8)))
                    }
                }
                path.stroke()
            }
        }
        return image.cgImage
    }
}

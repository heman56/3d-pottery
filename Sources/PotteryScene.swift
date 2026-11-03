import SwiftUI
import RealityKit

/// 3D 場景：轉盤、陶器、相機與燈光
@MainActor
final class PotteryScene {
    let root = Entity()
    private let turntable = Entity()
    private let pot = ModelEntity()
    private let disc = ModelEntity()
    private let camera = PerspectiveCamera()
    /// 永遠面向相機的背景（iOS 的 RealityView 不能直接設背景色）
    private let backdrop = ModelEntity(
        mesh: .generatePlane(width: 12, height: 12),
        materials: [UnlitMaterial(color: UIColor(red: 0.98, green: 0.92, blue: 0.80, alpha: 1))]
    )

    private var glaze = PotteryModel.Glaze.clay
    private var pattern = PotteryModel.Pattern.stripes
    private var wireframe = false
    private var finish = Finish.matte
    private var interiorMaterial: any RealityKit.Material = PotteryMaterial.make(color: .darkGray, finish: .matte, wireframe: false, texture: nil)
    private var material: any RealityKit.Material = PotteryMaterial.make(color: .brown, finish: .matte, wireframe: false, texture: nil)
    /// 環境光（IBL）的來源：只有真機與 Mac 版會用到（Intel 模擬器的光照材質會當機）
    private let lightSource = Entity()
    private var textures: [PotteryModel.Pattern: TextureResource] = [:]
    private var photo: UIImage?
    private var photoTexture: TextureResource?
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
    private var targetTopInset: Float = 0
    private var targetBottomInset: Float = 0
    private var hasInsets = false

    private static let baseThickness: Float = 0.012
    private static let wall: Float = 0.88   // 內壁 / 外壁 的大小比例
    private static let lookAt: SIMD3<Float> = [0, 0.12, 0]

    /// 只在模擬器使用（見 rebuild）
    private let cavity = ModelEntity()
    private var cavityMaterial = UnlitMaterial(color: UIColor.black)

    init() {
        root.addChild(backdrop)

        // 轉盤：自己組網格；先用純灰色，放射狀線條的貼圖在 loadTextures() 載入後才貼上
        let plainGray = PotteryMaterial.make(color: UIColor(white: 0.72, alpha: 1), finish: .matte, wireframe: false, texture: nil)
        if let mesh = Self.makeTurntableMesh(radius: PotteryModel.turntableRadius, thickness: 0.03) {
            disc.model = ModelComponent(mesh: mesh, materials: [plainGray])
        } else {
            disc.model = ModelComponent(mesh: .generateCylinder(height: 0.03, radius: PotteryModel.turntableRadius), materials: [plainGray])
            disc.position.y = -0.015
        }
        turntable.addChild(disc)

        turntable.addChild(pot)
        root.addChild(turntable)
        root.addChild(lightSource)

        root.addChild(camera)
        applyCamera()

        #if targetEnvironment(simulator)
        turntable.addChild(cavity)
        #else
        // 主光：從右上前方打來，產生柔和的陰影
        let sun = DirectionalLight()
        sun.light.intensity = 1500
        sun.shadow = DirectionalLightComponent.Shadow(maximumDistance: 2, depthBias: 2)
        sun.look(at: [0, 0.1, 0], from: [0.6, 1.2, 0.8], relativeTo: nil)
        root.addChild(sun)

        // 補光：從左側照亮暗部，避免陰影太黑
        let fill = DirectionalLight()
        fill.light.intensity = 300
        fill.look(at: [0, 0.1, 0], from: [-0.8, 0.5, 0.6], relativeTo: nil)
        root.addChild(fill)
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
        targetTopInset = Float(top)
        targetBottomInset = Float(bottom)
        if !hasInsets {   // 第一次直接就位，不要在啟動時滑動
            topInset = targetTopInset
            bottomInset = targetBottomInset
            hasInsets = true
        }
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
        let position = Self.lookAt + direction * pose.distance

        // 相機位置不動，只讓視線往下傾斜：畫面上的陶器整個往上移，而看陶器的角度（杯口的橢圓）不變。
        // 如果連相機一起平移，面板很高的 iPhone 上相機會降到杯口的高度，只看得到杯口的邊
        // 相機的「上」要用傾斜前的視線算出來並明確指定：「上視」時視線幾乎垂直向下，
        // 傾斜後視線會越過正下方，look(at:) 預設的上方向會翻轉 180°，陶器就會掉到面板下面
        let forward = simd_normalize(target - position)
        var upVector = SIMD3<Float>(0, 1, 0)
        let right = simd_cross(forward, [0, 1, 0])
        if simd_length(right) > 1e-4 {
            upVector = simd_cross(simd_normalize(right), forward)
            if viewHeight > 0 {
                let fraction = (bottomInset - topInset) / (2 * viewHeight)
                target -= upVector * (fraction * 2 * pose.distance * tan(verticalFov / 2))
            }
        }
        camera.look(at: target, from: position, upVector: upVector, relativeTo: nil)

        let backdropPosition = Self.lookAt - direction * 1.8
        backdrop.look(at: backdropPosition - direction, from: backdropPosition, relativeTo: nil)
    }

    private func tick(_ dt: Float) {
        turntable.orientation = simd_quatf(angle: dt * 1.2, axis: [0, 1, 0]) * turntable.orientation

        let k = min(1, dt * 10)
        currentPose.yaw += (targetPose.yaw - currentPose.yaw) * k
        currentPose.pitch += (targetPose.pitch - currentPose.pitch) * k
        currentPose.distance += (targetPose.distance - currentPose.distance) * k
        // 選單收合／展開時，陶器順著面板的高度變化慢慢滑到新的中央
        topInset += (targetTopInset - topInset) * k
        bottomInset += (targetBottomInset - bottomInset) * k
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

    /// 載入所有程式畫出的貼圖（花紋、轉盤）。TextureResource(image:withName:options:) 是 async，
    /// 所以放在這裡，而不是 init
    func loadTextures() async {
        for pattern in PotteryModel.Pattern.allCases {
            if let image = Self.patternImage(pattern),
               let texture = try? await TextureResource(image: image, withName: nil, options: .init(semantic: .color)) {
                textures[pattern] = texture
            }
        }
        if let image = Self.turntableImage(),
           let texture = try? await TextureResource(image: image, withName: nil, options: .init(semantic: .color)) {
            disc.model?.materials = [PotteryMaterial.make(color: .white, finish: .matte, wireframe: false, texture: texture)]
        }
        await loadEnvironment()
        refreshMaterials()
    }

    /// 載入環境光，讓陶器和轉盤接收：亮釉、金屬、琉璃的反光都靠它。
    /// 強度指數 2.3 是用離屏渲染測試（tools/render-test）調出來的：HDRI 本身偏暗，每加 1 亮度乘 2
    private func loadEnvironment() async {
        #if !targetEnvironment(simulator)
        guard let environment = await StudioLighting.load() else { return }
        lightSource.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 2.3))
        for entity in [pot, disc] {
            entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lightSource))
        }
        #endif
    }

    func setFinish(_ finish: Finish) {
        self.finish = finish
        refreshMaterials()
    }

    func setPhoto(_ image: UIImage?) async {
        photo = image
        if let image, let cgImage = Self.photoImage(image) {
            photoTexture = try? await TextureResource(image: cgImage, withName: nil, options: .init(semantic: .color))
        } else {
            photoTexture = nil
        }
        refreshMaterials()
    }

    /// 照片整張當作一塊「拼磚」。先重畫一次，把照片的方向（EXIF）轉正；縮到最長邊 1024 以內。
    /// 之後網格的 UV 會讓這塊磚重複拼貼，張數由陶器的 UV 決定，改張數不用重畫貼圖
    private static func photoImage(_ photo: UIImage) -> CGImage? {
        let scale = min(1, 1024 / max(max(photo.size.width, photo.size.height), 1))
        let size = CGSize(width: max(photo.size.width * scale, 1), height: max(photo.size.height * scale, 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            photo.draw(in: CGRect(origin: .zero, size: size))
        }
        return image.cgImage
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
        // 照片模式：貼圖已經包含釉色底，色調用白色，照片才不會被染色
        let usePhoto = pattern == .photo && photoTexture != nil
        let color = wireframe ? glaze.color.shaded(by: 0.55) : (usePhoto ? UIColor.white : glaze.color)
        let texture = wireframe ? nil : (usePhoto ? photoTexture : textures[pattern])
        material = PotteryMaterial.make(color: color, finish: finish, wireframe: wireframe, texture: texture)
        // 內側：同釉色的深色素面，不上釉（不受質感與花紋影響）
        let interiorColor = wireframe ? color : glaze.color.shaded(by: 0.5)
        interiorMaterial = PotteryMaterial.make(color: interiorColor, finish: .matte, wireframe: wireframe, texture: nil)
        pot.model?.materials = [material, interiorMaterial]

        cavityMaterial = UnlitMaterial(color: glaze.color.shaded(by: 0.45))
        cavity.model?.materials = [cavityMaterial]
        cavity.isEnabled = !wireframe
    }

    /// 重新產生陶器網格。連續拖曳時只保留最新的一份，避免排隊
    func rebuild(_ spec: VesselSpec) {
        guard let mesh = Self.makeVessel(spec) else { return }
        pot.model = ModelComponent(mesh: mesh, materials: [material, interiorMaterial])

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

    /// 底面輪廓上的「欄」：每欄是一條從底到口的頂點線，相鄰的欄之間成一片牆。
    /// 欄的位置用沿周長的比例 t 表示：t = 0 與 1 在陶器背面（接縫，頂點重複），t = 0.5 在貼紙正中央。
    /// 圓形整圈共用頂點；多邊形每個面各自成「段」，段與段不共用頂點，所以每個面有自己的法線（平面），
    /// 每個面再細分，貼紙跨過很大的面時才不會被拉歪
    private struct Column {
        var unit: SIMD2<Float>   // 外接圓半徑為 1 時，輪廓上的位置（局部座標）
        var t: Float
        var patternU: Float      // 花紋貼圖的 u
        var segment: Int
    }

    private static let columnsAround = 96     // 繞一圈約幾欄
    private static let patternCellsAround = 16 // 花紋貼圖橫向一圈的格數

    private static func makeColumns(sides: Int) -> [Column] {
        if sides == 0 {
            return (0...columnsAround).map { k in
                let t = Float(k) / Float(columnsAround)
                let a = 2 * Float.pi * (t - 0.5)   // 貼紙中心（t = 0.5）在角度 0，接縫在 ±π
                return Column(unit: [cos(a), sin(a)], t: t, patternU: t, segment: 0)
            }
        }
        let faceSpan = 1 / Float(sides)
        // 每個面只佔花紋貼圖的一小段（約 16 / 邊數 格），格子才不會被拉成細長條
        let cellsPerFace = max(1, Int((Double(patternCellsAround) / Double(sides)).rounded()))
        let faceU = Float(cellsPerFace) / Float(patternCellsAround)
        func vertex(_ k: Int) -> SIMD2<Float> {
            let a = Float(vertexAngle(k % sides, sides: sides, count: sides))
            return [cos(a), sin(a)]
        }

        var columns: [Column] = []
        var segment = 0
        for face in 0..<sides {
            // 第 0 面的正中央對到 t = 0.5
            let low = 0.5 - 0.5 * faceSpan + Float(face) * faceSpan
            let high = low + faceSpan
            // (起點, 終點, 參考點)：參考點是這個面在「展開的 t」上的起點，用來算面內的位置 λ
            var pieces: [(Float, Float, Float)]
            if low >= 1 {
                pieces = [(low - 1, high - 1, low - 1)]
            } else if high > 1 {
                pieces = [(low, 1, low), (0, high - 1, low - 1)]   // 跨過接縫的面切成兩段
            } else {
                pieces = [(low, high, low)]
            }
            for (start, end, reference) in pieces where end - start > 1e-5 {
                let count = max(2, Int((Float(columnsAround) * (end - start)).rounded(.up)))
                for j in 0...count {
                    let t = start + (end - start) * Float(j) / Float(count)
                    let lambda = min(max((t - reference) / faceSpan, 0), 1)
                    let unit = vertex(face) + (vertex(face + 1) - vertex(face)) * lambda
                    columns.append(Column(unit: unit, t: t, patternU: faceU * lambda, segment: segment))
                }
                segment += 1
            }
        }
        return columns
    }

    /// 用 MeshDescriptor 自己組出整件陶器：外壁、內壁、口沿、外底面、內底面。
    /// 頂點、法線、UV 三個陣列必須一一對應（多一筆或少一筆，整個網格就會消失）。
    /// 座標：Y 軸朝上，高度 0 在轉盤上；半徑是外接圓半徑；每層依扭轉角度繞 Y 軸轉。
    /// UV：一般花紋用「繞一圈 × 從底到口」；照片貼紙用實際的弧長（公尺）換算，
    /// 所以不論陶器多粗，照片的比例都不會被拉長或壓扁
    private static func makeVessel(_ spec: VesselSpec) -> MeshResource? {
        let layers = spec.radii.count
        let height = PotteryModel.height
        let columns = makeColumns(sides: spec.sides)
        let strips = (0..<(columns.count - 1)).filter { columns[$0].segment == columns[$0 + 1].segment }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        // 每個三角形用哪個材質：0 是外側（上釉、有花紋），1 是內側（深色素面，不上釉）
        var faceMaterials: [UInt32] = []
        var currentMaterial: UInt32 = 0

        func point(_ column: Int, _ layer: Int, scale: Float) -> SIMD3<Float> {
            let t = Float(layer) / Float(layers - 1)
            let theta = spec.twist * t
            let unit = columns[column].unit
            let x = unit.x * cos(theta) - unit.y * sin(theta)
            let y = unit.x * sin(theta) + unit.y * cos(theta)
            let r = spec.radii[layer] * scale
            // 與先前的擠出做法相同：局部的 (x, y) 對應世界的 (x, -z)
            return [r * x, t * height, -r * y]
        }

        // 照片拼貼用的量：沿陶壁從底往上量的長度（占全長的比例決定 v）
        var profileLength = [Float](repeating: 0, count: layers)
        for i in 1..<layers {
            let dr = spec.radii[i] - spec.radii[i - 1]
            let dy = height / Float(layers - 1)
            profileLength[i] = profileLength[i - 1] + (dr * dr + dy * dy).squareRoot()
        }
        let totalLength = max(profileLength[layers - 1], 1e-6)

        func uv(_ column: Int, _ layer: Int) -> SIMD2<Float> {
            guard let tiles = spec.tiles else {
                return [columns[column].patternU, Float(layer) / Float(layers - 1)]
            }
            // 整數拼貼：u 繞一圈剛好 around 張（t 在接縫是 0 與 1，所以頭尾剛好接上），
            // v 從底到口剛好 up 張。v 往上增加：RealityKit 的 v = 0 在貼圖下緣
            return [columns[column].t * Float(tiles.around), profileLength[layer] / totalLength * Float(tiles.up)]
        }

        /// 三角形的順序依「想朝向的方向」自動決定（逆時針為正面）
        func addTriangle(_ a: Int, _ b: Int, _ c: Int, facing n: SIMD3<Float>) {
            let g = cross(positions[b] - positions[a], positions[c] - positions[a])
            if dot(g, n) >= 0 {
                indices += [UInt32(a), UInt32(b), UInt32(c)]
            } else {
                indices += [UInt32(a), UInt32(c), UInt32(b)]
            }
            faceMaterials.append(currentMaterial)
        }

        /// 一面牆（外壁或內壁）：每個頂點的法線由相鄰頂點的差分算出，朝外壁的外側或內壁的軸心側
        func addWall(scale: Float, facingOutward: Bool) {
            let first = positions.count
            func index(_ column: Int, _ layer: Int) -> Int { first + column * layers + layer }

            for c in columns.indices {
                let previous = c > 0 && columns[c - 1].segment == columns[c].segment ? c - 1 : c
                let next = c < columns.count - 1 && columns[c + 1].segment == columns[c].segment ? c + 1 : c
                for i in 0..<layers {
                    let p = point(c, i, scale: scale)
                    let along = point(c, min(i + 1, layers - 1), scale: scale) - point(c, max(i - 1, 0), scale: scale)
                    let around = point(next, i, scale: scale) - point(previous, i, scale: scale)
                    var n = cross(around, along)
                    let length = simd_length(n)
                    n = length > 1e-9 ? n / length : [0, 0, 1]
                    let radial = SIMD3<Float>(p.x, 0, p.z)
                    if (dot(n, radial) >= 0) != facingOutward { n = -n }
                    positions.append(p)
                    normals.append(n)
                    uvs.append(uv(c, i))
                }
            }
            for c0 in strips {
                let c1 = c0 + 1
                for i in 0..<(layers - 1) {
                    let a = index(c0, i), b = index(c1, i), c = index(c1, i + 1), d = index(c0, i + 1)
                    addTriangle(a, b, c, facing: normals[a])
                    addTriangle(a, c, d, facing: normals[a])
                }
            }
        }

        addWall(scale: 1, facingOutward: true)
        currentMaterial = 1
        addWall(scale: wall, facingOutward: false)
        currentMaterial = 0

        // 口沿：頂層外壁與內壁之間的一圈平面，朝上
        for c0 in strips {
            let c1 = c0 + 1
            let top = layers - 1
            let corners = [
                point(c0, top, scale: 1), point(c1, top, scale: 1),
                point(c1, top, scale: wall), point(c0, top, scale: wall),
            ]
            let first = positions.count
            for corner in corners {
                positions.append(corner)
                normals.append([0, 1, 0])
                uvs.append([(columns[c0].patternU + columns[c1].patternU) / 2, 1])
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
            for c0 in strips {
                addTriangle(first, first + 1 + c0, first + 2 + c0, facing: facing)
            }
        }

        addDisc(scale: 1, y: 0, facing: [0, -1, 0])
        currentMaterial = 1
        addDisc(scale: wall * 0.999, y: baseThickness, facing: [0, 1, 0])

        var descriptor = MeshDescriptor(name: "pot")
        descriptor.materials = .perFace(faceMaterials)
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

    // MARK: 轉盤

    /// 轉盤：頂面（y = 0）是一圈扇形，側面是一圈牆。頂面的 UV 用俯視的位置，
    /// 側面的 UV 固定指到貼圖角落那一點（純灰色）
    private static func makeTurntableMesh(radius: Float, thickness: Float, segments: Int = 96) -> MeshResource? {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        func addTriangle(_ a: Int, _ b: Int, _ c: Int, facing n: SIMD3<Float>) {
            let g = cross(positions[b] - positions[a], positions[c] - positions[a])
            if dot(g, n) >= 0 {
                indices += [UInt32(a), UInt32(b), UInt32(c)]
            } else {
                indices += [UInt32(a), UInt32(c), UInt32(b)]
            }
        }

        // 頂面
        positions.append([0, 0, 0])
        normals.append([0, 1, 0])
        uvs.append([0.5, 0.5])
        for k in 0..<segments {
            let a = 2 * Float.pi * Float(k) / Float(segments)
            positions.append([radius * cos(a), 0, radius * sin(a)])
            normals.append([0, 1, 0])
            uvs.append([0.5 + 0.5 * cos(a), 0.5 + 0.5 * sin(a)])
        }
        for k in 0..<segments {
            addTriangle(0, 1 + k, 1 + (k + 1) % segments, facing: [0, 1, 0])
        }

        // 側面
        let wall = positions.count
        let plain: SIMD2<Float> = [0.01, 0.01]
        for k in 0..<segments {
            let a = 2 * Float.pi * Float(k) / Float(segments)
            let outward: SIMD3<Float> = [cos(a), 0, sin(a)]
            positions.append([radius * cos(a), 0, radius * sin(a)])
            positions.append([radius * cos(a), -thickness, radius * sin(a)])
            normals.append(outward)
            normals.append(outward)
            uvs.append(plain)
            uvs.append(plain)
        }
        for k in 0..<segments {
            let next = (k + 1) % segments
            let topA = wall + 2 * k, bottomA = topA + 1
            let topB = wall + 2 * next, bottomB = topB + 1
            let outward = normals[topA]
            addTriangle(topA, topB, bottomB, facing: outward)
            addTriangle(topA, bottomB, bottomA, facing: outward)
        }

        var descriptor = MeshDescriptor(name: "turntable")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// 轉盤的貼圖：灰底，交錯的扇形（每 10° 一塊）、放射狀的線（每 30° 加粗）、幾圈同心圓。
    /// 圓以外（含角落）是純灰色，轉盤側面就取這個顏色
    private static func turntableImage() -> CGImage? {
        let side: CGFloat = 1024
        let center = CGPoint(x: side / 2, y: side / 2)
        let radius = side / 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cg = context.cgContext
            UIColor(white: 0.70, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 0, width: side, height: side))

            // 交錯的扇形：深淺相間，轉動時一眼就看得出來
            let wedges = 36
            for i in 0..<wedges where i % 2 == 0 {
                let start = 2 * CGFloat.pi * CGFloat(i) / CGFloat(wedges)
                let end = 2 * CGFloat.pi * CGFloat(i + 1) / CGFloat(wedges)
                cg.move(to: center)
                cg.addArc(center: center, radius: radius * 0.99, startAngle: start, endAngle: end, clockwise: false)
                cg.closePath()
                UIColor(white: 0.60, alpha: 1).setFill()
                cg.fillPath()
            }

            // 放射狀的線
            UIColor(white: 0.36, alpha: 1).setStroke()
            for i in 0..<wedges {
                let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(wedges)
                cg.setLineWidth(i % 3 == 0 ? 7 : 3)
                cg.move(to: CGPoint(x: center.x + radius * 0.10 * cos(angle), y: center.y + radius * 0.10 * sin(angle)))
                cg.addLine(to: CGPoint(x: center.x + radius * 0.99 * cos(angle), y: center.y + radius * 0.99 * sin(angle)))
                cg.strokePath()
            }

            // 同心圓與外緣
            for fraction in [0.30, 0.55, 0.80, 0.99] as [CGFloat] {
                cg.setLineWidth(fraction > 0.95 ? 10 : 4)
                cg.strokeEllipse(in: CGRect(x: center.x - radius * fraction, y: center.y - radius * fraction,
                                            width: radius * fraction * 2, height: radius * fraction * 2))
            }
        }
        return image.cgImage
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
            case .photo:
                break
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

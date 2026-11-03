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
    private var ridges = true
    private var ridgeNormalMap: TextureResource?
    private var floorMaterial: any RealityKit.Material = PotteryMaterial.make(color: .darkGray, finish: .matte, wireframe: false, texture: nil)
    private var interiorMaterial: any RealityKit.Material = PotteryMaterial.make(color: .darkGray, finish: .matte, wireframe: false, texture: nil)
    private var material: any RealityKit.Material = PotteryMaterial.make(color: .brown, finish: .matte, wireframe: false, texture: nil)
    /// 環境光（IBL）的來源：只有真機與 Mac 版會用到（Intel 模擬器的光照材質會當機）
    private let lightSource = Entity()
    private var textures: [PotteryModel.Pattern: TextureResource] = [:]
    private var photo: UIImage?
    private var photoTexture: TextureResource?
    private var spin: EventSubscription?
    /// 轉盤轉速（弧度／秒）：塑形時轉，檢視時停下來方便看細節；變速時慢慢加減速
    private var spinTarget: Float = 1.2
    private var spinSpeed: Float = 1.2
    private var mode = PotteryModel.Mode.sculpt
    /// 入窯燒製：fireTime 是已經燒了幾秒（nil 代表沒在燒），heat 是目前的溫度 0…1
    private var fireTime: Float?
    private var heat: Float = 0
    private var onFireEnd: (() -> Void)?
    private static let fireDuration: Float = 6
    private static let cream = UIColor(red: 0.98, green: 0.92, blue: 0.80, alpha: 1)
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
        spinSpeed += (spinTarget - spinSpeed) * min(1, dt * 6)
        turntable.orientation = simd_quatf(angle: dt * spinSpeed, axis: [0, 1, 0]) * turntable.orientation
        tickFire(dt)

        let k = min(1, dt * 10)
        currentPose.yaw += (targetPose.yaw - currentPose.yaw) * k
        currentPose.pitch += (targetPose.pitch - currentPose.pitch) * k
        currentPose.distance += (targetPose.distance - currentPose.distance) * k
        // 選單收合／展開時，陶器順著面板的高度變化慢慢滑到新的中央
        topInset += (targetTopInset - topInset) * k
        bottomInset += (targetBottomInset - bottomInset) * k
        applyCamera()
    }

    /// 檢視模式轉盤停下來；入窯時一律轉，整件陶器才看得到各面的火光
    func setMode(_ mode: PotteryModel.Mode) {
        self.mode = mode
        updateSpinTarget()
    }

    private func updateSpinTarget() {
        spinTarget = (mode == .sculpt || fireTime != nil) ? 1.2 : 0
    }

    /// 入窯燒製：約 6 秒。升溫（1.5 秒）→ 高溫火光閃動 → 慢慢降溫。背景跟著變暗，像在窯裡
    func fire(onEnd: @escaping () -> Void) {
        guard fireTime == nil else { return }
        fireTime = 0
        onFireEnd = onEnd
        updateSpinTarget()
    }

    private func tickFire(_ dt: Float) {
        guard let time = fireTime else { return }
        let t = time + dt
        if t >= Self.fireDuration {
            fireTime = nil
            heat = 0
            backdrop.model?.materials = [UnlitMaterial(color: Self.cream)]
            refreshMaterials()
            updateSpinTarget()
            onFireEnd?()
            onFireEnd = nil
            return
        }
        fireTime = t
        let rise: Float = 1.5, hold: Float = 1.5
        if t < rise {
            let x = t / rise
            heat = x * x * (3 - 2 * x)
        } else if t < rise + hold {
            heat = 0.92 + 0.08 * sin(t * 18) * sin(t * 7.3)   // 火光微微閃動
        } else {
            let x = (t - rise - hold) / (Self.fireDuration - rise - hold)
            heat = pow(1 - x, 1.6)
        }
        backdrop.model?.materials = [UnlitMaterial(color: Self.cream.mixed(with: UIColor(red: 0.10, green: 0.04, blue: 0.03, alpha: 1), by: CGFloat(heat) * 0.85))]
        refreshMaterials()
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
        if let image = PotteryMaterial.ridgeNormalImage() {
            ridgeNormalMap = try? await TextureResource(image: image, withName: nil, options: .init(semantic: .normal))
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

    func setRidges(_ on: Bool) {
        ridges = on
        refreshMaterials()
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
    static func photoImage(_ photo: UIImage) -> CGImage? {
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
        material = PotteryMaterial.make(color: color, finish: finish, wireframe: wireframe, texture: texture,
                                          normalMap: ridges && !wireframe ? ridgeNormalMap : nil, heat: heat)
        // 內側：同釉色的深色素面，不上釉（不受質感與花紋影響）
        let interiorColor = wireframe ? color : glaze.color.shaded(by: 0.5)
        interiorMaterial = PotteryMaterial.make(color: interiorColor, finish: .matte, wireframe: wireframe, texture: nil,
                                                normalMap: ridges && !wireframe ? ridgeNormalMap : nil, heat: heat)
        // 內底：平的，拉坯紋的貼圖在這裡會變成一條條直線，所以不加法線貼圖
        floorMaterial = PotteryMaterial.make(color: interiorColor, finish: .matte, wireframe: wireframe, texture: nil, heat: heat)
        pot.model?.materials = [material, interiorMaterial, floorMaterial]

        cavityMaterial = UnlitMaterial(color: glaze.color.shaded(by: 0.45))
        cavity.model?.materials = [cavityMaterial]
        cavity.isEnabled = !wireframe
    }

    /// 重新產生陶器網格。連續拖曳時只保留最新的一份，避免排隊
    func rebuild(_ spec: VesselSpec) {
        guard let mesh = Self.makeVessel(spec) else { return }
        pot.model = ModelComponent(mesh: mesh, materials: [material, interiorMaterial, floorMaterial])

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
    /// 多邊形的輪廓是「直線 + 圓弧倒角」交替；直線與圓弧各自成「段」，段與段之間頂點重複，
    /// 法線各算各的，所以平面保持平、轉角圓滑；兩段交界處的切線相同，看不出接縫。
    /// 花紋與照片的 u 沿整圈連續（t），不再每個面重來
    private struct Column {
        var unit: SIMD2<Float>   // 外接圓半徑為 1 時，輪廓上的位置（局部座標）
        var t: Float
        var patternU: Float      // 花紋貼圖的 u
        var segment: Int
    }

    private static let columnsAround = 96     // 繞一圈約幾欄

    private static func makeColumns(sides: Int) -> [Column] {
        if sides == 0 {
            return (0...columnsAround).map { k in
                let t = Float(k) / Float(columnsAround)
                let a = 2 * Float.pi * (t - 0.5)   // 貼紙中心（t = 0.5）在角度 0，接縫在 ±π
                return Column(unit: [cos(a), sin(a)], t: t, patternU: t, segment: 0)
            }
        }
        let n = sides
        let nf = Float(n)
        let corner = 2 * Float.pi / nf                  // 每個轉角圓弧的張角
        let edge = 2 * sin(Float.pi / nf)
        let d = PotteryModel.cornerRounding * edge      // 倒角從頂點往兩邊退的長度
        let rho = d / tan(Float.pi / nf)                // 圓弧半徑
        let straight = edge - 2 * d                     // 每邊剩下的直線長度
        let arc = rho * corner
        let perimeter = PotteryModel.outlinePerimeter(sides: n)

        func vertexAngle(_ k: Int) -> Float { Float(PotteryScene.vertexAngle(k % n, sides: n, count: n)) }
        func vertex(_ k: Int) -> SIMD2<Float> { [cos(vertexAngle(k)), sin(vertexAngle(k))] }
        /// 第 k 面（頂點 k 到 k + 1）直線部分上的位置，λ = 0…1
        func straightPoint(_ k: Int, _ lambda: Float) -> SIMD2<Float> {
            let dir = (vertex(k + 1) - vertex(k)) / edge
            return vertex(k) + dir * (d + straight * lambda)
        }
        /// 頂點 j 的圓弧上的位置，λ = 0…1（逆時針）
        func arcPoint(_ j: Int, _ lambda: Float) -> SIMD2<Float> {
            let phi = vertexAngle(j)
            let center = vertex(j) * (1 - rho / cos(Float.pi / nf))
            let psi = phi - Float.pi / nf + corner * lambda
            return center + rho * SIMD2<Float>(cos(psi), sin(psi))
        }

        // 從第 0 面的正中央出發，逆時針走一圈；s 是走過的路程
        struct Piece { var start: Float; var length: Float; var point: (Float) -> SIMD2<Float> }
        var pieces: [Piece] = []
        var s: Float = 0
        pieces.append(Piece(start: s, length: straight / 2, point: { straightPoint(0, 0.5 + 0.5 * $0) }))
        s += straight / 2
        for k in 1...n {
            let j = k
            pieces.append(Piece(start: s, length: arc, point: { arcPoint(j, $0) }))
            s += arc
            if k < n {
                pieces.append(Piece(start: s, length: straight, point: { straightPoint(j, $0) }))
                s += straight
            } else {
                pieces.append(Piece(start: s, length: straight / 2, point: { straightPoint(0, 0.5 * $0) }))
                s += straight / 2
            }
        }

        // s → t：第 0 面中央對到 t = 0.5，跨過 t = 1 的那一段切成兩段，接縫在背面
        struct Run { var t0: Float; var t1: Float; var u0: Float; var u1: Float; var piece: Int }
        var runs: [Run] = []
        for (index, piece) in pieces.enumerated() {
            let t0 = piece.start / perimeter + 0.5
            let t1 = (piece.start + piece.length) / perimeter + 0.5
            if t0 >= 1 {
                runs.append(Run(t0: t0 - 1, t1: t1 - 1, u0: 0, u1: 1, piece: index))
            } else if t1 > 1 {
                let mid = (1 - t0) / (t1 - t0)
                runs.append(Run(t0: t0, t1: 1, u0: 0, u1: mid, piece: index))
                runs.append(Run(t0: 0, t1: t1 - 1, u0: mid, u1: 1, piece: index))
            } else {
                runs.append(Run(t0: t0, t1: t1, u0: 0, u1: 1, piece: index))
            }
        }
        runs.sort { $0.t0 < $1.t0 }

        var columns: [Column] = []
        for (segment, run) in runs.enumerated() where run.t1 - run.t0 > 1e-6 {
            let isArc = run.piece % 2 == 1   // pieces 依序是 直線、圓弧、直線、…，圓弧都在奇數位
            let minimum = isArc ? 6 : 2
            let count = max(minimum, Int((Float(columnsAround) * (run.t1 - run.t0)).rounded(.up)))
            for j in 0...count {
                let f = Float(j) / Float(count)
                let t = run.t0 + (run.t1 - run.t0) * f
                let unit = pieces[run.piece].point(run.u0 + (run.u1 - run.u0) * f)
                columns.append(Column(unit: unit, t: t, patternU: t, segment: segment))
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
        let geometry = makeGeometry(spec)
        var descriptor = MeshDescriptor(name: "pot")
        descriptor.materials = .perFace(geometry.faceMaterials)
        descriptor.positions = MeshBuffer(geometry.positions)
        descriptor.normals = MeshBuffer(geometry.normals)
        descriptor.tangents = MeshBuffer(geometry.tangents)
        descriptor.bitangents = MeshBuffer(geometry.bitangents)
        descriptor.textureCoordinates = MeshBuffer(geometry.uvs)
        descriptor.primitives = .triangles(geometry.indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// 陶器的網格資料（頂點、法線、UV、三角形與每個三角形的材質）。畫面上的 MeshResource 和匯出的 .glb 共用
    static func makeGeometry(_ spec: VesselSpec) -> VesselGeometry {
        let layers = spec.radii.count
        let height = PotteryModel.height
        let columns = makeColumns(sides: spec.sides)
        let strips = (0..<(columns.count - 1)).filter { columns[$0].segment == columns[$0 + 1].segment }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        // 每個三角形用哪個材質：0 是外側（上釉、有花紋），1 是內壁、2 是內底（深色素面，不上釉）
        var tangents: [SIMD3<Float>] = []
        var bitangents: [SIMD3<Float>] = []
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
                    // 法線貼圖要用：u 方向是繞一圈（around），v 方向是往口沿（along）
                    tangents.append(simd_length(around) > 1e-9 ? simd_normalize(around) : [1, 0, 0])
                    bitangents.append(simd_length(along) > 1e-9 ? simd_normalize(along) : [0, 1, 0])
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
                tangents.append([1, 0, 0])
                bitangents.append([0, 0, 1])
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
            tangents.append([1, 0, 0])
            bitangents.append([0, 0, 1])
            uvs.append([0.5, 0.5])
            for c in columns.indices {
                var p = point(c, 0, scale: scale)
                p.y = y
                positions.append(p)
                normals.append(facing)
                tangents.append([1, 0, 0])
                bitangents.append([0, 0, 1])
                uvs.append([0.5 + 0.5 * p.x / extent, 0.5 + 0.5 * p.z / extent])
            }
            for c0 in strips {
                addTriangle(first, first + 1 + c0, first + 2 + c0, facing: facing)
            }
        }

        addDisc(scale: 1, y: 0, facing: [0, -1, 0])
        currentMaterial = 2
        addDisc(scale: wall * 0.999, y: baseThickness, facing: [0, 1, 0])

        return VesselGeometry(positions: positions, normals: normals, tangents: tangents, bitangents: bitangents,
                              uvs: uvs, indices: indices, faceMaterials: faceMaterials)
    }

    /// 模擬器專用：蓋在開口上的深色薄片（世界座標，已含頂層的扭轉角度）
    private static func makeCap(_ spec: VesselSpec) -> MeshResource? {
        // 輪廓與陶壁相同（含圓弧倒角）；欄是頭尾重複的一圈，扇形的三角形就沿著它排
        let outline = makeColumns(sides: spec.sides).map(\.unit)
        let radius = spec.radii[spec.radii.count - 1] * wall * 0.98
        let y = PotteryModel.height - 0.002
        let cosTwist = cos(spec.twist), sinTwist = sin(spec.twist)
        var positions: [SIMD3<Float>] = [[0, y, 0]]
        var indices: [UInt32] = []
        for (k, unit) in outline.enumerated() {
            let x = unit.x * cosTwist - unit.y * sinTwist
            let z = unit.x * sinTwist + unit.y * cosTwist
            positions.append([radius * x, y, -radius * z])
            if k > 0 { indices += [0, UInt32(k), UInt32(k + 1)] }
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
    static func patternImage(_ pattern: PotteryModel.Pattern) -> CGImage? {
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
            case .bands:
                for row in stride(from: 0, to: 8, by: 2) {
                    context.fill(CGRect(x: 0, y: CGFloat(row) * cell, width: width, height: cell))
                }
            case .diagonal:
                // 水平週期 128，高 512 剛好位移 4 個週期，左右接得起來
                for x0 in stride(from: CGFloat(-512), to: width, by: 128) {
                    let p = UIBezierPath()
                    p.move(to: CGPoint(x: x0, y: 0))
                    p.addLine(to: CGPoint(x: x0 + 64, y: 0))
                    p.addLine(to: CGPoint(x: x0 + 64 + height, y: height))
                    p.addLine(to: CGPoint(x: x0 + height, y: height))
                    p.close()
                    p.fill()
                }
            case .diamonds:
                for row in 0..<8 {
                    for column in 0..<16 {
                        let r = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell).insetBy(dx: 5, dy: 5)
                        let p = UIBezierPath()
                        p.move(to: CGPoint(x: r.midX, y: r.minY))
                        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
                        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
                        p.close()
                        if (row + column) % 2 == 0 {
                            p.fill()
                        } else {
                            p.lineWidth = 6
                            p.stroke()
                        }
                    }
                }
            case .zigzag:
                let path = UIBezierPath()
                path.lineWidth = 14
                path.lineJoinStyle = .miter
                for row in 0..<8 {
                    let baseline = CGFloat(row) * cell + cell / 2
                    path.move(to: CGPoint(x: 0, y: baseline + 16))
                    for k in 0..<32 {
                        path.addLine(to: CGPoint(x: CGFloat(k + 1) * 32, y: baseline + (k % 2 == 0 ? -16 : 16)))
                    }
                }
                path.stroke()
            case .scales:
                // 半圓一排一排疊起來，奇數排錯開半格
                let cg = context.cgContext
                cg.setLineWidth(7)
                for r in 0..<17 {
                    for c in -1..<17 {
                        let center = CGPoint(x: CGFloat(c) * cell + CGFloat(r % 2) * 32, y: CGFloat(r) * 32 + 16)
                        let rect = CGRect(x: center.x - 32, y: center.y - 32, width: 64, height: 64)
                        UIColor.white.setFill()
                        cg.fillEllipse(in: rect)
                        cg.strokeEllipse(in: rect.insetBy(dx: 3.5, dy: 3.5))
                    }
                }
            case .hearts:
                for row in 0..<8 {
                    for column in 0..<16 {
                        Self.heart(in: CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell).insetBy(dx: 8, dy: 8)).fill()
                    }
                }
            case .stars:
                for row in 0..<8 {
                    for column in 0..<16 {
                        let center = CGPoint(x: CGFloat(column) * cell + cell / 2, y: CGFloat(row) * cell + cell / 2)
                        let p = UIBezierPath()
                        for i in 0..<10 {
                            let radius: CGFloat = i % 2 == 0 ? 27 : 11
                            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                            let point = CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
                            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                        }
                        p.close()
                        p.fill()
                    }
                }
            case .flowers:
                let cg = context.cgContext
                for row in 0..<8 {
                    for column in 0..<16 {
                        let center = CGPoint(x: CGFloat(column) * cell + cell / 2, y: CGFloat(row) * cell + cell / 2)
                        for i in 0..<5 {
                            let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / 5
                            cg.fillEllipse(in: CGRect(x: center.x + 15 * cos(a) - 11, y: center.y + 15 * sin(a) - 11, width: 22, height: 22))
                        }
                        UIColor.white.setFill()
                        cg.fillEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
                        ink.setFill()
                    }
                }
            case .key:
                // 回紋：方形的螺旋，一格一個
                let unit = cell / 8
                let spiral: [(CGFloat, CGFloat)] = [(1, 7), (1, 1), (7, 1), (7, 6), (3, 6), (3, 3), (5, 3), (5, 4)]
                let p = UIBezierPath()
                p.lineWidth = 6
                p.lineJoinStyle = .miter
                p.lineCapStyle = .square
                for row in 0..<8 {
                    for column in 0..<16 {
                        let origin = CGPoint(x: CGFloat(column) * cell, y: CGFloat(row) * cell)
                        for (i, point) in spiral.enumerated() {
                            let q = CGPoint(x: origin.x + point.0 * unit, y: origin.y + point.1 * unit)
                            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                        }
                    }
                }
                p.stroke()
            case .rings:
                let cg = context.cgContext
                cg.setLineWidth(6)
                for row in 0..<8 {
                    for column in 0..<16 {
                        let center = CGPoint(x: CGFloat(column) * cell + cell / 2, y: CGFloat(row) * cell + cell / 2)
                        for radius in [CGFloat(26), 15] {
                            cg.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                        }
                        cg.fillEllipse(in: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
                    }
                }
            case .plaid:
                // 直條與橫條半透明疊在一起，交叉的地方比較深
                UIColor(white: 0.66, alpha: 0.5).setFill()
                for x in stride(from: CGFloat(0), to: width, by: 128) {
                    context.fill(CGRect(x: x, y: 0, width: 40, height: height))
                }
                for y in stride(from: CGFloat(0), to: height, by: 128) {
                    context.fill(CGRect(x: 0, y: y, width: width, height: 40))
                }
                UIColor(white: 0.66, alpha: 1).setFill()
                for x in stride(from: CGFloat(80), to: width, by: 128) {
                    context.fill(CGRect(x: x, y: 0, width: 6, height: height))
                }
                for y in stride(from: CGFloat(80), to: height, by: 128) {
                    context.fill(CGRect(x: 0, y: y, width: width, height: 6))
                }
            case .leaves:
                for row in 0..<8 {
                    for column in 0..<16 {
                        let center = CGPoint(x: CGFloat(column) * cell + cell / 2, y: CGFloat(row) * cell + cell / 2)
                        let a = CGPoint(x: center.x - 20, y: center.y + 20), b = CGPoint(x: center.x + 20, y: center.y - 20)
                        let p = UIBezierPath()
                        p.move(to: a)
                        p.addQuadCurve(to: b, controlPoint: CGPoint(x: center.x - 26, y: center.y - 26))
                        p.addQuadCurve(to: a, controlPoint: CGPoint(x: center.x + 26, y: center.y + 26))
                        p.fill()
                        UIColor.white.setStroke()
                        let vein = UIBezierPath()
                        vein.move(to: CGPoint(x: center.x - 15, y: center.y + 15))
                        vein.addLine(to: CGPoint(x: center.x + 12, y: center.y - 12))
                        vein.lineWidth = 3
                        vein.stroke()
                        ink.setStroke()
                    }
                }
            }
        }
        return image.cgImage
    }

    /// 愛心的外框（尖端朝下）
    private static func heart(in r: CGRect) -> UIBezierPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        let p = UIBezierPath()
        p.move(to: point(0.5, 1))
        p.addCurve(to: point(0, 0.35), controlPoint1: point(0.25, 0.8), controlPoint2: point(0, 0.6))
        p.addCurve(to: point(0.5, 0.22), controlPoint1: point(0, 0.05), controlPoint2: point(0.4, 0.0))
        p.addCurve(to: point(1, 0.35), controlPoint1: point(0.6, 0.0), controlPoint2: point(1, 0.05))
        p.addCurve(to: point(0.5, 1), controlPoint1: point(1, 0.6), controlPoint2: point(0.75, 0.8))
        p.close()
        return p
    }

    private static var thumbnails: [PotteryModel.Pattern: UIImage] = [:]

    /// 花紋選單的小圖：取貼圖左上 4×4 格
    static func patternThumbnail(_ pattern: PotteryModel.Pattern) -> UIImage? {
        if pattern == .photo { return nil }
        if let cached = thumbnails[pattern] { return cached }
        guard let full = patternImage(pattern), let crop = full.cropping(to: CGRect(x: 0, y: 0, width: 256, height: 256)) else { return nil }
        let image = UIImage(cgImage: crop)
        thumbnails[pattern] = image
        return image
    }
}

/// 陶器網格的原始資料。faceMaterials 每個三角形一筆：0 外側、1 內壁、2 內底
struct VesselGeometry {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var tangents: [SIMD3<Float>]
    var bitangents: [SIMD3<Float>]
    var uvs: [SIMD2<Float>]
    var indices: [UInt32]
    var faceMaterials: [UInt32]
}

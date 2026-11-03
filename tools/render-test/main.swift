// 離屏渲染測試：用 RealityRenderer 把各種質感渲染成 PNG，不需要螢幕或模擬器。
// 用法：./tools/render-test/run.sh [輸出.png] [環境光強度指數] [太陽光強度，0 代表不加]
import RealityKit
import Metal
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
func render() async throws {
    let args = CommandLine.arguments
    let hdrPath = args[1]
    let outPath = args[2]
    let exponent = args.count > 3 ? Float(args[3]) ?? 0 : 0
    let sunIntensity = args.count > 4 ? Float(args[4]) ?? 0 : 0

    let renderer = try RealityRenderer()
    if let environment = await StudioLighting.load(url: URL(fileURLWithPath: hdrPath)) {
        renderer.lighting.resource = environment
        renderer.lighting.intensityExponent = exponent
    } else {
        print("⚠️ 環境光載入失敗，將在沒有環境光的情況下渲染")
    }

    // 兩排：上排用赤陶色，下排用藍色；五欄是五種質感
    let colors: [PlatformColor] = [PlatformColor(red: 0.72, green: 0.45, blue: 0.30, alpha: 1),
                                   PlatformColor(red: 0.20, green: 0.42, blue: 0.80, alpha: 1)]
    for (row, color) in colors.enumerated() {
        for (column, finish) in Finish.allCases.enumerated() {
            let ball = ModelEntity(
                mesh: .generateSphere(radius: 0.12),
                materials: [PotteryMaterial.make(color: color, finish: finish, wireframe: false, texture: nil)]
            )
            ball.position = [Float(column - 2) * 0.3, Float(1 - row) * 0.3 - 0.15, 0]
            renderer.entities.append(ball)
        }
    }
    // 背後放一塊米色底板，才看得出琉璃（半透明）
    let backdrop = ModelEntity(
        mesh: .generatePlane(width: 3, height: 2),
        materials: [UnlitMaterial(color: PlatformColor(red: 0.98, green: 0.92, blue: 0.80, alpha: 1))]
    )
    backdrop.position = [0, 0, -0.4]
    renderer.entities.append(backdrop)

    if sunIntensity > 0 {
        let sun = DirectionalLight()
        sun.light.intensity = sunIntensity
        sun.look(at: .zero, from: [0.6, 1.2, 0.8], relativeTo: nil)
        renderer.entities.append(sun)
    }

    let camera = PerspectiveCamera()
    camera.look(at: [0, 0, 0], from: [0, 0, 1.7], relativeTo: nil)
    renderer.entities.append(camera)
    renderer.activeCamera = camera
    renderer.cameraSettings.colorBackground = .color(CGColor(red: 0.98, green: 0.92, blue: 0.80, alpha: 1))

    let width = 1500, height = 600
    guard let device = MTLCreateSystemDefaultDevice() else { fatalError("沒有 Metal 裝置") }
    print("Metal 裝置：\(device.name)")
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    guard let target = device.makeTexture(descriptor: descriptor) else { fatalError("建立輸出貼圖失敗") }
    let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: target))

    // 材質與環境光是非同步載入的，多渲染幾張，取最後一張
    for _ in 0..<40 {
        try renderer.updateAndRender(deltaTime: 0.1, cameraOutput: output)
        try await Task.sleep(for: .milliseconds(60))
    }

    // private 貼圖要先用 blit 拷到可讀的 buffer
    let bytesPerRow = width * 4
    guard let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
          let queue = device.makeCommandQueue(),
          let commands = queue.makeCommandBuffer(),
          let blit = commands.makeBlitCommandEncoder() else { fatalError("建立 Metal 指令失敗") }
    blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: width, height: height, depth: 1),
              to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
    blit.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()

    let context = CGContext(data: buffer.contents(), width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("已輸出 \(outPath)")
}

Task { @MainActor in
    do { try await render() } catch { print("失敗：\(error)") }
    exit(0)
}
RunLoop.main.run()

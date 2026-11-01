import SwiftUI
import RealityKit
import PhotosUI

struct ContentView: View {
    @State private var model = PotteryModel()
    @State private var scene = PotteryScene()
    /// 拖曳時上一個手指位置，用來算移動量
    @State private var lastDragPoint: CGPoint?
    @State private var zoomStart: Float?
    @State private var isSculpting = false
    @State private var viewHeight: CGFloat = 0
    @State private var headerFrame = CGRect.zero
    @State private var controlsFrame = CGRect.zero
    @State private var pickedItem: PhotosPickerItem?

    private static let brown = Color(red: 0.45, green: 0.25, blue: 0.12)

    var body: some View {
        ZStack {
            RealityView { content in
                content.camera = .virtual
                content.add(scene.root)
                scene.start(in: content)
                scene.setGlaze(model.glaze)
                scene.setPattern(model.pattern)
                scene.rebuild(model.spec)
            }
            .gesture(dragGesture)
            .simultaneousGesture(zoomGesture)
            .onChange(of: model.spec) { scene.rebuild(model.spec) }
            .onChange(of: model.pattern) { scene.setPattern(model.pattern) }
            .onChange(of: model.photo) { scene.setPhoto(model.photo) }
            .onChange(of: pickedItem) { loadPickedPhoto() }
            .onChange(of: model.glaze) { scene.setGlaze(model.glaze) }
            .onChange(of: model.showWireframe) { scene.setWireframe(model.showWireframe) }
            .onChange(of: model.camera) { scene.setCamera(model.camera) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                scene.setViewport($0)
                viewHeight = $0.height
                updateInsets()
            }
            .ignoresSafeArea()

            VStack {
                VStack(spacing: 4) {
                    Text("製陶大師")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text(hint)
                        .font(.system(.title3, design: .rounded, weight: .medium))
                }
                .foregroundStyle(Self.brown)
                .allowsHitTesting(false)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    headerFrame = $0
                    updateInsets()
                }

                // 退回、重做很常用：放大，放在模型的左右兩側，拇指好按
                HStack {
                    FloatingButton(title: "退回", symbol: "arrow.uturn.backward", isEnabled: model.canUndo) {
                        model.undo()
                    }
                    Spacer()
                    FloatingButton(title: "重做", symbol: "arrow.uturn.forward", isEnabled: model.canRedo) {
                        model.redo()
                    }
                }
                .frame(maxHeight: .infinity)

                controls
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        controlsFrame = $0
                        updateInsets()
                    }
            }
            .padding()
        }
    }

    /// 標題底部到面板頂端之間才是看得到陶器的地方，把陶器移到那裡的正中央
    private func updateInsets() {
        guard viewHeight > 0, controlsFrame.height > 0 else { return }
        scene.setInsets(top: headerFrame.maxY, bottom: viewHeight - controlsFrame.minY)
    }

    /// 把選到的照片讀進來。先縮到最長邊 1024 以內，省記憶體；照片只留在這台裝置上
    private func loadPickedPhoto() {
        guard let item = pickedItem else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            let longest = max(image.size.width, image.size.height)
            let scale = min(1, 1024 / max(longest, 1))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            model.setPhoto(resized)
            pickedItem = nil
        }
    }

    private var hint: String {
        switch model.mode {
        case .sculpt:
            model.camera.pitch > 1.2 ? "從上面看不能塑形，換個角度吧！" : "用手指在轉盤上拖曳，推出你想要的形狀！"
        case .look:
            "拖曳轉動視角，兩指開合放大縮小"
        }
    }

    // MARK: 手勢

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                switch model.mode {
                case .sculpt:
                    guard !scene.isTooSteepToSculpt,
                          let rough = scene.profilePoint(at: value.location),
                          rough.y >= 0, rough.y <= PotteryModel.height else { return }
                    // 先用轉軸平面估出高度與目前的半徑，再把平面移到外緣切點的位置重算一次
                    let depth = scene.tangentDepth(radius: model.surfaceRadius(atHeight: rough.y))
                    guard let p = scene.profilePoint(at: value.location, towardCamera: depth),
                          p.y >= 0, p.y <= PotteryModel.height else { return }
                    // 剖面平面通過轉軸，所以離轉軸的水平距離就是半徑
                    let fingerRadius = hypot(p.x, p.z)
                    if !isSculpting {
                        // 剛碰到：只記下手指與陶壁的距離，不改形狀
                        model.beginStroke()
                        model.beginSculpt(atHeight: p.y, fingerRadius: fingerRadius)
                        isSculpting = true
                    } else {
                        model.sculpt(atHeight: p.y, fingerRadius: fingerRadius)
                    }
                case .look:
                    let previous = lastDragPoint ?? value.location
                    model.orbit(dx: value.location.x - previous.x, dy: value.location.y - previous.y)
                    lastDragPoint = value.location
                }
            }
            .onEnded { _ in
                lastDragPoint = nil
                isSculpting = false
                model.endStroke()
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard model.mode == .look else { return }
                let start = zoomStart ?? model.camera.distance
                zoomStart = start
                model.zoom(to: start / Float(value.magnification))
            }
            .onEnded { _ in zoomStart = nil }
    }

    // MARK: 控制列

    /// 「照片」花紋的設定：選照片、調大小與高度（照片像貼紙貼一次，大小是最長邊的實際長度）
    private var photoControls: some View {
        VStack(spacing: 6) {
            PhotosPicker(selection: $pickedItem, matching: .images) {
                Label(model.photo == nil ? "選擇照片" : "換一張照片", systemImage: "photo.on.rectangle")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .background(Capsule().fill(Color(red: 0.62, green: 0.38, blue: 0.22)))
            }
            if model.photo != nil {
                stickerSlider("大小", value: model.stickerSize, range: 0.04...0.22) { model.setStickerSize($0) }
                stickerSlider("高度", value: model.stickerHeight, range: 0...1) { model.setStickerHeight($0) }
            }
        }
    }

    private func stickerSlider(_ title: String, value: Float, range: ClosedRange<Float>,
                               set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Self.brown)
                .frame(width: 44, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range) { editing in
                if editing { model.beginStroke() } else { model.endStroke() }
            }
            .tint(Self.brown)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ToolButton(title: "塑形", symbol: "hand.draw.fill", isOn: model.mode == .sculpt) {
                    model.mode = .sculpt
                }
                ToolButton(title: "檢視", symbol: "rotate.3d", isOn: model.mode == .look) {
                    model.mode = .look
                }
                Divider().frame(height: 40)
                ToolButton(title: "網格", symbol: "grid", isOn: model.showWireframe) {
                    model.showWireframe.toggle()
                }
            }

            if model.mode == .look {
                HStack(spacing: 10) {
                    ForEach(CameraPose.Preset.allCases) { preset in
                        ToolButton(title: preset.title, symbol: preset.symbol) {
                            model.setView(preset)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                ForEach(PotteryModel.Preset.allCases) { preset in
                    ToolButton(title: preset.title, symbol: preset.symbol) {
                        model.apply(preset)
                    }
                }
            }

            Picker("底面", selection: Binding(
                get: { model.baseShape },
                set: { model.setBaseShape($0) }
            )) {
                ForEach(PotteryModel.BaseShape.allCases) { shape in
                    Text(shape.title).tag(shape)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Text("扭轉 \(Int((model.twist * 180 / .pi).rounded()))°")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Self.brown)
                    .frame(width: 88, alignment: .leading)
                Slider(
                    value: Binding(get: { model.twist }, set: { model.setTwist($0) }),
                    in: -PotteryModel.maxTwist...PotteryModel.maxTwist
                ) { editing in
                    if editing { model.beginStroke() } else { model.endStroke() }
                }
                .tint(Self.brown)
                Button {
                    model.resetTwist()
                } label: {
                    Label("歸零", systemImage: "arrow.counterclockwise")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background(Capsule().fill(Color(red: 0.62, green: 0.38, blue: 0.22)))
                        .opacity(model.twist == 0 ? 0.35 : 1)
                }
                .buttonStyle(.plain)
                .disabled(model.twist == 0)
            }

            Picker("花紋", selection: Binding(
                get: { model.pattern },
                set: { model.setPattern($0) }
            )) {
                ForEach(PotteryModel.Pattern.allCases) { pattern in
                    Text(pattern.title).tag(pattern)
                }
            }
            .pickerStyle(.segmented)

            if model.pattern == .photo {
                photoControls
            }

            HStack(spacing: 12) {
                ForEach(PotteryModel.Glaze.allCases) { glaze in
                    Button {
                        model.setGlaze(glaze)
                    } label: {
                        Circle()
                            .fill(Color(glaze.color))
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(.white, lineWidth: model.glaze == glaze ? 5 : 0))
                            .shadow(radius: 3)
                    }
                    .accessibilityLabel("釉色")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 480)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
    }
}

/// 模型兩側的大圓鈕（退回／重做）
private struct FloatingButton: View {
    let title: String
    let symbol: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .bold))
                Text(title)
                    .font(.system(.footnote, design: .rounded, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(width: 76, height: 76)
            .background(Circle().fill(Color(red: 0.62, green: 0.38, blue: 0.22)))
            .shadow(radius: 3)
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// 圖示在上、文字在下的大按鈕（小朋友的手指比較粗，至少 56 點高）
private struct ToolButton: View {
    let title: String
    let symbol: String
    var isOn = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.title2)
                Text(title)
                    .font(.system(.footnote, design: .rounded, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(minWidth: 52, minHeight: 52)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isOn ? Color.orange : Color(red: 0.62, green: 0.38, blue: 0.22))
            )
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

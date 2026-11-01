import SwiftUI
import RealityKit

struct ContentView: View {
    @State private var model = PotteryModel()
    @State private var scene = PotteryScene()
    /// 拖曳時上一個手指位置，用來算移動量
    @State private var lastDragPoint: CGPoint?
    @State private var zoomStart: Float?

    private static let brown = Color(red: 0.45, green: 0.25, blue: 0.12)

    var body: some View {
        ZStack {
            RealityView { content in
                content.camera = .virtual
                content.add(scene.root)
                scene.start(in: content)
                scene.setGlaze(model.glaze)
                await scene.rebuild(model.spec)
            }
            .gesture(dragGesture)
            .simultaneousGesture(zoomGesture)
            .onChange(of: model.spec) {
                Task { await scene.rebuild(model.spec) }
            }
            .onChange(of: model.glaze) { scene.setGlaze(model.glaze) }
            .onChange(of: model.showWireframe) { scene.setWireframe(model.showWireframe) }
            .onChange(of: model.camera) { scene.setCamera(model.camera) }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { scene.setViewport($0) }
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

                Spacer()
                controls
            }
            .padding()
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
                    if lastDragPoint == nil { model.beginStroke() }
                    lastDragPoint = value.location
                    guard !scene.isTooSteepToSculpt,
                          let p = scene.profilePoint(at: value.location),
                          p.y >= 0, p.y <= PotteryModel.height else { return }
                    // 剖面平面通過轉軸，所以離轉軸的水平距離就是半徑
                    model.sculpt(atHeight: p.y, radius: hypot(p.x, p.z))
                case .look:
                    let previous = lastDragPoint ?? value.location
                    model.orbit(dx: value.location.x - previous.x, dy: value.location.y - previous.y)
                    lastDragPoint = value.location
                }
            }
            .onEnded { _ in
                lastDragPoint = nil
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
                ToolButton(title: "退回", symbol: "arrow.uturn.backward", isEnabled: model.canUndo) {
                    model.undo()
                }
                ToolButton(title: "重做", symbol: "arrow.uturn.forward", isEnabled: model.canRedo) {
                    model.redo()
                }
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

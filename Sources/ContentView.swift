import SwiftUI
import RealityKit

struct ContentView: View {
    @State private var model = PotteryModel()
    @State private var scene = PotteryScene()

    var body: some View {
        ZStack {
            RealityView { content in
                content.camera = .virtual
                content.add(scene.root)
                scene.startSpinning(in: content)
                scene.setGlaze(model.glaze)
                await scene.rebuild(radii: model.radii)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let p = scene.profilePoint(at: value.location),
                              p.y >= 0, p.y <= PotteryModel.height else { return }
                        model.sculpt(atHeight: p.y, radius: abs(p.x))
                    }
            )
            .onChange(of: model.radii) {
                Task { await scene.rebuild(radii: model.radii) }
            }
            .onChange(of: model.glaze) {
                scene.setGlaze(model.glaze)
            }
            .ignoresSafeArea()

            VStack {
                Text("製陶大師")
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.45, green: 0.25, blue: 0.12))
                Text("用手指在轉盤上拖曳，推出你想要的形狀！")
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .foregroundStyle(Color(red: 0.45, green: 0.25, blue: 0.12))
                Spacer()
                controls
            }
            .padding()
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(PotteryModel.Preset.allCases) { preset in
                    Button {
                        model.apply(preset)
                    } label: {
                        Label(preset.title, systemImage: preset.symbol)
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.62, green: 0.38, blue: 0.22))
                }
            }
            HStack(spacing: 16) {
                ForEach(PotteryModel.Glaze.allCases) { glaze in
                    Button {
                        model.glaze = glaze
                    } label: {
                        Circle()
                            .fill(Color(glaze.color))
                            .frame(width: 56, height: 56)
                            .overlay(Circle().stroke(.white, lineWidth: model.glaze == glaze ? 5 : 0))
                            .shadow(radius: 3)
                    }
                    .accessibilityLabel("釉色")
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
    }
}

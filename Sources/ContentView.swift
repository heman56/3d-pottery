import SwiftUI
import RealityKit
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = PotteryModel()
    @State private var scene = PotteryScene()
    /// 拖曳時上一個手指位置，用來算移動量
    @State private var lastDragPoint: CGPoint?
    @State private var zoomStart: Float?
    @State private var isSculpting = false
    @State private var isFiring = false
    @State private var exportFile = PotteryFile()
    @State private var exportType = UTType.pottery
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var fileMessage: String?
    @Environment(\.scenePhase) private var scenePhase
    /// 有未存檔的改動時，開啟或新作品之前先問
    private enum PendingAction { case open, new }
    @State private var pendingAction: PendingAction?
    @State private var askUnsaved = false
    /// 先存檔、存好再做的動作
    @State private var afterSave: PendingAction?
    /// 上次沒存的作品（自動暫存）；有值時問使用者要不要接續
    @State private var restoreRecord: Autosave.Record?
    @State private var lastAutosave: PotteryModel.Mark?
    @State private var viewHeight: CGFloat = 0
    @State private var headerFrame = CGRect.zero
    @State private var controlsFrame = CGRect.zero
    @State private var pickedItem: PhotosPickerItem?
    /// 選單收起來時，3D 畫面可以用更大的空間；塑形／檢視兩個模式的按鈕仍然留著。記住使用者的選擇
    @AppStorage("menuCollapsed") private var menuCollapsed = false

    private static let brown = Color(red: 0.45, green: 0.25, blue: 0.12)

    var body: some View {
        ZStack {
            RealityView { content in
                content.camera = .virtual
                content.add(scene.root)
                scene.start(in: content)
                scene.setGlaze(model.glaze)
                scene.setPattern(model.pattern)
                scene.setFinish(model.finish)
                scene.setRidges(model.ridges)
                scene.rebuild(model.spec)
                await scene.loadTextures()
            }
            .gesture(dragGesture)
            .simultaneousGesture(zoomGesture)
            .onChange(of: model.spec) { scene.rebuild(model.spec) }
            .onChange(of: model.pattern) { scene.setPattern(model.pattern) }
            .onChange(of: model.photo) { Task { await scene.setPhoto(model.photo) } }
            .onChange(of: pickedItem) { loadPickedPhoto() }
            .onChange(of: model.glaze) { scene.setGlaze(model.glaze) }
            .onChange(of: model.finish) { scene.setFinish(model.finish) }
            .onChange(of: model.ridges) { scene.setRidges(model.ridges) }
            .onChange(of: model.mode) { scene.setMode(model.mode) }
            .onChange(of: model.showWireframe) { scene.setWireframe(model.showWireframe) }
            .onChange(of: model.camera) { scene.setCamera(model.camera) }
            // 選單收合／展開的動畫結束後，再重算一次陶器的位置，避免動畫途中量到的高度留下來
            .onChange(of: menuCollapsed) {
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    updateInsets()
                }
            }
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
                    if model.fileName != nil || model.isDirty {
                        Text("\(model.fileName ?? "未命名")\(model.isDirty ? " •" : "")")
                            .font(.system(.callout, design: .rounded, weight: .medium))
                            .opacity(0.75)
                    }
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
            .overlay(alignment: .topTrailing) { fileMenu.padding() }
        }
        .fileExporter(isPresented: $showExporter, document: exportFile, contentType: exportType,
                      defaultFilename: model.fileName ?? Self.defaultName) { result in
            switch result {
            case .success(let url):
                if exportType == .pottery { didSave(to: url) }
            case .failure(let error):
                afterSave = nil
                if (error as? CocoaError)?.code != .userCancelled { fileMessage = "存檔失敗：\(error.localizedDescription)" }
            }
        }
        .confirmationDialog("目前的作品還沒存檔", isPresented: $askUnsaved, titleVisibility: .visible) {
            Button("儲存") {
                afterSave = pendingAction
                save()
            }
            Button("不存檔", role: .destructive) {
                if let action = pendingAction { perform(action) }
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: {
            Text("要先存起來嗎？")
        }
        .alert("上次的作品還沒存檔", isPresented: Binding(get: { restoreRecord != nil }, set: { _ in })) {
            Button("接續") {
                if let record = restoreRecord {
                    model.load(record.document, name: record.name, saved: false)
                    restoreRecord = nil
                }
            }
            Button("重新開始", role: .destructive) {
                Autosave.remove()
                restoreRecord = nil
            }
        } message: {
            Text("要接著做上次的陶器嗎？")
        }
        .task {
            restoreRecord = Autosave.read()
            // 隔一段時間暫存一次，App 當掉或被系統收掉也不會全部丟失
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                autosave()
            }
        }
        .onChange(of: scenePhase) { if scenePhase != .active { autosave() } }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pottery]) { result in
            openPottery(result)
        }
        .alert("製陶大師", isPresented: Binding(get: { fileMessage != nil }, set: { if !$0 { fileMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(fileMessage ?? "")
        }
    }

    // MARK: 存檔／匯出

    private static var defaultName: String {
        "陶器 " + Date.now.formatted(.iso8601.year().month().day())
    }

    /// 右上角的「檔案」選單：存成 .pottery（可以再載入）、開啟、匯出 .glb（給 Blender 等軟體）
    private var fileMenu: some View {
        Menu {
            Button("新作品", systemImage: "plus") { request(.new) }
            Button("開啟作品…", systemImage: "folder") { request(.open) }
            Divider()
            Button("儲存", systemImage: "square.and.arrow.down") { save() }
            Button("另存新檔…", systemImage: "square.and.arrow.down.on.square") { saveAs() }
            Divider()
            Button("匯出 3D 模型（.glb）", systemImage: "cube") {
                let input = GLBExport.Input(spec: model.spec, glaze: model.glaze, pattern: model.pattern,
                                            finish: model.finish, ridges: model.ridges, photo: model.photo)
                guard let data = GLBExport.make(input) else {
                    fileMessage = "匯出失敗。"
                    return
                }
                exportFile = PotteryFile(data: data)
                exportType = .glb
                showExporter = true
            }
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(red: 0.62, green: 0.38, blue: 0.22)))
        }
        .accessibilityLabel("檔案")
    }

    /// 開啟、新作品：有沒存的改動就先問
    private func request(_ action: PendingAction) {
        if model.isDirty {
            pendingAction = action
            askUnsaved = true
        } else {
            perform(action)
        }
    }

    private func perform(_ action: PendingAction) {
        pendingAction = nil
        switch action {
        case .open: showImporter = true
        case .new:
            model.startNew()
            Autosave.remove()
            lastAutosave = nil
        }
    }

    /// 儲存：已經有檔案位置就直接覆蓋，否則（或寫入失敗）問存哪裡
    private func save() {
        guard let url = model.fileURL, let data = try? model.makeDocument().encoded() else {
            saveAs()
            return
        }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            try data.write(to: url)
            didSave(to: url)
        } catch {
            saveAs()
        }
    }

    private func saveAs() {
        guard let data = try? model.makeDocument().encoded() else { return }
        exportFile = PotteryFile(data: data)
        exportType = .pottery
        showExporter = true
    }

    private func didSave(to url: URL) {
        model.markSaved(name: url.deletingPathExtension().lastPathComponent, url: url)
        Autosave.remove()
        lastAutosave = nil
        if let action = afterSave {
            afterSave = nil
            perform(action)
        }
    }

    /// 有改動就暫存；回到沒改動（存檔或退回到存檔時的樣子）就清掉暫存。
    /// 還在問「要不要接續上次的作品」時不動，免得蓋掉
    private func autosave() {
        guard restoreRecord == nil else { return }
        if model.isDirty {
            let mark = model.mark
            guard mark != lastAutosave else { return }
            Autosave.write(name: model.fileName, document: model.makeDocument())
            lastAutosave = mark
        } else if lastAutosave != nil {
            Autosave.remove()
            lastAutosave = nil
        }
    }

    private func openPottery(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            // 從「檔案」App 選到的檔案在 App 外面，要先取得存取權
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let document = try PotteryDocument.decode(try Data(contentsOf: url))
            model.load(document, name: url.deletingPathExtension().lastPathComponent, url: url)
            Autosave.remove()
            lastAutosave = nil
        } catch {
            fileMessage = "開啟失敗：\(error.localizedDescription)"
        }
    }

    /// 花紋選單：一排可以左右滑的小圖，選到的有咖啡色框
    private var patternPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PotteryModel.Pattern.allCases) { pattern in
                    let selected = model.pattern == pattern
                    Button { model.setPattern(pattern) } label: {
                        VStack(spacing: 2) {
                            Group {
                                if let thumb = PotteryScene.patternThumbnail(pattern) {
                                    Image(uiImage: thumb).resizable().interpolation(.medium)
                                } else {
                                    Image(systemName: "photo").resizable().scaledToFit().padding(12).foregroundStyle(Self.brown)
                                }
                            }
                            .frame(width: 48, height: 48)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Self.brown : Color.gray.opacity(0.4), lineWidth: selected ? 3 : 1))
                            Text(pattern.title)
                                .font(.system(size: 12, weight: selected ? .bold : .regular, design: .rounded))
                                .foregroundStyle(selected ? Self.brown : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pattern.title)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 3)
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
                    guard !isFiring, !scene.isTooSteepToSculpt,
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

    /// 「照片」花紋的設定：選照片、調整左右與上下各拼幾張（整數，貼滿陶器外面）
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
                tileSlider("左右", value: model.tilesAround) { model.setTilesAround($0) }
                HStack(spacing: 8) {
                    tileSlider("上下", value: model.tilesUp) { model.setTilesUp($0) }
                    Button {
                        model.fitTilesToPhoto()
                    } label: {
                        Label("自動", systemImage: "wand.and.stars")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(Capsule().fill(Color(red: 0.62, green: 0.38, blue: 0.22)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 張數滑桿：整數 1 到 12，一格一張
    private func tileSlider(_ title: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 10) {
            Text("\(title) \(value) 張")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Self.brown)
                .frame(width: 84, alignment: .leading)
            Slider(
                value: Binding(get: { Double(value) }, set: { set(Int($0.rounded())) }),
                in: 1...Double(PotteryModel.maxTiles), step: 1
            ) { editing in
                if editing { model.beginStroke() } else { model.endStroke() }
            }
            .tint(Self.brown)
        }
    }

    /// 形狀、底面、扭轉、花紋、釉色：可以整個收起來
    private var menuBody: some View {
        VStack(spacing: 10) {
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

            patternPicker

            if model.pattern == .photo {
                photoControls
            }

            HStack(spacing: 8) {
                Picker("質感", selection: Binding(
                    get: { model.finish },
                    set: { model.setFinish($0) }
                )) {
                    ForEach(Finish.allCases) { finish in
                        Text(finish.title).tag(finish)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("拉坯紋", isOn: Binding(
                    get: { model.ridges },
                    set: { model.setRidges($0) }
                ))
                .toggleStyle(.button)
                .tint(Color(red: 0.62, green: 0.38, blue: 0.22))
                .fixedSize()
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
                ToolButton(title: "入窯", symbol: "flame.fill", isEnabled: !isFiring) {
                    isFiring = true
                    scene.fire {
                        isFiring = false
                        // 燒好的陶器上了釉：原本是啞光（生坯）就換成亮釉；使用者已選別的質感就不動
                        if model.finish == .matte { model.setFinish(.glossy) }
                    }
                }
                ToolButton(title: menuCollapsed ? "展開" : "收合", symbol: menuCollapsed ? "chevron.up" : "chevron.down") {
                    withAnimation(.easeInOut(duration: 0.25)) { menuCollapsed.toggle() }
                }
                // 切換時整顆重新建立，不在動畫中原地改圖示與文字（模擬器上偶爾在更新圖示排版時當掉）
                .id(menuCollapsed)
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

            if !menuCollapsed {
                menuBody
                    .transition(.opacity)
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

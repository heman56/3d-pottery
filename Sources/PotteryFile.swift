import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// 製陶大師的存檔（內容是 JSON）。型別在 Info.plist 的 UTExportedTypeDeclarations 宣告
    static let pottery = UTType(exportedAs: "com.hemanlu.pottery", conformingTo: .json)
    /// glTF 二進位（.glb）。Blender、macOS 預覽程式等都讀得懂
    static let glb = UTType("org.khronos.gltf-binary") ?? UTType(filenameExtension: "glb", conformingTo: .data) ?? .data
}

/// .pottery 檔的內容：重新做出同一件陶器所需的參數，不含網格。
/// 加欄位時把 currentVersion 加一，讀檔時依版本補預設值
struct PotteryDocument: Codable {
    static let currentVersion = 1

    var version = PotteryDocument.currentVersion
    var radii: [Float]
    var baseShape: PotteryModel.BaseShape
    var twist: Float
    var glaze: PotteryModel.Glaze
    var pattern: PotteryModel.Pattern
    var finish: Finish
    var ridges: Bool
    var tilesAround: Int
    var tilesUp: Int
    /// 照片貼紙用的照片（JPEG；JSON 裡自動變成 base64）
    var photo: Data?

    enum LoadError: LocalizedError {
        case unreadable, newerVersion, badShape

        var errorDescription: String? {
            switch self {
            case .unreadable: "這不是製陶大師的作品檔。"
            case .newerVersion: "這個作品是用比較新的製陶大師存的，請先更新 App。"
            case .badShape: "作品檔裡的形狀資料不正確。"
            }
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> PotteryDocument {
        guard let document = try? JSONDecoder().decode(PotteryDocument.self, from: data) else { throw LoadError.unreadable }
        guard document.version <= currentVersion else { throw LoadError.newerVersion }
        guard document.radii.count == PotteryModel.Preset.clay.radii.count else { throw LoadError.badShape }
        return document
    }
}

/// 給 fileExporter／fileImporter 用的包裝：.pottery 與 .glb 共用，只差內容與型別
struct PotteryFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pottery] }
    static var writableContentTypes: [UTType] { [.pottery, .glb] }

    var data: Data

    init(data: Data = Data()) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw PotteryDocument.LoadError.unreadable }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// 自動暫存：App 進背景或隔一段時間，把還沒存的作品寫進 App 自己的資料夾，下次開啟時問要不要接續
enum Autosave {
    struct Record: Codable {
        var name: String?
        var document: PotteryDocument
    }

    private static var url: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("autosave.pottery")
    }

    static func write(name: String?, document: PotteryDocument) {
        guard let url, let data = try? JSONEncoder().encode(Record(name: name, document: document)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> Record? {
        guard let url, let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              (try? PotteryDocument.decode(try JSONEncoder().encode(record.document))) != nil else { return nil }
        return record
    }

    static func remove() {
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

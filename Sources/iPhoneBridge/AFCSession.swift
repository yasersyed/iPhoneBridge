import Foundation
import UniformTypeIdentifiers
import CIMobileDevice

struct RemoteFile: Identifiable, Hashable, Sendable {
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    var isImage: Bool {
        guard !isDirectory, let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

enum FileSource: Hashable, Sendable {
    case photos
    case app(SharedApp)

    var title: String {
        switch self {
        case .photos: return "Photos"
        case .app(let app): return app.name
        }
    }

    /// The camera roll lives under DCIM; File Sharing apps only expose Documents.
    var root: String { self == .photos ? "/DCIM" : "/Documents" }
}

/// An AFC connection to the camera roll or to one app's File Sharing folder.
/// AFC connections aren't thread-safe, so an actor serializes access.
actor AFCSession {
    private static let chunkSize = 1 << 20

    private let device: idevice_t
    private let houseArrest: house_arrest_client_t?
    private let afc: afc_client_t

    init(udid: String, source: FileSource) throws {
        var dev: idevice_t?
        try check(idevice_new(&dev, udid), "Connecting to device")
        var ha: house_arrest_client_t?
        var client: afc_client_t?
        do {
            switch source {
            case .photos:
                // The plain AFC service exposes the Media folder, which is where the camera roll is stored.
                try check(afc_client_start_service(dev, &client, clientLabel), "Opening photo library")
            case .app(let app):
                try check(house_arrest_client_start_service(dev, &ha, clientLabel), "Starting file service")
                try check(house_arrest_send_command(ha, "VendDocuments", app.id), "Opening app files")
                var result: plist_t?
                try check(house_arrest_get_result(ha, &result), "Opening app files")
                defer { plist_free(result) }
                if let reason = MobileDevice.string(plist_dict_get_item(result, "Error")) {
                    throw DeviceError("iOS refused access to this app's files (\(reason))")
                }
                try check(afc_client_new_from_house_arrest_client(ha, &client), "Opening app files")
            }
        } catch {
            if ha != nil { house_arrest_client_free(ha) }
            idevice_free(dev)
            throw error
        }
        device = dev!
        houseArrest = ha
        afc = client!
    }

    deinit {
        // An app's AFC client rides on its house_arrest connection, so it has to go first.
        afc_client_free(afc)
        if let houseArrest { house_arrest_client_free(houseArrest) }
        idevice_free(device)
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    func list(_ dir: String) throws -> [RemoteFile] {
        var raw: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        try check(afc_read_directory(afc, dir, &raw), "Reading \(dir)")
        defer { afc_dictionary_free(raw) }
        return try cStrings(raw)
            .filter { $0 != "." && $0 != ".." }
            .map { try fileInfo(Self.join(dir, $0)) }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    /// Every image below `dir`; the camera roll spreads photos across 100APPLE, 101APPLE, … folders.
    func images(under dir: String) throws -> [RemoteFile] {
        try Task.checkCancellation()
        return try list(dir).flatMap { file -> [RemoteFile] in
            if file.isDirectory { return try images(under: file.path) }
            return file.isImage ? [file] : []
        }
    }

    /// Whole file in memory, for previews and thumbnails.
    func data(_ path: String) throws -> Data {
        var data = Data()
        try readChunks(path) { data.append($0) }
        return data
    }

    func download(_ file: RemoteFile, into folder: URL) throws {
        let dest = folder.appendingPathComponent(file.name)
        guard file.isDirectory else { return try copyOut(file.path, to: dest) }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for child in try list(file.path) { try download(child, into: dest) }
    }

    func upload(_ source: URL, into dir: String) throws {
        let dest = Self.join(dir, source.lastPathComponent)
        guard (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return try copyIn(source, to: dest)
        }
        try makeDirectory(dest)
        for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            try upload(child, into: dest)
        }
    }

    func delete(_ path: String) throws {
        try check(afc_remove_path_and_contents(afc, path), "Deleting \(path)")
    }

    func makeDirectory(_ path: String) throws {
        try check(afc_make_directory(afc, path), "Creating \(path)")
    }

    private func fileInfo(_ path: String) throws -> RemoteFile {
        var raw: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        try check(afc_get_file_info(afc, path, &raw), "Reading \(path)")
        defer { afc_dictionary_free(raw) }

        // AFC returns info as a flat key, value, key, value… list.
        let flat = cStrings(raw)
        let info = Dictionary(
            stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0], flat[$0 + 1]) },
            uniquingKeysWith: { first, _ in first }
        )
        return RemoteFile(
            path: path,
            isDirectory: info["st_ifmt"] == "S_IFDIR",
            size: Int64(info["st_size"] ?? "") ?? 0,
            modified: Int64(info["st_mtime"] ?? "").map { Date(timeIntervalSince1970: Double($0) / 1e9) }  // nanoseconds
        )
    }

    private func copyOut(_ path: String, to dest: URL) throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        try readChunks(path) { out.write($0) }
    }

    /// Shared by downloads, previews and thumbnails so the AFC read loop lives in one place.
    private func readChunks(_ path: String, _ consume: (Data) throws -> Void) throws {
        // Thumbnails scrolled off screen are cancelled; skip the USB read instead of finishing it.
        try Task.checkCancellation()

        var handle: UInt64 = 0
        try check(afc_file_open(afc, path, AFC_FOPEN_RDONLY, &handle), "Opening \(path)")
        defer { afc_file_close(afc, handle) }

        var buffer = [CChar](repeating: 0, count: Self.chunkSize)
        while true {
            var read: UInt32 = 0
            try check(afc_file_read(afc, handle, &buffer, UInt32(buffer.count), &read), "Reading \(path)")
            if read == 0 { break }
            try consume(buffer.withUnsafeBytes { Data($0.prefix(Int(read))) })
        }
    }

    private func copyIn(_ source: URL, to path: String) throws {
        var handle: UInt64 = 0
        try check(afc_file_open(afc, path, AFC_FOPEN_WRONLY, &handle), "Creating \(path)")
        defer { afc_file_close(afc, handle) }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        while let data = try input.read(upToCount: Self.chunkSize), !data.isEmpty {
            try data.withUnsafeBytes { raw in
                let base = raw.bindMemory(to: CChar.self).baseAddress!
                var offset = 0
                // AFC may accept fewer bytes than offered, so keep writing until the chunk is done.
                while offset < raw.count {
                    var written: UInt32 = 0
                    try check(afc_file_write(afc, handle, base + offset, UInt32(raw.count - offset), &written), "Writing \(path)")
                    guard written > 0 else { throw DeviceError("Writing \(path) stalled") }
                    offset += Int(written)
                }
            }
        }
    }
}

import AppKit

struct PhotoSection: Identifiable {
    let title: String
    var photos: [RemoteFile]
    var id: String { title }
}

/// Drives both the app file browser and the photo library, which share connection, preview and download logic.
@MainActor
final class BrowserModel: ObservableObject {
    let udid: String
    let source: FileSource

    @Published private(set) var path: String
    @Published private(set) var files: [RemoteFile] = []
    @Published private(set) var photoSections: [PhotoSection] = []
    @Published var selection = Set<RemoteFile.ID>()
    @Published private(set) var busy: String?
    @Published var error: String?

    @Published private(set) var previewing: RemoteFile?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewError: String?

    private var session: AFCSession?
    private lazy var thumbnails = ThumbnailCache(udid: udid)

    var ready: Bool { session != nil && busy == nil }
    var canGoUp: Bool { path != "/" }
    var images: [RemoteFile] { files.filter(\.isImage) }

    init(udid: String, source: FileSource) {
        self.udid = udid
        self.source = source
        path = source.root
    }

    func connect() async {
        let (udid, source) = (udid, source)
        await run("Connecting…") {
            session = try await offMain { try AFCSession(udid: udid, source: source) }
            try await reload()
        }
    }

    func refresh() async {
        await run("Refreshing…") { try await reload() }
    }

    func goUp() async {
        let parent = (path as NSString).deletingLastPathComponent
        await run("Loading…") { try await load(parent) }
    }

    func open(_ ids: Set<RemoteFile.ID>) async {
        guard ids.count == 1, let file = items(ids).first else { return }
        if file.isDirectory {
            await run("Loading…") { try await load(file.path) }
        } else if file.isImage {
            await preview(file)
        }
    }

    func thumbnail(for file: RemoteFile) async -> NSImage? {
        await thumbnails.image(for: file) { try await self.session?.data($0) ?? Data() }
    }

    func preview(_ file: RemoteFile) async {
        previewing = file
        previewImage = nil
        previewError = nil
        do {
            let data = try await session?.data(file.path) ?? Data()
            // Ignore a stale result if the user already stepped to another image.
            guard previewing == file else { return }
            if let image = NSImage(data: data) {
                previewImage = image
            } else {
                previewError = "This image format can't be displayed."
            }
        } catch {
            if previewing == file { previewError = error.localizedDescription }
        }
    }

    func stepPreview(by offset: Int) async {
        guard let current = previewing, let i = images.firstIndex(of: current),
              images.indices.contains(i + offset) else { return }
        await preview(images[i + offset])
    }

    func closePreview() {
        previewing = nil
        previewImage = nil
        previewError = nil
    }

    func upload(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        await run("Uploading \(urls.count) item(s)…") {
            for url in urls {
                // File-picker URLs are security-scoped and unreadable until access is opened.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try await session?.upload(url, into: path)
            }
            try await load(path)
        }
    }

    func download(_ ids: Set<RemoteFile.ID>) async {
        let selected = items(ids)
        guard !selected.isEmpty, let folder = Self.chooseFolder() else { return }
        await run("Downloading \(selected.count) item(s)…") {
            for file in selected { try await session?.download(file, into: folder) }
            NSWorkspace.shared.activateFileViewerSelecting(selected.map { folder.appendingPathComponent($0.name) })
        }
    }

    func delete(_ ids: Set<RemoteFile.ID>) async {
        let selected = items(ids)
        await run("Deleting \(selected.count) item(s)…") {
            for file in selected { try await session?.delete(file.path) }
            try await load(path)
        }
    }

    func makeFolder(named name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        await run("Creating folder…") {
            try await session?.makeDirectory(AFCSession.join(path, name))
            try await load(path)
        }
    }

    private func items(_ ids: Set<RemoteFile.ID>) -> [RemoteFile] {
        files.filter { ids.contains($0.id) }
    }

    private func reload() async throws {
        if source == .photos {
            busy = "Scanning photo library…"
            try await loadPhotos()
        } else {
            try await load(path)
        }
    }

    private func load(_ dir: String) async throws {
        files = try await session?.list(dir) ?? []
        path = dir
        selection = []
    }

    private func loadPhotos() async throws {
        let photos = try await session?.images(under: source.root) ?? []
        files = photos.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }

        // Newest first, grouped by month like the Photos app.
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        var sections: [PhotoSection] = []
        for photo in files {
            let title = photo.modified.map(formatter.string(from:)) ?? "Unknown date"
            if sections.last?.title == title {
                sections[sections.count - 1].photos.append(photo)
            } else {
                sections.append(PhotoSection(title: title, photos: [photo]))
            }
        }
        photoSections = sections
        selection = []
    }

    /// Shows progress and turns any failure into an alert, so each action only describes its work.
    private func run(_ label: String, _ work: () async throws -> Void) async {
        busy = label
        defer { busy = nil }
        do { try await work() } catch { self.error = error.localizedDescription }
    }

    private static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

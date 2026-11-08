import AppKit

enum PhotoGrouping: String, CaseIterable, Identifiable {
    case day, month, year

    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: return "Days"
        case .month: return "Months"
        case .year: return "Years"
        }
    }

    fileprivate var components: Set<Calendar.Component> {
        switch self {
        case .day: return [.year, .month, .day]
        case .month: return [.year, .month]
        case .year: return [.year]
        }
    }

    fileprivate var template: String {
        switch self {
        case .day: return "EEEEdMMMMyyyy"
        case .month: return "MMMMyyyy"
        case .year: return "yyyy"
        }
    }
}

struct PhotoSection: Identifiable {
    let id: String
    let title: String
    /// Position of the first photo in `BrowserModel.files`, so range selection can work on indices.
    let start: Int
    var photos: [RemoteFile]

    var range: Range<Int> { start..<start + photos.count }
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
    @Published var grouping = PhotoGrouping(rawValue: UserDefaults.standard.string(forKey: "photoGrouping") ?? "") ?? .month {
        didSet {
            UserDefaults.standard.set(grouping.rawValue, forKey: "photoGrouping")
            regroupPhotos()
        }
    }
    /// Groups start collapsed; a large library is easier to scan as a list of dates.
    @Published var expanded = Set<PhotoSection.ID>()

    /// Where the last plain click landed; shift-click selects from here.
    private var anchor: Int?
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
        selection = []
        anchor = nil
        regroupPhotos()
    }

    /// Newest first, like the Photos app. Regrouping collapses everything, because old group IDs no longer apply.
    private func regroupPhotos() {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(grouping.template)

        var sections: [PhotoSection] = []
        for (i, photo) in files.enumerated() {
            let id: String
            if let date = photo.modified {
                let c = calendar.dateComponents(grouping.components, from: date)
                id = [c.year, c.month, c.day].compactMap { $0.map(String.init) }.joined(separator: "-")
            } else {
                id = "unknown"
            }
            if sections.last?.id == id {
                sections[sections.count - 1].photos.append(photo)
            } else {
                let title = photo.modified.map(formatter.string(from:)) ?? "Unknown date"
                sections.append(PhotoSection(id: id, title: title, start: i, photos: [photo]))
            }
        }
        photoSections = sections
        expanded = []
    }

    // MARK: Photo selection

    func selectedCount(in section: PhotoSection) -> Int {
        section.photos.reduce(0) { $0 + (selection.contains($1.id) ? 1 : 0) }
    }

    /// Finder rules: a plain click selects one photo, ⌘ toggles it, ⇧ selects everything from the last click.
    func click(_ photo: RemoteFile, command: Bool, shift: Bool) {
        guard let index = files.firstIndex(of: photo) else { return }
        if shift, let anchor {
            let ids = files[min(anchor, index)...max(anchor, index)].map(\.id)
            selection = command ? selection.union(ids) : Set(ids)
        } else if command {
            selection.formSymmetricDifference([photo.id])
            anchor = index
        } else {
            selection = [photo.id]
            anchor = index
        }
    }

    /// Selects or clears a whole group. With ⇧, extends from the last click to the far edge of this group.
    func toggleSection(_ section: PhotoSection, shift: Bool) {
        if shift, let anchor {
            let lower = min(anchor, section.range.lowerBound)
            let upper = max(anchor, section.range.upperBound - 1)
            selection.formUnion(files[lower...upper].map(\.id))
            return
        }
        let ids = section.photos.map(\.id)
        if selectedCount(in: section) == ids.count {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
        anchor = section.start
    }

    func photos(from start: Date, through end: Date) -> [RemoteFile] {
        let calendar = Calendar.current
        let lower = calendar.startOfDay(for: min(start, end))
        let upper = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(start, end))) ?? .distantFuture
        return files.filter { $0.modified.map { $0 >= lower && $0 < upper } ?? false }
    }

    func selectDates(from start: Date, through end: Date) {
        selection = Set(photos(from: start, through: end).map(\.id))
        anchor = nil
    }

    var dateSpan: ClosedRange<Date>? {
        let dates = files.compactMap(\.modified)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return first...last
    }

    func toggleExpanded(_ section: PhotoSection, all: Bool) {
        let opening = !expanded.contains(section.id)
        if all {
            expanded = opening ? Set(photoSections.map(\.id)) : []
        } else if opening {
            expanded.insert(section.id)
        } else {
            expanded.remove(section.id)
        }
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

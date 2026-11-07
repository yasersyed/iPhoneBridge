import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = DeviceStore()

    var body: some View {
        NavigationSplitView {
            List(store.devices, selection: $store.selectedDevice) { device in
                DeviceRow(device: device) { store.pair(device.id) }
            }
            .overlay {
                if store.devices.isEmpty {
                    Placeholder(title: "Connect your iPhone with a USB cable and unlock it", systemImage: "cable.connector")
                }
            }
            .navigationTitle("Devices")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } content: {
            sourceList
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let udid = store.selectedDevice, let source = store.selectedSource {
                // A new identity per source gives each one a fresh connection and view state.
                SourceView(udid: udid, source: source).id("\(udid)/\(store.selectedApp ?? "")")
            } else {
                Placeholder(title: "Select Photos or an app", systemImage: "photo.on.rectangle")
            }
        }
        .frame(minWidth: 960, minHeight: 560)
        .errorAlert($store.error)
    }

    @ViewBuilder private var sourceList: some View {
        if store.selected?.trust == .trusted {
            List(selection: $store.selectedApp) {
                Section("Library") {
                    Label("Photos", systemImage: "photo.on.rectangle").tag(String?.some(DeviceStore.photosID))
                }
                Section("File Sharing") {
                    ForEach(store.apps) { app in
                        Label(app.name, systemImage: "app").tag(String?.some(app.id))
                    }
                    if store.loadingApps {
                        ProgressView().controlSize(.small)
                    } else if store.apps.isEmpty {
                        Text("No apps share files").foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Placeholder(title: "Select a trusted iPhone", systemImage: "iphone")
        }
    }
}

struct DeviceRow: View {
    let device: Device
    let pair: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(device.name, systemImage: "iphone").font(.headline)
            if !device.subtitle.isEmpty {
                Text(device.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            if let message = device.trust.message {
                Text(message).font(.caption).foregroundStyle(.orange)
                Button("Pair", action: pair).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Owns the model and the pieces both screens share: connection, progress, preview and errors.
struct SourceView: View {
    @StateObject private var model: BrowserModel

    init(udid: String, source: FileSource) {
        _model = StateObject(wrappedValue: BrowserModel(udid: udid, source: source))
    }

    var body: some View {
        Group {
            if model.source == .photos {
                PhotoGallery(model: model)
            } else {
                FileBrowser(model: model)
            }
        }
        .navigationTitle(model.source.title)
        .safeAreaInset(edge: .bottom) {
            if let busy = model.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(busy)
                    Spacer()
                }
                .padding(8)
                .background(.bar)
            }
        }
        // Bound to a Bool, not the item, so stepping between images doesn't dismiss and re-open the sheet.
        .sheet(isPresented: Binding(get: { model.previewing != nil }, set: { if !$0 { model.closePreview() } })) {
            ImagePreview(model: model)
        }
        .errorAlert($model.error)
        .task { await model.connect() }
    }
}

struct PhotoGallery: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 4)], spacing: 4, pinnedViews: .sectionHeaders) {
                ForEach(model.photoSections) { section in
                    Section {
                        ForEach(section.photos) { photo in
                            PhotoTile(photo: photo, model: model, selected: model.selection.contains(photo.id))
                                .onTapGesture(count: 2) { Task { await model.preview(photo) } }
                                .onTapGesture { select(photo) }
                        }
                    } header: {
                        HStack {
                            Text(section.title).font(.headline)
                            Spacer()
                            Text("\(section.photos.count)").foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.bar)
                    }
                }
            }
            .padding(4)
        }
        .overlay {
            if model.ready && model.files.isEmpty {
                Placeholder(title: "No photos are stored on this iPhone", systemImage: "photo")
            }
        }
        .navigationSubtitle("\(model.files.count) photos")
        .toolbar {
            // No upload or delete: changing DCIM directly bypasses the Photos database and can corrupt the library.
            ToolbarItemGroup {
                Group {
                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Button { model.selection = Set(model.files.map(\.id)) } label: { Label("Select All", systemImage: "checkmark.circle") }
                        .keyboardShortcut("a")
                    Button { Task { await model.download(model.selection) } } label: {
                        Label("Download", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.selection.isEmpty)
                }
                .disabled(!model.ready)
            }
        }
    }

    /// Matches Finder: ⌘-click toggles, a plain click selects only this photo.
    private func select(_ photo: RemoteFile) {
        if NSEvent.modifierFlags.contains(.command) {
            model.selection.formSymmetricDifference([photo.id])
        } else {
            model.selection = [photo.id]
        }
    }
}

struct PhotoTile: View {
    let photo: RemoteFile
    let model: BrowserModel
    let selected: Bool
    @State private var image: NSImage?

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay {
                if selected {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            .task(id: photo.id) { image = await model.thumbnail(for: photo) }
    }
}

struct FileBrowser: View {
    @ObservedObject var model: BrowserModel
    @State private var importing = false
    @State private var confirmingDelete = false
    @State private var namingFolder = false
    @State private var folderName = ""

    var body: some View {
        Table(model.files, selection: $model.selection) {
            TableColumn("Name") { file in
                Label(file.name, systemImage: file.isDirectory ? "folder" : file.isImage ? "photo" : "doc")
            }
            TableColumn("Size") { file in
                Text(file.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .width(90)
            TableColumn("Modified") { file in
                Text(file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(170)
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            if ids.count == 1, let file = model.files.first(where: { $0.id == ids.first }), file.isImage {
                Button("Preview") { Task { await model.preview(file) } }
            }
            Button("Download…") { Task { await model.download(ids) } }
            Button("Delete…", role: .destructive) {
                model.selection = ids
                confirmingDelete = true
            }
        } primaryAction: { ids in
            Task { await model.open(ids) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.upload(urls) }
            return true
        }
        .overlay {
            if model.ready && model.files.isEmpty {
                Placeholder(title: "Empty folder. Drop files here to upload.", systemImage: "tray")
            }
        }
        .navigationSubtitle(model.path)
        .toolbar { toolbar }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.upload(urls) } }
        }
        .confirmationDialog("Delete \(model.selection.count) item(s) from the iPhone?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await model.delete(model.selection) } }
        } message: {
            Text("This can't be undone.")
        }
        .alert("New Folder", isPresented: $namingFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { Task { await model.makeFolder(named: folderName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { Task { await model.goUp() } } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.ready || !model.canGoUp)
        }
        ToolbarItemGroup {
            Group {
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button {
                    folderName = ""
                    namingFolder = true
                } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                Button { importing = true } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                Button { Task { await model.download(model.selection) } } label: {
                    Label("Download", systemImage: "square.and.arrow.down")
                }
                .disabled(model.selection.isEmpty)
                Button { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .disabled(model.selection.isEmpty)
            }
            .disabled(!model.ready)
        }
    }
}

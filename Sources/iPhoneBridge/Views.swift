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
                    Label("Photos", systemImage: "photo.on.rectangle").tag(DeviceStore.photosID)
                }
                Section("File Sharing") {
                    ForEach(store.apps) { app in
                        Label(app.name, systemImage: "app").tag(app.id)
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
    @State private var choosingDates = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(model.photoSections) { section in
                    let open = model.expanded.contains(section.id)
                    Section {
                        if open {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 4)], spacing: 4) {
                                ForEach(section.photos) { photo in
                                    PhotoTile(photo: photo, model: model, selected: model.selection.contains(photo.id))
                                        .onTapGesture(count: 2) { Task { await model.preview(photo) } }
                                        .onTapGesture {
                                            let flags = NSEvent.modifierFlags
                                            model.click(photo, command: flags.contains(.command), shift: flags.contains(.shift))
                                        }
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.bottom, 12)
                        }
                    } header: {
                        PhotoSectionHeader(section: section, model: model, open: open)
                    }
                }
            }
        }
        .overlay {
            if model.ready && model.files.isEmpty {
                Placeholder(title: "No photos are stored on this iPhone", systemImage: "photo")
            }
        }
        .onExitCommand { model.selection = [] }
        .navigationSubtitle(subtitle)
        .toolbar {
            // No upload or delete: changing DCIM directly bypasses the Photos database and can corrupt the library.
            ToolbarItemGroup {
                Group {
                    Picker("Group by", selection: $model.grouping) {
                        ForEach(PhotoGrouping.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Group photos by day, month or year")

                    Button {
                        model.expanded = model.expanded.isEmpty ? Set(model.photoSections.map(\.id)) : []
                    } label: {
                        model.expanded.isEmpty
                            ? Label("Expand All", systemImage: "rectangle.expand.vertical")
                            : Label("Collapse All", systemImage: "rectangle.compress.vertical")
                    }
                    .help(model.expanded.isEmpty ? "Expand all groups" : "Collapse all groups")

                    Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }

                    Button { choosingDates = true } label: { Label("Select Dates…", systemImage: "calendar") }
                        .help("Select every photo between two dates")
                        .popover(isPresented: $choosingDates, arrowEdge: .bottom) {
                            DateRangePicker(model: model) { choosingDates = false }
                        }

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

    private var subtitle: String {
        let total = "\(model.files.count.formatted()) photos"
        return model.selection.isEmpty ? total : "\(total), \(model.selection.count.formatted()) selected"
    }
}

/// A collapsed group still reads as photos: its header carries a contact strip of the first few thumbnails.
struct PhotoSectionHeader: View {
    let section: PhotoSection
    @ObservedObject var model: BrowserModel
    let open: Bool

    private static let stripCount = 8

    var body: some View {
        let selected = model.selectedCount(in: section)
        HStack(spacing: 10) {
            Button {
                model.toggleExpanded(section, all: NSEvent.modifierFlags.contains(.option))
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                    // A fixed title column per grouping keeps the contact strips lined up down the list.
                    Text(section.title)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(minWidth: titleWidth, alignment: .leading)
                        .fixedSize()
                    if !open {
                        ContactStrip(photos: Array(section.photos.prefix(Self.stripCount)), model: model)
                    }
                    Spacer(minLength: 8)
                    Text(countLabel(selected))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(selected > 0 ? Color.accentColor : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Collapse. Option-click to collapse every group." : "Expand. Option-click to expand every group.")
            .accessibilityLabel("\(section.title), \(countLabel(selected))")
            .accessibilityValue(open ? "Expanded" : "Collapsed")

            Button {
                model.toggleSection(section, shift: NSEvent.modifierFlags.contains(.shift))
            } label: {
                Image(systemName: selected == 0 ? "circle" : selected == section.photos.count ? "checkmark.circle.fill" : "minus.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(selected == 0 ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(selected == section.photos.count
                  ? "Deselect this group"
                  : "Select this group. Shift-click to select everything since your last click.")
            .accessibilityLabel(selected == section.photos.count ? "Deselect \(section.title)" : "Select \(section.title)")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .animation(.easeOut(duration: 0.15), value: open)
    }

    private var titleWidth: CGFloat {
        switch model.grouping {
        case .day: return 220
        case .month: return 140
        case .year: return 48
        }
    }

    private func countLabel(_ selected: Int) -> String {
        let total = section.photos.count
        if selected == 0 { return total == 1 ? "1 photo" : "\(total.formatted()) photos" }
        return "\(selected.formatted()) of \(total.formatted()) selected"
    }
}

struct ContactStrip: View {
    let photos: [RemoteFile]
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(photos) { photo in
                StripThumb(photo: photo, model: model)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}

struct StripThumb: View {
    let photo: RemoteFile
    let model: BrowserModel
    @State private var image: NSImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .frame(width: 28, height: 28)
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .task(id: photo.id) { image = await model.thumbnail(for: photo) }
    }
}

struct DateRangePicker: View {
    @ObservedObject var model: BrowserModel
    let done: () -> Void
    @State private var from = Date()
    @State private var through = Date()

    var body: some View {
        let count = model.photos(from: from, through: through).count
        VStack(alignment: .leading, spacing: 12) {
            Text("Select photos taken between").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("From").foregroundStyle(.secondary)
                    DatePicker("From", selection: $from, in: span, displayedComponents: .date).labelsHidden()
                }
                GridRow {
                    Text("Through").foregroundStyle(.secondary)
                    DatePicker("Through", selection: $through, in: span, displayedComponents: .date).labelsHidden()
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(count == 1 ? "Select 1 Photo" : "Select \(count.formatted()) Photos") {
                    model.selectDates(from: from, through: through)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            // Start from the newest month, the range people most often want to pull off the phone.
            guard let span = model.dateSpan else { return }
            through = span.upperBound
            from = max(span.lowerBound, Calendar.current.date(byAdding: .month, value: -1, to: span.upperBound) ?? span.lowerBound)
        }
    }

    private var span: ClosedRange<Date> {
        guard let s = model.dateSpan else { return Date()...Date() }
        return Calendar.current.startOfDay(for: s.lowerBound)...s.upperBound
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

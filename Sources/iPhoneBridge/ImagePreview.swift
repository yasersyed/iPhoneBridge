import SwiftUI

struct ImagePreview: View {
    @ObservedObject var model: BrowserModel

    private var position: Int? {
        model.previewing.flatMap { model.images.firstIndex(of: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let image = model.previewImage {
                    Image(nsImage: image).resizable().scaledToFit().padding(8)
                } else if let error = model.previewError {
                    Placeholder(title: error, systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 720, idealWidth: 960, minHeight: 480, idealHeight: 720)
            .background(.black.opacity(0.85))

            Divider()

            HStack(spacing: 12) {
                Button { Task { await model.stepPreview(by: -1) } } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled((position ?? 0) == 0)
                Button { Task { await model.stepPreview(by: 1) } } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled((position ?? model.images.count) >= model.images.count - 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.previewing?.name ?? "").lineLimit(1).truncationMode(.middle)
                    Text(details).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                Button("Download…") {
                    if let file = model.previewing { Task { await model.download([file.id]) } }
                }
                Button("Done") { model.closePreview() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
    }

    private var details: String {
        var parts: [String] = []
        if let i = position { parts.append("\(i + 1) of \(model.images.count)") }
        if let rep = model.previewImage?.representations.first {
            parts.append("\(rep.pixelsWide) × \(rep.pixelsHigh)")
        }
        if let file = model.previewing {
            parts.append(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

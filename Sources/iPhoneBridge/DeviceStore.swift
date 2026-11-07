import Foundation

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published var selectedDevice: String? {
        didSet { if selectedDevice != oldValue { loadApps() } }
    }
    @Published private(set) var apps: [SharedApp] = []
    @Published private(set) var loadingApps = false
    @Published var selectedApp: String?
    @Published var error: String?

    private var timer: Timer?
    private var polling = false

    /// Shares the app-selection slot; bundle IDs always contain dots, so this can't collide.
    static let photosID = "photos"

    var selected: Device? { devices.first { $0.id == selectedDevice } }

    var selectedSource: FileSource? {
        if selectedApp == Self.photosID { return .photos }
        return apps.first { $0.id == selectedApp }.map(FileSource.app)
    }

    init() {
        // Polling is simpler than bridging libimobiledevice's C event callback, and it also
        // notices Trust taps, which don't raise any event.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        Task { await poll() }
    }

    func pair(_ udid: String) {
        Task {
            do {
                let state = try await offMain { try MobileDevice.pair(udid) }
                if let i = devices.firstIndex(where: { $0.id == udid }) { devices[i].trust = state }
                if state == .trusted { await refresh(udid) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }

        let udids = (try? await offMain { MobileDevice.connectedUDIDs() }) ?? []
        devices.removeAll { !udids.contains($0.id) }
        if let id = selectedDevice, !udids.contains(id) { selectedDevice = nil }

        for id in udids where devices.first(where: { $0.id == id })?.trust.retriesAutomatically ?? true {
            await refresh(id)
        }
    }

    private func refresh(_ udid: String) async {
        guard let device = try? await offMain({ MobileDevice.info(udid) }) else { return }
        let wasTrusted = devices.first { $0.id == udid }?.trust == .trusted

        if let i = devices.firstIndex(where: { $0.id == udid }) {
            devices[i] = device
        } else {
            devices.append(device)
        }

        if selectedDevice == nil {
            selectedDevice = udid
        } else if selectedDevice == udid, device.trust == .trusted, !wasTrusted {
            loadApps()
        }
    }

    private func loadApps() {
        apps = []
        selectedApp = nil
        guard let udid = selectedDevice, selected?.trust == .trusted else { return }

        loadingApps = true
        Task {
            defer { loadingApps = false }
            do {
                let result = try await offMain { try MobileDevice.fileSharingApps(udid) }
                // The user may have switched devices while this was loading.
                if udid == selectedDevice { apps = result }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

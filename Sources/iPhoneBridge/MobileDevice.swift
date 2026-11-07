import Foundation
import CIMobileDevice

struct Device: Identifiable, Hashable, Sendable {
    let id: String
    var name = "iPhone"
    var model = ""
    var version = ""
    var battery: Int?
    var trust = TrustState.waitingForTrust

    var subtitle: String {
        [model, version.isEmpty ? "" : "iOS \(version)", battery.map { "\($0)% battery" } ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

enum TrustState: Hashable, Sendable {
    case trusted, locked, waitingForTrust, denied, failed(String)

    var message: String? {
        switch self {
        case .trusted: return nil
        case .locked: return "Unlock your iPhone"
        case .waitingForTrust: return "Tap Trust on your iPhone"
        case .denied: return "Trust was declined"
        case .failed(let reason): return reason
        }
    }

    /// A declined device isn't retried on its own, since each attempt would pop the Trust dialog again.
    var retriesAutomatically: Bool { self != .trusted && self != .denied }

    init(_ rc: lockdownd_error_t) {
        switch rc {
        case LOCKDOWN_E_SUCCESS: self = .trusted
        case LOCKDOWN_E_PASSWORD_PROTECTED: self = .locked
        case LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING: self = .waitingForTrust
        case LOCKDOWN_E_USER_DENIED_PAIRING: self = .denied
        case LOCKDOWN_E_INVALID_HOST_ID: self = .failed("Pairing is out of date. Tap Pair.")
        default: self = .failed("Lockdown error \(rc.rawValue)")
        }
    }
}

struct SharedApp: Identifiable, Hashable, Sendable {
    let id: String  // bundle identifier
    let name: String
}

/// Synchronous wrappers over libimobiledevice. Call them through `offMain`.
enum MobileDevice {
    static func connectedUDIDs() -> [String] {
        var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count: Int32 = 0
        guard idevice_get_device_list(&list, &count) == IDEVICE_E_SUCCESS else { return [] }
        defer { idevice_device_list_free(list) }
        // A phone on both USB and Wi-Fi sync is listed twice.
        return Array(Set(cStrings(list))).sorted()
    }

    static func info(_ udid: String) -> Device {
        var device = Device(id: udid)
        do {
            try withDevice(udid) { dev in
                // An unpaired session can still read basic identity, so the sidebar is useful before Trust.
                var plain: lockdownd_client_t?
                if lockdownd_client_new(dev, &plain, clientLabel) == LOCKDOWN_E_SUCCESS, let plain {
                    readIdentity(plain, into: &device)
                    lockdownd_client_free(plain)
                }

                // The handshake also starts pairing, which shows the Trust dialog when there's no record yet.
                var ld: lockdownd_client_t?
                let rc = lockdownd_client_new_with_handshake(dev, &ld, clientLabel)
                device.trust = TrustState(rc)
                guard rc == LOCKDOWN_E_SUCCESS, let ld else { return }
                defer { lockdownd_client_free(ld) }

                readIdentity(ld, into: &device)
                device.battery = lockdownValue(ld, key: "BatteryCurrentCapacity", domain: "com.apple.mobile.battery") { node in
                    var pct: UInt64 = 0
                    plist_get_uint_val(node, &pct)
                    return Int(pct)
                }
            }
        } catch {
            device.trust = .failed(error.localizedDescription)
        }
        return device
    }

    static func pair(_ udid: String) throws -> TrustState {
        try withDevice(udid) { dev in
            var ld: lockdownd_client_t?
            try check(lockdownd_client_new(dev, &ld, clientLabel), "Starting lockdown session")
            defer { lockdownd_client_free(ld) }
            return TrustState(lockdownd_pair(ld, nil))
        }
    }

    /// Only apps with File Sharing enabled; iOS refuses access to every other app's container.
    static func fileSharingApps(_ udid: String) throws -> [SharedApp] {
        try withDevice(udid) { dev in
            var proxy: instproxy_client_t?
            try check(instproxy_client_start_service(dev, &proxy, clientLabel), "Starting app list service")
            defer { instproxy_client_free(proxy) }

            // Built by hand because instproxy_client_options_add is variadic, which Swift can't call.
            let options = plist_new_dict()
            defer { plist_free(options) }
            plist_dict_set_item(options, "ApplicationType", plist_new_string("User"))
            let attributes = plist_new_array()
            for key in ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "UIFileSharingEnabled"] {
                plist_array_append_item(attributes, plist_new_string(key))
            }
            plist_dict_set_item(options, "ReturnAttributes", attributes)

            var result: plist_t?
            try check(instproxy_browse(proxy, options, &result), "Listing apps")
            defer { plist_free(result) }

            return (0..<plist_array_get_size(result))
                .compactMap { i -> SharedApp? in
                    let app = plist_array_get_item(result, i)
                    guard bool(plist_dict_get_item(app, "UIFileSharingEnabled")),
                          let id = string(plist_dict_get_item(app, "CFBundleIdentifier")) else { return nil }
                    let name = string(plist_dict_get_item(app, "CFBundleDisplayName"))
                        ?? string(plist_dict_get_item(app, "CFBundleName")) ?? id
                    return SharedApp(id: id, name: name)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    static func string(_ node: plist_t?) -> String? {
        guard let node else { return nil }
        var value: UnsafeMutablePointer<CChar>?
        plist_get_string_val(node, &value)
        guard let value else { return nil }
        defer { free(value) }
        return String(cString: value)
    }

    /// Some apps declare UIFileSharingEnabled as the string "YES" instead of a boolean.
    private static func bool(_ node: plist_t?) -> Bool {
        guard let node else { return false }
        if plist_get_node_type(node) == PLIST_BOOLEAN {
            var value: UInt8 = 0
            plist_get_bool_val(node, &value)
            return value != 0
        }
        return ["yes", "true", "1"].contains(string(node)?.lowercased() ?? "")
    }

    private static func withDevice<T>(_ udid: String, _ body: (idevice_t) throws -> T) throws -> T {
        var dev: idevice_t?
        try check(idevice_new(&dev, udid), "Connecting to device")
        defer { idevice_free(dev) }
        return try body(dev!)
    }

    private static func readIdentity(_ ld: lockdownd_client_t, into device: inout Device) {
        device.name = lockdownValue(ld, key: "DeviceName", read: string) ?? device.name
        device.model = lockdownValue(ld, key: "ProductType", read: string) ?? device.model
        device.version = lockdownValue(ld, key: "ProductVersion", read: string) ?? device.version
    }

    private static func lockdownValue<T>(
        _ ld: lockdownd_client_t, key: String, domain: String? = nil, read: (plist_t) -> T?
    ) -> T? {
        var node: plist_t?
        guard lockdownd_get_value(ld, domain, key, &node) == LOCKDOWN_E_SUCCESS, let node else { return nil }
        defer { plist_free(node) }
        return read(node)
    }
}

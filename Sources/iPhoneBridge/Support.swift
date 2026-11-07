import Foundation
import SwiftUI

let clientLabel = "iPhoneBridge"

struct DeviceError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Every libimobiledevice service reports failure as a nonzero enum code, so one helper covers them all.
func check<E: RawRepresentable>(_ rc: E, _ what: @autoclosure () -> String) throws where E.RawValue: BinaryInteger {
    guard rc.rawValue == 0 else { throw DeviceError("\(what()) failed (code \(rc.rawValue))") }
}

/// libimobiledevice blocks on USB I/O; running it off the main thread keeps the UI responsive.
func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated, operation: work).value
}

/// Reads the NULL-terminated string arrays used for device lists and AFC listings.
func cStrings(_ list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> [String] {
    guard let list else { return [] }
    var out: [String] = []
    var i = 0
    while let s = list[i] {
        out.append(String(cString: s))
        i += 1
    }
    return out
}

extension View {
    func errorAlert(_ error: Binding<String?>) -> some View {
        alert(
            "Something went wrong",
            isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }
}

struct Placeholder: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 32)).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

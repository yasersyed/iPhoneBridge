# iPhone Bridge — Handover

## Why this exists

Finder stopped showing the iPhone on an Intel MacBook Pro, and the free alternatives were weak. This is a small native macOS app that talks to the iPhone over USB directly, without depending on Finder.

## Status

| Feature | State |
|---|---|
| Device detection, info, pairing / Trust | Working (confirmed on device) |
| Browse File Sharing apps: list, upload, download, delete, new folder | Working (confirmed on device) |
| Image viewer (double-click, ← → to step through) | Written, not yet confirmed on device |
| Photos library grid (camera roll, cached thumbnails) | Written, not yet confirmed on device |
| Photos grouped by Days / Months / Years, collapsed by default, with interval selection | Written, rendered with fake data, not yet confirmed on device |

The code was written in an environment with no Swift toolchain, so the last two features have never been compiled. Expect a small fix or two on the first build.

## Build and run

Needs macOS 13+, the Swift toolchain, and Homebrew.

```bash
xcode-select --install                     # skip if Xcode is installed
brew install libimobiledevice pkg-config
swift run                                  # dev run from Terminal
./build-app.sh                             # builds "build/iPhone Bridge.app"
```

The `.app` links to Homebrew's dylibs in `/usr/local`, so it only runs on a Mac with `libimobiledevice` installed. It is ad-hoc signed and not notarized.

## How it's put together

It's a Swift package with no Xcode project. The only external dependency is [libimobiledevice](https://libimobiledevice.org), the C library behind `ideviceinfo` and friends.

```
Package.swift                 SwiftPM manifest; finds libimobiledevice via pkg-config
Sources/CIMobileDevice/       C module map + shim header exposing libimobiledevice to Swift
Sources/iPhoneBridge/
  MobileDevice.swift          Device list, lockdown info, pairing, File Sharing app list (sync C wrappers)
  AFCSession.swift            AFC file access for Photos (/DCIM) or one app (/Documents); an actor
  DeviceStore.swift           Main-actor state: polls devices every 2s, selected device/source, app list
  BrowserModel.swift          Per-source state: listing, photo sections, preview, upload/download/delete
  Thumbnails.swift            Thumbnail downscaling + memory/disk cache (~/Library/Caches/iPhoneBridge)
  Views.swift                 Three-column UI: devices → sources → file table or photo grid
  ImagePreview.swift          Full-size image sheet
  Support.swift               Error type, `check()` for C return codes, `offMain`, shared UI bits
  App.swift                   Entry point; sets a regular activation policy so `swift run` gets a Dock icon
build-app.sh                  Wraps the release binary in a .app bundle
```

### Data flow

1. `DeviceStore` polls `MobileDevice.connectedUDIDs()` every 2 seconds. For each device that isn't trusted yet, it calls `MobileDevice.info()`. The lockdown handshake inside `info()` is what makes the iPhone show its Trust prompt.
2. Choosing **Photos** or an app produces a `FileSource`. `SourceView` then creates a `BrowserModel`, which opens an `AFCSession`:
   - **Photos** uses the plain AFC service. Its root is the phone's Media folder, and photos are under `/DCIM/1xxAPPLE/`.
   - **An app** uses `house_arrest` with `VendDocuments` to reach the app's `/Documents` folder.
3. Every libimobiledevice call blocks on USB, so all of them run off the main thread (`offMain`, or inside the `AFCSession` actor).

## Decisions worth knowing

- **Polling instead of the C event callback.** It's simpler to bridge, and it also notices Trust taps, which don't raise an event.
- **A device that declined Trust isn't retried automatically.** Each attempt would show the Trust dialog again. The user clicks **Pair** instead.
- **The Photos view is read-only on purpose.** Writing to or deleting from `/DCIM` directly bypasses the Photos database and can corrupt the library.
- **Only File Sharing apps are reachable.** iOS refuses `house_arrest` access to any app without `UIFileSharingEnabled`. Some apps set that key as the string `"YES"` instead of a boolean, and `MobileDevice.bool()` handles both.
- **App options plist is built by hand.** `instproxy_client_options_add` is variadic, which Swift can't call.
- **Thumbnail cache key is size + path.** An edited photo keeps its name but changes size, so it gets a new thumbnail.
- **Photo groups open collapsed.** A collapsed header shows a strip of its first 8 thumbnails, so it still reads as photos. Changing the grouping collapses everything again, because group IDs change.
- **Selection follows Finder.** Click selects one photo, ⌘-click toggles, ⇧-click selects from the last click (even through collapsed groups). The circle on a header selects or clears that group, and ⇧-clicking it extends the range. **Select Dates…** picks a From–Through range. ⌥-click a header to expand or collapse all; Esc clears the selection.
- **The preview sheet is bound to a Bool, not to the previewed item.** Stepping between images then doesn't close and reopen the sheet.

## Known limitations

- Videos and Live Photos aren't shown in Photos; only `UTType.image` files are listed.
- Photos are grouped by the file's modification date rather than the EXIF capture date. The two usually match.
- With iCloud "Optimize iPhone Storage" turned on, photos that exist only in iCloud don't appear.
- The Photos scan walks all of `/DCIM` before showing anything, which is slow on large libraries.
- Files are read whole into memory for previews and thumbnails, so very large images use a lot of RAM.
- Upload and download show a single busy label with no per-file progress, and there's no cancel.
- There are no tests.

## Possible next steps

1. Build the image viewer and Photos changes on the device and fix any compile errors.
2. Add videos, using an AVKit player in the preview and pairing Live Photo `.MOV` files with their stills.
3. Use EXIF capture dates for grouping. `CGImageSourceCopyPropertiesAtIndex` can read them from the first chunk of each file.
4. Show photos progressively while the scan runs, and add per-file progress with a cancel button.
5. Bundle the dylibs into the `.app` (for example with `dylibbundler`) so it runs without Homebrew.

## Troubleshooting

- **No device listed:** use a data cable plugged directly into the Mac, and unlock the phone. `system_profiler SPUSBDataType | grep -i iphone` confirms whether USB sees it.
- **"Pairing is out of date":** click **Pair**, unlock the phone and tap **Trust**. If that fails, run `sudo killall usbmuxd` and reconnect.
- **Library not found at build time:** run `brew install libimobiledevice pkg-config`, then `pkg-config --libs libimobiledevice-1.0` should print link flags.

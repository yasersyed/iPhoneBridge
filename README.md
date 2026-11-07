# iPhone Bridge

A small macOS app (13+) for an iPhone over USB. It doesn't depend on Finder.

- Detects connected iPhones and shows the name, model, iOS version and battery.
- Handles pairing and walks you through the Trust prompt.
- Browses the files of apps that have **File Sharing** turned on, such as VLC, Documents and Pages.
- Lets you upload (drag and drop or the Upload button), download, delete and create folders.

It's built on [libimobiledevice](https://libimobiledevice.org).

## Setup

```bash
xcode-select --install                      # Swift toolchain, if you don't have Xcode
brew install libimobiledevice pkg-config
```

## Run

```bash
swift run                 # quick start from Terminal
./build-app.sh            # or build "build/iPhone Bridge.app"
open build                # then drag it to /Applications
```

## Notes

- iOS only exposes apps that opt into File Sharing. Photos and other apps' private data aren't reachable this way.
- If the phone shows "Pairing is out of date", click **Pair**, unlock the phone, and tap **Trust**.
- A `.app` built this way links to Homebrew's libraries in `/usr/local`. Keep `libimobiledevice` installed.

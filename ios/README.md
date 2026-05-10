# X Video iOS

Standalone iOS and Mac Catalyst client for the local downloader service.

This app does not replace the existing web UI. It connects to the Python server from the repository root:

```bash
.venv/bin/python server.py
```

Default server URL:

```text
http://127.0.0.1:8765
```

Default login:

- Username: `admin`
- Password: `admin234`

## Run On Mac mini

Open `ios/XVideoIOS.xcodeproj` in Xcode and run the `XVideoIOS` scheme.

Supported destinations:

- iPhone Simulator
- iPad Simulator
- Mac Catalyst, so it can run as an app on the Mac mini

Downloads are saved by the Python server, not inside the iOS app sandbox. Use the save directory field to control the Mac mini path.

## CLI Build Check

Mac Catalyst build:

```bash
xcodebuild \
  -project ios/XVideoIOS.xcodeproj \
  -scheme XVideoIOS \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/xvideo-ios-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

In this workspace, the Mac Catalyst build succeeds. iOS Simulator listing is currently blocked by the local Xcode/CoreSimulator mismatch:

```text
CoreSimulator is out of date. Current version (1051.49.0) is older than build version (1051.50.0).
```

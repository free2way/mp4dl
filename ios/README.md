# X Video macOS

Standalone macOS downloader app built with SwiftUI.

This app does not replace the existing web UI and does not require the local Python server. The release package bundles:

- `yt-dlp`
- `ffmpeg`
- the dynamic libraries needed by the bundled `ffmpeg`

Downloads are saved on the Mac at:

```text
~/Downloads/X Video
```

The save directory can be changed inside the app.

## Run On Mac mini

Open `ios/XVideoIOS.xcodeproj` in Xcode and run the `XVideoIOS` scheme on `My Mac`.

CLI build check:

```bash
xcodebuild \
  -project ios/XVideoIOS.xcodeproj \
  -scheme XVideoIOS \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/xvideo-standalone-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The GitHub release package is created by copying the bundled command-line tools into `XVideoIOS.app/Contents/Resources/` and ad-hoc signing the app.

# X Video Android

This is a standalone Android client for the downloader. It does not reuse or replace the existing local web app in the repository root.

## What It Does

- Downloads public X, YouTube, and Bilibili videos directly on the phone.
- Supports pasting multiple links and downloading them as a queue.
- Lets you set concurrent downloads from 1 to 5.
- Saves files to the phone's public download folder: `Download/X Video/`.
- Uses the bundled `youtubedl-android` runtime, so it does not need `server.py` running on a computer.

## Build

Open the `android/` folder in Android Studio and run the `app` configuration, or build an APK from Android Studio.

The first run initializes the yt-dlp runtime. If a site changes and parsing stops working, tap `Update engine` in the app to refresh yt-dlp.

Dependencies are pulled from Maven Central:

- `io.github.junkfood02.youtubedl-android:library`
- `io.github.junkfood02.youtubedl-android:ffmpeg`

## Storage Notes

Android 10 and older may ask for storage permission. Android 11 and newer use scoped storage rules and write to `Download/X Video/`.

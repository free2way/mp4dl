# X Video Downloader

A small local web app for downloading videos from public X, YouTube, and Bilibili pages.

Use it only for videos you own or have permission to save.

## Requirements

- Python 3.10+
- `yt-dlp`
- `curl-cffi`
- `ffmpeg` recommended for highest-quality video/audio merging

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Install `ffmpeg` if you want best video + best audio merging:

```bash
brew install ffmpeg
```

## Run

```bash
.venv/bin/python server.py
```

Open `http://127.0.0.1:8765`.

Downloads are saved into `downloads/` by default.

## Notes

- Paste an X, YouTube, or Bilibili link, parse the available resolutions, then choose the quality to download.
- Set the save directory in the page. Relative paths are resolved from the project folder.
- When subtitles are available, the page lets you choose whether to download them and which language to request.
- Completed files are named as `<page title>-<resolution>.<ext>`.
- Some videos require login. In that case, select the browser whose cookies contain your logged-in session.
- The app runs locally and binds to `127.0.0.1` by default.

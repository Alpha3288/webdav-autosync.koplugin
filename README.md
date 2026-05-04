# WebDAV Auto Sync – KOReader Plugin

Sync files from a WebDAV server to your device. Optional credentials, configurable download folder, and either automatic sync on startup or manual sync on demand.

## Features

- **WebDAV connection** – Server URL with optional username/password (Basic auth).
- **Import from KOReader cloud storage** – If you already configured a WebDAV server under KOReader's built-in *Cloud storage* feature, pick it from KOReader's own picker (which also lets you choose a folder inside the server) and the URL and credentials are copied over automatically. The local download folder is always chosen separately.
- **Download folder** – Opens KOReader’s file explorer; navigate and long-press a folder to select it (no typing paths).
- **File extensions (optional)** – Sync only files with given extensions (e.g. `epub, pdf, txt`). Leave empty to sync all formats KOReader supports (EPUB, PDF, DjVu, XPS, CBT, CBZ, CB7, FB2, PDB, TXT, HTML, RTF, CHM, DOC, MOBI, ZIP, MD).
- **Auto sync** – When enabled, sync runs once when KOReader starts.
- **Manual sync** – Use **Sync now** from the menu to pull all files at any time.
- **Two-way sync (optional)** – When enabled, also uploads new or changed local files back to the server. Uses a small state cache to detect what changed since the last sync, so re-runs only transfer files that actually moved. Conflicts (a file changed on both sides) are resolved interactively on manual sync; auto sync skips them silently. Deletions are never propagated — removing a file on one side leaves the other side untouched.

## Installation

1. Download or clone this repo so the plugin folder is named `webdav-autosync.koplugin`.
2. Copy the whole `webdav-autosync.koplugin` folder into your KOReader plugins directory (e.g. `koreader/plugins/`).
3. Restart KOReader; the plugin appears in the main menu as **WebDAV Sync**.

## Usage

1. Open the main menu → **WebDAV Sync**.
2. **Set server URL** – Your WebDAV base URL (e.g. `https://example.com/webdav`). You can skip this step and use **Import from KOReader cloud storage** to copy the URL and credentials from a server you already configured under KOReader's built-in cloud storage; you'll be able to drill into a specific subfolder during the pick.
3. **Set credentials (optional)** – Username and password if the server requires auth.
4. **Choose download folder** – Opens the file browser; navigate to a folder and long-press it to select it as the download location.
5. **Set file extensions (optional)** – Comma- or space-separated list (e.g. `epub, pdf, txt`). Leave empty to sync all KOReader-supported formats.
6. **Auto sync on startup** – Turn on to sync automatically when KOReader starts.
7. **Two-way sync (upload local changes)** – Turn on to also push local changes back to the server. The very first run after enabling silently establishes a baseline of files already present on both sides (no transfers, no conflicts). Subsequent runs upload anything new or modified locally and download anything new or modified remotely.
8. **Sync now** – Run a full sync manually (lists all files on the server and downloads only those matching the extension filter into the chosen folder; with two-way on, also uploads local changes).

Sync downloads **all files** under the server URL recursively; subfolders are recreated under the download folder.

### Two-way sync details

- The same extension filter applies to uploads — only book files are pushed.
- A small state cache (`<settings_dir>/webdav_autosync_state.lua`) tracks per-file fingerprints so unchanged files are skipped on every run.
- **Conflicts** (a file changed on both sides since the last sync): on manual sync you'll be asked per file to *Keep local (upload)*, *Keep remote (download)*, or *Skip*. Auto sync skips conflicts silently and tells you how many were skipped.
- **No deletions**: removing a file on one side does not delete it on the other. The plugin remembers the deletion so it doesn't keep re-syncing the file back.

## Requirements

- KOReader with LuaSocket (and HTTPS support for `https://` URLs).
- A WebDAV server that supports PROPFIND and GET.

## Files

- `_meta.lua` – Plugin manifest.
- `main.lua` – Entry point, menu, settings, auto/manual sync, conflict dialog.
- `webdav.lua` – WebDAV client (PROPFIND, GET, PUT, MKCOL; Basic auth).
- `sync.lua` – One-way sync (`run_sync`) and two-way sync (`plan` / `do_action` / `save_cache`) with state cache.

## License

MIT.

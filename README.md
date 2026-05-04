# WebDAV Auto Sync – KOReader Plugin

Sync files from a WebDAV server to your device. Optional credentials, configurable download folder, and either automatic sync on startup or manual sync on demand.

## Features

- **WebDAV connection** – Server URL with optional username/password (Basic auth).
- **Import from KOReader cloud storage** – If you already configured a WebDAV server under KOReader's built-in *Cloud storage* feature, pick it from KOReader's own picker (which also lets you choose a folder inside the server) and the URL and credentials are copied over automatically. The local download folder is always chosen separately.
- **Download folder** – Opens KOReader’s file explorer; navigate and long-press a folder to select it (no typing paths).
- **File extensions (optional)** – Sync only files with given extensions (e.g. `epub, pdf, txt`). Leave empty to sync all formats KOReader supports (EPUB, PDF, DjVu, XPS, CBT, CBZ, CB7, FB2, PDB, TXT, HTML, RTF, CHM, DOC, MOBI, ZIP, MD).
- **Auto sync** – When enabled, sync runs once when KOReader starts.
- **Manual sync** – Use **Sync now** from the menu to pull all files at any time.

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
7. **Sync now** – Run a full sync manually (lists all files on the server and downloads only those matching the extension filter into the chosen folder).

Sync downloads **all files** under the server URL recursively; subfolders are recreated under the download folder.

## Requirements

- KOReader with LuaSocket (and HTTPS support for `https://` URLs).
- A WebDAV server that supports PROPFIND and GET.

## Files

- `_meta.lua` – Plugin manifest.
- `main.lua` – Entry point, menu, settings, auto/manual sync.
- `webdav.lua` – WebDAV client (PROPFIND, GET, Basic auth).
- `sync.lua` – Sync logic (list all, download to folder).

## License

MIT.

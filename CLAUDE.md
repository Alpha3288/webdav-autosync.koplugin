# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A KOReader plugin (`.koplugin` directory) that syncs files from a WebDAV server to a local folder. Loaded by KOReader at runtime; **cannot be executed standalone** — it `require`s KOReader-only modules (`dispatcher`, `ui/widget/*`, `socketutil`, `ui/network/manager`).

## Development commands

```sh
make check    # lint + parse-check (run before committing)
make lint     # selene static analysis only
make parse    # LuaJIT parse-check every .lua file
```

There are no tests. Local validation = static checks; behavioral testing requires installing the plugin into a KOReader instance.

## Linter setup is non-standard — read before editing config

Upstream KOReader uses **luacheck**. This repo uses **selene** instead, because luacheck was unworkable on the dev machine (Arch with Lua 5.5, missing `argparse`/`lfs`). The two configs are not interchangeable:

- `selene.toml` composes std `lua51+koreader`.
- `koreader.yml` is the project-local std file. It declares the KOReader runtime globals (`G_reader_settings`, `G_defaults`) and patches selene's `lua51` base with LuaJIT 2.1 + LUA52COMPAT extensions (`bit`, `jit`, `_ENV`, `table.pack`, `table.unpack`).
- When a new plugin module starts using a new global, add it to `koreader.yml` under `globals:` with `any: true`. Do not write `read_globals` or `globals` in selene.toml — those aren't selene keys.
- `multiple_statements = "allow"` is intentional. KOReader idiom uses `if not foo then return end` one-liners pervasively; flagging them would be all noise.

## Module architecture

Three Lua modules form a thin pipeline. Read them in this order to understand the flow:

```
main.lua     UI/menu/settings (WidgetContainer subclass)
   |
   v   doSync()
sync.lua     Orchestrator: list -> filter -> download
   |
   v   uses
webdav.lua   WebDAV client (PROPFIND for listing, GET for download)
```

Non-obvious points across files:

- **Settings namespace**: every setting is keyed `webdav_autosync_<name>` in `G_reader_settings`. The `getSetting`/`saveSetting` helpers in `main.lua` add the prefix automatically — call them, don't touch `G_reader_settings` directly except for the auto-sync enable flag.
- **Auto-sync runs at most once per KOReader session** and **only in File Manager context** (`not self.ui.document`). The guard is the module-local `auto_sync_started` in `main.lua`. Don't introduce a new `G_*` global for this — that's how it was before; it was deliberately removed.
- **`webdav.lua` mirrors KOReader's own `apps/cloudstorage/webdavapi.lua`**: trailing slash required for PROPFIND, minimal `<allprop/>` body, `user`/`password` go in the request table (not as an `Authorization: Basic …` header), timeouts use `socketutil:set_timeout()`. Diverging from this pattern has historically broken servers like Nextcloud — keep parity unless there's a strong reason not to.
- **Recursion in `webdav.list_all`** issues one PROPFIND per directory with `Depth: 1`. The recursion's self-skip (`e_path_norm ~= url_path`) prevents the parent from re-listing itself; removing that check causes infinite recursion.
- **Cloud storage import** (`importFromCloudStorage` in `main.lua`) follows the upstream pattern used by `statistics.koplugin` and `vocabbuilder.koplugin`: it calls `self.ui.cloudstorage:onShowCloudStorageList(callback)` and lets KOReader present its own picker (server selection + folder navigation inside the server). The callback delivers a server object containing `name`, `type`, `address`, `username`, `password`, `url`, and the plugin imports those into its `server_url` (built from `address + url`), `username`, and `password` settings. If `type ~= "webdav"`, the import is rejected with a message — `onShowCloudStorageList` doesn't filter by type, so the validation is post-pick. The local download folder is **deliberately not** imported from upstream's `sync_dest_folder` — that's always user-chosen via "Choose download folder", since the cloud and local destinations are conceptually separate.
- **Filename preservation**: WebDAV filenames are kept as-is locally. An earlier version renamed downloaded EPUBs to `<dc:title>.epub`, but that broke the existence check on re-syncs (re-downloading every time). The plugin now relies on filenames being usable as-shipped from the server; KOReader's file browser displays the book title from metadata regardless of filename.

## KOReader plugin conventions this repo follows

- `_meta.lua` returns the plugin manifest table (`name`, `fullname`, `description`).
- `main.lua` returns a `WidgetContainer:extend{}` subclass with `name = "webdav_autosync"`.
- Menu entries are registered via `self.ui.menu:registerToMainMenu(self)` plus `addToMainMenu(menu_items)`.
- Dispatcher actions (e.g. `WebDAVSyncNow`) are registered in `init()` and dispatched to handlers named `on<Event>` (e.g. `onWebDAVSyncNow`).
- Indentation: 4 spaces. Function naming: `camelCase` for methods, `snake_case` for module-local helpers (matches KOReader upstream).

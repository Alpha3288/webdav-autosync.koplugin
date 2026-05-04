# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A KOReader plugin (`.koplugin` directory) that syncs files from a WebDAV server to a local folder. Loaded by KOReader at runtime; **cannot be executed standalone** — it `require`s KOReader-only modules (`dispatcher`, `ui/widget/*`, `socketutil`, `ffi/zip`, `ui/network/manager`).

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

Four Lua modules form a thin pipeline. Read them in this order to understand the flow:

```
main.lua          UI/menu/settings (WidgetContainer subclass)
   |
   v   doSync()
sync.lua          Orchestrator: list -> filter -> download -> rename
   |
   v   uses
webdav.lua        WebDAV client (PROPFIND for listing, GET for download)
epub_metadata.lua EPUB title extraction (used to rename downloaded .epub files)
```

Non-obvious points across files:

- **Settings namespace**: every setting is keyed `webdav_autosync_<name>` in `G_reader_settings`. The `getSetting`/`saveSetting` helpers in `main.lua` add the prefix automatically — call them, don't touch `G_reader_settings` directly except for the auto-sync enable flag.
- **Auto-sync runs at most once per KOReader session** and **only in File Manager context** (`not self.ui.document`). The guard is the module-local `auto_sync_started` in `main.lua`. Don't introduce a new `G_*` global for this — that's how it was before; it was deliberately removed.
- **`webdav.lua` mirrors KOReader's own `apps/cloudstorage/webdavapi.lua`**: trailing slash required for PROPFIND, minimal `<allprop/>` body, `user`/`password` go in the request table (not as an `Authorization: Basic …` header), timeouts use `socketutil:set_timeout()`. Diverging from this pattern has historically broken servers like Nextcloud — keep parity unless there's a strong reason not to.
- **Recursion in `webdav.list_all`** issues one PROPFIND per directory with `Depth: 1`. The recursion's self-skip (`e_path_norm ~= url_path`) prevents the parent from re-listing itself; removing that check causes infinite recursion.
- **EPUB rename after download** is best-effort: `os.rename` first, ZIP-style fallback (open/read/write/remove) if rename fails across filesystems. The `extract_title` flow opens `META-INF/container.xml`, reads the rootfile path, then parses `<dc:title>` from the OPF.

## Known behavioral issue (not yet fixed)

In `sync.lua`, files are skipped when they exist locally — but the existence check uses the original WebDAV filename, while EPUBs are then *renamed* to `<title>.epub`. So renamed EPUBs get re-downloaded on every sync. Either skip the rename, or change the existence check to also look for the title-renamed variant. Flag this if a user reports redundant downloads.

## KOReader plugin conventions this repo follows

- `_meta.lua` returns the plugin manifest table (`name`, `fullname`, `description`).
- `main.lua` returns a `WidgetContainer:extend{}` subclass with `name = "webdav_autosync"`.
- Menu entries are registered via `self.ui.menu:registerToMainMenu(self)` plus `addToMainMenu(menu_items)`.
- Dispatcher actions (e.g. `WebDAVSyncNow`) are registered in `init()` and dispatched to handlers named `on<Event>` (e.g. `onWebDAVSyncNow`).
- Indentation: 4 spaces. Function naming: `camelCase` for methods, `snake_case` for module-local helpers (matches KOReader upstream).

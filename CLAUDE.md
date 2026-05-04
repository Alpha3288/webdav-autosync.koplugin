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
main.lua     UI/menu/settings + lifecycle event handlers
             (WidgetContainer subclass — file manager AND reader contexts).
   |
   v   doSync({is_auto = ...})         book full-library
   v   doProgressSync({manual,         progress full-library
   v                  interactive})
   v   doProgressSyncForBook(book_rel) progress scoped (one PROPFIND, close trigger)
sync.lua     Books: run_sync (one-way) | plan (two-way).
             Progress: plan_progress (full library) | plan_progress_book (one book).
             Shared: diff_indices, do_action, save_cache.
   |
   v   uses
webdav.lua   WebDAV client (PROPFIND list, GET download, PUT upload, MKCOL).
```

Non-obvious points across files:

- **Settings namespace**: every setting is keyed `webdav_autosync_<name>` in `G_reader_settings`. The `getSetting`/`saveSetting` helpers in `main.lua` add the prefix automatically — call them, don't touch `G_reader_settings` directly except for the three toggle flags `webdav_autosync_books_auto`, `webdav_autosync_books_two_way`, and `webdav_autosync_progress_auto` and the numeric `webdav_autosync_cooldown_seconds` setting. (The toggle keys were renamed from `webdav_autosync_enabled`, `webdav_autosync_two_way`, and `webdav_autosync_progress` in v1.2.0 to disambiguate book vs progress sync; no migration shim — users on the old keys had their toggles reset to default. The cooldown key was added in v1.4.0.)
- **Trigger taxonomy and unified cooldown** — automatic syncs (book and progress) are gated by a single shared cooldown in `main.lua`: module-local `auto_sync_last_run` + `get_cooldown()` (reads `webdav_autosync_cooldown_seconds`, default 120 s, range 0–1800 s in 30 s steps; 0 disables). The user-settable cooldown was added in v1.4.0 — earlier versions hardcoded 120 s. The cooldown check lives at the *event-handler level*, not inside the runners — once a chain (e.g. Resume's progress → book sync via `on_done`) is admitted, it runs to completion as one logical operation under one cooldown slot. Manual entry points call `mark_auto_run()` at start to bump the timestamp without checking, so subsequent auto triggers debounce naturally.
  - **Per-book carve-out for close**: `last_close_book_rel` tracks which book the last close-triggered sync was for. Closing a *different* book bypasses `should_run_auto()` because each book's `.sdr/` is independent — no overlap with the prior sync, no rate-limit benefit to skipping it. Only consecutive closes of the *same* book are debounced.
  - There were previously per-type debounces (`progress_sync_last_run` 30 s, `book_sync_last_run` 60 s) and an even earlier once-per-session boolean (`auto_sync_started`); both were replaced when the trigger taxonomy was simplified for v1.3.0. Don't reintroduce per-type cooldowns or per-session booleans.
- **Silent vs interactive triggers**:
  - *Silent* — `onCloseDocument`: scoped sync of just the closed book's `.sdr/` via `sync.plan_progress_book` (one PROPFIND, no full library walk). Conflicts are **deferred** (not resolved, not reported, cache rows for conflicting entries are not updated). The next interactive trigger re-detects and surfaces them.
  - *Interactive* — `onResume`, plugin `init()` startup, manual menu/Dispatcher entry: full-library reconcile via `plan_progress`, then chain `resolveConflictsInteractive` over any pending conflicts.
  - Auto interactive triggers (Resume, startup) silently no-op when offline; manual triggers prompt for Wi-Fi via the existing `ConfirmBox` path.
  - **UI feedback for progress sync is gated on `interactive`, not `manual`** (fixed in v1.4.2). All three callers of `runProgressSync` (startup, Resume, manual) get the "Syncing reading progress…" InfoMessage, the summary popup, and any `plan_progress` failure popup. Pre-v1.4.2 the gate was `manual`, so auto interactive runs went through silently and a failed `plan_progress` only logged at `dbg`. The matching close trigger stays silent because it goes through `doProgressSyncForBook`, a separate code path that never touches `runProgressSync`. Book sync's `runTwoWaySync` already shows its UI unconditionally; this just brings progress sync in line.
  - **`onSuspend` is intentionally absent.** It existed in v1.1.0–v1.2.x but was removed in v1.3.0 — Suspend can't show interactive UI, and a full library walk during suspension burns rate-limit budget on quota-enforcing WebDAV servers for limited benefit (the close trigger already pushed the just-edited book; the rest of the library hasn't changed in the second between close and suspend). Reintroducing it requires a strong reason.
  - Book auto-sync only fires from the interactive event set (init + Resume, chained after progress sync via `on_done`); the close trigger is progress-only and scoped.
  - Book auto-sync is still **file-manager-only** (`not self.ui.document`) — running a full library scan from inside a reader context is disruptive. Progress sync runs in either context.
- **`webdav.lua` mirrors KOReader's own `apps/cloudstorage/webdavapi.lua`**: trailing slash required for PROPFIND, minimal `<allprop/>` body, `user`/`password` go in the request table (not as an `Authorization: Basic …` header), timeouts use `socketutil:set_timeout()`. Diverging from this pattern has historically broken servers like Nextcloud — keep parity unless there's a strong reason not to.
- **Recursion in `webdav.list_all`** issues one PROPFIND per directory with `Depth: 1`. The recursion's self-skip (`e_path_norm ~= url_path`) prevents the parent from re-listing itself; removing that check causes infinite recursion. Two encoding invariants matter here:
  - Recursion URLs use `e.href_raw` (the wire-format, percent-encoded href as the server returned it), **not** the decoded `e.href`. Some servers (Koofr's HTTP frontend in particular) return 400 Bad Request when handed a request URL containing literal spaces or other unescaped reserved characters — which is exactly what happened pre-v1.4.1, since `parse_propfind_response` decoded the href before recursion. The bug went undiagnosed for months because the v1.3.0/v1.4.0 work mistakenly attributed the symptom to rate limiting; the actual fix is to keep the encoded href on the wire.
  - The self-skip comparison decodes `url_path` before comparing against the (decoded) `e.path`. Since the recursion now passes encoded URLs back into `list_one`, the request URL's path retains `%xx` escapes; without the decode step the self-skip would never match its own entry, the parent would re-list itself, and infinite recursion would only be averted by an eventual server error.
  - External consumers of `list_all` results (`download_file`, `upload_file`) keep using `e.href_full` (decoded) and re-encode via `url_encode` — that path is unchanged.
- **Cloud storage import** (`importFromCloudStorage` in `main.lua`) handles two KOReader generations:
  - Pre-2026.03: `plugins/cloudstorage.koplugin/` exists and registers an instance on `self.ui.cloudstorage`. Call `cs:onShowCloudStorageList(callback)`; KOReader shows its own picker (server selection + folder navigation inside the server). Same pattern statistics/vocabbuilder used to follow.
  - 2026.03+: the cloudstorage plugin was deleted from KOReader. `self.ui.cloudstorage` is permanently nil. Upstream plugins migrated to `SyncService` (`require("frontend/apps/cloudstorage/syncservice")`); we do the same — `picker = SyncService:new{}; picker.onConfirm = handler; UIManager:show(picker)`.
  - Both routes deliver a server object with the same fields (`name`, `type`, `address`, `username`, `password`, `url`); `applyCloudStorageEntry` consumes it identically. The post-pick `if type ~= "webdav"` check still matters because `SyncService` also offers Dropbox.
  - The local download folder is **deliberately not** imported from upstream's `sync_dest_folder` — that's always user-chosen via "Choose download folder", since the cloud and local destinations are conceptually separate.
- **Filename preservation**: WebDAV filenames are kept as-is locally. An earlier version renamed downloaded EPUBs to `<dc:title>.epub`, but that broke the existence check on re-syncs (re-downloading every time). The plugin now relies on filenames being usable as-shipped from the server; KOReader's file browser displays the book title from metadata regardless of filename.
- **Two-way book sync** (opt-in via the `webdav_autosync_books_two_way` toggle; only affects book sync, not progress sync — progress sync is always bidirectional):
  - State cache lives at `<settings_dir>/webdav_autosync_state.lua` via `LuaSettings`. Schema: `files = { [relpath] = { remote_etag, remote_mtime, local_mtime, local_size } }`. Updated in-memory after each successful action and flushed at end of sync; partial syncs leave a consistent partial cache. Book and progress sync share this single cache — relpaths are disjoint by construction (`is_sidecar_path` = "any path segment ending in `.sdr`").
  - Change detection: remote-changed if etag or mtime differs from cache; local-changed if mtime or size differs. Both changed = conflict.
  - **First two-way run after enabling baselines silently** any file that exists on both sides without a cache entry — no transfer, no conflict dialog. Avoids dialog spam on libraries previously synced one-way. The same baseline rule applies to progress sync's first run. Side effect: pre-existing local edits made before two-way was enabled are not preserved as a "changed" signal.
  - **No-deletion policy**: if a file disappears on one side after being cached, the plugin neither re-creates it nor propagates the deletion. The cache entry is kept so subsequent runs continue to skip it. Applies to both book and progress sync.
  - **Conflict UI**: `resolveConflictsInteractive` chains a `ButtonDialogTitle` per conflict (Keep local / Keep remote / Skip). Dialogs are sequential — each pick triggers the next dialog, then the summary fires when the chain finishes. UI input requires this chained-callback approach because `do_action` is synchronous; do not attempt to surface conflicts inside the planner.
  - **Conflict resolution policy is shared between book and progress sync**: silent triggers defer; interactive triggers run the dialog chain. The previous "auto silently skips conflicts and counts them in the summary" behavior was removed when the trigger taxonomy was introduced — auto runs from init() and Resume now go through the dialog chain because the user is present.
  - **Same extension filter applies in both directions**: only files matching `webdav_autosync_file_extensions` (or the default KOReader format list) are considered for either upload or download. Random non-book files in the download folder are not pushed. Progress sync uses a separate filter (`is_sidecar_path`) and ignores the extension setting entirely.
  - **Upload path**: `webdav.upload_file` does PUT; `webdav.ensure_remote_dirs` walks parent path segments and MKCOLs each (treating 405 = already exists as success). PUT response ETag is captured when the server provides one; if absent, the next PROPFIND fills it in for subsequent change detection.

- **Progress sync** (opt-in via the `webdav_autosync_progress_auto` toggle, default off):
  - Reuses the two-way machinery via `sync.plan_progress` and `sync.plan_progress_book` (alongside `sync.plan`); `do_action`, `save_cache`, and `resolveConflictsInteractive` are shared with book sync without modification. The shared `diff_indices` helper in `sync.lua` is what makes that work — the three planners only differ in how they build the remote/local indices.
  - **Triggered by**: `onCloseDocument` (silent, **scoped to the just-closed book** via `plan_progress_book` — one PROPFIND), `onResume` (interactive, full reconcile via `plan_progress`), `init()` (interactive, full reconcile). Plus the `webdav_progress_sync_now` Dispatcher action and the "Sync reading progress now" menu item, which are always interactive, full-library, and bypass the cooldown.
  - **Why close is scoped, not full-library**: rate-limited WebDAV providers returned 400s under v1.1.0–v1.2.x's pattern of running a full recursive PROPFIND on every close. v1.3.0 changed the close trigger to walk only `<book>.sdr/` — one network round-trip per close. The catch-up moments (Resume, startup, manual) still do the full reconcile. Don't expand the close trigger back to a full walk without first proving the rate-limit story has changed.
  - **Sidecar location requirement**: only KOReader's default `document_metadata_folder = "doc"` is supported, since only that mode places `.sdr` directories inside the synced library tree. With `dir` or `hash` modes the sidecars are off-tree and have no remote mapping; silent triggers no-op (one debug log line), interactive manual triggers show an `InfoMessage` explaining the limit. Do not try to chase per-mode sidecar paths — the remote layout has no place for them.
  - **Why we don't auto-resolve progress conflicts via mtime**: an earlier draft proposed mtime-wins on close so cross-device reading would be self-healing. We dropped it: the user wants conflicts surfaced explicitly at the next interactive moment. Don't reintroduce auto-resolve without explicit say-so.
  - **Device-specific paths in synced sidecars are expected and self-heal — do NOT rewrite them on the wire.** A freshly downloaded `metadata.<ext>.lua` on device B still contains the source device's `doc_path` (e.g. `/mnt/us/eBooks/foo.epub`) and a `-- /path/to/sidecar` header comment, both pointing at device A's filesystem. KOReader handles this on its own: `DocSettings:open(doc_path)` (`frontend/docsettings.lua`) loads the stored data and then unconditionally clobbers `data.doc_path = doc_path` with the caller-supplied current path, and `util.writeToFile` (`frontend/util.lua`) regenerates the leading `-- <filepath>` comment from the *writing* device's sidecar path on every flush. So both stale fields are corrected on the first open + flush of the book on the destination device. Reading position, bookmarks, highlights, percent finished, last xpointer, partial MD5 are all device-agnostic and consume cleanly. Editing sidecars in flight would be touching live KOReader state files and is much riskier than letting KOReader self-heal — don't go there.
  - **`is_doc_only = false`** stays — without it, lifecycle events fired by the reader (`CloseDocument`, `Resume`) wouldn't reach the plugin.

## Releases

A tag matching `v*` triggers `.github/workflows/release.yml`, which builds `webdav-autosync.koplugin-<tag>.zip` (containing the plugin folder with only the runtime files: `_meta.lua`, `main.lua`, `sync.lua`, `webdav.lua`, `LICENSE`, `README.md` — dev tooling like `Makefile`, `selene.toml`, `koreader.yml`, `.editorconfig`, `CLAUDE.md` is excluded) and publishes a GitHub Release with auto-generated notes.

The workflow guards against tag/version drift: the tag (without leading `v`) must match `version` in `_meta.lua` or it fails fast. To cut a release: bump `_meta.lua` `version` first, commit, then `git tag vX.Y.Z && git push origin vX.Y.Z`.

`appstore.koplugin` discovers this plugin via GitHub Search (it pulls the repo zipball at HEAD, not the release asset). Repo discoverability requires either the `koreader-plugin` GitHub topic on the repo, or a name matching `*.koplugin` (which this repo satisfies). Releases are still useful for users who download manually.

## KOReader plugin conventions this repo follows

- `_meta.lua` returns the plugin manifest table (`name`, `fullname`, `description`).
- `main.lua` returns a `WidgetContainer:extend{}` subclass with `name = "webdav_autosync"`.
- Menu entries are registered via `self.ui.menu:registerToMainMenu(self)` plus `addToMainMenu(menu_items)`.
- Dispatcher actions (e.g. `WebDAVSyncNow`, `WebDAVProgressSyncNow`) are registered in `init()` and dispatched to handlers named `on<Event>` (e.g. `onWebDAVSyncNow`, `onWebDAVProgressSyncNow`). Lifecycle events (`CloseDocument`, `Suspend`, `Resume`) follow the same `on<Event>` convention but are broadcast by KOReader rather than dispatcher actions; their handlers must NOT return `true` (other plugins still need the event).
- Indentation: 4 spaces. Function naming: `camelCase` for methods, `snake_case` for module-local helpers (matches KOReader upstream).

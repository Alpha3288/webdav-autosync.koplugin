# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A KOReader plugin (`.koplugin` directory) that syncs files from a WebDAV server to a local folder. Loaded by KOReader at runtime; **cannot be executed standalone** — it `require`s KOReader-only modules (`dispatcher`, `ui/widget/*`, `socketutil`, `ui/network/manager`).

## Development commands

```sh
make check    # lint + parse-check (run before committing)
make lint     # selene static analysis only
make parse    # LuaJIT parse-check every .lua file
```

No tests. Local validation = static checks; behavioral testing requires installing into a KOReader instance.

## Coding conventions (project-specific)

User-set rules; follow in source files (`*.lua`) and user-facing strings:

- **No vendor / WebDAV-provider names in code or comments.** Use generic phrasing — "strict WebDAV servers", "the server" — instead of naming Koofr, Nextcloud, ownCloud, etc. Vendor symptoms can be described generically (e.g. "returns 400 on unencoded reserved characters"). CLAUDE.md and commit messages are the place for vendor names when context demands them.
- **No real book titles or library contents in code or comments.** Use generic placeholders (`<book>.epub`, `Some Book.sdr/metadata.epub.lua`). Applies to fixtures, log examples in comments, `_meta.lua` description strings.

Both rules apply to CLAUDE.md prose where it would leak a specific user's setup. Naming the offending vendor / dataset is acceptable only in CLAUDE.md when discussing prior incidents.

## Linter setup is non-standard

This repo uses **selene** instead of upstream KOReader's **luacheck** (luacheck was unworkable on the dev machine — Arch with Lua 5.5, missing `argparse`/`lfs`):

- `selene.toml` composes std `lua51+koreader`.
- `koreader.yml` declares KOReader runtime globals (`G_reader_settings`, `G_defaults`) and patches selene's `lua51` with LuaJIT 2.1 + LUA52COMPAT extensions (`bit`, `jit`, `_ENV`, `table.pack`, `table.unpack`).
- New global → add to `koreader.yml` under `globals:` with `any: true`. Don't write `read_globals` / `globals` in `selene.toml` — those aren't selene keys.
- `multiple_statements = "allow"` is intentional: KOReader idiom uses `if not foo then return end` one-liners pervasively.

## Module architecture

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

### Settings & gating

- **Settings namespace**: every key is `webdav_autosync_<name>` in `G_reader_settings`. Use `getSetting` / `saveSetting` helpers in `main.lua` (they add the prefix); touch `G_reader_settings` directly only for toggle flags and the cooldown numerics.
- Toggle flags: `webdav_autosync_master` (master gate), `webdav_autosync_{books,progress}_on_{startup,resume[,close]}` (per-event), `webdav_autosync_books_two_way` (book sync mode, applies to manual + auto).
- **Master + per-event gating** — `is_master_on()` and `event_enabled(key)` in `main.lua` are canonical. `event_enabled` short-circuits on master off; menu rows use `enabled_func` to grey out when master is off. Manual entries (menu items, Dispatcher actions `webdav_sync_now` / `webdav_progress_sync_now`) bypass both. **All gating happens at the event-handler level** (`init()`'s `scheduleIn`, `onResume`, `onCloseDocument`); runners (`doProgressSync`, `doProgressSyncForBook`, `maybeRunBookAutoSync`) intentionally don't re-check toggles. Don't reintroduce toggle checks inside the runners — they'd shadow handler-level gating and create a second source of truth.

### Trigger taxonomy and cooldowns

Two independent persistent cooldowns gate auto syncs:

- **Full-reconcile cooldown** (`webdav_autosync_cooldown_seconds`, default 300 s, range 0–1800 s in 30 s steps; 0 disables) gates startup, Resume, and chained book auto-sync. State key `last_auto_run_at`. Manual entries call `mark_auto_run()`.
- **Close-trigger cooldown** (`webdav_autosync_close_cooldown_seconds`, default 30 s, range 0–600 s in 10 s steps; 0 disables) gates only the scoped close-trigger sync (one PROPFIND on `<book>.sdr/`, much cheaper). State keys `last_close_run_at` + `last_close_book_rel`. `mark_close_run(book_rel)` bumps both atomically.
- **State persistence**: timestamps + `last_close_book_rel` live in `<settings_dir>/webdav_autosync_state.lua` via `sync.read_state` / `sync.write_state`. State-file (not `G_reader_settings`) was chosen so wiping the state to force a baseline rebuild also resets the cooldowns. Same `LuaSettings` instance as the per-file `files` table (separate keys).
- **The two cooldowns are fully independent.** A close at t=10 doesn't push back the next Resume sync, and vice versa. Manual entries bump only the full-reconcile timestamp — close path is too cheap to bother suppressing.
- **Per-book carve-out for close**: `should_run_close(book_rel)` returns true unconditionally for a different book — only consecutive closes of the *same* book are debounced.
- Cooldown checks live at the event-handler level. Once a chain (e.g. Resume's progress → book sync via `on_done`) is admitted, it runs to completion under one cooldown slot.
- **Startup `scheduleIn` runs at most once per KOReader process** (`startup_sync_scheduled` module-local boolean). KOReader instantiates the plugin separately under `FileManager` and `ReaderUI`; without the guard, every FM↔Reader transition outside the cooldown window fires a full-library sync. The boolean is module-local (shared across FM and Reader instances since `require("main")` returns the same module table). Don't re-run startup sync on Reader→FM transitions — Resume covers wake-from-sleep, manual entries cover everything else, and the close trigger already pushed the just-edited book.
- Don't reintroduce per-sync-kind cooldowns (book vs progress) or per-session booleans — the split is per-*trigger-kind* (close vs everything-else).

### Silent vs interactive triggers

- *Silent* — `onCloseDocument`: scoped sync of the closed book's `.sdr/` via `sync.plan_progress_book` (one PROPFIND). Conflicts are **deferred** — not resolved, not reported, cache rows for conflicting entries not updated. The next interactive trigger re-detects and surfaces them.
- *Interactive* — `onResume`, `init()` startup, manual menu/Dispatcher: full-library reconcile via `plan_progress`, then chain `resolveConflictsInteractive`.
- **Offline handling for auto interactive triggers** — Resume and startup poll `NetworkMgr:isOnline()` AND `NetworkMgr:hasDefaultRoute()` themselves with bounded retries (`defer_until_online`, 6 × 5 s = ~30 s, then silent give-up: `skip reason=offline-give-up online=… has_route=…`). Defer happens *after* toggle and cooldown gates; cooldown is consumed (`mark_auto_run()`) only after both checks pass, so a Wi-Fi-still-reconnecting Resume doesn't burn the next 5 min.
  - **Why both `isOnline` + `hasDefaultRoute`**: `isOnline()` is `canResolveHostnames()` (DNS probe to `dns.msftncsi.com`) — DNS can succeed against cached records before the kernel routing table is populated. The post-suspend race: DNS comes back first, helper returns "online", `mark_auto_run()` fires, then PROPFIND fails with "Network is unreachable" and the cooldown is burned for nothing. `hasDefaultRoute()` (UDP `setpeername` to a doc-range IP) catches that case. The defer/give-up log lines report both flags.
  - **Don't use `NetworkMgr:willRerunWhenOnline` for auto-trigger gating.** It only registers the callback in the `not isConnected()` branch (`frontend/ui/network/manager.lua` lines 674-686 in v2026.03). When `isConnected()` is cached true but `isOnline()` (DNS) currently fails — the post-suspend race, since `NetworkListener:onResume` flips `is_connected=true` before DNS catches up — it calls `beforeWifiAction()` *without* the callback and the caller waits on an event that never fires. Polling sidesteps this. It's also tied to the `wifi_enable_action` state machine (turn_on / prompt / ignore), which auto triggers shouldn't engage.
  - Manual triggers prompt for Wi-Fi via `ConfirmBox`/`turnOnWifi`. Close-trigger silently no-ops when offline (debounced; next interactive trigger picks it up via the full reconcile). Runner-level `isOnline()` checks in `doProgressSync`, `maybeRunBookAutoSync`, `doProgressSyncForBook` are kept as defense-in-depth.
  - The retry count threads as an optional first arg through `onResume` and `run_startup_sync`. KOReader's `Resume` event has no payload, so the extra arg is invisible to broadcast callers; only the helper's own `scheduleIn` re-entries pass it.
- **UI feedback for progress sync is gated on `interactive`, not `manual`** — all three `runProgressSync` callers (startup, Resume, manual) get the InfoMessage, summary popup, and `plan_progress` failure popup. Close trigger goes through `doProgressSyncForBook` (separate code path) and stays silent. Book sync's `runTwoWaySync` already shows its UI unconditionally.
- **`onSuspend` is intentionally absent.** Suspend can't show interactive UI, and a full library walk burns rate-limit budget on quota-enforcing servers for limited benefit (close trigger already pushed the just-edited book). Reintroducing requires a strong reason.
- **Chain logic in `init()` and `onResume`** — both check `progress_on_<event>` and `books_on_<event>` together. If progress is on, run progress; chain books in `on_done` only when books is also on. If progress is off but books is on, run books standalone. If both off, bail before the cooldown check (no cooldown burn for no-op). Log lines include the active flags.
- **Book auto-sync is file-manager-only** (`not self.ui.document`). Progress sync runs in either context.

### WebDAV client conventions

- **`webdav.lua` mirrors KOReader's `apps/cloudstorage/webdavapi.lua`**: trailing slash required for PROPFIND, minimal `<allprop/>` body, `user`/`password` go in the request table (not as an `Authorization: Basic …` header), timeouts use `socketutil:set_timeout()`. Diverging has historically broken servers like Nextcloud — keep parity.
- **`webdav.list_all` fast path** — one PROPFIND with `Depth: infinity` returns the entire subtree in one round trip (5–50× faster than recursive Depth: 1 for `plan_progress`). When the server refuses (some hosted providers return `403`/`507`/`501`/etc.) the call falls back to recursive Depth: 1 walk and memos the host in `infinity_unsupported` (in-process, cleared at restart). Non-HTTP failures (timeout, DNS, auth) are *not* memoed — surface them immediately. Both paths are parsed by the same `parse_propfind_response` and obey the same self-skip rule.
- **Recursion in `webdav.list_all` fallback** — one PROPFIND per directory with `Depth: 1`. Self-skip (`e_path_norm ~= url_path`) prevents infinite recursion. Two encoding invariants:
  - Recursion URLs use `e.href_raw` (wire-format, percent-encoded), **not** decoded `e.href`. Some servers return 400 on literal spaces or unescaped reserved chars — don't decode the href before recursing.
  - The self-skip comparison decodes `url_path` before comparing against decoded `e.path`. Without the decode, the request URL's `%xx` escapes prevent the self-skip from matching its own entry.
- **Encoding contract** — `download_file`, `upload_file`, `mkcol`, `get_props` all accept **decoded** URLs and call `url_encode(normalize_url(...))` internally. `list_one` is the **single exception**: it accepts an already-encoded URL because `list_all`'s recursion has to feed it pre-encoded `href_raw`, and re-encoding inside `list_one` would double-encode the `%`. Any caller that hands `list_one` a self-constructed URL (e.g. `build_remote_url(...)` output, decoded) must wrap it in `webdav.url_encode(...)` — `plan_progress_book` does. `webdav.url_encode` is exported.

### Cloud storage import

`importFromCloudStorage` in `main.lua` runs a fallback chain. Both branches are live in upstream master as of 2026-05; the SyncService branch was added defensively.

- **Legacy path (preferred):** if `self.ui.cloudstorage` exists, call `cs:onShowCloudStorageList(callback)`. This is what every shipped KOReader version currently goes through.
- **Forward-compatible fallback:** if `self.ui.cloudstorage` is nil, fall through to `SyncService` (`require("frontend/apps/cloudstorage/syncservice")`): `picker = SyncService:new{}; picker.onConfirm = handler; UIManager:show(picker)`. Don't delete this branch — it's defensive against upstream eventually removing the legacy plugin.
- Both routes deliver a server object with the same fields (`name`, `type`, `address`, `username`, `password`, `url`); `applyCloudStorageEntry` consumes it identically. The post-pick `if type ~= "webdav"` check matters because `SyncService` also offers Dropbox.
- The local download folder is **deliberately not** imported from upstream's `sync_dest_folder` — always user-chosen via "Choose download folder", since cloud and local destinations are conceptually separate.

### Two-way book sync & state cache

Opt-in via `webdav_autosync_books_two_way`; only affects book sync (progress sync is always bidirectional).

- **State cache** at `<settings_dir>/webdav_autosync_state.lua` via `LuaSettings`. Schema: `files = { [relpath] = { remote_etag, remote_mtime, local_mtime, local_size, local_hash } }`. Updated in-memory after each successful action, flushed at end of sync (partial syncs leave a consistent partial cache). Book and progress sync share this single cache — relpaths disjoint by construction (`is_sidecar_path` = "any path segment ending in `.sdr`"). `local_hash` is sidecar-only.
- **Change detection**: remote-changed if etag or mtime differs from cache; local-changed if size differs OR (when both sides have a content hash) hash differs OR (fallback) mtime drifts ≥ **2 s** from cache. Both changed = conflict.
  - **Mtime tolerance ≥ 2 s** because vfat/exFAT user-storage rounds mtime to 2-s granularity on flush.
  - **Content hash for sidecars**: KOReader rewrites sidecars verbatim during normal operation (coverbrowser metadata extraction, auto-save flushes after self-healing `doc_path` on first open), advancing mtime by minutes while leaving bytes byte-identical. Without hashing every sidecar looked locally-changed → full re-upload on every progress sync. `walk_local_sidecars` and `stat_local` capture `loc.hash = util.partialMD5(path)` for sidecars (cheap — a few KB, ms-scale); `local_changed` trusts hash absolutely when both sides have one. **Books are NOT hashed** (too large to fingerprint on every walk) — they fall through to size+mtime+tolerance.
  - **Hash reuse from cache** — `walk_local_sidecars` takes the cache and skips `partialMD5` for entries whose `(size, mtime)` exactly match the cache row, returning `cached.local_hash` directly. The verbatim-rewrite case still works: same content but new flush time → cache mismatch → re-hash → `local_changed` correctly returns false. Implementation in `resolve_sidecar_hash`, used by `walk_local_sidecars` and `plan_progress_book`. `stat_local` (post-write) still hashes unconditionally.
  - Don't reintroduce strict mtime equality, and don't drop the mtime fallback (book files still need it).
- **First two-way run silently baselines** files existing on both sides without a cache entry — no transfer, no conflict dialog. Same baseline rule for progress sync's first run. Side effect: pre-existing local edits before two-way was enabled aren't preserved as a "changed" signal.
- **No-deletion policy**: a file disappearing on one side after being cached is neither re-created nor propagated. Cache entry is kept so subsequent runs skip it. Applies to both book and progress sync.
- **Conflict UI**: `resolveConflictsInteractive` chains a `ButtonDialogTitle` per conflict (Keep local / Keep remote / Skip). Sequential — each pick triggers the next, then the summary fires. Required because `do_action` is synchronous; don't try to surface conflicts inside the planner.
- **Conflict resolution policy is shared between book and progress sync**: silent triggers defer; interactive triggers run the dialog chain. Don't reintroduce "auto silently skips conflicts and counts them in the summary" — auto runs from `init()`/Resume now go through the dialog chain because the user is present.
- **Same extension filter applies in both directions** (book sync only): only files matching `webdav_autosync_file_extensions` (or default KOReader format list). Random non-book files in the download folder are not pushed. Progress sync uses `is_sidecar_path` and ignores the extension setting.
- **Upload path**: `webdav.upload_file` does PUT; `webdav.ensure_remote_dirs` walks parent path segments and MKCOLs each (treating 405 = already exists as success). PUT response ETag is captured when the server provides one; if absent, the next PROPFIND fills it in.
- **Filename preservation**: WebDAV filenames are kept as-is locally. Don't reintroduce renaming downloaded EPUBs to `<dc:title>.epub` — that broke the existence check on re-syncs (re-downloading every time).

### Progress sync

Opt-in, gated by per-event toggles `webdav_autosync_progress_on_{startup,resume,close}` plus master, all default off.

- Reuses two-way machinery via `sync.plan_progress` and `sync.plan_progress_book`; `do_action`, `save_cache`, `resolveConflictsInteractive` are shared with book sync without modification. Shared `diff_indices` helper in `sync.lua` is what makes that work — the three planners only differ in how they build the remote/local indices.
- **Triggered by**: `onCloseDocument` (silent, scoped via `plan_progress_book`), `onResume` (interactive, full reconcile), `init()` (interactive, full reconcile). Manual `webdav_progress_sync_now` Dispatcher action and "Sync reading progress now" menu item bypass cooldown + toggles.
- **Why close is scoped, not full-library**: rate-limited providers returned 400s on full PROPFIND-on-every-close. Close walks only `<book>.sdr/` — one round-trip. Don't expand back to a full walk without proving the rate-limit story has changed.
- **Sidecar location requirement**: only KOReader's default `document_metadata_folder = "doc"` is supported (only mode that places `.sdr` inside the synced library tree). With `dir` or `hash` modes, sidecars are off-tree with no remote mapping; silent triggers no-op (one debug log line), interactive manual triggers show an `InfoMessage`.
- **Don't auto-resolve progress conflicts via mtime.** An earlier draft proposed mtime-wins on close for cross-device self-healing; we dropped it because the user wants conflicts surfaced explicitly at the next interactive moment. Don't reintroduce without explicit say-so.
- **Device-specific paths in synced sidecars are expected and self-heal — do NOT rewrite them on the wire.** A freshly downloaded `metadata.<ext>.lua` on device B still contains device A's `doc_path` (e.g. `/mnt/us/eBooks/foo.epub`) and a `-- /path/to/sidecar` header comment. KOReader handles it: `DocSettings:open(doc_path)` (`frontend/docsettings.lua`) clobbers `data.doc_path` with the caller-supplied current path; `util.writeToFile` (`frontend/util.lua`) regenerates the leading `-- <filepath>` comment from the writing device's sidecar path on every flush. Reading position, bookmarks, highlights, percent finished, last xpointer, partial MD5 are all device-agnostic. Editing sidecars in flight would touch live KOReader state files — don't go there.
- **`is_doc_only = false`** stays — without it, lifecycle events fired by the reader (`CloseDocument`, `Resume`) wouldn't reach the plugin.

### Debug logging

Every log line starts with `webdav_autosync:` so it can be greppd from `crash.log`. Format: `webdav_autosync: <action> [key=value …]` — scannable, greppable; don't log credentials (URLs are fine, passwords go in the request table).

- **`logger.info`** — trigger entry points (`trigger=startup|resume|close|manual_books|manual_progress`), sync start (`progress sync start`, `book sync start mode=…`), sync done summaries (`progress sync done downloaded=N uploaded=N …`). Always visible. Trigger firing is the most-asked-about diagnostic — don't bury it behind `dbg`.
- **`logger.dbg`** — gating decisions (`skip reason=disabled|cooldown|offline|metadata-folder-mode|not-configured|outside-library|debounce|reader-context`; `disabled` covers both master-off and per-event-off), per-file diff classifications (`diff rel=X decision=… reason=…`), per-action HTTP outcomes, planner index sizes, individual WebDAV requests (`PROPFIND|GET|PUT|MKCOL url=… status=…`), conflict resolution choices.
- **`logger.warn`** — real plan failures (`book sync plan failed`, etc.) and per-action failures from the close-trigger path (the only sync that doesn't surface failures via UI).
- Don't construct expensive log strings unconditionally — gate behind `if logger.is_dbg` if you'd need to walk a structure.

### Library refresh after writes

`notifyLibraryRefresh` in `main.lua`: every sync path that writes files locally collects the relpaths it wrote and hands them in after `save_cache`. Broadcasts:

- `Event:new("InvalidateMetadataCache", <book_file_path>)` per book — drops the SQLite-cached metadata row used by `coverbrowser.koplugin`. Without this, cover mosaic / list views show stale percent / cover until the next directory navigation.
- `Event:new("BookMetadataChanged")` (no `prop_updated` arg) — handled by `FileManager`, `FileManagerHistory`, `FileManagerCollection`, `FileSearcher`. Reader-side handlers (`ReaderCoptListener`, `ReaderFooter`) gate on `prop_updated`, so passing nil makes them no-op — safe to broadcast even from a reader context.
- Sidecar `metadata.<ext>.lua` rels map to `<stem>.<ext>` book paths via `^(.+)%.sdr/metadata%.([^.]+)%.lua$`. Other sidecar files (cover, custom_metadata) don't carry the book extension — they fall through to just the global `BookMetadataChanged`. Book-file rels (no `.sdr/` segment) used as-is.
- Helper is empty-safe — no-ops on nil/empty list, so callers can call it unconditionally on every sync exit path.

## Releases

A tag matching `v*` triggers `.github/workflows/release.yml`, which builds `webdav-autosync.koplugin-<tag>.zip` (runtime files only: `_meta.lua`, `main.lua`, `sync.lua`, `webdav.lua`, `LICENSE`, `README.md` — dev tooling like `Makefile`, `selene.toml`, `koreader.yml`, `.editorconfig`, `CLAUDE.md` excluded) and publishes a GitHub Release with auto-generated notes.

The workflow guards against tag/version drift: tag (without leading `v`) must match `version` in `_meta.lua` or it fails fast. To cut a release: bump `_meta.lua` `version`, commit, then `git tag vX.Y.Z && git push origin vX.Y.Z`.

`appstore.koplugin` discovers this plugin via GitHub Search (pulls the repo zipball at HEAD, not the release asset). Discoverability requires either the `koreader-plugin` GitHub topic or a name matching `*.koplugin` (which this repo satisfies).

## KOReader plugin conventions this repo follows

- `_meta.lua` returns the manifest table (`name`, `fullname`, `description`).
- `main.lua` returns a `WidgetContainer:extend{}` subclass with `name = "webdav_autosync"`.
- Menu entries via `self.ui.menu:registerToMainMenu(self)` + `addToMainMenu(menu_items)`.
- Dispatcher actions (e.g. `WebDAVSyncNow`, `WebDAVProgressSyncNow`) registered in `init()`, dispatched to handlers named `on<Event>`. Lifecycle events (`CloseDocument`, `Suspend`, `Resume`) follow the same `on<Event>` convention but are broadcast by KOReader; their handlers must NOT return `true` (other plugins still need the event).
- Indentation: 4 spaces. Naming: `camelCase` for methods, `snake_case` for module-local helpers (matches KOReader upstream).

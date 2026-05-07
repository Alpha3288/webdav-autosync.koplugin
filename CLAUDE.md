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
main.lua       Plugin entry point. WidgetContainer subclass, lifecycle hooks
               (init, onCloseDocument, onResume, onSuspend), Dispatcher
               registrations, addToMainMenu (uses event_toggle_row /
               spin_setting_row builders), doSync / doProgressSync /
               doProgressSyncForBook / maybeRunBookAutoSync entry points
               (resolve config, prompt for Wi-Fi if needed, dispatch into
               runner). Thin — no runners, no settings dialogs, no chain
               orchestrator.
settings.lua   Cooldown bounds + bounded getters, prefixed get/save against
               G_reader_settings, master+event gating, cooldown bookkeeping
               (should_run_auto, mark_auto_run, should_run_close, mark_close_run),
               state-file accessors (read_state, write_state — module-local).
triggers.lua   Resume defer + cancel, Kindle powerd unscheduled-wake classifier,
               online-defer poll, in-flight lock, schedule_startup_sync,
               run_resume_sync / run_startup_sync (fire-time gating),
               dispatch_auto_chain (3-branch chain orchestrator). Owns
               sync_in_flight, pending_resume_sync_fn, startup_sync_scheduled
               module-locals (shared between FM and Reader plugin instances
               via Lua's require cache).
runner.lua     run_planned (parameterized planner runner — replaces the
               three legacy runners), run_one_way (legacy download-only
               wrapper), conflict dialog chain, summary formatters
               (per-runner show_summary, chain show_chain_summary),
               chain stats accumulator (make_empty_chain_stats,
               merge_chain_stats, merge_plan_failure, chain_total_failed),
               init_stats_from_plan, run_action_loop, library refresh
               broadcast (notify_library_refresh).
ui.lua         Settings dialogs: set_webdav_server, import_from_cloud_storage,
               set_download_folder, set_file_extensions, the three SpinWidget
               settings (cooldown, close-cooldown, resume-settle, all
               backed by one make_spin_setting helper), help text.
sync.lua       Books: run_sync (one-way) | plan (two-way).
               Progress: plan_progress (full library) | plan_progress_book
               (one book).
               Shared: diff_indices, do_action, save_cache, rel_is_safe
               (path-traversal rejection).
webdav.lua     WebDAV client (PROPFIND list/get_props, GET download, PUT
               upload, MKCOL ensure_remote_dirs); private do_request helper
               threads socketutil's timeout pair around each call.
```

### Settings & gating

- **Settings namespace**: every key is `webdav_autosync_<name>` in `G_reader_settings`. Use `settings.get` / `settings.save` helpers (they add the prefix); touch `G_reader_settings` directly only for toggle flags and the cooldown numerics.
- Toggle flags: `webdav_autosync_master` (master gate), `webdav_autosync_{books,progress}_on_{startup,resume[,close]}` (per-event), `webdav_autosync_books_two_way` (book sync mode, applies to manual + auto).
- **Master + per-event gating** — `settings.is_master_on()` and `settings.event_enabled(key)` are canonical. `settings.event_enabled` short-circuits on master off; menu rows use `enabled_func` to grey out when master is off. Manual entries (menu items, Dispatcher actions `webdav_sync_now` / `webdav_progress_sync_now`) bypass both. **All gating happens at the event-handler level** (`init()`'s `scheduleIn`, `onResume` + `triggers.run_resume_sync`, `onCloseDocument`); runners (`doProgressSync`, `doProgressSyncForBook`, `maybeRunBookAutoSync`) intentionally don't re-check toggles. Don't reintroduce toggle checks inside the runners — they'd shadow handler-level gating and create a second source of truth.

### Trigger taxonomy and cooldowns

Two independent persistent cooldowns gate auto syncs:

- **Full-reconcile cooldown** (`webdav_autosync_cooldown_seconds`, default 300 s, range 0–1800 s in 30 s steps; 0 disables) gates startup, Resume, and chained book auto-sync. State key `last_auto_run_at`. Manual entries call `mark_auto_run()`.
- **Close-trigger cooldown** (`webdav_autosync_close_cooldown_seconds`, default 30 s, range 0–600 s in 10 s steps; 0 disables) gates only the scoped close-trigger sync (one PROPFIND on `<book>.sdr/`, much cheaper). State keys `last_close_run_at` + `last_close_book_rel`. `mark_close_run(book_rel)` bumps both atomically.
- **Resume settle delay** (`webdav_autosync_resume_settle_seconds`, default 15 s, range 0–60 s in 5 s steps; 0 disables) is *not* a cooldown — it's the wait window between `Resume` firing and the actual sync starting (see "Resume settle delay" subsection below). Lives next to the cooldowns in the menu because it's adjacent UX and uses the same SpinWidget pattern.
- **State persistence**: timestamps + `last_close_book_rel` live in `<settings_dir>/webdav_autosync_state.lua` via `settings.read_state` / `settings.write_state`. State-file (not `G_reader_settings`) was chosen so wiping the state to force a baseline rebuild also resets the cooldowns. Same `LuaSettings` instance as the per-file `files` table (separate keys).
- **The two cooldowns are fully independent.** A close at t=10 doesn't push back the next Resume sync, and vice versa. Manual entries bump only the full-reconcile timestamp — close path is too cheap to bother suppressing.
- **Per-book carve-out for close**: `should_run_close(book_rel)` returns true unconditionally for a different book — only consecutive closes of the *same* book are debounced.
- Cooldown checks live at the event-handler level. Once a chain (e.g. Resume's progress → book sync via `on_done`) is admitted, it runs to completion under one cooldown slot.
- **Startup `scheduleIn` runs at most once per KOReader process** (`startup_sync_scheduled` module-local boolean in `triggers.lua`). KOReader instantiates the plugin separately under `FileManager` and `ReaderUI`; without the guard, every FM↔Reader transition outside the cooldown window fires a full-library sync. The boolean is module-local (shared across FM and Reader instances since `require("triggers")` returns the same module table). Don't re-run startup sync on Reader→FM transitions — Resume covers wake-from-sleep, manual entries cover everything else, and the close trigger already pushed the just-edited book.
- Don't reintroduce per-sync-kind cooldowns (book vs progress) or per-session booleans — the split is per-*trigger-kind* (close vs everything-else).

### Trigger UI policy: manual vs auto

Two UI modes:
- **Manual** (`onWebDAVSyncNow`, `onWebDAVProgressSyncNow`, the "Sync … now" menu items): full UI — "Syncing…" / "Syncing reading progress…" InfoMessage during the run, summary popup always at the end. The user explicitly asked for the sync, so they want feedback regardless of outcome.
- **Auto** (`onResume`, `init()` startup, `onCloseDocument`): silent_mode UI — no "Syncing…" indicator during the run; summary popup only when something failed. Conflict dialogs always surface (they need user input regardless of mode). Plan-level failures (server unreachable etc.) always surface via their dedicated `InfoMessage` — silent_mode doesn't gate those.

The unified `runner.run_planned` and the legacy `runner.run_one_way` helpers (called by main.lua's `doSync` / `doProgressSync` / `doProgressSyncForBook` entry points) take a `silent_mode` opt; auto callers pass `true`, manual callers leave it at the default `false`. Don't add a third UI mode unless there's a strong reason — the manual/auto split covers everything we've needed.

All four auto+manual paths use `runner.resolve_conflicts_interactive` for conflicts. Pre-1.8.0 the close trigger deferred conflicts to the next interactive trigger; that carve-out was removed (the user just closed the book; a dialog right after is cheap, and immediate surfacing is consistent with the other auto triggers). Don't reintroduce conflict deferral.

The full-library reconciles (`onResume`, `init()` startup, manual menu) walk via `plan_progress`/`plan`. The close trigger (`onCloseDocument`) walks only `<book>.sdr/` via `plan_progress_book` for cost reasons (see "Why close is scoped, not full-library" in the Progress sync section).
- **Resume settle delay** — `onResume` does *not* run the sync inline. It performs the cheap toggle gate, then schedules `triggers.run_resume_sync` `settings.get_resume_settle()` seconds later via `UIManager:scheduleIn`. The fire-time function re-checks toggles + cooldown + Wi-Fi, runs the Kindle unscheduled-wake gate, then enters the existing online-defer chain. Two complementary mechanisms suppress brief unscheduled wakes (Kindle framework / RTC / hall-sensor wakes that fire `Resume` for a few seconds before re-suspending):
  - **Cross-platform** — `onSuspend` calls `triggers.cancel_pending_resume_sync` to unschedule the pending fn before it fires. On Kindle the back-to-sleep edge after a brief unscheduled wake commonly goes powerd `screenSaver → suspended` *without* firing `goingToScreenSaver`, so `onSuspend` may never run; in that case the CPU is suspended before our scheduled task can fire. Either path, the deferred fn does not execute while the device is asleep.
  - **Kindle-only** — at fire time, `triggers.is_unscheduled_kindle_wake()` reads `Device:getPowerDevice():getPowerdState()`. If state is `screenSaver` or `suspended`, the wake was unscheduled (matches `KindlePowerD:checkUnexpectedWakeup` at `frontend/device/kindle/powerd.lua:258-269`, which itself uses a 15 s window — that's why the default `DEFAULT_RESUME_SETTLE=15`). Skip with `skip reason=unscheduled-wake state=…`. Non-Kindle devices fall through (`triggers.read_powerd_state` returns nil).
  - **Why both**: cross-platform mechanism is a fallback for devices where we can't read the canonical state; the Kindle gate is the explicit path with a clear log line. The kicker is **NO_FRAMEWORK Kindles** (`koreader.sh --framework_stop`): with the Lab126 framework killed, the screensaver blanket unloaded, and `userpasswdenabled` deleted to prevent it inhibiting `outOfScreenSaver` (`platform/kindle/koreader.sh:201-207`), every powerd-reported wake propagates straight to `Resume` without the framework filtering brief system wakes. The defer is more pressing there than on stock-framework Kindles.
  - **User-configurable via `setResumeSettle`** — `webdav_autosync_resume_settle_seconds` (0–60 s, step 5, default 15). Setting to 0 takes the inline path: `onResume` calls `triggers.run_resume_sync(nil, { skip_unscheduled_check = true })` directly. The skip flag is necessary because at t=0 powerd state on Kindle is *always* `screenSaver` right at wake — the Kindle gate would otherwise classify every Resume as unscheduled. Setting the delay to 0 mid-defer also calls `triggers.cancel_pending_resume_sync` so a pending fn from before the change doesn't fire under the now-stale gate assumption.
  - **Single pending fn shared across instances** — `pending_resume_sync_fn` is module-local in `triggers.lua` (FM and Reader instances share it). `onResume`'s "skip reason=already-scheduled" branch keeps repeated Resume broadcasts inside the settle window from double-scheduling.
  - Don't reintroduce inline-on-Resume sync as the default; the defer is the whole point of the change. The 0 opt-out is for users who want pre-1.7.8 behavior.
- **Offline handling for auto interactive triggers** — Resume and startup poll `NetworkMgr:isOnline()` AND `NetworkMgr:hasDefaultRoute()` themselves with bounded retries (`triggers.defer_until_online`, 6 × 5 s = ~30 s, then silent give-up: `skip reason=offline-give-up online=… has_route=…`). Defer happens *after* toggle, cooldown, and Kindle-state gates; cooldown is consumed (`settings.mark_auto_run()`) only after all of them pass, so a Wi-Fi-still-reconnecting Resume doesn't burn the next 5 min.
  - **Why both `isOnline` + `hasDefaultRoute`**: `isOnline()` is `canResolveHostnames()` (DNS probe to `dns.msftncsi.com`) — DNS can succeed against cached records before the kernel routing table is populated. The post-suspend race: DNS comes back first, helper returns "online", `mark_auto_run()` fires, then PROPFIND fails with "Network is unreachable" and the cooldown is burned for nothing. `hasDefaultRoute()` (UDP `setpeername` to a doc-range IP) catches that case. The defer/give-up log lines report both flags.
  - **Don't use `NetworkMgr:willRerunWhenOnline` for auto-trigger gating.** It only registers the callback in the `not isConnected()` branch (`frontend/ui/network/manager.lua` lines 674-686 in v2026.03). When `isConnected()` is cached true but `isOnline()` (DNS) currently fails — the post-suspend race, since `NetworkListener:onResume` flips `is_connected=true` before DNS catches up — it calls `beforeWifiAction()` *without* the callback and the caller waits on an event that never fires. Polling sidesteps this. It's also tied to the `wifi_enable_action` state machine (turn_on / prompt / ignore), which auto triggers shouldn't engage.
  - Manual triggers prompt for Wi-Fi via `ConfirmBox`/`turnOnWifi`. Close-trigger silently no-ops when offline (debounced; next interactive trigger picks it up via the full reconcile). Runner-level `isOnline()` checks in `doProgressSync`, `maybeRunBookAutoSync`, `doProgressSyncForBook` are kept as defense-in-depth.
  - The retry count threads as an optional first arg through `triggers.run_resume_sync` and `triggers.run_startup_sync`. KOReader's `Resume` event has no payload, so `onResume` itself takes none; only the helpers' own `scheduleIn` re-entries pass it.
- **UI feedback shape per trigger** — runners take `silent_mode` (default false) and `chain_stats` (optional accumulator). What each trigger sets:
  - **Manual** (menu / Dispatcher): `silent_mode=false`, no `chain_stats` — runner shows its own "Syncing…" / "Syncing reading progress…" InfoMessage AND its own per-runner summary popup, regardless of failure count.
  - **Auto standalone** (Resume / startup with only one sync on, or close trigger): `silent_mode=true`, no `chain_stats` — runner suppresses the InfoMessage; runs `runner.resolve_conflicts_interactive` if needed; shows summary popup at the end IFF `stats.failed > 0`. Plan-level failure shows its dedicated InfoMessage regardless.
  - **Auto chain** (Resume / startup with both syncs on): `silent_mode=true` AND `chain_stats=…` on both runners. They suppress their own UI entirely; counts accumulate. The orchestrator's `on_done` callback at chain end calls `runner.chain_total_failed(chain_stats) > 0` and only then calls `runner.show_chain_summary`.
  - **Plan-level failures** in chain: fold into `chain_stats` as one synthetic failure entry on the right section ("progress" or "books"). Don't show a separate InfoMessage in chain mode — that'd defeat the single-popup contract.
  - `runner.merge_chain_stats(chain_stats, stats, section)` is the canonical accumulator setter — all runners route through it. One-way book sync constructs a synthetic stats table mapping its result onto the unified shape (skipped → unchanged, single err string → one synthetic failures entry).
  - `runner.show_summary(prefix, stats)` is the single per-runner summary popup formatter — `run_planned` passes `_("Sync done.")` or `_("Reading progress synced.")` depending on planner. The chain-level merged popup goes through `runner.show_chain_summary` (different shape — multi-section).
  - Don't add per-runner summary calls inside chain branches — `chain_stats ~= nil` is the silencing predicate. Don't gate the conflict dialog on `silent_mode` — conflicts always need user input.
- **`onSuspend` is cancel-only** — its sole purpose is calling `triggers.cancel_pending_resume_sync` to unschedule a pending Resume defer. Don't reintroduce a sync-on-suspend codepath: Suspend can't show interactive UI, and a full library walk burns rate-limit budget on quota-enforcing servers for limited benefit (close trigger already pushed the just-edited book).
- **Chain logic in `init()` and `triggers.run_resume_sync`** — three branches per orchestrator: (a) both on → chain via `chain_stats` + `on_done` callback nesting; (b) progress only → standalone progress; (c) books only → standalone book. If both off, bail before the cooldown check (no cooldown burn for no-op). Log lines include the active flags. (`onResume` itself does an early both-off bail before scheduling; the same check re-runs in `triggers.run_resume_sync` because toggles can change during the settle window.) The chain's nested `on_done` callbacks are how the orchestrator knows when to close the combined InfoMessage and show the merged summary; runners must call `on_done` on every exit path, including in-flight skips and offline-skips, or the chain stalls without a popup. `maybeRunBookAutoSync` does the same for its own early-return paths.
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
- **Conflict UI**: `runner.resolve_conflicts_interactive` chains a `ButtonDialogTitle` per conflict (Keep local / Keep remote / Skip). Sequential — each pick triggers the next, then the summary fires. Required because `do_action` is synchronous; don't try to surface conflicts inside the planner.
- **Conflict resolution policy is shared across all triggers (1.8.0+)**: every trigger — manual, Resume, startup, close — runs `runner.resolve_conflicts_interactive` when conflicts exist. The pre-1.8.0 carve-out where the close trigger silently deferred conflicts was removed. Don't reintroduce silent skipping — the user has consistently asked for conflicts to surface immediately.
- **Same extension filter applies in both directions** (book sync only): only files matching `webdav_autosync_file_extensions` (or default KOReader format list). Random non-book files in the download folder are not pushed. Progress sync uses `is_sidecar_path` and ignores the extension setting.
- **Upload path**: `webdav.upload_file` does PUT; `webdav.ensure_remote_dirs` walks parent path segments and MKCOLs each (treating 405 = already exists as success). PUT response ETag is captured when the server provides one; if absent, the next PROPFIND fills it in.
- **Filename preservation**: WebDAV filenames are kept as-is locally. Don't reintroduce renaming downloaded EPUBs to `<dc:title>.epub` — that broke the existence check on re-syncs (re-downloading every time).
- **Action loop is shared**: `runner.run_action_loop(plan_obj, stats[, on_action_failure])` iterates `plan_obj.actions.to_download` then `to_upload`, calling `sync.do_action` and bumping `stats` counters / appending per-rel failures. Used by `run_planned` and `doProgressSyncForBook`. The optional `on_action_failure(kind, rel, msg)` callback exists for the close-trigger runner's per-failure `logger.warn` lines; the other runners surface failures via the summary popup so they don't need it.

### Progress sync

Opt-in, gated by per-event toggles `webdav_autosync_progress_on_{startup,resume,close}` plus master, all default off.

- Reuses two-way machinery via `sync.plan_progress` and `sync.plan_progress_book`; `do_action`, `save_cache`, `runner.resolve_conflicts_interactive` are shared with book sync without modification. Shared `diff_indices` helper in `sync.lua` is what makes that work — the three planners only differ in how they build the remote/local indices.
- **Triggered by**: `onCloseDocument` (auto, scoped via `plan_progress_book`), `onResume` (auto, full reconcile), `init()` (auto, full reconcile). Manual `webdav_progress_sync_now` Dispatcher action and "Sync reading progress now" menu item bypass cooldown + toggles. All four route through `runner.resolve_conflicts_interactive` for conflicts (no longer deferred from close).
- **Why close is scoped, not full-library**: rate-limited providers returned 400s on full PROPFIND-on-every-close. Close walks only `<book>.sdr/` — one round-trip. Don't expand back to a full walk without proving the rate-limit story has changed.
- **Sidecar location requirement**: only KOReader's default `document_metadata_folder = "doc"` is supported (only mode that places `.sdr` inside the synced library tree). With `dir` or `hash` modes, sidecars are off-tree with no remote mapping; silent triggers no-op (one debug log line), interactive manual triggers show an `InfoMessage`.
- **Don't auto-resolve progress conflicts via mtime.** An earlier draft proposed mtime-wins on close for cross-device self-healing; we dropped it because the user wants conflicts surfaced explicitly. Don't reintroduce without explicit say-so. (1.8.0+ surfaces them immediately at close-trigger time too — they're not deferred anymore.)
- **Device-specific paths in synced sidecars are expected and self-heal — do NOT rewrite them on the wire.** A freshly downloaded `metadata.<ext>.lua` on device B still contains device A's `doc_path` (e.g. `/mnt/us/eBooks/foo.epub`) and a `-- /path/to/sidecar` header comment. KOReader handles it: `DocSettings:open(doc_path)` (`frontend/docsettings.lua`) clobbers `data.doc_path` with the caller-supplied current path; `util.writeToFile` (`frontend/util.lua`) regenerates the leading `-- <filepath>` comment from the writing device's sidecar path on every flush. Reading position, bookmarks, highlights, percent finished, last xpointer, partial MD5 are all device-agnostic. Editing sidecars in flight would touch live KOReader state files — don't go there.
- **`is_doc_only = false`** stays — without it, lifecycle events fired by the reader (`CloseDocument`, `Resume`) wouldn't reach the plugin.

### Debug logging

Every log line starts with `webdav_autosync:` so it can be greppd from `crash.log`. Format: `webdav_autosync: <action> [key=value …]` — scannable, greppable; don't log credentials (URLs are fine, passwords go in the request table).

- **`logger.info`** — trigger entry points (`trigger=startup|resume|close|manual_books|manual_progress`), sync start (`progress sync start`, `book sync start mode=…`), sync done summaries (`progress sync done downloaded=N uploaded=N …`). Always visible. Trigger firing is the most-asked-about diagnostic — don't bury it behind `dbg`.
- **`logger.dbg`** — gating decisions (`skip reason=disabled|cooldown|offline|metadata-folder-mode|not-configured|outside-library|debounce|reader-context|already-scheduled|unscheduled-wake`; `disabled` covers both master-off and per-event-off), Resume defer/cancel (`trigger=resume defer secs=…`, `trigger=resume cancelled reason=…`), per-file diff classifications (`diff rel=X decision=… reason=…`), per-action HTTP outcomes, planner index sizes, individual WebDAV requests (`PROPFIND|GET|PUT|MKCOL url=… status=…`), conflict resolution choices.
- **`logger.warn`** — real plan failures (`book sync plan failed`, etc.) and per-action failures from the close-trigger path (the only sync that doesn't surface failures via UI).
- Don't construct expensive log strings unconditionally — gate behind `if logger.is_dbg` if you'd need to walk a structure.

### Library refresh after writes

`runner.notify_library_refresh`: every sync path that writes files locally collects the relpaths it wrote and hands them in after `save_cache`. Broadcasts:

- `Event:new("InvalidateMetadataCache", <book_file_path>)` per book — drops the SQLite-cached metadata row used by `coverbrowser.koplugin`. Without this, cover mosaic / list views show stale percent / cover until the next directory navigation.
- `Event:new("BookMetadataChanged")` (no `prop_updated` arg) — handled by `FileManager`, `FileManagerHistory`, `FileManagerCollection`, `FileSearcher`. Reader-side handlers (`ReaderCoptListener`, `ReaderFooter`) gate on `prop_updated`, so passing nil makes them no-op — safe to broadcast even from a reader context.
- Sidecar `metadata.<ext>.lua` rels map to `<stem>.<ext>` book paths via `^(.+)%.sdr/metadata%.([^.]+)%.lua$`. Other sidecar files (cover, custom_metadata) don't carry the book extension — they fall through to just the global `BookMetadataChanged`. Book-file rels (no `.sdr/` segment) used as-is.
- Helper is empty-safe — no-ops on nil/empty list, so callers can call it unconditionally on every sync exit path.

## Releases

A tag matching `v*` triggers `.github/workflows/release.yml`, which builds `webdav-autosync.koplugin-<tag>.zip` (runtime files only: `_meta.lua`, `main.lua`, `settings.lua`, `triggers.lua`, `runner.lua`, `ui.lua`, `sync.lua`, `webdav.lua`, `LICENSE`, `README.md` — dev tooling like `Makefile`, `selene.toml`, `koreader.yml`, `.editorconfig`, `CLAUDE.md` excluded) and publishes a GitHub Release with auto-generated notes.

The workflow guards against tag/version drift: tag (without leading `v`) must match `version` in `_meta.lua` or it fails fast. To cut a release: bump `_meta.lua` `version`, commit, then `git tag vX.Y.Z && git push origin vX.Y.Z`.

`appstore.koplugin` discovers this plugin via GitHub Search (pulls the repo zipball at HEAD, not the release asset). Discoverability requires either the `koreader-plugin` GitHub topic or a name matching `*.koplugin` (which this repo satisfies).

## KOReader plugin conventions this repo follows

- `_meta.lua` returns the manifest table (`name`, `fullname`, `description`).
- `main.lua` returns a `WidgetContainer:extend{}` subclass with `name = "webdav_autosync"`.
- Menu entries via `self.ui.menu:registerToMainMenu(self)` + `addToMainMenu(menu_items)`.
- Dispatcher actions (e.g. `WebDAVSyncNow`, `WebDAVProgressSyncNow`) registered in `init()`, dispatched to handlers named `on<Event>`. Lifecycle events (`CloseDocument`, `Suspend`, `Resume`) follow the same `on<Event>` convention but are broadcast by KOReader; their handlers must NOT return `true` (other plugins still need the event).
- Indentation: 4 spaces. Naming: `camelCase` for methods, `snake_case` for module-local helpers (matches KOReader upstream).

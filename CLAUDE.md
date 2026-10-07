# Weink

## Project Overview

Weink is an e-ink KOReader client for WeRead (微信读书) books and MP articles. Lua codebase running inside KOReader's plugin system.

## Identity and upstream

- The code started from `finlater/weread.koplugin` and has run on its own line since `942e25c` (2026-08-01). Upstream and Weink have since diverged in data paths; keep user-facing docs free of protocol internals.
- Version numbers are independent from 2.0.0 onward. Upstream ports are cherry-picked, and the commit message or CHANGELOG entry names the upstream version they came from.
- The KOReader plugin directory name, plugin name (`weread`) and `settings/weread.lua` stay unchanged on purpose: existing installs must keep their login, cache and local-book matches.

## Language

- Code, variable names, commit messages: English
- User-facing strings: wrapped in `_()` for i18n, Chinese translations in `weink/lib/i18n.lua`
- Communication with user: Simplified Chinese (简体中文)

## Architecture

```
main.lua                       Plugin entry, dependency construction, and module composition
weink/lib/mixin.lua          Collision-safe composition of feature methods into the plugin class
weink/lib/migrations.lua     Settings and per-book storage migrations
weink/lib/plugin_util.lua    Shared translation, logging, error, timing, and file helpers
weink/lib/reader_lifecycle.lua KOReader lifecycle and reader-state orchestration
weink/lib/client.lua         HTTP client (eink APIs on i.weread.qq.com)
weink/lib/book_store.lua     Per-book metadata, reading-state, and article-list persistence
weink/lib/content.lua        Eink ZIP download, EPUB/HTML generation
weink/lib/footnotes.lua      Network-free book-footnote scanning, indexing, conversion, and validation
weink/lib/crypto.lua         SHA-256, MD5 (pure Lua)
weink/lib/downloader.lua     Book/chapter download engine (state machine + standby guard)
weink/lib/i18n.lua           Chinese translations (zh table, _() wrapper)
weink/lib/position_mapper.lua Pure KOReader ↔ WeRead chapter/offset mapping
weink/lib/external_annotations_db.lua Per-local-book SQLite annotation storage and migration
weink/lib/progress_sync.lua  Automatic progress-sync state machine and safety gate
weink/lib/read_report.lua    Reading-report state machine, context refresh, retries
weink/lib/settings.lua       Settings persistence via KOReader LuaSettings
weink/lib/protocol.lua       WeRead protocol utilities (encoding, signing, URL helpers)
weink/ui/menu.lua            Main menu and settings menu composition
weink/ui/update.lua          Plugin self-update menu and install UI flow
weink/lib/updater.lua        GitHub release/branch update client with proxy fallback
weink/ui/common.lua          Shared dialog, network-task, and account UI helpers
weink/ui/cache.lua           Cache settings, directory selection, scan, and cleanup flows
weink/ui/library.lua         Bookshelf, book, chapter, public-account, and search flows
weink/ui/read_report.lua     Reading-report settings, target picker, and statistics flow
weink/ui/annotations_controller.lua Annotation visibility and thought-link interaction
weink/ui/reader_navigation.lua End-of-book navigation integration
weink/ui/download_dialog.lua Custom download progress dialog with cancel button
weink/ui/progress_sync_dialog.lua Progress conflict and sync-result dialogs
weink/ui/thought_popup.lua   Native underline/thought TextViewer with previous/next paging
```

## Key Conventions

### Module Namespace

- Keep every project-owned Lua module under the `weink/` namespace directory.
- Put non-UI modules in `weink/lib/` and load them with `require("weink.lib.<module>")`.
- Put UI and presentation modules in `weink/ui/` and load them with `require("weink.ui.<module>")`.
- Do not add project-owned modules under root-level `lib/` or `ui/`, and do not use bare `lib.*` or `ui.*` module keys. KOReader-owned imports such as `require("ui/widget/menu")` are not affected.
- Keep only KOReader plugin entry files such as `main.lua` and `_meta.lua` at the plugin root.

### KOReader Plugin API

- Plugin extends `WidgetContainer`, registered via `self.ui.menu:registerToMainMenu(self)`
- UI widgets: `Menu`, `InfoMessage`, `ConfirmBox`, `InputDialog`, `ButtonDialog`
- Event loop: `UIManager:show()`, `UIManager:close()`, `UIManager:scheduleIn()`
- Events: `onReaderReady` (book opened), `onCloseDocument` (book closed), `onFlushSettings`
- **`scheduleIn(0)` blocks the event loop** — use `scheduleIn(0.1)` minimum for cooperative multitasking
- Menu items support: `text`, `mandatory` (right-aligned), `post_text`, `callback`, `checked_func`, `enabled_func`, `sub_item_table_func`, `separator`, `keep_menu_open`
- Menu has built-in pagination (swipe, page indicators, search via page indicator tap)

### Settings Pattern

`settings/weread.lua` is reserved for small, bounded configuration and critical
state only. Never store downloaded content, annotations, thoughts, catalogs,
history, or other user-data collections there. Persist growing/queryable data
in dedicated SQLite databases under the plugin data directory instead, and
migrate legacy settings data before deleting its old key.

```lua
local val = self.settings:get("key")  -- reads with default from defaults table
self.settings:set("key", val)
self.settings:flush()                  -- must call to persist
```

### Network Pattern

```lua
self:runNetworkAction(label, function()
    -- runs inside NetworkMgr:runWhenOnline
    -- return string → shown as info; error → shown as error
end)
```

### Translation Pattern

```lua
local PluginUtil = require("weink.lib.plugin_util")
local _ = PluginUtil.tr
_("English key")                    -- simple
T(_("Template %1"), value)          -- with substitution (ffi/util.template)

-- In weink/lib/i18n.lua, add to zh table:
["English key"] = "中文翻译",
```

### Loop Variable

Use `_i` (not `_`) in `for _i, item in ipairs(...)` to avoid shadowing the `_()` translation function.

### Menu Maintenance

Whenever a menu item is added, removed, renamed, or moved:

- Update the menu definition in `weink/ui/menu.lua` (or the owning feature UI module)
- Add, rename, or remove the corresponding translation entry in `weink/lib/i18n.lua`; do not leave unused menu translation keys behind
- Keep the menu tree in `README.md` in sync
- Search all three files for the old and new labels before considering the change complete

## Auth and APIs

Login is eink QR only (`weink/lib/eink_qr_login.lua`). Production APIs use `vid` + `accessToken` against `i.weread.qq.com`. Public WeChat article fetch (`get_public_text` / mp.weixin.qq.com) stays. Do not restore web Cookie, Skill `api_key`, or `/web/book/chapter/*` shards.

## WeRead API Integration Rules

**For any feature that calls WeRead APIs:**

1. **Script-first validation**: Write a Python script in `scripts/` to prototype and validate the API interaction
2. **Verify on real data**: Run the script against actual WeRead responses to confirm correctness
3. **Then implement in Lua**: Only after the script validates successfully, implement the equivalent logic in the plugin

Existing reference scripts:
- `scripts/verify_mp_articles.py` — MP article API verification
- `scripts/verify_own_notes.py` — current-book note list verification
- `scripts/verify_review_single.py` — single review/comment thread verification
- `scripts/verify_split_layout_paths.py` — split-layout path verification

## Privacy / Security

Never commit or log:
- KOReader `settings/weread.lua`
- Real API keys (`wrk-...`), cookie values (`wr_skey`, `wr_rt`, `wr_vid`, etc.)
- Anti-abuse headers (`x-wrpa-*`)
- Generated EPUB/cache files

Pre-commit scan:
```bash
rg -n "wrk-|wr_skey[=]|wr_rt[=]|wr_vid[=]|ptcz[=]|x-wrpa|thirdwx" -S .
```

## Reference Docs

- `docs/weink-annotations-flow.md` — underline/thought download → embed → tap-to-display flow
- `docs/weink-eink-upload.md` — eink highlight/thought upload contract
- `docs/annotations-overlay.md` — annotation overlay architecture, invalidation and limits
- `docs/releasing.md` / `docs/testing.md` — release packaging and the three test layers

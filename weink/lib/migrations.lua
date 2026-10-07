local Content = require("weink.lib.content")
local logger = require("weink.lib.logger")
-- libkoreader-lfs ships with KOReader; in bare CI/spec environments it is
-- absent and the repair pass degrades to a no-op (catalog migration still runs).
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then
    lfs = nil
end

local PluginUtil = require("weink.lib.plugin_util")
local log_error = PluginUtil.log_error

local Migrations = {}

local function is_dir(path)
    return lfs ~= nil and type(path) == "string" and path ~= ""
        and lfs.attributes(path, "mode") == "directory"
end

local function is_file(path)
    return lfs ~= nil and type(path) == "string" and path ~= ""
        and lfs.attributes(path, "mode") == "file"
end

local function dirname(path)
    if type(path) ~= "string" then
        return nil
    end
    return path:match("^(.*)/[^/]+$")
end

local function join(a, b)
    return tostring(a):gsub("/+$", "") .. "/" .. tostring(b):gsub("^/+", "")
end

local function has_sidecar_markers(dir)
    if not is_dir(dir) then
        return false
    end
    return is_file(join(dir, "catalog.json"))
        or is_file(join(dir, "thoughts.db"))
        or is_file(join(dir, "metadata.json"))
        or is_file(join(dir, "reading_state.json"))
end

local function has_epub(dir)
    if not is_dir(dir) then
        return false
    end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok then
        return false
    end
    for name in iter, dir_obj do
        if type(name) == "string" and name:lower():match("%.epub$") then
            return true
        end
    end
    return false
end

-- Repair book.cache_dir values left behind by the short-lived flat-layout fork:
-- they often point at <library>/metadata/<bookId> which only has metadata.json,
-- while catalog/thoughts/EPUB still live under the legacy download folder.
local function repair_flat_layout_cache_dirs(settings, books)
    local repaired = 0
    local download_root = settings.cache_dir
    local candidates_root = {
        download_root,
        settings.meta_dir,
        settings.default_meta_dir,
        settings.default_cache_dir,
        settings.data_dir and (settings.data_dir .. "/meta") or nil,
        settings.data_dir and (settings.data_dir .. "/cache") or nil,
    }

    for book_id, book in pairs(books) do
        if type(book) == "table" then
            local current = book.cache_dir
            local current_ok = has_sidecar_markers(current) or has_epub(current)
            if not current_ok then
                local picks = {}
                local function consider(dir)
                    if type(dir) ~= "string" or dir == "" then
                        return
                    end
                    dir = dir:gsub("/+$", "")
                    if picks[dir] then
                        return
                    end
                    picks[dir] = true
                end

                consider(dirname(book.cached_file))
                if type(book.cached_chapters) == "table" then
                    for _uid, path in pairs(book.cached_chapters) do
                        consider(dirname(path))
                    end
                end
                for _i, root in ipairs(candidates_root) do
                    if type(root) == "string" and root ~= "" then
                        consider(join(root, Content.book_dir_name(book_id)))
                    end
                end

                local best
                for dir, _ in pairs(picks) do
                    local score = 0
                    if has_epub(dir) then score = score + 4 end
                    if is_file(join(dir, "catalog.json")) then score = score + 3 end
                    if is_file(join(dir, "thoughts.db")) then score = score + 2 end
                    if is_file(join(dir, "metadata.json")) then score = score + 1 end
                    if score > 0 and (not best or score > best.score) then
                        best = { dir = dir, score = score }
                    end
                end

                if best and best.dir ~= current then
                    book.cache_dir = best.dir
                    -- If cached_file is missing/broken but an EPUB remains in the
                    -- recovered directory, rebind to the largest EPUB there.
                    if not is_file(book.cached_file) then
                        local ok, iter, dir_obj = pcall(lfs.dir, best.dir)
                        if ok then
                            local main_epub, main_size = nil, -1
                            for name in iter, dir_obj do
                                if type(name) == "string" and name:lower():match("%.epub$") then
                                    local path = join(best.dir, name)
                                    local size = lfs.attributes(path, "size") or 0
                                    if size > main_size then
                                        main_size = size
                                        main_epub = path
                                    end
                                end
                            end
                            if main_epub then
                                book.cached_file = main_epub
                            end
                        end
                    end
                    repaired = repaired + 1
                    logger.info("repaired book cache_dir:",
                        "book_id=", tostring(book_id),
                        "from=", tostring(current),
                        "to=", best.dir)
                end
            end
        end
    end
    return repaired
end

-- ------------------------------------------------------------------
-- Rename migration (drop this hook once every install has run it)
-- ------------------------------------------------------------------
-- The plugin's own directories were renamed from "weread" to "weink". Older
-- versions stored absolute paths inside that tree (per-book cache/meta paths
-- and cached WeChat article files), so re-point them once and remember that
-- the work is done. The hook is keyed in settings and can be deleted in a
-- later release without leaving anything behind.
local RENAME_MIGRATION_KEY = "rename_migration"
local RENAME_MIGRATION_VALUE = "weink"
local LEGACY_DATA_DIRNAME = "weread"

local function repoint(value, old_prefix, new_prefix)
    if type(value) ~= "string" or value == "" then return nil end
    if value:sub(1, #old_prefix) ~= old_prefix then return nil end
    return new_prefix .. value:sub(#old_prefix + 1)
end

function Migrations.run_rename(settings)
    if settings.store:readSetting(RENAME_MIGRATION_KEY, "") == RENAME_MIGRATION_VALUE then
        return 0
    end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or type(DataStorage.getFullDataDir) ~= "function" then
        return 0
    end
    local old_prefix = DataStorage:getFullDataDir() .. "/" .. LEGACY_DATA_DIRNAME
    local new_prefix = tostring(settings.data_dir or "")
    if new_prefix == "" or new_prefix == old_prefix then
        return 0
    end
    local changed = 0
    for _, key in ipairs({ "download_dir", "meta_dir" }) do
        local moved = repoint(settings.store:readSetting(key, ""), old_prefix, new_prefix)
        if moved then
            settings.store:saveSetting(key, moved)
            changed = changed + 1
        end
    end
    local books = settings.store:readSetting("books", {})
    if type(books) == "table" then
        local touched = false
        for _, book in pairs(books) do
            if type(book) == "table" then
                for _, key in ipairs({ "cache_dir", "cached_file", "cached_full_book" }) do
                    local moved = repoint(book[key], old_prefix, new_prefix)
                    if moved then
                        book[key] = moved
                        touched = true
                        changed = changed + 1
                    end
                end
            end
        end
        if touched then
            settings.store:saveSetting("books", books)
        end
    end
    local ok_db, LibraryDB = pcall(require, "weink.lib.library_db")
    if ok_db and type(LibraryDB) == "table"
        and type(LibraryDB.migrateCachedPaths) == "function" then
        local ok_call, moved_or_err = pcall(function()
            return LibraryDB:new(settings):migrateCachedPaths(old_prefix, new_prefix)
        end)
        if ok_call and type(moved_or_err) == "number" then
            changed = changed + moved_or_err
        else
            logger.warn("rename migration: article paths not migrated:",
                log_error(moved_or_err))
        end
    end
    settings.store:saveSetting(RENAME_MIGRATION_KEY, RENAME_MIGRATION_VALUE)
    settings.store:flush()
    logger.info("rename migration done:", "repointed_paths=", tostring(changed))
    return changed
end

function Migrations.run(settings, client)
    local ok_rename, rename_or_err = pcall(Migrations.run_rename, settings)
    if not ok_rename then
        logger.warn("rename migration failed:", log_error(rename_or_err))
    end
    local books = settings:get("books", {})
    local found, migrated, failed = false, 0, 0
    for _book_id, book in pairs(books) do
        if type(book) == "table" and book.chapters ~= nil then
            found = true
            if type(book.chapters) == "table" then
                local ok, saved = pcall(Content.save_catalog_cache,
                    client, settings, book, book.chapters)
                if ok and saved then
                    migrated = migrated + 1
                else
                    failed = failed + 1
                end
            end
            book.chapters = nil
        end
    end

    local repaired = 0
    local ok_repair, repair_or_err = pcall(repair_flat_layout_cache_dirs, settings, books)
    if ok_repair then
        repaired = tonumber(repair_or_err) or 0
    else
        logger.warn("flat-layout cache_dir repair failed:",
            log_error(repair_or_err))
    end

    if not found and repaired == 0 and not settings:has_legacy_book_records() then
        return
    end

    local ok, err = pcall(function()
        settings:set("books", books)
        settings:flush()
    end)
    if ok then
        logger.info("legacy per-book data migrated:",
            "catalogs=", tostring(migrated),
            "catalog_failures=", tostring(failed),
            "cache_dir_repaired=", tostring(repaired))
    else
        logger.err("legacy per-book data migration failed:",
            log_error(err))
    end
end

return Migrations

-- The rename migration must re-point absolute paths stored by pre-rename
-- versions, hand cached article paths to the library DB, and run exactly once.
package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(value, label)
    checks = checks + 1
    if not value then error(label or ("check " .. checks .. " failed")) end
end

local values = {
    download_dir = "/data/weread/cache",
    meta_dir = "/data/weread/meta",
    books = { ["42"] = { cache_dir = "/data/weread/cache",
        cached_file = "/data/weread/cache/42.epub", title = "book" } },
}
local flushes = 0
local store = {
    readSetting = function(_self, key, default)
        local value = values[key]
        if value == nil then return default end
        return value
    end,
    saveSetting = function(_self, key, value) values[key] = value end,
    flush = function() flushes = flushes + 1 end,
}

package.preload["datastorage"] = function()
    return { getFullDataDir = function() return "/data" end }
end
package.preload["weink.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weink.lib.plugin_util"] = function()
    return { tr = function(text) return text end, log_error = tostring,
        T = function(text) return text end, perf = function() end }
end
package.preload["weink.lib.content"] = function() return {} end
local db_old, db_new, db_calls = nil, nil, 0
package.preload["weink.lib.library_db"] = function()
    local LibraryDB = {}
    LibraryDB.__index = LibraryDB
    function LibraryDB:new(_settings) return self end
    function LibraryDB:migrateCachedPaths(old_prefix, new_prefix)
        db_calls = db_calls + 1
        db_old, db_new = old_prefix, new_prefix
        return 3
    end
    return LibraryDB
end

local Migrations = require("weink.lib.migrations")
local settings = { data_dir = "/data/weink", store = store }
expect(Migrations.run_rename(settings) == 7, "four settings paths plus three database rows")
expect(values.download_dir == "/data/weink/cache", "download dir re-pointed")
expect(values.meta_dir == "/data/weink/meta", "meta dir re-pointed")
expect(values.books["42"].cache_dir == "/data/weink/cache", "book cache dir re-pointed")
expect(values.books["42"].cached_file == "/data/weink/cache/42.epub", "book file re-pointed")
expect(db_calls == 1 and db_old == "/data/weread" and db_new == "/data/weink",
    "article cache paths migrated through the library database")
expect(values.rename_migration == "weink2", "migration recorded as done")
expect(flushes >= 1, "settings flushed")
expect(Migrations.run_rename(settings) == 0 and db_calls == 1, "second run is a no-op")
print(("rename_migration_spec: %d checks"):format(checks))
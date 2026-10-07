package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message) end
end
package.preload["libs/libkoreader-lfs"] = function() return require("lfs") end
for _, name in ipairs({ "ui/widget/buttondialog", "ui/widget/pathchooser" }) do
    package.preload[name] = function() return {} end
end
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_self, opts) return opts end }
end
local shown_dialog
package.preload["ui/uimanager"] = function()
    return {
        show = function(_self, dialog) shown_dialog = dialog end,
        close = function() end,
    }
end
package.preload["weink.lib.article_cache"] = function()
    return {
        snapshot = function() return { size = 2048, count = 2, files = { "a", "b" } } end,
        clear = function() return true end,
    }
end
package.preload["weink.lib.content"] = function() return {} end
package.preload["weink.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weink.lib.scan"] = function() return {} end
package.preload["weink.lib.protocol"] = function()
    return { is_mp_book = function(id) return tostring(id):match("^MP_WXS_") ~= nil end }
end
package.preload["weink.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, value) return text:gsub("%%1", tostring(value)) end,
        log_error = tostring, display_error = tostring,
        file_exists = function() return false end,
    }
end

local Cache = require("weink.ui.cache")
local cleared_lists, saved = 0, 0
local host_items
local host = {
    settings = {
        get = function(_self, key, default) return key == "books" and {} or default end,
        set = function() saved = saved + 1 end,
        flush = function() end,
    },
    library_db = { clearMpArticles = function() cleared_lists = cleared_lists + 1 return true end },
    safeCallback = function(_self, _label, callback) return callback end,
    showList = function(_self, _title, items)
        host_items = items
        return {}
    end,
    refreshShelfCacheIndicators = function() end,
    showTransientInfo = function() end,
}
for key, value in pairs(Cache) do
    if host[key] == nil then host[key] = value end
end

host:showCacheManagement()
expect(host_items[1].text:find("WeChat article cache", 1, true) ~= nil,
    "cache manager still exposes the legacy public-account action")
expect(host_items[1].text:find("2 KB", 1, true) ~= nil,
    "cache manager did not include standalone articles in its size")
host_items[1].callback()
expect(shown_dialog and shown_dialog.ok_callback, "article cleanup confirmation missing")
shown_dialog.ok_callback()
expect(cleared_lists == 1, "favorites/floating list cache was not cleared")
expect(saved == 0, "article cleanup changed book records")

print(("cache_articles_ui_spec: %d checks"):format(checks))

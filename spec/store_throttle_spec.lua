-- Regression lock for the store debounce: a double tap must not fire a second
-- request, and a request in flight must not be re-entered.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local scheduled = 0
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function() end,
        setDirty = function() end,
        widgetRepaint = function() end,
        forceRePaint = function() end,
        -- called as UIManager:scheduleIn(delay, fn)
        scheduleIn = function(_self, _delay, fn)
            scheduled = scheduled + 1
            if fn then fn() end
        end,
    }
end
package.preload["ui/widget/confirmbox"] = function() return {} end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["weink.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weink.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weink.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        log_error = tostring,
        display_error = tostring,
    }
end
package.preload["weink.ui.library_view"] = function() return { show = function() end } end

local Store = require("weink.ui.store")

local fake = setmetatable({
    showTransientInfo = function() end,
    _store_fetch_at = nil,
    _store_inflight = nil,
}, { __index = Store })

expect(Store.storeFetchAllowed ~= nil, "helper is exposed")

-- first use of a key is allowed, the immediate repeat is not
expect(Store.storeFetchAllowed(fake, "home") == true, "first fetch allowed")
Store.storeFetchBegin(fake, "home")
expect(Store.storeFetchBlocked(fake, "home") == true, "repeat is debounced")
expect(scheduled >= 1, "an expiry timer was armed")

-- another key is independent
expect(Store.storeFetchAllowed(fake, "search:x:1") == true, "other key allowed")

-- once the call finishes, the in-flight marker clears but the min interval holds
Store.storeFetchEnd(fake, "home")
expect(fake._store_inflight["home"] == nil, "in-flight marker cleared")
expect(Store.storeFetchBlocked(fake, "home") == true, "still inside the min interval")
expect(Store.storeFetchAllowed(fake, "search:x:1") == true, "other key still fine")

print(("store_throttle_spec: %d checks"):format(checks))

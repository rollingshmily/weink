-- Builds weink.ui.library_view with real store rows (fixtures captured live on
-- 2026-10-09, trimmed of book content) to prove the store screen renders
-- without errors and shares the four-tab bar.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Widget = {}
Widget.__index = Widget
function Widget:extend(defaults)
    defaults = defaults or {}
    defaults.__index = defaults
    return setmetatable(defaults, { __index = self })
end
function Widget:new(values)
    values = values or {}
    setmetatable(values, { __index = self })
    if values.init then values:init() end
    return values
end
function Widget:getSize()
    local dimen = self.dimen or {}
    return { w = self.width or dimen.w or 100, h = self.height or dimen.h or 20 }
end
function Widget:getHeight() return self:getSize().h end

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0, COLOR_BLACK = 1, COLOR_GRAY = 2, COLOR_DARK_GRAY = 3 }
end
package.preload["ffi/util"] = function()
    return {
        template = function(text, ...)
            local values = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(values[tonumber(index)] or "")
            end))
        end,
    }
end
package.preload["device"] = function()
    return {
        input = { group = { Back = "back" } },
        hasKeys = function() return false end,
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_self, value) return value end,
        },
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function() end,
        setDirty = function() end,
        widgetRepaint = function() end,
        forceRePaint = function() end,
        scheduleIn = function() end,
    }
end
package.preload["ui/gesturerange"] = function()
    return { new = function(_self, values) return values end }
end
package.preload["ui/geometry"] = function()
    local geometry = {}
    function geometry.new(_self, values)
        values = values or {}
        values.copy = function(self) return geometry.new(nil, self) end
        return values
    end
    return geometry
end
package.preload["ui/size"] = function()
    return {
        padding = { tiny = 1, small = 2, default = 3, large = 4 },
        border = { thin = 1 },
    }
end
package.preload["ui/font"] = function()
    return { getFace = function(_self, name, size) return name .. size end }
end
package.preload["ui/widget/focusmanager"] = function()
    local manager = Widget:extend{
        FOCUS_ONLY_ON_NT = 1,
        NOT_UNFOCUS = 2,
    }
    function manager:moveFocusTo() return true end
    return manager
end
package.preload["bit"] = function()
    return {
        bor = function(a, b) return (a or 0) + (b or 0) end,
        band = function(a, b) return a or 0 end,
    }
end
package.preload["ui/widget/container/inputcontainer"] = function()
    return Widget:extend{}
end
package.preload["ui/widget/widget"] = function()
    return Widget:extend{}
end
package.preload["ui/widget/button"] = function()
    return Widget:extend{}
end
package.preload["ui/widget/container/centercontainer"] = function()
    return Widget:extend{}
end
package.preload["ui/widget/container/framecontainer"] = function()
    return Widget:extend{}
end
package.preload["ui/widget/container/scrollablecontainer"] = function()
    return Widget:extend{}
end
package.preload["ui/widget/horizontalgroup"] = function()
    local group = Widget:extend{}
    function group:init()
        if not self[1] then self[1] = {} end
    end
    function group:insert(value) table.insert(self[1], value) end
    return group
end
package.preload["ui/widget/verticalgroup"] = function()
    local group = Widget:extend{}
    function group:init()
        if not self[1] then self[1] = {} end
    end
    function group:insert(value) table.insert(self[1], value) end
    return group
end
package.preload["ui/widget/horizontalspan"] = function() return Widget:extend{} end
package.preload["ui/widget/verticalspan"] = function() return Widget:extend{} end
package.preload["ui/widget/linewidget"] = function() return Widget:extend{} end
package.preload["ui/widget/imagewidget"] = function() return Widget:extend{} end
package.preload["ui/widget/overlapgroup"] = function() return Widget:extend{} end
package.preload["ui/widget/textwidget"] = function() return Widget:extend{} end
package.preload["ui/widget/textboxwidget"] = function() return Widget:extend{} end
package.preload["ui/widget/titlebar"] = function() return Widget:extend{} end
package.preload["weink.lib.i18n"] = function()
    return { tr = function(text) return text end }
end
package.preload["weink.lib.book_reviews"] = function()
    return {
        format_date = function() return "" end,
        format_rating = tostring,
        preview = function(text) return text end,
    }
end

local LibraryView = require("weink.ui.library_view")

local store_rows = {
    { kind = "heading", text = "热门推荐", status = "356" },
    { kind = "book", book = { title = "Sample One", author = "Author",
                              price = 12.5, paying_status = 2 } },
    { kind = "book", book = { title = "Sample Two", author = "Author",
                              paying_status = 1, paid = true } },
    { kind = "category", category = { title = "精品小说", total = 42174 } },
    { kind = "more", section = { name = "重磅好书" }, label = "Load more" },
    { kind = "load_more", label = "Load more" },
}

local ok, err = pcall(function()
    local view = LibraryView.show({
        mode = "store",
        title = "WeRead Store",
        rows = store_rows,
        paged = true,
        page = 1,
        page_size = 10,
    }, {})
    expect(view ~= nil, "store view built")
    expect(#view._tab_buttons == 4, "store screen shows four tabs")
    expect(view._tab_buttons[1].text == "Store", "first tab is the store")
    expect(view._tab_buttons[2].text == "Books (0)", "second tab is books")
    expect(#view._item_rows == #store_rows, "every store row is rendered")
end)
expect(ok, "store rows failed to render: " .. tostring(err))

-- Paging over rows must slice, not drop.
local paged_ok, paged_err = pcall(function()
    local view = LibraryView.show({
        mode = "store",
        title = "Search",
        rows = store_rows,
        paged = true,
        page = 2,
        page_size = 4,
    }, {})
    expect(view ~= nil, "second page built")
    expect(#view._item_rows == 2, "second page holds the remaining rows")
end)
expect(paged_ok, "store paging failed: " .. tostring(paged_err))

print(("store_ui_spec: %d checks"):format(checks))
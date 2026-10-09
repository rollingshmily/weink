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
    local child = self[1] and self[1].getSize and self[1]:getSize() or {}
    return { w = self.width or dimen.w or child.w or 100,
             h = self.height or dimen.h or child.h or 20 }
end
function Widget:getHeight() return self:getSize().h end
function Widget:paintTo(bb, x, y)
    local size = self:getSize()
    self.dimen = { x = x, y = y, w = size.w, h = size.h }
    for _i, child in ipairs(self) do
        if child.paintTo then child:paintTo(bb, x, y) end
    end
end

local function buffer()
    return {
        getWidth = function() return 600 end,
        getHeight = function() return 800 end,
        getType = function() return 0 end,
        fill = function() end,
        blitFrom = function() end,
        free = function(self) self.freed = true end,
    }
end

package.preload["ffi/blitbuffer"] = function()
    return { COLOR_WHITE = 0, COLOR_BLACK = 1, COLOR_GRAY = 2, COLOR_DARK_GRAY = 3,
             new = buffer }
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
        isTouchDevice = function() return false end,
        screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_self, value) return value end,
            getSize = function() return { w = 600, h = 800 } end,
        },
    }
end
local scheduled, dirty = {}, 0
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function() end,
        setDirty = function() dirty = dirty + 1 end,
        widgetRepaint = function() end,
        forceRePaint = function() end,
        scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end,
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
    -- Optional verification against the unmodified KOReader container source.
    -- All list/controller code remains real; only drawing primitives are fake.
    local source = os.getenv("WEINK_SCROLLABLE_SOURCE")
    if source then return dofile(source) end
    local scroll = Widget:extend{ _scroll_offset_x = 0, _scroll_offset_y = 0 }
    function scroll:setScrolledOffset(point)
        self._scroll_offset_x, self._scroll_offset_y = point.x, point.y
    end
    function scroll:getScrolledOffset()
        return { x = self._scroll_offset_x, y = self._scroll_offset_y }
    end
    function scroll:paintTo(bb, x, y)
        self._is_scrollable = true
        self._max_scroll_offset_y = math.max(0, self[1]:getSize().h - self.dimen.h)
        self._bb = self._bb or buffer()
        self[1]:paintTo(bb, x, y - self._scroll_offset_y)
    end
    function scroll:onCloseWidget()
        if self._bb then self._bb:free(); self._bb = nil end
    end
    return scroll
end
package.preload["ui/bidi"] = function() return { mirroredUILayout = function() return false end } end
package.preload["optmath"] = function() return { round = function(n) return math.floor(n + 0.5) end } end
package.preload["logger"] = function() return { dbg = function() end } end
local scrollbar = Widget:extend{}
function scrollbar:set() end
package.preload["ui/widget/verticalscrollbar"] = function() return scrollbar end
package.preload["ui/widget/horizontalscrollbar"] = function() return scrollbar end
package.preload["ui/widget/horizontalgroup"] = function()
    local group = Widget:extend{}
    function group:init()
        if not self[1] then self[1] = {} end
    end
    function group:insert(value) table.insert(self[1], value) end
    function group:getSize()
        local w, h = 0, 0
        for _i, child in ipairs(self) do
            if child.getSize then
                local size = child:getSize()
                w, h = w + size.w, math.max(h, size.h)
            end
        end
        return { w = w, h = h }
    end
    return group
end
package.preload["ui/widget/verticalgroup"] = function()
    local group = Widget:extend{}
    function group:init()
        if not self[1] then self[1] = {} end
    end
    function group:insert(value) table.insert(self[1], value) end
    function group:getSize()
        local w, h = 0, 0
        for _i, child in ipairs(self) do
            if child.getSize then
                local size = child:getSize()
                w, h = math.max(w, size.w), h + size.h
            end
        end
        return { w = w, h = h }
    end
    return group
end
package.preload["ui/widget/horizontalspan"] = function() return Widget:extend{} end
package.preload["ui/widget/verticalspan"] = function()
    local span = Widget:extend{}
    function span:getSize() return { w = 0, h = self.width or 0 } end
    return span
end
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
    expect(view._tab_buttons[2].text == "Books", "second tab is books")
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

-- Regression: appended content must be painted at the saved offset on its
-- FIRST frame. KOReader's setter itself does not issue a repaint.
local books = {}
for index = 1, 30 do
    books[index] = { kind = "book", book = { book_id = tostring(index), title = "Book " .. index } }
end
scheduled = {}
local view = LibraryView.show({ mode = "store", rows = books,
    cover_mode = true, cover_columns = 5, cover_rows = 3, scroll_offset = 120 }, {})
local scroll = view._nav_scroll
expect(scroll:getScrolledOffset().y == 120, "offset restored synchronously before any paint")
expect(#scheduled == 0, "no delayed position restore")
view:paintTo(buffer(), 0, 0)
expect(scroll:getScrolledOffset().y == 120, "first paint preserves offset")

scroll:setScrolledOffset({ x = 0, y = 310 })
local cells, generation = view._item_rows, view._build_generation
local paths, loading = {}, {}
for index = 1, 30 do
    if index <= 15 then loading[books[index].book] = true
    else paths[books[index].book] = "/cache/" .. index .. ".jpg" end
end
local old_dirty = dirty
view:updateCovers(paths, loading)
expect(view._nav_scroll == scroll, "cover completion retains the scroll container")
expect(view._build_generation == generation, "cover completion does not rebuild the page")
expect(view._item_rows == cells, "cover completion retains the existing cells")
expect(scroll:getScrolledOffset().y == 310, "cover completion preserves LIVE offset, not the older load offset")
expect(view._item_rows[16]._has_cover == true, "new page cover is displayed")
expect(dirty == old_dirty + 1, "cover completion requests a repaint")
view:paintTo(buffer(), 0, 0)
expect(scroll:getScrolledOffset().y == 310, "cover repaint stays on the same books")
view:updateCovers(paths, loading)
expect(dirty == old_dirty + 1, "unchanged covers do not repaint again")

local old_buffer = scroll._bb
view:apply({ mode = "store", rows = books, cover_mode = true,
    cover_columns = 5, cover_rows = 3, scroll_offset = 310 }, {})
expect(old_buffer.freed == true, "replacing a list releases the old scroll scratch buffer")
expect(view._nav_scroll:getScrolledOffset().y == 310, "appending another page restores offset before painting")

-- A timer running before the first paint must not confuse uninitialized
-- limits with a genuinely short page. Old/closed page timers do nothing.
scheduled = {}
local fills, reaches = 0, 0
view:apply({ mode = "store", rows = books }, {
    on_fill_page = function() fills = fills + 1 end,
    on_reach_bottom = function() reaches = reaches + 1 end,
})
scheduled[1].callback()
expect(fills == 0 and reaches == 0, "unpainted list does not auto-load")
expect(#scheduled == 2, "unpainted list waits for layout")
view:paintTo(buffer(), 0, 0)
local live_scroll = view._nav_scroll
expect(live_scroll._max_scroll_offset_y > 0, "fixture exceeds viewport")
live_scroll:setScrolledOffset({ x = 0, y = live_scroll._max_scroll_offset_y })
scheduled[2].callback()
expect(reaches == 1 and fills == 0, "painted list loads once when scrolled to its end")
local stale = scheduled[2].callback
view:apply({ mode = "store", rows = {} }, {})
stale()
expect(reaches == 1, "old build watcher is invalidated")
scheduled = {}
view:apply({ mode = "store", rows = books }, { on_reach_bottom = function() reaches = reaches + 1 end })
view:onCloseWidget()
scheduled[1].callback()
expect(reaches == 1, "closed page does not auto-load")

print(("store_ui_spec: %d checks"):format(checks))

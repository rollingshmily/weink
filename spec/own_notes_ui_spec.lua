-- Exercise the production review view with deterministic KOReader widget doubles.
-- These check construction/geometry/callbacks, not device font rasterization.
package.path = "./?.lua;" .. package.path
local checks = 0
local function expect(value, label) checks = checks + 1; assert(value, label) end
local Widget = {}
function Widget:extend(value) self.__index = self; return setmetatable(value or {}, self) end
function Widget:new(value)
    value = self:extend(value)
    if value.init then value:init() end
    return value
end
function Widget:getSize()
    if self.dimen then return self.dimen end
    return { w = self.width or 600, h = self.height or 40 }
end
function Widget:getHeight() return self:getSize().h end
function Widget:free() self.freed = true end
local function preload(name, module) package.preload[name] = function() return module end end
preload("ui/gesturerange", { new = function(_self, value) return value end })
preload("ui/geometry", { new = function(_self, value)
    value.copy = function(self) return { x = self.x, y = self.y, w = self.w, h = self.h } end
    return value
end })
preload("ffi/blitbuffer", { COLOR_WHITE = "white", COLOR_BLACK = "black" })
local scale, screen_w = 1.5, 900
preload("device", { screen = {
    getWidth = function() return screen_w end,
    getHeight = function() return 1200 end,
    scaleBySize = function(_self, value) return value * scale end,
}, hasKeys = function() return false end })
preload("ui/size", { padding = { large = 12, default = 8, small = 4 }, border = { thin = 1 } })
preload("ui/font", { getFace = function(_self, name, size) return { name = name, orig_size = size } end })
preload("ffi/util", { template = function(s, ...)
    local values = {...}; return (s:gsub("%%(%d)", function(i) return tostring(values[tonumber(i)]) end))
end })
for _, name in ipairs({ "container/framecontainer", "container/scrollablecontainer", "textwidget",
    "horizontalgroup", "horizontalspan", "verticalgroup", "verticalspan", "titlebar", "linewidget",
    "container/inputcontainer" }) do
    preload("ui/widget/" .. name, Widget:extend{})
end
local TextBox, Top = Widget:extend{}, Widget:extend{}
preload("ui/widget/textboxwidget", TextBox)
preload("ui/widget/container/topcontainer", Top)
local Focus = Widget:extend{}
function Focus:init() end
preload("ui/widget/focusmanager", Focus)
preload("weread.ui.focus_nav", {
    apply = function(view, rows) view.layout = rows end,
    initialFocus = function(view, x, y) view.selected = { x = x, y = y } end,
})
local Button = Widget:extend{}
function Button:init()
    self.label_widget = Widget:new{ text = self.text }
    self.label_container = Widget:new{ dimen = { w = self.width - 2 * (self.padding_h or 0)
        - 2 * (self.bordersize or 0), h = self.height or 40 }, self.label_widget }
    self.frame = Widget:new{ self.label_container }
end
preload("ui/widget/button", Button)
local shown
preload("ui/uimanager", { show = function(_self, view) shown = view end, close = function() end,
    setDirty = function() end })
local View = require("weread.ui.own_notes_view")
local long = string.rep("一段很长的原文和想法。\n", 600)
for _, width in ipairs({ 600, 900, 1200 }) do
    screen_w = width; scale = width / 600
    local deleted, refresh, more
    local note = { kind = "review", quote = long, content = long }
    local underline = { kind = "bookmark", quote = "短划线", content = "not a thought" }
    local view = View.show{
        title = "Book", records = { { note = note, metadata = "date · chapter" },
            { note = underline, metadata = "underline · chapter" } }, more = true,
        on_delete = function(n, v) deleted = { n, v } end,
        on_refresh = function() refresh = true end, on_more = function() more = true end,
    }
    expect(shown == view and #view._blocks == 2, "same scroll page has both notes")
    local block = view._blocks[1]
    expect(block.block[1] == block.row and block.row[1] == block.column,
        "text column with the delete control beside it")
    expect(block.column[1] == block.quote, "quote above thought")
    expect(block.row[#block.row] == block.delete, "trash control sits to the right")
    expect(block.quote.text == "│ " .. long and block.thought.text == long, "long text never truncated")
    expect(block.quote.height == nil and block.thought.height == nil, "natural height, not screen-capped")
    expect(block.quote.face.orig_size == 17 and not block.quote.bold
        and block.thought.face.orig_size == 20 and block.thought.bold, "separate typography")
    expect(view._blocks[2].thought == nil, "underline is not a thought")
    expect(block.column[#block.column] == block.metadata
        and block.metadata.face.orig_size == 14, "metadata is the final small text line")
    block.delete.callback()
    expect(deleted[1] == note and deleted[2] == view, "delete binds exact original record")
    block.delete:paintTo({ paintRect = function() end }, 40, 800)
    expect(block.delete.dimen.x == 40 and block.delete.dimen.y == 800,
        "painted control keeps its tap range where it is drawn")
    view.layout[1][1].callback(); view.layout[#view.layout][1].callback()
    expect(refresh and more, "refresh and more remain focusable")
    local delta
    view.scroll._scrollBy = function(_self, x, y) expect(x == 0, "vertical paging"); delta = y end
    view:onNextPage()
    expect(delta > 0 and delta < view.scroll.dimen.h, "page key keeps overlap inside long notes")
    view:onPrevPage()
    expect(delta < 0, "back key scrolls text without selecting another note")
end
print("own_notes_ui_spec: " .. checks .. " checks")

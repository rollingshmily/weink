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
    "horizontalgroup", "horizontalspan", "verticalgroup", "verticalspan", "titlebar" }) do
    preload("ui/widget/" .. name, Widget:extend{})
end
local TextBox, Top = Widget:extend{}, Widget:extend{}
preload("ui/widget/textboxwidget", TextBox)
preload("ui/widget/container/topcontainer", Top)
local Focus = Widget:extend{}
function Focus:init() end
preload("ui/widget/focusmanager", Focus)
preload("weink.ui.focus_nav", {
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
preload("ui/uimanager", { show = function(_self, view) shown = view end, close = function() end })
local Reviews = require("weink.lib.book_reviews")
local View = require("weink.ui.book_reviews_view")
local result = Reviews.normalize_list({ reviews = {
    { type = 4, content = "好", author = { nick = "A" }, star = 100, createTime = 1700000000 },
    { type = 4, content = "千言万语，汇成一句：鲁迅不愧是鲁迅！", author = { nick = "B" } },
    { type = 4, content = string.rep("这是一条足够长的书评。", 20), author = { nick = "C" } },
    { type = 4, content = "<p>&nbsp;<br></p>" },
}, hasMore = false })
local selected, switched, more_calls
local function open(mode, data)
    return View.show({ book_title = "Book", mode = mode, result = data or result }, {
        on_select = function(review, tab) selected = { review, tab } end,
        on_switch = function(tab) switched = tab end,
        on_more = function() more_calls = (more_calls or 0) + 1 end,
    })
end
for _, width in ipairs({ 600, 900, 1200 }) do
    screen_w = width; scale = width / 600
    local recommended, latest = open("recommended"), open("latest")
    expect(shown == latest and #recommended._review_buttons == 3 and #latest._review_buttons == 3,
        "both modes use only written reviews")
    for index = 1, 3 do
        local a, b = recommended._review_buttons[index], latest._review_buttons[index]
        local box = a.label_widget
        expect(getmetatable(box) == TextBox and getmetatable(a.label_container) == Top,
            "every row, including one character, uses explicit multiline text and top alignment")
        expect(box.face.name == "cfont" and box.face.orig_size == 17 and box.bold == false
            and box.line_height == 0 and box.alignment == "left", "latest multiline typography shared by all lengths")
        expect(a.avoid_text_truncation == false and a.text_font_size == 17,
            "Button cannot auto-shrink or switch text widget types")
        expect(box.height == 66 * scale and box.height_adjust == false and box.height_overflow_show_ellipsis,
            "fixed row text budget with overflow ellipsis")
        expect(a.label_container[1] == box and a.frame[1] == a.label_container,
            "new textbox is attached to actual frame; no stale centered label")
        expect(box.width == a.label_container.dimen.w and box.height == a.label_container.dimen.h,
            "text and hit-target geometry remain consistent")
        for _, key in ipairs({ "width", "height", "line_height", "alignment", "bold", "height_adjust" }) do
            expect(box[key] == b.label_widget[key], "recommended/latest share " .. key)
        end
        expect(not a.text:find("No review content.", 1, true), "no synthetic empty body text")
    end
    recommended._review_buttons[1].callback()
    expect(selected[1] == result.items[1] and selected[2] == "recommended", "short review remains selectable")
    recommended._tab_buttons[2].callback()
    expect(switched == "latest", "tab switch callback intact")
    expect(result.items[3].content == string.rep("这是一条足够长的书评。", 20), "preview truncation never deletes body")
end
local empty = open("recommended", { items = {}, has_more = true })
expect(#empty._review_buttons == 1 and empty._review_buttons[1].text == "Load more reviews",
    "filtered-empty view still exposes more button")
expect(#empty.layout == 2 and empty.layout[2][1] == empty._review_buttons[1],
    "empty-page continuation stays in key focus layout")
empty._review_buttons[1].callback()
expect(more_calls == 1, "empty-page continuation is actionable")
local done = open("recommended", { items = {}, has_more = false })
expect(#done._review_buttons == 0 and #done.layout == 1, "final empty result has tabs, no phantom rows")
print("book_reviews_ui_spec: " .. checks .. " checks")

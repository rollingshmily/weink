-- Personal cloud notes: full text in one scroll surface, never Menu summaries.
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GestureRange = require("ui/gesturerange")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local FocusNav = require("weread.ui.focus_nav")
local _ = require("weread.lib.i18n").tr
local Screen = Device.screen

-- Trash-can action button for every record. KOReader ships no delete/trash
-- icon and IconButton only accepts names from its own icon set, so the glyph
-- is painted from rectangles. The widget keeps the tap and focus protocol
-- FocusNav expects (onTap/onFocus/onUnfocus), like the Button it replaced.
local TrashButton = InputContainer:extend{
    dimen = nil,
    callback = nil,
    show_parent = nil,
}
function TrashButton:init()
    local size = tonumber(self.size) or Screen:scaleBySize(30)
    self.width, self.height = size, size
    self.glyph = math.floor(size * 0.6)
    self.dimen = Geom:new{ x = 0, y = 0, w = size, h = size }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function TrashButton:getSize()
    return self.dimen
end

function TrashButton:paintTo(bb, x, y)
    -- Containers only hand the position to paintTo: the widget owns its dimen,
    -- and the tap GestureRange points at that same object. Without this line
    -- the range stays at the origin and taps on the icon go nowhere.
    self.dimen.x, self.dimen.y = x, y
    local unit = math.max(1, math.floor(Screen:scaleBySize(1.4)))
    local g = self.glyph
    local left = x + math.floor((self.width - g) / 2)
    local top = y + math.floor((self.height - g) / 2)
    bb:paintRect(x, y, self.width, self.height,
        self.hasFocus and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_WHITE)
    local lid_y = top + math.floor(g * 0.22)
    local body_top = lid_y + unit
    local body_bottom = top + g - math.floor(g * 0.04)
    local body_left = left + math.floor(g * 0.2)
    local body_right = left + g - math.floor(g * 0.2)
    local ink = Blitbuffer.COLOR_BLACK
    bb:paintRect(left + math.floor(g * 0.4), lid_y - unit,
        math.floor(g * 0.2), unit, ink)
    bb:paintRect(body_left - unit, lid_y,
        (body_right - body_left) + 2 * unit, unit, ink)
    bb:paintRect(body_left, body_top, unit, body_bottom - body_top, ink)
    bb:paintRect(body_right - unit, body_top, unit, body_bottom - body_top, ink)
    bb:paintRect(body_left, body_bottom - unit, body_right - body_left, unit, ink)
    local slot_h = math.max(unit, body_bottom - body_top - 4 * unit)
    bb:paintRect(left + math.floor(g * 0.42), body_top + 2 * unit, unit, slot_h, ink)
    bb:paintRect(left + math.floor(g * 0.56), body_top + 2 * unit, unit, slot_h, ink)
end

function TrashButton:onTap()
    if self.callback then
        self.callback()
    end
    return true
end

function TrashButton:onFocus()
    self.hasFocus = true
    UIManager:setDirty(self.show_parent or self, "ui")
    return true
end

function TrashButton:onUnfocus()
    self.hasFocus = false
    UIManager:setDirty(self.show_parent or self, "ui")
    return true
end

local View = FocusManager:extend{}

function View:init()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    self.covers_fullscreen = true
    local margin = Size.padding.large
    local width = w - 2 * margin - 3 * Screen:scaleBySize(6)
    local icon_size = Screen:scaleBySize(30)
    local icon_gap = Size.padding.default
    local text_width = math.max(Screen:scaleBySize(120), width - icon_size - icon_gap)
    local function text(value, size, bold, box_width)
        return TextBoxWidget:new{
            text = value, face = Font:getFace("cfont", size), bold = bold or false,
            width = box_width or width, alignment = "left", line_height = 0,
            fgcolor = Blitbuffer.COLOR_BLACK, bgcolor = Blitbuffer.COLOR_WHITE,
        }
    end
    local title = TitleBar:new{
        width = w, title = self.title, title_multilines = true,
        with_bottom_line = true, show_parent = self,
        close_callback = function() self:onClose() end,
    }
    local refresh = Button:new{
        text = _("Refresh from WeRead"), width = w, show_parent = self,
        callback = self.on_refresh,
    }
    local content = VerticalGroup:new{ align = "left", HorizontalSpan:new{ width = width } }
    local rows = { { refresh } }
    self._blocks = {}
    for _index, record in ipairs(self.records) do
        local note = record.note
        local block = VerticalGroup:new{ align = "left" }
        -- Quote and thought are independent text boxes: normal wrapping and
        -- natural height retain even multi-screen paragraphs without ellipses.
        local quote = text("│ " .. (note.quote ~= "" and note.quote or _("No quoted text.")), 17,
            false, text_width)
        local column = VerticalGroup:new{ align = "left" }
        table.insert(column, quote)
        local thought
        if note.kind == "review" and note.content ~= "" then
            table.insert(column, VerticalSpan:new{ width = Size.padding.default })
            thought = text(note.content, 20, true, text_width)
            table.insert(column, thought)
        end
        -- The delete action became a right-hand icon, so the height it used to
        -- take goes into breathing room between the thought and the date.
        table.insert(column, VerticalSpan:new{ width = Size.padding.default })
        local metadata = text(record.metadata, 14, false, text_width)
        table.insert(column, metadata)
        local delete = TrashButton:new{
            size = icon_size, show_parent = self,
            callback = function() self.on_delete(note, self) end,
        }
        local row = HorizontalGroup:new{ align = "center" }
        table.insert(row, column)
        table.insert(row, HorizontalSpan:new{ width = icon_gap })
        table.insert(row, delete)
        table.insert(block, row)
        rows[#rows + 1] = { delete }
        table.insert(content, block)
        table.insert(content, LineWidget:new{
            dimen = Geom:new{ w = width, h = Size.border.thin },
            background = Blitbuffer.COLOR_BLACK,
        })
        table.insert(content, VerticalSpan:new{ width = Size.padding.default })
        self._blocks[#self._blocks + 1] = { quote = quote, thought = thought,
            metadata = metadata, delete = delete, block = block, row = row, column = column }
    end
    if #self.records == 0 then
        table.insert(content, text(_("No personal underlines or thoughts in this book."), 17))
    end
    local more
    if self.more then
        more = Button:new{ text = _("Load more of my thoughts"), width = width,
            show_parent = self, callback = self.on_more }
        table.insert(content, more)
        rows[#rows + 1] = { more }
    end
    table.insert(content, text(self.more and _("Cloud notes · more thoughts available")
        or _("Cloud notes · all loaded"), 14))
    self.scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = w, h = h - title:getHeight() - refresh:getSize().h },
        show_parent = self,
        HorizontalGroup:new{ HorizontalSpan:new{ width = margin }, content },
    }
    FocusNav.apply(self, rows, { scroll = self.scroll, outside_scroll = { [refresh] = true } })
    -- Unlike summary lists, PgFwd/PgBack scroll by pixels, not by focus row:
    -- a single quote/thought may be taller than the screen. D-pad/Tab still
    -- focus explicit delete controls and scroll them into view.
    self.onNextPage = function(view) view.scroll:_scrollBy(0, math.floor(view.scroll.dimen.h * 0.85)); return true end
    self.onPrevPage = function(view) view.scroll:_scrollBy(0, -math.floor(view.scroll.dimen.h * 0.85)); return true end
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    FocusNav.initialFocus(self, 1, 1)
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, margin = 0,
        dimen = self.dimen:copy(),
        VerticalGroup:new{ align = "left", title, refresh, self.scroll },
    }
end

function View:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end
function View:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end
function View:onClose()
    UIManager:close(self)
    return true
end

local M = {}
function M.show(data)
    local view = View:new(data)
    UIManager:show(view)
    return view
end
return M

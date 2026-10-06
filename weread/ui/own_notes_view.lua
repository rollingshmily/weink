-- Personal cloud notes: full text in one scroll surface, never Menu summaries.
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
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
local View = FocusManager:extend{}

function View:init()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    self.covers_fullscreen = true
    local margin = Size.padding.large
    local width = w - 2 * margin - 3 * Screen:scaleBySize(6)
    local function text(value, size, bold)
        return TextBoxWidget:new{
            text = value, face = Font:getFace("cfont", size), bold = bold or false,
            width = width, alignment = "left", line_height = 0,
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
        local quote = text("│ " .. (note.quote ~= "" and note.quote or _("No quoted text.")), 17)
        table.insert(block, quote)
        local thought
        if note.kind == "review" and note.content ~= "" then
            table.insert(block, VerticalSpan:new{ width = Size.padding.small })
            thought = text(note.content, 20, true)
            table.insert(block, thought)
        end
        table.insert(block, VerticalSpan:new{ width = Size.padding.small })
        table.insert(block, text(record.metadata, 14))
        local delete = Button:new{
            text = _("Delete from WeRead"), text_font_size = 14,
            width = width, align = "right", bordersize = 0, margin = 0,
            padding_v = Size.padding.small, show_parent = self,
            callback = function() self.on_delete(note, self) end,
        }
        table.insert(block, delete)
        rows[#rows + 1] = { delete }
        table.insert(content, block)
        table.insert(content, LineWidget:new{
            dimen = Geom:new{ w = width, h = Size.border.thin },
            background = Blitbuffer.COLOR_BLACK,
        })
        table.insert(content, VerticalSpan:new{ width = Size.padding.default })
        self._blocks[#self._blocks + 1] = { quote = quote, thought = thought, delete = delete, block = block }
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

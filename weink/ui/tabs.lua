-- Shared top tab bar: 书城 / 书籍 / 收藏 / 浮窗.
--
-- The store and the bookshelf are separate screens but must feel like one
-- page, so both build their tab row here instead of each keeping its own copy.

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LineWidget = require("ui/widget/linewidget")
local Screen = Device.screen
local VerticalGroup = require("ui/widget/verticalgroup")

local Tabs = {}

-- Modes in display order. `enabled` is resolved per call so the WeChat tabs
-- can be hidden for accounts that did not grant the favourites scope.
Tabs.MODES = { "store", "books", "favorites", "floating" }

-- labels: { store = "...", books = "...", favorites = "..." }
-- active: current mode string
-- enabled: optional { mode = false } to disable a single tab
-- on_switch: function(mode)
function Tabs.build(opts)
    opts = opts or {}
    local labels = opts.labels or {}
    local enabled_map = opts.enabled or {}
    local width = opts.width or Screen:getWidth()
    local modes = opts.modes or Tabs.MODES
    local cell_w = math.floor(width / #modes)
    local row = HorizontalGroup:new{}
    local buttons = {}
    for index, mode in ipairs(modes) do
        local active = mode == opts.active
        -- Only the storefront is always reachable; the rest need eink login,
        -- which the caller signals through `enabled`.
        local enabled = enabled_map[mode] ~= false
        local cell_width = index == #modes
            and width - cell_w * (#modes - 1) or cell_w
        local button = Button:new{
            text = labels[mode] or mode,
            width = cell_width,
            radius = 0,
            margin = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            text_font_size = opts.font_size or 22,
            text_font_bold = true,
            enabled = enabled,
            show_parent = opts.show_parent,
            callback = function()
                if enabled and not active and opts.on_switch then
                    opts.on_switch(mode)
                end
            end,
        }
        if enabled then buttons[#buttons + 1] = button end
        table.insert(row, VerticalGroup:new{
            align = "left",
            button,
            LineWidget:new{
                dimen = Geom:new{
                    w = cell_width,
                    h = active and Screen:scaleBySize(3) or 1,
                },
                background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
            },
        })
    end
    return {
        widget = FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, row },
        buttons = buttons,
    }
end

return Tabs
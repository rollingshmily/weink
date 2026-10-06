-- Exact eink queries and UI pagination callbacks; no network or account writes.
package.path = "./?.lua;" .. package.path
local checks = 0
local function expect(value, label) checks = checks + 1; assert(value, label) end
local Reviews = require("weread.lib.book_reviews")
local function rows(count, empty, start)
    local result = {}
    for i = (start or 1), count do
        result[#result + 1] = { review = { reviewId = tostring(i), type = 4,
            content = empty and "<p>&nbsp;</p>" or "好", author = { nick = "Reader" } } }
    end
    return result
end
local response, requests = {}, {}
local client = {}
function client:get_book_reviews(book, list_type, count, kind, cursor)
    requests[#requests + 1] = { book = book, list_type = list_type, count = count, kind = kind, cursor = cursor }
    if response.fail then error("transport failure") end
    return response
end
response = { reviews = rows(20, true), totalCount = 1087, hasMore = 0, synckey = 99 }
local first = Reviews.load_more(client, "book", 8, 4)
expect(first.visible_count == 0 and first.raw_count == 20 and first.has_more,
    "full rating-only snapshot offers more even with hasMore=0")
expect(first.total_count == 1087 and first.request_count == 20, "server total is not a visible total")
response = { reviews = rows(39), totalCount = 1087, hasMore = 0, synckey = 99 }
local second = Reviews.load_more(client, "book", 8, 4, first)
expect(requests[2].count == 40 and requests[2].cursor == nil, "expand snapshot count, not incremental watermark")
expect(second.visible_count == 39 and second.raw_count == 39 and not second.has_more,
    "larger snapshot replaces rather than duplicates rows; short snapshot ends despite totalCount")
response = { reviews = rows(40), totalCount = 1087, hasMore = 0 }
local full = Reviews.load_more(client, "book", 8, 4, first)
expect(full.has_more, "another full snapshot can continue")
local stalled = Reviews.load_more(client, "book", 8, 4, full)
expect(not stalled.has_more and #stalled.items == 40, "server cap/repeated snapshot cannot loop")

response = { reviews = rows(1, true), totalCount = 80, hasMore = 1, synckey = 10 }
local delta = Reviews.load_more(client, "book", 8, 4)
expect(delta.has_more and delta.next_synckey == 10 and delta.visible_count == 0, "empty body sync page keeps cursor")
response = { reviews = {}, totalCount = 80, hasMore = true, synckey = 20 }
local empty_delta = Reviews.load_more(client, "book", 8, 4, delta)
expect(requests[#requests].cursor == 10 and requests[#requests].count == 20,
    "incremental continuation reuses count and sends server synckey")
expect(empty_delta.visible_count == 0 and empty_delta.has_more and empty_delta.next_synckey == 20,
    "even a raw-empty advancing page does not truncate")
response = { reviews = rows(2, false, 2), totalCount = 80, hasMore = 0, synckey = 30 }
local last = Reviews.load_more(client, "book", 8, 4, empty_delta)
expect(#last.items == 1 and last.items[1].review_id == "2" and not last.has_more,
    "real short review after two empty pages is reachable")
expect(last.total_count == 80 and last.raw_count == 2, "counts remain distinct after sync merge")

response = { reviews = rows(2), hasMore = 1, synckey = 40 }
local overlap = Reviews.load_more(client, "book", 3)
response = { reviews = rows(3), hasMore = 0, synckey = 50 }
local merged = Reviews.load_more(client, "book", 3, nil, overlap)
expect(#merged.items == 3 and merged.raw_count == 3, "overlapping IDs deduplicated on incremental sync")
for _, bad in ipairs({
    { reviews = {}, hasMore = 1 },
    { reviews = {}, hasMore = 1, synckey = 20 },
    { reviews = {}, hasMore = 1, synckey = 10 },
    {}, { errcode = -1 },
}) do
    response = bad
    expect(not pcall(Reviews.load_more, client, "book", 8, 4, empty_delta), "invalid/stalled/cyclic pages rejected")
end
expect(empty_delta.next_synckey == 20 and empty_delta.visible_count == 0,
    "failure does not mutate previous result or cursor")

-- Test actual library flow, per-tab caches, retries and no tight request loops.
local function empty_module() return {} end
for _, name in ipairs({ "weread.ui.chapter_list_view", "ui/widget/buttondialog", "ui/widget/confirmbox",
    "weread.lib.content", "ui/widget/infomessage", "ui/widget/inputdialog", "ui/widget/progressbardialog",
    "ui/widget/textviewer", "weread.lib.protocol" }) do package.preload[name] = empty_module end
package.preload["weread.lib.logger"] = function() return { err = function() end } end
package.preload["weread.lib.plugin_util"] = function() return {
    tr = function(s) return s end, log_error = tostring, display_error = tostring,
    T = function(s, ...) local v = {...}; return (s:gsub("%%(%d)", function(i) return tostring(v[tonumber(i)]) end)) end,
} end
local views = {}
package.preload["weread.ui.book_reviews_view"] = function() return { show = function(data, callbacks)
    local view = { data = data, callbacks = callbacks }; views[#views + 1] = view; return view
end } end
package.preload["ui/uimanager"] = function() return { close = function(_self, view) view.closed = true end } end
local Library = require("weread.ui.library")
local tasks, notices = {}, {}
local host = setmetatable({ client = client }, { __index = Library })
function host:requireLogin() return true end
function host:showBusy() end
function host:closeBusy() end
function host:showInfo(text) notices[#notices + 1] = text end
function host:runOnlineTask(_label, callback) tasks[#tasks + 1] = callback; return true end
local function flush() assert(table.remove(tasks, 1))() end
response = { reviews = rows(20, true), hasMore = 0, totalCount = 1087 }
host:showBookReviews({ bookId = "book", title = "Test book" })
expect(#tasks == 1 and #views == 0, "first load is deferred")
flush()
local rec = views[#views]
expect(rec.data.mode == "recommended" and rec.data.result.has_more and #rec.data.result.items == 0,
    "rating-only initial view can continue")
expect(requests[#requests].list_type == 8 and requests[#requests].kind == 4,
    "recommended still requests listType=8&type=4")
rec.callbacks.on_more(); rec.callbacks.on_more()
expect(#tasks == 1, "double tap cannot enqueue duplicate page requests")
response = { fail = true }; flush()
expect(not rec.closed and #notices == 1 and #views == 1, "failed page retains old view and cache")
response = { reviews = rows(21), hasMore = 0 }
rec.callbacks.on_more(); flush()
local expanded = views[#views]
expect(rec.closed and #expanded.data.result.items == 21 and requests[#requests].count == 40,
    "retry uses same target count and replaces view only after success")
expanded.callbacks.on_switch("latest")
response = { reviews = rows(12), totalCount = 40, hasMore = 0 }; flush()
expect(requests[#requests].list_type == 3 and requests[#requests].kind == nil and requests[#requests].count == 20,
    "latest stays listType=3 with an independent count")
local reqs = #requests
views[#views].callbacks.on_switch("recommended")
expect(#tasks == 0 and #requests == reqs and #views[#views].data.result.items == 21,
    "switching back reuses the correct expanded tab cache")

-- Exact transport binding, including an optional incremental cursor.
package.preload["ltn12"] = empty_module
package.preload["socketutil"] = empty_module
package.preload["socket.http"] = empty_module
package.preload["json"] = empty_module
local Client = require("weread.lib.client")
local api = setmetatable({}, { __index = Client })
local path, params
function api:eink_json(p, q) path, params = p, q; return {} end
api:get_book_reviews("book", 8, 40, 4)
expect(path == "/review/list" and params.listType == 8 and params.type == 4 and params.count == 40
    and params.synckey == nil, "snapshot transport uses exact existing endpoint and selectors")
api:get_book_reviews("book", 3, 20, nil, 123)
expect(path == "/review/list" and params.listType == 3 and params.type == nil and params.synckey == 123,
    "incremental continuation forwards cursor without changing latest selector")
print("book_reviews_loading_spec: " .. checks .. " checks")

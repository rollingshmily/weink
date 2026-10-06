package.path = "./?.lua;" .. package.path
local checks = 0
local function expect(value, label)
    checks = checks + 1
    assert(value, label)
end
local Notes = require("weread.lib.own_notes")
local function review(rid, vid, book, kind)
    return { review = { review = { reviewId = rid, author = { userVid = vid or "me" },
        bookId = book or "b", type = kind or 1, chapterUid = 7, abstract = "quote", content = "thought",
        createTime = 1700000000 } } }
end
local marks = { updated = {
    { bookmarkId = "same", type = 1, chapterUid = 7, markText = "quote", reviewId = "do-not-delete" },
    { bookmarkId = "same", type = 1 }, -- duplicate
    { bookmarkId = "page", type = 0 },
    { bookmarkId = "other-book", bookId = "elsewhere", type = 1 },
    { bookmarkId = "foreign", userVid = "them", type = 1 },
}, chapters = { { chapterUid = 7, title = "Chapter title" } } }
local own = Notes.bookmarks(marks, "b", "me")
expect(#own == 1 and own[1].kind == "bookmark", "type=1 bookmarks must stay underlines")
expect(#Notes.bookmarks({ updated = { { type = 1, reviewId = "not-a-bookmark-id" } } }, "b", "me") == 0,
    "a missing bookmarkId must not fall back to an attached reviewId")
local page = { reviews = { review("same"), review("same"), review("foreign", "them"),
    review("other-book", "me", "x"), review("rating", "me", "b", 4),
    { type = 1, reviewId = "anonymous", author = {} },
}, hasMore = 1, synckey = 100 }
local thoughts, more, cursor = Notes.review_page(page, "b", "me", 0)
expect(#thoughts == 1 and thoughts[1].kind == "review", "own thoughts filtered by author/book/type and deduplicated")
expect(more and cursor == 100, "server cursor preserved")
expect(not pcall(Notes.review_page, page, "b", "me", 100), "stalled pagination rejected")
expect(not pcall(Notes.review_page, { reviews = {}, hasMore = 1 }, "b", "me", 0), "missing cursor rejected")
expect(not pcall(Notes.review_page, {}, "b", "me", 0), "malformed list not accepted as empty")
expect(not pcall(Notes.bookmarks, {}, "b", "me"), "malformed bookmarks rejected")
local many = { reviews = {}, hasMore = 0 }
for i = 1, 601 do many.reviews[i] = review(tostring(i)) end
expect(#Notes.review_page(many, "b", "me", 0) == 601, "personal list has no 20/500 row truncation")
local both = Notes.merge(own, thoughts)
expect(#both == 2, "bookmark/review IDs are separate namespaces")
expect(#Notes.merge(both, thoughts) == 2, "pagination overlaps deduplicated")
local removed = Notes.merge(both, {}, { "same" })
expect(#removed == 1 and removed[1].kind == "bookmark", "review tombstone leaves paired underline")

package.preload["ltn12"] = function() return {} end
package.preload["socketutil"] = function() return {} end
package.preload["socket.http"] = function() return {} end
package.preload["json"] = function() return { encode = function() return "{}" end } end
package.preload["weread.lib.logger"] = function() return { info = function() end, warn = function() end } end
local Client = require("weread.lib.client")
local requests, posted, active_vid, response = {}, {}, "me", { succ = 1 }
local client = setmetatable({}, { __index = Client })
function client:eink_credentials() return active_vid end
function client:eink_json(path, params) requests[#requests + 1] = { path = path, params = params }; return page end
function client:eink_post_json(path, params) posted[#posted + 1] = { path = path, params = params }; return response end
function client:eink_request(path, params) requests[#requests + 1] = { path = path, params = params }; return "{}", 200 end
function client:decode_http_json() return marks end
client:eink_own_reviews("b", 25)
expect(requests[1].path == "/review/list" and requests[1].params.listType == 11
    and requests[1].params.mine == 1 and requests[1].params.listMode == 0
    and requests[1].params.synckey == 25 and requests[1].params.bookId == "b", "exact APK own list query")
expect(requests[1].params.count == nil and requests[1].params.type == nil, "no arbitrary count/type cap")
client:eink_bookmarklist("b")
client:eink_bookmarklist("b")
expect(#requests == 2, "existing cached bookmark calls preserved")
client:eink_bookmarklist("b", true)
expect(#requests == 3 and requests[3].params.synckey == 0, "refresh bypasses cached/delta bookmarks")
Notes.delete(client, own[1], "b", "me")
expect(posted[1].path == "/book/removeBookmark" and posted[1].params.bookmarkId == "same"
    and posted[1].params.reviewId == nil, "delete underline never deletes attached thought")
Notes.delete(client, thoughts[1], "b", "me")
expect(posted[2].path == "/review/delete" and posted[2].params.reviewId == "same", "thought deletes only reviewId")
for _, bad in ipairs({ {}, { succ = 0 }, { succ = 1, errcode = -1 } }) do
    response = bad
    expect(not pcall(Notes.delete, client, thoughts[1], "b", "me"), "unconfirmed delete must fail")
end
response = { succ = 1 }
local n = #posted
active_vid = "other"
expect(not pcall(Notes.delete, client, thoughts[1], "b", "me") and #posted == n, "account switch blocks delete")
active_vid = "me"
expect(not pcall(Notes.delete, client, thoughts[1], "other-book", "me") and #posted == n, "wrong book blocks delete")
expect(not pcall(Notes.delete, client, { owner_vid = "me", book_id = "b", kind = "review" }, "b", "me"), "missing ID blocks delete")

-- Execute the real UI callbacks with harmless in-memory transport/widget doubles.
local shown, menus, notices, tasks = {}, {}, {}, {}
package.preload["ui/uimanager"] = function() return {
    show = function(_self, widget) shown[#shown + 1] = widget end,
    close = function(_self, widget) widget.closed = true end,
} end
package.preload["ui/widget/textviewer"] = function() return { new = function(_self, args) return args end } end
package.preload["ui/widget/confirmbox"] = function() return { new = function(_self, args) return args end } end
package.preload["weread.lib.plugin_util"] = function() return {
    tr = function(s) return s end, display_error = tostring,
    T = function(s, ...) local v = {...}; return (s:gsub("%%(%d)", function(i) return tostring(v[tonumber(i)]) end)) end,
} end
local UI = require("weread.ui.own_notes")
local binding, book_reads, thought_reads = { book_id = "b", title = "Test book" }, 0, 0
local host = { ui = { document = { file = "book.epub" } }, client = client }
function host:_annotationBinding() return binding end
function host:requireLogin() return true end
function host:showBusy() end
function host:closeBusy() end
function host:showInfo(s) notices[#notices + 1] = s end
function host:runOnlineTask(_label, fn) tasks[#tasks + 1] = fn; return true end
function host:showList(title, items, _empty, opts)
    local menu = { title = title, items = items, opts = opts }; menus[#menus + 1] = menu; return menu
end
local review_page = page
function client:eink_bookmarklist(_book, fresh)
    expect(fresh == true, "UI reload requests fresh bookmarks")
    book_reads = book_reads + 1; return marks
end
function client:eink_own_reviews(_book, key)
    thought_reads = thought_reads + 1
    requests[#requests + 1] = { cursor = key }
    return review_page
end
local function flush() local fn = table.remove(tasks, 1); assert(fn); fn() end
local session = UI.show(host)
expect(#tasks == 1 and #menus == 0, "UI load is deferred through network task")
flush()
expect(#session.items == 2 and session.more and menus[#menus].opts.items_per_page == 8, "paginated personal list renders")
expect(menus[#menus].items[3].text:find("Chapter title", 1, true), "chapter title rendered")
local thought_row = menus[#menus].items[4]
local thought_date = os.date("%Y-%m-%d", 1700000000)
expect(thought_row.text == "Chapter title · " .. thought_date .. "\nthought",
    "thought row starts with chapter/date, not repeated My thought prefix; body intact")
expect(menus[#menus].title == "My underlines/thoughts · Test book", "page title keeps personal context")
expect(menus[#menus].items[3].text:find("My underline · ", 1, true) == 1,
    "mixed list still distinguishes underline rows")
thought_row.callback()
local initial_thought_viewer = shown[#shown]
expect(initial_thought_viewer.title == "My thought", "thought detail retains meaningful title")
expect(initial_thought_viewer.text == "Test book\nChapter title\n" .. thought_date
    .. "\n\nQuoted text\nquote\n\nMy thought\nthought",
    "detail removes only duplicate type header, preserves chapter/date/quote/body and section labels")
review_page = { reviews = { review("second") }, hasMore = 0, synckey = 200 }
menus[#menus].items[2].callback() -- load more
flush()
expect(book_reads == 1 and thought_reads == 2 and requests[#requests].cursor == 100, "more uses server cursor without reloading bookmarks")
expect(#session.items == 3 and not session.more, "second page accumulated and all-loaded reflected")

menus[#menus].items[2].callback() -- underline detail
local viewer = shown[#shown]
expect(viewer.text:find("quote", 1, true) and viewer.text:find("Chapter title", 1, true), "detail contains quote and chapter")
n = #posted
viewer.buttons_table[1][1].callback()
local confirm = shown[#shown]
expect(#posted == n and confirm.text:find("cannot be undone", 1, true), "delete opens confirmation, no network mutation")
-- Cancel is no callback, hence no delete. A stale confirmation must be harmless.
active_vid = "other"
confirm.ok_callback(); flush()
expect(#posted == n and #session.items == 3, "account switch after confirmation leaves list intact")
active_vid = "me"
viewer.buttons_table[1][1].callback()
confirm = shown[#shown]
confirm.ok_callback()
host.ui.document.file = "changed.epub"
flush()
expect(#posted == n, "document switch during queued delete blocks request")
host.ui.document.file = "book.epub"
response = { succ = 0 }
viewer.buttons_table[1][1].callback(); shown[#shown].ok_callback(); flush()
expect(#session.items == 3 and not viewer.closed, "failed deletion preserves detail and list")
response = {}
viewer.buttons_table[1][1].callback(); shown[#shown].ok_callback(); flush()
expect(#session.items == 3 and not viewer.closed, "empty HTTP-success payload cannot remove a note")
response = { succ = 1 }
-- After successful deletion the cloud refresh itself fails: retain all other rows.
function client:eink_bookmarklist() error("refresh unavailable") end
viewer.buttons_table[1][1].callback(); shown[#shown].ok_callback(); flush()
expect(viewer.closed and #session.items == 2 and session.items[1].kind == "review", "successful delete removes only chosen kind")
expect(notices[#notices]:find("refresh failed", 1, true), "successful mutation with failed refresh is reported distinctly")
expect(posted[#posted].path == "/book/removeBookmark", "UI selected underline posts only bookmark endpoint")
n = #posted
confirm.ok_callback(); flush()
expect(#posted == n, "reusing an old confirmation cannot delete an already removed row")

-- A completed cloud refresh after a thought delete retains its paired underline.
function client:eink_bookmarklist() return marks end
review_page = { reviews = { review("same") }, hasMore = 0, synckey = 300 }
local fresh = UI.show(host); flush()
menus[#menus].items[3].callback()
local thought_viewer = shown[#shown]
function client:eink_post_json(path, params)
    posted[#posted + 1] = { path = path, params = params }
    review_page = { reviews = {}, hasMore = 0, synckey = 301 }
    return { succ = true }
end
thought_viewer.buttons_table[1][1].callback(); shown[#shown].ok_callback(); flush()
expect(#fresh.items == 1 and fresh.items[1].kind == "bookmark" and thought_viewer.closed,
    "confirmed thought deletion refreshes and retains underline")
expect(posted[#posted].path == "/review/delete", "UI thought delete routes to correct endpoint")

binding = nil
local before = #tasks
UI.show(host)
expect(#tasks == before and notices[#notices]:find("Match this local book", 1, true), "unbound local book has no network side effects")
print("own_notes_spec: " .. checks .. " checks")

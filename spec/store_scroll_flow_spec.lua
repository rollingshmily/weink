-- Store controller regressions: cover callbacks cannot reset/navigate pages,
-- and reaching a terminal category/search page cannot fire another request.
package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(ok, message)
    checks = checks + 1
    assert(ok, message)
end
local updates, draws, completion = 0, 0, nil
local view = { mode = "store" }
function view:apply() draws = draws + 1 end
function view:updateCovers(paths)
    updates = updates + 1
    self.paths = paths
end
package.preload["weink.ui.library_view"] = function()
    return { show = function() draws = draws + 1; return view end }
end
package.preload["ui/widget/confirmbox"] = function() return {} end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["ui/uimanager"] = function() return { scheduleIn = function() end } end
package.preload["weink.lib.logger"] = function() return { err = function() end } end
package.preload["weink.lib.plugin_util"] = function()
    return { tr = function(text) return text end, T = function(text, value)
        return (text:gsub("%%1", function() return tostring(value) end))
    end,
        log_error = tostring, display_error = tostring }
end

local StoreUI = require("weink.ui.store")
local cache_paths = {}
local fake = setmetatable({
    _store_cover_layout = { columns = 5, rows = 3 },
    getShelfCoverCache = function()
        return { pathFor = function(_self, book) return cache_paths[book] end }
    end,
    fetchStoreCovers = function(_self, _books, callback) completion = callback end,
}, { __index = StoreUI })
local book = { book_id = "42", title = "Second page" }
local frame = { rows = { { kind = "book", book = book } }, keep_offset = 200 }
fake:storePush(frame)
expect(draws == 1, "initial view is drawn once")
cache_paths[book] = "/cache/42.jpg"
completion()
expect(updates == 1 and draws == 1, "cover completion updates cells without applying the frame")
expect(view.paths[book] == cache_paths[book], "downloaded cover path reaches the existing cell")
local old_completion = completion
fake:storePush({ rows = {} })
old_completion()
expect(updates == 1 and draws == 2, "completion from an older frame does not redraw the new page")
fake._store_nav = { frame }
view.mode = "books"
old_completion()
expect(updates == 1, "store completion does not repaint the bookshelf tab")
view.mode = "store"
view._closed = true
old_completion()
expect(updates == 1, "store completion does not repaint a closed view")
view._closed = nil
fake.shelf_view = {}
old_completion()
expect(updates == 1, "store completion does not touch a replacement view")
fake.shelf_view = view

local mounted, category_requests, search_requests
category_requests, search_requests = 0, 0
fake.storePush = function(_self, state) mounted = state end
fake.storeReplace = fake.storePush
fake.storeLoadCategoryBooks = function() category_requests = category_requests + 1 end
fake.storeLoadSearch = function() search_requests = search_requests + 1 end
fake._store_category_books = { title = "Category", books = { book }, has_more = false }
fake:mountCategoryBooks(false)
expect(mounted.on_more == nil and mounted.on_fill == nil, "terminal category has no auto-load callbacks")
fake._store_category_books.has_more = true
fake:mountCategoryBooks(true)
expect(type(mounted.on_more) == "function", "category with more books can continue")
mounted.on_more(240)
expect(category_requests == 1 and fake._store_category_books.keep_offset == 240,
    "category continuation records the actual trigger offset")
mounted.on_fill()
fake:mountCategoryBooks(true)
expect(mounted.on_fill == nil, "short category page is auto-filled only once")
mounted.loader()
expect(fake._store_category_books.keep_offset == 0 and fake._store_category_books.autofilled == nil,
    "explicit category refresh resets position and short-page fill state")

fake._store_search = { keyword = "Sample", books = { book }, has_more = false }
fake:mountSearch(false)
expect(mounted.on_more == nil and mounted.on_fill == nil, "terminal search has no auto-load callbacks")
fake._store_search.has_more = true
fake:mountSearch(true)
mounted.on_more(270)
expect(search_requests == 1 and fake._store_search.keep_offset == 270,
    "search continuation records the actual trigger offset")
mounted.on_fill()
fake:mountSearch(true)
expect(mounted.on_fill == nil, "short search page is auto-filled only once")

-- The first screen contains only root cards; novel children live one level down.
fake._store_category_raw = dofile("spec/fixtures/store_categories_20261009.lua")
fake:mountCategoryTree(false)
expect(mounted.title == "All categories", "category screen uses the all-categories title")
local headers, cards, category_ids = 0, 0, {}
for _i, row in ipairs(mounted.rows) do
    if row.kind == "group" then
        headers = headers + 1
    elseif row.kind == "category" then
        cards = cards + 1
        expect(not category_ids[row.category.category_id], "category card is not duplicated")
        category_ids[row.category.category_id] = true
    end
end
expect(headers == 0 and cards == 22, "all 22 roots are cards, without headings or expanded children")
expect(category_ids["300000"] and category_ids["200000"] and category_ids["700000"],
    "literature, history and computers are directly selectable")
expect(category_ids["1900000"] and category_ids["2000000"] and category_ids["100000"],
    "all three novel parents are first-level cards")
expect(not category_ids["100006"], "novel subcategories are not expanded on the root screen")
local selected_category
fake.openCategoryBooks = function(_self, id, title) selected_category = { id = id, title = title } end
local root_frame = mounted
local novel_sizes = { ["1900000"] = 13, ["2000000"] = 16, ["100000"] = 6 }
for _i, row in ipairs(root_frame.rows) do
    local size = novel_sizes[row.category.category_id]
    if size then
        selected_category = nil
        fake:onStoreRowSelected(row)
        expect(mounted.title == row.category.title and #mounted.rows == size,
            "novel parent opens its own child-card screen")
        expect(selected_category == nil, "novel parent does not request a book list")
        for _j, child_row in ipairs(mounted.rows) do
            expect(child_row.kind == "category"
                and child_row.category.parent_id == row.category.category_id,
                "second-level page contains only children of the selected parent")
        end
        local child_frame = mounted
        child_frame.loader()
        expect(mounted.title == child_frame.title and #mounted.rows == size,
            "refresh stays inside the selected novel category")
        fake:onStoreRowSelected(mounted.rows[1])
        expect(selected_category and selected_category.id == mounted.rows[1].category.category_id,
            "a novel subcategory opens its own book list")
    end
end
for _i, row in ipairs(root_frame.rows) do
    if row.kind == "category" and row.category.category_id == "700000" then
        fake:onStoreRowSelected(row)
    end
end
expect(selected_category and selected_category.id == "700000" and selected_category.title == "计算机",
    "restored standalone category routes to its own book list")

-- Exercise the real stack: returning from a child must reveal all root cards.
local hierarchy = setmetatable({
    _store_category_raw = fake._store_category_raw,
    _store_cover_layout = false,
    storeDraw = function() end,
}, { __index = StoreUI })
hierarchy:storePush({ title = "WeRead Store", rows = {} })
hierarchy:mountCategoryTree(false)
local hierarchy_root = hierarchy:storeTop()
hierarchy:onStoreRowSelected(hierarchy_root.rows[1])
expect(#hierarchy:storeNav() == 3 and hierarchy:storeTop().title == "男生小说",
    "opening novel children pushes exactly one navigation level")
expect(hierarchy:storeFrameData().back_label == "‹ Back to All categories",
    "child page names the actual parent in its back button")
hierarchy:storeFrameRefresh(hierarchy:storeTop())
expect(#hierarchy:storeNav() == 3 and hierarchy:storeTop().title == "男生小说",
    "child refresh replaces the frame instead of pushing or returning to the root")
hierarchy:storePush({ title = "Subcategory books", rows = {} })
expect(hierarchy:storeFrameData().back_label == "‹ Back to 男生小说",
    "book-list back button targets the selected novel parent")
expect(hierarchy:storeBack() and hierarchy:storeTop().title == "男生小说",
    "book list returns to its child-category screen")
expect(hierarchy:storeBack() and hierarchy:storeTop() == hierarchy_root
    and #hierarchy:storeTop().rows == 22,
    "novel children return to the unchanged 22 root cards")
expect(hierarchy:storeBack() and hierarchy:storeTop().title == "WeRead Store",
    "all categories returns to the storefront")
expect(not hierarchy:storeBack(), "storefront root cannot pop off the stack")

-- Navigation requests keep the current view visible, without loading dialogs.
fake.showBusy = function() error("store navigation opened a loading dialog") end
fake.closeBusy = function() error("store navigation closed an unrelated dialog") end
fake.requireLogin = function() return true end
fake.storeFetchBlocked = function() return false end
fake.storeFetchBegin = function() end
fake.storeFetchEnd = function() end
fake.runOnlineTask = function(_self, _label, callback) callback() end
local request_count, failure = 0, nil
local function response()
    request_count = request_count + 1
    return { books = { { bookId = "42", title = "Sample" } }, hasMore = true }
end
fake.client = {
    store_home = function() request_count = request_count + 1; return {} end,
    category_list = function() request_count = request_count + 1; return {} end,
    store_category_books = response,
    search_store = response,
    book_similar = response,
}
StoreUI.storeLoadHome(fake, false)
StoreUI.storeLoadCategories(fake, false)
fake._store_category_books = { id = "1", title = "Category", books = {} }
StoreUI.storeLoadCategoryBooks(fake, false)
fake._store_search = { keyword = "Sample", books = {} }
StoreUI.storeLoadSearch(fake, false)
StoreUI.showSimilarBooks(fake, book)
expect(request_count == 5, "all five navigation loaders work without loading dialogs")
fake.client.store_category_books = function() error("request failed") end
fake.showInfo = function(_self, message) failure = message end
StoreUI.storeLoadCategoryBooks(fake, true)
expect(failure ~= nil, "real request failures still display an error")

print(("store_scroll_flow_spec: %d checks"):format(checks))

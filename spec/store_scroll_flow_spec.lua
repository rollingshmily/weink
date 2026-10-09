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
    return { tr = function(text) return text end, T = function(text) return text end,
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

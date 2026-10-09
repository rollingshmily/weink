-- Bookstore UI: home feed, category browsing, search, and book records.
--
-- Rendered through weink.ui.library_view so the storefront and the bookshelf
-- share one screen chrome (title bar + 书城/书籍/收藏/浮窗 tabs + paging).
-- The actionBar callbacks in library_view are shelf-specific and are only
-- invoked when the caller supplies them, so this module leaves them unset.

local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local LibraryView = require("weink.ui.library_view")
local PluginUtil = require("weink.lib.plugin_util")
local Store = require("weink.lib.store")
local UIManager = require("ui/uimanager")

local _ = PluginUtil.tr
local T = PluginUtil.T
local log_error = PluginUtil.log_error
local display_error = PluginUtil.display_error
local logger = require("weink.lib.logger")

local M = {}

-- Store requests are tap-driven, so the only thing to defend against is a
-- double tap or a re-entrant open while the first call is still in flight.
local STORE_MIN_INTERVAL_SECONDS = 1.0
local STORE_INFLIGHT_TTL_SECONDS = 15

local function now_seconds()
    local ok, socket = pcall(require, "socket")
    if ok and type(socket) == "table" and type(socket.gettime) == "function" then
        return socket.gettime()
    end
    return os.time()
end

function M:storeFetchAllowed(key)
    local now = now_seconds()
    local at = self._store_fetch_at and self._store_fetch_at[key]
    if at and (now - at) < STORE_MIN_INTERVAL_SECONDS then return false end
    if self._store_inflight and self._store_inflight[key] then return false end
    return true
end

function M:storeFetchBlocked(key)
    if self:storeFetchAllowed(key) then return false end
    self:showTransientInfo(_("Slow down a little."), 1)
    return true
end

function M:storeFetchBegin(key)
    self._store_fetch_at = self._store_fetch_at or {}
    self._store_inflight = self._store_inflight or {}
    self._store_inflight_token = self._store_inflight_token or {}
    self._store_fetch_at[key] = now_seconds()
    local token = {}
    self._store_inflight_token[key] = token
    self._store_inflight[key] = true
    -- Safety net: never let a lost callback wedge the button forever.
    UIManager:scheduleIn(STORE_INFLIGHT_TTL_SECONDS, function()
        if self._store_inflight_token[key] == token then
            self._store_inflight[key] = nil
        end
    end)
end

function M:storeFetchEnd(key)
    if self._store_inflight then self._store_inflight[key] = nil end
    if self._store_inflight_token then self._store_inflight_token[key] = nil end
end

local HOME_PAGE_SIZE = 10
local STORE_TITLE = _("WeRead Store")

local function mp_mode(mode)
    return mode == "favorites" and 2 or 1
end

-- Section heading for the home feed, falling back to the storefront name.
local function section_title(section)
    local name = section.name
    if type(name) ~= "string" or name == "" then
        return _("Recommendations")
    end
    return name
end

function M:showStoreHome(old_view)
    if not self:requireLogin(true, true) then return end
    if old_view then UIManager:close(old_view) end
    if self._store_sections then
        self:loadStoreHome()
        return
    end
    if self:storeFetchBlocked("home") then return end
    self:storeFetchBegin("home")
    self:showBusy(_("Loading book store..."))
    self:runOnlineTask(_("WeRead Store"), function()
        local ok, result = pcall(function()
            return self.client:store_home()
        end)
        self:closeBusy()
        self:storeFetchEnd("home")
        if not ok then
            logger.err("store home failed:", log_error(result))
            self:showInfo(T(_("Load book store failed:\n%1"), display_error(result)))
            return
        end
        self._store_sections = Store.sections(result)
        self:loadStoreHome()
    end)
end

function M:loadStoreHome()
    local rows = self:buildStoreRows(self._store_sections or {})
    self._store_mode = "store"
    self:renderStoreRows(rows, _("WeRead Store"), "store", {
        on_refresh = function()
            self._store_sections = nil
            self._store_page = 1
            self:showStoreView()
        end,
    })
end

-- Flatten feed sections into display rows: a heading row per section followed
-- by its books (capped) or category tiles.
function M:buildStoreRows(sections)
    local rows = {
        { kind = "action", action = "search", label = _("Search the store") },
        { kind = "action", action = "categories", label = _("All categories") },
    }
    for _i, section in ipairs(sections) do
        local has_content = #section.books > 0
            or #section.categories > 0
            or #section.topics > 0
        if has_content then
            rows[#rows + 1] = {
                kind = "heading",
                text = section_title(section),
                status = section.total > 0 and tostring(section.total) or "",
            }
        end
        for index, book in ipairs(section.books) do
            if index > HOME_PAGE_SIZE then break end
            rows[#rows + 1] = { kind = "book", book = book }
        end
        for _j, category in ipairs(section.categories) do
            rows[#rows + 1] = { kind = "category", category = category }
        end
        for _j, topic in ipairs(section.topics) do
            rows[#rows + 1] = { kind = "topic", topic = topic }
        end
        if section.has_more and #section.books > HOME_PAGE_SIZE then
            rows[#rows + 1] = { kind = "more", section = section }
        end
    end
    return rows
end

function M:renderStoreRows(rows, title, mode, callbacks)
    callbacks = callbacks or {}
    local view
    local open_row = function(row)
        self:onStoreRowSelected(row, view)
    end
    view = LibraryView.show({
        mode = mode or "store",
        title = title or STORE_TITLE,
        rows = rows,
        paged = true,
        page = self._store_page or 1,
        page_size = math.max(4, 12),
    }, {
        on_switch = function(new_mode)
            self:onStoreTabSwitch(new_mode, view)
        end,
        on_refresh = callbacks.on_refresh,
        on_select = open_row,
        on_page_changed = function(new_page)
            self._store_page = new_page
            self:renderStoreRows(rows, title, mode, callbacks)
        end,
    })
    self._store_view = view
    self._store_rows = rows
    self._store_title = title
    self._store_mode = mode
    self._store_callbacks = callbacks
    return view
end

function M:showStoreView()
    self._store_page = 1
    if self._store_sections then
        self:renderStoreRows(self._store_sections, self._store_title, self._store_mode,
            self._store_callbacks)
    else
        self:showStoreHome()
    end
end

function M:closeStoreView(view)
    local target = view or self._store_view
    if target then UIManager:close(target) end
    self._store_view = nil
end

-- Tab bar switching while a store page is open.
function M:onStoreTabSwitch(mode, view)
    if mode == "store" then return end
    if mode == "books" then
        self:closeStoreView(view)
        self:showShelfView("books")
        return
    end
    self:closeStoreView(view)
    self:showWeChatArticlesPage(mp_mode(mode), nil)
end

function M:onStoreRowSelected(row, view)
    if type(row) ~= "table" then return end
    if row.kind == "action" then
        if row.action == "search" then
            self:showStoreSearch(view)
        elseif row.action == "categories" then
            self:showStoreCategories(view)
        end
    elseif row.kind == "book" then
        self:showStoreBookRecord(row.book, view)
    elseif row.kind == "category" or row.kind == "topic" then
        self:openStoreCategory(row.category or row.topic, view)
    elseif row.kind == "heading" then
        return
    elseif row.kind == "more" then
        self:openStoreCategory(row.section, view, { list_only = true })
    end
end

-- Books related to the open one (GET /book/similar).
function M:showSimilarBooks(book, old_view)
    if not self:requireLogin(true, true) then return end
    local book_id = tostring(book.book_id or "")
    if book_id == "" then return end
    if old_view then UIManager:close(old_view) end
    local throttle_key = "similar:" .. tostring(book_id)
    if self:storeFetchBlocked(throttle_key) then return end
    self:storeFetchBegin(throttle_key)
    self:showBusy(_("Loading related books..."))
    self:runOnlineTask(_("Related books"), function()
        local ok, result = pcall(function()
            return self.client:book_similar(book_id, 20)
        end)
        self:closeBusy()
        self:storeFetchEnd(throttle_key)
        if not ok then
            logger.err("similar books failed:", log_error(result))
            self:showInfo(T(_("Load related books failed:\n%1"), display_error(result)))
            return
        end
        local parsed = Store.books(type(result) == "table" and result.books or {})
        if #parsed == 0 then
            self:showInfo(_("No related books."))
            return
        end
        local rows = {}
        for _i, entry in ipairs(parsed) do
            rows[#rows + 1] = { kind = "book", book = entry }
        end
        self:renderStoreRows(rows, T(_("Related to %1"), book.title or book_id), "store", {
            on_refresh = function() self:showSimilarBooks(book, nil) end,
        })
    end)
end

-- ---------- category browsing ----------

function M:showStoreCategories(old_view)
    if not self:requireLogin(true, true) then return end
    if self._store_category_tree then
        if old_view then UIManager:close(old_view) end
        self:renderCategoryTree()
        return
    end
    if self:storeFetchBlocked("categories") then return end
    self:storeFetchBegin("categories")
    self:showBusy(_("Loading categories..."))
    self:runOnlineTask(_("Categories"), function()
        local ok, result = pcall(function()
            return self.client:category_list()
        end)
        self:closeBusy()
        self:storeFetchEnd("categories")
        if not ok then
            logger.err("category list failed:", log_error(result))
            self:showInfo(T(_("Load categories failed:\n%1"), display_error(result)))
            return
        end
        self._store_category_tree = Store.category_list(result)
        if old_view then UIManager:close(old_view) end
        self:renderCategoryTree()
    end)
end

function M:renderCategoryTree()
    local rows = {}
    for _i, category in ipairs(self._store_category_tree or {}) do
        rows[#rows + 1] = { kind = "category", category = category }
    end
    self:renderStoreRows(rows, _("Categories"), "store", {
        on_refresh = function()
            self._store_category_tree = nil
            self:showStoreView()
        end,
    })
end

-- `entry` is either a category tile from a feed (has category_id + title) or a
-- whole feed section ("more" row: list its books directly).
function M:openStoreCategory(entry, old_view, options)
    options = options or {}
    if not entry then return end
    if options.list_only then
        local rows = {}
        for index, book in ipairs(entry.books or {}) do
            if index > HOME_PAGE_SIZE * 3 then break end
            rows[#rows + 1] = { kind = "book", book = book }
        end
        self:renderStoreRows(rows, section_title(entry), "store")
        return
    end
    local category_id = tostring(entry.category_id or "")
    if category_id == "" then return end
    if old_view then UIManager:close(old_view) end
    self:showCategoryBooks(category_id, entry.title, nil, 1)
end

function M:showCategoryBooks(category_id, title, old_view, page)
    if not self:requireLogin(true, true) then return end
    page = tonumber(page) or 1
    local throttle_key = "category:" .. tostring(category_id) .. ":" .. tostring(page)
    if self:storeFetchBlocked(throttle_key) then return end
    self:storeFetchBegin(throttle_key)
    self:showBusy(T(_("Loading %1..."), title or _("category")))
    self:runOnlineTask(_("Category"), function()
        local ok, result = pcall(function()
            return self.client:store_category_books(category_id, HOME_PAGE_SIZE)
        end)
        self:closeBusy()
        self:storeFetchEnd(throttle_key)
        if not ok then
            logger.err("category books failed:", log_error(result))
            self:showInfo(T(_("Load category failed:\n%1"), display_error(result)))
            return
        end
        local parsed = Store.category_books(result)
        if self._store_category_cache and self._store_category_cache.id == category_id then
            for _i, book in ipairs(parsed.books) do
                self._store_category_cache.books[#self._store_category_cache.books + 1] = book
            end
            self._store_category_cache.has_more = parsed.has_more
            self._store_category_cache.max_idx = parsed.max_idx
        else
            self._store_category_cache = {
                id = category_id,
                title = title,
                books = parsed.books,
                has_more = parsed.has_more,
                max_idx = parsed.max_idx,
                loaded_pages = 1,
            }
        end
        local cache = self._store_category_cache
        cache.loaded_pages = math.max(cache.loaded_pages or 1, page)
        cache.title = title or cache.title
        if old_view then UIManager:close(old_view) end
        self:renderCategoryBooks()
    end)
end

function M:renderCategoryBooks()
    local cache = self._store_category_cache
    if not cache then return end
    local rows = {}
    for _i, book in ipairs(cache.books) do
        rows[#rows + 1] = { kind = "book", book = book }
    end
    if cache.has_more then
        rows[#rows + 1] = { kind = "load_more", label = _("Load more") }
    end
    local view
    view = LibraryView.show({
        mode = "store",
        title = cache.title or _("Category"),
        rows = rows,
        paged = true,
        page = cache.loaded_pages or 1,
        page_size = HOME_PAGE_SIZE,
    }, {
        on_switch = function(new_mode) self:onStoreTabSwitch(new_mode, view) end,
        on_refresh = function()
            self._store_category_cache = nil
            self:showStoreView()
        end,
        on_select = function(row)
            if row.kind == "load_more" then
                self:showCategoryBooks(cache.id, cache.title, view,
                    (cache.loaded_pages or 1) + 1)
                return
            end
            self:onStoreRowSelected(row, view)
        end,
        on_page_changed = function(new_page)
            cache.loaded_pages = new_page
            if new_page > (cache.pages_loaded or 0) then
                cache.pages_loaded = new_page
            end
            self:renderCategoryBooks()
        end,
    })
    self._store_view = view
    self._store_mode = "store"
end

-- ---------- search ----------

function M:showStoreSearch(old_view, keyword)
    if not self:requireLogin(true, true) then return end
    if keyword and keyword ~= "" then
        if old_view then UIManager:close(old_view) end
        self:searchStore(keyword, nil, 1)
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search WeRead"),
        input = "",
        input_type = "text",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local value = dialog:getInputText()
                    UIManager:close(dialog)
                    if value and value ~= "" then
                        if old_view then UIManager:close(old_view) end
                        self:searchStore(value, nil, 1)
                    end
                end,
            },
        }},
    }
    self:showInputDialog(dialog)
end

function M:searchStore(keyword, old_view, page)
    page = tonumber(page) or 1
    local throttle_key = "search:" .. tostring(keyword) .. ":" .. tostring(page)
    if self:storeFetchBlocked(throttle_key) then return end
    self:storeFetchBegin(throttle_key)
    self:showBusy(T(_("Searching %1..."), keyword))
    self:runOnlineTask(_("Search"), function()
        local ok, result = pcall(function()
            return self.client:search_store(keyword, 10, (page - 1) * 10)
        end)
        self:closeBusy()
        self:storeFetchEnd(throttle_key)
        if not ok then
            logger.err("store search failed:", log_error(result))
            self:showInfo(T(_("Search failed:\n%1"), display_error(result)))
            return
        end
        local parsed = Store.search_result(result)
        if self._store_search and self._store_search.keyword == keyword and page > 1 then
            for _i, book in ipairs(parsed.books) do
                self._store_search.books[#self._store_search.books + 1] = book
            end
        else
            self._store_search = {
                keyword = keyword,
                books = parsed.books,
                has_more = parsed.has_more,
                correction = parsed.correction,
                pages = 1,
            }
        end
        local state = self._store_search
        state.pages = math.max(state.pages or 1, page)
        state.has_more = parsed.has_more
        if old_view then UIManager:close(old_view) end
        self:renderSearchResults()
    end)
end

function M:renderSearchResults()
    local state = self._store_search
    if not state then return end
    local rows = {}
    if state.correction and (state.pages or 1) == 1 then
        rows[#rows + 1] = {
            kind = "heading",
            text = T(_("Showing results for \"%1\""), state.correction),
        }
    end
    for _i, book in ipairs(state.books) do
        rows[#rows + 1] = { kind = "book", book = book }
    end
    if state.has_more then
        rows[#rows + 1] = { kind = "load_more", label = _("Load more") }
    end
    local view
    view = LibraryView.show({
        mode = "store",
        title = T(_("Search: %1"), state.keyword),
        rows = rows,
        paged = true,
        page = state.pages or 1,
        page_size = 10,
    }, {
        on_switch = function(new_mode) self:onStoreTabSwitch(new_mode, view) end,
        on_refresh = function() self:searchStore(state.keyword, nil, 1) end,
        on_select = function(row)
            if row.kind == "load_more" then
                self:searchStore(state.keyword, view, (state.pages or 1) + 1)
                return
            end
            if row.kind == "heading" then return end
            self:onStoreRowSelected(row, view)
        end,
        on_page_changed = function(new_page)
            state.pages = new_page
            self:renderSearchResults()
        end,
    })
    self._store_view = view
    self._store_mode = "store"
end

-- ---------- book record ----------

function M:showStoreBookRecord(book, old_view)
    if type(book) ~= "table" then return end
    if old_view then UIManager:close(old_view) end
    local book_id = tostring(book.book_id or "")
    if book_id == "" then return end
    local cached = self.settings:get("books", {})[book_id]
    local known = cached and cached._shelf_member
    self:_showStoreBookDetail(book, known, nil)
end

-- One shared detail sheet for store rows. `shelf_member` is nil while unknown
-- (the check runs in the background), true/false once resolved.
function M:_showStoreBookDetail(book, shelf_member, old_view)
    local BookDetailView = require("weink.ui.book_detail_view")
    if old_view then UIManager:close(old_view) end
    local book_id = tostring(book.book_id or "")
    local view
    local function redraw(new_member)
        self:_showStoreBookDetail(book, new_member, view)
    end

    local availability = Store.availability(book)
    local metadata = {}
    if book.publisher and book.publisher ~= "" then
        metadata[#metadata + 1] = { text = T(_("Publisher: %1"), book.publisher) }
    end
    local price = Store.price_label(book)
    if price ~= "" then
        metadata[#metadata + 1] = { text = T(_("Price: %1"), price) }
    end
    if book.rating and book.rating > 0 then
        metadata[#metadata + 1] = {
            text = T(_("Rating: %1 (%2 ratings)"),
                string.format("%.1f", book.rating / 100), tostring(book.rating_count or 0)),
        }
    end
    if book.word_count and book.word_count > 0 then
        metadata[#metadata + 1] = {
            text = T(_("Word count: %1"), tostring(book.word_count)),
        }
    end
    if book.category and book.category ~= "" then
        metadata[#metadata + 1] = { text = T(_("Category: %1"), book.category) }
    end

    local statuses = {}
    if availability.label and availability.label ~= "" then
        statuses[#statuses + 1] = availability.label
    end
    if book.paid then
        statuses[#statuses + 1] = _("Purchased")
    end
    if book.max_free_chapter and book.max_free_chapter > 0 and not book.paid then
        statuses[#statuses + 1] = T(_("Free up to chapter %1"), tostring(book.max_free_chapter))
    end

    if shelf_member == nil then
        statuses[#statuses + 1] = _("Checking bookshelf...")
        self:checkShelfMember(book_id, function(is_member)
            redraw(is_member)
        end)
    elseif shelf_member then
        statuses[#statuses + 1] = _("In bookshelf")
    else
        statuses[#statuses + 1] = _("Not in bookshelf")
    end

    local actions = {
        {
            text = _("Related books"),
            callback = function()
                self:showSimilarBooks(book, view)
            end,
        },
    }
    if shelf_member == true then
        actions[#actions + 1] = {
            text = _("Remove from bookshelf"),
            callback = function()
                self:confirmShelfRemove(book, function(ok) if ok then redraw(false) end end)
            end,
        }
    elseif shelf_member == false then
        actions[#actions + 1] = {
            text = _("Add to bookshelf"),
            bold = true,
            callback = function()
                self:addToShelf(book, function(ok) if ok then redraw(true) end end)
            end,
        }
    end

    local bottom = {
        {
            text = _("⇩ Download"),
            enabled = availability.downloadable ~= false,
            callback = function()
                if availability.downloadable == false then
                    self:showInfo(availability.trial_hint or _(
                        "This book can only be read after purchase. Buy it in the WeRead phone app."))
                    return
                end
                self:confirmStoreDownload(book)
            end,
        },
        {
            text = _("▤ Details"),
            enabled = false,
        },
    }
    actions[#actions + 1] = {
        text = _("Book information"),
        callback = function()
            self:showBookRecord(book)
        end,
    }

    view = BookDetailView.show({
        title = book.title or _("Untitled"),
        author_line = book.author or "",
        status_line = table.concat(statuses, "  ·  "),
        refresh_label = _("↻ Get latest information"),
        refresh_date = _("Never updated"),
        metadata = metadata,
        intro = book.intro,
        actions = actions,
        bottom_actions = bottom,
    }, {
        on_refresh = function()
            self:refreshStoreBook(book, function() redraw(shelf_member) end)
        end,
    })
    self._book_detail_view = view
    return view
end

function M:refreshStoreBook(book, callback)
    if not self:requireLogin(true, true) then return end
    self:showBusy(_("Loading book info..."))
    self:runOnlineTask(_("Book info"), function()
        local ok, info = pcall(function()
            return self.client:get_book_info(book.book_id)
        end)
        self:closeBusy()
        if not ok then
            logger.err("store book info failed:", log_error(info))
            self:showInfo(T(_("Load book info failed:\n%1"), display_error(info)))
            return
        end
        local updated = Store.book(info)
        if updated then
            for key, value in pairs(updated) do book[key] = value end
        end
        if callback then callback(updated) end
    end)
end

-- ---------- shelf membership ----------

function M:checkShelfMember(book_id, callback)
    book_id = tostring(book_id or "")
    if book_id == "" then
        if callback then callback(nil) end
        return
    end
    local cache = self._shelf_member_cache
    if cache and cache[book_id] ~= nil then
        if callback then callback(cache[book_id]) end
        return
    end
    self:runOnlineTask(_("Bookshelf"), function()
        local ok, result = pcall(function()
            return self.client:get_shelf()
        end)
        if not ok then
            if callback then callback(nil) end
            return
        end
        local members = {}
        for _i, item in ipairs((type(result) == "table" and result.books) or {}) do
            members[tostring(item.bookId or item.book_id or "")] = true
        end
        self._shelf_member_cache = members
        if callback then callback(members[book_id] == true) end
    end)
end

function M:addToShelf(book, callback)
    if not self:requireLogin(true, true) then return end
    local book_id = tostring(book.book_id or "")
    if book_id == "" then return end
    local throttle_key = "shelf:add:" .. tostring(book_id)
    if self:storeFetchBlocked(throttle_key) then return end
    self:storeFetchBegin(throttle_key)
    self:showBusy(_("Adding to bookshelf..."))
    self:runOnlineTask(_("Add to bookshelf"), function()
        local ok, result = pcall(function()
            return self.client:eink_shelf_add({ book_id })
        end)
        self:closeBusy()
        self:storeFetchEnd(throttle_key)
        if not ok then
            logger.err("shelf add failed:", log_error(result))
            self:showInfo(T(_("Add to bookshelf failed:\n%1"), display_error(result)))
            return
        end
        if self._shelf_member_cache then self._shelf_member_cache[book_id] = true end
        self:showTransientInfo(T(_("\"%1\" added to bookshelf"), book.title or book_id), 2)
        self:invalidateShelfSnapshot()
        self:verifyShelfMember(book_id, true)
        if callback then callback(true) end
    end)
end

function M:confirmShelfRemove(book, callback)
    local book_id = tostring(book.book_id or "")
    if book_id == "" then return end
    local dialog
    dialog = ConfirmBox:new{
        text = T(_("Remove \"%1\" from the WeRead bookshelf?\n\nDownloaded files on this device are kept."),
            book.title or book_id),
        ok_text = _("Remove"),
        ok_callback = function()
            UIManager:close(dialog)
            self:removeFromShelf(book, callback)
        end,
    }
    UIManager:show(dialog)
end

function M:removeFromShelf(book, callback)
    local book_id = tostring(book.book_id or "")
    local throttle_key = "shelf:del:" .. tostring(book_id)
    if self:storeFetchBlocked(throttle_key) then return end
    self:storeFetchBegin(throttle_key)
    self:showBusy(_("Removing from bookshelf..."))
    self:runOnlineTask(_("Remove from bookshelf"), function()
        local ok, result = pcall(function()
            return self.client:eink_shelf_delete({ book_id })
        end)
        self:closeBusy()
        self:storeFetchEnd(throttle_key)
        if not ok then
            logger.err("shelf delete failed:", log_error(result))
            self:showInfo(T(_("Remove from bookshelf failed:\n%1"), display_error(result)))
            return
        end
        if self._shelf_member_cache then self._shelf_member_cache[book_id] = false end
        self:showTransientInfo(T(_("\"%1\" removed from bookshelf"), book.title or book_id), 2)
        self:invalidateShelfSnapshot()
        self:verifyShelfMember(book_id, false)
        if callback then callback(true) end
    end)
end

-- Shelf writes land within ~1s but not synchronously. Re-read once shortly
-- after the write: a bare {"succ":1} ack is not proof (the singular `bookId`
-- key returns exactly that while changing nothing), so the UI state is only
-- trusted after the server agrees.
function M:verifyShelfMember(book_id, want_member, attempt)
    attempt = tonumber(attempt) or 1
    if attempt > 4 then
        logger.warn("shelf write not visible yet:", book_id, tostring(want_member))
        return
    end
    UIManager:scheduleIn(1.0, function()
        local ok, result = pcall(function()
            return self.client:get_shelf()
        end)
        if not ok then
            self:verifyShelfMember(book_id, want_member, attempt + 1)
            return
        end
        local found = false
        for _j, item in ipairs((type(result) == "table" and result.books) or {}) do
            if tostring(item.bookId or item.book_id or "") == book_id then
                found = true
                break
            end
        end
        if found == want_member then
            if self._shelf_member_cache then
                self._shelf_member_cache[book_id] = want_member
            end
            return
        end
        self:verifyShelfMember(book_id, want_member, attempt + 1)
    end)
end

-- A shelf write invalidates the cached bookshelf so the 书籍 tab shows it.
function M:invalidateShelfSnapshot()
    self._shelf_member_cache = nil
    if self.library_db then
        pcall(function() self.library_db:cacheShelf(nil) end)
    end
    self._shelf_snapshot_stale = true
end

function M:confirmStoreDownload(book)
    local dialog
    dialog = ConfirmBox:new{
        text = T(_("Download \"%1\" to this device?\n\nThe full book download can take a while."),
            book.title or book.book_id),
        ok_text = _("Download"),
        ok_callback = function()
            UIManager:close(dialog)
            self:showBookRecord(book)
        end,
    }
    UIManager:show(dialog)
end

return M
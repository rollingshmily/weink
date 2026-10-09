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

local STORE_TITLE = _("WeRead Store")

-- Store requests are tap-driven, so the only thing to defend against is a
-- double tap or a re-entrant open while the first call is still in flight.
local STORE_MIN_INTERVAL_SECONDS = 1.0
local STORE_INFLIGHT_TTL_SECONDS = 15
-- Re-reading the same book (or the shelf) on every detail open made a slow link
-- feel stuck; both are cached for a while instead.
local BOOK_INFO_TTL_SECONDS = 600
local SHELF_CACHE_TTL_SECONDS = 120

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

-- ------------------------------------------------------------- navigation
--
-- The storefront lives in the same persistent full-screen view as the
-- bookshelf (self.shelf_view). Levels are frames on self._store_nav, and every
-- move re-renders that one widget in place (LibraryView:apply). Closing and
-- re-showing a full-screen widget makes e-ink repaint the whole screen, which
-- flashes and briefly exposes the FileManager underneath.
function M:storeNav()
    self._store_nav = self._store_nav or {}
    return self._store_nav
end

function M:storeTop()
    local nav = self:storeNav()
    return nav[#nav]
end

function M:storeCoverLayout()
    if self._store_cover_layout ~= nil then return self._store_cover_layout end
    local ok, layout = pcall(function()
        local CoverLayout = require("weink.lib.cover_layout")
        local Screen = require("device").screen
        local scaled = tonumber(Screen:scaleBySize(1000))
        local size_scale = scaled and scaled > 0 and scaled / 1000 or 1
        return CoverLayout.calculate{
            width = Screen:getWidth(),
            height = Screen:getHeight(),
            size_scale = size_scale,
        }
    end)
    if not ok or type(layout) ~= "table" then
        self._store_cover_layout = false
        return false
    end
    self._store_cover_layout = layout
    return layout
end

function M:storeCollectCovers(rows)
    local paths, loading, missing = {}, {}, {}
    local ok, cache = pcall(function() return self:getShelfCoverCache() end)
    if not ok or not cache then
        self._store_cover_paths = paths
        self._store_cover_loading = loading
        return missing
    end
    for _i, row in ipairs(rows or {}) do
        if row.kind == "book" then
            local book = row.book
            local path = cache:pathFor(book)
            if path then
                paths[book] = path
            else
                loading[book] = true
                missing[#missing + 1] = book
            end
        end
    end
    self._store_cover_paths = paths
    self._store_cover_loading = loading
    return missing
end

function M:storeFrameData()
    local state = self:storeTop()
    if not state then return nil end
    local data = {
        mode = "store",
        title = state.title or STORE_TITLE,
        rows = state.rows or {},
        paged = false,
        scroll_offset = state.keep_offset,
        back_label = #self:storeNav() > 1 and _("‹ Back to store") or nil,
    }
    local layout = self:storeCoverLayout()
    if layout then
        data.cover_mode = true
        data.cover_columns = layout.columns
        data.cover_rows = layout.rows
        data.cover_paths = self._store_cover_paths
        data.cover_loading = self._store_cover_loading
    end
    return data
end

function M:storeCallbacks()
    local state = self:storeTop()
    return {
        on_switch = function(mode) self:onStoreTabSwitch(mode) end,
        on_back = function() return self:storeBack() end,
        on_refresh = function() self:storeFrameRefresh(state) end,
        on_search = function() self:showStoreSearch() end,
        on_categories = function() self:showStoreCategories() end,
        on_select = function(row) self:onStoreRowSelected(row) end,
        on_reach_bottom = state and state.on_more or nil,
        on_fill_page = state and state.on_fill or nil,
    }
end

function M:storeDraw()
    local state = self:storeTop()
    if not state then return nil end
    local missing = self:storeCollectCovers(state.rows)
    local data = self:storeFrameData()
    if not data then return nil end
    local view = self.shelf_view
    if not view then
        view = LibraryView.show(data, self:storeCallbacks())
        self.shelf_view = view
    else
        view:apply(data, self:storeCallbacks())
    end
    if #missing > 0 then
        self:fetchStoreCovers(missing, function()
            -- A cover batch may finish after navigation or a tab switch. It
            -- must neither repaint a different page nor reset the live offset.
            if self.shelf_view ~= view or view._closed or view.mode ~= "store"
                or self:storeTop() ~= state then return end
            self:storeCollectCovers(state.rows)
            view:updateCovers(self._store_cover_paths, self._store_cover_loading)
        end)
    end
    return view
end

function M:storePush(state)
    local nav = self:storeNav()
    nav[#nav + 1] = state
    self:storeDraw()
end

function M:storeReplace(state)
    local nav = self:storeNav()
    if #nav == 0 then
        nav[1] = state
    else
        nav[#nav] = state
    end
    self:storeDraw()
end

-- Returns true when it went up a level, so the X can close at the root.
function M:storeBack()
    local nav = self._store_nav
    if not nav or #nav <= 1 then return false end
    table.remove(nav)
    self:storeDraw()
    return true
end

function M:storeFrameRefresh(state)
    if state and state.loader then state.loader() end
end

function M:storeLoadMore()
    local state = self:storeTop()
    if state and state.on_more then state.on_more() end
end

local HOME_PAGE_SIZE = 15
-- Cover wall: two rows of three before the section offers more.
-- Cover wall: three rows of five before the section offers more.
local SECTION_PREVIEW = 15

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
    if old_view then self.shelf_view = old_view end
    if self._store_sections then
        self._store_nav = {}
        self:storePush(self:storeHomeFrame(self:buildStoreRows(self._store_sections)))
        return
    end
    self:storeLoadHome(false)
end

function M:storeHomeFrame(rows)
    return {
        title = _("WeRead Store"),
        rows = rows,
        loader = function() self:storeLoadHome(true) end,
    }
end

function M:storeLoadHome(replace_top)
    if self:storeFetchBlocked("home") then return end
    self:storeFetchBegin("home")
    self:runOnlineTask(_("WeRead Store"), function()
        local ok, result = pcall(function()
            return self.client:store_home()
        end)
        self:storeFetchEnd("home")
        if not ok then
            logger.err("store home failed:", log_error(result))
            self:showInfo(T(_("Load book store failed:\n%1"), display_error(result)))
            return
        end
        self._store_sections = Store.sections(result)
        local frame = self:storeHomeFrame(self:buildStoreRows(self._store_sections))
        if replace_top and #self:storeNav() > 0 then
            self:storeReplace(frame)
        else
            self._store_nav = {}
            self:storePush(frame)
        end
    end)
end

-- Flatten feed sections into display rows: a heading row per section followed
-- by its books (capped) or category tiles.
function M:buildStoreRows(sections)
    local rows = {}
    for _i, section in ipairs(sections) do
        local has_content = #section.books > 0
            or #section.categories > 0
            or #section.topics > 0
        if has_content then
            rows[#rows + 1] = {
                kind = "group",
                text = section_title(section),
                status = #section.books > SECTION_PREVIEW and _("More ›") or "",
                target = #section.books > SECTION_PREVIEW and section or nil,
            }
        end
        for index, book in ipairs(section.books) do
            if index > SECTION_PREVIEW then break end
            rows[#rows + 1] = { kind = "book", book = book }
        end
        for _j, category in ipairs(section.categories) do
            rows[#rows + 1] = { kind = "category", category = category }
        end
        for _j, topic in ipairs(section.topics) do
            rows[#rows + 1] = { kind = "topic", topic = topic }
        end

    end
    return rows
end

-- Rendering is owned by the navigation core (storeDraw).

function M:showStoreView()
    self:storeDraw()
end

function M:closeStoreView()
    self._store_nav = nil
end

-- Tab bar switching while a store page is open.
function M:onStoreTabSwitch(mode)
    if mode == "store" then return end
    local view = self.shelf_view
    self._store_nav = nil
    if mode == "books" then
        self:showShelfView("books", nil, view)
    else
        self:showWeChatArticlesPage(mp_mode(mode), nil, view)
    end
end

function M:onStoreRowSelected(row)
    if type(row) ~= "table" then return end
    if row.kind == "action" then
        if row.action == "search" then
            self:showStoreSearch(row.view)
        elseif row.action == "categories" then
            self:showStoreCategories()
        end
    elseif row.kind == "book" then
        self:showStoreBookRecord(row.book)
    elseif row.kind == "category" or row.kind == "topic" then
        self:openStoreCategory(row.category or row.topic)
    elseif row.kind == "group" then
        if row.target then self:openStoreSection(row.target) end
    elseif row.kind == "section" then
        self:openStoreSection(row.section)
    elseif row.kind == "heading" then
        if row.more and row.section then self:openStoreSection(row.section) end
    end
end

-- Books related to the open one (GET /book/similar).
function M:showSimilarBooks(book)
    if not self:requireLogin(true, true) then return end
    local book_id = tostring(book.book_id or "")
    if book_id == "" then return end
    local key = "similar:" .. book_id
    if self:storeFetchBlocked(key) then return end
    self:storeFetchBegin(key)
    self:runOnlineTask(_("Related books"), function()
        local ok, result = pcall(function()
            return self.client:book_similar(book_id, 20)
        end)
        self:storeFetchEnd(key)
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
        self:storePush({
            title = T(_("Related to %1"), book.title or book_id),
            rows = rows,
        })
    end)
end

-- ---------- category browsing ----------

function M:showStoreCategories()
    if not self:requireLogin(true, true) then return end
    if self._store_category_raw then
        self:mountCategoryTree(false)
        return
    end
    self:storeLoadCategories(false)
end

function M:storeLoadCategories(replace_top)
    if self:storeFetchBlocked("categories") then return end
    self:storeFetchBegin("categories")
    self:runOnlineTask(_("Categories"), function()
        local ok, result = pcall(function()
            return self.client:category_list()
        end)
        self:storeFetchEnd("categories")
        if not ok then
            logger.err("category list failed:", log_error(result))
            self:showInfo(T(_("Load categories failed:\n%1"), display_error(result)))
            return
        end
        self._store_category_raw = result
        self:mountCategoryTree(replace_top)
    end)
end

function M:mountCategoryTree(replace_top)
    local rows = {}
    local groups = Store.category_groups(self._store_category_raw or {})
    for _i, group in ipairs(groups) do
        if #group.children == 0 then
            rows[#rows + 1] = { kind = "category", category = group }
        else
            rows[#rows + 1] = {
                kind = "group",
                text = group.title,
                status = T(_("%1 categories"), tostring(#group.children)),
            }
            for _j, child in ipairs(group.children) do
                rows[#rows + 1] = { kind = "category", category = child }
            end
        end
    end
    if #rows == 0 then
        for _i, category in ipairs(Store.category_list(self._store_category_raw or {})) do
            rows[#rows + 1] = { kind = "category", category = category }
        end
    end
    local frame = {
        title = _("All categories"),
        rows = rows,
        loader = function()
            self._store_category_raw = nil
            self:storeLoadCategories(true)
        end,
    }
    if replace_top then self:storeReplace(frame) else self:storePush(frame) end
end

-- Category rendering is owned by mountCategoryTree.

-- `entry` is either a category tile from a feed (has category_id + title) or a
-- whole feed section ("more" row: list its books directly).
-- A feed category tile, a topic, or a ranking tile that carries no id.
function M:openStoreCategory(entry)
    if type(entry) ~= "table" then return end
    local category_id = tostring(entry.category_id or "")
    if category_id ~= "" then
        self:openCategoryBooks(category_id, entry.title)
        return
    end
    -- Ranking tiles (/store/list type=12) carry their top books but no
    -- category id, so show those books instead of a dead end.
    local rows = {}
    for _i, book in ipairs(entry.books or {}) do
        rows[#rows + 1] = { kind = "book", book = book }
    end
    if #rows == 0 then return end
    self:storePush({ title = entry.title or _("Ranking"), rows = rows })
end

-- Whole section: the "see all" row at the end of a home feed block.
function M:openStoreSection(section)
    if type(section) ~= "table" then return end
    local rows = {}
    for _i, book in ipairs(section.books or {}) do
        rows[#rows + 1] = { kind = "book", book = book }
    end
    if #rows == 0 then return end
    self:storePush({ title = section_title(section), rows = rows })
end

function M:openCategoryBooks(category_id, title)
    category_id = tostring(category_id or "")
    if category_id == "" then return end
    self._store_category_books = {
        id = category_id,
        title = title,
        books = {},
        has_more = false,
    }
    self:storeLoadCategoryBooks(false)
end

function M:storeLoadCategoryBooks(replace_top)
    local cache = self._store_category_books
    if not cache then return end
    local max_idx = #cache.books
    local key = "category:" .. cache.id .. ":" .. tostring(max_idx)
    if self:storeFetchBlocked(key) then return end
    self:storeFetchBegin(key)
    self:runOnlineTask(_("Category"), function()
        local ok, result = pcall(function()
            return self.client:store_category_books(cache.id, HOME_PAGE_SIZE, max_idx)
        end)
        self:storeFetchEnd(key)
        if not ok then
            logger.err("category books failed:", log_error(result))
            self:showInfo(T(_("Load category failed:\n%1"), display_error(result)))
            return
        end
        local parsed = Store.category_books(result)
        for _i, book in ipairs(parsed.books) do
            cache.books[#cache.books + 1] = book
        end
        -- A page that adds nothing must not keep the auto-loader firing.
        cache.has_more = parsed.has_more and #parsed.books > 0
        self:mountCategoryBooks(replace_top)
    end)
end

function M:mountCategoryBooks(replace_top)
    local cache = self._store_category_books
    if not cache then return end
    local rows = {}
    for _i, book in ipairs(cache.books) do
        rows[#rows + 1] = { kind = "book", book = book }
    end

    local frame = {
        title = cache.title or _("Category"),
        keep_offset = cache.keep_offset,
        rows = rows,
        loader = function()
            cache.books = {}
            cache.keep_offset = 0
            cache.autofilled = nil
            cache.has_more = false
            self:storeLoadCategoryBooks(true)
        end,
        on_more = cache.has_more and function(offset)
            cache.keep_offset = offset
            self:storeLoadCategoryBooks(true)
        end or nil,
        on_fill = (not cache.autofilled) and cache.has_more and function()
            cache.autofilled = true
            cache.keep_offset = 0
            self:storeLoadCategoryBooks(true)
        end or nil,
    }
    if replace_top then self:storeReplace(frame) else self:storePush(frame) end
end

-- ---------- search ----------

function M:showStoreSearch()
    if not self:requireLogin(true, true) then return end
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
                        self:openStoreSearch(value)
                    end
                end,
            },
        }},
    }
    self:showInputDialog(dialog)
end

function M:openStoreSearch(keyword)
    self._store_search = {
        keyword = keyword,
        books = {},
        has_more = false,
        correction = nil,
    }
    self:storeLoadSearch(false)
end

function M:storeLoadSearch(replace_top)
    local state = self._store_search
    if not state then return end
    local max_idx = #state.books
    local key = "search:" .. state.keyword .. ":" .. tostring(max_idx)
    if self:storeFetchBlocked(key) then return end
    self:storeFetchBegin(key)
    self:runOnlineTask(_("Search"), function()
        local ok, result = pcall(function()
            return self.client:search_store(state.keyword, HOME_PAGE_SIZE, max_idx)
        end)
        self:storeFetchEnd(key)
        if not ok then
            logger.err("store search failed:", log_error(result))
            self:showInfo(T(_("Search failed:\n%1"), display_error(result)))
            return
        end
        local parsed = Store.search_result(result)
        for _i, book in ipairs(parsed.books) do
            state.books[#state.books + 1] = book
        end
        state.has_more = parsed.has_more and #parsed.books > 0
        state.correction = parsed.correction
        self:mountSearch(replace_top)
    end)
end

function M:mountSearch(replace_top)
    local state = self._store_search
    if not state then return end
    local rows = {}
    if state.correction and #state.books <= HOME_PAGE_SIZE then
        rows[#rows + 1] = {
            kind = "heading",
            text = T(_("Showing results for \"%1\""), state.correction),
        }
    end
    for _i, book in ipairs(state.books) do
        rows[#rows + 1] = { kind = "book", book = book }
    end

    local keyword = state.keyword
    local frame = {
        title = T(_("Search: %1"), keyword),
        keep_offset = state.keep_offset,
        rows = rows,
        loader = function()
            state.keep_offset = 0
            self._store_search = { keyword = keyword, books = {}, has_more = false }
            self:storeLoadSearch(true)
        end,
        on_more = state.has_more and function(offset)
            state.keep_offset = offset
            self:storeLoadSearch(true)
        end or nil,
        on_fill = (not state.autofilled) and state.has_more and function()
            state.autofilled = true
            self:storeLoadSearch(true)
        end or nil,
    }
    if replace_top then self:storeReplace(frame) else self:storePush(frame) end
end

-- ---------- book record ----------

function M:showStoreBookRecord(book)
    if type(book) ~= "table" then return end
    if tostring(book.book_id or "") == "" then return end
    self:_showStoreBookDetail(book, nil)
end

-- One shared detail sheet for store rows. `shelf_member` is nil while unknown
-- (the check runs in the background), true/false once resolved.
function M:_showStoreBookDetail(book, shelf_member, old_view)
    local BookDetailView = require("weink.ui.book_detail_view")
    if old_view then UIManager:close(old_view) end
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
    local rank = book.ranklist
    if type(rank) == "table" and tonumber(rank.seq) and tostring(rank.categoryName or "") ~= "" then
        metadata[#metadata + 1] = {
            text = T(_("Rank: #%1 in %2"), tostring(rank.seq), tostring(rank.categoryName)),
        }
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
        self:loadStoreBookState(book, function(is_member)
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

-- One background round for the detail sheet: refresh the book metadata
-- (which is where the ranking position comes from) and resolve shelf
-- membership. The result is a boolean so a failed lookup cannot loop the
-- caller.
function M:loadStoreBookState(book, callback)
    local book_id = tostring(book.book_id or "")
    if book_id == "" then
        if callback then callback(false) end
        return
    end
    self:runOnlineTask(_("Book info"), function()
        local cached = self._store_book_info and self._store_book_info[book_id]
        if not (cached and (now_seconds() - cached.at) < BOOK_INFO_TTL_SECONDS) then
            local ok, info = pcall(function()
                return self.client:get_book_info(book_id)
            end)
            if ok and type(info) == "table" then
                local updated = Store.book(info)
                if updated then
                    for key, value in pairs(updated) do book[key] = value end
                    self._store_book_info = self._store_book_info or {}
                    self._store_book_info[book_id] = { at = now_seconds(), book = updated }
                end
            end
        end
        if callback then callback(self:shelfMemberFrom(book_id)) end
    end)
end

function M:shelfMemberFrom(book_id, force)
    local cache = self._store_shelf_ids
    if force or not (cache and (now_seconds() - cache.at) < SHELF_CACHE_TTL_SECONDS) then
        local ok, shelf = pcall(function()
            return self.client:get_shelf()
        end)
        if not (ok and type(shelf) == "table") then
            return cache and cache.ids[book_id] == true or false
        end
        local ids = {}
        for _i, item in ipairs(shelf.books or {}) do
            ids[tostring(item.bookId or item.book_id or "")] = true
        end
        self._store_shelf_ids = { at = now_seconds(), ids = ids }
        self._shelf_member_cache = ids
    end
    return self._store_shelf_ids.ids[book_id] == true
end

function M:markShelfMember(book_id, member)
    self._store_shelf_ids = self._store_shelf_ids or { at = now_seconds(), ids = {} }
    self._store_shelf_ids.ids[book_id] = member or nil
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
        self:markShelfMember(book_id, true)
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
        self:markShelfMember(book_id, false)
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

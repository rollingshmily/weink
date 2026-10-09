-- Bookshelf, book, chapter, public-account, and search UI flows.
local BookReviews = require("weink.lib.book_reviews")
local BookReviewsView = require("weink.ui.book_reviews_view")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Content = require("weink.lib.content")
local CoverLayout = require("weink.lib.cover_layout")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("weink.lib.logger")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local Protocol = require("weink.lib.protocol")

local PluginUtil = require("weink.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
local log_error = PluginUtil.log_error
local display_error = PluginUtil.display_error
local file_exists = PluginUtil.file_exists

-- 微信文章列表 /mp/list 的 listType（2026-10-07 真机实测）：1 = 微信浮窗，
-- 2 = 文章收藏。旧代码把两者反着对应，这里只保留一份映射，别再各写各的。
local MP_LIST_TYPE_BY_MODE = { favorites = 2, floating = 1 }
local MP_MODE_BY_LIST_TYPE = { [1] = "floating", [2] = "favorites" }

local function mp_list_type(mode)
    return MP_LIST_TYPE_BY_MODE[mode] or 1
end

local function mp_mode(list_type)
    return MP_MODE_BY_LIST_TYPE[tonumber(list_type) or 0] or "floating"
end

local M = {}
local sortBooks

local function cover_subprocess_runner()
    local ok, ffiutil = pcall(require, "ffi/util")
    if not ok or type(ffiutil.runInSubProcess) ~= "function" then return nil end
    return {
        run = function(callback) return ffiutil.runInSubProcess(callback, true) end,
        write_all = function(fd, data) return ffiutil.writeToFD(fd, data, true) end,
        is_done = function(pid) return ffiutil.isSubProcessDone(pid) end,
        terminate = function(pid) return ffiutil.terminateSubProcess(pid) end,
        read_all = function(fd) return ffiutil.readAllFromFD(fd) end,
    }
end

local local_cache_fields = {
    cache_dir = true,
    cached_file = true,
    cached_full_book = true,
    cached_chapters = true,
}

local function keep_local_cache(record)
    local local_record = {}
    for key, value in pairs(record or {}) do
        if local_cache_fields[key] then local_record[key] = value end
    end
    return local_record
end

local function has_book_details(book)
    if type(book) ~= "table" then return false end
    if tonumber(book.detail_updated_at or 0) > 0 then return true end
    for _, key in ipairs({
        "intro", "publisher", "isbn", "wordCount", "newRating",
        "translator", "categoryName", "publishTime",
    }) do
        if book[key] ~= nil and book[key] ~= "" then return true end
    end
    return false
end

local function list_items_per_page()
    local perpage = 14
    if G_reader_settings and G_reader_settings.readSetting then
        perpage = tonumber(G_reader_settings:readSetting("items_per_page")) or perpage
    end
    return math.max(4, perpage)
end

function M:showBookshelf()
    local cached = self.library_db and self.library_db:getShelf() or nil
    if cached and #cached > 0 then
        self:applyShelfSnapshot(cached)
        self:showShelfView("books")
        return
    end
    self:refreshBookshelf()
end

function M:closeWeinkUI()
    -- Close from the topmost view down so no full-screen WeRead widget remains
    -- in UIManager's window stack after a document is opened.
    local seen = {}
    for _, field in ipairs({
        "_chapter_list_view",
        "_book_detail_view",
        "_store_view",
        "shelf_view",
    }) do
        local view = self[field]
        self[field] = nil
        if view and not seen[view] then
            seen[view] = true
            UIManager:close(view)
        end
    end
end

function M:onWeinkAccountChanged()
    if self.progress_sync and self.progress_sync.on_account_changed then
        self.progress_sync:on_account_changed()
    end
    if self.downloader then
        self.downloader:cancelPrefetch("account_changed")
    end
    if self._cancelUnifiedAnnotationSync then
        self:_cancelUnifiedAnnotationSync()
    end
    self:closeWeinkUI()
    self.shelf_regular = nil
    self.shelf_mp = nil
    self.shelf_books = nil
    self.shelf_search_keyword = nil
    self.shelf_view_pages = nil
    self.shelf_cover_pending = nil
    self.shelf_cover_generation = (self.shelf_cover_generation or 0) + 1
    local job = self.shelf_cover_job
    self.shelf_cover_job = nil
    if job and job.pid and self.shelf_cover_subprocess
        and type(self.shelf_cover_subprocess.terminate) == "function" then
        pcall(self.shelf_cover_subprocess.terminate, job.pid)
    end
end

function M:applyShelfSnapshot(all_books)
    local shelf = self.settings:get("shelf")
    self.shelf_filters = { reading = shelf.filter_reading, download = shelf.filter_download }
    self.shelf_regular = {}
    self.shelf_mp = {}
    for _i, book in ipairs(all_books or {}) do
        if Protocol.is_mp_book(book.book_id or book.bookId) then
            table.insert(self.shelf_mp, book)
        else
            table.insert(self.shelf_regular, book)
        end
    end
    self.shelf_books = self.shelf_regular
end

function M:refreshBookshelf(old_view, view_options)
    if not self:requireLogin(false, true) then return end
    self:showBusy(_("Loading bookshelf..."))
    self:runOnlineTask(_("Bookshelf"), function()
        local ok, result = pcall(function()
            return self.client:get_shelf()
        end)
        if not ok then
            self:closeBusy()
            logger.err("load bookshelf failed:", log_error(result))
            self:showInfo(T(
                _("Load bookshelf failed:\n%1\n\nIf other account features still work, use Search to find and download books."),
                display_error(result)
            ))
            return
        end
        local all_books = type(result) == "table"
            and type(result.books) == "table"
            and result.books
            or {}
        local shelf = self.settings:get("shelf")
        self.shelf_filters = { reading = shelf.filter_reading, download = shelf.filter_download }
        self.shelf_regular = {}
        self.shelf_mp = {}
        for _i, book in ipairs(all_books) do
            if Protocol.is_mp_book(book.bookId) then
                table.insert(self.shelf_mp, book)
            else
                table.insert(self.shelf_regular, book)
            end
        end
        if self.library_db then
            self.library_db:cacheShelf(all_books)
        end
        self:applyShelfSnapshot(all_books)
        self:closeBusy()
        if old_view then UIManager:close(old_view) end
        self:showShelfView(
            view_options and view_options.mode or self.shelf_view_mode or "books",
            view_options and view_options.keyword or nil,
            nil,
            view_options
        )
    end)
end

local function shelf_search_match(book, keyword)
    if not keyword or keyword == "" then return true end
    local needle = string.lower(keyword)
    for _, value in ipairs({ book.title, book.author, book.bookId, book.book_id }) do
        if type(value) == "string" and string.find(string.lower(value), needle, 1, true) then
            return true
        end
    end
    return false
end

local function shelf_page_items(items, page, page_size)
    items = type(items) == "table" and items or {}
    page_size = math.max(1, math.floor(tonumber(page_size) or 1))
    local page_count = math.max(1, math.ceil(#items / page_size))
    page = math.max(1, math.min(math.floor(tonumber(page) or 1), page_count))
    local first = (page - 1) * page_size + 1
    local last = math.min(#items, first + page_size - 1)
    local result = {}
    for index = first, last do result[#result + 1] = items[index] end
    return result, page
end

function M:getShelfCoverCache()
    if not self.shelf_cover_cache then
        local CoverCache = require("weink.lib.cover_cache")
        self.shelf_cover_cache = CoverCache:new(self.settings)
    end
    return self.shelf_cover_cache
end

function M:fetchVisibleShelfCovers(view, books, options)
    if not view or not books or #books == 0 then return end
    options = options or {}
    local cache = self:getShelfCoverCache()
    local visible = shelf_page_items(books, view.page, view.page_size or 6)
    local missing = {}
    local online = self:isNetworkOnline()
    for _, book in ipairs(visible) do
        if type(book.cover) == "string" and book.cover:match("^https://")
            and not cache:pathFor(book) then
            -- Legacy full-resolution cache entries can be converted while
            -- offline. A network request is only needed when no source exists.
            if online or cache:sourcePathFor(book) then
                missing[#missing + 1] = book
            end
        end
    end
    if #missing == 0 then return end

    if self.shelf_cover_job then
        -- Keep only the newest visible page while the current child exits.
        self.shelf_cover_pending = { view = view, books = books, options = options }
        return
    end

    local runner = self.shelf_cover_subprocess
    if runner == nil then
        runner = cover_subprocess_runner() or false
        self.shelf_cover_subprocess = runner
    end
    if not runner then
        logger.warn("bookshelf cover background worker is unavailable")
        return
    end

    local generation = self.shelf_cover_generation
    local index, changed = 1, false
    local function finish_batch()
        self.shelf_cover_job = nil
        if changed and generation == self.shelf_cover_generation and self.shelf_view == view then
            local pruned = pcall(cache.prune, cache)
            if not pruned then logger.warn("bookshelf cover cache pruning failed") end
            local next_options = {}
            for key, value in pairs(options) do next_options[key] = value end
            next_options.prepared_shelf = {
                books = books,
            }
            next_options.page = view.page
            next_options.skip_cover_fetch_once = true
            self:showShelfView("books", self.shelf_search_keyword, view, next_options)
        end
        local pending = self.shelf_cover_pending
        self.shelf_cover_pending = nil
        if pending then
            self:fetchVisibleShelfCovers(pending.view, pending.books, pending.options)
        end
    end

    local function fetch_next()
        if generation ~= self.shelf_cover_generation or self.shelf_view ~= view then
            finish_batch()
            return
        end
        local book = missing[index]
        if not book then
            finish_batch()
            return
        end

        local pid, read_fd = runner.run(function(_pid, child_write_fd)
            local ok, path = pcall(cache.thumbnailFromCached, cache, book)
            if not (ok and path) and online then
                local downloaded, data = pcall(function()
                    return self.client:get_binary(book.cover, {
                        timeout = { 8, 12 },
                    })
                end)
                if downloaded then ok, path = pcall(cache.store, cache, book, data) end
            end
            runner.write_all(child_write_fd, ok and path and "ok" or "error")
        end)
        if not pid then
            logger.warn("bookshelf cover background worker failed to start")
            index = index + 1
            UIManager:scheduleIn(0.1, fetch_next)
            return
        end

        local job = { pid = pid, read_fd = read_fd, started_at = os.time() }
        self.shelf_cover_job = job
        local poll
        poll = function()
            if self.shelf_cover_job ~= job then return end
            if not runner.is_done(job.pid) then
                if os.time() - job.started_at > 30 then
                    runner.terminate(job.pid)
                end
                UIManager:scheduleIn(0.15, poll)
                return
            end
            local result = job.read_fd and runner.read_all(job.read_fd) or nil
            job.read_fd = nil
            self.shelf_cover_job = nil
            if result == "ok" and cache:pathFor(book) then
                changed = true
            else
                logger.warn("bookshelf cover background task failed")
            end
            index = index + 1
            fetch_next()
        end
        UIManager:scheduleIn(0.15, poll)
    end
    fetch_next()
end


-- Cover downloads for store pages: same cache and background worker as the
-- shelf, but a store page is unpaged and redraws through the caller.
function M:fetchStoreCovers(books, redraw)
    if not books or #books == 0 then return end
    local cache = self:getShelfCoverCache()
    local online = self:isNetworkOnline()
    local missing = {}
    for _i, book in ipairs(books) do
        if type(book.cover) == "string" and book.cover:match("^https://")
            and not cache:pathFor(book) then
            if online or cache:sourcePathFor(book) then
                missing[#missing + 1] = book
            end
        end
    end
    if #missing == 0 then return end
    if self.store_cover_job then
        self.store_cover_pending = { books = books, redraw = redraw }
        return
    end
    local runner = self.shelf_cover_subprocess
    if runner == nil then
        runner = cover_subprocess_runner() or false
        self.shelf_cover_subprocess = runner
    end
    if not runner then
        logger.warn("store cover background worker is unavailable")
        return
    end
    local index, changed = 1, false
    local function finish_batch()
        self.store_cover_job = nil
        if changed then
            pcall(cache.prune, cache)
        end
        local pending = self.store_cover_pending
        self.store_cover_pending = nil
        if pending then self:fetchStoreCovers(pending.books, pending.redraw) end
    end
    local function fetch_next()
        local book = missing[index]
        if not book then
            finish_batch()
            return
        end
        local pid, read_fd = runner.run(function(_pid, child_write_fd)
            local ok, path = pcall(cache.thumbnailFromCached, cache, book)
            if not (ok and path) and online then
                local downloaded, data = pcall(function()
                    return self.client:get_binary(book.cover, { timeout = { 8, 12 } })
                end)
                if downloaded then ok, path = pcall(cache.store, cache, book, data) end
            end
            runner.write_all(child_write_fd, ok and path and "ok" or "error")
        end)
        if not pid then
            index = index + 1
            UIManager:scheduleIn(0.1, fetch_next)
            return
        end
        local job = { pid = pid, read_fd = read_fd, started_at = os.time() }
        self.store_cover_job = job
        local poll
        poll = function()
            if self.store_cover_job ~= job then return end
            if not runner.is_done(job.pid) then
                if os.time() - job.started_at > 30 then runner.terminate(job.pid) end
                UIManager:scheduleIn(0.15, poll)
                return
            end
            local result = job.read_fd and runner.read_all(job.read_fd) or nil
            job.read_fd = nil
            self.store_cover_job = nil
            if result == "ok" and cache:pathFor(book) then
                changed = true
                -- The view updates only changed cells and keeps its viewport.
                -- Show each completed cover rather than waiting for every
                -- download in a slow batch to finish.
                if redraw then redraw() end
            end
            index = index + 1
            fetch_next()
        end
        UIManager:scheduleIn(0.15, poll)
    end
    fetch_next()
end
function M:showShelfView(mode, keyword, old_view, options)
    local LibraryView = require("weink.ui.library_view")
    options = options or {}
    mode = mode or "books"
    options.mode = mode
    options.keyword = keyword
    local skip_cover_fetch_once = options.skip_cover_fetch_once == true
    options.skip_cover_fetch_once = nil
    self.shelf_cover_generation = (self.shelf_cover_generation or 0) + 1
    self.shelf_view_mode = mode
    self.shelf_search_keyword = keyword
    self.shelf_view_pages = self.shelf_view_pages or { books = 1, favorites = 1, floating = 1 }
    local saved_books = self.settings:get("books", {})
    local downloaded_cache = {}
    local function filtered(source, with_download_state)
        local result = {}
        local sorted = sortBooks(source or {}, self.settings:get("shelf").sort_order)
        for _i, book in ipairs(sorted) do
            local matches_filters = not with_download_state
                or self:bookMatchesFilters(book, saved_books, downloaded_cache)
            if matches_filters and shelf_search_match(book, keyword) then
                if with_download_state then
                    book._cached = self:isBookDownloaded(book, saved_books, downloaded_cache)
                end
                result[#result + 1] = book
            end
        end
        return result
    end
    local prepared = options.prepared_shelf
    local books = prepared and prepared.books or filtered(self.shelf_regular, true)
    local shelf_settings = self.settings:get("shelf")
    local cover_mode = mode == "books" and shelf_settings.view_mode == "cover"
    local paged = cover_mode or shelf_settings.paginated ~= false
    local page = paged and (options.page or self.shelf_view_pages[mode] or 1) or 1
    local cover_layout
    if cover_mode then
        local Screen = require("device").screen
        local scaled_size = tonumber(Screen:scaleBySize(1000))
        local size_scale = scaled_size and scaled_size > 0 and scaled_size / 1000 or 1
        cover_layout = CoverLayout.calculate{
            width = Screen:getWidth(),
            height = Screen:getHeight(),
            size_scale = size_scale,
        }
    end
    local page_size = cover_layout and cover_layout.page_size
        or math.max(4, list_items_per_page() - 4)
    local cover_paths, cover_loading
    if cover_mode then
        cover_paths = {}
        cover_loading = {}
        local cache = self:getShelfCoverCache()
        local online = self:isNetworkOnline()
        local visible, clamped_page = shelf_page_items(books, page, page_size)
        page = clamped_page
        for _, book in ipairs(visible) do
            local path = cache:pathFor(book)
            cover_paths[book] = path
            if not path and type(book.cover) == "string" and book.cover:match("^https://") then
                cover_loading[book] = online or cache:sourcePathFor(book) ~= nil
            end
        end
    end
    if old_view then UIManager:close(old_view) end
    local view
    view = LibraryView.show({
        mode = mode,
        title = options.title,
        wp_enable = options.wp_enable,
        books = books,
        keyword = keyword,
        sort_label = self:shelfSortSummary(),
        filter_label = self:shelfFilterSummary(),
        paged = paged,
        page = page,
        page_size = page_size,
        cover_mode = cover_mode,
        cover_columns = cover_layout and cover_layout.columns,
        cover_rows = cover_layout and cover_layout.rows,
        cover_cell_height = cover_layout and cover_layout.cell_height,
        cover_paths = cover_paths,
        cover_loading = cover_loading,
    }, {
        on_switch = function(new_mode)
            if new_mode == "store" then
                self:showStoreHome(view)
                return
            end
            if new_mode == "favorites" or new_mode == "floating" then
                self:showWeChatArticlesPage(mp_list_type(new_mode), nil, view)
                return
            end
            local next_options = {}
            for key, value in pairs(options) do next_options[key] = value end
            next_options.prepared_shelf = { books = books }
            next_options.page = self.shelf_view_pages[new_mode] or 1
            self:showShelfView(new_mode, keyword, view, next_options)
        end,
        on_search = function()
            self:showShelfSearchDialog(view, mode, keyword, options)
        end,
        on_refresh = function()
            self.shelf_view_pages = { books = 1, favorites = 1, floating = 1 }
            local refresh_options = {}
            for key, value in pairs(options) do refresh_options[key] = value end
            refresh_options.prepared_shelf = nil
            refresh_options.page = 1
            self:refreshBookshelf(view, refresh_options)
        end,
        on_sort = function()
            self:showShelfSortOptions(function()
                self.shelf_view_pages = { books = 1, favorites = 1, floating = 1 }
                options.prepared_shelf = nil
                options.page = 1
                self:showShelfView(mode, keyword, view, options)
            end)
        end,
        on_filter = function()
            self:showShelfFilterOptions(function()
                self.shelf_view_pages = { books = 1, favorites = 1, floating = 1 }
                options.prepared_shelf = nil
                options.page = 1
                self:showShelfView(mode, keyword, view, options)
            end)
        end,
        on_select = function(book, selected_mode)
            if options.on_select then
                options.on_select(book, selected_mode, view)
            else
                self:showBookRecord(book)
            end
        end,
        on_page_changed = function(new_page)
            self.shelf_view_pages[mode] = new_page
            local next_options = {}
            for key, value in pairs(options) do next_options[key] = value end
            next_options.prepared_shelf = { books = books }
            next_options.page = new_page
            self:showShelfView(mode, keyword, view, next_options)
        end,
    })
    if paged then self.shelf_view_pages[mode] = view.page end
    self.shelf_view = view
    if cover_mode and not skip_cover_fetch_once then
        local fetch_options = {}
        for key, value in pairs(options) do fetch_options[key] = value end
        self:fetchVisibleShelfCovers(view, books, fetch_options)
    end
end

function M:showShelfSearchDialog(view, mode, keyword, options)
    local dialog
    dialog = InputDialog:new{
        title = _("Search shelf"),
        input = keyword or "",
        input_type = "text",
        buttons = {{
            {
                text = _("Clear"),
                callback = self:safeCallback(_("Clear"), function()
                    UIManager:close(dialog)
                    self.shelf_view_pages = { books = 1, favorites = 1, floating = 1 }
                    options.prepared_shelf = nil
                    options.page = 1
                    self:showShelfView(mode, nil, view, options)
                end),
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = self:safeCallback(_("Search"), function()
                    local value = dialog:getInputText()
                    UIManager:close(dialog)
                    self.shelf_view_pages = { books = 1, favorites = 1, floating = 1 }
                    options.prepared_shelf = nil
                    options.page = 1
                    self:showShelfView(
                        mode, value ~= "" and value or nil, view, options
                    )
                end),
            },
        }},
    }
    self:showInputDialog(dialog)
end

sortBooks = function(books, sort_order)
    if sort_order == "default" or not sort_order then
        return books
    end
    local sorted = {}
    for i, book in ipairs(books) do
        sorted[i] = book
    end
    if sort_order == "time_desc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) > (b.readUpdateTime or 0)
        end)
    elseif sort_order == "time_asc" then
        table.sort(sorted, function(a, b)
            return (a.readUpdateTime or 0) < (b.readUpdateTime or 0)
        end)
    elseif sort_order == "name_asc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
    elseif sort_order == "name_desc" then
        table.sort(sorted, function(a, b)
            return (a.title or "") > (b.title or "")
        end)
    end
    return sorted
end

function M:refreshShelfCacheIndicators()
    self._shelf_saved_books = self.settings:get("books", {})
    if self.shelf_menu and self._shelf_refresh then
        local ok, err = pcall(self._shelf_refresh)
        if not ok then
            logger.warn("refresh shelf cache indicators failed:", log_error(err))
        end
    end
end

function M:showBookRecord(book)
    local books = self.settings:get("books", {})
    local book_id = book.book_id or book.bookId
    if not book_id then return end

    local account_key = self.library_db and self.library_db:accountKey() or nil
    local saved = books[book_id] or {}
    if account_key and saved._library_account_key
        and saved._library_account_key ~= account_key then
        saved = keep_local_cache(saved)
    end
    local cached = self.library_db and self.library_db:getBook(book_id) or nil
    for key, value in pairs(cached or {}) do
        if saved[key] == nil then saved[key] = value end
    end
    for key, value in pairs(book) do
        if value ~= nil and key ~= "_cached" then saved[key] = value end
    end
    saved.book_id = book_id
    saved._library_account_key = account_key
    saved.updated_at = saved.updated_at or os.time()
    books[book_id] = saved
    self.settings:set("books", books)
    self.settings:flush()
    if self.library_db then self.library_db:putBook(saved) end
    if type(saved.chapters) ~= "table" and self.library_db then
        saved.chapters = self.library_db:getChapters(book_id)
    end
    if not has_book_details(cached) then
        self:refreshBookRecord(saved, nil, { automatic = true })
    else
        self:showBookMenu(saved)
    end
end

function M:refreshBookRecord(book, old_view, options)
    options = options or {}
    if not self:requireLogin(false, true) then
        if options.automatic then self:showBookMenu(book) end
        return
    end
    local book_id = book.book_id or book.bookId
    if not self:isNetworkOnline() then
        if options.automatic then self:showBookMenu(book) end
        self:showOffline(_("Book info"))
        return
    end
    self:showBusy(_("Loading book info..."))
    local started = self:runOnlineTask(_("Book info"), function()
        local ok, err = pcall(function()
            local info = self.client:get_book_info(book_id)
            if info then
                for key, value in pairs(info) do
                    if value ~= nil then book[key] = value end
                end
                book.categoryName = info.categoryName or info.category or book.categoryName
            end
            local progress_result = self.client:get_progress(book_id)
            if progress_result and progress_result.book then
                local remote = progress_result.book
                book.progress = remote.progress or book.progress or 0
                book.chapter_uid = remote.chapterUid or remote.chapterId
                    or remote.chapter_uid or book.chapter_uid
                book.chapter_idx = tonumber(remote.chapterIdx or remote.chapterIndex
                    or remote.chapter_idx) or tonumber(book.chapter_idx)
                book.chapter_offset = tonumber(remote.chapterOffset or remote.chapterPos
                    or remote.offset) or tonumber(book.chapter_offset) or 0
            end
            book.book_id = book_id
            book._library_account_key = self.library_db
                and self.library_db:accountKey() or nil
            book.detail_updated_at = os.time()
            local books = self.settings:get("books", {})
            books[book_id] = book
            self.settings:set("books", books)
            self.settings:flush()
            if self.library_db then self.library_db:putBook(book) end
        end)
        self:closeBusy()
        if not ok then
            logger.err("load book info failed:", log_error(err))
            if options.automatic then self:showBookMenu(book) end
            self:showInfo(T(_("%1 failed:\n%2"), _("Book info"), display_error(err)))
            return
        end
        if old_view then UIManager:close(old_view) end
        self:showBookMenu(book)
        self:showTransientInfo(_("Book information updated."), 2)
    end)
    if started == false and options.automatic then self:showBookMenu(book) end
end

function M:showBookMenu(book)
    local BookDetailView = require("weink.ui.book_detail_view")
    local book_id = book.book_id or book.bookId
    if type(book.chapters) ~= "table" then
        book.chapters = self.library_db and self.library_db:getChapters(book_id) or nil
        if type(book.chapters) ~= "table" then
            local legacy_catalog = Content.load_catalog_cache(self.client, self.settings, book)
            if legacy_catalog and self.library_db then
                self.library_db:putChapters(book_id, legacy_catalog)
            end
        end
    end
    local saved = self.settings:get("books", {})[book_id] or book
    local cached_path = self:getFullBookCachePath(saved)
    local is_full_cached = file_exists(cached_path)
    local has_cache = self:bookRecordHasDownload(saved)
    book.cached_full_book = is_full_cached and cached_path or nil
    local cached_chapter_count = 0
    for _uid, path in pairs(book.cached_chapters or {}) do
        if file_exists(path) then cached_chapter_count = cached_chapter_count + 1 end
    end
    local total_chapters = type(book.chapters) == "table" and #book.chapters or nil
    if is_full_cached and cached_chapter_count == 0 and total_chapters then
        cached_chapter_count = total_chapters
    end
    local chapter_status = total_chapters
        and T(_("Cached %1/%2 chapters"), tostring(cached_chapter_count), tostring(total_chapters))
        or T(_("%1 chapters cached"), tostring(cached_chapter_count))

    local author_parts = {}
    if book.author and book.author ~= "" then author_parts[#author_parts + 1] = book.author end
    if book.translator and book.translator ~= "" then
        author_parts[#author_parts + 1] = T(_("Translated by %1"), book.translator)
    end
    local statuses = {}
    if book.progress and book.progress > 0 then
        statuses[#statuses + 1] = T(_("Progress %1%"), tostring(book.progress))
    end
    statuses[#statuses + 1] = chapter_status

    local metadata = {}
    local function format_field(label, value)
        if value == nil or value == "" then return nil end
        return T(_("%1: %2"), tostring(label), tostring(value))
    end
    local function add_row(left_label, left_value, right_label, right_value)
        local left = format_field(left_label, left_value)
        local right = format_field(right_label, right_value)
        if left or right then metadata[#metadata + 1] = { left = left, right = right } end
    end
    local word_count
    if book.wordCount and book.wordCount > 0 then
        word_count = book.wordCount >= 10000
            and string.format("%.1f%s", book.wordCount / 10000, _("w words"))
            or tostring(book.wordCount)
    end
    local rating
    if book.newRating and book.newRating > 0 then
        local score = string.format("%.1f", book.newRating / 100)
        rating = T(_("%1 (%2 ratings)"), score, tostring(book.newRatingCount or 0))
    end
    add_row(_("Publisher"), book.publisher,
        _("Publication date"), BookReviews.format_date(book.publishTime))
    local category = format_field(_("Category"), book.categoryName)
    if category then metadata[#metadata + 1] = { text = category } end
    local words = format_field(_("Word count"), word_count)
    if words then metadata[#metadata + 1] = { text = words } end
    add_row("ISBN", book.isbn, _("Rating"), rating)

    local view
    local open_chapter_list = self:safeCallback(_("Chapter list"), function()
        self:showChapterList(book, function()
            local latest = self.settings:get("books", {})[book_id] or book
            if view then UIManager:close(view) end
            self:showBookMenu(latest)
        end)
    end)
    local review_action = {
        text = _("Recommended / Latest"),
        callback = self:safeCallback(_("Book reviews"), function()
            self:showBookReviews(book)
        end),
    }
    local actions = {}
    if has_cache then
        actions[#actions + 1] = {
            text = _("Clear book cache"),
            callback = self:safeCallback(_("Clear book cache"), function()
                self:confirmClearBookCache(book_id, book.title or book_id, function()
                    book.cached_file = nil
                    book.cached_full_book = nil
                    book.cached_chapters = nil
                    book.cache_dir = nil
                    if view then UIManager:close(view) end
                    self:showBookMenu(book)
                end)
            end),
        }
    end
    local updated = book.detail_updated_at
        and os.date("%Y-%m-%d %H:%M", book.detail_updated_at) or _("Never updated")
    local bottom_actions = {
        {
            text = _("⇩ Download full book"),
            callback = self:safeCallback(_("Download full book"), function()
                self:confirmDownloadAllChapters(book)
            end),
        },
        {
            text = _("☷ Chapter list"),
            callback = open_chapter_list,
        },
        {
            text = _("▤ Read"),
            enabled = has_cache,
            callback = self:safeCallback(_("Read"), function()
                self:openBookForReading(book)
            end),
        },
    }
    view = BookDetailView.show({
        title = book.title or _("Book details"),
        author_line = table.concat(author_parts, "  ·  "),
        status_line = table.concat(statuses, "  ·  "),
        refresh_label = _("↻ Get latest information"),
        refresh_date = updated,
        metadata = metadata,
        intro = book.intro,
        review_action = review_action,
        actions = actions,
        bottom_actions = bottom_actions,
    }, {
        on_refresh = self:safeCallback(_("Get latest information"), function()
            self:refreshBookRecord(book, view)
        end),
    })
    self._book_detail_view = view
    return view
end

function M:showBookReviewDetail(book, review, mode)
    local author = review.author ~= "" and review.author or _("Anonymous")
    local metadata = {}
    if review.rating > 0 then
        metadata[#metadata + 1] = T(
            _("Score %1"), BookReviews.format_rating(review.rating)
        )
    end
    local review_date = BookReviews.format_date(review.create_time)
    if review_date ~= "" then
        metadata[#metadata + 1] = review_date
    end
    if review.is_finish then
        metadata[#metadata + 1] = _("Finished")
    end

    local text = {}
    text[#text + 1] = "《" .. tostring(book.title or _("Untitled")) .. "》"
    text[#text + 1] = author
    if #metadata > 0 then
        text[#text + 1] = table.concat(metadata, " · ")
    end
    text[#text + 1] = ""
    text[#text + 1] = review.content ~= "" and review.content or _("No review content.")

    UIManager:show(TextViewer:new{
        title = mode == "latest" and _("Latest review") or _("Recommended review"),
        text = table.concat(text, "\n"),
        text_type = "general",
        auto_para_direction = true,
    })
end

function M:showBookReviews(book)
    if not self:requireLogin(false, true) then
        return
    end
    local book_id = book.book_id or book.bookId
    local session = {
        cache = {},
    }

    local loadReviews
    loadReviews = function(mode, old_view, more)
        if session.loading then return end
        local function showResult(result)
            if old_view then
                UIManager:close(old_view)
            end
            local view
            view = BookReviewsView.show({
                book_title = book.title or _("Untitled"),
                mode = mode,
                result = result,
            }, {
                on_switch = function(new_mode)
                    loadReviews(new_mode, view)
                end,
                on_select = function(review, selected_mode)
                    self:showBookReviewDetail(book, review, selected_mode)
                end,
                on_more = function()
                    loadReviews(mode, view, true)
                end,
            })
        end

        if session.cache[mode] and not more then
            showResult(session.cache[mode])
            return
        end
        session.loading = true
        self:showBusy(_("Loading book reviews..."))
        local started = self:runOnlineTask(_("Book reviews"), function()
            local ok, result = pcall(function()
                -- APK BaseBookReviewListService:
                -- latest = ReviewListType.BOOK_TOP (listType=3)
                -- recommended = ReviewListType.BOOK_WONDERFUL (listType=8) + type=4
                -- listType=1 is the current user's own underlines/thoughts.
                local list_type = 8
                local review_type = 4
                if mode == "latest" then
                    list_type = 3
                    review_type = nil
                end
                return BookReviews.load_more(self.client, book_id, list_type, review_type,
                    more and session.cache[mode] or nil)
            end)
            session.loading = false
            self:closeBusy()
            if not ok then
                logger.err("load book reviews failed:", log_error(result))
                self:showInfo(T(_("%1 failed:\n%2"), _("Book reviews"), display_error(result)))
                return
            end
            session.cache[mode] = result
            showResult(result)
        end)
        if started == false then
            session.loading = false
            self:closeBusy()
        end
    end

    loadReviews("recommended", nil)
end

function M:showWeChatArticlesPage(list_type, title, old_view)
    list_type = tonumber(list_type) or 2
    title = title or (list_type == 1 and _("WeChat Floating Articles") or _("WeChat Favorites"))
    local cached = self.library_db and self.library_db:getMpArticles(list_type) or nil
    if cached and #cached > 0 then
        self:renderWeChatArticleList(list_type, title, cached, old_view)
        return
    end
    self:fetchWeChatArticles(list_type, title, old_view)
end

function M:fetchWeChatArticles(list_type, title, old_view)
    list_type = tonumber(list_type) or 2
    title = title or (list_type == 1 and _("WeChat Floating Articles") or _("WeChat Favorites"))
    self:runOnlineTask(_("Sync WeChat articles..."), function()
        self:showBusy(_("Sync WeChat articles..."))
        local ok, res_or_err = pcall(function()
            return self.client:eink_mp_list(list_type, 0, 50)
        end)
        self:closeBusy()
        if not ok or type(res_or_err) ~= "table" then
            logger.err("fetch WeChat articles failed:", log_error(res_or_err))
            self:showInfo(T(_("Sync WeChat articles failed:\n%1"), display_error(res_or_err)))
            return
        end
        local articles = self:dedupeMpArticles(res_or_err.lists or {})
        if self.library_db then
            self.library_db:cacheMpArticles(list_type, articles)
        end
        self:renderWeChatArticleList(list_type, title, articles, old_view)
    end)
end

-- /mp/list returns the same saved article twice -- once as a WeRead-native
-- entry, once in the WeChat-saved form -- for articles the user touched from
-- both apps. The raw response renders two rows on the first sync and one after
-- the same list is read back from the database cache. Keep one row per
-- reviewId, preferring the copy whose link already carries a chksm signature.
function M:dedupeMpArticles(articles)
    local is_signed = type(Content.mp_url_is_signed) == "function"
        and Content.mp_url_is_signed or function() return false end
    local rows, seen = {}, {}
    for _, article in ipairs(articles or {}) do
        local review_id = tostring(article.reviewId or article.review_id or "")
        if review_id == "" then
            rows[#rows + 1] = article
        else
            local at = seen[review_id]
            if not at then
                seen[review_id] = #rows + 1
                rows[#rows + 1] = article
            elseif not is_signed(rows[at].url) and is_signed(article.url) then
                rows[at] = article
            end
        end
    end
    return rows
end

function M:renderWeChatArticleList(list_type, title, articles, old_view)
    local LibraryView = require("weink.ui.library_view")
    local mode = mp_mode(list_type)
    local rows = {}
    for _, article in ipairs(self:dedupeMpArticles(articles)) do
        local cached_path = Content.article_cached_path(self.settings, nil, article)
        if not Content.is_valid_article_cache(cached_path) then
            cached_path = nil
        end
        article._cached_path = cached_path
        article._cached = cached_path ~= nil and file_exists(cached_path)
        rows[#rows + 1] = article
    end
    local pending_links = {}
    for _, article in ipairs(rows) do
        if not article._cached then pending_links[#pending_links + 1] = article end
    end
    self:prefetchWeChatArticleLinks(pending_links, mode .. ":" ..
        tostring(self.shelf_view_pages and self.shelf_view_pages[mode] or 1))
    if old_view then UIManager:close(old_view) end
    local view
    view = LibraryView.show({
        mode = mode,
        title = _("WeRead Bookshelf"),
        books = self.shelf_regular or {},
        articles = rows,
        paged = true,
        page = self.shelf_view_pages and self.shelf_view_pages[mode] or 1,
        page_size = math.max(4, list_items_per_page() - 4),
    }, {
        on_switch = function(new_mode)
            if new_mode == "store" then
                self:showStoreHome(view)
            elseif new_mode == "books" then
                self:showShelfView("books", nil, view)
            else
                self:showWeChatArticlesPage(mp_list_type(new_mode), nil, view)
            end
        end,
        on_refresh = function()
            self:fetchWeChatArticles(list_type, title, view)
        end,
        on_select = function(article)
            local path = article._cached_path
            if path and Content.is_valid_article_cache(path) and file_exists(path) then
                self:openFile(path)
            else
                self:downloadWeChatArticleAndRead(article, list_type)
            end
        end,
        on_page_changed = function(new_page)
            self.shelf_view_pages = self.shelf_view_pages or {}
            self.shelf_view_pages[mode] = new_page
            self:renderWeChatArticleList(list_type, title, articles, view)
        end,
    })
    self.shelf_view_mode = mode
    self.shelf_view = view
    self.shelf_view_pages = self.shelf_view_pages or {}
    self.shelf_view_pages[mode] = view.page
    return view
end

-- Silent, capped prefetch of the signed links for the articles on screen. See
-- weink/lib/mp_link_prefetch_worker.lua for why the lookup is expensive.
-- The same page is only prefetched once per MP_LINK_PREFETCH_INTERVAL: KOReader
-- re-renders the list on every page turn and refresh, and each batch costs a
-- couple of dozen /review/single calls on the device.
local MP_LINK_PREFETCH_LIMIT = 6
local MP_LINK_PREFETCH_INTERVAL = 60

function M:prefetchWeChatArticleLinks(articles, key)
    local worker = self.prefetch_worker
    if not worker or type(worker.start) ~= "function" or not worker:available() then
        return false
    end
    local MpLinkPrefetchWorker = require("weink.lib.mp_link_prefetch_worker")
    local candidates = MpLinkPrefetchWorker.candidates(articles, MP_LINK_PREFETCH_LIMIT)
    if #candidates == 0 then return false end
    local now = os.time()
    key = tostring(key or "default")
    if self._mp_prefetch_key == key
        and (now - (self._mp_prefetch_at or 0)) < MP_LINK_PREFETCH_INTERVAL then
        return false
    end
    self._mp_prefetch_key = key
    self._mp_prefetch_at = now
    local auth_fingerprint = require("weink.lib.worker_settings").fingerprint(self.settings)
    -- Declared before the closure: on_done compares against it, and a local
    -- declared in the same statement is not in scope inside the initializer.
    local handle
    local ok
    ok, handle = worker:start {
        queue = true,
        timeout = 180,
        task = function(context)
            return MpLinkPrefetchWorker.run(self.settings, self.client, candidates, context)
        end,
        on_done = function(result)
            if self._mp_prefetch_handle == handle then self._mp_prefetch_handle = nil end
            local value = type(result) == "table" and (result.value or result) or nil
            if type(value) ~= "table" then return end
            local WorkerSettings = require("weink.lib.worker_settings")
            if value.auth and not WorkerSettings.merge(self.settings,
                auth_fingerprint, value.auth) then
                logger.info("skip MP link prefetch auth write-back: parent auth changed")
            end
            local links = value.links
            if type(links) ~= "table" then return end
            local stored = 0
            for review_id, url in pairs(links) do
                if Content.remember_mp_article_url(review_id, url) then
                    stored = stored + 1
                end
            end
            if stored > 0 then
                logger.info("MP article links prefetched:", "stored=", tostring(stored))
            end
        end,
    }
    self._mp_prefetch_handle = ok and handle or nil
    return ok
end

function M:cancelWeChatArticleLinkPrefetch(reason)
    local worker = self.prefetch_worker
    local handle = self._mp_prefetch_handle
    self._mp_prefetch_handle = nil
    if not worker or not handle then return false end
    return worker:cancel(handle, reason or "cancelled")
end

function M:downloadWeChatArticleAndRead(article, list_type, on_complete)
    -- The user wants this link now; stop the background batch so it does not
    -- compete for the worker and the network.
    self:cancelWeChatArticleLinkPrefetch("article_open")
    self:runOnlineTask(_("Download article and read"), function()
        self:showBusy(T(_("Downloading article: %1"), article.title or ""))
        local progress_dialog
        local ok, path_or_err = pcall(function()
            local saved_path = Content.fetch_article_html(self.client, self.settings, nil, article, {
                progress = function(current, total)
                    if not progress_dialog then
                        self:closeBusy()
                        progress_dialog = ProgressbarDialog:new{
                            title = T(_("Downloading images: %1"), article.title or ""),
                            progress_max = total,
                        }
                        progress_dialog:show()
                        self:refreshUI()
                    end
                    progress_dialog:reportProgress(current)
                end,
            })
            if not saved_path or not Content.is_valid_article_cache(saved_path) then
                error("article cache is invalid")
            end
            if self.library_db and article.reviewId then
                self.library_db:updateMpArticleCachePath(article.reviewId, saved_path)
            end
            local reported, report_err = pcall(function()
                return self.client:eink_report_mp_read(article, false)
            end)
            if reported then
                logger.info("MP article marked as read:",
                    "reviewId=" .. tostring(article.reviewId or ""))
            else
                logger.warn("MP article read report failed:", log_error(report_err))
            end
            return saved_path
        end)
        if progress_dialog then
            progress_dialog:close()
        else
            self:closeBusy()
        end
        if not ok then
            logger.err("download WeChat article failed:", log_error(path_or_err))
            self:showInfo(T(_("Download failed:\n%1"), display_error(path_or_err)))
            return
        end
        if type(on_complete) == "function" then
            pcall(on_complete)
        end
        self:openFile(path_or_err)
    end)
end

function M:loadChapters(book, callback, force_refresh)
    if not force_refresh then
        if book.chapters and #book.chapters > 0 then
            local book_id = book.book_id or book.bookId
            if self.library_db and book_id then
                self.library_db:putChapters(book_id, book.chapters)
            end
            local catalog_path = Content.catalog_cache_path(
                self.settings, book)
            if catalog_path and not file_exists(catalog_path) then
                local cache_ok, cache_err = Content.save_catalog_cache(
                    self.client, self.settings, book, book.chapters)
                if not cache_ok then
                    logger.warn("save chapter catalog cache failed:",
                        log_error(cache_err))
                end
            end
            callback(book.chapters)
            return
        end
        local book_id = book.book_id or book.bookId
        local cached = self.library_db and self.library_db:getChapters(book_id) or nil
        if type(cached) == "table" and #cached > 0 then
            book.chapters = cached
            local catalog_path = Content.catalog_cache_path(
                self.settings, book)
            if catalog_path and not file_exists(catalog_path) then
                local cache_ok, cache_err = Content.save_catalog_cache(
                    self.client, self.settings, book, cached)
                if not cache_ok then
                    logger.warn("save chapter catalog cache failed:",
                        log_error(cache_err))
                end
            end
        else
            cached = Content.load_catalog_cache(self.client, self.settings, book)
            if type(cached) == "table" and #cached > 0 and self.library_db then
                self.library_db:putChapters(book_id, cached)
            end
        end
        if type(cached) == "table" and #cached > 0 then
            callback(cached)
            return
        end
    end
    if not self:requireLogin(true, false) then
        return
    end
    self:runOnlineTask(_("Loading chapter list..."), function()
        self:showBusy(_("Loading chapter list..."))
        local ok, chapters_or_err = pcall(function()
            return Content.fetch_catalog(self.client, book)
        end)
        self:closeBusy()
        if not ok then
            logger.err("load chapters failed:", log_error(chapters_or_err))
            self:showInfo(T(_("Load chapters failed:\n%1"), display_error(chapters_or_err)))
            return
        end
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters_or_err)
        if not cache_ok then
            logger.warn("save chapter catalog cache failed:", log_error(cache_err))
        end
        local books = self.settings:get("books", {})
        local book_id = book.book_id or book.bookId
        if book_id then
            if self.library_db then
                self.library_db:putChapters(book_id, chapters_or_err)
                self.library_db:putBook(book)
            end
            books[book_id] = book
            self.settings:set("books", books)
            self.settings:flush()
        end
        callback(chapters_or_err)
    end)
end

function M:showChapterList(book, on_close)
    local ChapterListView = require("weink.ui.chapter_list_view")
    local function reloadBookCache()
        if not self.settings then return end
        local book_id = book.book_id or book.bookId
        local latest = book_id and self.settings:get("books", {})[book_id]
        if type(latest) ~= "table" then return end
        for field in pairs(local_cache_fields) do
            if latest[field] ~= nil then book[field] = latest[field] end
        end
        if self.library_db then self.library_db:putBook(latest) end
    end
    local showCatalog
    showCatalog = function(chapters, old_view)
        -- Downloads persist their cache paths before invoking on_complete.
        -- Always rebuild from that persisted record instead of the snapshot
        -- captured when the chapter list was first opened.
        reloadBookCache()
        local rows = {}
        for _i, chapter in ipairs(chapters) do
            local chapter_uid = chapter.chapterUid or chapter.chapterId
            local cached = book.cached_chapters
                and book.cached_chapters[tostring(chapter_uid)]
            if cached and not file_exists(cached) then
                book.cached_chapters[tostring(chapter_uid)] = nil
                cached = nil
            end
            rows[#rows + 1] = {
                title = chapter.title or T(_("Chapter %1"), tostring(chapter_uid)),
                status = cached and _("Cached")
                    or T(_("%1 words"), tostring(chapter.wordCount or 0)),
                source = chapter,
            }
        end
        if old_view then
            UIManager:close(old_view)
            if self._chapter_list_view == old_view then
                self._chapter_list_view = nil
            end
        end
        local view
        view = ChapterListView.show({
            title = book.title or _("Chapter list"),
            chapters = rows,
        }, {
            on_refresh = self:safeCallback(_("Refresh chapter list"), function()
                self:loadChapters(book, function(refreshed_chapters)
                    showCatalog(refreshed_chapters, view)
                    self:showTransientInfo(T(_("Chapter list refreshed: %1 chapters"),
                        tostring(#refreshed_chapters)), 2)
                end, true)
            end),
            on_select_download = self:safeCallback(_("Select chapters to download"), function()
                self:showChapterDownloadSelection(book, chapters, function()
                    showCatalog(chapters, view)
                end)
            end),
            on_select = function(chapter)
                self:openChapter(book, chapter, function()
                    -- The downloader has persisted the new chapter path before
                    -- this callback runs. Rebuild beneath the completion dialog
                    -- so either "Read now" or "Close" leaves current cache state.
                    UIManager:scheduleIn(0.1, function()
                        showCatalog(chapters, view)
                    end)
                end)
            end,
            on_close = function()
                if self._chapter_list_view == view then
                    self._chapter_list_view = nil
                end
                if on_close then on_close() end
            end,
        })
        self._chapter_list_view = view
    end
    self:loadChapters(book, function(chapters)
        showCatalog(chapters)
    end)
end

function M:showChapterDownloadSelection(book, chapters, on_downloaded)
    local selected = {}
    local menu
    local function selectedChapters()
        local result = {}
        for _i, chapter in ipairs(chapters) do
            local uid = tostring(chapter.chapterUid or chapter.chapterId or _i)
            if selected[uid] then
                result[#result + 1] = chapter
            end
        end
        return result
    end
    local function selectedCount()
        local count = 0
        for _uid in pairs(selected) do count = count + 1 end
        return count
    end

    local items = {}
    local perpage = list_items_per_page()
    local chapters_per_page = math.max(1, perpage - 1)
    local function appendDownloadAction()
        items[#items + 1] = {
            text_func = function()
                return T(_("[Download] Selected chapters (%1)"),
                    tostring(selectedCount()))
            end,
            bold = true,
            select_enabled_func = function() return selectedCount() > 0 end,
            separator = true,
            callback = self:safeCallback(_("Download selected chapters"), function()
                local targets = selectedChapters()
                if #targets == 0 then return end
                self:confirmAndDownloadChapters(book, targets, "chapters", {
                    separate_chapters = true,
                    on_complete = function(ok)
                        if not ok then return end
                        UIManager:scheduleIn(0.1, function()
                            if menu then UIManager:close(menu) end
                            if on_downloaded then on_downloaded() end
                        end)
                    end,
                })
            end),
        }
    end
    for page_start = 1, #chapters, chapters_per_page do
        appendDownloadAction()
        local page_end = math.min(#chapters, page_start + chapters_per_page - 1)
        for chapter_index = page_start, page_end do
            local chapter = chapters[chapter_index]
            local uid = tostring(chapter.chapterUid or chapter.chapterId or chapter_index)
            local cached = book.cached_chapters and book.cached_chapters[uid]
            local is_cached = file_exists(cached)
            items[#items + 1] = {
                text_func = function()
                    local marker = selected[uid] and "[✓] " or "[  ] "
                    return marker .. (chapter.title or T(_("Chapter %1"), uid))
                end,
                mandatory_func = function()
                    if selected[uid] then return _("Selected") end
                    return is_cached and _("Cached")
                        or T(_("%1 words"), tostring(chapter.wordCount or 0))
                end,
                callback = self:safeCallback(chapter.title or _("Chapter"), function()
                    if selected[uid] then
                        selected[uid] = nil
                    else
                        selected[uid] = true
                    end
                    if menu then menu:updateItems() end
                end),
            }
        end
    end
    menu = self:showList(_("Select chapters to download"), items,
        _("No chapters."), { items_per_page = perpage })
end

function M:openFile(path)
    if not path or path == "" then
        self:showInfo(_("No cached file."))
        return
    end
    self:closeWeinkUI()
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
end

function M:openBookForReading(book)
    local full_path = self:getFullBookCachePath(book)
    if file_exists(full_path) then
        self:openFile(full_path)
        return true
    end

    local book_id = book.book_id or book.bookId
    local chapters = book.chapters
    if type(chapters) ~= "table" and self.library_db then
        chapters = self.library_db:getChapters(book_id)
        if chapters then book.chapters = chapters end
    end
    if type(chapters) ~= "table" then
        chapters = Content.load_catalog_cache(self.client, self.settings, book)
    end

    local candidates = {}
    local target_index
    if type(chapters) == "table" then
        for index, chapter in ipairs(chapters) do
            local uid = tostring(chapter.chapterUid or chapter.chapterId or index)
            local path = book.cached_chapters and book.cached_chapters[uid]
            if file_exists(path) then
                candidates[#candidates + 1] = { index = index, path = path }
            end
            if book.chapter_uid ~= nil
                and uid == tostring(book.chapter_uid) then
                target_index = index
            elseif target_index == nil and book.chapter_idx ~= nil
                and tonumber(chapter.chapterIdx or chapter.chapterIndex) == tonumber(book.chapter_idx) then
                target_index = index
            end
        end
        if not target_index and tonumber(book.progress) then
            local progress = math.max(0, math.min(100, tonumber(book.progress)))
            target_index = math.floor(progress / 100 * math.max(0, #chapters - 1)) + 1
        end
    end

    if #candidates > 0 then
        target_index = target_index or candidates[1].index
        table.sort(candidates, function(left, right)
            local left_distance = math.abs(left.index - target_index)
            local right_distance = math.abs(right.index - target_index)
            if left_distance ~= right_distance then return left_distance < right_distance end
            local left_precedes = left.index <= target_index
            local right_precedes = right.index <= target_index
            if left_precedes ~= right_precedes then return left_precedes end
            return left.index < right.index
        end)
        self:openFile(candidates[1].path)
        return true
    end

    local fallback_paths = {}
    for uid, path in pairs(book.cached_chapters or {}) do
        if file_exists(path) then fallback_paths[#fallback_paths + 1] = { uid = tostring(uid), path = path } end
    end
    table.sort(fallback_paths, function(left, right) return left.uid < right.uid end)
    if fallback_paths[1] then
        self:openFile(fallback_paths[1].path)
        return true
    end
    self:showInfo(_("No cached file."))
    return false
end

-- Open a chapter, preferring its cached file and falling back to a download.
function M:openChapter(book, chapter, on_downloaded)
    local chapter_uid = chapter.chapterUid or chapter.chapterId
    local cached = book.cached_chapters and book.cached_chapters[tostring(chapter_uid)]
    if cached and file_exists(cached) then
        self:openFile(cached)
    elseif self.downloader:promotePrefetch(book, chapter) then
        -- The downloader promotes the background task to a visible progress
        -- dialog and opens the chapter as soon as the same task completes.
        return
    else
        self:downloadChapterAndRead(book, chapter, on_downloaded)
    end
end

-- Open a chapter selected by cloud-progress resolution. Unlike ordinary
-- chapter navigation, a missing target must be confirmed explicitly and then
-- opened automatically so ProgressSync can apply its pending in-chapter jump
-- in the next onReaderReady event.
function M:openProgressTargetChapter(book, chapter)
    if type(book) ~= "table" or type(chapter) ~= "table" then
        return false, "target_chapter_unavailable"
    end
    local chapter_uid = chapter.chapterUid or chapter.chapterId
    local cached = chapter_uid and book.cached_chapters
        and book.cached_chapters[tostring(chapter_uid)]
    if cached and file_exists(cached) then
        self:openFile(cached)
        return true
    end

    local title = chapter.title
        or T(_("Chapter %1"), tostring(chapter_uid or ""))
    local confirm
    confirm = ConfirmBox:new{
        text = T(_(
            "Cloud progress is in \"%1\", but this chapter has not been downloaded.\n\n"
            .. "Download and open it now?"
        ), title),
        ok_text = _("Download target chapter"),
        ok_callback = self:safeCallback(_("Download target chapter"), function()
            UIManager:close(confirm)
            self.downloader:start(book, { chapter }, "chapter", {
                single_chapter = true,
                open_on_complete = true,
                on_complete = function(ok, reason)
                    if not ok and self.progress_sync then
                        self.progress_sync:cancel_pending_jump(reason)
                    end
                end,
            })
        end),
        cancel_text = _("Cancel"),
        cancel_callback = function()
            if self.progress_sync then
                self.progress_sync:cancel_pending_jump(
                    "target_chapter_download_cancelled")
            end
        end,
    }
    UIManager:show(confirm)
    return true
end

function M:downloadChapterAndRead(book, chapter, on_downloaded)
    self:confirmAndDownloadChapters(book, { chapter }, "chapter", {
        single_chapter = true,
        on_complete = function(ok, path)
            if ok and on_downloaded then on_downloaded(path) end
        end,
    })
end

function M:confirmDownloadAllChapters(book)
    self:loadChapters(book, function(chapters)
        self:confirmAndDownloadChapters(book, chapters, "full", {
            confirmation_text = T(_("Download all %1 chapters as one EPUB?"), tostring(#chapters)),
        })
    end)
end

-- Every manual book/chapter download makes annotation fetching an explicit,
-- per-job choice. The persisted annotation flag is reserved for background
-- prefetches, so a manual choice never changes future automatic behaviour.
function M:confirmAndDownloadChapters(book, chapters, suffix, options)
    options = options or {}
    local text = options.confirmation_text
        or T(_("Download %1 selected chapter(s)?"), tostring(#chapters))
    if suffix == "full" then
        text = text .. "\n" .. _(
            "A book with many chapters may take a long time. Prefer single- or multi-chapter downloads when possible."
        )
    end
    text = text .. "\n" .. _(
        "Downloading underlines and thoughts may significantly increase download time."
    )

    local dialog
    local function start(include_annotations)
        UIManager:close(dialog)
        local job_options = {}
        for key, value in pairs(options) do job_options[key] = value end
        job_options.include_annotations = include_annotations == true
        self.downloader:start(book, chapters, suffix, job_options)
    end
    dialog = ButtonDialog:new{
        title = text,
        buttons = {
            {{
                text = _("Download text only"),
                callback = self:safeCallback(_("Download text only"), function()
                    start(false)
                end),
            }},
            {{
                text = _("Download with underlines and thoughts"),
                callback = self:safeCallback(_("Download with underlines and thoughts"), function()
                    start(true)
                end),
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            }},
        },
    }
    UIManager:show(dialog)
end

function M:showSearch()
    if not self:requireLogin(true, true) then
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search WeRead"),
        input = "",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = self:safeCallback(_("Cancel"), function()
                        UIManager:close(dialog)
                    end),
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = self:safeCallback(_("Search"), function()
                        local keyword = dialog:getInputText()
                        UIManager:close(dialog)
                        self:searchWithUI(keyword)
                    end),
                },
            },
        },
    }
    self:showInputDialog(dialog)
end

function M:searchWithUI(keyword)
    if not keyword or keyword == "" then
        return
    end
    self:runOnlineTask(_("Search"), function()
        local ok, result = pcall(function()
            return self.client:search_store(keyword, 10)
        end)
        if not ok then
            logger.err("search failed:", log_error(result))
            self:showInfo(T(_("Search failed:\n%1"), display_error(result)))
            return
        end
        local items = {}
        for group_index, group in ipairs(result.results or {}) do
            for book_index, entry in ipairs(group.books or {}) do
                local book = entry.bookInfo or entry
                table.insert(items, {
                    text = book.title or book.bookId or _("Untitled"),
                    post_text = book.author or "",
                    mandatory = book.category or "",
                    callback = self:safeCallback(book.title or book.bookId or _("Untitled"), function()
                        self:showBookRecord(book)
                    end),
                })
            end
        end
        self:showList(T(_("Search: %1"), keyword), items, _("No search results."))
    end)
end

function M:showCurrentBookDetails()
    local book_id = self:detectWeinkBook()
    local book = book_id and self.settings:get("books", {})[book_id] or nil
    if not book then
        self:showInfo(_("The current document is not a WeRead cached book."))
        return
    end
    book.book_id = book.book_id or book_id
    self:showBookRecord(book)
end

return M

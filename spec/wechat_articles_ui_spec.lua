-- UI tests for WeChat Articles (Favorites and Floating) tabs and pages.

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks, failures = 0, 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then
        failures = failures + 1
        print("FAIL " .. (message or ("check " .. checks)))
    end
end

package.preload["weread.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weread.ui.book_reviews_view"] = function() return {} end
package.preload["ui/widget/buttondialog"] = function() return {} end
package.preload["ui/widget/confirmbox"] = function() return {} end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["ui/widget/progressbardialog"] = function() return {} end
package.preload["ui/widget/textviewer"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_self, _delay, callback) callback() end,
        close = function() end,
    }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...) return text end,
        log_error = tostring,
        display_error = tostring,
        file_exists = function(path)
            return path and path:find("cached", 1, true) ~= nil
        end,
    }
end
package.preload["weread.lib.content"] = function()
    return {
        is_valid_article_cache = function(path)
            return path and path:find("/cache/", 1, true) ~= nil
        end,
        article_cached_path = function(_settings, _book, article)
            if article.reviewId == "cached_1" then return "/cache/cached_1.html" end
            return nil
        end,
        fetch_article_html = function(_client, _settings, _book, article)
            return "/cache/" .. article.reviewId .. ".html"
        end,
        save_article_html = function()
            error("fetched file path must not be saved as article body")
        end,
    }
end

local shown_views = {}
package.preload["weread.ui.library_view"] = function()
    return {
        show = function(data, callbacks)
            local view = { data = data, callbacks = callbacks, page = data.page or 1 }
            shown_views[#shown_views + 1] = view
            return view
        end,
    }
end

local Library = require("weread.ui.library")

local opened_files = {}
local mp_articles_store = { [1] = {}, [2] = {} }
local updated_cache_paths = {}
local reported_reads = {}

local host = {
    settings = {
        get = function(_self, _key, default) return default end,
        set = function() end,
        flush = function() end,
    },
    library_db = {
        getMpArticles = function(_self, lt) return mp_articles_store[lt] end,
        cacheMpArticles = function(_self, lt, articles)
            mp_articles_store[lt] = articles
            return true
        end,
        updateMpArticleCachePath = function(_self, rid, path)
            updated_cache_paths[rid] = path
            return true
        end,
    },
    client = {
        eink_mp_list = function(_self, lt)
            return {
                lists = {
                    { reviewId = "art_1", title = "Article 1", account = "Account 1" },
                    { reviewId = "cached_1", title = "Cached Article", account = "Account 2" },
                },
                synckey = 100,
            }
        end,
        eink_report_mp_read = function(_self, article, is_delete)
            reported_reads[#reported_reads + 1] = { article = article, is_delete = is_delete }
            return { succ = 1 }
        end,
    },
    shelf_regular = { { bookId = "b1" }, { bookId = "b2" } },
    shelf_mp = {},
    safeCallback = function(_self, _name, fn) return fn end,
    runOnlineTask = function(_self, _label, fn) fn() end,
    showBusy = function() end,
    closeBusy = function() end,
    refreshUI = function() end,
    openFile = function(_self, path) opened_files[#opened_files + 1] = path end,
}

for k, v in pairs(Library) do
    if host[k] == nil then host[k] = v end
end

-- The article tab renders the list directly on the full-screen shelf view.
host:showWeChatArticlesPage(2)
expect(#shown_views == 1, "article view count mismatch")
local view = shown_views[1]
expect(view.data.mode == "floating", "floating shelf mode mismatch")
expect(#view.data.articles == 2, "article list count mismatch")
expect(view.data.articles[2]._cached == true, "cached article badge mismatch")

view.callbacks.on_switch("favorites")
expect(shown_views[2].data.mode == "favorites", "favorites tab did not open directly")
expect(#shown_views[2].data.articles == 2, "favorites list missing")

view = shown_views[2]
view.callbacks.on_refresh()
expect(#shown_views == 3 and shown_views[3].data.mode == "favorites",
    "refresh button did not reload the current article list")
view = shown_views[3]

-- Cached article opens directly; uncached article fetches exactly once.
view.callbacks.on_select(view.data.articles[2])
expect(#opened_files == 1 and opened_files[1] == "/cache/cached_1.html", "cached article open mismatch")

view.callbacks.on_select(view.data.articles[1])
expect(#opened_files == 2 and opened_files[2] == "/cache/art_1.html", "uncached article download & open mismatch")
expect(updated_cache_paths["art_1"] == "/cache/art_1.html", "db cache path not updated")
expect(#reported_reads == 1 and reported_reads[1].article.reviewId == "art_1", "read status not reported")

if failures > 0 then
    error(string.format("%d checks failed in wechat_articles_ui_spec", failures))
end
print(string.format("wechat_articles_ui_spec: %d checks, 0 failure(s)", checks))

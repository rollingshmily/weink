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

package.preload["weink.lib.book_reviews"] = function()
    return { format_date = function() return "" end }
end
package.preload["weink.ui.book_reviews_view"] = function() return {} end
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
package.preload["weink.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weink.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["weink.lib.plugin_util"] = function()
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
package.preload["weink.lib.content"] = function()
    return {
        mp_url_is_signed = function(url)
            return type(url) == "string" and url:find("chksm=", 1, true) ~= nil
        end,
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
package.preload["weink.ui.library_view"] = function()
    return {
        show = function(data, callbacks)
            local view = { data = data, callbacks = callbacks, page = data.page or 1 }
            shown_views[#shown_views + 1] = view
            return view
        end,
    }
end

local Library = require("weink.ui.library")

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
-- /mp/list listType: 1 = WeChat floating, 2 = favorites (verified against a
-- real account on 2026-10-07; the two used to be mapped the other way round).
host:showWeChatArticlesPage(2)
expect(#shown_views == 1, "article view count mismatch")
local view = shown_views[1]
expect(view.data.mode == "favorites", "favorites shelf mode mismatch")
expect(#view.data.articles == 2, "article list count mismatch")
expect(view.data.articles[2]._cached == true, "cached article badge mismatch")

view.callbacks.on_switch("floating")
expect(shown_views[2].data.mode == "floating", "floating tab did not open directly")
expect(#shown_views[2].data.articles == 2, "floating list missing")

view = shown_views[2]
view.callbacks.on_refresh()
expect(#shown_views == 3 and shown_views[3].data.mode == "floating",
    "refresh button did not reload the current article list")
view = shown_views[3]

-- Cached article opens directly; uncached article fetches exactly once.
view.callbacks.on_select(view.data.articles[2])
expect(#opened_files == 1 and opened_files[1] == "/cache/cached_1.html", "cached article open mismatch")

view.callbacks.on_select(view.data.articles[1])
expect(#opened_files == 2 and opened_files[2] == "/cache/art_1.html", "uncached article download & open mismatch")
expect(updated_cache_paths["art_1"] == "/cache/art_1.html", "db cache path not updated")
expect(#reported_reads == 1 and reported_reads[1].article.reviewId == "art_1", "read status not reported")

-- /mp/list returns the same saved article twice (a WeRead-native entry plus
-- the WeChat-saved form) for articles touched from both apps; the list must
-- keep one row per reviewId (2026-10-08 device report).
local deduped = host:dedupeMpArticles({
    { reviewId = "dup_1", title = "dup", url = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=b&scene=58&subscene=0" },
    { reviewId = "dup_1", title = "dup", url = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=b&chksm=" .. string.rep("d", 64) },
    { reviewId = "other", title = "other", url = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=c" },
    { reviewId = "", title = "no id", url = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=d" },
    { reviewId = "", title = "no id 2", url = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=e" },
})
expect(#deduped == 4, "duplicate reviewIds must collapse, got " .. #deduped)
expect(deduped[1].reviewId == "dup_1" and deduped[2].reviewId == "other",
    "dedupe must keep the first occurrence position")
expect(deduped[1].url:find("chksm=", 1, true) ~= nil,
    "dedupe must prefer the already signed copy")
expect(deduped[3].reviewId == "" and deduped[4].reviewId == "",
    "entries without a reviewId must all be kept")

host.client.eink_mp_list = function()
    return {
        lists = {
            { reviewId = "dup_2", title = "dup", url = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=f&scene=58&subscene=0" },
            { reviewId = "dup_2", title = "dup", url = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=f&scene=58&subscene=0" },
            { reviewId = "solo", title = "solo", url = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=g&scene=58&subscene=0" },
        },
        synckey = 1,
    }
end
local views_before = #shown_views
host:fetchWeChatArticles(2)
expect(#shown_views == views_before + 1, "fetch must render exactly one view")
local fetched = shown_views[#shown_views]
expect(#fetched.data.articles == 2,
    "duplicate rows must not reach the view, got " .. #fetched.data.articles)
expect(mp_articles_store[2][1].reviewId == "dup_2",
    "the database cache must receive the deduped list")

if failures > 0 then
    error(string.format("%d checks failed in wechat_articles_ui_spec", failures))
end
print(string.format("wechat_articles_ui_spec: %d checks, 0 failure(s)", checks))

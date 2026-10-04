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
    return {
        is_mp_book = function() return false end,
        mp_reader_url = function() return "https://weread.qq.com" end,
    }
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
        mp_article_cached_path = function(_settings, _book, article)
            if article.reviewId == "cached_1" then return "/cache/cached_1.html" end
            return nil
        end,
        fetch_mp_article_html = function(_client, _settings, _book, article)
            return "<html><body>" .. article.title .. "</body></html>"
        end,
        save_mp_article_html = function(_settings, _book, article)
            return "/cache/" .. article.reviewId .. ".html"
        end,
    }
end

local Library = require("weread.ui.library")

local shown_lists = {}
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
    showList = function(_self, title, items, empty_text)
        shown_lists[#shown_lists + 1] = { title = title, items = items, empty = empty_text }
        return { switchItemTable = function() end }
    end,
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

-- 1. showShelfTabs shows Books and WeChat Articles
host:showShelfTabs()
expect(#shown_lists == 1, "showShelfTabs list count mismatch")
local tab_items = shown_lists[1].items
expect(#tab_items == 2, "shelf tab count mismatch")
expect(tab_items[1].text == "Books", "tab 1 mismatch")
expect(tab_items[2].text == "WeChat Articles", "tab 2 mismatch")

-- 2. showWeChatArticlesTab shows Floating and Favorites
shown_lists = {}
host:showWeChatArticlesTab()
expect(#shown_lists == 1, "showWeChatArticlesTab list count mismatch")
local wx_tabs = shown_lists[1].items
expect(#wx_tabs == 2, "wx tabs count mismatch")
expect(wx_tabs[1].text == "WeChat Floating Articles", "floating tab mismatch")
expect(wx_tabs[2].text == "WeChat Favorites", "favorites tab mismatch")

-- 3. showWeChatArticlesPage fetches remote if cache empty
shown_lists = {}
host:showWeChatArticlesPage(2)
expect(#shown_lists == 1, "article list page count mismatch")
local art_items = shown_lists[1].items
expect(#art_items == 3, "article items count mismatch (2 articles + 1 refresh item)")
expect(art_items[1].text == "Article 1", "article 1 title mismatch")
expect(art_items[2].text == "Cached Article", "cached article title mismatch")
expect(art_items[2].mandatory == "Cached", "cached badge mismatch")

-- 4. Clicking cached article opens directly
art_items[2].callback()
expect(#opened_files == 1 and opened_files[1] == "/cache/cached_1.html", "cached article open mismatch")

-- 5. Clicking uncached article downloads and opens
art_items[1].callback()
expect(#opened_files == 2 and opened_files[2] == "/cache/art_1.html", "uncached article download & open mismatch")
expect(updated_cache_paths["art_1"] == "/cache/art_1.html", "db cache path not updated")
expect(#reported_reads == 1 and reported_reads[1].article.reviewId == "art_1", "read status not reported")

if failures > 0 then
    error(string.format("%d checks failed in wechat_articles_ui_spec", failures))
end
print(string.format("wechat_articles_ui_spec: %d checks, 0 failure(s)", checks))

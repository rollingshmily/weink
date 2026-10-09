-- Regression lock for the store client surface added in 2.7.0.
--
-- Every assertion here mirrors a live-verified fact (i.weread.qq.com,
-- 2026-10-09). If the server contract changes, these fail loudly instead of
-- the storefront silently returning empty screens.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["ltn12"] = function()
    return { source = { string = function(value) return function() return value end end } }
end
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["socketutil"] = function()
    return {
        set_timeout = function() end,
        reset_timeout = function() end,
        table_sink = function(target)
            return function(chunk)
                if chunk then target[#target + 1] = chunk end
                return 1
            end
        end,
    }
end
package.preload["socket.http"] = function()
    return { request = function() return 1, 200, {}, "ok" end }
end
package.preload["weink.lib.protocol"] = function()
    return {
        USER_AGENT = "spec",
        urlencode = function(value) return tostring(value) end,
    }
end

local failures, checks = 0, 0
local current_test

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    fn()
end

-- Minimal Client stub: records each call, returns a canned body.
local calls
local Client = require("weink.lib.client")

local function stub_client()
    calls = {}
    local self = setmetatable({}, { __index = Client })
    self.eink_json = function(_self, path, params)
        calls[#calls + 1] = { method = "GET", path = path, params = params }
        return { ok = true }, 200
    end
    self.eink_post_json = function(_self, path, payload)
        calls[#calls + 1] = { method = "POST", path = path, params = payload }
        return { succ = 1 }, 200
    end
    return self
end

test("shelf writes send an array under bookIds", function()
    local client = stub_client()
    client:eink_shelf_add({ "123" })
    client:eink_shelf_delete({ "123" })
    client:eink_shelf_archive({ "123" })
    client:eink_shelf_delete_archive({ "123" })
    eq(#calls, 4, "four calls")
    for index, path in ipairs({ "/shelf/add", "/shelf/delete", "/shelf/archive",
                                "/shelf/deleteArchive" }) do
        eq(calls[index].method, "POST", "POST " .. path)
        eq(calls[index].path, path, path)
        eq(type(calls[index].params.bookIds), "table", path .. " uses an array")
        eq(calls[index].params.bookIds[1], "123", path .. " carries the id")
        eq(calls[index].params.bookId, nil, path .. " never sends a bare bookId")
    end
end)

test("scalar ids are still wrapped in an array", function()
    local client = stub_client()
    client:eink_shelf_add("123")
    eq(type(calls[1].params.bookIds), "table", "wrapped")
    eq(calls[1].params.bookIds[1], "123", "id kept")
end)

test("numeric ids are stringified and blanks dropped", function()
    local client = stub_client()
    client:eink_shelf_add({ 123, "", 456 })
    eq(#calls[1].params.bookIds, 2, "blanks dropped")
    eq(calls[1].params.bookIds[1], "123", "numeric id stringified")
    eq(calls[1].params.bookIds[2], "456", "later id kept")
end)

test("book infos is a POST with an id array", function()
    local client = stub_client()
    client:eink_book_infos({ "1", "2" })
    eq(calls[1].method, "POST", "POST only")
    eq(calls[1].path, "/book/infos", "path")
    eq(type(calls[1].params.bookIds), "table", "array, not a joined string")
end)

test("store home reads /store/list", function()
    local client = stub_client()
    client:store_home()
    eq(calls[1].path, "/store/list", "home feed")
end)

test("category browsing uses /store/categories then /store/category", function()
    local client = stub_client()
    client:store_category_node("100001")
    client:store_category_books("100001")
    eq(calls[1].path, "/store/categories", "node path")
    eq(calls[1].params.categoryId, "100001", "node id")
    eq(calls[2].path, "/store/category", "books path")
    eq(calls[2].params.maxIdx, nil, "no cursor on page 1")
end)

test("paging cursors are only sent once they are positive", function()
    local client = stub_client()
    client:search_store("word", 10, 0)
    client:search_store("word", 10, 10)
    client:store_category_books("100001", 10, nil)
    client:store_category_books("100001", 10, 10)
    client:book_similar("1", 5, nil)
    client:book_similar("1", 5, 10)
    eq(calls[1].params.maxIdx, nil, "search page 1")
    eq(calls[2].params.maxIdx, 10, "search page 2")
    eq(calls[3].params.maxIdx, nil, "category page 1")
    eq(calls[4].params.maxIdx, 10, "category page 2")
    eq(calls[5].params.maxIdx, nil, "similar page 1")
    eq(calls[6].params.maxIdx, 10, "similar page 2")
    eq(calls[5].params.count, 5, "similar accepts a count")
end)

test("search keeps the count and keyword the caller asked for", function()
    local client = stub_client()
    client:search_store("三体", 10, 10)
    eq(calls[1].path, "/store/search", "path")
    eq(calls[1].params.keyword, "三体", "keyword")
    eq(calls[1].params.count, 10, "count")
end)

test("ranking directory preserves server IDs and adds omitted novel totals", function()
    local client = stub_client()
    client.eink_json = function(_self, path, params)
        calls[#calls + 1] = { path = path, params = params }
        if params.ranklist then return { categories = { { CategoryId = "rising" }, { CategoryId = "future_chart" } } } end
        return { CategoryId = params.categoryId, title = params.categoryId }
    end
    local result = client:store_rankings()
    eq(calls[1].path, "/market/categories", "directory route")
    eq(calls[1].params.ranklist, 1, "APK directory switch")
    eq(calls[1].params.synckey, 0, "full directory")
    eq(calls[1].params.subtype, 0, "store subtype")
    eq(#result.categories, 4, "server IDs retained and two totals appended")
    eq(result.categories[2].CategoryId, "future_chart", "unknown future chart is preserved")
    eq(calls[2].params.categoryId, "novel_male", "male total metadata")
    eq(calls[3].params.categoryId, "novel_female", "female total metadata")
    eq(calls[2].params.rank, 1, "novel metadata uses rank=1")
    client.eink_json = function(_self, path, params)
        calls[#calls + 1] = { path = path, params = params }
        return { categories = { { CategoryId = "novel_male" }, { CategoryId = "novel_female" } } }
    end
    local before = #calls
    client:store_rankings()
    eq(#calls - before, 1, "novel totals already in the directory are not refetched")
end)

test("ranking paging always uses /market/category and rank=1", function()
    local client = stub_client()
    client:store_ranking_books("rising", 20, 0)
    client:store_ranking_books("rising", 20, 20)
    eq(calls[1].path, "/market/category", "ranking route")
    eq(calls[1].params.rank, 1, "not ordinary category order")
    eq(calls[1].params.synckey, 0, "full pages, not delta sync")
    eq(calls[1].params.maxIdx, 0, "initial cursor")
    eq(calls[2].params.maxIdx, 20, "continuation cursor")
    eq(calls[2].params.count, 20, "page size")
end)

print(string.format("client_store_spec: %d checks, %d failure(s)", checks, failures))
if failures > 0 then os.exit(1) end

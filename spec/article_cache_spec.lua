package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["libs/libkoreader-lfs"] = function() return require("lfs") end
package.preload["weread.lib.content"] = function()
    return {
        book_resolved_dir = function(_settings, _id, book) return book.cache_dir end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function(id) return tostring(id):match("^MP_WXS_") ~= nil end }
end

local ArticleCache = require("weread.lib.article_cache")
local lfs = require("lfs")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message) end
end
local function write(path, content)
    local file = assert(io.open(path, "wb"))
    file:write(content)
    file:close()
end

local root = os.tmpname() .. "-article-cache"
os.remove(root)
local settings = { meta_dir = root .. "/meta", cache_dir = root .. "/cache" }
local mp_dir = settings.meta_dir .. "/MP_WXS_1"
local asset_dir = mp_dir .. "/.weread-mp-article-assets"
local standalone = settings.cache_dir .. "/articles/account"
local legacy = root .. "/legacy/MP_WXS_2"
for _, dir in ipairs({ asset_dir, standalone, legacy, settings.meta_dir .. "/BOOK_1" }) do
    assert(os.execute("mkdir -p " .. string.format("%q", dir)) == 0)
end
write(mp_dir .. "/article.html", "article")
write(mp_dir .. "/mp_articles.json", "[]")
write(mp_dir .. "/thoughts.db", "notes")
write(asset_dir .. "/img.jpg", "image")
write(standalone .. "/new.html", "new")
write(legacy .. "/old.html", "old")
write(settings.meta_dir .. "/BOOK_1/book.html", "keep")
local outside = root .. "-outside"
assert(os.execute("mkdir -p " .. string.format("%q", outside)) == 0)
write(outside .. "/unrelated.html", "private")
assert(os.execute("ln -s " .. string.format("%q", outside) .. " "
    .. string.format("%q", settings.meta_dir .. "/MP_WXS_link")) == 0)

local snapshot = ArticleCache.snapshot(settings, {
    MP_WXS_2 = { cache_dir = legacy },
})
expect(snapshot.count == 5, "new and legacy article files were not all found")
expect(snapshot.size == 7 + 2 + 5 + 3 + 3, "article cache size mismatch")
local ok, err = ArticleCache.clear(snapshot, lfs)
expect(ok, "article cache cleanup failed: " .. tostring(err))
expect(lfs.attributes(mp_dir .. "/article.html") == nil, "MP article remains")
expect(lfs.attributes(asset_dir) == nil, "article image assets remain")
expect(lfs.attributes(standalone .. "/new.html") == nil, "standalone article remains")
expect(lfs.attributes(legacy .. "/old.html") == nil, "legacy article remains")
expect(lfs.attributes(mp_dir .. "/thoughts.db") ~= nil, "book thoughts were removed")
expect(lfs.attributes(settings.meta_dir .. "/BOOK_1/book.html") ~= nil,
    "non-article book content was removed")
expect(lfs.attributes(outside .. "/unrelated.html") ~= nil,
    "article cache cleanup followed a symlink outside its roots")

assert(os.execute("rm -rf " .. string.format("%q", root)) == 0)
assert(os.execute("rm -rf " .. string.format("%q", outside)) == 0)
print(("article_cache_spec: %d checks"):format(checks))

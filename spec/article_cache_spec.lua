package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["libs/libkoreader-lfs"] = function() return require("lfs") end
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
local settings = { data_dir = root .. "/data", meta_dir = root .. "/meta",
    cache_dir = root .. "/cache" }
local standalone = settings.data_dir .. "/articles/account"
local asset_dir = standalone .. "/.weread-article-assets"
for _, dir in ipairs({ asset_dir, settings.meta_dir .. "/BOOK_1",
        settings.cache_dir .. "/articles/old" }) do
    assert(os.execute("mkdir -p " .. string.format("%q", dir)) == 0)
end
write(asset_dir .. "/img.jpg", "image")
write(standalone .. "/new.html", "new")
write(settings.cache_dir .. "/articles/old/old.html", "old")
write(settings.meta_dir .. "/BOOK_1/book.html", "keep")
local outside = root .. "-outside"
assert(os.execute("mkdir -p " .. string.format("%q", outside)) == 0)
write(outside .. "/unrelated.html", "private")
assert(os.execute("ln -s " .. string.format("%q", outside) .. " "
    .. string.format("%q", standalone .. "/external-link")) == 0)

local snapshot = ArticleCache.snapshot(settings, {})
expect(snapshot.count == 3, "current article files were not found")
expect(snapshot.size == 5 + 3, "article cache size mismatch")
local ok, err = ArticleCache.clear(snapshot, lfs)
expect(ok, "article cache cleanup failed: " .. tostring(err))
expect(lfs.attributes(asset_dir) == nil, "article image assets remain")
expect(lfs.attributes(standalone .. "/new.html") == nil, "standalone article remains")
expect(lfs.attributes(settings.cache_dir .. "/articles/old/old.html") ~= nil,
    "article cleanup touched a different storage root")
expect(lfs.attributes(settings.meta_dir .. "/BOOK_1/book.html") ~= nil,
    "non-article book content was removed")
expect(lfs.attributes(outside .. "/unrelated.html") ~= nil,
    "article cache cleanup followed a symlink outside its root")

assert(os.execute("rm -rf " .. string.format("%q", root)) == 0)
assert(os.execute("rm -rf " .. string.format("%q", outside)) == 0)
print(("article_cache_spec: %d checks"):format(checks))

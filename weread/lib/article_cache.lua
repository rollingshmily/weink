-- Inventory and remove plugin-owned standalone WeChat article files.
-- Keep book catalogs, thoughts and other sidecars in MP_WXS_ directories.

local Content = require("weread.lib.content")
local WeRead = require("weread.lib.protocol")

local ArticleCache = {}

local function filesystem()
    return require("libs/libkoreader-lfs")
end

local function normalized(path)
    if type(path) ~= "string" or path == "" or path == "/" then return nil end
    return path:gsub("/+$", "")
end

local function attributes(fs, path)
    if type(fs.symlinkattributes) == "function" then
        return fs.symlinkattributes(path)
    end
    return fs.attributes(path)
end

local function children(fs, path)
    local ok, iter, dir = pcall(fs.dir, path)
    if not ok then return function() return nil end end
    return function()
        while true do
            local name = iter(dir)
            if not name then return nil end
            if name ~= "." and name ~= ".." then return name end
        end
    end
end

function ArticleCache.snapshot(settings, books, fs)
    fs = fs or filesystem()
    local roots, seen_roots = {}, {}
    local function add_root(path)
        path = normalized(path)
        local attr = path and attributes(fs, path)
        if path and not seen_roots[path] and attr and attr.mode == "directory" then
            seen_roots[path] = true
            roots[#roots + 1] = path
        end
    end

    local meta_root = normalized(settings.meta_dir)
    if meta_root then
        for name in children(fs, meta_root) do
            if name:match("^MP_WXS_") then add_root(meta_root .. "/" .. name) end
        end
    end
    if type(settings.cache_dir) == "string" then
        add_root(settings.cache_dir .. "/articles")
    end
    if type(settings.data_dir) == "string" then
        add_root(settings.data_dir .. "/articles")
    end
    for book_id, book in pairs(books or {}) do
        if WeRead.is_mp_book(book_id) then
            add_root(Content.book_resolved_dir(settings, book_id, book))
        end
    end

    local files, dirs, seen_files = {}, {}, {}
    local total_size = 0
    local function add_file(path, attr)
        if seen_files[path] then return end
        seen_files[path] = true
        files[#files + 1] = path
        total_size = total_size + (attr.size or 0)
    end
    local function walk(path, in_assets)
        for name in children(fs, path) do
            local child = path .. "/" .. name
            local attr = attributes(fs, child)
            if attr and attr.mode == "directory" then
                local assets = in_assets or name:match("^%.weread%-mp%-.*%-assets$") ~= nil
                walk(child, assets)
                if assets then dirs[#dirs + 1] = child end
            elseif attr and attr.mode == "file" then
                if in_assets or name:match("%.html$") or name:match("%.epub$")
                    or name == "mp_articles.json" then
                    add_file(child, attr)
                end
            end
        end
    end
    for _, root in ipairs(roots) do walk(root, false) end
    table.sort(dirs, function(a, b) return #a > #b end)
    return { files = files, dirs = dirs, size = total_size, count = #files }
end

function ArticleCache.clear(snapshot, fs)
    fs = fs or filesystem()
    local errors = {}
    for _, path in ipairs(snapshot.files or {}) do
        local ok, err = os.remove(path)
        if not ok then errors[#errors + 1] = path .. ": " .. tostring(err) end
    end
    for _, path in ipairs(snapshot.dirs or {}) do
        local attr = attributes(fs, path)
        if attr and attr.mode == "directory" then
            local ok, err = fs.rmdir(path)
            if not ok then errors[#errors + 1] = path .. ": " .. tostring(err) end
        end
    end
    return #errors == 0, table.concat(errors, "\n")
end

return ArticleCache

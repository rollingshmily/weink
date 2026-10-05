-- Inventory and remove only files owned by the current WeChat article cache.

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

function ArticleCache.snapshot(settings, _books, fs)
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

    local root = settings.data_dir or settings.cache_dir
    if type(root) == "string" then add_root(root .. "/articles") end

    local files, dirs, seen_files = {}, {}, {}
    local total_size = 0
    local function add_file(path, attr)
        if seen_files[path] then return end
        seen_files[path] = true
        files[#files + 1] = path
        total_size = total_size + (attr.size or 0)
    end
    local function walk(path)
        for name in children(fs, path) do
            local child = path .. "/" .. name
            local attr = attributes(fs, child)
            if attr and attr.mode == "directory" then
                walk(child)
                dirs[#dirs + 1] = child
            elseif attr and attr.mode == "file" then
                add_file(child, attr)
            elseif attr and attr.mode == "link" then
                add_file(child, { size = 0 })
            end
        end
    end
    for _, path in ipairs(roots) do walk(path) end
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

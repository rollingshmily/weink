local Crypto = require("weink.lib.crypto")
local Eink = require("weink.lib.eink")
local WeRead = require("weink.lib.protocol")
local Thoughts = require("weink.lib.thoughts")
local logger = require("weink.lib.logger")
local Checkpoint = require("weink.lib.download_checkpoint")

local Content = {}

local function basename_safe(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    if value == "" then
        value = "weread"
    end
    return value
end

local function filename_safe(value)
    value = tostring(value or ""):gsub("[%z%c/\\:%*%?\"<>|]", "_")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    value = value:gsub("%s+", " ")
    if value == "" then
        value = "weread"
    end
    return value
end

local function path_dirname(path)
    if type(path) == "string" then
        return path:match("^(.*)/[^/]+$")
    end
end

local function path_exists(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    file:close()
    return true
end

local function ensure_directory(path)
    if type(path) ~= "string" or path == "" then
        return
    end
    os.execute("mkdir -p " .. string.format("%q", path))
end

-- Directory name a book is stored under (sanitized book id). Exposed so the
-- local-cache scanner can match on-disk directory names against shelf book ids.
function Content.book_dir_name(book_id)
    return basename_safe(book_id)
end

-- Flat library root for EPUB content files (user-facing book library).
function Content.book_content_dir(settings)
    return settings.cache_dir
end

-- Canonical per-book sidecar root: catalog/thoughts/metadata/MP html.
-- Always keyed by bookId under settings.meta_dir so content and metadata stay
-- linked even when EPUBs are flat title-named files in the book library.
function Content.book_meta_dir(settings, book_id)
    local root = settings.meta_dir
    if type(root) ~= "string" or root == "" then
        root = (settings.data_dir or settings.cache_dir) .. "/meta"
    end
    return tostring(root):gsub("/+$", "") .. "/" .. Content.book_dir_name(book_id)
end

local function looks_like_book_id_dir(dir, book_id)
    if type(dir) ~= "string" or dir == "" then
        return false
    end
    return dir:match("([^/]+)$") == Content.book_dir_name(book_id)
end

local function dir_has_sidecar(dir)
    if type(dir) ~= "string" or dir == "" then
        return false
    end
    return path_exists(dir .. "/catalog.json")
        or path_exists(dir .. "/thoughts.db")
        or path_exists(dir .. "/metadata.json")
        or path_exists(dir .. "/reading_state.json")
        or path_exists(dir .. "/articles.json")
end

-- Resolve sidecar directory for thoughts/catalog/metadata/MP articles.
-- Priority:
--   1) explicit book.cache_dir when it still holds sidecars (or is the canonical meta path)
--   2) legacy combined layout: parent of cached_file/chapter when parent is <bookId>
--   3) canonical meta_dir/<bookId>
-- Never treat the flat library root (parent of title.epub) as a sidecar dir.
function Content.book_resolved_dir(settings, book_id, book)
    local canonical = Content.book_meta_dir(settings, book_id)
    if book and type(book.cache_dir) == "string" and book.cache_dir ~= "" then
        local pinned = book.cache_dir:gsub("/+$", "")
        -- Trust only the canonical meta path or a directory that already holds
        -- real sidecars. A bare bookId-named empty folder (e.g. leftover under
        -- the library root) must NOT pin future writes.
        if pinned == canonical or dir_has_sidecar(pinned) then
            return pinned
        end
    end

    local dir = book and path_dirname(book.cached_full_book or book.cached_file)
    if looks_like_book_id_dir(dir, book_id) and dir_has_sidecar(dir) then
        return dir
    end
    if book and type(book.cached_chapters) == "table" then
        for _i, chapter_path in pairs(book.cached_chapters) do
            dir = path_dirname(chapter_path)
            if looks_like_book_id_dir(dir, book_id) and dir_has_sidecar(dir) then
                return dir
            end
        end
    end
    return canonical
end

-- Pin and ensure the sidecar directory used by index/catalog/thoughts.
function Content.ensure_book_meta_dir(settings, book_id, book)
    local dir = Content.book_meta_dir(settings, book_id)
    ensure_directory(dir)
    if book then
        book.cache_dir = dir
        book.book_id = book.book_id or book.bookId or tostring(book_id)
    end
    return dir
end

-- Choose a flat EPUB path under the book library root.
-- Prefer a readable title-based name; disambiguate with bookId on collision.
function Content.book_content_epub_path(settings, book, suffix)
    local content_dir = Content.book_content_dir(settings)
    ensure_directory(content_dir)
    local book_id = book and (book.book_id or book.bookId) or "weread"
    local book_title = (book and book.title) or "WeRead"
    local label = book_title
    if suffix and suffix ~= "" and suffix ~= "book" then
        label = book_title .. " - " .. suffix
    end
    local preferred_name = filename_safe(label) .. ".epub"
    local preferred = content_dir .. "/" .. preferred_name
    local current = book and book.cached_file
    if type(current) == "string" and current == preferred then
        return preferred
    end
    if path_exists(preferred) then
        if type(current) ~= "string" or current ~= preferred then
            return content_dir .. "/" .. filename_safe(label .. " [" .. tostring(book_id) .. "]") .. ".epub"
        end
    end
    return preferred
end

-- Delete plugin-owned files for one book: sidecar directory + recorded content
-- files. Never rm -rf the library/meta roots themselves.
function Content.remove_book_files(settings, book_id, book)
    local meta_dir = Content.book_resolved_dir(settings, book_id, book)
    local download_root = type(settings.cache_dir) == "string" and settings.cache_dir:gsub("/+$", "") or nil
    local meta_root = type(settings.meta_dir) == "string" and settings.meta_dir:gsub("/+$", "") or nil
    local meta_norm = type(meta_dir) == "string" and meta_dir:gsub("/+$", "") or nil

    if meta_norm and meta_norm ~= "" and meta_norm ~= download_root and meta_norm ~= meta_root then
        os.execute("rm -rf " .. string.format("%q", meta_norm))
    end

    local function maybe_remove_file(path)
        if type(path) ~= "string" or path == "" then
            return
        end
        if meta_norm and (path == meta_norm or path:sub(1, #meta_norm + 1) == meta_norm .. "/") then
            return
        end
        if path == download_root or path == meta_root then
            return
        end
        os.remove(path)
    end

    if type(book) == "table" then
        maybe_remove_file(book.cached_file)
        if type(book.cached_chapters) == "table" then
            for _uid, chapter_path in pairs(book.cached_chapters) do
                maybe_remove_file(chapter_path)
            end
        end
    end
end

function Content.catalog_cache_path(settings, book)
    local book_id = book and (book.book_id or book.bookId)
    if not book_id then
        return nil
    end
    return Content.book_resolved_dir(settings, book_id, book) .. "/catalog.json"
end

function Content.save_catalog_cache(client, settings, book, chapters)
    if type(chapters) ~= "table" then
        return false, "chapter list is not a table"
    end
    local path = Content.catalog_cache_path(settings, book)
    if not path then
        return false, "missing book id"
    end
    local dir = path:match("^(.*)/[^/]+$")
    os.execute("mkdir -p " .. string.format("%q", dir))
    local ok, encoded = pcall(function()
        return client:json_encode({
            version = 1,
            updated_at = os.time(),
            chapters = chapters,
        })
    end)
    if not ok then
        return false, encoded
    end
    local tmp_path = path .. ".tmp"
    local file, err = io.open(tmp_path, "wb")
    if not file then
        return false, err
    end
    local write_ok, write_err = file:write(encoded)
    file:close()
    if not write_ok then
        os.remove(tmp_path)
        return false, write_err
    end
    local rename_ok, rename_err = os.rename(tmp_path, path)
    if not rename_ok then
        os.remove(tmp_path)
        return false, rename_err
    end
    if book then
        book.cache_dir = dir
    end
    return true, path
end

function Content.load_catalog_cache(client, settings, book)
    local path = Content.catalog_cache_path(settings, book)
    if not path then
        return nil
    end
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local encoded = file:read("*a")
    file:close()
    local ok, decoded = pcall(function()
        return client:json_decode(encoded)
    end)
    if not ok or type(decoded) ~= "table" then
        logger.warn("ignore invalid catalog cache:", path)
        return nil
    end
    local chapters = decoded.chapters
    if type(chapters) ~= "table" then
        return nil
    end
    book.chapters = chapters
    return chapters
end

local function item_id(prefix, value)
    return prefix .. basename_safe(value):gsub("%.", "_")
end

local function utc_modified()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function media_type_for(data)
    if data:sub(1, 8) == "\137PNG\r\n\026\n" then
        return ".png", "image/png"
    elseif data:sub(1, 3) == "\255\216\255" then
        return ".jpg", "image/jpeg"
    elseif data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
        return ".gif", "image/gif"
    elseif data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return ".webp", "image/webp"
    end
    return ".bin", "application/octet-stream"
end

local function media_type_for_file(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, nil, err end
    local head = file:read(12) or ""
    file:close()
    return media_type_for(head)
end

local function trim_nulls(value)
    return tostring(value or ""):gsub("%z.*$", ""):gsub("%s+$", "")
end

local function tar_entries(data)
    local entries = {}
    local offset = 1
    while offset + 511 <= #data do
        local header = data:sub(offset, offset + 511)
        if header:match("^%z+$") then
            break
        end
        local name = trim_nulls(header:sub(1, 100))
        local size_text = trim_nulls(header:sub(125, 136)):gsub("%s", "")
        local size = tonumber(size_text, 8) or 0
        local typeflag = header:sub(157, 157)
        local body_start = offset + 512
        local body_end = body_start + size - 1
        if name ~= "" and (typeflag == "0" or typeflag == "" or typeflag == "\0") and size > 0 then
            table.insert(entries, {
                name = name,
                data = data:sub(body_start, body_end),
            })
        end
        offset = body_start + math.ceil(size / 512) * 512
    end
    return entries
end

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

local function unique_asset_name(used, name, ext)
    local base = filename_safe(name)
    if not base:lower():match(ext:gsub("%.", "%%.") .. "$") then
        base = base .. ext
    end
    local candidate = base
    local index = 2
    while used[candidate] do
        local stem = base:gsub("%.[^%.]+$", "")
        candidate = stem .. "-" .. tostring(index) .. ext
        index = index + 1
    end
    used[candidate] = true
    return candidate
end

local function write_file(path, data)
    local file, err = io.open(path, "wb")
    if not file then
        error(err)
    end
    file:write(data)
    file:close()
end

local function make_path(path)
    local ok, util = pcall(require, "util")
    if ok and util and util.makePath then
        local made, err = util.makePath(path)
        if not made then error(err or ("could not create directory: " .. path)) end
        return
    end
    local result = os.execute("mkdir -p " .. string.format("%q", path))
    if result ~= true and result ~= 0 then
        error("could not create directory: " .. path)
    end
end

local function remove_tree(path)
    if type(path) ~= "string"
        or not path:match("/%.weread%-download%-%d+%-%d+$") then
        return nil, "refusing to remove an invalid download workspace"
    end
    local ok, purge_util = pcall(require, "ffi/util")
    if not ok or not purge_util or not purge_util.purgeDir then
        return nil, "directory cleanup unavailable"
    end
    local called, removed, err = pcall(purge_util.purgeDir, path)
    if not called then return nil, removed end
    if removed == false then return nil, err end
    return true
end

function Content.create_download_workspace(settings, book)
    local book_id = book.book_id or book.bookId
    local book_dir = Content.book_resolved_dir(settings, book_id, book)
    make_path(book_dir)
    book.cache_dir = book_dir
    local workspace = string.format("%s/.weread-download-%d-%d",
        book_dir, os.time(), math.random(100000, 999999))
    local incoming_dir = workspace .. "/incoming"
    local asset_dir = workspace .. "/images"
    make_path(incoming_dir)
    make_path(asset_dir)
    return {
        path = workspace,
        incoming_dir = incoming_dir,
        asset_dir = asset_dir,
    }
end

function Content.cleanup_download_workspace(workspace)
    local path = type(workspace) == "table" and workspace.path or workspace
    if not path then return true end
    local ok, err = remove_tree(path)
    if not ok then
        logger.warn("download workspace cleanup failed:", tostring(err))
    end
    return ok, err
end

function Content.cleanup_stale_downloads(settings)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs or not lfs then return 0 end
    local dirs = {}
    -- Full-book EPUBs and their atomic .part/.weread-backup files live in the
    -- flat user-facing library root in this fork, while staged assets live in
    -- each book's sidecar directory. Scan both locations during recovery.
    local content_dir = Content.book_content_dir(settings)
    if type(content_dir) == "string" and content_dir ~= "" then
        dirs[content_dir:gsub("/+$", "")] = true
    end
    for book_id, book in pairs(settings:get("books", {}) or {}) do
        local dir = Content.book_resolved_dir(settings, book_id, book)
        if type(dir) == "string" and dir ~= "" then
            dirs[dir:gsub("/+$", "")] = true
        end
    end
    local function has_resume_checkpoint(workspace_path)
        for book_id, book in pairs(settings:get("books", {}) or {}) do
            local checkpoint_path = Checkpoint.path(settings, book_id)
            local file = io.open(checkpoint_path, "rb")
            local encoded = file and file:read("*a")
            if file then file:close() end
            if encoded and encoded:find(workspace_path, 1, true) then
                return true
            end
        end
        return false
    end
    local removed = 0
    for dir in pairs(dirs) do
        if lfs.attributes(dir, "mode") == "directory" then
            for name in lfs.dir(dir) do
                if name:match("^%.weread%-download%-%d+%-%d+$") then
                    local candidate = dir .. "/" .. name
                    if not has_resume_checkpoint(candidate) then
                        local cleaned = remove_tree(candidate)
                        if cleaned then removed = removed + 1 end
                    end
                elseif name:match("^%.weread%-download%-build%-%d+%-%d+$") then
                    local cleaned = remove_tree(dir .. "/" .. name)
                    if cleaned then removed = removed + 1 end
                elseif name:match("%.epub%.part$") then
                    if os.remove(dir .. "/" .. name) then removed = removed + 1 end
                elseif name:match("%.epub%.weread%-backup$") then
                    local backup = dir .. "/" .. name
                    local final = backup:gsub("%.weread%-backup$", "")
                    local current = io.open(final, "rb")
                    if current then
                        current:close()
                        if os.remove(backup) then removed = removed + 1 end
                    elseif os.rename(backup, final) then
                        removed = removed + 1
                    end
                end
            end
        end
    end
    return removed
end

local function commit_file(part_path, path)
    local renamed, rename_err = os.rename(part_path, path)
    if renamed then return true end
    local old = io.open(path, "rb")
    if not old then return nil, rename_err end
    old:close()
    local backup = path .. ".weread-backup"
    pcall(os.remove, backup)
    local backed_up, backup_err = os.rename(path, backup)
    if not backed_up then return nil, backup_err or rename_err end
    renamed, rename_err = os.rename(part_path, path)
    if not renamed then
        os.rename(backup, path)
        return nil, rename_err
    end
    pcall(os.remove, backup)
    return true
end

local function write_epub(path, entries)
    local Archiver = require("ffi/archiver")
    local archive = Archiver.Writer:new{}
    local part_path = path .. ".part"
    pcall(os.remove, part_path)
    if not archive:open(part_path, "epub") then
        error("failed to open archive for writing: " .. tostring(archive.err))
    end
    local mtime = os.time()
    local ok, err = xpcall(function()
        assert(archive:setZipCompression("store"), archive.err)
        local mimetype_data = "application/epub+zip"
        for _, entry in ipairs(entries) do
            if entry.name == "mimetype" then
                mimetype_data = entry.data
                break
            end
        end
        assert(archive:addFileFromMemory("mimetype", mimetype_data, mtime), archive.err)
        assert(archive:setZipCompression("deflate"), archive.err)
        for _, entry in ipairs(entries) do
            if entry.name ~= "mimetype" then
                local added
                if entry.path then
                    added = archive:addPath(
                        entry.name, entry.path, entry.recursive == true, mtime)
                    -- KOReader's current Writer:addPath() returns false after
                    -- a successful walk because its terminal status is EOF,
                    -- while leaving err unset. A real libarchive failure sets
                    -- err, so accept only this error-free EOF case.
                    if not added and archive.err == nil then added = true end
                else
                    added = archive:addFileFromMemory(entry.name, entry.data or "", mtime)
                end
                assert(added, archive.err or ("failed to add " .. entry.name))
            end
        end
    end, debug.traceback)
    pcall(function() archive:close() end)
    if not ok then
        pcall(os.remove, part_path)
        error(err, 0)
    end
    local committed, commit_err = commit_file(part_path, path)
    if not committed then
        pcall(os.remove, part_path)
        error(commit_err or "failed to commit EPUB", 0)
    end
end

local function image_href(workspace, filename)
    local prefix = workspace and workspace.asset_prefix
    if prefix and prefix ~= "" then
        return "images/" .. prefix .. "/" .. filename
    end
    return "images/" .. filename
end

local function append_asset_entries(entries, assets)
    local disk_dirs = {}
    for _, asset in ipairs(assets or {}) do
        if asset.path then
            local parent = asset.path:match("^(.*)/[^/]+$")
            if not parent then
                error("invalid file-backed asset path: " .. tostring(asset.path))
            end
            local virtual_dir = asset.href:match("^(.*)/[^/]+$") or "images"
            if disk_dirs[virtual_dir] and disk_dirs[virtual_dir] ~= parent then
                error("file-backed EPUB assets must share one directory per virtual path")
            end
            disk_dirs[virtual_dir] = parent
        else
            table.insert(entries, {
                name = "OEBPS/" .. asset.href,
                data = asset.data,
                store = asset.store,
            })
        end
    end
    for virtual_dir, disk_dir in pairs(disk_dirs) do
        table.insert(entries, {
            name = "OEBPS/" .. virtual_dir,
            path = disk_dir,
            recursive = true,
        })
    end
end

local function xml_escape(value)
    value = tostring(value or "")
    -- XML 1.0 permits tabs, newlines, and carriage returns from the C0 range,
    -- but rejects the remaining control characters. Book metadata comes from
    -- remote APIs, so remove those bytes before embedding it in the OPF.
    value = value:gsub("[%z\1-\8\11\12\14-\31]", "")
    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    value = value:gsub("\"", "&quot;")
    return value
end

-- WeRead EPUB chapters may decode to multiple concatenated XHTML documents.
-- The first <body> is often a title shell; main content lives in later bodies.
local function body_fragment(xhtml)
    xhtml = tostring(xhtml or "")
    local bodies = {}
    local remaining = xhtml
    while remaining ~= "" do
        local body_start = remaining:find("<body", 1, true)
        if not body_start then
            break
        end
        local body_open_end = remaining:find(">", body_start, true)
        if not body_open_end then
            break
        end
        local body_close = remaining:find("</body>", body_open_end, true)
        if not body_close then
            bodies[#bodies + 1] = remaining:sub(body_open_end + 1)
            break
        end
        bodies[#bodies + 1] = remaining:sub(body_open_end + 1, body_close - 1)
        remaining = remaining:sub(body_close + 7)
    end
    if #bodies > 0 then
        return table.concat(bodies, "\n")
    end
    xhtml = xhtml:gsub("<%?xml.-%?>", "")
    xhtml = xhtml:gsub("<!DOCTYPE.-%>", "")
    return xhtml
end

function Content.normalize_chapters(payload, book_id)
    local records = payload
    if type(payload) == "table" and payload.data then
        records = payload.data
    end
    if type(records) ~= "table" then
        return {}
    end
    if records.bookId or records.updated then
        records = { records }
    end
    for record_index, record in ipairs(records) do
        if tostring(record.bookId or "") == tostring(book_id) then
            return record.updated or record.chapterInfos or record.chapters or {}
        end
    end
    return {}
end

function Content.first_readable_chapter(chapters)
    for chapter_index, chapter in ipairs(chapters or {}) do
        if tonumber(chapter.wordCount or 0) > 0 and tostring(chapter.title or "") ~= "封面" then
            return chapter
        end
    end
end

function Content.readable_chapters(chapters)
    local out = {}
    for chapter_index, chapter in ipairs(chapters or {}) do
        if tonumber(chapter.wordCount or 0) > 0 and tostring(chapter.title or "") ~= "封面" then
            table.insert(out, chapter)
        end
    end
    return out
end

local function chapter_level(chapter)
    local level = tonumber(chapter and chapter.level or 1) or 1
    if level < 1 then
        level = 1
    elseif level > 6 then
        level = 6
    end
    return level
end

local function build_chapter_tree(chapters, filename_for)
    local root = { children = {} }
    local stack = { root }
    for chapter_index, chapter in ipairs(chapters or {}) do
        local level = chapter_level(chapter)
        if level > #stack then
            level = #stack
        end
        while #stack > level do
            table.remove(stack)
        end
        local parent = stack[#stack] or root
        local node = {
            title = chapter.title or ("Chapter " .. tostring(chapter.chapterUid or chapter_index)),
            href = filename_for(chapter_index, chapter),
            children = {},
        }
        table.insert(parent.children, node)
        stack[level + 1] = node
    end
    return root.children
end

local function build_nav_items(chapters, filename_for)
    local tree = build_chapter_tree(chapters, filename_for)
    local function render(nodes)
        local out = {}
        for node_index, node in ipairs(nodes or {}) do
            table.insert(out, [[<li><a href="]] .. xml_escape(node.href) .. [[">]] .. xml_escape(node.title) .. [[</a>]])
            if node.children and #node.children > 0 then
                table.insert(out, "<ol>")
                table.insert(out, render(node.children))
                table.insert(out, "</ol>")
            end
            table.insert(out, "</li>")
        end
        return table.concat(out, "\n")
    end

    return render(tree)
end

local function build_ncx_points(chapters, filename_for)
    local tree = build_chapter_tree(chapters, filename_for)
    local play_order = 0
    local function render(nodes)
        local out = {}
        for node_index, node in ipairs(nodes or {}) do
            play_order = play_order + 1
            local current_order = play_order
            table.insert(out, [[<navPoint id="navPoint-]] .. tostring(current_order) .. [[" playOrder="]] .. tostring(current_order) .. [[">]])
            table.insert(out, [[<navLabel><text>]] .. xml_escape(node.title) .. [[</text></navLabel>]])
            table.insert(out, [[<content src="]] .. xml_escape(node.href) .. [["/>]])
            if node.children and #node.children > 0 then
                table.insert(out, render(node.children))
            end
            table.insert(out, "</navPoint>")
        end
        return table.concat(out, "\n")
    end
    return render(tree), play_order
end

function Content.save_chapter_epub(settings, book, chapter, xhtml, assets, css)
    local book_id = book.book_id or book.bookId
    Content.ensure_book_meta_dir(settings, book_id, book)
    local book_title = book.title or "WeRead"
    local chapter_label = chapter.title or tostring(chapter.chapterUid or "chapter")
    local path = Content.book_content_epub_path(settings, book, chapter_label)
    local title = chapter.title or book.title or "WeRead"
    local author = book.author or "WeRead"
    local manifest_assets = {}
    for asset_index, asset in ipairs(assets or {}) do
        table.insert(manifest_assets, [[<item id="asset_]] .. tostring(asset_index) .. [[" href="]] .. xml_escape(asset.href) .. [[" media-type="]] .. xml_escape(asset.media_type) .. [["/>]])
    end
    local chapter_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
<head>
<title>]] .. xml_escape(title) .. [[</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body>
]] .. body_fragment(xhtml) .. [[
</body>
</html>]]
    local opf = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">weread-]] .. xml_escape(book_id) .. [[-]] .. xml_escape(chapter.chapterUid or "chapter") .. [[</dc:identifier>
<dc:title>]] .. xml_escape(book_title) .. [[</dc:title>
<dc:creator>]] .. xml_escape(author) .. [[</dc:creator>
<dc:publisher>WeRead</dc:publisher>
<dc:source>]] .. xml_escape(WeRead.reader_url(book_id, chapter.chapterUid)) .. [[</dc:source>
<dc:language>zh-CN</dc:language>
<meta property="dcterms:modified">]] .. utc_modified() .. [[</meta>
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
<item id="style" href="style.css" media-type="text/css"/>
<item id="chapter" href="text/chapter.xhtml" media-type="application/xhtml+xml"/>
]] .. table.concat(manifest_assets, "\n") .. [[
</manifest>
<spine>
<itemref idref="chapter"/>
</spine>
</package>]]
    local nav = [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Navigation</title></head>
<body>
<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
<ol><li><a href="text/chapter.xhtml">]] .. xml_escape(title) .. [[</a></li></ol>
</nav>
</body>
</html>]]
    css = css or [[body { line-height: 1.7; margin: 5%; } img { max-width: 100%; }]]
    local entries = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]] },
        { name = "OEBPS/content.opf", data = opf },
        { name = "OEBPS/nav.xhtml", data = nav },
        { name = "OEBPS/style.css", data = css },
        { name = "OEBPS/text/chapter.xhtml", data = chapter_xhtml },
    }
    append_asset_entries(entries, assets)
    write_epub(path, entries)
    return path
end

function Content.save_book_epub_from_files(settings, book, chapters, body_files,
    assets, css, cover_data)
    local book_id = book.book_id or book.bookId
    Content.ensure_book_meta_dir(settings, book_id, book)
    local book_title = book.title or "WeRead"
    local path = Content.book_content_epub_path(settings, book, "full")
    local author = book.author or "WeRead"
    local root = Content.book_resolved_dir(settings, book_id, book)
        .. string.format("/.weread-download-build-%d-%d", os.time(), math.random(100000, 999999))
    local text_dir = root .. "/text"
    make_path(text_dir)

    local function cleanup()
        local ok, purge_util = pcall(require, "ffi/util")
        if ok and purge_util and purge_util.purgeDir then
            pcall(purge_util.purgeDir, root)
        else
            os.execute("rm -rf " .. string.format("%q", root))
        end
    end
    local function read_text(file_path)
        local file, err = io.open(file_path, "rb")
        if not file then error(err or ("missing chapter file: " .. tostring(file_path))) end
        local text = file:read("*a")
        file:close()
        return text
    end
    local function write_text(file_path, text)
        local file, err = io.open(file_path, "wb")
        if not file then error(err or ("could not write: " .. file_path)) end
        local ok, write_err = file:write(text)
        file:close()
        if not ok then error(write_err or ("could not write: " .. file_path)) end
    end

    local manifest_items = {
        [[<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>]],
        [[<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>]],
        [[<item id="style" href="style.css" media-type="text/css"/>]],
    }
    local spine_items = {}
    local entries = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]] },
    }
    local cover_meta = ""
    if cover_data and #cover_data > 0 then
        local ext, mime = media_type_for(cover_data)
        local cover_img_href = "images/cover" .. ext
        table.insert(entries, { name = "OEBPS/" .. cover_img_href, data = cover_data })
        table.insert(manifest_items, [[<item id="cover-image" href="]] .. cover_img_href .. [[" media-type="]] .. mime .. [[" properties="cover-image"/>]])
        table.insert(manifest_items, [[<item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>]])
        table.insert(spine_items, [[<itemref idref="cover"/>]])
        write_text(text_dir .. "/cover.xhtml", [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head><title>Cover</title><style>html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;}img{display:block;width:100%;height:100%;object-fit:contain;}</style></head>
<body><img src="../]] .. cover_img_href .. [[" alt="Cover"/></body>
</html>]])
        cover_meta = [[
<meta name="cover" content="cover-image"/>]]
    end

    for asset_index, asset in ipairs(assets or {}) do
        table.insert(manifest_items, [[<item id="asset_]] .. tostring(asset_index) .. [[" href="]] .. xml_escape(asset.href) .. [[" media-type="]] .. xml_escape(asset.media_type) .. [["/>]])
    end
    append_asset_entries(entries, assets)

    for chapter_index, chapter in ipairs(chapters or {}) do
        local uid = tostring(chapter.chapterUid or chapter_index)
        local filename = string.format("chapter-%03d.xhtml", chapter_index)
        local id = item_id("chapter_", uid)
        local title = chapter.title or ("Chapter " .. uid)
        local source_path = body_files and body_files[uid]
        if not source_path then
            error("missing checkpoint path for chapter " .. uid)
        end
        local chapter_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
<head><title>]] .. xml_escape(title) .. [[</title><link rel="stylesheet" type="text/css" href="../style.css"/></head>
<body>
]] .. body_fragment(read_text(source_path)) .. [[
</body>
</html>]]
        write_text(text_dir .. "/" .. filename, chapter_xhtml)
        table.insert(manifest_items, [[<item id="]] .. id .. [[" href="text/]] .. filename .. [[" media-type="application/xhtml+xml"/>]])
        table.insert(spine_items, [[<itemref idref="]] .. id .. [["/>]])
    end

    local opf = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">weread-]] .. xml_escape(book_id) .. [[-full</dc:identifier>
<dc:title>]] .. xml_escape(book_title) .. [[</dc:title>
<dc:creator>]] .. xml_escape(author) .. [[</dc:creator>
<dc:publisher>WeRead</dc:publisher>
<dc:source>]] .. xml_escape(WeRead.reader_url(book_id)) .. [[</dc:source>
<dc:language>zh-CN</dc:language>
<meta property="dcterms:modified">]] .. utc_modified() .. [[</meta>]] .. cover_meta .. [[
</metadata>
<manifest>
]] .. table.concat(manifest_items, "\n") .. [[
</manifest>
<spine toc="toc">
]] .. table.concat(spine_items, "\n") .. [[
</spine>
</package>]]
    local ncx_points = build_ncx_points(chapters, function(chapter_index)
        return "text/" .. string.format("chapter-%03d.xhtml", chapter_index)
    end)
    local ncx = [[<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head><meta name="dtb:uid" content="weread-]] .. xml_escape(book_id) .. [[-full"/><meta name="dtb:depth" content="6"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head>
<docTitle><text>]] .. xml_escape(book_title) .. [[</text></docTitle><navMap>
]] .. ncx_points .. [[
</navMap></ncx>]]
    local nav = [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Navigation</title></head><body><nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops"><ol>
]] .. build_nav_items(chapters, function(chapter_index)
        return "text/" .. string.format("chapter-%03d.xhtml", chapter_index)
    end) .. [[
</ol></nav></body></html>]]
    css = css or [[body { line-height: 1.7; margin: 5%; } img { max-width: 100%; }]]
    table.insert(entries, { name = "OEBPS/content.opf", data = opf })
    table.insert(entries, { name = "OEBPS/nav.xhtml", data = nav })
    table.insert(entries, { name = "OEBPS/toc.ncx", data = ncx })
    table.insert(entries, { name = "OEBPS/style.css", data = css })
    table.insert(entries, { name = "OEBPS/text", path = text_dir, recursive = true })

    local ok, err = pcall(write_epub, path, entries)
    cleanup()
    if not ok then error(err, 0) end
    return path
end

function Content.save_book_epub(settings, book, chapters, chapter_bodies, suffix, assets, css, cover_data)
    local book_id = book.book_id or book.bookId
    Content.ensure_book_meta_dir(settings, book_id, book)
    local book_title = book.title or "WeRead"
    local path = Content.book_content_epub_path(settings, book, suffix or "book")
    local author = book.author or "WeRead"
    local description_meta = ""
    local description = xml_escape(book.intro)
    if description ~= "" then
        description_meta = "\n<dc:description>" .. description .. "</dc:description>"
    end
    local manifest_items = {
        [[<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>]],
        [[<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>]],
        [[<item id="style" href="style.css" media-type="text/css"/>]],
    }
    local spine_items = {}
    local entries = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = [[<?xml version="1.0" encoding="utf-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]] },
    }

    local cover_meta = ""
    if cover_data and #cover_data > 0 then
        local ext, mime = media_type_for(cover_data)
        local cover_img_href = "images/cover" .. ext
        table.insert(entries, { name = "OEBPS/" .. cover_img_href, data = cover_data })
        table.insert(manifest_items, [[<item id="cover-image" href="]] .. xml_escape(cover_img_href) .. [[" media-type="]] .. xml_escape(mime) .. [[" properties="cover-image"/>]])
        table.insert(manifest_items, [[<item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>]])
        table.insert(spine_items, [[<itemref idref="cover"/>]])
        local cover_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN">
<head><title>Cover</title>
<style>html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;}img{display:block;width:100%;height:100%;object-fit:contain;}</style>
</head>
<body><img src="../]] .. xml_escape(cover_img_href) .. [[" alt="Cover"/></body>
</html>]]
        table.insert(entries, { name = "OEBPS/text/cover.xhtml", data = cover_xhtml })
        cover_meta = '\n<meta name="cover" content="cover-image"/>'
    end

    for asset_index, asset in ipairs(assets or {}) do
        table.insert(manifest_items, [[<item id="asset_]] .. tostring(asset_index) .. [[" href="]] .. xml_escape(asset.href) .. [[" media-type="]] .. xml_escape(asset.media_type) .. [["/>]])
    end
    append_asset_entries(entries, assets)

    for chapter_index, chapter in ipairs(chapters or {}) do
        local uid = tostring(chapter.chapterUid or chapter_index)
        local filename = string.format("text/chapter-%03d.xhtml", chapter_index)
        local id = item_id("chapter_", uid)
        local title = chapter.title or ("Chapter " .. uid)
        local chapter_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN">
<head>
<title>]] .. xml_escape(title) .. [[</title>
<link rel="stylesheet" type="text/css" href="../style.css"/>
</head>
<body>
]] .. body_fragment(chapter_bodies[uid] or "") .. [[
</body>
</html>]]
        table.insert(entries, { name = "OEBPS/" .. filename, data = chapter_xhtml })
        table.insert(manifest_items, [[<item id="]] .. id .. [[" href="]] .. filename .. [[" media-type="application/xhtml+xml"/>]])
        table.insert(spine_items, [[<itemref idref="]] .. id .. [["/>]])
    end

    local opf = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0" prefix="dcterms: http://purl.org/dc/terms/">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="bookid">weread-]] .. xml_escape(book_id) .. [[-]] .. xml_escape(suffix or "book") .. [[</dc:identifier>
<dc:title>]] .. xml_escape(book_title) .. [[</dc:title>
<dc:creator>]] .. xml_escape(author) .. [[</dc:creator>]] .. description_meta .. [[
<dc:publisher>WeRead</dc:publisher>
<dc:source>]] .. xml_escape(WeRead.reader_url(book_id)) .. [[</dc:source>
<dc:language>zh-CN</dc:language>
<meta property="dcterms:modified">]] .. utc_modified() .. [[</meta>]] .. cover_meta .. [[
</metadata>
<manifest>
]] .. table.concat(manifest_items, "\n") .. [[
</manifest>
<spine toc="toc">
]] .. table.concat(spine_items, "\n") .. [[
</spine>
</package>]]
    local ncx_points = build_ncx_points(chapters, function(chapter_index)
        return string.format("text/chapter-%03d.xhtml", chapter_index)
    end)
    local ncx = [[<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head>
<meta name="dtb:uid" content="weread-]] .. xml_escape(book_id) .. [[-]] .. xml_escape(suffix or "book") .. [["/>
<meta name="dtb:depth" content="6"/>
<meta name="dtb:totalPageCount" content="0"/>
<meta name="dtb:maxPageNumber" content="0"/>
</head>
<docTitle><text>]] .. xml_escape(book_title) .. [[</text></docTitle>
<navMap>
]] .. ncx_points .. [[
</navMap>
</ncx>]]
    local nav = [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Navigation</title></head>
<body>
<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
<ol>
]] .. build_nav_items(chapters, function(chapter_index)
        return string.format("text/chapter-%03d.xhtml", chapter_index)
    end) .. [[
</ol>
</nav>
</body>
</html>]]
    css = css or [[body { line-height: 1.7; margin: 5%; } img { max-width: 100%; }]]
    table.insert(entries, { name = "OEBPS/content.opf", data = opf })
    table.insert(entries, { name = "OEBPS/nav.xhtml", data = nav })
    table.insert(entries, { name = "OEBPS/toc.ncx", data = ncx })
    table.insert(entries, { name = "OEBPS/style.css", data = css })
    write_epub(path, entries)
    return path
end

function Content.rewrite_image_sources(xhtml, src_map)
    if not src_map or not next(src_map) then
        return xhtml
    end
    local function replace_src(quote, src)
        local clean = tostring(src or ""):gsub("&amp;", "&")
        local key = basename(clean:match("^[^%?#]+") or clean)
        local href = src_map[key]
        if href then
            return "src=" .. quote .. href .. quote
        end
        return "src=" .. quote .. src .. quote
    end
    xhtml = xhtml:gsub("src=(['\"])(.-)%1", replace_src)
    return xhtml
end

function Content.download_remote_images(client, xhtml, used_names, progress)
    local assets = {}
    used_names = used_names or {}
    used_names.__remote_image_hrefs = used_names.__remote_image_hrefs or {}
    local remote_image_hrefs = used_names.__remote_image_hrefs
    local function remote_url(src)
        local url = tostring(src or "")
        if url:match("^//") then
            url = "https:" .. url
        end
        if url:match("^https?://") then
            return url
        end
    end
    local img_total = 0
    xhtml:gsub('src=(["\'])(.-)%1', function(_, src)
        if remote_url(src) then
            img_total = img_total + 1
        end
    end)
    if img_total == 0 then
        return xhtml, assets
    end
    local index = 0
    local body = xhtml:gsub('src=(["\'])(.-)%1', function(quote, src)
        local url = remote_url(src)
        if not url then
            return "src=" .. quote .. src .. quote
        end
        index = index + 1
        if progress then
            progress(index, img_total)
        end
        local cached_href = remote_image_hrefs[url]
        if cached_href then
            return "src=" .. quote .. "../" .. cached_href .. quote
        end
        local ok, data = pcall(function()
            return client:get_binary(url, { referer = "https://weread.qq.com/" })
        end)
        if not ok or not data or #data == 0 then
            return "src=" .. quote .. src .. quote
        end
        local ext, mt = media_type_for(data)
        if not mt:match("^image/") then
            return "src=" .. quote .. src .. quote
        end
        local seed = basename((url:match("^[^%?#]+") or url))
        local fname = unique_asset_name(used_names, seed ~= "" and seed or ("img" .. tostring(index)), ext)
        local href = image_href(nil, fname)
        remote_image_hrefs[url] = href
        table.insert(assets, {
            href = href,
            media_type = mt,
            data = data,
        })
        return "src=" .. quote .. "../" .. href .. quote
    end)
    return body, assets
end

function Content.download_chapter_assets(client, book, chapter, used_names)
    if not chapter or not chapter.tar or chapter.tar == "" then
        return {}, {}
    end
    used_names = used_names or {}
    local book_id = book.book_id or book.bookId
    local referer = WeRead.reader_url(book_id, chapter.chapterUid)
    local tar_url = tostring(chapter.tar)
    if tar_url:match("^//") then
        tar_url = "https:" .. tar_url
    elseif tar_url:match("^/") then
        tar_url = "https://weread.qq.com" .. tar_url
    end
    local raw = client:get_binary(tar_url, { referer = referer })
    local assets = {}
    local src_map = {}
    for entry_index, entry in ipairs(tar_entries(raw)) do
        local ext, media_type = media_type_for(entry.data)
        if media_type:match("^image/") then
            local stem = basename(entry.name)
            local filename = unique_asset_name(used_names, stem, ext)
            local href = image_href(nil, filename)
            local epub_relative = "../" .. href
            table.insert(assets, {
                href = href,
                media_type = media_type,
                data = entry.data,
            })
            src_map[stem] = epub_relative
            src_map[filename] = epub_relative
        end
    end
    return assets, src_map
end

local MAX_TAR_ENTRY_BYTES = 512 * 1024 * 1024
local FILE_COPY_CHUNK_BYTES = 64 * 1024

-- WeRead's catalog field is named `tar`, but cloud-converted documents may
-- point it at a ZIP archive instead. KOReader already ships libarchive, so use
-- its format auto-detection for those resources while keeping the small TAR
-- reader below for the common streaming path.
local function extract_zip_images(archive_path, asset_dir, used_names, workspace)
    local Archiver = require("ffi/archiver")
    local archive = Archiver.Reader:new()
    local assets = {}
    local src_map = {}
    local ok, err = xpcall(function()
        if not archive:open(archive_path) then
            error(archive.err or "could not open chapter resource archive")
        end
        for entry in archive:iterate() do
            if entry.mode == "file" and entry.size > 0 then
                if entry.size > MAX_TAR_ENTRY_BYTES then
                    error("chapter resource archive entry is too large")
                end
                local data = archive:extractToMemory(entry.path)
                if not data then
                    error(archive.err or "could not extract chapter resource")
                end
                local ext, media_type = media_type_for(data)
                if media_type:match("^image/") then
                    local stem = basename(entry.path)
                    local filename = unique_asset_name(used_names, stem, ext)
                    local href = image_href(workspace, filename)
                    local asset = { href = href, media_type = media_type }
                    if asset_dir then
                        local output = assert(io.open(asset_dir .. "/" .. filename, "wb"))
                        assert(output:write(data))
                        output:close()
                        asset.path = asset_dir .. "/" .. filename
                        asset.size = #data
                        asset.store = true
                    else
                        asset.data = data
                    end
                    table.insert(assets, asset)
                    local epub_relative = "../" .. href
                    src_map[stem] = epub_relative
                    src_map[filename] = epub_relative
                end
            end
        end
    end, debug.traceback)
    archive:close()
    if not ok then error(err, 0) end
    return assets, src_map
end

local function extract_tar_images(tar_path, asset_dir, used_names, workspace)
    local input, open_err = io.open(tar_path, "rb")
    if not input then error(open_err or "could not open chapter resource archive") end
    local assets = {}
    local src_map = {}
    local output
    local ok, err = xpcall(function()
        while true do
            local header = input:read(512)
            if not header then break end
            if #header ~= 512 then error("truncated TAR header") end
            if header:match("^%z+$") then break end
            local name = trim_nulls(header:sub(1, 100))
            local size_text = trim_nulls(header:sub(125, 136)):gsub("%s", "")
            local size = tonumber(size_text, 8)
            if not size or size < 0 or size > MAX_TAR_ENTRY_BYTES then
                error("invalid TAR entry size")
            end
            local typeflag = header:sub(157, 157)
            local is_file = name ~= "" and size > 0
                and (typeflag == "0" or typeflag == "" or typeflag == "\0")
            local first_size = math.min(size, 12)
            local first = first_size > 0 and input:read(first_size) or ""
            if #first ~= first_size then error("truncated TAR entry") end
            local remaining = size - first_size
            local ext, media_type = media_type_for(first)
            local output_path
            local filename
            if is_file and media_type:match("^image/") then
                local stem = basename(name)
                filename = unique_asset_name(used_names, stem, ext)
                output_path = asset_dir .. "/" .. filename
                output = assert(io.open(output_path, "wb"))
                assert(output:write(first))
            end
            while remaining > 0 do
                local chunk = input:read(math.min(remaining, FILE_COPY_CHUNK_BYTES))
                if not chunk or #chunk == 0 then error("truncated TAR entry") end
                remaining = remaining - #chunk
                if output then assert(output:write(chunk)) end
            end
            if output then
                output:close()
                output = nil
                local href = image_href(workspace, filename)
                table.insert(assets, {
                    href = href,
                    media_type = media_type,
                    path = output_path,
                    size = size,
                    store = true,
                })
                local epub_relative = "../" .. href
                local stem = basename(name)
                src_map[stem] = epub_relative
                src_map[filename] = epub_relative
            end
            local padding = (512 - size % 512) % 512
            if padding > 0 then
                local skipped = input:read(padding)
                if not skipped or #skipped ~= padding then error("truncated TAR padding") end
            end
        end
    end, debug.traceback)
    if output then output:close() end
    input:close()
    if not ok then error(err, 0) end
    return assets, src_map
end

function Content.download_chapter_assets_to_files(client, book, chapter, used_names, workspace)
    if not chapter or not chapter.tar or chapter.tar == "" then return {}, {} end
    used_names = used_names or {}
    local book_id = book.book_id or book.bookId
    local referer = WeRead.reader_url(book_id, chapter.chapterUid)
    local tar_url = tostring(chapter.tar)
    if tar_url:match("^//") then
        tar_url = "https:" .. tar_url
    elseif tar_url:match("^/") then
        tar_url = "https://weread.qq.com" .. tar_url
    end
    local tar_path = string.format("%s/chapter-%s.tar",
        workspace.incoming_dir, basename_safe(chapter.chapterUid or "unknown"))
    client:download_to_file(tar_url, tar_path, {
        referer = referer,
        max_bytes = MAX_TAR_ENTRY_BYTES,
    })
    local input = assert(io.open(tar_path, "rb"))
    local signature = input:read(4) or ""
    input:close()
    local extractor = signature:sub(1, 2) == "PK"
        and extract_zip_images or extract_tar_images
    local ok, assets, src_map = pcall(
        extractor, tar_path, workspace.asset_dir, used_names, workspace)
    pcall(os.remove, tar_path)
    if not ok then error(assets, 0) end
    return assets, src_map
end

function Content.download_remote_images_to_files(client, xhtml, used_names, workspace, progress)
    local assets = {}
    used_names = used_names or {}
    used_names.__remote_image_hrefs = used_names.__remote_image_hrefs or {}
    local remote_image_hrefs = used_names.__remote_image_hrefs
    local function remote_url(src)
        local url = tostring(src or "")
        if url:match("^//") then url = "https:" .. url end
        if url:match("^https?://") then return url end
    end
    local img_total = 0
    xhtml:gsub('src=(["\'])(.-)%1', function(_, src)
        if remote_url(src) then img_total = img_total + 1 end
    end)
    local index = 0
    local body = xhtml:gsub('src=(["\'])(.-)%1', function(quote, src)
        local url = remote_url(src)
        if not url then return "src=" .. quote .. src .. quote end
        index = index + 1
        if progress then progress(index, img_total) end
        local cached_href = remote_image_hrefs[url]
        if cached_href then return "src=" .. quote .. "../" .. cached_href .. quote end
        local incoming = string.format("%s/remote-%06d.bin", workspace.incoming_dir, index)
        local ok = pcall(function()
            client:download_to_file(url, incoming, {
                referer = "https://weread.qq.com/",
                max_bytes = 64 * 1024 * 1024,
            })
        end)
        if not ok then
            pcall(os.remove, incoming)
            return "src=" .. quote .. src .. quote
        end
        local ext, mt = media_type_for_file(incoming)
        if not mt or not mt:match("^image/") then
            pcall(os.remove, incoming)
            return "src=" .. quote .. src .. quote
        end
        local seed = basename((url:match("^[^%?#]+") or url))
        local fname = unique_asset_name(used_names,
            seed ~= "" and seed or ("img" .. tostring(index)), ext)
        local output_path = workspace.asset_dir .. "/" .. fname
        local renamed = os.rename(incoming, output_path)
        if not renamed then
            pcall(os.remove, incoming)
            return "src=" .. quote .. src .. quote
        end
        local file = io.open(output_path, "rb")
        local size = file and file:seek("end") or 0
        if file then file:close() end
        local href = image_href(workspace, fname)
        remote_image_hrefs[url] = href
        table.insert(assets, {
            href = href,
            media_type = mt,
            path = output_path,
            size = size,
            store = true,
        })
        return "src=" .. quote .. "../" .. href .. quote
    end)
    return body, assets
end

function Content.fetch_catalog(client, book)
    local book_id = book.book_id or book.bookId
    local catalog = client:eink_chapterinfo(book_id)
    local chapters = Content.readable_chapters(Content.normalize_chapters(catalog, book_id))
    book.chapters = chapters
    return chapters
end

function Content.txt_to_xhtml(text)
    return Eink.txt_to_xhtml(text)
end

local function apply_chapter_annotations(client, settings, book, chapter, xhtml, css)
    local cache = settings:get("cache", {})
    if cache.download_underlines_and_thoughts ~= true then
        return xhtml, css
    end
    local book_id = book.book_id or book.bookId
    local chapter_uid = chapter and chapter.chapterUid
    local processed, annotation_css = Thoughts.apply(client, settings, book_id, chapter_uid, xhtml)
    return processed, Thoughts.merge_css(css, annotation_css)
end

function Content.fetch_chapter_epub(client, settings, book, chapter)
    local path = Content.fetch_chapters_epub_eink(client, settings, book, { chapter })
    return path
end

-- Split chapter downloading around annotation fetching so the UI can request
-- thought batches cooperatively instead of blocking inside Thoughts.apply().
function Content.fetch_single_chapter_source(client, settings, book, chapter, state)
    state = state or {}
    if not client.can_eink_download or not client:can_eink_download() then
        error("eink download is not available")
    end
    local chapters = Content.ensure_eink_chapter_files(client, book, { chapter })
    local param = Eink.build_chapters_param({ chapter.chapterUid })
    if param == "" then
        error("No readable chapter found")
    end
    local files = client:eink_download_zip(book.book_id or book.bookId, param)
    local bodies, assets = Eink.files_to_chapter_bodies(files, chapters)
    local uid = tostring(chapter.chapterUid or "")
    local xhtml = bodies[uid]
    if type(xhtml) ~= "string" or xhtml == "" then
        error("eink ZIP contained no matching chapter")
    end
    if type(assets) == "table" then
        state.eink_assets = assets
    end
    return xhtml
end

function Content.finalize_single_chapter_content(client, settings, book, chapter, xhtml, state)
    state = state or {}
    local chapter_assets = {}
    local cache = settings:get("cache", {})
    if cache.download_book_images then
        state.used_asset_names = state.used_asset_names or {}
        local tar_assets, src_map
        if state.workspace then
            tar_assets, src_map = Content.download_chapter_assets_to_files(
                client, book, chapter, state.used_asset_names, state.workspace)
        else
            tar_assets, src_map = Content.download_chapter_assets(
                client, book, chapter, state.used_asset_names)
        end
        for _, asset in ipairs(tar_assets) do
            table.insert(chapter_assets, asset)
        end
        xhtml = Content.rewrite_image_sources(xhtml, src_map)
        local inline_xhtml, inline_assets
        if state.workspace then
            inline_xhtml, inline_assets = Content.download_remote_images_to_files(
                client, xhtml, state.used_asset_names, state.workspace)
        else
            inline_xhtml, inline_assets = Content.download_remote_images(
                client, xhtml, state.used_asset_names)
        end
        xhtml = inline_xhtml
        for _, asset in ipairs(inline_assets) do
            table.insert(chapter_assets, asset)
        end
    end
    return xhtml, chapter_assets
end

function Content.ensure_eink_chapter_files(client, book, chapters)
    local missing = false
    for _, chapter in ipairs(chapters or {}) do
        if type(chapter.files) ~= "table" or not chapter.files[1] then
            missing = true
            break
        end
    end
    if not missing then
        return chapters
    end
    local info = client:eink_chapterinfo(book.book_id or book.bookId)
    local files_by_uid = {}
    for _, chapter in ipairs(info.chapters or info.updated or info.chapterInfos or {}) do
        files_by_uid[tostring(chapter.chapterUid)] = chapter.files
    end
    for _, chapter in ipairs(chapters or {}) do
        if type(chapter.files) ~= "table" or not chapter.files[1] then
            chapter.files = files_by_uid[tostring(chapter.chapterUid)]
        end
    end
    return chapters
end

function Content.fetch_chapters_epub_eink(client, settings, book, chapters, options)
    options = options or {}
    if not client.can_eink_download or not client:can_eink_download() then
        error("eink download is not available")
    end
    chapters = Content.ensure_eink_chapter_files(client, book, chapters)
    local uids = {}
    for _, chapter in ipairs(chapters or {}) do
        uids[#uids + 1] = chapter.chapterUid
    end
    local param = Eink.build_chapters_param(uids)
    if param == "" then
        error("No readable chapter found")
    end
    logger.info("eink zip download", "bookId=", tostring(book.book_id or book.bookId), "chapters=", param)
    local files = client:eink_download_zip(book.book_id or book.bookId, param)
    local bodies, assets = Eink.files_to_chapter_bodies(files, chapters)
    local css
    local selected = {}
    for chapter_index, chapter in ipairs(chapters or {}) do
        local uid = tostring(chapter.chapterUid or chapter_index)
        local xhtml = bodies[uid]
        if type(xhtml) == "string" and xhtml ~= "" then
            if options.progress then
                options.progress(chapter_index, #chapters, chapter, "text")
            end
            xhtml, css = apply_chapter_annotations(client, settings, book, chapter, xhtml, css)
            bodies[uid] = xhtml
            selected[#selected + 1] = chapter
        end
    end
    if #selected == 0 then
        error("eink ZIP contained no matching chapters")
    end
    local path = Content.save_book_epub(settings, book, selected, bodies, options.suffix or "book", assets, css)
    book.cached_chapters = book.cached_chapters or {}
    for chapter_index, chapter in ipairs(selected) do
        book.cached_chapters[tostring(chapter.chapterUid or chapter_index)] = path
    end
    book.cached_file = path
    book.reader_url = book.reader_url or WeRead.reader_url(book.book_id or book.bookId)
    return path, selected
end

function Content.extract_article_body(html)
    html = tostring(html or "")
    local body = html:match('<div[^>]*id="js_content"[^>]*>(.-)</div>%s*<script')
    if not body then
        body = html:match('class="rich_media_content[^"]*"[^>]*>(.-)</div>%s*<script')
    end
    if not body then
        body = html:match('<div[^>]*id="js_content"[^>]*>(.*)')
    end
    if not body or body == "" then
        return nil
    end
    body = body:gsub("<script.-</script>", "")
    body = body:gsub("<style.-</style>", "")
    body = body:gsub(' src=""', '')
    body = body:gsub(" src=''", "")
    body = body:gsub("data%-src=", "src=")
    return body
end

-- Map WeChat's editor font names onto the generic families KOReader maps in
-- its Font-family fonts menu (serif / sans-serif / monospace / "Fang Song").
-- Named fonts like SimSun are NOT honored by CREngine, so we never emit them.
-- The common system-ui / -apple-system-font noise maps to nothing (falls back
-- to the user's main font), unless it is explicitly a serif/sans choice.
local function mp_font_family(value)
    local v = (value or ""):lower()
    -- Exact generic keywords pass through: the whitelist pass normalizes named
    -- families first, and substring matching below would misroute "sans-serif"
    -- to serif (it contains "serif") -- the pingfang bug all over again.
    if v == "serif" then return "serif" end
    if v == "sans-serif" or v == "sans serif" then return "sans-serif" end
    if v == "monospace" then return "monospace" end
    if v == "fang song" then return "Fang Song" end
    local function has(pat)
        return v:find(pat) ~= nil
    end
    -- PingFang is Apple's sans CJK font ("pingfang" contains "fang"): check it
    -- before Fang Song so it does not misroute to the Fang Song family.
    if has("pingfang") or has("苹方") then
        return "sans-serif"
    end
    -- Fang Song before song: "fangsong" contains "song" and would go serif.
    -- The family name is emitted without quotes: CSS allows unquoted multi-word
    -- family names, and quotes would break the style attribute in the HTML.
    if has("fangsong") or has("仿宋") or has("fang") then
        return "Fang Song"
    end
    if has("kai") or has("楷") then
        return "serif"
    end
    if has("song") or has("sun") or has("宋") or has("serif")
        or has("times") or has("georgia") or has("ming") or has("明") then
        return "serif"
    end
    if has("hei") or has("黑") or has("yahei") or has("雅黑")
        or has("sans") or has("arial") or has("helvetica")
        or has("verdana") or has("tahoma") or has("noto%s+sans")
        or has("system%-ui") or has("apple") or has("microsoft") then
        return "sans-serif"
    end
    if has("mono") or has("courier") or has("consolas") or has("menlo") then
        return "monospace"
    end
    return nil
end

local function strip_mp_reader_font_styles(html)
    -- Whitelist mode: keep only typography CREngine can render meaningfully
    -- (text-align, font-weight, relative font-size). Everything else that
    -- WeChat's editor emits (margins, letter-spacing, colors, backgrounds,
    -- flex, vendor props, page-breaks...) is dropped -- those are what made
    -- KOReader paginate one paragraph per page with blank space below.
    --
    -- font-size is normalized against the article's dominant size: a paragraph
    -- set in the common size becomes 1em (dropped), while genuinely smaller or
    -- larger text (footnotes, emphasized lines, headers) keeps its ratio.
    local size_counts = {}
    for value in tostring(html or ""):gmatch("font%-size%s*:%s*([^;]+)") do
        local lower = value:lower()
        local px = tonumber(lower:match("^%s*([%d%.]+)%s*px%s*$"))
        local pt = tonumber(lower:match("^%s*([%d%.]+)%s*pt%s*$"))
        local n
        if px then
            n = px
        elseif pt then
            n = pt * 4 / 3
        end
        if n and n > 0 then
            size_counts[n] = (size_counts[n] or 0) + 1
        end
    end
    local base_px = 15 -- CSS default; overridden by the mode below
    local best = 0
    for n, c in pairs(size_counts) do
        if c > best then
            base_px, best = n, c
        end
    end

    local function keep_font_size(value)
        local lower = value:lower()
        local px = tonumber(lower:match("^%s*([%d%.]+)%s*px%s*$"))
        local pt = tonumber(lower:match("^%s*([%d%.]+)%s*pt%s*$"))
        local em = tonumber(lower:match("^%s*([%d%.]+)%s*em%s*$"))
        local percent = tonumber(lower:match("^%s*([%d%.]+)%s*%%%s*$"))
        local ratio
        if px then
            ratio = px / base_px
        elseif pt then
            ratio = pt * 4 / 3 / base_px
        elseif em then
            ratio = em
        elseif percent then
            ratio = percent / 100
        end
        if ratio and math.abs(ratio - 1) >= 0.1 then
            return string.format("font-size: %.2fem", ratio)
        end
        return nil
    end

    return tostring(html or ""):gsub('style=([\"\'])(.-)%1', function(quote, style)
        local kept = {}
        for decl in style:gmatch("[^;]+") do
            local name, value = decl:match("^%s*([^:]+)%s*:%s*(.-)%s*$")
            if name and value then
                local property = name:lower()
                if property == "font-size" then
                    local fs = keep_font_size(value)
                    if fs then
                        table.insert(kept, fs)
                    end
                elseif property == "font-weight" then
                    local w = value:lower()
                    local wnum = tonumber(w)
                    if w == "bold" or (wnum and wnum >= 600) then
                        table.insert(kept, "font-weight: bold")
                    end
                elseif property == "text-align" then
                    local a = value:lower()
                    if a == "center" or a == "left" or a == "right" or a == "justify" then
                        table.insert(kept, name .. ": " .. a)
                    end
                elseif property == "font-family" then
                    local fam = mp_font_family(value)
                    if fam then
                        table.insert(kept, "font-family: " .. fam)
                    end
                end
            end
        end
        if #kept == 0 then
            return ""
        end
        return "style=" .. quote .. table.concat(kept, "; ") .. quote
    end)
end


function Content.strip_article_images(html)
    html = tostring(html or "")
    html = html:gsub(
        "<[pP][iI][cC][tT][uU][rR][eE][^>]*>.-</[pP][iI][cC][tT][uU][rR][eE]%s*>",
        ""
    )
    html = html:gsub("<[iI][mM][gG][^>]*>", "")
    html = html:gsub("</[iI][mM][gG]%s*>", "")
    html = html:gsub("<[sS][oO][uU][rR][cC][eE][^>]*>", "")
    return html
end

-- WeChat nests <section>/<span> shells 10-20 levels deep and wraps most inline
-- text in attribute-less <span> wrappers. After style stripping the shells are
-- pure layout noise: unwrapping them shrinks the render tree by an order of
-- magnitude (measured: 1400+ tags / 18 levels -> ~400 tags / 2 levels) which is
-- exactly what makes KOReader hang for seconds on open.
local function simplify_mp_markup(html)
    -- Attribute-less spans are pure wrappers: unwrap them, keeping inner markup
    -- and text. Attributed spans (annotation markers etc.) are preserved.
    -- Whitelist span attributes: only class (annotation markers) and style
    -- (already reduced to the typography whitelist) survive; WeChat image
    -- shells carry dozens of data-*/align/width attributes that only block
    -- unwrapping.
    html = html:gsub("<span([^>]*)>", function(attrs)
        if attrs == "" or not attrs:match("%S") then
            return "<span>"
        end
        local cls = attrs:match('class%s*=%s*["\'](.-)["\']')
        local style = attrs:match('style%s*=%s*["\'](.-)["\']')
        local kept = {}
        if cls and cls ~= "" then
            table.insert(kept, 'class="' .. cls .. '"')
        end
        if style and style ~= "" then
            table.insert(kept, 'style="' .. style .. '"')
        end
        if #kept == 0 then
            return "<span>"
        end
        return "<span " .. table.concat(kept, " ") .. ">"
    end)
    -- Attribute-less spans are pure wrappers: unwrap them, keeping inner markup
    html = html:gsub("<[sS][pP][aA][nN]%s+>", "<span>")
    for _ = 1, 8 do
        local previous = html
        html = html:gsub("<span>(.-)</span>", "%1")
        if html == previous then
            break
        end
    end

    -- Collapse single-child div chains. WeChat's section tree is mostly nested
    -- wrappers around exactly one block child; after attribute stripping they
    -- carry no layout meaning. Divs with attributes or multiple children stay.
    -- First drop the remaining non-style attributes (WeChat dark-mode classes,
    -- 135editor data-role/label hooks, nodeleaf, etc.): they have no rendering
    -- meaning in KOReader and only block the collapsing below.
    html = html:gsub("<div([^>]*)>", function(attrs)
        if attrs == "" or not attrs:match("%S") then
            return "<div>"
        end
        local style = attrs:match('style%s*=%s*["\'](.-)["\']')
        if style and style ~= "" then
            return '<div style="' .. style .. '">'
        end
        return "<div>"
    end)
    for _ = 1, 24 do
        local previous = html
        html = html:gsub("<div([^>]*)>(<div[^>]*>.-</div>)</div>", function(attrs, inner)
            if attrs:match("%S") then
                return "<div" .. attrs .. ">" .. inner .. "</div>"
            end
            return inner
        end)
        if html == previous then
            break
        end
    end
    -- Drop empty divs that the collapsing may have left behind.
    html = html:gsub("<div%s*>%s*</div>", "")

    return html
end

local function strip_blank_mp_blocks(html)
    html = tostring(html or "")
    html = html:gsub("<mp%-common%-profile[^>]->.-</mp%-common%-profile>", "")
    html = html:gsub("<mp%-style%-type[^>]->.-</mp%-style%-type>", "")
    html = html:gsub("<[bB][rR]%s*/?%s*>", "<br/>")
    html = html:gsub("&nbsp;", " ")
    html = html:gsub("&#160;", " ")
    html = html:gsub("&#x[aA]0;", " ")
    html = html:gsub("\194\160", " ")

    for _ = 1, 12 do
        local previous = html
        for _, tag in ipairs({ "a", "span", "p", "section", "div", "figure", "picture",
            "h1", "h2", "h3", "h4", "h5", "h6" }) do
            html = html:gsub("<" .. tag .. "[^>]->%s*<br/>%s*</" .. tag .. ">", "")
            html = html:gsub("<" .. tag .. "[^>]->%s*</" .. tag .. ">", "")
        end
        if html == previous then
            break
        end
    end

    -- WeChat editor sometimes wraps the article lead (导语) and inline labels in
    -- <h1>/<h2>. The saved article already prepends the real title as <h1>, so
    -- demote ALL in-body headings to paragraphs (keeping inner <strong>/<b> so
    -- section labels stay visually distinct). Drop the whole style attribute:
    -- WeChat headings carry e.g. font-size: 1.38em which would otherwise keep
    -- the paragraph oversized.
    html = html:gsub("<([hH])([1-6])([^>]*)>(.-)</%1%2>", function(tag, level, attrs, inner)
        if inner:match("^%s*$") then
            return ""
        end
        -- Keep the (already whitelisted) style so in-body headings keep their
        -- emphasis size; only the tag is demoted to a paragraph.
        return "<p" .. attrs .. ">" .. inner .. "</p>"
    end)

    for _ = 1, 4 do
        local updated = html:gsub("(%s*<br/>%s*)%s*<br/>%s*", "<br/>")
        if updated == html then
            break
        end
        html = updated
    end

    -- CREngine handles <div> much more predictably than WeChat's deeply
    -- nested <section> trees; convert section wrappers to plain divs.
    html = html:gsub("<([sS][eE][cC][tT][iI][oO][nN])([^>]*)>", "<div%2>")
    html = html:gsub("</[sS][eE][cC][tT][iI][oO][nN]>", "</div>")

    -- WeChat editor dumps editor state (including serialized styles) into
    -- data-pm-slice / data-mpa-* attributes; drop them to keep output clean.
    html = html:gsub("%s+data%-pm%-slice%s*=%s*([\"\']).-%1", "")
    html = html:gsub("%s+data%-mpa%-[%w%-]+%s*=%s*([\"\']).-%1", "")
    html = html:gsub("%s+data%-mpa%-action%-id%s*=%s*([\"\']).-%1", "")
    -- Same editor leaks without the data- prefix: mpa-font-*, leaf, data-nest-level.
    html = html:gsub("%s+mpa%-font%-[%w%-]+%s*=%s*([\"\']).-%1", "")
    -- valueless form: <span mpa-font-> (attribute without ="...")
    html = html:gsub("%s+mpa%-font%-+([ >])", "%1")
    html = html:gsub("%s+leaf%s*=%s*([\"\']).-%1", "")
    html = html:gsub("%s+data%-nest%-level%s*=%s*([\"\']).-%1", "")
    -- <font face="宋体"> has no matching device font, but the family intent is
    -- real: map it onto the generic family (serif/sans-serif/Fang Song) that
    -- the user maps in KOReader's Font-family fonts menu. Unknown faces drop.
    -- <o:p> is a Word placeholder that renders as an empty paragraph.
    html = html:gsub('%s+face%s*=%s*[\"\'](.-)[\"\']', function(v)
        local fam = mp_font_family(v)
        if fam then
            return ' face="' .. fam .. '"'
        end
        return ""
    end)
    html = html:gsub("<[oO]:[pP][^>]*>.-</[oO]:[pP]>", "")
    -- Tencent doc editor tags <span text="...">; the value duplicates the text
    -- content and has no meaning for rendering. Sometimes the attribute is
    -- valueless (<span text>), so handle both forms.
    html = html:gsub("%s+text%s*=%s*([\"\']).-%1", "")
    html = html:gsub("%s+text([ >])", "%1")
    -- lang= is meaningless for a zh-CN render and only blocks unwrapping.
    html = html:gsub("%s+lang%s*=%s*([\"\']).-%1", "")

    html = simplify_mp_markup(html)

    html = html:gsub("\n%s*\n%s*\n+", "\n\n")
    return html
end

function Content.download_article_images_to_files(
        client, settings, book, article, body_html, progress)
    body_html = tostring(body_html or "")
    local html_path = Content.article_path(settings, book, article)
    local article_dir = html_path:match("^(.*)/[^/]+$")
    if not article_dir then error("Could not resolve WeChat article directory") end

    local function normalize_url(src)
        local url = tostring(src or ""):gsub("&amp;", "&")
        if url:match("^//") then url = "https:" .. url end
        if not url:match("^https?://mmbiz%.qpic%.cn/")
            and not url:match("^https?://mmbiz%.qlogo%.cn/") then
            return nil
        end
        return url
    end

    local asset_name = ".weread-article-"
        .. tostring(html_path:match("([^/]+)%.html$")) .. "-assets"
    local asset_dir = article_dir .. "/" .. asset_name
    ensure_directory(asset_dir)
    local source_url = tostring(
        (article.url and article.url ~= "" and article.url)
        or article.sourceUrl or "")
    local image_referer = source_url:match("^https://mp%.weixin%.qq%.com/")
        and source_url or "https://mp.weixin.qq.com/"

    local unique_urls, total = {}, 0
    body_html:gsub([=[src=(["'])([^"']-)["']]=], function(_quote, src)
        local url = normalize_url(src)
        if url and unique_urls[url] == nil then
            unique_urls[url] = false
            total = total + 1
        end
    end)

    local resolved, index, downloaded = {}, 0, 0
    local body = body_html:gsub([=[src=(["'])([^"']-)["']]=], function(quote, src)
        local url = normalize_url(src)
        if not url then return "src=" .. quote .. src .. quote end
        if resolved[url] ~= nil then
            local relative = resolved[url]
            return relative and ("src=" .. quote .. relative .. quote)
                or ("src=" .. quote .. src .. quote)
        end
        index = index + 1
        if progress then progress(index, total) end
        local stem = string.format("img-%04d", index)
        local incoming = asset_dir .. "/" .. stem .. ".download"
        local ok, err = pcall(function()
            client:download_to_file(url, incoming, {
                accept = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
                referer = image_referer,
                max_bytes = 64 * 1024 * 1024,
            })
        end)
        if not ok then
            resolved[url] = false
            logger.warn("MP image download failed:", "index=", tostring(index),
                "error=", tostring(err))
            pcall(os.remove, incoming)
            collectgarbage("step", 64)
            return "src=" .. quote .. src .. quote
        end
        local ext, media_type, detect_error = media_type_for_file(incoming)
        if not ext or ext == ".bin" or not tostring(media_type):match("^image/") then
            resolved[url] = false
            logger.warn("MP image response is not a supported image:",
                "index=", tostring(index), "error=", tostring(detect_error or media_type))
            pcall(os.remove, incoming)
            collectgarbage("step", 64)
            return "src=" .. quote .. src .. quote
        end
        local filename = stem .. ext
        local final_path = asset_dir .. "/" .. filename
        pcall(os.remove, final_path)
        local renamed, rename_error = os.rename(incoming, final_path)
        if not renamed then
            resolved[url] = false
            logger.warn("MP image commit failed:", "index=", tostring(index),
                "error=", tostring(rename_error))
            pcall(os.remove, incoming)
            collectgarbage("step", 64)
            return "src=" .. quote .. src .. quote
        end
        local relative = asset_name .. "/" .. filename
        resolved[url] = relative
        downloaded = downloaded + 1
        collectgarbage("step", 64)
        return "src=" .. quote .. relative .. quote
    end)
    logger.info("MP images stored as local files:",
        "downloaded=", tostring(downloaded), "total=", tostring(total))
    return body
end

function Content.article_path(settings, book, article)
    local root = settings and (settings.data_dir or settings.cache_dir) or "/tmp/weread"
    local account = settings and type(settings.get) == "function"
        and settings:get("account", {}) or {}
    local vid = type(account) == "table" and account.user_vid or nil
    if not vid or tostring(vid) == "" then
        local eink = settings and type(settings.get) == "function"
            and settings:get("eink", {}) or {}
        vid = type(eink) == "table" and eink.vid or nil
    end
    local account_key = vid and tostring(vid) ~= ""
        and Crypto.sha256_hex("weread-articles:" .. tostring(vid)):sub(1, 20)
        or "anonymous"
    local dir = root .. "/articles/" .. account_key
    local review_id = article and (article.reviewId or article.review_id or article.key)
    if not review_id or tostring(review_id) == "" then
        error("Article review ID is missing", 0)
    end
    local key = Crypto.sha256_hex(tostring(review_id)):sub(1, 24)
    return dir .. "/" .. key .. ".html"
end

function Content.article_cached_path(settings, book, article)
    local html_path = Content.article_path(settings, book, article)
    if Content.is_valid_article_cache(html_path) then
        return html_path
    end
    return nil
end

function Content.is_valid_article_cache(path)
    if type(path) ~= "string" or not path:match("%.html$") then return false end
    local f = io.open(path, "rb")
    if not f then return false end
    local header = f:read(1024) or ""
    f:close()
    return header:find('name="weread-article-cache-version" content="3"', 1, true) ~= nil
end

-- CREngine's standalone-HTML mode ignores inline style attributes (only EPUB
-- gets full CSS cascade; legacy presentational attributes are honored since
-- KOReader 2024.04). So after the whitelist pass we translate the surviving
-- typography into mechanisms CREngine actually applies:
--   font-weight: bold   -> <b> element
--   text-align: ...     -> align="..." attribute (block elements)
--   font-size: X.XXem   -> class="mp-fs-NNN" + <style> rule
--   font-family: ...    -> face="..." attribute (presentational hint) + class
-- Returns the rewritten HTML plus the collected <style> rules.
local function mp_typography_to_legacy(html)
    local css_defs = {}
    local css_seen = {}
    local function add_css(selector, rule)
        if not css_seen[selector] then
            css_seen[selector] = true
            table.insert(css_defs, selector .. " { " .. rule .. " }")
        end
    end

    -- 1. bold -> <b> for spans whose inner is plain text (safe against
    --    nested spans; iterated so inner-most levels collapse first).
    for _ = 1, 8 do
        local prev = html
        html = html:gsub('<span style="([^"]*font%-weight:%s*bold[^"]*)">([^<]-)</span>',
            function(style, inner)
                if inner == "" then
                    return ""
                end
                local cls = {}
                local fs = style:match("font%-size:%s*([%d%.]+)em")
                if fs then
                    local key = string.format("mp-fs-%d", math.floor(tonumber(fs) * 100 + 0.5))
                    table.insert(cls, key)
                    add_css("." .. key, string.format("font-size: %.2fem", tonumber(fs)))
                end
                if #cls > 0 then
                    return '<b class="' .. table.concat(cls, " ") .. '">' .. inner .. "</b>"
                end
                return "<b>" .. inner .. "</b>"
            end)
        if html == prev then
            break
        end
    end

    -- 2. remaining styles (text-align / font-weight / font-size / font-family)
    --    -> attributes / classes; bold that could not safely become <b> (mixed
    --    content, block elements) falls back to the .mp-b class rule.
    --    and classes; the style attribute itself is removed.
    html = html:gsub("<([a-zA-Z][a-zA-Z0-9]*)([^>]*)>", function(tag, attrs)
        local style = attrs:match('style%s*=%s*["\'](.-)["\']')
        if not style or style == "" then
            return "<" .. tag .. attrs .. ">"
        end
        local align, bold, fs, ff
        for decl in style:gmatch("[^;]+") do
            local name, value = decl:match("^%s*([^:]+)%s*:%s*(.-)%s*$")
            if name then
                local p = name:lower()
                if p == "text-align" then
                    align = value:lower()
                elseif p == "font-weight" then
                    local w = value:lower()
                    local wnum = tonumber(w)
                    if w == "bold" or (wnum and wnum >= 600) then
                        bold = true
                    end
                elseif p == "font-size" then
                    fs = value:lower()
                elseif p == "font-family" then
                    ff = value
                end
            end
        end
        attrs = attrs:gsub('style%s*=%s*["\'](.-)["\']', "")
        local extra = {}
        if bold then
            table.insert(extra, ' class="mp-b"')
            add_css(".mp-b", "font-weight: bold")
        end
        if align and (tag == "p" or tag == "div" or tag == "blockquote") then
            table.insert(extra, ' align="' .. align .. '"')
        end
        if fs then
            local em = tonumber(fs:match("([%d%.]+)em"))
            if em and math.abs(em - 1) >= 0.1 then
                local key = string.format("mp-fs-%d", math.floor(em * 100 + 0.5))
                table.insert(extra, ' class="' .. key .. '"')
                add_css("." .. key, string.format("font-size: %.2fem", em))
            end
        end
        if ff then
            local fam = mp_font_family(ff)
            if fam then
                table.insert(extra, ' face="' .. fam .. '"')
                local key = "mp-ff-" .. fam:gsub("%s", "")
                if not attrs:match('class="[^"]*' .. key) and not table.concat(extra):find(key, 1, true) then
                    add_css("." .. key, "font-family: " .. fam)
                end
            end
        end
        -- merge class into an existing class attribute if present
        local existing = attrs:match('class%s*=%s*["\'](.-)["\']')
        local new_classes = {}
        for c in (table.concat(extra, " ")):gmatch('class="([^"]+)"') do
            for w in c:gmatch("[^%s]+") do table.insert(new_classes, w) end
        end
        if #new_classes > 0 then
            if existing then
                attrs = attrs:gsub('class%s*=%s*["\'](.-)["\']',
                    'class="' .. existing .. " " .. table.concat(new_classes, " ") .. '"')
            else
                attrs = attrs .. ' class="' .. table.concat(new_classes, " ") .. '"'
            end
            -- drop the class= entries already emitted inside extra
            local cleaned = {}
            for _, e in ipairs(extra) do
                if not e:match('^%s*class=') then table.insert(cleaned, e) end
            end
            extra = cleaned
        end
        return "<" .. tag .. attrs .. table.concat(extra) .. ">"
    end)

    return html, css_defs
end

function Content.save_article_html(settings, book, article, body_html)
    if not body_html or body_html:match("^%s*$") then
        error("article body content is empty", 0)
    end
    local mp_css
    local title = article.title or "Article"
    local path = Content.article_path(settings, book, article)
    ensure_directory(path_dirname(path))
    body_html = strip_mp_reader_font_styles(body_html)
    body_html = strip_blank_mp_blocks(body_html)
    body_html, mp_css = mp_typography_to_legacy(body_html)

    local html = [[<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="weread-article-cache-version" content="3"/>
<title>]] .. xml_escape(title) .. [[</title>
<style>
html, body {
  color: #000 !important;
  font-size: 1em !important;
  line-height: 1.7;
  margin: 0;
  padding: 0;
  -webkit-text-size-adjust: 100%;
  text-size-adjust: 100%;
}
body {
  margin: 0 !important;
  padding: 0 !important;
}
body * {
  color: inherit !important;
  line-height: inherit !important;
}
img {
  display: inline !important;
  max-width: 100%;
  height: auto;
  margin: 0.2em 0 !important;
  vertical-align: middle;
  page-break-before: auto !important;
  page-break-after: auto !important;
  break-before: auto !important;
  break-after: auto !important;
}
h1, h2, h3, h4, h5, h6 {
  font-size: 1.2em !important;
  line-height: 1.4 !important;
  margin: 0.6em 0 0.3em !important;
  page-break-after: avoid;
  break-after: avoid;
}
h1 {
  font-size: 1.3em !important;
}
p {
  margin: 0.25em 0 !important;
  text-indent: 0 !important;
}
/* WeChat typography translated to classes (CREngine ignores inline styles
   in standalone-HTML mode; align= / face= / <b> are the presentational hints) */
]] .. table.concat(mp_css or {}, "\n") .. [[

section, div {
  margin: 0 !important;
  padding: 0 !important;
}
</style>
</head>
<body>
<h1>]] .. xml_escape(title) .. [[</h1>
]] .. body_html .. [[
</body>
</html>]]

    write_file(path, html)
    return path
end

function Content.fetch_article_html(client, settings, book, article, opts)
    opts = opts or {}
    local source_url = tostring(
        (article.url and article.url ~= "" and article.url)
        or article.sourceUrl or "")
    if not source_url:match("^https?://mp%.weixin%.qq%.com/") then
        error("WeChat article source URL is missing or invalid", 0)
    end
    local html, meta = client:get_public_text(source_url)
    local body = Content.extract_article_body(html)
    if not body then
        local empty_response = not html or html:match("^%s*$") ~= nil
        logger.warn(
            "could not extract MP article body:",
            "reason=", empty_response and "empty_response" or "missing_body",
            "html_length=", tostring(meta and meta.length or #(html or "")),
            "content_type=", tostring(meta and meta.content_type or ""),
            "has_source_url=", "yes"
        )
        if empty_response then
            error("Article content response is empty. See KOReader log for details.", 0)
        end
        error("Could not extract article body. See KOReader log for details.", 0)
    end
    local cache = (settings and type(settings.get) == "function" and settings:get("cache", {}))
        or (settings and settings.cache) or {}
    if cache.download_article_images then
        body = Content.download_article_images_to_files(
            client, settings, book, article, body, opts.progress)
    else
        body = Content.strip_article_images(body)
    end
    return Content.save_article_html(settings, book, article, body)
end

return Content

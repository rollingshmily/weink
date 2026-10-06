-- Reader-side chapter identity. Never infer a chapter from whole-book words.
-- The within-chapter offset is still a layout/word-count estimate, NOT the
-- native app's htmlPos. Callers must keep that limitation visible.
local Chapters = require("weread.lib.annotation_chapters")
local Mapper = require("weread.lib.position_mapper")
local ReaderPosition = {}

local function number(value)
    value = tonumber(value)
    if not value or value ~= value or math.abs(value) == math.huge then return nil end
    return value
end

local function call(document, name, ...)
    if type(document) ~= "table" or type(document[name]) ~= "function" then return nil end
    local ok, value = pcall(document[name], document, ...)
    if ok then return value end
end

local function before(document, left, right)
    local cmp = call(document, "compareXPointers", left, right)
    if cmp == nil then return nil end
    -- CRE returns 1 when left precedes right (not strcmp's sign).
    return cmp == 1
end

local function bounds(document, range)
    local start = number(call(document, "getPosFromXPointer", range.start_xpointer))
    local height = number(document.info and document.info.doc_height)
        or number(document.doc_height)
    local finish = range.end_xpointer
        and number(call(document, "getPosFromXPointer", range.end_xpointer)) or height
    if not start or not finish or not height or height <= 0
        or start < 0 or finish <= start or finish > height then
        return nil, nil, nil
    end
    return start, finish, height
end

function ReaderPosition.prepare(document, book, chapters)
    local toc = call(document, "getToc")
    if type(toc) ~= "table" or #toc == 0 then return nil, "document_toc_unavailable" end
    -- Only explicit download manifests assert positional order. A legacy
    -- cached_chapters list does not prove the document's TOC order.
    local descriptor = book.annotation_documents and book.annotation_documents[document.file]
    if not descriptor then
        local exact, normalized = {}, {}
        for _, item in ipairs(toc) do
            local title = tostring(item.title or "")
            exact[title] = (exact[title] or 0) + 1
            local norm = Chapters.normalize(title)
            normalized[norm] = (normalized[norm] or 0) + 1
        end
        for _, chapter in ipairs(chapters) do
            local title = tostring(chapter.title or "")
            local count = exact[title] or normalized[Chapters.normalize(title)] or 0
            if count > 1 then return nil, "document_chapter_ambiguous" end
        end
    end
    local selected, ranges = Chapters.map({ getToc = function() return toc end }, chapters, descriptor)
    local entries, by_uid, used = {}, {}, {}
    local last
    for _, chapter in ipairs(selected) do
        local uid = Chapters.uid(chapter)
        local range = ranges[uid]
        if range and range.start_xpointer then
            if used[range.start_xpointer] or by_uid[uid] then
                return nil, "document_chapter_ambiguous"
            end
            if last and before(document, last, range.start_xpointer) ~= true then
                return nil, "document_chapter_order_invalid"
            end
            local entry = { chapter = chapter, range = range }
            entries[#entries + 1] = entry
            by_uid[uid] = entry
            used[range.start_xpointer] = true
            last = range.start_xpointer
        end
    end
    if #entries == 0 then return nil, "document_chapter_unmapped" end
    return { entries = entries, by_uid = by_uid }
end

function ReaderPosition.capture(document, mapping)
    local point = call(document, "getXPointer")
    if not point or not mapping then return nil, "document_position_unavailable" end
    local lo, hi, entry = 1, #mapping.entries, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local candidate = mapping.entries[mid]
        local cmp = call(document, "compareXPointers", candidate.range.start_xpointer, point)
        if cmp == nil then return nil, "document_position_unavailable" end
        if cmp == 0 or cmp == 1 then entry = candidate; lo = mid + 1
        else hi = mid - 1 end
    end
    if not entry then return nil, "document_chapter_unmapped" end
    local range = entry.range
    if range.end_xpointer and before(document, point, range.end_xpointer) ~= true then
        -- Do not stretch a preceding mapped chapter across an unmapped sibling.
        return nil, "document_chapter_unmapped"
    end
    local start, finish, height = bounds(document, range)
    local pos = number(call(document, "getPosFromXPointer", point))
    if not start or not pos or pos < start or pos > finish then
        return nil, "document_chapter_bounds_unavailable"
    end
    return {
        chapter_uid = entry.chapter.chapterUid or entry.chapter.chapterId or entry.chapter.chapter_uid,
        chapter_fraction = (pos - start) / (finish - start),
        document_fraction = pos / height,
        local_xpointer = point,
        chapter_verified = true,
        offset_basis = "chapter_layout_estimate",
    }
end

function ReaderPosition.target(document, mapping, chapters, remote)
    local uid = remote.chapter_uid
    local entry = uid ~= nil and mapping and mapping.by_uid[tostring(uid)]
    if not entry then return nil, "remote_chapter_unmapped" end
    local offset = number(remote.raw_chapter_offset or remote.chapter_offset)
    if remote.has_chapter_offset == false or remote.chapter_offset_present == false
        or not offset or offset < 0 then return nil, "remote_offset_unavailable" end
    local item = Mapper.catalog(chapters).by_uid[tostring(uid)]
    -- Do not silently clamp an htmlPos into a word-count range.
    if not item or item.words <= 0 or offset > item.words then
        return nil, "remote_offset_unit_unresolved"
    end
    local start, finish, height = bounds(document, entry.range)
    if not start then return nil, "document_chapter_bounds_unavailable" end
    local target_pos = start + offset / item.words * (finish - start)
    local xp = entry.range.start_xpointer
    if offset > 0 then
        -- GotoPercent uses pages in page mode and document height in scroll
        -- mode. Never feed a height fraction into that mode-dependent API.
        -- Find the target page's XPointer, then use native GotoXPointer in both.
        local count = number(call(document, "getPageCount"))
        if not count or count < 1 then return nil, "document_pages_unavailable" end
        local low, high = 1, math.floor(count)
        while low <= high do
            local middle = math.floor((low + high) / 2)
            local candidate = call(document, "getPageXPointer", middle)
            local y = candidate and number(call(document, "getPosFromXPointer", candidate))
            if not y then return nil, "document_pages_unavailable" end
            if y <= target_pos then
                if y >= start and y < finish then xp = candidate end
                low = middle + 1
            else high = middle - 1 end
        end
    end
    return {
        fraction = target_pos / height,
        xpointer = xp,
        chapter = entry.chapter,
        requires_chapter_open = false,
        offset_basis = "chapter_layout_estimate",
    }
end

return ReaderPosition

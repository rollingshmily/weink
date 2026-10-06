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

local function title_index(items)
    local exact, normalized = {}, {}
    for index, item in ipairs(items) do
        local title = tostring(item.title or "")
        local norm = Chapters.normalize(title)
        exact[title] = exact[title] or {}
        normalized[norm] = normalized[norm] or {}
        exact[title][#exact[title] + 1] = index
        normalized[norm][#normalized[norm] + 1] = index
    end
    return exact, normalized
end

function ReaderPosition.prepare(document, book, chapters)
    local original = call(document, "getToc")
    if type(original) ~= "table" or #original == 0 then return nil, "document_toc_unavailable" end
    -- Repeated links to the same title AND XPointer are aliases, not ambiguity.
    -- Never merge two different titles merely because they share a position.
    local toc, aliases, positions = {}, {}, {}
    for _, item in ipairs(original) do
        local title = tostring(item.title or "")
        local previous = item.xpointer and aliases[item.xpointer]
            and aliases[item.xpointer][title]
        if previous then
            previous.depth = math.min(tonumber(previous.depth) or 1, tonumber(item.depth) or 1)
        else
            local copy = {}
            for key, value in pairs(item) do copy[key] = value end
            toc[#toc + 1] = copy
            if item.xpointer then
                aliases[item.xpointer] = aliases[item.xpointer] or {}
                aliases[item.xpointer][title] = copy
                positions[item.xpointer] = positions[item.xpointer] or #toc
            end
        end
    end
    -- Only an explicit download manifest asserts positional chapter order.
    local descriptor = book.annotation_documents and book.annotation_documents[document.file]
    local filtered, blocked, ambiguous = chapters, {}, 0
    if not descriptor then
        filtered = {}
        local exact, normalized = title_index(toc)
        local cloud_exact, cloud_normalized = title_index(chapters)
        -- Short titles repeat across a long novel. When both sides repeat a
        -- title the same number of times and the occurrences stay in step,
        -- Chapters.map pairs k-th with k-th in document order; counts that
        -- disagree or drift beyond a few entries stay gated instead.
        local function occurrences_aligned(candidates, owners)
            if #candidates ~= #owners then return false end
            for k = 1, #candidates do
                if math.abs(candidates[k] - owners[k]) > 16 then return false end
            end
            return true
        end
        for _, chapter in ipairs(chapters) do
            local title = tostring(chapter.title or "")
            local norm = Chapters.normalize(title)
            local candidates = exact[title] or normalized[norm] or {}
            local owners = exact[title] and cloud_exact[title] or cloud_normalized[norm]
            if title ~= "" and #candidates == 1 and #owners == 1 then
                filtered[#filtered + 1] = chapter
            elseif title ~= "" and #candidates >= 2
                and occurrences_aligned(candidates, owners or {}) then
                filtered[#filtered + 1] = chapter
            elseif #candidates > 0 then
                ambiguous = ambiguous + 1
                for _, index in ipairs(candidates) do blocked[index] = true end
            end
        end
    end
    local selected, ranges = Chapters.map({ getToc = function() return toc end }, filtered, descriptor)
    local starts, uids = {}, {}
    for _, chapter in ipairs(selected) do
        local uid = Chapters.uid(chapter)
        local range = ranges[uid]
        if range and range.start_xpointer then
            starts[range.start_xpointer] = (starts[range.start_xpointer] or 0) + 1
            uids[uid] = (uids[uid] or 0) + 1
        end
    end
    -- Isolate colliding UID/start ranges instead of disabling unrelated chapters.
    for _, chapter in ipairs(selected) do
        local uid = Chapters.uid(chapter)
        local range = ranges[uid]
        if range and (starts[range.start_xpointer] > 1 or uids[uid] > 1) then
            blocked[positions[range.start_xpointer]] = true
            ambiguous = ambiguous + 1
        end
    end
    local next_blocked, following = {}, nil
    for index = #toc, 1, -1 do
        next_blocked[index] = following
        if blocked[index] then following = index end
    end
    local entries, by_uid, last = {}, {}, nil
    for _, chapter in ipairs(selected) do
        local uid = Chapters.uid(chapter)
        local range = ranges[uid]
        local index = range and positions[range.start_xpointer]
        if index and not blocked[index] then
            if last and before(document, last, range.start_xpointer) ~= true then
                return nil, "document_chapter_order_invalid"
            end
            -- An ambiguous nested TOC node must not leak into its mapped parent.
            local blocked_index = next_blocked[index]
            local stop = blocked_index and toc[blocked_index].xpointer
            if stop and (not range.end_xpointer
                or before(document, stop, range.end_xpointer) == true) then
                range.end_xpointer = stop
            end
            local entry = { chapter = chapter, range = range }
            entries[#entries + 1] = entry
            by_uid[uid] = entry
            last = range.start_xpointer
        end
    end
    if #entries == 0 then
        return nil, ambiguous > 0 and "document_chapter_ambiguous" or "document_chapter_unmapped"
    end
    return { entries = entries, by_uid = by_uid, toc_count = #toc,
        ambiguous_count = ambiguous, alias_count = #original - #toc }
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

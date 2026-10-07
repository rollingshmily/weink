-- Pure reader-coordinate tests: no network/account or filesystem mutation.
package.path = "./?.lua;" .. package.path
local Reader = require("weink.lib.reader_position")
local Mapper = require("weink.lib.position_mapper")
local checks = 0
local function eq(a, b, label)
    checks = checks + 1
    assert(a == b, (label or "mismatch") .. ": " .. tostring(a) .. " != " .. tostring(b))
end
local chapters = {
    { chapterUid = 9, title = "第九章 九", wordCount = 100, chapterIdx = 9 },
    { chapterUid = 10, title = "第十章 十", wordCount = 300, chapterIdx = 10 },
    { chapterUid = 11, title = "第十一章 十一", wordCount = 600, chapterIdx = 11 },
}
local toc = {
    { title = chapters[1].title, xpointer = "0", depth = 1 },
    { title = chapters[2].title, xpointer = "6000", depth = 1 },
    { title = chapters[3].title, xpointer = "9000", depth = 1 },
}
local point = "5900"
local document = {
    file = "full.epub", info = { doc_height = 10000 },
    getToc = function() return toc end,
    getXPointer = function() return point end,
    getPosFromXPointer = function(_, xp) return tonumber(xp) end,
    getPageCount = function() return 100 end,
    getPageXPointer = function(_, p) return tostring((p - 1) * 100) end,
    compareXPointers = function(_, a, b)
        a, b = tonumber(a), tonumber(b)
        return a == b and 0 or (a < b and 1 or -1)
    end,
}
local mapping = assert(Reader.prepare(document, {}, chapters))
local resolved = assert(Reader.capture(document, mapping))
eq(resolved.chapter_uid, 9, "real chapter wins over whole-book fraction")
eq(resolved.chapter_verified, true)
eq(resolved.offset_basis, "chapter_layout_estimate")
local old = assert(Mapper.local_to_remote(chapters, 0.59, { is_full_book = true }))
eq(old.chapter_uid, 11, "fixture exposes wrong global word-count chapter")
local position = assert(Mapper.local_to_remote(chapters, 0.59,
    { is_full_book = true, resolved_chapter = resolved }))
eq(position.chapter_uid, 9)
eq(position.chapter_offset, 98)
eq(position.local_xpointer, point)
eq(Mapper.compare(position, { chapter_uid = 10, percent = 9.8, chapter_offset = 98 }), "different")
eq(Mapper.compare(position, { chapter_uid = 9, percent = 9.8, chapter_offset = 99 }), "unknown")
eq(Mapper.compare(position, { chapter_uid = 9, percent = 99, chapter_offset = 98 }), "same")
eq(Mapper.compare(position, { percent = 9.8 }), "unknown")
for _, bad in ipairs({ -1, math.huge, 0/0, 1.5 }) do
    eq(Mapper.compare(position, { chapter_uid = 9, chapter_offset = bad }), "unknown")
end
point = "6000"
eq(assert(Reader.capture(document, mapping)).chapter_uid, 10, "exact chapter boundary")
point = "9999"
eq(assert(Reader.capture(document, mapping)).chapter_uid, 11, "last page uses real document end")
local target = assert(Reader.target(document, mapping, chapters,
    { chapter_uid = 10, chapter_offset = 150 }))
eq(target.xpointer, "7500", "inverse mapping uses target chapter, not global words")
eq(target.fraction, 0.75)
eq(target.offset_basis, "chapter_layout_estimate")
local invalid, reason = Reader.target(document, mapping, chapters,
    { chapter_uid = 10, chapter_offset = 999 })
eq(invalid, nil); eq(reason, "remote_offset_unit_unresolved")
invalid, reason = Reader.target(document, mapping, chapters,
    { chapter_uid = 10, chapter_offset = 0, has_chapter_offset = false })
eq(invalid, nil); eq(reason, "remote_offset_unavailable")

-- Gaps must not be attributed to the preceding mapped chapter; sparse catalogs
-- must still locate the later chapter rather than the old binary-search hole.
table.insert(toc, 2, { title = "未匹配的插页", xpointer = "4000", depth = 1 })
mapping = assert(Reader.prepare(document, {}, chapters))
point = "4500"
invalid, reason = Reader.capture(document, mapping)
eq(invalid, nil); eq(reason, "document_chapter_unmapped")
point = "7000"
eq(assert(Reader.capture(document, mapping)).chapter_uid, 10)
local sparse = { chapters[1], { chapterUid = 88, title = "缺失章节", wordCount = 99 }, chapters[3] }
local sparse_map = assert(Reader.prepare(document, {}, sparse))
point = "9200"
eq(assert(Reader.capture(document, sparse_map)).chapter_uid, 11)

local old_height = document.info.doc_height
document.info.doc_height = nil
invalid, reason = Reader.capture(document, mapping)
eq(invalid, nil); eq(reason, "document_chapter_bounds_unavailable")
document.info.doc_height = old_height
local saved_point = document.getXPointer
document.getXPointer = function() error("unavailable") end
eq(Reader.capture(document, mapping), nil)
document.getXPointer = saved_point

-- An ambiguous title is isolated; it does not invalidate other chapters.
toc[#toc + 1] = { title = chapters[3].title, xpointer = "9900", depth = 1 }
mapping = assert(Reader.prepare(document, {}, chapters))
point = "9200"
invalid, reason = Reader.capture(document, mapping)
eq(invalid, nil); eq(reason, "document_chapter_unmapped")
point = "7000"
eq(assert(Reader.capture(document, mapping)).chapter_uid, 10, "unrelated chapter still resolves")
eq(Reader.prepare({ getToc = function() return {} end }, {}, chapters), nil)
-- Regression: layout height and chapter text length disagree. An image-only
-- block makes the start of the chapter tall but carries no characters, so a
-- height fraction lands later than the cloud character offset. The APK treats
-- the offset as a character position (BookPosition.convertFromServeProgress),
-- so the text length must decide where to land.
do
    local function text_len(xp)
        -- Pages are 100 height units apart; the chapter spans 6000..9000 and
        -- the first 1000 units are an image block with no characters.
        if xp <= 7000 then return 0 end
        if xp >= 9000 then return 300 end
        return math.floor((xp - 7000) / 2000 * 300)
    end
    local text_document = {
        file = "full.epub", info = { doc_height = 10000 },
        getToc = function()
            return {
                { title = "第十章 十", xpointer = "6000", depth = 1 },
                { title = "第十一章 十一", xpointer = "9000", depth = 1 },
            }
        end,
        getXPointer = function() return "8000" end,
        getPosFromXPointer = function(_, xp) return tonumber(xp) end,
        getPageCount = function() return 100 end,
        getPageXPointer = function(_, p) return tostring((p - 1) * 100) end,
        compareXPointers = function(_, a, b)
            a, b = tonumber(a), tonumber(b)
            return a == b and 0 or (a < b and 1 or -1)
        end,
        getTextFromXPointers = function(_, first, last)
            local from, to = tonumber(first), tonumber(last)
            if not from or not to or to <= from then return "" end
            return string.rep("x", math.max(0, text_len(to) - text_len(from)))
        end,
    }
    local text_chapters = {
        { chapterUid = 10, title = "第十章 十", wordCount = 300, chapterIdx = 10 },
        { chapterUid = 11, title = "第十一章 十一", wordCount = 300, chapterIdx = 11 },
    }
    local text_mapping = assert(Reader.prepare(text_document, {}, text_chapters))
    local text_target = assert(Reader.target(text_document, text_mapping,
        text_chapters, { chapter_uid = 10, chapter_offset = 150 }))
    -- The height fraction would land on 7500; character 150 sits at 8000.
    eq(text_target.xpointer, "8000", "character offset decides, not layout height")
    local height_only = assert(Reader.target(text_document, text_mapping,
        text_chapters, { chapter_uid = 10, chapter_offset = 100 }))
    eq(height_only.xpointer, "7600", "text length still drives the search")
end

print(("reader_position_spec: %d checks passed"):format(checks))

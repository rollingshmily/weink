-- Regression: an unrelated repeated title must not disable a whole book.
package.path = "./?.lua;" .. package.path
local Reader = require("weread.lib.reader_position")
local checks = 0
local function eq(got, expected, label)
    checks = checks + 1
    assert(got == expected, label .. ": " .. tostring(got) .. " != " .. tostring(expected))
end
local function fixture(toc, chapters, book)
    local point = "500"
    local doc = {
        file = "full.epub", info = { doc_height = 4000 },
        getToc = function() return toc end,
        getXPointer = function() return point end,
        getPosFromXPointer = function(_, xp) return tonumber(xp) end,
        getPageCount = function() return 40 end,
        getPageXPointer = function(_, p) return tostring((p - 1) * 100) end,
        compareXPointers = function(_, a, b)
            a, b = tonumber(a), tonumber(b)
            return a == b and 0 or (a < b and 1 or -1)
        end,
    }
    local mapping, err = Reader.prepare(doc, book or {}, chapters)
    assert(mapping, "unrelated title ambiguity must not reject this book: " .. tostring(err))
    return function(xp)
        point = xp
        return Reader.capture(doc, mapping)
    end, mapping, doc
end
local function chapter(uid, title) return { chapterUid = uid, title = title, wordCount = 100 } end
local function entry(title, xp, depth) return { title = title, xpointer = xp, depth = depth or 1 } end
local catalog = { chapter(1, "炼瞳"), chapter(2, "重复标题"), chapter(3, "后章") }
local toc = { entry("炼瞳", "0"), entry("重复标题", "1000"),
    entry("重复标题", "2000"), entry("后章", "3000") }
local capture, mapping, doc = fixture(toc, catalog)
eq(assert(capture("500")).chapter_uid, 1, "unrelated duplicate does not block current chapter")
eq(assert(capture("3500")).chapter_uid, 3, "later known chapter remains available")
eq(capture("1500"), nil, "actually ambiguous chapter stays gated")
eq(capture("2500"), nil, "second ambiguous candidate is not guessed")
eq(mapping.by_uid["2"], nil, "ambiguous UID has no upload/jump mapping")
eq(Reader.target(doc, mapping, catalog, { chapter_uid = 2, chapter_offset = 0 }), nil,
    "cloud jump cannot choose an ambiguous occurrence")

-- Same target referenced twice is a TOC alias, not two possible positions.
capture = fixture({ entry("炼瞳", "0"), entry("炼瞳", "0", 2), entry("后章", "3000") },
    { catalog[1], catalog[3] })
eq(assert(capture("500")).chapter_uid, 1, "identical TOC alias collapsed")
eq(assert(capture("3500")).chapter_uid, 3, "alias does not alter next boundary")

-- Chapter numbers in an exact title must not be discarded before comparison.
capture = fixture({ entry("第一章 重复", "0"), entry("第二章 重复", "1000"), entry("后章", "3000") },
    { chapter(1, "第一章 重复"), chapter(2, "第二章 重复"), chapter(3, "后章") })
eq(assert(capture("1500")).chapter_uid, 2, "unique exact numbered titles still work")

-- Ambiguity in the cloud catalog must not assign the first matching UID.
capture = fixture({ entry("重复标题", "0"), entry("炼瞳", "1000"), entry("后章", "3000") },
    { chapter(8, "重复标题"), chapter(9, "重复标题"), catalog[1], catalog[3] })
eq(capture("500"), nil, "two cloud UIDs for one title remain unmapped")
eq(assert(capture("1500")).chapter_uid, 1, "unrelated catalog ambiguity is isolated")

-- Two distinct chapter names pointing at the same start must be isolated too.
capture = fixture({ entry("冲突一", "0"), entry("冲突二", "0"), entry("炼瞳", "1000"), entry("后章", "3000") },
    { chapter(8, "冲突一"), chapter(9, "冲突二"), catalog[1], catalog[3] })
eq(capture("500"), nil, "different UIDs sharing one XPointer are not trusted")
eq(assert(capture("1500")).chapter_uid, 1, "unrelated same-XPointer conflict is isolated")

-- An excluded nested chapter may not be swallowed by the prior parent's range.
capture = fixture({ entry("炼瞳", "0"), entry("重复标题", "1000", 2),
    entry("重复标题", "2000", 2), entry("后章", "3000") }, catalog)
eq(assert(capture("500")).chapter_uid, 1, "parent before ambiguous nested heading works")
eq(capture("1500"), nil, "ambiguous nested heading is not assigned to parent")
eq(assert(capture("3500")).chapter_uid, 3, "next known chapter works after ambiguous nested heading")

-- Explicit download manifests keep their existing authoritative ordering.
local selected = { chapter(8, "重复标题"), chapter(9, "重复标题"), catalog[1] }
capture = fixture({ entry("重复标题", "0"), entry("重复标题", "1000"), entry("炼瞳", "2000") },
    selected, { annotation_documents = { ["full.epub"] = { chapters = selected } } })
eq(assert(capture("1500")).chapter_uid, 9, "explicit manifest disambiguates repeated titles")

print(("reader_position_ambiguity_spec: %d checks passed"):format(checks))

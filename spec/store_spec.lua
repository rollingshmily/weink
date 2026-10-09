-- Unit tests for weink/lib/store.lua (storefront data shaping).
-- Run from the repo root:
--   luajit spec/store_spec.lua
--
-- Fixtures mirror the live payloads verified against i.weread.qq.com on
-- 2026-10-09 but contain no account identifiers, tokens or book content.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["weink.lib.i18n"] = function()
    return { tr = function(text) return text end }
end

local Store = require("weink.lib.store")

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

-- ---------------------------------------------------------------- books

test("normalizes a feed book wrapped in bookInfo", function()
    local book = Store.book({
        bookInfo = {
            bookId = 695233,
            title = "Sample",
            author = "Author",
            cover = "https://example.test/c.jpg",
            price = 89.99,
            centPrice = 8999,
            payType = 4097,
            payingStatus = 1,
            paid = 1,
            soldout = 0,
            bookStatus = 1,
            maxFreeChapter = 24,
            totalWords = 884061,
            newRating = 930,
            newRatingCount = 295515,
        },
        searchIdx = 1,
    })
    eq(book.book_id, "695233", "bookId is stringified")
    eq(book.title, "Sample", "title")
    eq(book.price, 89.99, "price")
    eq(book.paid, true, "paid flag")
    eq(book.free, false, "free defaults to false")
    eq(book.max_free_chapter, 24, "free chapter count")
    eq(book.rating, 930, "rating")
end)

test("negative price means 'no whole-book price'", function()
    local book = Store.book({ bookId = 1, price = -1, unitPrice = 0.05 })
    eq(book.price, nil, "negative price dropped")
    eq(book.unit_price, 0.05, "unit price kept")
end)

test("entries without a bookId are dropped", function()
    eq(#Store.books({ { title = "no id" }, { bookId = "2" } }), 1, "only valid rows")
end)

-- --------------------------------------------------------------- search

test("search result flattens books and keeps correction", function()
    local parsed = Store.search_result({
        books = { { bookInfo = { bookId = "1", title = "A" } } },
        totalCount = 42,
        hasMore = 1,
        correction = "Sample",
    })
    eq(#parsed.books, 1, "books")
    eq(parsed.total, 42, "total")
    eq(parsed.has_more, true, "hasMore numeric 1")
    eq(parsed.correction, "Sample", "correction surfaced")
end)

test("search result tolerates a missing body", function()
    local parsed = Store.search_result(nil)
    eq(#parsed.books, 0, "no books")
    eq(parsed.has_more, false, "no more")
    eq(parsed.correction, nil, "no correction")
end)

test("suggestions keep only non-empty words", function()
    local words = Store.suggestions({ records = {
        { word = "Sample", totalCount = 3 },
        { word = "" },
        { totalCount = 9 },
    } })
    eq(#words, 1, "one usable suggestion")
    eq(words[1].word, "Sample", "word")
    eq(words[1].count, 3, "count")
end)

-- -------------------------------------------------------------- sections

test("sections skip banners and flatten books", function()
    local sections = Store.sections({ data = {
        { type = 11, name = " ", banners = { { id = 1 } } },
        { type = 1, name = "  Picks ", totalCount = 18, hasMore = 1,
          books = { { bookInfo = { bookId = "1", title = "A" } } } },
    } })
    eq(#sections, 1, "banner section dropped")
    eq(sections[1].name, "Picks", "name trimmed")
    eq(sections[1].total, 18, "total")
    eq(sections[1].has_more, true, "hasMore")
    eq(#sections[1].books, 1, "books")
end)

test("sections keep category tiles and topic lists", function()
    local sections = Store.sections({ data = {
        { type = 12, name = "Rank", categories = {
            { categoryId = "100001", title = "Social", totalCount = 11302 },
        } },
        { type = 10, name = "Lists", topics = {
            { topicId = "t1", title = "Curated" },
        } },
    } })
    eq(#sections[0 + 1].categories, 1, "category tile")
    eq(sections[1].categories[1].category_id, "100001", "category id")
    eq(#sections[2].topics, 1, "topic list")
    eq(sections[2].topics[1].topic_id, "t1", "topic id")
end)

-- -------------------------------------------------------------- category

test("category list merges novel roots and e-book categories once", function()
    local tree = Store.category_list({
        novelCategories = { { categoryId = "1900000", title = "Male" } },
        categories = {
            { categoryId = "100006", title = "Fantasy", totalCount = 1821 },
            { categoryId = "1900000", title = "Male" },
        },
    })
    eq(#tree, 2, "deduplicated by id")
    eq(tree[1].title, "Male", "novel roots first")
    eq(tree[2].total, 1821, "category total")
end)

test("live category tree preserves every root and its descendants", function()
    local fixture = dofile("spec/fixtures/store_categories_20261009.lua")
    local flat = Store.category_list(fixture)
    local groups = Store.category_groups(fixture)
    eq(#flat, 57, "public category fixture contains 57 unique IDs")
    eq(#groups, 22, "all 22 roots are retained, not only the three with children")
    local represented, leaves, child_count = {}, 0, 0
    for _i, group in ipairs(groups) do
        represented[group.category_id] = true
        if #group.children == 0 then leaves = leaves + 1 end
        for _j, child in ipairs(group.children) do
            represented[child.category_id] = true
            child_count = child_count + 1
        end
    end
    eq(leaves, 19, "19 standalone categories are not filtered out")
    eq(child_count, 35, "existing novel subcategories are unchanged")
    for _i, node in ipairs(flat) do
        eq(represented[node.category_id], true, "category retained: " .. node.title)
    end
end)

test("category node exposes children for a second drill-down", function()
    local node = Store.category_node({
        CategoryId = "100000",
        title = "Picks",
        totalCount = 42174,
        bookTitles = { "A", "B" },
        sublist = { { CategoryId = "100001", title = "Social", totalCount = 11302 } },
    })
    eq(node.category_id, "100000", "id")
    eq(#node.children, 1, "child count")
    eq(node.children[1].category_id, "100001", "child id")
end)

test("category books report the next page cursor", function()
    local page = Store.category_books({
        books = { { bookInfo = { bookId = "1" } } },
        hasMore = 1,
        synckey = 1,
        totalCount = 11302,
    })
    eq(#page.books, 1, "books")
    eq(page.has_more, true, "hasMore")
    eq(page.max_idx, 1, "paging cursor")
end)

-- ---------------------------------------------------------- availability

local function expect_availability(fields, downloadable, reason)
    local state = Store.availability(Store.book(fields))
    eq(state.downloadable, downloadable, "downloadable for " .. tostring(fields.bookId))
    eq(state.reason, reason, "reason for " .. tostring(fields.bookId))
end

test("owned books are downloadable", function()
    expect_availability({ bookId = "1", paid = 1, payingStatus = 1 }, true, "owned")
    expect_availability({ bookId = "2", payingStatus = 1 }, true, "owned")
    expect_availability({ bookId = "3", free = 1 }, true, "owned")
end)

test("purchasable books are not downloadable", function()
    expect_availability({ bookId = "1", payingStatus = 2, maxFreeChapter = 7 }, false, "trial")
    expect_availability({ bookId = "2", payingStatus = 2 }, false, "paid")
end)

test("sold-out books are never downloadable", function()
    expect_availability({ bookId = "1", soldout = 1, paid = 1 }, false, "soldout")
end)

test("per-chapter serials report a paid state", function()
    expect_availability({ bookId = "1", payingStatus = 4, unitPrice = 0.05,
                          price = -1, maxFreeChapter = 151 }, false, "paid")
end)

test("availability labels stay human readable", function()
    local trial = Store.availability(Store.book({ bookId = "1", payingStatus = 2,
        maxFreeChapter = 7 }))
    eq(trial.label, "Free trial", "trial label")
    local owned = Store.availability(Store.book({ bookId = "2", paid = 1 }))
    eq(owned.label, "Available", "owned label")
end)

-- ---------------------------------------------------------------- prices

test("price labels cover whole-book, per-chapter and owned", function()
    eq(Store.price_label(Store.book({ bookId = "1", price = 89.99 })), "¥89.99",
        "whole book price")
    eq(Store.price_label(Store.book({ bookId = "2", price = -1, unitPrice = 0.05 })),
        "¥0.05/chapter", "per-chapter price")
    eq(Store.price_label(Store.book({ bookId = "3", paid = 1 })), "Owned", "owned")
    eq(Store.price_label(Store.book({ bookId = "4", free = 1 })), "Owned", "free")
    eq(Store.price_label(Store.book({ bookId = "5" })), "", "no price")
end)

print(string.format("store_spec: %d checks, %d failure(s)", checks, failures))
if failures > 0 then os.exit(1) end

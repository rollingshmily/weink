-- WeRead store/storefront data layer.
--
-- Pure, device-free helpers that turn raw eink JSON (verified live against
-- i.weread.qq.com on 2026-10-09) into the flat rows the UI renders. No KOReader
-- widgets, no network: the UI layer owns both.

local I18n = require("weink.lib.i18n")

local _ = I18n.tr

local Store = {}

-- Section types seen in /store/list and /store/recommend. `books` sections
-- carry a book list; `categories` sections carry entry tiles; `topics` carry
-- curated lists; `banners` are image-only and get skipped by the UI.
-- Audio (24) has no use on an e-ink reader, so it never reaches the UI.
Store.SKIPPED_SECTION_TYPES = { [24] = true }

Store.SECTION_TYPE = {
    BANNER = 11,
    CATEGORY_ENTRANCE = 13,
    RANK = 14,
    RANK_CATEGORY = 12,
    TOPIC_LIST = 10,
}

-- Books whose payType carries the "whole book purchase" bit can be downloaded
-- only after paying. payingStatus values verified live 2026-10-09:
--   1 = already owned, 2 = purchasable, 4 = per-chapter serial.
local OWNED, PURCHASABLE, SERIAL = 1, 2, 4

local function number(value)
    local n = tonumber(value)
    return n
end

-- Flat book record shared by every store surface (feed, category, search,
-- similar). Both the store feed shape (`bookInfo` wrapper) and the bare search
-- book shape are accepted.
function Store.book(raw)
    if type(raw) ~= "table" then return nil end
    local info = raw.bookInfo or raw
    local book_id = tostring(info.bookId or info.book_id or "")
    if book_id == "" then return nil end
    local price = number(info.price)
    if price and price < 0 then price = nil end
    return {
        book_id = book_id,
        title = tostring(info.title or ""),
        author = tostring(info.author or ""),
        translator = tostring(info.translator or ""),
        cover = tostring(info.cover or ""),
        intro = tostring(info.intro or ""),
        publisher = tostring(info.publisher or ""),
        category = tostring(info.category or info.categoryName or ""),
        deep_link = tostring(info.deepLink or ""),
        price = price,
        cent_price = number(info.centPrice),
        unit_price = number(info.unitPrice),
        original_price = number(info.originalPrice),
        pay_type = number(info.payType),
        paying_status = number(info.payingStatus),
        paid = number(info.paid) == 1,
        free = number(info.free) == 1,
        secret = number(info.secret) == 1,
        soldout = number(info.soldout) == 1,
        book_status = number(info.bookStatus),
        max_free_chapter = number(info.maxFreeChapter),
        is_chapter_paid = number(info.isChapterPaid) == 1,
        mcard_discount = number(info.mcardDiscount),
        word_count = number(info.totalWords),
        rating = number(info.newRating),
        rating_count = number(info.newRatingCount),
        ranklist = type(info.ranklist) == "table" and info.ranklist or nil,
    }
end

function Store.books(entries)
    local out = {}
    for _i, entry in ipairs(entries or {}) do
        local book = Store.book(entry)
        if book then out[#out + 1] = book end
    end
    return out
end

-- `/store/search` -> flat books. The endpoint also returns `correction` when
-- it guessed a different spelling, which the UI surfaces instead of silently
-- showing results for another word.
function Store.search_result(response)
    if type(response) ~= "table" then
        return { books = {}, total = 0, has_more = false, correction = nil }
    end
    return {
        books = Store.books(response.books),
        total = number(response.totalCount) or 0,
        has_more = response.hasMore == 1 or response.hasMore == true,
        correction = tostring(response.correction or "") ~= ""
            and tostring(response.correction) or nil,
    }
end

-- `/store/suggest` -> plain suggestion words (text only).
function Store.suggestions(response)
    local out = {}
    if type(response) ~= "table" then return out end
    for _i, record in ipairs(response.records or {}) do
        local word = tostring(record.word or "")
        if word ~= "" then
            out[#out + 1] = { word = word, count = number(record.totalCount) or 0 }
        end
    end
    return out
end

-- A whole `/store/list` or `/store/recommend` response -> ordered sections.
function Store.sections(response)
    local out = {}
    if type(response) ~= "table" then return out end
    for _i, raw in ipairs(response.data or {}) do
        local kind = number(raw.type) or 0
        if kind ~= Store.SECTION_TYPE.BANNER and not Store.SKIPPED_SECTION_TYPES[kind] then
            local entry = {
                type = kind,
                name = tostring(raw.name or ""):gsub("^%s+", ""):gsub("%s+$", ""),
                total = number(raw.totalCount) or 0,
                has_more = raw.hasMore == 1,
                books = Store.books(raw.books),
                categories = {},
                topics = {},
            }
            for _j, category in ipairs(raw.categories or {}) do
                entry.categories[#entry.categories + 1] = {
                    category_id = tostring(category.categoryId or category.CategoryId or ""),
                    title = tostring(category.title or ""),
                    sub_title = tostring(category.subTitle or ""),
                    total = number(category.totalCount) or 0,
                    books = Store.books(category.books),
                    book_titles = category.bookTitles or {},
                }
            end
            for _j, topic in ipairs(raw.topics or {}) do
                entry.topics[#entry.topics + 1] = {
                    topic_id = tostring(topic.topicId or topic.booklistId or ""),
                    title = tostring(topic.title or topic.name or ""),
                    books = Store.books(topic.books),
                }
            end
            out[#out + 1] = entry
        end
    end
    return out
end

-- `/category/list` -> flat [{category_id, title, total}] including the novel
-- root nodes, deduplicated by id and ordered as the server returns them.
function Store.category_list(response)
    local out, seen = {}, {}
    if type(response) ~= "table" then return out end
    local function add(node)
        local id = tostring(node.categoryId or node.CategoryId or "")
        if id == "" or seen[id] then return end
        seen[id] = true
        out[#out + 1] = {
            category_id = id,
            title = tostring(node.title or ""),
            total = number(node.totalCount) or 0,
            level = number(node.level) or 1,
            parent_id = tostring(node.parentCategoryId or ""),
        }
    end
    for _i, node in ipairs(response.novelCategories or {}) do add(node) end
    for _i, node in ipairs(response.categories or {}) do add(node) end
    return out
end

-- `/store/categories?categoryId=...` -> one node plus its children.
function Store.category_node(response)
    if type(response) ~= "table" then return nil end
    local node = {
        category_id = tostring(response.CategoryId or response.categoryId or ""),
        title = tostring(response.title or ""),
        total = number(response.totalCount) or 0,
        book_titles = response.bookTitles or {},
        children = {},
    }
    for _i, child in ipairs(response.sublist or {}) do
        local id = tostring(child.CategoryId or child.categoryId or "")
        if id ~= "" then
            node.children[#node.children + 1] = {
                category_id = id,
                title = tostring(child.title or ""),
                total = number(child.totalCount) or 0,
            }
        end
    end
    return node
end

-- `/store/category?categoryId=...` -> paginated books.
function Store.category_books(response)
    if type(response) ~= "table" then
        return { books = {}, total = 0, has_more = false, max_idx = 0 }
    end
    local books = Store.books(response.books)
    return {
        books = books,
        total = number(response.totalCount) or 0,
        has_more = response.hasMore == 1 or response.hasMore == true,
        max_idx = number(response.synckey) or 0,
    }
end

-- Whether the whole book can be pulled down right now, and why not when it
-- cannot. Costs and entitlements come from /book/info (verified live
-- 2026-10-09; see memory/2026-10-09.md for the field dump).
function Store.availability(book)
    if type(book) ~= "table" then
        return { downloadable = false, label = "" }
    end
    if book.soldout then
        return { downloadable = false, reason = "soldout", label = _("Unavailable") }
    end
    if book.free or book.paid or book.paying_status == OWNED then
        return { downloadable = true, reason = "owned", label = _("Available") }
    end
    -- Serial novels and per-chapter titles are sold chapter by chapter; the
    -- free prefix is still readable, but the book itself is not.
    if book.paying_status == SERIAL
        or (book.price == nil and book.unit_price) then
        if book.max_free_chapter and book.max_free_chapter > 0 then
            return {
                downloadable = false,
                reason = "paid",
                label = _("Free first chapters"),
            }
        end
        return { downloadable = false, reason = "paid", label = _("Paid") }
    end
    if book.paying_status == PURCHASABLE then
        if book.max_free_chapter and book.max_free_chapter > 0 then
            return {
                downloadable = false,
                reason = "trial",
                label = _("Free trial"),
            }
        end
        return { downloadable = false, reason = "paid", label = _("Paid") }
    end
    if book.max_free_chapter and book.max_free_chapter > 0 then
        return { downloadable = false, reason = "trial", label = _("Free trial") }
    end
    return { downloadable = true, reason = "unknown", label = "" }
end

-- Price line for a store row: "¥12.99", "¥0.05/chapter", "Free", "".
function Store.price_label(book)
    if type(book) ~= "table" then return "" end
    if book.free or book.paid or book.paying_status == 1 then return _("Owned") end
    if book.price and book.price > 0 then
        return "¥" .. string.format("%.2f", book.price)
    end
    if book.unit_price and book.unit_price > 0 then
        return "¥" .. string.format("%.2f", book.unit_price) .. "/" .. _("chapter")
    end
    return ""
end


-- `/category/list` -> ordered groups for the two-level category screen.
-- Level-1 entries (parent 0) are the first screen's cards; everything whose
-- parentCategoryId points at one of them becomes a second-level card.
-- A root with no child nodes is itself a browsable category, not an empty
-- group to discard (literature, history, computers, etc.).
function Store.category_groups(response)
    local flat = Store.category_list(response)
    local groups = {}
    for _i, node in ipairs(flat) do
        if node.parent_id == "" or node.parent_id == "0" then
            groups[#groups + 1] = {
                category_id = node.category_id,
                title = node.title,
                total = node.total,
                children = {},
            }
        end
    end
    for _i, node in ipairs(flat) do
        if node.parent_id ~= "" and node.parent_id ~= "0" then
            for _j, group in ipairs(groups) do
                if group.category_id == node.parent_id then
                    group.children[#group.children + 1] = node
                    break
                end
            end
        end
    end
    return groups
end
return Store

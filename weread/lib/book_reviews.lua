local BookReviews = {}
local _ = require("weread.lib.i18n").tr

local function trim(text)
    return tostring(text or ""):match("^%s*(.-)%s*$")
end

local function utf8_char(codepoint)
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(
            0xC0 + math.floor(codepoint / 0x40),
            0x80 + codepoint % 0x40
        )
    elseif codepoint < 0x10000 then
        return string.char(
            0xE0 + math.floor(codepoint / 0x1000),
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + codepoint % 0x40
        )
    elseif codepoint <= 0x10FFFF then
        return string.char(
            0xF0 + math.floor(codepoint / 0x40000),
            0x80 + math.floor(codepoint / 0x1000) % 0x40,
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + codepoint % 0x40
        )
    end
    return ""
end

local function decode_entities(text)
    local named = {
        amp = "&",
        apos = "'",
        gt = ">",
        lt = "<",
        nbsp = " ",
        quot = '"',
    }
    text = text:gsub("&#[xX]([%da-fA-F]+);", function(value)
        return utf8_char(tonumber(value, 16) or 0)
    end)
    text = text:gsub("&#(%d+);", function(value)
        return utf8_char(tonumber(value, 10) or 0)
    end)
    return text:gsub("&([%a]+);", function(name)
        return named[name:lower()] or "&" .. name .. ";"
    end)
end

function BookReviews.plain_text(value)
    local text = tostring(value or "")
    text = text:gsub("<[bB][rR]%s*/?%s*>", "\n")
    text = text:gsub("</[pP]%s*>", "\n\n")
    text = text:gsub("</[dD][iI][vV]%s*>", "\n")
    text = text:gsub("<[^>]->", "")
    text = decode_entities(text)
    text = text:gsub("\r\n?", "\n")
    text = text:gsub("[ \t]+\n", "\n")
    text = text:gsub("\n[ \t]+", "\n")
    text = text:gsub("[ \t][ \t]+", " ")
    text = text:gsub("\n\n\n+", "\n\n")
    return trim(text)
end

local function unwrap_review(entry)
    local review = type(entry) == "table" and entry or {}
    for _i = 1, 4 do
        if type(review.review) ~= "table" then
            break
        end
        review = review.review
    end
    return review
end

local function author_name(author)
    if type(author) == "table" then
        return trim(author.nick or author.name or author.userName or author.username)
    end
    return trim(author)
end

-- Rating-only reviews are common in BOOK_WONDERFUL. Test the rendered body,
-- not its HTML wrapper or its length: a one-character review is still useful.
local function review_body(value)
    if type(value) ~= "string" then return "" end
    local text = value:gsub("<!%-%-.-%-%->", "")
    text = text:gsub("<[sS][cC][rR][iI][pP][tT][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>", "")
    text = text:gsub("<[sS][tT][yY][lL][eE][^>]*>.-</[sS][tT][yY][lL][eE]%s*>", "")
    local spacing = { ensp = " ", emsp = " ", thinsp = " ", zwnj = utf8_char(0x200C),
        zwj = utf8_char(0x200D), zerowidthspace = utf8_char(0x200B) }
    text = text:gsub("&([%a]+);", function(name) return spacing[name:lower()] or "&" .. name .. ";" end)
    text = BookReviews.plain_text(text)
    for _i, cp in ipairs({ 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004,
        0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 }) do
        text = text:gsub(utf8_char(cp), " ")
    end
    -- Do not strip joiners from real text (in particular emoji sequences).
    local visible = text
    for _i, cp in ipairs({ 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF }) do
        visible = visible:gsub(utf8_char(cp), "")
    end
    return trim(visible) ~= "" and trim(text) or ""
end

function BookReviews.normalize_item(entry)
    local review = unwrap_review(entry)
    local content = review_body(review.content)
    if content == "" then
        content = review_body(review.htmlContent)
    end
    local rating = tonumber(review.star) or 0
    if rating > 10 then
        rating = rating / 10
    end
    return {
        review_id = review.reviewId or (type(entry) == "table" and entry.reviewId),
        author = author_name(review.author),
        content = content,
        rating = rating,
        create_time = tonumber(review.createTime) or 0,
        is_finish = review.isFinish == true or tonumber(review.isFinish) == 1,
        idx = tonumber(type(entry) == "table" and entry.idx) or 0,
        review_type = tonumber(review.type),
    }
end

function BookReviews.normalize_list(data, opts)
    data = type(data) == "table" and data or {}
    opts = opts or {}
    local only_type = opts.only_type
    local items = {}
    for _i, entry in ipairs(data.reviews or {}) do
        local item = BookReviews.normalize_item(entry)
        if item.content ~= "" and (only_type == nil or item.review_type == only_type) then
            items[#items + 1] = item
        end
    end
    return {
        items = items,
        -- This is the server's total, including rating-only records, not the
        -- number of written reviews visible after filtering.
        total_count = tonumber(data.totalCount) or tonumber(data.reviewsCnt) or #(data.reviews or {}),
        raw_count = #(data.reviews or {}),
        recent_count = tonumber(data.recentTotalCnt) or 0,
        has_more = data.reviewsHasMore == true or tonumber(data.reviewsHasMore) == 1
            or data.hasMore == true or tonumber(data.hasMore) == 1,
        synckey = tonumber(data.synckey),
    }
end

-- Both eink lists are count-limited snapshots. Live BOOK_WONDERFUL returns
-- hasMore=0 even when count=20 cuts the snapshot (count=40 returns more).
-- hasMore, when set, describes incremental sync and uses synckey instead.
-- One request per user action; a filtered-empty page must keep its next action.
function BookReviews.load_more(client, book_id, list_type, review_type, previous)
    local incremental = previous and previous.next_synckey ~= nil
    local count = previous and previous.request_count or 20
    if previous and not incremental then count = count + 20 end
    local cursor = incremental and previous.next_synckey or nil
    local data = client:get_book_reviews(book_id, list_type, count, review_type, cursor)
    assert(type(data) == "table" and type(data.reviews) == "table", _("Invalid book review list."))
    local result = BookReviews.normalize_list(data, { only_type = 4 })
    result.request_count = count
    result.cursors = {}
    result.raw_ids = {}
    if incremental then
        for key in pairs(previous.cursors) do result.cursors[key] = true end
        for key in pairs(previous.raw_ids) do result.raw_ids[key] = true end
    end
    local raw_count = incremental and previous.raw_count or 0
    local new_records = 0
    for _i, entry in ipairs(data.reviews) do
        local review = unwrap_review(entry)
        local id = review.reviewId or (type(entry) == "table" and entry.reviewId)
        id = id and tostring(id)
        if not id or not result.raw_ids[id] then
            raw_count = raw_count + 1
            if not previous or not id or not previous.raw_ids[id] then new_records = new_records + 1 end
        end
        if id then result.raw_ids[id] = true end
    end
    result.raw_count = raw_count
    if incremental and data.totalCount == nil and data.reviewsCnt == nil then
        result.total_count = previous.total_count
    end
    local merged, seen = {}, {}
    for _i, source in ipairs({ incremental and previous.items or {}, result.items }) do
        for _j, item in ipairs(source) do
            local id = item.review_id and tostring(item.review_id)
            if not id or not seen[id] then merged[#merged + 1] = item end
            if id then seen[id] = true end
        end
    end
    result.items = merged
    result.visible_count = #result.items
    if result.has_more then
        assert(result.synckey and result.synckey > 0 and result.synckey ~= cursor
            and not result.cursors[result.synckey], _("Book review pagination did not advance. Reopen and retry."))
        result.next_synckey = result.synckey
        result.cursors[result.synckey] = true
    else
        -- Never use the filtered count, or totalCount (which may include many
        -- ratings outside the server's available snapshot), as an end marker.
        result.has_more = raw_count >= count and (not previous or new_records > 0)
    end
    return result
end

function BookReviews.format_date(value)
    if type(value) == "string" then
        value = trim(value)
        local year, month, day = value:match("(%d%d%d%d)[-/%.](%d%d?)[-/%.](%d%d?)")
        if year then
            return string.format("%s-%02d-%02d", year, tonumber(month), tonumber(day))
        end
        if not tonumber(value) then
            return value
        end
    end
    local timestamp = tonumber(value)
    if not timestamp or timestamp <= 0 then
        return ""
    end
    if timestamp > 100000000000 then
        timestamp = math.floor(timestamp / 1000)
    end
    return os.date("%Y-%m-%d", timestamp)
end

function BookReviews.format_rating(value)
    local rating = tonumber(value) or 0
    if rating <= 0 then
        return ""
    end
    return string.format("%.1f", rating)
end

function BookReviews.preview(text, max_chars)
    text = BookReviews.plain_text(text):gsub("\n+", " ")
    max_chars = tonumber(max_chars) or 60
    local bytes, chars = 0, 0
    while bytes < #text and chars < max_chars do
        local byte = text:byte(bytes + 1)
        local width = byte < 0x80 and 1
            or byte < 0xE0 and 2
            or byte < 0xF0 and 3
            or 4
        bytes = bytes + width
        chars = chars + 1
    end
    if bytes < #text then
        return text:sub(1, bytes) .. "…"
    end
    return text
end

return BookReviews

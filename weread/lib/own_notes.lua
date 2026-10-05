-- Own cloud notes only. Never feed public heat-map rows into this module.
local Notes = {}

local function id(value)
    if type(value) == "string" or type(value) == "number" then return tostring(value) end
    return ""
end

local function unwrap(row)
    for _i = 1, 5 do
        if type(row) ~= "table" then return {} end
        if type(row.review) ~= "table" then return row end
        row = row.review
    end
    return {}
end

local function belongs(row, book_id, vid, require_author)
    if row.bookId ~= nil and id(row.bookId) ~= book_id then return false end
    local author = type(row.author) == "table" and row.author.userVid or row.userVid
    if author ~= nil then return id(author) == vid end
    return not require_author -- bookmarklist is authenticated and book-scoped
end

local function item(row, kind, book_id, vid)
    local note_id
    if kind == "bookmark" then note_id = row.bookmarkId else note_id = row.reviewId end
    return {
        kind = kind, id = id(note_id),
        book_id = book_id, owner_vid = vid, chapter_uid = id(row.chapterUid),
        chapter_title = type(row.chapterTitle) == "string" and row.chapterTitle or "",
        quote = type(row.markText) == "string" and row.markText
            or type(row.abstract) == "string" and row.abstract or "",
        content = kind == "review" and type(row.content) == "string" and row.content or "",
        create_time = tonumber(row.createTime) or 0,
    }
end

function Notes.bookmarks(data, book_id, vid)
    assert(type(data) == "table" and type(data.updated) == "table", "Invalid own bookmark list")
    local rows, seen = {}, {}
    for _, row in ipairs(data.updated) do
        -- APK bookmark.type=1 means underline, NOT thought; type=0 is a page bookmark.
        if type(row) == "table" and tonumber(row.type) == 1 and belongs(row, book_id, vid, false) then
            local note = item(row, "bookmark", book_id, vid)
            if note.id ~= "" and not seen[note.id] then
                rows[#rows + 1], seen[note.id] = note, true
            end
        end
    end
    return rows
end

function Notes.review_page(data, book_id, vid, previous_cursor)
    assert(type(data) == "table" and type(data.reviews) == "table", "Invalid own thought list")
    local rows, seen = {}, {}
    for _, wrapper in ipairs(data.reviews) do
        local row = unwrap(wrapper)
        -- Book ratings (type=4) and other people's reviews are not personal chapter thoughts.
        if tonumber(row.type) == 1 and belongs(row, book_id, vid, true) then
            local note = item(row, "review", book_id, vid)
            if note.id ~= "" and not seen[note.id] then
                rows[#rows + 1], seen[note.id] = note, true
            end
        end
    end
    assert(data.hasMore == true or data.hasMore == false
        or tonumber(data.hasMore) == 0 or tonumber(data.hasMore) == 1, "Invalid own thought pagination")
    local more = data.hasMore == true or tonumber(data.hasMore) == 1
    local cursor = tonumber(data.synckey)
    if more then
        assert(cursor and cursor > 0 and cursor ~= tonumber(previous_cursor), "Own thought cursor did not advance")
    end
    return rows, more, cursor, data.removed or {}
end

function Notes.merge(existing, incoming, removed)
    local rows, positions, deleted = {}, {}, {}
    for _, value in ipairs(removed or {}) do
        deleted[id(type(value) == "table" and value.reviewId or value)] = true
    end
    for _, list in ipairs({ existing, incoming }) do
        for _, note in ipairs(list) do
            local key = note.kind .. ":" .. note.id
            if note.kind ~= "review" or not deleted[note.id] then
                local pos = positions[key]
                if pos then rows[pos] = note else
                    rows[#rows + 1], positions[key] = note, #rows + 1
                end
            end
        end
    end
    return rows
end

function Notes.delete(client, note, book_id, vid)
    assert(type(note) == "table" and type(note.id) == "string" and note.id ~= "" and vid ~= "" and note.book_id == book_id
        and note.owner_vid == vid and id(client:eink_credentials()) == vid, "Own note identity changed")
    local result
    if note.kind == "bookmark" then
        result = client:eink_remove_bookmark(note.id)
    elseif note.kind == "review" then
        result = client:eink_delete_review(note.id)
    else
        error("Invalid own note kind")
    end
    -- Transport 200 / an empty JSON object is not proof of a completed deletion.
    assert(type(result) == "table" and (result.succ == true or tonumber(result.succ) == 1)
        and (result.errcode == nil or tonumber(result.errcode) == 0)
        and (result.errCode == nil or tonumber(result.errCode) == 0), "Cloud deletion was not confirmed")
    return true
end

return Notes

local bit = require("bit")
local Crypto = require("weread.lib.crypto")

local WeRead = {}

WeRead.USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0"

function WeRead.is_success_response(result, field)
    if type(result) ~= "table" then
        return false
    end
    local value = result[field or "succ"]
    return value == true or tonumber(value) == 1
end

local function is_digit_string(value)
    return tostring(value):match("^%d+$") ~= nil
end

local function js_string(value)
    if value == true then
        return "true"
    elseif value == false then
        return "false"
    elseif value == nil then
        return "null"
    end
    return tostring(value)
end

function WeRead.urlencode(value)
    value = js_string(value)
    return (value:gsub("([^%w%-_%.~])", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
end

function WeRead.sorted_query(params)
    local keys = {}
    for key in pairs(params) do
        if key ~= "s" then
            table.insert(keys, key)
        end
    end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        table.insert(parts, key .. "=" .. WeRead.urlencode(params[key]))
    end
    return table.concat(parts, "&")
end

function WeRead.sign(query)
    local a = 0x15051505
    local b = a
    local length = #query
    local i = length

    while i > 1 do
        a = bit.band(bit.bxor(a, bit.lshift(query:byte(i), ((length - i + 1) % 30))), 0x7fffffff)
        b = bit.band(bit.bxor(b, bit.lshift(query:byte(i - 1), ((i - 1) % 30))), 0x7fffffff)
        i = i - 2
    end

    return string.format("%x", a + b):lower()
end

local function byte_hex(value)
    local out = {}
    for i = 1, #value do
        out[i] = string.format("%x", value:byte(i))
    end
    return table.concat(out)
end

function WeRead.e(value)
    local s = tostring(value)
    local h = Crypto.md5_hex(s)
    local result = h:sub(1, 3)
    local chunks = {}
    local type_flag

    if is_digit_string(s) then
        type_flag = "3"
        local i = 1
        while i <= #s do
            local part = s:sub(i, i + 8)
            table.insert(chunks, string.format("%x", tonumber(part)))
            i = i + 9
        end
    else
        type_flag = "4"
        table.insert(chunks, byte_hex(s))
    end

    result = result .. type_flag .. "2" .. h:sub(-2)
    for i, chunk in ipairs(chunks) do
        result = result .. string.format("%02x", #chunk) .. chunk
        if i < #chunks then
            result = result .. "g"
        end
    end

    if #result < 20 then
        result = result .. h:sub(1, 20 - #result)
    end

    result = result .. Crypto.md5_hex(result):sub(1, 3)
    return result
end

-- Lua string indexes are byte offsets. Return a valid UTF-8 prefix containing
-- at most max_chars code points so payload fields are never cut mid-character.
function WeRead.utf8_substr(value, max_chars)
    local text = tostring(value or "")
    local limit = math.max(0, math.floor(tonumber(max_chars) or 0))
    local index = 1
    local count = 0

    while index <= #text and count < limit do
        local first = text:byte(index)
        local width = 0
        local second = text:byte(index + 1)

        if first <= 0x7f then
            width = 1
        elseif first >= 0xc2 and first <= 0xdf
            and second and second >= 0x80 and second <= 0xbf then
            width = 2
        elseif first == 0xe0
            and second and second >= 0xa0 and second <= 0xbf then
            width = 3
        elseif first >= 0xe1 and first <= 0xec
            and second and second >= 0x80 and second <= 0xbf then
            width = 3
        elseif first == 0xed
            and second and second >= 0x80 and second <= 0x9f then
            width = 3
        elseif first >= 0xee and first <= 0xef
            and second and second >= 0x80 and second <= 0xbf then
            width = 3
        elseif first == 0xf0
            and second and second >= 0x90 and second <= 0xbf then
            width = 4
        elseif first >= 0xf1 and first <= 0xf3
            and second and second >= 0x80 and second <= 0xbf then
            width = 4
        elseif first == 0xf4
            and second and second >= 0x80 and second <= 0x8f then
            width = 4
        else
            break
        end

        for offset = 2, width - 1 do
            local continuation = text:byte(index + offset)
            if not continuation or continuation < 0x80 or continuation > 0xbf then
                width = 0
                break
            end
        end
        if width == 0 then
            break
        end

        index = index + width
        count = count + 1
    end

    return text:sub(1, index - 1)
end

function WeRead.is_mp_book(book_id)
    return tostring(book_id or ""):sub(1, 7) == "MP_WXS_"
end

function WeRead.reader_url(book_id, chapter_uid)
    local url = "https://weread.qq.com/web/reader/" .. WeRead.e(book_id)
    if chapter_uid then
        url = url .. "k" .. WeRead.e(chapter_uid)
    end
    return url
end

--- Upgrade WeRead CDN cover URLs to the higher-resolution t9 token.
function WeRead.normalize_cover_url(url)
    if type(url) ~= "string" or url == "" then
        return url
    end
    return (url:gsub("/t%d+_", "/t9_"):gsub("/s_", "/t9_"))
end

return WeRead

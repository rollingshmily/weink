local bit = require("bit")
local Crypto = require("weink.lib.crypto")

local Protocol = {}

Protocol.USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0"

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

function Protocol.urlencode(value)
    value = js_string(value)
    return (value:gsub("([^%w%-_%.~])", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
end

function Protocol.sign(query)
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

function Protocol.e(value)
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

function Protocol.is_mp_book(book_id)
    return tostring(book_id or ""):sub(1, 7) == "MP_WXS_"
end

function Protocol.reader_url(book_id, chapter_uid)
    local url = "https://weread.qq.com/web/reader/" .. Protocol.e(book_id)
    if chapter_uid then
        url = url .. "k" .. Protocol.e(chapter_uid)
    end
    return url
end

--- Upgrade WeRead CDN cover URLs to the higher-resolution t9 token.
function Protocol.normalize_cover_url(url)
    if type(url) ~= "string" or url == "" then
        return url
    end
    return (url:gsub("/t%d+_", "/t9_"):gsub("/s_", "/t9_"))
end

return Protocol

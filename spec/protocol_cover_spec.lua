package.path = "./?.lua;" .. package.path

local has_bit = pcall(require, "bit")
if not has_bit then
    package.preload["bit"] = function()
        return {
            band = function(a, b)
                local result, place = 0, 1
                while a > 0 or b > 0 do
                    if a % 2 == 1 and b % 2 == 1 then result = result + place end
                    a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
                end
                return result
            end,
            bxor = function() return 0 end,
            lshift = function(a, b) return (a * 2 ^ b) % 2 ^ 32 end,
        }
    end
end
package.preload["weread.lib.crypto"] = function()
    return {
        md5_hex = function() return "0123456789abcdef0123456789abcdef" end,
        sha256_hex = function(value) return "sha256:" .. tostring(value) end,
    }
end

local WeRead = require("weread.lib.protocol")
local checks = 0
local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        error(label .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

local cover_base = "https://cdn.weread.qq.com/weread/cover/52/Example/"
for _, token in ipairs({ "s", "t6", "t12", "t9" }) do
    eq(WeRead.normalize_cover_url(cover_base .. token .. "_Example.jpg"),
        cover_base .. "t9_Example.jpg", token .. " cover normalization")
end
eq(WeRead.normalize_cover_url(nil), nil, "nil cover preserved")
eq(WeRead.normalize_cover_url(""), "", "empty cover preserved")
eq(WeRead.normalize_cover_url(false), false, "non-string cover preserved")
for _, url in ipairs({
    "https://example.com/cover.jpg",
    "https://example.com/books_Example.jpg",
    "https://example.com/small_Example.jpg",
    "https://example.com/t_Example.jpg",
    "https://example.com/twelve_Example.jpg",
}) do
    eq(WeRead.normalize_cover_url(url), url, "unrelated URL preserved: " .. url)
end

print(("protocol_cover_spec: %d checks"):format(checks))

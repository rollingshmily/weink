-- Anti-replay signature for WeRead e-ink report requests.
--
-- Recovered by static analysis of lib/armeabi-v7a/libencrypt.so shipped in the
-- WeRead e-ink APK 2.1.2.10245900, from the exported symbol
--   _ZN6weread12GenSignatureESt6vectorINSt6__ndk112basic_string...EE
-- (.text:0x30bd) plus its callers in classes4.dex:
--   Encrypt.encryptAntiReplaySignature(keys) -> EncryptUtils.getSignatures([guest_token] + keys)
-- where keys = { random, timestamp, payload }.
--
-- Reconstructed algorithm, traced instruction by instruction:
--   1. keys.insert("5a6f1")                       -- salt at .rodata 0xB274
--   2. sort(keys)                                 -- std::string byte order
--   3. C  = concat(keys)
--   4. D1 = rotate(C,  xor_all(C)  % 11)
--   5. H1 = hex(sha256(D1))
--   6. D2 = rotate(H1, xor_all(H1) % 11)
--   7. return hex(sha256(D2))
-- The rotate helper's index comes from the internal divmod at .text:0xa65c
-- (quotient in r0, remainder in r1) called as (key + i, len); the byte loop is
-- at .text:0x321a.
--
-- Caveat: this port is pure Lua and the native library is ARM-only, so the
-- output has NOT been compared against a runtime oracle yet. It is derived from
-- the shipped binary, not reverse-engineered from observed traffic.

local bit = require("bit")
local Crypto = require("weink.lib.crypto")

local M = {}

M.SALT = "5a6f1"

-- RemapString: the library substitutes every signature-input byte through this
-- 256-byte table *before* GenSignature sees it. Verified against three
-- device-captured signatures (see spec/anti_replay_spec.lua). The table lives in
-- .rodata of libencrypt.so (arm64 0xD9FC, armeabi-v7a 0xB174).
local REMAP_HEX = "34ca55401db693c63130293532a7b811c2b516fa8bb124a4109004e908f83b8a9c8c44f9bc5c69e2a1dad2d37589f71e2d5056d77253bf22fb200f012e45876e6648f2e0cdfe67a943f49451cea54aee13268eccaa33145d0e39bbcf912b814dea99ec1a2c85c5d936744b18e1f13d9d419fb4170dd64cbedcaf972877f062ff71c1c8278f6c68a89be6591c1b1209984e3f063700ba1f0a192fc9d5d057496ffd25e4610c42cb96645fdbad60238d9a6dc3c45e3eb9926abd5b077f7695ed4fab847a80e778c7e5eb73836bfc38467d4765b352633a05d1efa3a6de9e3c02aeb27ba0f6f32ac0ac86035a540bf582d47ee3dfb0d8dd21e87c88a2795870b715"
local REMAP = {}
for i = 1, 256 do
    REMAP[i] = tonumber(REMAP_HEX:sub(i * 2 - 1, i * 2), 16)
end

local function remap(text)
    local out = {}
    for i = 1, #text do
        out[i] = string.char(REMAP[text:byte(i) + 1])
    end
    return table.concat(out)
end

local function xor_mod11(text)
    local accumulator = 0
    for i = 1, #text do
        accumulator = bit.bxor(accumulator, text:byte(i))
    end
    return accumulator % 11
end

-- out[(key + i) mod n] = text[i]
local function rotate(text, key)
    local length = #text
    if length == 0 then
        return text
    end
    local out = {}
    for i = 1, length do
        out[((key + i - 1) % length) + 1] = text:sub(i, i)
    end
    return table.concat(out)
end

local function stage(text)
    local rotated = rotate(text, xor_mod11(text))
    return Crypto.sha256_hex(rotated)
end

-- FeatureGuestToken default (moai.feature.FeatureGuestTokenWrapper). GET
-- /feature ships no guest_token entry, so the client always falls back to this
-- value; it is an app-level constant, not account data.
M.GUEST_TOKEN = "5ecdcfd7f"

-- AntiReplayAction.getAntiReplaySignature (classes9.dex): plain SHA-256 over
-- "<timestamp><token><random>". This is the batchUploadProgress /
-- ReadBookMarkFinishReading signature, NOT the single /book/read one.
function M.anti_replay_signature(token, timestamp, random)
    return Crypto.sha256_hex(tostring(timestamp) .. tostring(token)
        .. tostring(random))
end

-- generatePayLoad() from ReportService (classes3.dex): the exact string the
-- native signature covers. Field order, separators and the absence of a
-- trailing underscore after the last hour bucket are load-bearing.
function M.payload_string(fields)
    fields = fields or {}
    local parts = {
        tostring(fields.vid or ""),
        tostring(fields.deviceId or ""),
        tostring(fields.appId or ""),
        tostring(fields.bookId or ""),
        tostring(fields.risk or 0),
        tostring(fields.recordCreateTimeZone or ""),
        tostring(fields.readingTime or 0),
        tostring(fields.ttsTime or 0),
    }
    for _i, hour in ipairs(fields.hours or {}) do
        parts[#parts + 1] = tostring(hour.startOfHour or 0)
        parts[#parts + 1] = tostring(hour.timeZone or "")
        parts[#parts + 1] = tostring(hour.readingTime or 0)
        parts[#parts + 1] = tostring(hour.ttsTime or 0)
    end
    return table.concat(parts, "_")
end

-- Encrypt.encryptAntiReplaySignature([guest_token] + [random, timestamp, payload]).
function M.report_signature(guest_token, random, timestamp, payload_string)
    return M.sign({
        tostring(guest_token or ""),
        tostring(random or 0),
        tostring(timestamp or 0),
        tostring(payload_string or ""),
    })
end

-- keys: ordered list of strings (order is irrelevant because sign() sorts).
function M.sign(keys)
    local parts = {}
    for _i, part in ipairs(keys or {}) do
        parts[#parts + 1] = remap(tostring(part == nil and "" or part))
    end
    -- The salt is pushed by the library itself, so it is NOT remapped.
    parts[#parts + 1] = M.SALT
    table.sort(parts)
    return stage(stage(table.concat(parts)))
end

return M

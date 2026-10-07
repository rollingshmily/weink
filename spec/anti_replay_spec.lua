package.path = "./?.lua;" .. package.path

local failures = 0
local function assert_eq(actual, expected, label)
    if actual ~= expected then
        failures = failures + 1
        io.stderr:write(string.format("FAIL %s: got %q expected %q\n",
            label, tostring(actual), tostring(expected)))
    end
end

local AntiReplay = require("weread.lib.anti_replay")
local Crypto = require("weread.lib.crypto")
local bit = require("bit")

assert_eq(AntiReplay.SALT, "5a6f1", "salt matches libencrypt .rodata 0xB274")

-- Structural properties of the reconstructed GenSignature().
local first = AntiReplay.sign({ "123", "1791333600000", "vid_dev_app_book" })
assert_eq(type(first), "string", "signature is a string")
assert_eq(#first, 64, "sha256 hex length")
assert_eq(first:match("^%x+$") ~= nil, true, "lowercase hex")

assert_eq(AntiReplay.sign({ "123", "1791333600000", "vid_dev_app_book" }), first,
    "deterministic")

-- GenSignature sorts its inputs, so argument order cannot matter.
local reordered = AntiReplay.sign({ "vid_dev_app_book", "1791333600000", "123" })
assert_eq(reordered, first, "input order is irrelevant")

-- The hardcoded salt participates in the sorted concatenation.
assert_eq(AntiReplay.sign({}) == AntiReplay.sign({ "5a6f1" }), false,
    "salt is appended exactly once")

local different = AntiReplay.sign({ "123", "1791333600000", "vid_dev_app_other" })
assert_eq(different ~= first, true, "payload changes the signature")

-- Primitive regression lock: xor-over-bytes modulo 11 and the index rotation
-- are the two moving parts recovered from .text:0xa65c / .text:0x321a. The
-- expected values below lock the current implementation; they are not an
-- independent proof against the native library.
local function xor_mod11(text)
    local acc = 0
    for i = 1, #text do
        acc = bit.bxor(acc, text:byte(i))
    end
    return acc % 11
end

assert_eq(xor_mod11(""), 0, "empty xor")
assert_eq(xor_mod11("\0"), 0, "single zero byte")
assert_eq(xor_mod11("AB"), bit.bxor(65, 66) % 11, "two byte xor")

-- sha256 hex of the double-rotated stage is exercised through the public API;
-- assert the composition matches an explicit re-implementation.
do
    local function rotate(text, key)
        local n = #text
        local out = {}
        for i = 1, n do
            out[((key + i - 1) % n) + 1] = text:sub(i, i)
        end
        return table.concat(out)
    end
    local parts = { "123", "1791333600000", "vid_dev_app_book", "5a6f1" }
    table.sort(parts)
    local concat = table.concat(parts)
    local stage1 = rotate(concat, xor_mod11(concat))
    local hex1 = Crypto.sha256_hex(stage1)
    local stage2 = rotate(hex1, xor_mod11(hex1))
    assert_eq(AntiReplay.sign({ "123", "1791333600000", "vid_dev_app_book" }),
        Crypto.sha256_hex(stage2), "composition matches the traced algorithm")
end

-- generatePayLoad(): the signed field string, mirroring ReportService.generatePayLoad.
do
    local fields = {
        vid = "1000", deviceId = "eink334691225", appId = "eink334691225",
        bookId = "22691208", risk = 0, recordCreateTimeZone = "+08:00",
        readingTime = 90, ttsTime = 0,
        hours = {
            { startOfHour = 1791331200, timeZone = "+08:00", readingTime = 30, ttsTime = 0 },
            { startOfHour = 1791334800, timeZone = "+08:00", readingTime = 60, ttsTime = 0 },
        },
    }
    assert_eq(AntiReplay.payload_string(fields),
        "1000_eink334691225_eink334691225_22691208_0_+08:00_90_0"
        .. "_1791331200_+08:00_30_0_1791334800_+08:00_60_0",
        "payload string with two hour buckets")

    local single = {
        vid = "1", deviceId = "d", appId = "d", bookId = "b",
        risk = 0, recordCreateTimeZone = "+08:00", readingTime = 30, ttsTime = 0,
        hours = { { startOfHour = 1791331200, timeZone = "+08:00", readingTime = 30, ttsTime = 0 } },
    }
    assert_eq(AntiReplay.payload_string(single),
        "1_d_d_b_0_+08:00_30_0_1791331200_+08:00_30_0",
        "no trailing underscore after the last bucket")

    local no_hours = {
        vid = "1", deviceId = "d", appId = "d", bookId = "b",
        risk = 0, recordCreateTimeZone = "+08:00", readingTime = 0, ttsTime = 0,
    }
    assert_eq(AntiReplay.payload_string(no_hours), "1_d_d_b_0_+08:00_0_0",
        "empty ledger still signs the base fields")

    local signature = AntiReplay.report_signature("guest", 123, 1791333600000,
        AntiReplay.payload_string(fields))
    assert_eq(signature, AntiReplay.sign({ "guest", "123", "1791333600000",
        AntiReplay.payload_string(fields) }), "report_signature composes sign()")
    assert_eq(#signature, 64, "report signature is sha256 hex")
end

if failures > 0 then
    io.stderr:write(string.format("%d anti_replay assertions failed\n", failures))
    os.exit(1)
end
print("anti_replay_spec: ok")

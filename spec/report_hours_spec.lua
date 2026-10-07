package.path = "./?.lua;" .. package.path

local failures = 0
local function assert_eq(actual, expected, label)
    if actual ~= expected then
        failures = failures + 1
        io.stderr:write(string.format("FAIL %s: got %s expected %s\n",
            label, tostring(actual), tostring(expected)))
    end
end

local Hours = require("weread.lib.report_hours")

-- hourBeginTime() floors on the GMT+8 wall clock.
-- 2026-10-07 08:40:00 +08:00 == 2026-10-07 00:40:00 UTC == 1791333600.
do
    local ts = 1791333600
    local start = Hours.hour_begin(ts)
    assert_eq(start, 1791331200, "hour begin floors to the GMT+8 hour")
    assert_eq(start % 3600, 0, "hour begin is hour-aligned")
    assert_eq((ts - start) / 60, 40, "minutes into the hour")
end

assert_eq(Hours.hour_begin(1791331200), 1791331200, "already aligned")
assert_eq(Hours.hour_begin(1791331201), 1791331200, "one second in")

assert_eq(Hours.timezone_string(8 * 3600), "+08:00", "east offset")
assert_eq(Hours.timezone_string(-(5 * 3600 + 30 * 60)), "-05:30", "west half-hour offset")
assert_eq(Hours.timezone_string(0), "+00:00", "utc")

-- Accumulation appends to the current hour bucket.
do
    local now = 1791333600
    local ledger = Hours.accumulate({}, 30, { now = now })
    assert_eq(#ledger, 1, "one bucket")
    assert_eq(ledger[1].startOfHour, 1791331200, "bucket key")
    assert_eq(ledger[1].readingTime, 30, "bucket seconds")
    assert_eq(ledger[1].ttsTime, 0, "bucket tts untouched")
    assert_eq(ledger[1].timeZone, "+08:00", "bucket timezone")

    ledger = Hours.accumulate(ledger, 30, { now = now + 5 })
    assert_eq(#ledger, 1, "same hour stays one bucket")
    assert_eq(ledger[1].readingTime, 60, "same hour accumulates")

    local reading, tts = Hours.totals(ledger)
    assert_eq(reading, 60, "total reading")
    assert_eq(tts, 0, "total tts")
end

-- Crossing an hour boundary opens a second bucket; the APK then batches.
do
    local now = 1791333600 -- 08:40 +08:00
    local ledger = Hours.accumulate({}, 60, { now = now })
    ledger = Hours.accumulate(ledger, 60, { now = now + 3600 })
    assert_eq(#ledger, 2, "two hour buckets")
    assert_eq(ledger[2].startOfHour, ledger[1].startOfHour + 3600, "next hour key")
    assert_eq(Hours.needs_batch(ledger), true, "needs batch")

    local reading = Hours.totals(ledger)
    assert_eq(reading, 120, "cumulative across buckets")
end

assert_eq(Hours.needs_batch(Hours.accumulate({}, 30, { now = 0 })), false, "single bucket no batch")

-- TTS is tracked separately, mirroring saveHoursTime(x, tts = true).
do
    local ledger = Hours.accumulate({}, 30, { now = 0, tts = true })
    assert_eq(ledger[1].ttsTime, 30, "tts bucket")
    assert_eq(ledger[1].readingTime, 0, "reading untouched by tts")
end

-- Non-positive deltas must not create buckets.
do
    local ledger = Hours.accumulate({}, 0, { now = 0 })
    assert_eq(#ledger, 0, "zero delta creates nothing")
    assert_eq(#ledger, 0, "empty ledger")
    ledger = Hours.accumulate(ledger, -5, { now = 0 })
    assert_eq(#ledger, 0, "negative delta creates nothing")
end

-- normalize() is tolerant of JSON round-trips and junk.
do
    local ledger = Hours.normalize({
        { startOfHour = "1791331200", readingTime = "45.9", ttsTime = nil, timeZone = "+08:00" },
        "junk",
        { startOfHour = 1, readingTime = 2, ttsTime = 3, timeZone = "+08:00" },
    })
    assert_eq(#ledger, 2, "junk entries dropped")
    assert_eq(ledger[1].startOfHour, 1791331200, "numeric strings coerced")
    assert_eq(ledger[1].readingTime, 45, "floats floored")
    assert_eq(ledger[1].ttsTime, 0, "missing tts defaults to zero")
    assert_eq(Hours.normalize("junk") and #Hours.normalize("junk"), 0, "non-table is empty")
end

-- serialize/parse round-trip must be byte-identical so the ledger can be
-- persisted in settings and used as a fingerprint component.
do
    local ledger = Hours.accumulate({}, 60, { now = 1791333600 })
    ledger = Hours.accumulate(ledger, 90, { now = 1791337200 })
    local text = Hours.serialize(ledger)
    assert_eq(text, "1791331200:60:0:+08:00|1791334800:90:0:+08:00", "serialized ledger")
    local restored = Hours.parse(text)
    assert_eq(#restored, #ledger, "round-trip bucket count")
    assert_eq(Hours.serialize(restored), text, "round-trip is byte-identical")
    assert_eq(Hours.totals(restored), 150, "round-trip preserves totals")
end

assert_eq(#Hours.parse(""), 0, "empty parse")
assert_eq(Hours.serialize({}), "", "empty serialize")

if failures > 0 then
    io.stderr:write(string.format("%d report_hours assertions failed\n", failures))
    os.exit(1)
end
print("report_hours_spec: ok")

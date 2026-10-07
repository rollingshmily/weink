-- Hour-bucketed reading-time ledger for the e-ink read report.
--
-- Contract recovered from the WeRead e-ink APK 2.1.2.10245900 (classes3.dex):
--   ReportServiceKt.hourBeginTime                        -> local hour start (GMT+8), epoch seconds
--   ReportServiceKt.saveHoursTime                        -> append/increment {startOfHour,readingTime,ttsTime,timeZone}
--   ReportService.m45updateReadProgress$lambda6$lambda3  -> readingTime accumulates per book
--   ReportService.generateBookReadPostBody               -> posts cumulative readingTime + hours[]
--   ReportService.m42updateProgress$lambda47             -> clears the ledger on BooleanResult.isSuccess()
--   ReportService.m39updateProgress$lambda45             -> hours.size() > 1 uses /book/batchUploadProgress
--
-- The server's daily reading bucket (/readdata/detail, readTimes) is keyed by the
-- same local hour start, so a report that omits "hours" has no time ledger to credit.

local M = {}

-- hourBeginTime() hardcodes GMT+8, independently of the device time zone.
M.DEFAULT_OFFSET_SECONDS = 8 * 3600

local function finite(value, fallback)
    local number = tonumber(value)
    if number and number == number and math.abs(number) ~= math.huge then
        return math.floor(number)
    end
    return fallback
end

-- Matches Hour.Companion.generateCurrentTimeZone(): "%s%02d:%02d".
function M.timezone_string(offset_seconds)
    local offset = finite(offset_seconds, M.DEFAULT_OFFSET_SECONDS)
    local sign = offset < 0 and "-" or "+"
    local absolute = math.abs(offset)
    return string.format("%s%02d:%02d", sign,
        math.floor(absolute / 3600), math.floor((absolute % 3600) / 60))
end

-- Matches ReportServiceKt.hourBeginTime(): floor to the hour on the GMT+8 wall
-- clock, then back to epoch seconds.
function M.hour_begin(timestamp_seconds, offset_seconds)
    local timestamp = finite(timestamp_seconds, 0)
    local offset = finite(offset_seconds, M.DEFAULT_OFFSET_SECONDS)
    return (math.floor((timestamp + offset) / 3600) * 3600) - offset
end

-- Accept a persisted (JSON round-tripped) ledger and return a clean array.
function M.normalize(hours)
    local ledger = {}
    if type(hours) ~= "table" then
        return ledger
    end
    for _i, bucket in ipairs(hours) do
        if type(bucket) == "table" then
            ledger[#ledger + 1] = {
                startOfHour = finite(bucket.startOfHour, 0),
                readingTime = finite(bucket.readingTime, 0),
                ttsTime = finite(bucket.ttsTime, 0),
                timeZone = tostring(bucket.timeZone or ""),
            }
        end
    end
    return ledger
end

local function find_bucket(ledger, start_of_hour, timezone)
    for _i, bucket in ipairs(ledger) do
        if bucket.startOfHour == start_of_hour and bucket.timeZone == timezone then
            return bucket
        end
    end
    return nil
end

-- Append seconds to the bucket for the hour containing "now". Returns the new
-- ledger; the input is never mutated.
function M.accumulate(hours, seconds, options)
    options = options or {}
    local ledger = M.normalize(hours)
    local delta = finite(seconds, 0)
    if delta <= 0 then
        return ledger
    end
    local offset = finite(options.offset_seconds, M.DEFAULT_OFFSET_SECONDS)
    local timezone = M.timezone_string(offset)
    local start_of_hour = M.hour_begin(options.now, offset)
    local bucket = find_bucket(ledger, start_of_hour, timezone)
    if not bucket then
        bucket = {
            startOfHour = start_of_hour,
            readingTime = 0,
            ttsTime = 0,
            timeZone = timezone,
        }
        ledger[#ledger + 1] = bucket
    end
    if options.tts then
        bucket.ttsTime = bucket.ttsTime + delta
    else
        bucket.readingTime = bucket.readingTime + delta
    end
    return ledger
end

function M.totals(hours)
    local reading, tts = 0, 0
    for _i, bucket in ipairs(M.normalize(hours)) do
        reading = reading + bucket.readingTime
        tts = tts + bucket.ttsTime
    end
    return reading, tts
end

function M.is_empty(hours)
    return #M.normalize(hours) == 0
end

-- The APK switches to /book/batchUploadProgress once a report spans more than
-- one hour bucket.
function M.needs_batch(hours)
    return #M.normalize(hours) > 1
end

-- Deterministic text form. The ledger is persisted in the per-book settings
-- record and also used as a context-fingerprint component, so it must survive a
-- settings round-trip byte-identically; KOReader's json encoder does not
-- guarantee key order and tostring(table) is not stable across reads.
function M.serialize(hours)
    local parts = {}
    for _i, bucket in ipairs(M.normalize(hours)) do
        parts[#parts + 1] = table.concat({
            tostring(bucket.startOfHour),
            tostring(bucket.readingTime),
            tostring(bucket.ttsTime),
            bucket.timeZone,
        }, ":")
    end
    return table.concat(parts, "|")
end

function M.parse(text)
    local ledger = {}
    if type(text) ~= "string" or text == "" then
        return ledger
    end
    for record in text:gmatch("[^|]+") do
        local start_of_hour, reading, tts, timezone =
            record:match("^(%-?%d+):(%-?%d+):(%-?%d+):(.*)$")
        if start_of_hour then
            ledger[#ledger + 1] = {
                startOfHour = tonumber(start_of_hour),
                readingTime = tonumber(reading),
                ttsTime = tonumber(tts),
                timeZone = timezone,
            }
        end
    end
    return ledger
end

return M

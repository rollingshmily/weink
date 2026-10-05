-- Native POST /book/read payload shape.
-- Run from the repo root with:
--   lua spec/weread_read_payload_spec.lua

package.path = "./?.lua;" .. package.path

package.preload["weread.lib.content"] = function()
    return {}
end
package.preload["weread.lib.protocol"] = function()
    return {
        reader_url = function(book_id)
            return "https://weread.qq.com/web/reader/" .. tostring(book_id)
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            return { info = function() end, warn = function() end, err = function() end }
        end,
    }
end
package.preload["weread.lib.plugin_util"] = function()
    return { perf = function() end }
end
package.preload["ui/time"] = function()
    return { now = function() return 0 end }
end
package.preload["ffi/util"] = function()
    return {}
end

local ReadReport = require("weread.lib.read_report")
local failures, checks = 0, 0

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL %s: got %s, want %s",
            label, tostring(got), tostring(want)))
    end
end

local report = ReadReport:new{
    settings = {
        get = function() return {} end,
        is_eink_configured = function() return true end,
    },
    client = {},
    scheduler = { scheduleIn = function() end, unschedule = function() end },
    get_document = function() return { file = "/book.epub" } end,
    detect_book = function() return "22691208" end,
    subprocess = false,
    now = function() return 100 end,
}

local book = {
    book_id = "22691208",
    chapter_uid = 57,
    chapter_idx = 2,
    chapter_offset = 389.7,
    progress = 74.9,
    summary = "摄影笔记",
}
local payload = report:build_payload("22691208", 12, book)

eq(payload.bookId, "22691208", "native bookId")
eq(payload.chapterUid, 57, "native chapterUid")
eq(payload.chapterOffset, 389, "native chapterOffset is integer")
eq(payload.progress, 74.9, "native progress")
eq(payload.readingTime, 12, "native readingTime")
eq(payload.psvts, nil, "web psvts is omitted")
eq(payload.sg, nil, "web sg is omitted")
eq(payload.appId, nil, "web appId is omitted")
eq(payload.s, nil, "web signature is omitted")

print(string.format(
    "weread_read_payload_spec: %d checks, %d failure(s)",
    checks,
    failures
))
os.exit(failures == 0 and 0 or 1)

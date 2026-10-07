-- Response classification/replay boundaries through the real report payload and
-- Client:report_read -> eink_post_json -> request path. Only transport, JSON,
-- context fetching and renewal are mocked; no server writes are performed.
-- Run: lua spec/read_report_response_spec.lua
package.path = "./?.lua;" .. package.path

local logs = {}
local function capture(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    logs[#logs + 1] = table.concat(parts, " ")
end
package.preload["weread.lib.logger"] = function()
    -- Capture this component only. Shared Client diagnostics are out of scope.
    return { info = function() end, warn = function() end, err = function() end,
        scoped = function() return { info = capture, warn = capture, err = capture } end }
end
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return { reader_url = function() return "https://reader/" end }
end
package.preload["weread.lib.plugin_util"] = function() return { perf = function() end } end
package.preload["weread.lib.eink"] = function() return { APPVER = "test", USER_AGENT = "test" } end
package.preload["ltn12"] = function() return {} end
package.preload["socketutil"] = function() return {} end
package.preload["socket.http"] = function() return {} end
package.preload["ffi/util"] = function() return {} end

local Client = require("weread.lib.client")
local ReadReport = require("weread.lib.read_report")
local checks = 0
local function eq(got, want, message)
    checks = checks + 1
    assert(got == want, message .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end
local function contains(text, part, message)
    eq(text:find(part, 1, true) ~= nil, true, message)
end
local function log_count(label)
    local count = 0
    for _, line in ipairs(logs) do
        if line:find(label, 1, true) then count = count + 1 end
    end
    return count
end
local function fixture(replies, options)
    options = options or {}
    logs = {}
    local stats = { posts = 0, gets = 0, contexts = 0, refreshes = 0, renewals = 0, packets = {} }
    local settings = {
        get = function(_self, key, default)
            if key == "read_report" then
                return { enabled = true, mode = "auto", interval_seconds = 30 }
            end
            if key == "eink" then
                return { vid = "SECRET_ACCOUNT", access_token = "SECRET_TOKEN", device_id = "SECRET_DEVICE" }
            end
            if key == "eink_install_id" then return "SECRET_INSTALL" end
            return default or {}
        end,
        is_eink_configured = function() return true end,
    }
    local client = Client:new(settings)
    -- JSON transport stand-in keeps request/response tables available for exact
    -- assertions without adding a JSON package dependency to this unit spec.
    client.json_encode = function(_self, value) return value end
    client.json_decode = function(_self, value) return value end
    client.eink_credentials = function() return "SECRET_ACCOUNT", "SECRET_TOKEN" end
    client.eink_refresh_session = function()
        stats.renewals = stats.renewals + 1
        if options.renew_raise then error("SECRET_RENEW_EXCEPTION") end
        return options.renew_ok ~= false
    end
    client.request = function(_self, request)
        if request.method == "GET" then stats.gets = stats.gets + 1 end
        eq(request.method, "POST", "only existing report POSTs are made")
        eq(request.url, "https://i.weread.qq.com/book/read", "actual HTTP report endpoint")
        stats.posts = stats.posts + 1
        stats.packets[#stats.packets + 1] = request.body
        local reply = replies[math.min(stats.posts, #replies)]
        assert(reply, "unexpected POST")
        if reply.raise then error(reply.raise) end
        return reply.body, reply.http or 200
    end
    local report = ReadReport:new{
        settings = settings, client = client,
        scheduler = { scheduleIn = function() end, unschedule = function() end },
        get_document = function() return {} end,
        detect_book = function() return "SECRET_BOOK_ID" end,
        subprocess = false, now = function() return 10000 end,
    }
    report.ensure_context = function(_self, _book_id, force)
        stats.contexts = stats.contexts + 1
        if force then stats.refreshes = stats.refreshes + 1 end
        if stats.contexts == options.context_fail_at then error("SECRET_CONTEXT_EXCEPTION") end
        return { book_id = "SECRET_BOOK_ID", title = "SECRET_TITLE", chapter_uid = 11,
            chapter_idx = 2, chapter_offset = 389.7, progress = 74.9, summary = "SECRET_SUMMARY",
            bookVersion = 23, deviceId = "SECRET_DEVICE", appId = "SECRET_APP", installId = "SECRET_INSTALL" }
    end
    return report, stats
end
local function run(replies, options, opts)
    local report, stats = fixture(replies, options)
    local outcome = report:_run_pipeline("SECRET_BOOK_ID", opts or { allow_renewal = true })
    eq(stats.gets, 0, "diagnostics add no GETs")
    return outcome, stats, report
end
local function reply(body) return { body = body } end

local accepted = {
    { succ = 1 }, { succ = true }, { succ = "1", errcode = "0" },
    { data = { succ = 1 } }, { result = { succ = true } },
    { synckey = 123, data = { result = { succ = "1" } } },
    { data = {}, result = { succ = 1, errorCode = 0 } },
}
for _, body in ipairs(accepted) do
    local outcome, stats = run({ reply(body) })
    eq(outcome.accepted, true, "explicit BooleanResult success accepted")
    eq(outcome.response_state, "accepted", "accepted classification")
    eq(stats.posts, 1, "accepted response needs one actual POST")
    eq(stats.refreshes, 0, "accepted response needs no context refresh")
    eq(stats.renewals, 0, "accepted response needs no renewal")
end

local rejected = {
    { succ = 1, data = { succ = 0, errcode = -1 } }, -- original regression
    { succ = true, result = { succ = false } },
    { synckey = 123, data = { succ = 1, result = { errorCode = "-1" } } },
    { data = { succ = 1 }, result = { errCode = -1 } },
    { data = { errcode = -1 }, result = { succ = 1 } },
    { errCode = -1, data = { succ = 1 } },
    { data = { succ = 1, data = { result = { succ = "0" } } } },
    { succ = 1, errcode = "SECRET_NONNUMERIC", result = { succ = 0 } },
}
for _, body in ipairs(rejected) do
    local outcome, stats = run({ reply(body) })
    eq(outcome.accepted, false, "failure takes precedence over success/watermark")
    eq(outcome.response_state, "rejected", "explicit rejection classification")
    eq(outcome.error_kind, "server", "generic rejection is not authentication failure")
    eq(stats.posts, 2, "explicit rejection gets one bounded context retry")
    eq(stats.refreshes, 1, "one context refresh")
    eq(stats.renewals, 0, "generic rejection never renews login")
end

local unknown = {
    reply(nil), reply(false), reply(1), reply("SECRET_RAW_BODY"), reply({}),
    reply({ synckey = 123 }), reply({ data = { synckey = 456 } }),
    reply({ result = { synckey = 456 } }), reply({ data = { result = {} } }),
    reply({ succ = "SECRET_UNKNOWN" }), reply({ errcode = "SECRET_UNKNOWN" }),
    reply({ succ = 2 }), reply({ succ = 1, data = { errorCode = "SECRET_UNKNOWN" } }),
    reply({ succ = 1, result = { succ = "unknown" } }), reply({ errCode = 0 }),
    reply({ succ = 0 / 0 }), reply({ errorCode = math.huge }),
    { raise = "SECRET_TRANSPORT_EXCEPTION" }, { body = { succ = 1 }, http = 503 },
}
for _, response in ipairs(unknown) do
    local outcome, stats = run({ response })
    eq(outcome.accepted, false, "unknown never accepted")
    eq(outcome.response_state, "unconfirmed", "unknown is not explicit rejection")
    eq(outcome.error_kind, "unconfirmed", "uncertain acknowledgement kind")
    eq(stats.posts, 1, "unknown initial result never replays POST")
    eq(stats.refreshes, 0, "unknown initial result never refreshes context")
    eq(stats.renewals, 0, "unknown initial result never renews")
    local refreshed, retried = run({ reply({ errcode = -2012 }), response })
    eq(refreshed.response_state, "unconfirmed", "unknown refreshed result remains uncertain")
    eq(retried.posts, 2, "unknown refreshed result stops before third POST")
    eq(retried.renewals, 0, "unknown refreshed result does not enter renewal")
    local final, renewed = run({ reply({ errcode = -2012 }), reply({ data = { errCode = -2012 } }), response })
    eq(final.response_state, "unconfirmed", "unknown post-renewal result remains uncertain")
    eq(final.error_kind, "unconfirmed", "final unknown not mislabelled as server rejection")
    eq(renewed.posts, 3, "unknown final result stops at three POSTs")
    eq(renewed.renewals, 1, "renewal is bounded")
end

for _, final_body in ipairs({ { data = { succ = 1 } }, { result = { errcode = -2012 } } }) do
    local outcome, stats = run({ reply({ errcode = -2012 }), reply({ errcode = -2012 }), reply(final_body) })
    eq(outcome.response_state, final_body.data and "accepted" or "rejected", "final attempt classification")
    eq(stats.posts, 3, "known expiry has at most three report POSTs")
    eq(stats.renewals, 1, "known expiry renews once")
end
local no_renew, limited = run({ reply({ errcode = -2012 }) }, nil, { allow_renewal = false })
eq(no_renew.response_state, "rejected", "renewal cooldown preserves rejected classification")
eq(limited.posts, 2, "cooldown limits pipeline to two POSTs")
eq(limited.renewals, 0, "renewal cooldown respected")
local changed, changed_stats = run({ reply({ errcode = -2012 }), reply({ errcode = -1 }) })
eq(changed.response_state, "rejected", "refreshed rejection replaces initial expiry")
eq(changed_stats.renewals, 0, "stale auth rejection does not renew after a different failure")

for _, options in ipairs({ { renew_ok = false }, { renew_raise = true }, { context_fail_at = 3 } }) do
    local outcome, stats = run({ reply({ errcode = -2012 }) }, options)
    eq(outcome.accepted, false, "recovery failure not accepted")
    eq(stats.posts, 2, "recovery failure cannot issue final POST")
    eq(stats.renewals, 1, "failed renewal/final context is bounded")
    eq((outcome.error or ""):find("SECRET", 1, true), nil, "recovery exceptions not leaked")
end
local context_failure, no_posts = run({ reply({ succ = 1 }) }, { context_fail_at = 1 })
eq(context_failure.error_kind, "context", "pre-send context failure retained")
eq(no_posts.posts, 0, "no POST after initial context failure")
local refresh_failure, one_post = run({ reply({ errcode = -1 }) }, { context_fail_at = 2 })
eq(refresh_failure.response_state, "rejected", "context failure retains last actual rejection")
eq(one_post.posts, 1, "no POST after failed refresh")

-- Exercise the Client's own existing HTTP-401 retry: the pipeline must not add
-- yet another POST when that retry has an ambiguous acknowledgement.
for _, response in ipairs({ reply({}), { raise = "SECRET_RETRY_TRANSPORT" } }) do
    local outcome, stats = run({ { http = 401 }, response })
    eq(outcome.response_state, "unconfirmed", "client 401 retry unknown remains unconfirmed")
    eq(stats.posts, 2, "actual wire POST count includes client's HTTP-401 retry")
    eq(stats.refreshes, 0, "pipeline does not repeat the client's uncertain retry")
    eq(stats.renewals, 1, "only client-side 401 renewal happened")
end

-- Log actual outgoing rounded values after outcome application (parent side),
-- using the existing successful-report cadence. No payload fields are added.
local report, stats = fixture({ reply({ succ = true, data = { errcode = 0 }, synckey = "SECRET_WATERMARK",
    vid = "SECRET_ACCOUNT", accessToken = "SECRET_TOKEN", summary = "SECRET_RESPONSE_SUMMARY" }) })
local live = { chapter_uid = 22, chapter_idx = 3, chapter_offset = 151.9,
    percent = 44.25, chapter_fraction = 0.375, summary = "SECRET_POSITION_SUMMARY" }
for _ = 1, 20 do
    local outcome = report:_run_pipeline("SECRET_BOOK_ID", {
        allow_renewal = true, elapsed_seconds = 17.9, position = live,
    })
    eq(report:_apply_outcome(outcome), true, "accepted outcome applied")
end
eq(stats.posts, 20, "twenty reading reports issue exactly twenty POSTs")
eq(log_count("read report success:"), 2, "first and twentieth success logged")
local text = table.concat(logs, "\n")
for _, value in ipairs({ "result=accepted", "readingTime=17", "chapterUid=22", "chapterIdx=3",
        "chapterOffset=151", "progress=44.25", "currentProgress=44.25", "chapterProgress=37",
        "response.succ=1", "response.data.errcode=0" }) do
    contains(text, value, "numeric diagnostic " .. value)
end
eq(text:find("SECRET", 1, true), nil, "success log uses numeric allowlist")
-- APK contract (classes3.dex BaseReportService.ReadBookInShelf): cumulative
-- readingTime, the hour-bucketed ledger, device/app identity and the
-- guest-token signature.
local expected = { bookId = "SECRET_BOOK_ID", chapterUid = 22, chapterIdx = 3, chapterOffset = 151,
    progress = 44.25, currentProgress = 44.25, chapterProgress = 37, readingTime = 17,
    risk = 0, recordCreateTimeZone = "+08:00", reviewId = "", bookVersion = 23,
    ttsTime = 0, lectureTime = 0, lectureTextTime = 0, novalTime = 0,
    isLecture = 0, voiceType = -1, autoTime = 0, isStoryFeed = 0, wordCount = 0 }
for key, value in pairs(expected) do eq(stats.packets[1][key], value, "retained payload field " .. key) end
eq(type(stats.packets[1].timestamp), "number", "payload carries timestamp")
eq(type(stats.packets[1].random), "number", "payload carries random")
eq(type(stats.packets[1].hours), "table", "payload carries the hour ledger")
eq(#stats.packets[1].hours, 1, "single hour bucket in a short session")
eq(stats.packets[1].hours[1].readingTime, 17, "bucket mirrors cumulative time")
eq(stats.packets[1].hours[1].timeZone, "+08:00", "bucket timezone")
eq(type(stats.packets[1].deviceId), "string", "payload carries deviceId")
eq(stats.packets[1].appId, stats.packets[1].deviceId, "appId mirrors deviceId, as in the APK")
eq(type(stats.packets[1].installId), "string", "payload carries installId")
eq(type(stats.packets[1].summary), "string", "payload carries summary")
eq(type(stats.packets[1].signature), "string", "payload carries the read signature")
eq(#stats.packets[1].signature, 64, "signature is sha256 hex")
local allowed = { hours = true, timestamp = true, random = true, deviceId = true,
    appId = true, installId = true, summary = true, signature = true }
for key in pairs(expected) do allowed[key] = true end
for key in pairs(stats.packets[1]) do eq(allowed[key] == true, true, "no extra payload field " .. key) end
for _, key in ipairs({ "psvts", "sg", "s" }) do
    eq(stats.packets[1][key], nil, "web field omitted: " .. key)
end

-- Rejections and unknown results must not leak raw response/error strings.
for _, response in ipairs({ reply({ succ = 1, data = { succ = 0, errcode = -1,
        errmsg = "SECRET_SERVER_MESSAGE", summary = "SECRET_SUMMARY" } }),
        reply({ errorCode = "SECRET_NONNUMERIC", summary = "SECRET_SUMMARY" }),
        reply("SECRET_RAW_BODY"), { raise = "SECRET_TRANSPORT_EXCEPTION" } }) do
    local outcome, _, failed_report = run({ response })
    failed_report:_apply_outcome(outcome)
    local diagnostics = table.concat(logs, "\n")
    contains(diagnostics, "result=" .. outcome.response_state, "failure final state logged")
    contains(diagnostics, "readingTime=30", "periodic default time logged")
    eq(diagnostics:find("SECRET", 1, true), nil, "failure diagnostic redacts nonnumeric contents")
    eq(diagnostics:find("response_body", 1, true), nil, "full response logging removed")
end
local failed_report, failure_stats = fixture({ reply({ succ = 0, errcode = -1 }) })
for _ = 1, 20 do
    failed_report:_apply_outcome(failed_report:_run_pipeline("SECRET_BOOK_ID", { allow_renewal = true }))
end
eq(log_count("read report outcome:"), 2, "repeated failure diagnostics are throttled")
eq(failure_stats.posts, 40, "diagnostics do not add any report attempts")
local packet = failure_stats.packets[1]
eq(packet.currentProgress, nil, "no-position payload excludes currentProgress")
for _, key in ipairs({ "deviceId", "appId", "installId" }) do
    eq(type(packet[key]), "string", "no-position payload keeps " .. key)
end
eq(type(packet.bookVersion), "number", "no-position payload keeps bookVersion")
eq(packet.chapterProgress, 0, "no-position payload keeps chapterProgress")
eq(type(packet.signature), "string", "no-position payload is still signed")
local base_fields = { bookId = true, chapterUid = true, chapterIdx = true,
    chapterOffset = true, progress = true, readingTime = true,
    hours = true, timestamp = true, random = true, risk = true,
    recordCreateTimeZone = true, reviewId = true, chapterProgress = true,
    ttsTime = true, lectureTime = true, lectureTextTime = true, novalTime = true,
    isLecture = true, voiceType = true, autoTime = true, isStoryFeed = true,
    wordCount = true, deviceId = true, appId = true, installId = true,
    summary = true, signature = true, bookVersion = true }
for key in pairs(packet) do eq(base_fields[key], true, "no extra no-position field " .. key) end

print(("read_report_response_spec: %d checks"):format(checks))

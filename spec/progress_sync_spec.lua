-- Unit tests for weread/lib/progress_sync.lua.
-- Run from the repo root with:
--   lua spec/progress_sync_spec.lua

package.path = "./?.lua;" .. package.path
local diagnostic_logs, diagnostic_events = {}, {}
local function capture_log(...)
    local line = {}
    for i = 1, select("#", ...) do line[i] = tostring(select(i, ...)) end
    diagnostic_logs[#diagnostic_logs + 1] = table.concat(line, " ")
    diagnostic_events[#diagnostic_events + 1] = { ... }
end
package.loaded["weread.lib.logger"] = { scoped = function()
    return { info = capture_log, warn = capture_log, err = capture_log }
end }
-- Only unrelated catalog/network dependencies are stubbed. Mapper, payload
-- construction, _send, normalization and confirmation below are real functions.
package.preload["weread.lib.content"] = function() return {} end
package.preload["weread.lib.protocol"] = function() return {} end
local ProgressSync = require("weread.lib.progress_sync")
local Mapper = require("weread.lib.position_mapper")
local ReadReport = require("weread.lib.read_report")

local failures, checks = 0, 0
local current_test
local PULL_RETRY_DELAY_SECONDS = 15

local function eq(got, want, label)
    checks = checks + 1
    if got ~= want then
        failures = failures + 1
        print(string.format("FAIL [%s] %s: got %s, want %s",
            current_test, label, tostring(got), tostring(want)))
    end
end

local function test(name, fn)
    current_test = name
    diagnostic_logs, diagnostic_events = {}, {}
    fn()
end

local function events(label)
    local result = {}
    for _, event in ipairs(diagnostic_events) do
        if event[1] == label then result[#result + 1] = event end
    end
    return result
end

local function confirmation(status, reason)
    local calls = events("upload confirmation:")
    eq(#calls, 1, "exactly one confirmation for this test's upload")
    eq(calls[1] and calls[1][2], status, "exact confirmation status")
    eq(calls[1] and calls[1][4], reason, "fixed confirmation reason")
end

local chapters = {
    { chapterUid = 11, chapterIdx = 1, wordCount = 100 },
    { chapterUid = 22, chapterIdx = 2, wordCount = 300 },
    { chapterUid = 33, chapterIdx = 3, wordCount = 600 },
}

local function subprocess_fixture()
    local payload
    return {
        run = function(child)
            child(100, 200)
            return 100, 200
        end,
        write_all = function(_fd, data)
            payload = data
        end,
        is_done = function() return true end,
        terminate = function() end,
        read_size = function()
            return payload and #payload or 0
        end,
        read_all = function()
            local value = payload
            payload = nil
            return value
        end,
    }
end

local function fixture(remote, options)
    options = options or {}
    local document = {
        file = "/cache/book/full.epub",
        page = 25,
        getCurrentPage = function(self) return self.page end,
        getPageCount = function() return 100 end,
    }
    -- The reader now resolves actual TOC/XPointer identity. This baseline
    -- fixture deliberately has layout proportional to words; separate regression
    -- cases below make those distributions disagree.
    local reader_catalog
    local function get_chapters()
        if options.get_chapters then reader_catalog = options.get_chapters()
        else reader_catalog = chapters end
        if reader_catalog then
            for _, ch in ipairs(reader_catalog) do
                ch.title = ch.title or tostring(ch.chapterUid)
            end
        end
        return reader_catalog
    end
    document.info = { doc_height = 10000 }
    document.getXPointer = function(self) return tostring(self.page * 100) end
    document.getPosFromXPointer = function(_, xp) return tonumber(xp) end
    document.getPageXPointer = function(_, page) return tostring(page * 100) end
    document.compareXPointers = function(_, a, b)
        a, b = tonumber(a), tonumber(b)
        return a == b and 0 or (a < b and 1 or -1)
    end
    document.getToc = function()
        local map, toc = Mapper.catalog(reader_catalog), {}
        for _, item in ipairs(map.chapters) do
            toc[#toc + 1] = { title = item.source.title, depth = 1,
                xpointer = tostring(item.before / map.total_words * 10000) }
        end
        return toc
    end
    local book = {
        book_id = "book",
        title = "Book",
        summary = "Book",
        cached_file = document.file,
        cached_chapters = {
            ["11"] = document.file,
            ["22"] = document.file,
            ["33"] = document.file,
        },
    }
    local values = {
        sync = {
            pull_on_open = true,
            upload_on_close = true,
            ask_on_conflict = true,
        },
        books = { book = book },
    }
    local settings = {
        get = function(_self, key, default)
            return values[key] or default
        end,
        set = function(_self, key, value)
            values[key] = value
        end,
        flush = function() end,
        is_eink_configured = function() return true end,
    }
    local queue = {}
    local delays = {}
    local scheduler = {
        scheduleIn = function(_self, delay, callback)
            queue[#queue + 1] = callback
            delays[#delays + 1] = delay
        end,
        unschedule = function(_self, callback)
            for i, item in ipairs(queue) do
                if item == callback then
                    table.remove(queue, i)
                    table.remove(delays, i)
                    return
                end
            end
        end,
    }
    local choices = {}
    local uploads = {}
    local jumps = {}
    local notifications = {}
    local encoded_payload
    local client = {
        get_progress = function()
            local value = remote
            if options.remote_provider then
                value = options.remote_provider()
            end
            return { book = value }
        end,
        json_encode = function(_self, value)
            encoded_payload = value
            return "encoded"
        end,
        json_decode = function()
            return encoded_payload
        end,
    }
    local sync = ProgressSync:new{
        settings = settings,
        client = client,
        scheduler = scheduler,
        get_document = function() return document end,
        detect_book = function() return "book" end,
        get_book = function() return book end,
        get_chapters = get_chapters,
        refresh_catalog = options.refresh_catalog,
        get_file_context = function()
            return nil, nil, true
        end,
        run_online = options.run_online or function(_kind, callback)
            callback()
            return true
        end,
        upload_position = function(_book_id, position, elapsed)
            uploads[#uploads + 1] = position
            eq(elapsed, 0, "progress upload has zero reading time")
            return true, { accepted = true }
        end,
        build_upload_outcome = options.build_upload_outcome,
        apply_upload_outcome = options.apply_upload_outcome,
        goto_fraction = function(fraction)
            jumps[#jumps + 1] = fraction
            document.page = math.floor(fraction * 100 + 0.5)
            return true
        end,
        goto_xpointer = function(xp)
            jumps[#jumps + 1] = tonumber(xp) / 10000
            document.page = tonumber(xp) / 100
            return true
        end,
        open_chapter = function() return true end,
        on_choice = function(context)
            choices[#choices + 1] = context
        end,
        notify = function(code, data)
            notifications[#notifications + 1] = { code = code, data = data }
        end,
        readback_delay_seconds = options.readback_delay_seconds,
        readback_attempts = options.readback_attempts,
        is_online = options.is_online,
        now = options.now,
        subprocess = options.subprocess or false,
    }
    local function step()
        assert(#queue > 0, "scheduler queue is empty")
        local callback = table.remove(queue, 1)
        local delay = table.remove(delays, 1)
        callback()
        return delay
    end
    local function drain()
        local count = 0
        while #queue > 0 do
            count = count + 1
            assert(count < 20, "scheduler did not quiesce")
            step()
        end
    end
    return {
        sync = sync,
        document = document,
        values = values,
        choices = choices,
        uploads = uploads,
        jumps = jumps,
        notifications = notifications,
        queue = queue,
        delays = delays,
        step = step,
        drain = drain,
    }
end

-- Unlike the legacy fixture, child execution and completion are separate
-- scheduled phases. This catches close/reopen races before fork and after POST.
local function deferred_upload_fixture(accepted, remote_provider, options)
    options = options or {}
    local child, payload, done
    local stats = { built = 0, applied = 0, reads = 0 }
    local runner = {
        run = function(fn) child = fn; done = false; return 10, 20 end,
        write_all = function(_fd, data) payload = data end,
        is_done = function() return done end,
        terminate = function() done = true end,
        read_size = function() return payload and #payload or 0 end,
        read_all = function() local p = payload; payload = nil; return p end,
    }
    local f = fixture(nil, {
        subprocess = runner,
        get_chapters = options.get_chapters,
        now = options.now,
        remote_provider = function()
            stats.reads = stats.reads + 1
            if remote_provider then return remote_provider() end
            return { progress = 50, chapterUid = 33, chapterOffset = 100 }
        end,
        -- Run the diagnostic readback inline; production waits 3s and retries.
        readback_delay_seconds = 0.2,
        readback_attempts = 1,
        build_upload_outcome = function(_id, position)
            stats.built = stats.built + 1
            stats.position = position
            return { accepted = accepted ~= false }
        end,
        apply_upload_outcome = function() stats.applied = stats.applied + 1 end,
    })
    f.values.sync.pull_on_open = false
    f.sync:on_reader_ready(); f.drain()
    f.sync.verified = true
    f.document.page = options.percent or 50
    f.sync:on_page_update()
    f.execute_child = function() child(10, 20); done = true end
    local original_drain = f.drain
    f.drain = function()
        -- Start any queued confirmation, then run its separate worker phase.
        if stats.applied > 0 then
            original_drain()
            return
        end
        if #f.queue > 0 and stats.built > 0 then f.step() end
        if #f.queue > 0 and f.delays[1] == 0.2 then
            f.step()
            if f.sync.job then f.execute_child() end
        end
        original_drain()
    end
    f.stats = stats
    return f
end

test("close snapshot survives deferred fork and confirms once", function()
    local f = deferred_upload_fixture()
    f.sync:on_close_document()
    eq(f.stats.built, 0, "close did not perform network IO")
    f.document.page = 90
    f.step() -- start the child, do not execute it inline
    f.execute_child()
    f.drain()
    eq(f.stats.built, 1, "closed snapshot actually posted")
    eq(f.stats.position.percent, 50, "immutable close location")
    eq(f.stats.applied, 1, "outcome applied once")
    eq(f.stats.reads, 1, "one diagnostic readback")
    eq(f.sync.state, "idle", "closed reader stays idle")
    eq(f.values.books.book.pending_upload_position, nil, "accepted cleared pending")
    f.sync:on_close_document(); f.drain()
    eq(f.stats.built, 1, "duplicate close cannot upload twice")
end)

for _, change in ipairs({ "account", "same_book", "other_book" }) do
    for _, phase in ipairs({ "queued", "inflight" }) do
        test(change .. " rejects stale " .. phase .. " upload", function()
            local f = deferred_upload_fixture()
            f.sync:on_close_document()
            if phase == "inflight" then f.step(); f.execute_child() end
            if change == "account" then
                f.values.eink = { vid = "new_account" }
                f.sync:on_account_changed()
            else
                if change == "other_book" then
                    f.sync.detect_book = function() return "other" end
                end
                f.sync:on_reader_ready()
            end
            f.sync:_queue_snapshot({ book_id = "book", percent = 75 }, "newer")
            f.drain()
            eq(f.stats.built, phase == "inflight" and 1 or 0, "no stale queued POST")
            eq(f.stats.applied, 0, "no stale auth/context apply")
            eq(f.values.books.book.pending_upload_position.percent, 75,
                "late result preserves newer pending")
            eq(f.sync.last_uploaded_position, nil, "new reader not polluted")
        end)
    end
end

test("failed close preserves retry snapshot without readback", function()
    local f = deferred_upload_fixture(false)
    f.sync:on_close_document(); f.step(); f.execute_child(); f.drain()
    eq(f.values.books.book.pending_upload_position.percent, 50, "failed snapshot retained")
    eq(f.stats.reads, 0, "failed POST needs no diagnostic GET")
    eq(f.stats.built, 1, "no unbounded retry")
end)

test("failed GET cannot retry an accepted POST", function()
    local f = deferred_upload_fixture(true, function() error("private response") end)
    f.sync:on_close_document(); f.step(); f.execute_child(); f.drain()
    eq(f.stats.built, 1, "POST performed once")
    eq(f.stats.reads, 1, "GET performed once")
    eq(f.values.books.book.pending_upload_position, nil, "GET failure does not requeue POST")
    confirmation("unavailable", "readback_unavailable")
    eq(table.concat(diagnostic_logs, "\n"):find("private response", 1, true), nil,
        "GET exception text is not logged")
end)

test("newer pending survives same-session accepted callback", function()
    local f = deferred_upload_fixture()
    f.sync:on_close_document(); f.step(); f.execute_child()
    f.sync:_queue_snapshot({ book_id = "book", percent = 80 }, "newer")
    f.drain()
    eq(f.values.books.book.pending_upload_position.percent, 80, "newer snapshot preserved")
end)

test("new plugin instance invalidates old queued snapshot", function()
    local f = deferred_upload_fixture()
    f.sync:on_close_document()
    local other = fixture(nil)
    other.sync.settings = f.sync.settings
    other.values.sync.pull_on_open = false
    other.sync:on_reader_ready()
    f.drain()
    eq(f.stats.built, 0, "shared settings session rejects old instance")
end)

test("accepted is persisted before separate readback starts", function()
    local f = deferred_upload_fixture()
    f.sync:on_close_document(); f.step(); f.execute_child(); f.step()
    eq(f.values.books.book.pending_upload_position, nil, "POST committed before GET")
    eq(f.stats.reads, 0, "GET has not run")
    local accepted_log = table.concat(diagnostic_logs, "\n")
    eq(accepted_log:find("upload accepted:", 1, true) ~= nil, true, "accepted log exists")
    f.step(); f.execute_child(); f.step()
    confirmation("confirmed", "chapter_coordinates_match")
end)

test("readback diagnostics never log remote text or credentials", function()
    local f = deferred_upload_fixture(true, function()
        return { progress = 50, chapterUid = 33, chapterOffset = 100,
            summary = "SECRET_ORIGINAL_TEXT", token = "SECRET_TOKEN", cookie = "SECRET_COOKIE" }
    end)
    f.sync:on_close_document(); f.step(); f.execute_child(); f.drain()
    eq(table.concat(diagnostic_logs, "\n"):find("SECRET", 1, true), nil,
        "position log uses numeric allowlist")
end)

-- million-word catalog reproduces the integer-vs-reconstructed percent bug.
local function roundtrip_fixture(percent, mutate_response)
    local snapshot_catalog = {
        { chapterUid = 652, chapterIdx = 1, wordCount = 455000 },
        { chapterUid = 653, chapterIdx = 2, wordCount = 1000 },
        { chapterUid = 654, chapterIdx = 3, wordCount = 544000 },
    }
    local response
    local f = deferred_upload_fixture(true, function() return response end, {
        percent = percent,
        get_chapters = function() return snapshot_catalog end,
    })
    f.values.read_report = {}
    local report = ReadReport:new{
        settings = f.sync.settings,
        scheduler = f.sync.scheduler,
        get_document = f.sync.get_document,
        detect_book = f.sync.detect_book,
        now = function() return 100 end,
        subprocess = false,
        client = { report_read = function(_self, payload)
            f.stats.posts = (f.stats.posts or 0) + 1
            f.stats.payload = payload
            response = {}
            for key, value in pairs(payload) do response[key] = value end
            if mutate_response then mutate_response(response) end
            return { succ = 1 }
        end },
    }
    f.sync.build_upload_outcome = function(id, position, elapsed)
        f.stats.built = f.stats.built + 1
        f.stats.position = position
        local result = report:_send(id, {}, position, elapsed)
        return { accepted = result.succ == 1 }
    end
    f.report = report
    f.catalog = snapshot_catalog
    f.response = function() return response end
    return f
end

local function complete_close(f)
    f.sync:on_close_document(); f.step(); f.execute_child(); f.drain()
    eq(f.stats.posts, 1, "one final payload posted")
    eq(f.stats.reads, 1, "one readback")
    eq(f.values.books.book.pending_upload_position, nil, "accepted stays committed")
    eq(f.sync.state, "idle", "closed reader is not reopened by confirmation")
    f.sync:on_close_document(); f.drain()
    eq(f.stats.posts, 1, "confirmation never makes the accepted snapshot retryable")
end

for _, percent in ipairs({ 0, 44.99999, 45, 45.49, 45.50, 45.52275,
        45.52564, 45.88353, 45.99, 45.99999, 46, 46.00001, 99.99999, 100 }) do
    test("real payload roundtrip at " .. percent .. " percent", function()
        local f = roundtrip_fixture(percent)
        complete_close(f)
        confirmation("confirmed", "chapter_coordinates_match")
        local position, payload = f.stats.position, f.stats.payload
        eq(payload.chapterUid, position.chapter_uid, "actual outgoing UID")
        eq(payload.chapterOffset, position.chapter_offset, "actual outgoing offset")
        eq(payload.progress, position.percent, "actual outgoing floored percent unchanged")
        eq(payload.fraction, nil, "diagnostic fraction not added to payload protocol")
        local remote = assert(Mapper.normalize_remote(f.response(), "book", "eink", f.catalog))
        eq(Mapper.same_position(position, remote), math.abs(position.percent - remote.percent) <= 0.5,
            "generic same_position tolerance unchanged")
        if percent == 45.52564 then
            eq(position.chapter_uid, 653, "minimal reproduction UID")
            eq(position.chapter_offset, 256, "minimal reproduction offset")
            eq(position.percent, 45, "minimal reproduction floored percent")
            eq(math.abs(remote.percent - 45.5256) < 1e-9, true, "reconstructed precise percent")
            eq(Mapper.same_position(position, remote), false, "legacy comparator demonstrably fails")
        end
        eq(#events("upload snapshot"), 1, "one key-action snapshot log")
        eq(#events("upload payload:"), 1, "one final payload log")
        eq(#events("upload readback"), 1, "one numeric readback log")
    end)
end

for _, mismatch in ipairs({
    { field = "chapterUid", delta = 1, reason = "chapter_uid_mismatch" },
    { field = "chapterOffset", delta = 1, reason = "chapter_offset_mismatch" },
    { field = "chapterOffset", delta = -1, reason = "chapter_offset_mismatch" },
}) do
    test("readback mismatch " .. mismatch.field .. mismatch.delta, function()
        local f = roundtrip_fixture(45.52564, function(response)
            response[mismatch.field] = response[mismatch.field] + mismatch.delta
        end)
        complete_close(f)
        confirmation("not_confirmed", mismatch.reason)
    end)
end

test("numeric string coordinates confirm without comparing percent", function()
    local f = roundtrip_fixture(45.52564, function(response)
        response.chapterUid = tostring(response.chapterUid)
        response.chapterOffset = tostring(response.chapterOffset)
        response.progress = 99 -- lower-priority coarse field is not positional evidence
    end)
    complete_close(f)
    confirmation("confirmed", "chapter_coordinates_match")
end)

for _, field in ipairs({ "chapterUid", "chapterOffset" }) do
    for _, invalid in ipairs({
        { label = "missing", value = nil },
        { label = "text", value = "SECRET_BAD_COORDINATE" },
        { label = "empty", value = "" },
        { label = "boolean", value = false },
        { label = "table", value = {} },
        { label = "negative", value = -1 },
        { label = "fractional", value = 0.5 },
        { label = "infinite", value = math.huge },
        { label = "negative_infinite", value = -math.huge },
        { label = "nan", value = 0 / 0 },
    }) do
        test("readback " .. field .. " " .. invalid.label .. " cannot confirm", function()
            -- A chapter start specifically catches default/clamped-zero false matches.
            local f = roundtrip_fixture(45.50, function(response)
                response[field] = invalid.value
            end)
            complete_close(f)
            local coordinate = field == "chapterUid" and "uid" or "offset"
            local problem = invalid.label == "missing" and "missing" or "invalid"
            confirmation("unavailable", "readback_" .. coordinate .. "_" .. problem)
            eq(table.concat(diagnostic_logs, "\n"):find("SECRET", 1, true), nil,
                "illegal coordinate text never enters logs")
        end)
    end
end

test("zero is an invalid chapter UID but a valid offset", function()
    local f = roundtrip_fixture(45.50, function(response) response.chapterUid = 0 end)
    complete_close(f)
    confirmation("unavailable", "readback_uid_invalid")
end)

for _, field in ipairs({ "chapter_uid", "chapter_offset" }) do
    for _, invalid in ipairs({ { label = "missing" }, { label = "invalid", value = -1 } }) do
        test("invalid upload snapshot " .. field .. " " .. invalid.label, function()
            local f = roundtrip_fixture(45.50)
            local position = f.sync:capture_local()
            position[field] = invalid.value
            f.sync:_upload_snapshot(position, "manual_sync", false)
            f.step(); f.execute_child(); f.drain()
            confirmation("unavailable", "snapshot_" ..
                (field == "chapter_uid" and "uid" or "offset") .. "_" .. invalid.label)
            eq(f.stats.posts, 1, "no retry for incomplete accepted snapshot")
        end)
    end
end

for _, malformed in ipairs({ "empty", "missing_progress", "invalid_progress" }) do
    test("unavailable readback " .. malformed .. " cannot confirm", function()
        local f = roundtrip_fixture(45.50, function(response)
            if malformed == "empty" then
                for key in pairs(response) do response[key] = nil end
            else
                response.progress = malformed == "invalid_progress" and "SECRET_PROGRESS" or nil
            end
        end)
        complete_close(f)
        confirmation("unavailable", "readback_unavailable")
        eq(table.concat(diagnostic_logs, "\n"):find("SECRET", 1, true), nil,
            "invalid progress text never enters logs")
    end)
end

test("confirmation uses the close-time catalog after mutation and release", function()
    local f = roundtrip_fixture(45.52564)
    local observed_chapters
    local fetch = f.sync._child_fetch_remote
    f.sync._child_fetch_remote = function(self, id, snapshot_chapters)
        observed_chapters = snapshot_chapters
        return fetch(self, id, snapshot_chapters)
    end
    f.sync:on_close_document()
    f.catalog[1].wordCount = 1
    f.document.page = 90
    eq(f.sync.document_context, nil, "reader context released before child starts")
    f.step(); f.execute_child(); f.drain()
    eq(observed_chapters == f.catalog, false, "catalog independently copied")
    eq(observed_chapters[1].wordCount, 455000, "original chapter word count retained")
    confirmation("confirmed", "chapter_coordinates_match")
    local readback = events("upload readback")[1]
    eq(math.abs(tonumber(readback[9]) - 45.5256) < 1e-9, true,
        "logged readback percent uses the same snapshot catalog")
end)

test("hung confirmation times out without requeuing an accepted POST", function()
    local now = 100
    local f = deferred_upload_fixture(true, nil, { now = function() return now end })
    f.sync:on_close_document(); f.step(); f.execute_child(); f.step()
    eq(f.values.books.book.pending_upload_position, nil, "accepted persisted before hung GET")
    f.step() -- queue readback worker, deliberately never execute it
    eq(f.sync.job.kind, "progress_confirmation", "independent confirmation worker")
    now = now + 181
    f.step()
    confirmation("unavailable", "readback_unavailable")
    eq(f.stats.built, 1, "timeout did not repost")
    eq(f.values.books.book.pending_upload_position, nil, "timeout did not restore pending")
    eq(f.sync.job, nil, "confirmation job released")
    eq(#f.queue, 0, "no retry scheduled")
    eq(f.sync.state, "idle", "closed reader remains idle")
end)

test("key-action logs exclude private text and heartbeat/page updates stay quiet", function()
    local f = roundtrip_fixture(45.52564, function(response)
        response.summary = "SECRET_REMOTE_TEXT"
        response.chapterTitle = "SECRET_REMOTE_TITLE"
        response.token = "SECRET_REMOTE_TOKEN"
    end)
    f.values.books.book.title = "SECRET_LOCAL_TITLE"
    f.values.books.book.summary = "SECRET_LOCAL_SUMMARY"
    f.values.eink = { access_token = "SECRET_ACCESS_TOKEN" }
    complete_close(f)
    eq(table.concat(diagnostic_logs, "\n"):find("SECRET", 1, true), nil,
        "snapshot, final payload and readback omit text and credentials")
    local logged = #diagnostic_events
    f.report:_send("book", {}, f.stats.position, 30)
    f.report:_send("book", {}, f.stats.position, nil)
    for _ = 1, 20 do f.sync:on_page_update() end
    eq(#diagnostic_events, logged, "periodic reports and page updates add no diagnostic noise")
    local snapshot, payload = events("upload snapshot")[1], events("upload payload:")[1]
    for _, index in ipairs({ 3, 5, 7, 9 }) do
        eq(tonumber(payload[index]), tonumber(snapshot[index]), "final payload numeric field " .. index)
    end
end)

test("failed immutable close snapshot can be retried explicitly", function()
    local f = deferred_upload_fixture(false)
    f.sync:on_close_document(); f.step(); f.execute_child(); f.drain()
    local pending = f.values.books.book.pending_upload_position
    f.sync.build_upload_outcome = function(_id, position)
        f.stats.built = f.stats.built + 1
        eq(position.percent, 50, "retry retains failed close location")
        return { accepted = true }
    end
    f.sync:_upload_snapshot(pending, "retry", false)
    f.step(); f.execute_child(); f.step()
    eq(f.values.books.book.pending_upload_position, nil, "retry acceptance clears snapshot")
    eq(f.stats.built, 2, "one failed POST and one explicit retry")
    f.step(); f.execute_child(); f.step()
end)

test("late duplicate job callback is idempotent", function()
    local f = deferred_upload_fixture()
    f.sync:on_close_document(); f.step()
    local completion = f.sync.job.complete
    f.execute_child(); f.step()
    completion({ upload = { accepted = true } })
    eq(f.stats.applied, 1, "duplicate completion cannot apply context again")
    eq(#f.queue, 1, "duplicate completion schedules no second confirmation")
    f.step(); f.execute_child(); f.step()
end)

test("matching open progress verifies the reporting gate", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "session verified")
    eq(#f.choices, 0, "no conflict dialog")
    local position, reason, applies = f.sync:position_for_report("book")
    eq(applies, true, "provider applies")
    eq(reason, nil, "no gate reason")
    eq(position.chapter_uid, 22, "live chapter")
    eq(position.chapter_offset, 150, "live offset")
end)

test("automatic progress pull runs in a subprocess when available", function()
    local online_tasks = 0
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        subprocess = subprocess_fixture(),
        run_online = function()
            online_tasks = online_tasks + 1
            return false
        end,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(online_tasks, 0, "UI-thread online wrapper is bypassed")
    eq(f.sync:status().verified, true, "subprocess result verifies session")
end)

test("offline automatic pull schedules a delayed retry", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    f.sync:on_reader_ready()
    eq(f.step(), 0.6, "reader open keeps its existing delay")
    eq(f.sync:status().state, "offline", "automatic pull records offline")
    eq(#f.queue, 1, "offline automatic pull queues one retry")
    eq(f.delays[1], PULL_RETRY_DELAY_SECONDS, "retry waits for the link")
    eq(#f.notifications, 0, "automatic retry stays silent")
end)

test("offline manual sync never schedules a retry", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    eq(f.sync:sync_now(), false, "offline manual sync does not start")
    eq(#f.queue, 0, "manual path leaves the queue empty")
    eq(#f.notifications, 1, "manual offline notifies once")
    eq(f.notifications[1].code, "offline", "offline message is explicit")
end)

test("automatic pull retries stop at the attempt limit", function()
    local f = fixture({}, {
        is_online = function() return false end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(#f.queue, 1, "first retry queued")
    f.step()
    eq(#f.queue, 1, "second retry queued")
    f.step()
    eq(#f.queue, 1, "third retry queued")
    f.step()
    eq(#f.queue, 0, "retries stop at the limit")
    eq(f.sync:status().verified, false, "exhausted retries stay gated")
end)

test("automatic remote pull failure retries silently", function()
    local f = fixture({}, {
        remote_provider = function()
            error("weread link is not ready")
        end,
    })
    f.sync:on_reader_ready()
    eq(f.step(), 0.6, "reader open keeps its existing delay")
    eq(f.sync:status().verified, false, "failed remote pull stays gated")
    eq(#f.queue, 1, "remote pull failure queues one retry")
    eq(f.delays[1], PULL_RETRY_DELAY_SECONDS, "remote failure waits before retry")
    eq(#f.notifications, 0, "automatic remote failure stays silent")
end)

test("a stale in-flight pull does not block the next document", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync.pulling = true
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "new document pull is not blocked by a stale lock")
end)

test("stale pull completion does not clear the current pulling lock", function()
    local f = fixture({})
    f.sync.generation = 2
    f.sync.pulling = true
    f.sync:_complete_pull(1, { book_id = "old" }, { book_id = "old" }, {}, nil, "stale")
    eq(f.sync.pulling, true, "stale completion leaves the current lock")
end)

test("automatic online task failure remains silent and retries", function()
    local run_options
    local f = fixture({}, {
        is_online = function() return true end,
        run_online = function(_kind, _callback, options)
            run_options = options
            return false
        end,
    })
    f.sync:on_reader_ready()
    f.step()
    eq(f.sync:status().state, "offline", "failed online task records offline")
    eq(#f.queue, 1, "failed automatic online task queues one retry")
    eq(f.delays[1], PULL_RETRY_DELAY_SECONDS, "retry remains delayed")
    eq(run_options.silent_offline, true, "automatic preflight stays silent")
    eq(#f.notifications, 0, "automatic start failure does not notify")
end)

test("nearby percent no longer hides uncertain chapter offsets", function()
    local f = fixture({
        bookId = "book",
        progress = 26.9,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 169,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, false, "uncertain offset stays gated")
    eq(#f.choices, 1, "uncertain offset prompts")
    eq(f.choices[1].position_uncertain, true, "does not claim a precise native mismatch")
end)

test("unresolved conflict blocks reports and local choice uploads", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 1, "conflict dialog requested")
    local position, reason, applies = f.sync:position_for_report("book")
    eq(position, nil, "position withheld")
    eq(reason, "progress_unverified", "gate reason")
    eq(applies, true, "provider applies")
    f.choices[1].keep_local()
    eq(f.sync:status().verified, true, "local choice verifies")
    eq(#f.uploads, 1, "local choice uploads immediately")
    eq(f.uploads[1].chapter_offset, 150, "uploaded immutable position")
end)

test("page change uploads once on close", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 50
    f.sync:on_page_update()
    eq(f.sync:status().dirty, true, "page change marks dirty")
    f.sync:on_close_document()
    eq(#f.uploads, 1, "close uploads once")
    eq(f.uploads[1].percent, 50, "close uploads current percent")
    eq(f.uploads[1].chapter_uid, 33, "close uploads current chapter")
    eq(f.values.books.book.pending_upload_position, nil,
        "successful upload clears pending snapshot")
end)

test("remote choice jumps and verifies before reporting", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    f.drain()
    eq(#f.jumps, 1, "one jump")
    eq(f.jumps[1], 0.5, "jump fraction")
    eq(f.sync:status().verified, true, "remote choice verifies")
    local position = f.sync:position_for_report("book")
    eq(position.percent, 50, "report sees jumped position")
end)

test("busy read report is retried with the immutable snapshot", function()
    local f = fixture({
        bookId = "book",
        progress = 50,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 100,
        updateTime = 10,
    })
    local attempts = 0
    local uploaded
    f.sync.upload_position = function(_book_id, position)
        attempts = attempts + 1
        if attempts == 1 then
            return false, { error = "busy", error_kind = "busy" }
        end
        uploaded = position
        return true, { accepted = true }
    end
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].keep_local()
    -- Mutating the live page must not change the already captured retry.
    f.document.page = 75
    f.drain()
    eq(attempts, 2, "busy upload retried")
    eq(uploaded.percent, 25, "retry uses immutable position")
    eq(f.values.books.book.pending_upload_position, nil,
        "retry success clears pending snapshot")
end)

test("suspend queues movement locally and reconnect flushes it", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 40
    f.sync:on_suspend()
    eq(#f.uploads, 0, "suspend performs no network upload")
    eq(f.values.books.book.pending_upload_position.percent, 40,
        "suspend persists the immutable position")
    eq(f.values.books.book.pending_upload_reason, "suspend",
        "suspend records the queue reason")
    f.sync:on_network_connected()
    eq(#f.uploads, 1, "network reconnect flushes queued movement")
    eq(f.uploads[1].percent, 40, "suspend uses current page")
    eq(f.values.books.book.pending_upload_position, nil,
        "successful reconnect clears pending snapshot")
end)

test("suspend outside a WeRead document captures nothing and stays silent", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync.verified, true, "open WeRead document verifies first")
    local notifications = #f.notifications
    f.sync.detect_book = function() return nil end
    f.sync:on_suspend()
    eq(#f.notifications, notifications, "no dialog while no WeRead book is open")
    eq(f.sync.verified, true, "lock outside a document keeps verification")
    eq(f.values.books.book.pending_upload_position, nil,
        "lock outside a document queues nothing")
end)

test("reconnect uploads a queued snapshot in a subprocess", function()
    local built = 0
    local applied = 0
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        subprocess = subprocess_fixture(),
        build_upload_outcome = function(_book_id, position, elapsed)
            built = built + 1
            eq(position.percent, 40, "child receives immutable snapshot")
            eq(elapsed, 0, "child upload adds no reading time")
            return { accepted = true }
        end,
        apply_upload_outcome = function(_book_id, outcome)
            applied = applied + 1
            return outcome.accepted == true
        end,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.document.page = 40
    f.sync:on_suspend()
    f.sync:on_network_connected()
    f.drain()
    eq(built, 1, "one child upload started")
    eq(applied, 1, "parent applied one child outcome")
    eq(#f.uploads, 0, "blocking upload path was not used")
    eq(f.values.books.book.pending_upload_position, nil,
        "child success clears pending snapshot")
end)

test("long resume waits for a real network event before rechecking", function()
    local online = true
    local now = 100
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        is_online = function() return online end,
        now = function() return now end,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "initial open verifies")

    f.sync:on_suspend()
    online = false
    now = 100 + 6 * 60
    f.sync:on_resume()
    eq(f.sync:status().state, "waiting_for_network",
        "resume does not start network work")
    eq(f.sync:status().verified, false,
        "reading report remains gated until recheck")
    eq(#f.queue, 1, "offline resume schedules one fallback")
    eq(f.delays[1], 8, "fallback waits for DHCP quiet period")
    f.drain()
    eq(f.sync:status().state, "waiting_for_network",
        "fallback stays idle while Wi-Fi is down")
    eq(f.sync:status().verified, false,
        "offline fallback does not clear the report gate")

    online = true
    f.sync:on_network_connected()
    eq(f.sync:status().verified, true,
        "network event completes deferred recheck")
end)

test("resume while link is up still waits before fallback recheck", function()
    local now = 100
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        is_online = function() return true end,
        now = function() return now end,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "initial open verifies")

    f.sync:on_suspend()
    now = 100 + 6 * 60
    f.sync:on_resume()
    eq(f.sync:status().state, "waiting_for_network",
        "stale link-up must not start resume network work immediately")
    eq(f.sync:status().verified, false,
        "reading report remains gated until recheck")
    eq(#f.queue, 1, "online resume still defers to fallback")
    eq(f.delays[1], 8, "fallback waits for DHCP quiet period")

    f.drain()
    eq(f.sync:status().verified, true,
        "fallback rechecks once the quiet period has passed")
end)

test("stale connected state keeps resume recheck queued after child failure", function()
    local now = 100
    local current_remote = {
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }
    local f = fixture(current_remote, {
        subprocess = subprocess_fixture(),
        is_online = function() return true end,
        now = function() return now end,
        remote_provider = function() return current_remote end,
    })
    f.sync:on_reader_ready()
    f.drain()
    f.sync:on_suspend()
    now = 100 + 6 * 60
    current_remote = nil
    f.sync:on_resume()
    f.drain()
    eq(f.sync:status().state, "waiting_for_network",
        "failed stale-state child remains deferred")

    current_remote = {
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 20,
    }
    f.sync:on_network_connected()
    f.drain()
    eq(f.sync:status().verified, true,
        "later real network event retries deferred pull")
end)

test("single chapter cloud choice waits for target chapter then jumps", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    local current_chapter = chapters[1]
    local requested_chapter
    f.sync.get_file_context = function()
        return 1, current_chapter, false
    end
    f.sync.open_chapter = function(_book, chapter)
        requested_chapter = chapter
        return true
    end
    f.document.page = 50
    f.sync:on_reader_ready()
    f.drain()
    eq(#f.choices, 1, "chapter conflict requested")
    f.choices[1].use_remote()
    eq(requested_chapter.chapterUid, 22, "target chapter requested")
    eq(f.sync:status().verified, false, "reporting remains gated")
    eq(f.sync:status().state, "switching_chapter", "waiting for open")

    -- Simulate the downloader opening the requested single-chapter EPUB.
    current_chapter = chapters[2]
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().verified, true, "target chapter verifies")
    eq(f.jumps[#f.jumps], 0.5, "target chapter offset applied")
end)

test("cancelling target chapter download clears the pending jump", function()
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    })
    f.sync.get_file_context = function()
        return 1, chapters[1], false
    end
    f.sync.open_chapter = function() return true end
    f.document.page = 50
    f.sync:on_reader_ready()
    f.drain()
    f.choices[1].use_remote()
    eq(f.sync:cancel_pending_jump("cancelled"), true, "pending cancelled")
    eq(f.sync:status().state, "unverified", "returns to safe state")
    eq(f.sync:status().verified, false, "reporting stays gated")
end)

test("automatic hooks stay disabled when flags are absent", function()
    local f = fixture({
        bookId = "book",
        progress = 75,
        chapterUid = 33,
        chapterIdx = 3,
        chapterOffset = 300,
        updateTime = 10,
    })
    f.values.sync = {}
    f.sync:on_reader_ready()
    f.drain()
    eq(f.sync:status().state, "unverified", "open does not pull by default")
    eq(#f.choices, 0, "open does not prompt by default")

    f.sync.verified = true
    f.sync.dirty = true
    f.sync:on_close_document()
    eq(#f.uploads, 0, "close does not upload by default")
end)

test("manual sync refreshes a missing catalog inside the online task", function()
    local available_chapters
    local refresh_count = 0
    local online_count = 0
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, {
        get_chapters = function() return available_chapters end,
        refresh_catalog = function(book_id)
            eq(book_id, "book", "refresh receives current book")
            refresh_count = refresh_count + 1
            available_chapters = chapters
            return chapters
        end,
        run_online = function(_kind, callback)
            online_count = online_count + 1
            callback()
            return true
        end,
    })
    eq(f.sync:sync_now(), true, "manual sync starts")
    eq(refresh_count, 1, "catalog refreshed once")
    eq(online_count, 1, "catalog and progress share one online task")
    eq(f.sync:status().verified, true, "refreshed catalog completes sync")
    eq(#f.notifications, 1, "aligned manual sync notifies once")
    eq(f.notifications[1].code, "already_synced", "sync result notified")
end)

test("automatic open never refreshes a missing catalog", function()
    local refresh_count = 0
    local f = fixture({}, {
        get_chapters = function() return nil end,
        refresh_catalog = function()
            refresh_count = refresh_count + 1
            return chapters
        end,
    })
    f.sync:on_reader_ready()
    f.drain()
    eq(refresh_count, 0, "automatic path stays offline")
    eq(f.sync:status().state, "unsafe", "missing catalog degrades safely")
end)

test("offline manual catalog refresh reports offline instead of raw reason", function()
    local refresh_count = 0
    local f = fixture({}, {
        get_chapters = function() return nil end,
        refresh_catalog = function()
            refresh_count = refresh_count + 1
            return chapters
        end,
        is_online = function() return false end,
    })
    eq(f.sync:sync_now(), false, "offline sync does not start")
    eq(refresh_count, 0, "offline path does not refresh")
    eq(#f.notifications, 1, "offline failure notifies once")
    eq(f.notifications[1].code, "offline", "offline message is explicit")
end)

test("account changes terminate and invalidate an in-flight progress job", function()
    local terminated = 0
    local subprocess = {
        run = function() return 321, 654 end,
        write_all = function() end,
        is_done = function() return false end,
        terminate = function() terminated = terminated + 1 end,
        read_size = function() return 0 end,
        read_all = function() return nil end,
    }
    local f = fixture({
        bookId = "book",
        progress = 25,
        chapterUid = 22,
        chapterIdx = 2,
        chapterOffset = 150,
        updateTime = 10,
    }, { subprocess = subprocess })
    f.sync:on_reader_ready()
    f.step()
    eq(f.sync.job ~= nil, true, "progress job is active before account change")
    local generation = f.sync.generation
    f.sync:on_account_changed()
    eq(terminated, 1, "account change terminates the old progress process")
    eq(f.sync.job, nil, "account change discards the old progress job")
    eq(f.sync.generation, generation + 1, "account change invalidates callbacks")
    eq(f.sync.current_book_id, nil, "account change clears the old book")
end)

test("progress persistence updates only the current book", function()
    local f = fixture({})
    local updates = {}
    f.sync.settings = {
        update_book = function(_self, book_id, patch)
            updates[#updates + 1] = { book_id = book_id, patch = patch }
            return true
        end,
        get = function()
            error("full books store must not be loaded")
        end,
    }
    eq(f.sync:_persist("book", { progress = 42 }), true,
        "progress persistence succeeds through the single-book API")
    eq(#updates, 1, "one single-book update is issued")
    eq(updates[1].book_id, "book", "single-book update receives the book id")
    eq(updates[1].patch.progress, 42, "single-book update receives the patch")
end)

test("real chapter wins over stale footer and whole-book word distribution", function()
    local f = fixture({ progress = 50, chapterUid = 33, chapterOffset = 100 })
    f.document.getToc = function() return {
        { title = "11", xpointer = "0" },
        { title = "22", xpointer = "5000" },
        { title = "33", xpointer = "8000" },
    } end
    f.document.page = 60 -- Real chapter 22; the old whole-book calculation said 33.
    f.sync.get_footer = function() return { percent_finished = 0.9 } end
    f.sync:on_reader_ready(); f.drain()
    eq(#f.choices, 1, "actual different chapters prompt even with a stale footer")
    eq(f.choices[1].local_position.chapter_uid, 22, "real local chapter")
    eq(f.sync.verified, false, "mismatch not verified")
    f.choices[1].keep_local()
    eq(f.uploads[1].chapter_uid, 22, "explicit local upload uses actual chapter")
    f.document.page = 65
    local heartbeat = f.sync:position_for_report("book")
    eq(heartbeat.chapter_uid, 22, "heartbeat uses same capture chain")
    eq(heartbeat.chapter_offset, 150, "live offset not footer offset")
    f.sync:on_close_document()
    eq(f.uploads[#f.uploads].chapter_offset, heartbeat.chapter_offset, "close uses same location")
end)

test("pull completion and local choice recapture the live reading page", function()
    local f
    f = fixture(nil, { remote_provider = function()
        f.document.page = 50
        return { progress = 25, chapterUid = 22, chapterOffset = 150 }
    end })
    f.sync:on_reader_ready(); f.drain()
    eq(#f.choices, 1, "in-flight page turn cannot verify stale initial coordinates")
    eq(f.choices[1].local_position.chapter_uid, 33, "compare uses current chapter")
    f.document.page = 75
    f.choices[1].keep_local()
    eq(f.uploads[1].chapter_offset, 350, "choice does not upload the dialog's stale snapshot")
end)

test("unmapped page clears verification and cannot upload a stale close snapshot", function()
    local f = fixture({ progress = 25, chapterUid = 22, chapterOffset = 150 })
    f.sync:on_reader_ready(); f.drain()
    eq(f.sync.verified, true, "initial coordinates verified")
    f.document.getXPointer = function() return nil end
    f.sync:on_page_update()
    eq(f.sync.verified, false, "lost position clears the gate")
    eq(f.sync.state, "unsafe", "unavailable is explicit")
    local count = #f.notifications
    f.sync:on_page_update()
    eq(#f.notifications, count, "same unavailable reason is not spammed")
    f.sync:on_close_document()
    eq(#f.uploads, 0, "no stale fallback POST on close")
end)

test("unknown offset always asks instead of silently keeping local", function()
    local f = fixture({ progress = 25, chapterUid = 22, chapterOffset = 8000 })
    f.values.sync.ask_on_conflict = false
    f.sync:on_reader_ready(); f.drain()
    eq(#f.choices, 1, "uncertainty is not auto-resolved")
    eq(f.choices[1].position_uncertain, true, "uncertain rather than same")
    eq(f.sync.verified, false, "unknown gated")
end)

test("answered keep-local choice reports transiently and never stacks a dialog", function()
    local f = fixture({ progress = 25, chapterUid = 22, chapterOffset = 8000 })
    f.values.sync.ask_on_conflict = false
    f.sync:on_reader_ready(); f.drain()
    eq(#f.choices, 1, "uncertain position asks the reader")
    f.choices[1].keep_local()
    f.drain()
    eq(#f.uploads, 1, "keep-local uploads the reader's position")
    eq(#f.notifications, 1, "exactly one message after an answered dialog")
    eq(f.notifications[1].code, "upload_success", "acceptance is reported")
    eq(f.notifications[1].data.transient, true,
        "acceptance fades out instead of waiting for a tap")
end)

test("cloud jump is gated until the actual target chapter is captured", function()
    local f = fixture({ progress = 50, chapterUid = 33, chapterOffset = 100 })
    f.sync:on_reader_ready(); f.drain()
    f.sync.goto_xpointer = function() return true end -- API accepted but reader did not move.
    f.choices[1].use_remote()
    eq(f.sync.verified, false, "no eager verification")
    f.drain()
    eq(f.sync.verified, false, "wrong landing cannot unblock reporting")
    eq(f.sync.state, "unsafe", "failed landing is explicit")
end)

test("legacy queued positions cannot be replayed as trusted real chapters", function()
    local f = fixture({ progress = 25, chapterUid = 22, chapterOffset = 150 })
    f.sync:on_reader_ready(); f.drain()
    f.values.books.book.pending_upload_position = {
        book_id = "book", percent = 25, chapter_uid = 22, chapter_offset = 150,
    }
    f.sync:on_network_connected()
    eq(#f.uploads, 0, "unverified legacy coordinates not sent")
    eq(f.notifications[#f.notifications].data.error, "queued_chapter_unverified", "legacy queue is explicit")
    eq(f.values.books.book.pending_upload_position ~= nil, true, "old snapshot preserved, not deleted")
    local get_point = f.document.getXPointer
    f.document.getXPointer = function() return nil end
    f.sync:on_page_update()
    eq(f.sync.verified, false, "unavailable reading position gates reports")
    f.document.getXPointer = get_point
    f.sync:on_page_update(); f.drain()
    eq(f.sync.verified, true, "a now-reliable page can recheck without reopening")
end)

test("unrelated duplicate titles do not close the reading-report gate", function()
    local f = fixture({ progress = 25, chapterUid = 22, chapterOffset = 150 })
    f.document.getToc = function() return {
        { title = "11", xpointer = "0" },
        { title = "22", xpointer = "1000" },
        { title = "33", xpointer = "4000" },
        { title = "33", xpointer = "8000" },
    } end
    f.sync:on_reader_ready(); f.drain()
    eq(f.sync.verified, true, "known current chapter is verified")
    eq(#f.notifications, 0, "unrelated ambiguity produces no blocking popup")
    local position, reason, applies = f.sync:position_for_report("book")
    eq(position.chapter_uid, 22, "report receives the actual current chapter")
    eq(reason, nil, "not progress_unverified")
    eq(applies, true, "normal reporting gate applies")
    f.document.page = 50
    f.sync:on_page_update()
    eq(f.sync.verified, false, "entering the truly ambiguous range still gates reports")
    eq(f.sync.state, "unsafe", "current ambiguity remains explicit")
end)

test("single chapter uses live engine instead of footer", function()
    local f = fixture({ progress = 25, chapterUid = 22, chapterOffset = 150 })
    f.sync.get_file_context = function() return 2, chapters[2], false end
    f.sync.get_footer = function() return { percent_finished = 0.9 } end
    f.document.page = 50
    local position = assert(f.sync:capture_local())
    eq(position.chapter_uid, 22, "single chapter identity")
    eq(position.chapter_offset, 150, "live page, not footer")
end)

print(string.format(
    "progress_sync_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)

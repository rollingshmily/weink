-- Focused tests for ReadReport's progress gate and enter/report sequencing.
-- Run from the repo root with:
--   lua spec/read_report_progress_spec.lua

package.path = "./?.lua;" .. package.path

local cached_catalog
local saved_catalog
package.preload["weread.lib.content"] = function()
    return {
        load_catalog_cache = function(_client, _settings, book)
            if cached_catalog then book.chapters = cached_catalog end
            return cached_catalog
        end,
        save_catalog_cache = function(_client, _settings, _book, chapters)
            saved_catalog = chapters
            return true
        end,
    }
end

package.preload["weread.lib.protocol"] = function()
    return {
        e = function(value) return "e:" .. tostring(value) end,
        reader_url = function(book_id)
            return "https://reader/" .. tostring(book_id)
        end,
        is_success_response = function(value)
            return type(value) == "table" and value.succ == 1
        end,
    }
end

local ReadReport = require("weread.lib.read_report")

local failures, checks = 0, 0
local current_test

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
    fn()
end

local function fixture(provider)
    local records = {}
    local settings = {
        get = function(_self, key)
            if key == "read_report" then
                return {
                    enabled = true,
                    mode = "auto",
                    interval_seconds = 30,
                }
            end
            if key == "books" then
                return { book = { title = "Book" } }
            end
            return {}
        end,
        is_eink_configured = function() return true end,
    }
    local client = {
        report_read = function(_self, payload)
            records[#records + 1] = payload
            return { succ = 1 }
        end,
    }
    local report = ReadReport:new{
        settings = settings,
        client = client,
        scheduler = {
            scheduleIn = function() end,
            unschedule = function() end,
        },
        get_document = function() return { file = "/book.epub" } end,
        detect_book = function() return "book" end,
        position_provider = provider,
        is_online = function() return true end,
        subprocess = false,
        now = function() return 100 end,
    }
    return report, records
end

test("unverified position blocks reading-time reporting", function()
    local report = fixture(function()
        return nil, "progress_unverified", true
    end)
    local proceed = report:_precheck()
    eq(proceed, false, "precheck blocked")
    eq(report:status().state, "waiting_for_progress", "waiting state")
end)

test("verified live position passes the reporting gate", function()
    local live = { chapter_uid = 22, chapter_offset = 150, percent = 25 }
    local report = fixture(function()
        return live, nil, true
    end)
    local proceed, book_id, position = report:_precheck()
    eq(proceed, true, "precheck passed")
    eq(book_id, "book", "target book")
    eq(position, live, "live position forwarded")
end)

test("one reader session enters once and reports live position", function()
    local report, records = fixture()
    local book = {
        book_id = "book",
        chapter_uid = 11,
        chapter_idx = 1,
        chapter_offset = 1,
        progress = 1,
        psvts = "ps",
        pclts = "pc",
        token = "token",
    }
    local position = {
        chapter_uid = 22,
        chapter_idx = 2,
        chapter_offset = 150,
        percent = 25,
    }
    report:_send("book", book, position, 0)
    report:_send("book", book, position, 30)
    eq(#records, 2, "two native reports")
    eq(records[1].bookId, "book", "bookId is native")
    eq(tonumber(records[1].chapterUid), 22, "live chapter used")
    eq(records[1].chapterOffset, 150, "live offset used")
    eq(records[1].readingTime, 0, "progress-only report has zero time")
    eq(records[2].readingTime, 30, "time report keeps interval")
end)

test("native position fields omit device install and version metadata", function()
    local report = fixture()
    report.settings.get = function(_self, key)
        if key == "eink" then return { device_id = "device" } end
        if key == "eink_install_id" then return "install" end
        return {}
    end
    local book = { chapter_uid = 11, chapter_idx = 1, progress = 10, bookVersion = 23 }
    local packet = report:build_payload("book", 17, book, {
        chapter_uid = 22, chapter_idx = 2, chapter_offset = 150,
        chapter_fraction = 0.375, percent = 44,
    })
    eq(packet.chapterIdx, 2, "live chapter index")
    eq(packet.chapterProgress, 37, "chapter percent uses APK integer scale")
    eq(packet.currentProgress, 44, "current progress emitted independently")
    eq(packet.bookVersion, nil, "book version is not uploaded even when known")
    eq(packet.deviceId, nil, "device identity is not uploaded")
    eq(packet.appId, nil, "device-derived app identity is not uploaded")
    eq(packet.installId, nil, "install identity is not uploaded")
    eq(packet.readingTime, 17, "explicit elapsed seconds preserved")
    eq(packet.signature, nil, "no fabricated read signature")
    local no_position = report:build_payload("book", 0, book)
    eq(no_position.chapterProgress, nil, "no stale chapter percent reused")
    eq(no_position.currentProgress, nil, "no invented live position")
    for _, key in ipairs({ "bookVersion", "deviceId", "appId", "installId" }) do
        eq(no_position[key], nil, "background packet omits " .. key)
    end
end)

test("watermarks do not acknowledge read uploads or trigger duplicate POSTs", function()
    for _, reply in ipairs({ {}, { synckey = 123 }, { data = { synckey = 456 } } }) do
        local report = fixture()
        local calls = 0
        report.ensure_context = function() return { chapter_uid = 1, chapter_idx = 0 } end
        report.client.report_read = function() calls = calls + 1; return reply end
        local outcome = report:_run_pipeline("book", { allow_renewal = true, elapsed_seconds = 30 })
        eq(outcome.accepted, false, "no explicit success")
        eq(outcome.error_kind, "unconfirmed", "uncertain rather than rejected")
        eq(calls, 1, "no refresh/replay of uncertain POST")
    end
    local report = fixture()
    report.ensure_context = function() return { chapter_uid = 1 } end
    report.client.report_read = function() return { succ = 1, errcode = -1, synckey = 123 } end
    eq(report:_run_pipeline("book", { allow_renewal = false }).accepted, false,
        "contradictory error cannot count as success")
end)

test("report context restores SQLite catalog and backfills disk", function()
    local report = fixture()
    local db_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    report.library_db = {
        getChapters = function() return db_catalog end,
        putChapters = function() end,
    }
    cached_catalog = nil
    saved_catalog = nil
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    local context = report:_build_context("book", false, book)
    eq(context.chapters, db_catalog, "SQLite catalog restored")
    eq(saved_catalog, db_catalog, "catalog.json backfilled")
end)

test("report context backfills SQLite from catalog.json", function()
    local report = fixture()
    local disk_catalog = { { chapterUid = 11, chapterIdx = 1 } }
    local written_catalog
    report.library_db = {
        getChapters = function() return nil end,
        putChapters = function(_self, _book_id, chapters)
            written_catalog = chapters
        end,
    }
    cached_catalog = disk_catalog
    local book = {
        book_id = "book",
        psvts = "ps",
        chapter_uid = 11,
        read_context_updated_at = 100,
        read_session_id = report.session_id,
    }
    report:_build_context("book", false, book)
    eq(written_catalog, disk_catalog, "catalog.json backfills SQLite")
end)

test("report context persistence updates only the current book", function()
    local report = fixture()
    local updates = {}
    report.settings.update_book = function(_self, book_id, patch)
        updates[#updates + 1] = { book_id = book_id, patch = patch }
        return true
    end
    report.settings.get = function(_self, key)
        if key == "books" then
            error("full books store must not be loaded")
        end
        return {}
    end
    report:_persist_context("book", {
        title = "Updated",
        chapter_uid = 22,
    })
    eq(#updates, 1, "one single-book context update is issued")
    eq(updates[1].book_id, "book", "context update receives the book id")
    eq(updates[1].patch.title, "Updated", "context update preserves present fields")
    eq(updates[1].patch.chapter_offset, false,
        "context update clears fields absent from the child snapshot")
end)

test("suspend detaches an in-flight report without blocking termination", function()
    local report = fixture()
    local terminated = 0
    report.subprocess = {
        terminate = function() terminated = terminated + 1 end,
        is_done = function() return false end,
        read_size = function() return 0 end,
        read_all = function() return nil end,
    }
    report.task = function() end
    report.job = { pid = 42, poll = function() end }
    report:on_suspend()
    eq(terminated, 0, "suspend never waits for child termination")
    eq(report.job, nil, "stale job detached from report state")
    eq(report:status().state, "suspended", "report enters suspended state")
end)

print(string.format(
    "read_report_progress_spec: %d checks, %d failure(s)", checks, failures))
os.exit(failures == 0 and 0 or 1)

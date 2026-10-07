local AntiReplay = require("weread.lib.anti_replay")
local Content = require("weread.lib.content")
local ReportHours = require("weread.lib.report_hours")
local WeRead = require("weread.lib.protocol")

local logger = require("weread.lib.logger").scoped("ReadReport")
local PluginUtil = require("weread.lib.plugin_util")
local ok_time, time = pcall(require, "ui/time")
if not ok_time then
    time = { now = function() return 0 end }
end
local perf = PluginUtil.perf or function() end

local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
if not ok_ffiutil then
    ffiutil = nil
end

local DEFAULT_INTERVAL_SECONDS = 30
local MIN_INTERVAL_SECONDS = 10
local CONTEXT_TTL_SECONDS = 15 * 60
local RENEWAL_COOLDOWN_SECONDS = 10 * 60
local JOB_POLL_INITIAL_SECONDS = 0.25
local JOB_POLL_MAX_SECONDS = 2
local JOB_TIMEOUT_SECONDS = 180
local JOB_COLLECT_INTERVAL_SECONDS = 2

-- Context fields that the subprocess sends back for the parent to persist.
-- Mirrors the scalar reading-state fields stored by BookStore; the chapter
-- catalog itself stays in the on-disk catalog cache written by the child.
-- "report_hours_json" carries the hour-bucketed reading-time ledger between
-- ticks. It is a plain string so it round-trips through settings and stays a
-- stable context-fingerprint component.
local CONTEXT_FIELDS = {
    "title", "reader_url",
    "chapter_uid", "chapter_idx", "chapter_offset", "progress", "summary",
    "read_context_updated_at", "read_session_entered_at", "read_session_id",
    "report_hours_json",
}

local ReadReport = {}
ReadReport.__index = ReadReport

local function log(level, ...)
    if type(logger[level]) == "function" then
        logger[level](...)
    end
end

local function make_subprocess_runner()
    if not ffiutil or type(ffiutil.runInSubProcess) ~= "function" then
        return nil
    end
    return {
        -- Returns pid, parent_read_fd on success; false, error message on failure.
        run = function(child_func)
            return ffiutil.runInSubProcess(child_func, true)
        end,
        -- Blocking write from inside the child; closes the fd when done.
        write_all = function(fd, data)
            return ffiutil.writeToFD(fd, data, true)
        end,
        -- Non-blocking waitpid; also reaps the child once it has exited.
        is_done = function(pid)
            return ffiutil.isSubProcessDone(pid)
        end,
        terminate = function(pid)
            ffiutil.terminateSubProcess(pid)
        end,
        -- Non-blocking readable-size probe (0 when nothing is buffered).
        read_size = function(fd)
            return ffiutil.getNonBlockingReadSize(fd)
        end,
        -- Reads until EOF and closes the fd.
        read_all = function(fd)
            return ffiutil.readAllFromFD(fd)
        end,
    }
end

local function book_record(books, book_id)
    if type(books) ~= "table" then
        return nil
    end
    return books[tostring(book_id)] or books[book_id]
end

local ERROR_FIELDS = { "errCode", "errcode", "errorCode" }
local PAYLOAD_DIAGNOSTIC_FIELDS = {
    "readingTime", "chapterUid", "chapterIdx", "chapterOffset",
    "progress", "currentProgress", "chapterProgress",
}

local function finite_number(value)
    if type(value) ~= "number" and type(value) ~= "string" then return nil end
    local number = tonumber(value)
    if number and number == number and math.abs(number) ~= math.huge then return number end
end

-- Inspect every data/result envelope, including siblings and deeper wrappers.
-- A failure anywhere wins over success elsewhere. Unknown flags are not proof
-- of rejection: replaying their readingTime could count the same time twice.
local function classify_response(result, http_code)
    local accepted, rejected, unknown, authentication, has_synckey = false, false, false, false, false
    local fields, pending, seen = {}, { { node = result, path = "response" } }, {}
    local function add_number(path, value)
        if value ~= nil and #fields < 24 then
            fields[#fields + 1] = path:sub(1, 160) .. "=" .. tostring(value)
        end
    end
    while #pending > 0 do
        local entry = table.remove(pending)
        local node = entry.node
        if type(node) == "table" and not seen[node] then
            seen[node] = true
            if node.synckey ~= nil then has_synckey = true end
            if node.succ ~= nil then
                local succ = node.succ == true and 1 or node.succ == false and 0 or finite_number(node.succ)
                add_number(entry.path .. ".succ", succ)
                if succ == 1 then accepted = true
                elseif succ == 0 then rejected = true
                else unknown = true end
            end
            for _, key in ipairs(ERROR_FIELDS) do
                if node[key] ~= nil then
                    local code = finite_number(node[key])
                    add_number(entry.path .. "." .. key, code)
                    if code == nil then unknown = true
                    elseif code ~= 0 then
                        rejected = true
                        if code == -2012 then authentication = true end
                    end
                end
            end
            for _, key in ipairs({ "result", "data" }) do
                if type(node[key]) == "table" then
                    pending[#pending + 1] = { node = node[key], path = entry.path .. "." .. key }
                end
            end
        end
    end
    local http = finite_number(http_code)
    add_number("http", http)
    if http and (http < 200 or http >= 300) then unknown = true end
    return {
        state = rejected and "rejected" or (accepted and not unknown and "accepted" or "unconfirmed"),
        authentication = authentication,
        has_synckey = has_synckey,
        fields = table.concat(fields, ", "),
    }
end

local function diagnostic_summary(request, response)
    local parts = { "result=" .. response.state }
    for _, key in ipairs(PAYLOAD_DIAGNOSTIC_FIELDS) do
        local value = finite_number(request[key])
        if value ~= nil then parts[#parts + 1] = key .. "=" .. tostring(value) end
    end
    if response.fields ~= "" then parts[#parts + 1] = response.fields end
    return table.concat(parts, ", ")
end

function ReadReport:new(options)
    options = options or {}
    assert(options.settings, "read report settings are required")
    assert(options.client, "read report client is required")
    assert(options.scheduler, "read report scheduler is required")
    assert(type(options.get_document) == "function", "get_document callback is required")
    assert(type(options.detect_book) == "function", "detect_book callback is required")

    local object = {
        settings = options.settings,
        client = options.client,
        library_db = options.library_db,
        scheduler = options.scheduler,
        get_document = options.get_document,
        detect_book = options.detect_book,
        position_provider = options.position_provider,
        is_online = options.is_online or function() return true end,
        now = options.now or os.time,
        session_id = tostring({}) .. ":" .. tostring((options.now or os.time)()),
        subprocess = options.subprocess or make_subprocess_runner(),
        state = "stopped",
        generation = 0,
        count = 0,
        failure_count = 0,
        consecutive_failures = 0,
    }
    return setmetatable(object, self)
end

function ReadReport:_config()
    return self.settings:get("read_report")
end

function ReadReport:_interval()
    local interval = tonumber(self:_config().interval_seconds) or DEFAULT_INTERVAL_SECONDS
    return math.max(MIN_INTERVAL_SECONDS, interval)
end

function ReadReport:status()
    return {
        running = self.task ~= nil,
        state = self.state,
        count = self.count or 0,
        failure_count = self.failure_count or 0,
        consecutive_failures = self.consecutive_failures or 0,
        last_time = self.last_time,
        last_error = self.last_error,
        last_error_kind = self.last_error_kind,
        stop_reason = self.stop_reason,
        target_book_id = self.current_book_id,
        target_book_title = self.current_book_title,
        target_source = self.current_book_source,
    }
end

function ReadReport:resolve_target()
    local config = self:_config()
    local has_document = self.get_document() ~= nil
    if config.mode == "manual"
        and tostring(config.book_id or "") ~= ""
        and (has_document or config.report_on_open == false) then
        return tostring(config.book_id),
            tostring(config.book_title or "") ~= "" and config.book_title or tostring(config.book_id),
            "manual"
    end

    if not has_document then
        return nil, nil, "no_document"
    end

    local detected_id = self.detect_book()
    if detected_id then
        detected_id = tostring(detected_id)
        -- Avoid reloading every book record from disk on each tick just for
        -- the title; reuse the cached one while the target stays the same.
        if detected_id == self.current_book_id
            and tostring(self.current_book_title or "") ~= "" then
            return detected_id, self.current_book_title, "current_document"
        end
        local book = book_record(self.settings:get("books", {}), detected_id)
        return detected_id,
            type(book) == "table" and book.title or detected_id,
            "current_document"
    end
    return nil, nil, "document_not_weread"
end

function ReadReport:_set_error(err, kind, prefix)
    local message = tostring(err)
    self.last_error = message
    self.last_error_kind = kind or "error"
    self.failure_count = (self.failure_count or 0) + 1
    self.consecutive_failures = (self.consecutive_failures or 0) + 1
    self.state = "error"
    if self.logged_error ~= message then
        log("warn", prefix or "read report error:", message)
        self.logged_error = message
    end
end

function ReadReport:_record_success(outcome)
    local recovered = self.last_error ~= nil
    self.count = (self.count or 0) + 1
    self.last_time = self.now()
    self.last_error = nil
    self.last_error_kind = nil
    self.logged_error = nil
    self.last_skip = nil
    self.consecutive_failures = 0
    self.state = "active"
    if recovered or self.count == 1 or self.count % 20 == 0 then
        log("info", "read report success:",
            "count=", self.count,
            "has_synckey=", outcome.has_synckey == true,
            outcome.diagnostic or "result=accepted")
    end
end

function ReadReport:_log_skip(reason)
    if self.last_skip ~= reason then
        log("info", "read report skipped:", reason)
        self.last_skip = reason
    end
end

function ReadReport:maybe_start(reason)
    local config = self:_config()
    if not config.enabled then
        self:_log_skip("disabled")
        return false, nil, "disabled"
    end
    if self.suspended then
        self.state = "suspended"
        self:_log_skip("suspended")
        return false, nil, "suspended"
    end
    local book_id, title, source = self:resolve_target()
    if not book_id then
        self:stop(source)
        self:_log_skip(source)
        return false, nil, source
    end
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source
    if self.task then
        return true, title, source
    end
    return self:start(reason), title, source
end

function ReadReport:start(reason)
    if self.task then
        return true
    end
    local book_id, title, source = self:resolve_target()
    if not self:_config().enabled or self.suspended or not book_id then
        return false
    end

    self.generation = self.generation + 1
    local generation = self.generation
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source
    self.state = "waiting"
    self.stop_reason = nil
    self.last_skip = nil

    local task
    task = function()
        if self.generation ~= generation or self.task ~= task then
            return
        end
        self:_tick(generation, task)
    end
    self.task = task
    self.scheduler:scheduleIn(self:_interval(), task)
    log("info", "reading time report started:",
        "reason=", reason or "unknown",
        "book_id=", book_id,
        "source=", source)
    return true
end

function ReadReport:stop(reason, options)
    reason = reason or "unspecified"
    options = options or {}
    local had_task = self.task ~= nil
    self.generation = self.generation + 1
    if self.task then
        self.scheduler:unschedule(self.task)
        self.task = nil
    end
    if self.job then
        self:_abandon_job(self.job, options.terminate_job ~= false)
    end
    self.state = reason == "suspend" and "suspended"
        or "stopped"
    self.stop_reason = reason
    if had_task then
        log("info", "reading time report stopped:",
            "reason=", reason,
            "success_count=", self.count or 0,
            "failure_count=", self.failure_count or 0)
    end
end

function ReadReport:on_reader_ready()
    self.suspended = false
    return self:maybe_start("reader_ready")
end

function ReadReport:on_suspend()
    self.suspended = true
    -- Never wait for a network child while KOReader is entering suspend. The
    -- detached child is reaped after resume; its stale result is discarded.
    self:stop("suspend", { terminate_job = false })
end

function ReadReport:on_resume()
    self.suspended = false
    return self:maybe_start("resume")
end

function ReadReport:on_close_document()
    local config = self:_config()
    if config.report_on_open ~= false or config.mode == "auto" then
        self:stop("document_closed")
        self.current_book_id = nil
        self.current_book_title = nil
        self.current_book_source = nil
        return
    end
    self:maybe_start("document_closed_background")
end

-- ------------------------------------------------------------------
-- Scheduled tick: cheap parent-side checks, then hand the network
-- pipeline to a subprocess (or run it inline as a fallback).
-- ------------------------------------------------------------------

function ReadReport:_schedule_next(generation, task)
    if self.generation == generation and self.task == task then
        self.scheduler:scheduleIn(self:_interval(), task)
    end
end

function ReadReport:_tick(generation, task)
    local ok, err = pcall(function()
        local proceed, book_id, position = self:_precheck()
        if not proceed then
            self:_schedule_next(generation, task)
            return
        end
        if self.job then
            -- Previous report is still in flight; keep the cadence and let
            -- the poller reschedule once it completes.
            self:_schedule_next(generation, task)
            return
        end
        local allow_renewal = self:_renewal_allowed()
        local spawned, spawn_err = self:_start_job(
            book_id, allow_renewal, generation, task, position)
        if spawned then
            return
        end
        if not self.logged_inline_fallback then
            log("warn", "read report subprocess unavailable, reporting inline:",
                tostring(spawn_err))
            self.logged_inline_fallback = true
        end
        local outcome = self:_run_pipeline(book_id, {
            allow_renewal = allow_renewal,
            position = position,
        })
        self:_apply_outcome(outcome)
        self:_schedule_next(generation, task)
    end)
    if not ok then
        self:_set_error(err, "task", "read report task failed:")
        self:_schedule_next(generation, task)
    end
end

-- Parent-side gate before any network work. Returns true, book_id when a
-- report should be attempted. Must stay cheap: it runs on the UI loop.
function ReadReport:_precheck()
    local config = self:_config()
    if not config.enabled then
        self:stop("disabled")
        return false
    end
    if self.suspended then
        self:stop("suspend")
        return false
    end

    local book_id, title, source = self:resolve_target()
    if not book_id then
        self:stop(source)
        return false
    end
    if self.current_book_id and self.current_book_id ~= book_id then
        self:stop("document_changed")
        self:maybe_start("document_changed")
        return false
    end
    self.current_book_id = book_id
    self.current_book_title = title
    self.current_book_source = source

    if not self.settings:is_eink_configured() then
        self:_set_error("eink not configured", "authentication", "read report skipped:")
        return false
    end
    if not self.is_online() then
        self.state = "offline"
        self:_log_skip("offline")
        return false
    end
    local position
    if type(self.position_provider) == "function" then
        local provided, reason, applies = self.position_provider(book_id)
        if applies and not provided then
            self.state = "waiting_for_progress"
            self:_log_skip(reason or "progress_unverified")
            return false
        end
        position = provided
    end
    return true, book_id, position
end

function ReadReport:_renewal_allowed()
    return self.now() - (self.last_renew_attempt or 0) >= RENEWAL_COOLDOWN_SECONDS
end

function ReadReport:_auth_fingerprint()
    local eink = self.settings:get("eink", {}) or {}
    return table.concat({
        "vid=" .. tostring(eink.vid or ""),
        "access_token=" .. tostring(eink.access_token or ""),
        "refresh_token=" .. tostring(eink.refresh_token or ""),
        "device_id=" .. tostring(eink.device_id or ""),
        "skey=" .. tostring(eink.skey or ""),
    }, ";")
end

function ReadReport:_context_fingerprint(book_id)
    local book = book_record(self.settings:get("books", {}), book_id) or {}
    local parts = {}
    for _i, field in ipairs(CONTEXT_FIELDS) do
        parts[#parts + 1] = field .. "=" .. tostring(book[field])
    end
    return table.concat(parts, ";")
end

-- ------------------------------------------------------------------
-- Subprocess job management (parent side)
-- ------------------------------------------------------------------

function ReadReport:_start_job(book_id, allow_renewal, generation, task, position)
    local runner = self.subprocess
    if not runner then
        return false, "no subprocess support"
    end
    local pid, read_fd = runner.run(function(_pid, child_write_fd)
        local outcome = self:_child_report(book_id, allow_renewal, position)
        local ok, encoded = pcall(function()
            return self.client:json_encode(outcome)
        end)
        if not ok or type(encoded) ~= "string" then
            encoded = '{"accepted":false,"error":"failed to serialize report outcome",'
                .. '"error_kind":"job"}'
        end
        runner.write_all(child_write_fd, encoded)
    end)
    if not pid then
        return false, tostring(read_fd)
    end

    local job = {
        pid = pid,
        read_fd = read_fd,
        book_id = book_id,
        started_at = self.now(),
        poll_interval = JOB_POLL_INITIAL_SECONDS,
        auth_fingerprint = self:_auth_fingerprint(),
        context_fingerprint = self:_context_fingerprint(book_id),
    }
    job.poll = function()
        self:_poll_job(job, generation, task)
    end
    self.job = job
    self.scheduler:scheduleIn(job.poll_interval, job.poll)
    return true
end

function ReadReport:_poll_job(job, generation, task)
    if self.job ~= job then
        return
    end
    local runner = self.subprocess
    local done = runner.is_done(job.pid)
    local readable = job.read_fd and runner.read_size(job.read_fd)
    if done or (readable and readable > 0) then
        local payload
        if job.read_fd then
            payload = runner.read_all(job.read_fd)
            job.read_fd = nil
        end
        self.job = nil
        if not done then
            -- Output was read while the child was still exiting; reap it in
            -- the background so it does not linger as a zombie.
            self:_collect_pid(job.pid)
        end
        self:_apply_job_outcome(job, self:_decode_outcome(payload))
        self:_schedule_next(generation, task)
        return
    end
    if self.now() - job.started_at > JOB_TIMEOUT_SECONDS then
        log("warn", "read report job timed out, terminating:", "pid=", job.pid)
        self:_abandon_job(job)
        self:_set_error("report job timed out", "transport", "read report job failed:")
        self:_schedule_next(generation, task)
        return
    end
    job.poll_interval = math.min(job.poll_interval * 2, JOB_POLL_MAX_SECONDS)
    self.scheduler:scheduleIn(job.poll_interval, job.poll)
end

-- Detach a running job and keep reaping until the child is collected. Most
-- callers terminate first; suspend deliberately lets the child exit itself.
function ReadReport:_abandon_job(job, terminate_job)
    job = job or self.job
    if not job then
        return
    end
    if self.job == job then
        self.job = nil
    end
    local runner = self.subprocess
    if job.poll then
        self.scheduler:unschedule(job.poll)
    end
    if terminate_job ~= false then
        runner.terminate(job.pid)
    end
    local collect
    collect = function()
        if runner.is_done(job.pid) then
            if job.read_fd then
                runner.read_all(job.read_fd)
                job.read_fd = nil
            end
            return
        end
        if job.read_fd and (runner.read_size(job.read_fd) or 0) ~= 0 then
            -- Drain the pipe so a child blocked on write() can exit.
            runner.read_all(job.read_fd)
            job.read_fd = nil
        end
        self.scheduler:scheduleIn(JOB_COLLECT_INTERVAL_SECONDS, collect)
    end
    collect()
end

function ReadReport:_collect_pid(pid)
    local runner = self.subprocess
    local collect
    collect = function()
        if not runner.is_done(pid) then
            self.scheduler:scheduleIn(JOB_COLLECT_INTERVAL_SECONDS, collect)
        end
    end
    self.scheduler:scheduleIn(1, collect)
end

function ReadReport:_decode_outcome(payload)
    if type(payload) ~= "string" or payload == "" then
        return nil
    end
    local ok, decoded = pcall(function()
        return self.client:json_decode(payload)
    end)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

-- ------------------------------------------------------------------
-- Outcome application (parent side)
-- ------------------------------------------------------------------

function ReadReport:_apply_job_outcome(job, outcome)
    local book_id = job.book_id
    if type(outcome) == "table" then
        if type(outcome.auth) == "table" then
            if self:_auth_fingerprint() ~= job.auth_fingerprint then
                log("info", "skip renewed auth write-back: parent auth changed during job")
            else
                local ok, err = pcall(function()
                    self.settings:update_auth({
                        eink = outcome.auth.eink,
                    })
                end)
                if not ok then
                    log("warn", "persist renewed auth failed:", tostring(err))
                end
            end
        end
        if type(outcome.book) == "table" then
            if self:_context_fingerprint(book_id) ~= job.context_fingerprint then
                log("info", "skip report context write-back: parent record changed during job")
            else
                local ok, err = pcall(function()
                    self:_persist_context(book_id, outcome.book)
                end)
                if not ok then
                    log("warn", "persist report context failed:", tostring(err))
                end
            end
        end
    end
    return self:_apply_outcome(outcome)
end

function ReadReport:_apply_outcome(outcome)
    if type(outcome) ~= "table" then
        self:_set_error("report job returned no result", "job", "read report job failed:")
        return false
    end
    if outcome.renew_attempted then
        self.last_renew_attempt = self.now()
    end
    if outcome.accepted then
        self:_record_success(outcome)
        return true
    end
    local changed = self.last_error_kind ~= outcome.error_kind
    self:_set_error(outcome.error or "unknown report failure",
        outcome.error_kind or "error",
        outcome.error_prefix)
    if outcome.diagnostic and (changed or self.failure_count == 1 or self.failure_count % 20 == 0) then
        log("warn", "read report outcome:", outcome.diagnostic)
    end
    return false
end

function ReadReport:_context_snapshot(book)
    local snapshot = { book_id = book.book_id }
    for _i, field in ipairs(CONTEXT_FIELDS) do
        snapshot[field] = book[field]
    end
    return snapshot
end

function ReadReport:_persist_context(book_id, snapshot)
    if type(self.settings.update_book) == "function" then
        local patch = {}
        for _i, field in ipairs(CONTEXT_FIELDS) do
            local value = snapshot[field]
            if value == nil then
                patch[field] = false
            else
                patch[field] = value
            end
        end
        local started = time.now()
        self.settings:update_book(book_id, patch)
        perf("read_report.update_book", started, "book=", tostring(book_id))
        return
    end

    -- Compatibility fallback for older host/test settings objects.
    local books = self.settings:get("books", {})
    local book = book_record(books, book_id) or { book_id = book_id }
    local changed = false
    -- Replace semantics, not merge: a refreshed context may legitimately
    -- clear session fields (notably pclts), and the old wholesale record
    -- overwrite dropped them too. JSON strips nils from the outcome, so a
    -- missing snapshot field means "cleared".
    for _i, field in ipairs(CONTEXT_FIELDS) do
        local value = snapshot[field]
        if book[field] ~= value then
            book[field] = value
            changed = true
        end
    end
    if not changed then
        return
    end
    book.book_id = book.book_id or book_id
    books[book_id] = book
    self.settings:set("books", books)
    self.settings:flush()
end

-- ------------------------------------------------------------------
-- Report pipeline (runs in the subprocess, or inline as fallback)
-- ------------------------------------------------------------------

-- Child entry point. Neuters settings persistence inside the fork and
-- captures eink auth changes so the parent can persist them from the outcome.
function ReadReport:_child_report(book_id, allow_renewal, position, elapsed_seconds)
    self._no_persist = true
    self.settings.flush = function() end
    local auth_changed = false
    local original_update_auth = self.settings.update_auth
    self.settings.update_auth = function(settings_obj, credentials, options)
        auth_changed = true
        options = options or {}
        options.flush = false
        return original_update_auth(settings_obj, credentials, options)
    end

    local ok, outcome = pcall(function()
        return self:_run_pipeline(book_id, {
            allow_renewal = allow_renewal,
            position = position,
            elapsed_seconds = elapsed_seconds,
        })
    end)
    if not ok then
        outcome = {
            accepted = false,
            error = tostring(outcome),
            error_kind = "task",
            error_prefix = "read report task failed:",
        }
    end
    if auth_changed then
        outcome.auth = {
            eink = self.settings:get("eink", {}),
        }
    end
    return outcome
end

-- Full report attempt: context, send, refresh-retry, renewal, final retry.
-- Pure with respect to the parent state machine: everything the caller needs
-- is described by the returned outcome table.
function ReadReport:_run_pipeline(book_id, opts)
    opts = opts or {}
    local outcome = { accepted = false, renew_attempted = false, response_state = "unconfirmed" }

    local function attempt(book)
        local request = {}
        local ok, result, http_code = pcall(function()
            return self:_send(book_id, book, opts.position, opts.elapsed_seconds, request)
        end)
        outcome.book = self:_context_snapshot(book)
        -- Thrown errors can contain response bodies or credentials. Never log
        -- them here, and never interpret them as proof that the POST failed.
        local response = classify_response(ok and result or nil, http_code)
        outcome.response_state = response.state
        outcome.accepted = response.state == "accepted"
        outcome.has_synckey = response.has_synckey
        outcome.diagnostic = diagnostic_summary(request, response)
        return response
    end

    local function uncertain()
        outcome.error = "read report acknowledgment missing or request outcome uncertain; not replaying POST"
        outcome.error_kind = "unconfirmed"
        return outcome
    end

    -- The APK drops the per-book ledger the moment the server acknowledges
    -- (ReportService.m42updateProgress$lambda47 -> clearReadingInfo). Doing it
    -- before the parent persists the snapshot makes the next window start from
    -- zero instead of re-sending time the server already credited.
    local function accepted()
        if type(outcome.book) == "table" then
            outcome.book.report_hours_json = nil
        end
        return outcome
    end

    local context_ok, book = pcall(function()
        return self:ensure_context(book_id, false)
    end)
    if not context_ok then
        outcome.error = "read report context initialization failed"
        outcome.error_kind = "context"
        outcome.error_prefix = "read report context initialization failed:"
        return outcome
    end
    local response = attempt(book)
    if outcome.accepted then return accepted() end
    if response.state ~= "rejected" then return uncertain() end

    local failure = response.fields
    local refresh_ok, refreshed = pcall(function()
        return self:ensure_context(book_id, true)
    end)
    if refresh_ok then
        response = attempt(refreshed)
        if outcome.accepted then return accepted() end
        if response.state ~= "rejected" then return uncertain() end
        failure = "initial=" .. failure .. "; refreshed=" .. response.fields
    else
        failure = failure .. "; context_refresh=failed"
    end

    -- Context recovery is bounded to one retry. Only the known login-expiry
    -- error can enter auth renewal; arbitrary server rejections are not auth
    -- failures. The client's own HTTP-401 renewal remains unchanged.
    if not opts.allow_renewal or not response.authentication then
        outcome.error = failure
        outcome.error_kind = "server"
        outcome.error_prefix = "read report server rejected:"
        return outcome
    end
    outcome.renew_attempted = true
    local renew_ok, renew_result = pcall(function()
        return self.client:eink_refresh_session()
    end)
    if not renew_ok or renew_result ~= true then
        outcome.error = failure .. "; renewal=failed"
        outcome.error_kind = "authentication"
        outcome.error_prefix = "read report eink renewal failed:"
        return outcome
    end

    local final_context_ok, final_book = pcall(function()
        return self:ensure_context(book_id, true)
    end)
    if not final_context_ok then
        outcome.error = failure .. "; final_context=failed"
        outcome.error_kind = "context"
        outcome.error_prefix = "read report final context refresh failed:"
        return outcome
    end
    response = attempt(final_book)
    if outcome.accepted then return accepted() end
    if response.state ~= "rejected" then return uncertain() end
    outcome.error = failure .. "; final=" .. response.fields
    outcome.error_kind = "server"
    outcome.error_prefix = "read report final retry failed:"
    return outcome
end

-- Inline (blocking) report used when subprocess support is unavailable.
function ReadReport:report_once()
    local proceed, book_id, position = self:_precheck()
    if not proceed then
        return false
    end
    local outcome = self:_run_pipeline(book_id, {
        allow_renewal = self:_renewal_allowed(),
        position = position,
    })
    return self:_apply_outcome(outcome)
end

-- ------------------------------------------------------------------
-- Report context
-- ------------------------------------------------------------------

function ReadReport:_merge_remote_progress(book_id, book)
    local ok, result = pcall(function()
        return self.client:get_progress(book_id)
    end)
    if not ok or type(result) ~= "table" then
        return
    end
    local remote = type(result.book) == "table" and result.book or result
    book.progress = tonumber(remote.progress) or tonumber(book.progress) or 0
    book.chapter_uid = remote.chapterUid or remote.chapterId or remote.chapter_uid or book.chapter_uid
    book.chapter_idx = tonumber(remote.chapterIdx or remote.chapterIndex or remote.chapter_idx)
        or tonumber(book.chapter_idx)
    book.chapter_offset = tonumber(remote.chapterOffset or remote.chapterPos or remote.offset)
        or tonumber(book.chapter_offset) or 0
    book.summary = remote.summary or book.summary or ""
end

-- Build (and refresh when stale) the reader context on the given book
-- record. Performs network I/O; never persists settings.
function ReadReport:_build_context(book_id, force, book)
    book.book_id = book.book_id or book.bookId or book_id
    book.reader_url = WeRead.reader_url(book_id)

    -- BookStore never persists the chapter list, so a freshly loaded record
    -- has no chapters. Restore them from the on-disk catalog cache first;
    -- otherwise the TTL check below can never pass and every report would
    -- refetch the whole reader page.
    if type(book.chapters) ~= "table" or #book.chapters == 0 then
        local chapters = Content.load_catalog_cache(
            self.client, self.settings, book)
        if type(chapters) == "table" and #chapters > 0 then
            if self.library_db then
                self.library_db:putChapters(book_id, chapters)
            end
        else
            chapters = self.library_db
                and self.library_db:getChapters(book_id) or nil
            if type(chapters) == "table" and #chapters > 0 then
                book.chapters = chapters
                local cache_ok, cache_err = Content.save_catalog_cache(
                    self.client, self.settings, book, chapters)
                if not cache_ok then
                    log("warn", "save chapter catalog cache failed:",
                        tostring(cache_err))
                end
            end
        end
    end

    local age = self.now() - (tonumber(book.read_context_updated_at) or 0)
    local ready = book.chapter_uid ~= nil
        and type(book.chapters) == "table" and #book.chapters > 0
        and book.read_session_id == self.session_id
    if not force and ready and age < CONTEXT_TTL_SECONDS then
        return book
    end

    book.read_session_entered_at = nil
    book.read_session_id = self.session_id
    if force or type(book.chapters) ~= "table" or #book.chapters == 0 then
        local chapters = Content.fetch_catalog(self.client, book)
        local cache_ok, cache_err = Content.save_catalog_cache(
            self.client, self.settings, book, chapters)
        if not cache_ok then
            log("warn", "save chapter catalog cache failed:", tostring(cache_err))
        end
        if self.library_db then
            self.library_db:putChapters(book_id, chapters)
        end
    end
    self:_merge_remote_progress(book_id, book)

    local selected
    for _i, chapter in ipairs(book.chapters or {}) do
        if tostring(chapter.chapterUid or "") == tostring(book.chapter_uid or "") then
            selected = chapter
            break
        end
    end
    selected = selected or Content.first_readable_chapter(book.chapters)
    if not selected then
        error("no readable chapter found for report context")
    end
    book.chapter_uid = selected.chapterUid or book.chapter_uid
    book.chapter_idx = tonumber(selected.chapterIdx) or tonumber(book.chapter_idx) or 0
    book.read_context_updated_at = self.now()
    if book.chapter_uid == nil then
        error("reader context is incomplete")
    end
    return book
end

function ReadReport:ensure_context(book_id, force)
    book_id = tostring(book_id or "")
    if book_id == "" then
        error("missing book id")
    end
    if not self.settings:is_eink_configured() then
        error("eink not configured")
    end

    local books = self.settings:get("books", {})
    local book = book_record(books, book_id) or {
        book_id = book_id,
        title = self.current_book_title or book_id,
    }
    self:_build_context(book_id, force, book)
    if self._no_persist then
        -- Forked child: the parent persists the context from the outcome.
        return book
    end
    books[book_id] = book
    self.settings:set("books", books)
    self.settings:flush()
    return book
end

local function apply_position(book, position)
    if type(position) ~= "table" then return book end
    book.chapter_uid = position.chapter_uid or book.chapter_uid
    book.chapter_idx = tonumber(position.chapter_idx) or tonumber(book.chapter_idx) or 0
    book.chapter_offset = tonumber(position.chapter_offset)
        or tonumber(book.chapter_offset) or 0
    book.progress = tonumber(position.percent or position.progress)
        or tonumber(book.progress) or 0
    book.summary = position.summary or book.summary or ""
    return book
end

function ReadReport:build_payload(book_id, elapsed_seconds, book, position)
    book = book or self:ensure_context(book_id, false)
    apply_position(book, position)

    -- APK contract: reading time accumulates per book and is reported as an
    -- hour-bucketed ledger (ReportServiceKt.saveHoursTime ->
    -- generateBookReadPostBody). The server's daily bucket is keyed by the same
    -- local hour start, so a bare per-tick delta has nothing to credit.
    local delta = math.max(0, math.floor(tonumber(elapsed_seconds) or 0))
    local ledger = ReportHours.accumulate(
        ReportHours.parse(book.report_hours_json), delta, {
            now = self.now(),
            offset_seconds = ReportHours.DEFAULT_OFFSET_SECONDS,
        })
    book.report_hours_json = ReportHours.serialize(ledger)
    -- Cumulative since the last acknowledged report, not this tick's delta.
    local reading_time = ReportHours.totals(ledger)

    -- Identity: the APK sends DeviceId.get(context) for both deviceId and
    -- appId, plus the install id; appId/installId/summary are @NotNull on
    -- BaseReportService.ReadBookInShelf.
    local eink = self.settings:get("eink", {}) or {}
    local vid = tostring(eink.vid or "")
    local device_id = ""
    local install_id = ""
    if type(self.settings.get_eink_device_id) == "function" then
        device_id = tostring(self.settings:get_eink_device_id() or "")
    end
    if type(self.settings.get_eink_install_id) == "function" then
        install_id = tostring(self.settings:get_eink_install_id() or "")
    end
    local timezone = ReportHours.timezone_string(ReportHours.DEFAULT_OFFSET_SECONDS)
    local summary = tostring(book.summary or "")
    local risk = 0

    local payload = {
        bookId = tostring(book_id),
        chapterUid = tonumber(book.chapter_uid) or book.chapter_uid,
        chapterIdx = tonumber(book.chapter_idx) or 0,
        reviewId = "",
        chapterOffset = math.max(0, math.floor(tonumber(book.chapter_offset) or 0)),
        chapterProgress = 0,
        readingTime = reading_time,
        ttsTime = 0,
        lectureTime = 0,
        lectureTextTime = 0,
        novalTime = 0,
        appId = device_id,
        installId = install_id,
        bookVersion = tonumber(book.book_version) or tonumber(book.bookVersion) or 0,
        summary = summary,
        isLecture = 0,
        voiceType = -1,
        timestamp = self.now(),
        random = math.random(0, 999),
        autoTime = 0,
        isStoryFeed = 0,
        wordCount = 0,
        hours = ledger,
        deviceId = device_id,
        risk = risk,
        recordCreateTimeZone = timezone,
        progress = tonumber(book.progress) or 0,
    }
    -- APK ReadingProgressReporter forwards the current position separately
    -- from progress. Use the live position, never a cached chapter's fraction.
    if type(position) == "table" then
        local current = tonumber(position.percent)
        if current then payload.currentProgress = math.max(0, math.min(100, current)) end
        local fraction = tonumber(position.chapter_fraction)
        if fraction then
            payload.chapterProgress = math.floor(math.max(0, math.min(1, fraction)) * 100)
        end
    end
    -- Encrypt.encryptAntiReplaySignature([guest_token, random, timestamp,
    -- generatePayLoad(postBody)]) -> native GenSignature.
    payload.signature = AntiReplay.report_signature(
        AntiReplay.GUEST_TOKEN, payload.random, payload.timestamp,
        AntiReplay.payload_string({
            vid = vid,
            deviceId = device_id,
            appId = device_id,
            bookId = tostring(book_id),
            risk = risk,
            recordCreateTimeZone = timezone,
            readingTime = reading_time,
            ttsTime = 0,
            hours = ledger,
        }))
    return payload
end

function ReadReport:_send(book_id, book, position, elapsed_seconds, diagnostic)
    apply_position(book, position)
    if book.read_session_id ~= self.session_id then
        book.read_session_id = self.session_id
        book.read_session_entered_at = nil
    end
    if not book.read_session_entered_at then
        book.read_session_entered_at = self.now()
        book.read_session_id = self.session_id
    end
    local payload = self:build_payload(
        book_id,
        elapsed_seconds == nil and self:_interval() or elapsed_seconds,
        book,
        position
    )
    -- Carry only numeric request fields back to the parent for its existing
    -- first/every-20th outcome log. Capture before I/O, including on exceptions.
    if diagnostic then
        for _, key in ipairs(PAYLOAD_DIAGNOSTIC_FIELDS) do
            diagnostic[key] = finite_number(payload[key])
        end
    end
    -- Explicit progress uploads retain their separate key-action payload log.
    -- Fraction is the upload snapshot's
    -- precise fraction, not an extra field sent to /book/read.
    if elapsed_seconds == 0 and type(position) == "table" then
        log("info", "upload payload:",
            "uid=", tostring(tonumber(payload.chapterUid)),
            "offset=", tostring(tonumber(payload.chapterOffset)),
            "fraction=", tostring(tonumber(position.fraction)),
            "percent=", tostring(tonumber(payload.progress)),
            "current_progress=", tostring(tonumber(payload.currentProgress)),
            "chapter_progress=", tostring(tonumber(payload.chapterProgress)))
    end
    -- APK switches to the batch endpoint once the ledger spans more than one
    -- hour bucket (ReportService.m39updateProgress$lambda45).
    if ReportHours.needs_batch(payload.hours) then
        return self.client:report_read_batch(payload)
    end
    return self.client:report_read(payload)
end

function ReadReport:upload_position(book_id, position, elapsed_seconds)
    if self.job then
        return false, { error = "read_report_busy", error_kind = "busy" }
    end
    local outcome = self:_run_pipeline(tostring(book_id), {
        allow_renewal = self:_renewal_allowed(),
        position = position,
        elapsed_seconds = elapsed_seconds or 0,
    })
    if outcome.renew_attempted then
        self.last_renew_attempt = self.now()
    end
    if type(outcome.book) == "table" then
        local ok, err = pcall(function()
            self:_persist_context(tostring(book_id), outcome.book)
        end)
        if not ok then
            log("warn", "persist progress upload context failed:", tostring(err))
        end
    end
    return outcome.accepted == true, outcome
end

-- Build a progress-only upload inside a forked child. Persistence is disabled
-- by _child_report; the parent applies the returned auth/context explicitly.
function ReadReport:build_position_upload_outcome(book_id, position, elapsed_seconds)
    return self:_child_report(
        tostring(book_id),
        self:_renewal_allowed(),
        position,
        elapsed_seconds or 0
    )
end

function ReadReport:apply_position_upload_outcome(book_id, outcome)
    book_id = tostring(book_id)
    if type(outcome) ~= "table" then
        return false
    end
    if outcome.renew_attempted then
        self.last_renew_attempt = self.now()
    end
    if type(outcome.auth) == "table" then
        local ok, err = pcall(function()
            self.settings:update_auth({
                eink = outcome.auth.eink,
            })
        end)
        if not ok then
            log("warn", "persist progress upload auth failed:", tostring(err))
        end
    end
    if type(outcome.book) == "table" then
        local ok, err = pcall(function()
            self:_persist_context(book_id, outcome.book)
        end)
        if not ok then
            log("warn", "persist progress upload context failed:", tostring(err))
        end
    end
    return outcome.accepted == true
end

return ReadReport

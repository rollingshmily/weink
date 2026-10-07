local ltn12 = require("ltn12")
local logger = require("weread.lib.logger")
local socketutil = require("socketutil")
local http = require("socket.http")
local WeRead = require("weread.lib.protocol")
local Eink = require("weread.lib.eink")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local DEFAULT_TIMEOUT_SECONDS = 15
local Client = {}
Client.__index = Client

local function header_value(headers, name)
    if type(headers) ~= "table" or type(name) ~= "string" then return nil end
    if headers[name] ~= nil then return headers[name] end
    local target = name:lower()
    if headers[target] ~= nil then return headers[target] end
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == target then return value end
    end
    return nil
end

local function http_error(client, code, text, headers)
    text = text or ""
    local content_type = tostring(header_value(headers, "content-type") or "unknown")
    local parts = {
        "HTTP " .. tostring(code),
        "content_type=" .. content_type,
        "body_bytes=" .. tostring(#text),
    }
    local looks_like_json = content_type:lower():find("json", 1, true)
        or text:match("^%s*{") ~= nil
        or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(function()
            return client:json_decode(text)
        end)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            local err_message = data.errMsg or data.errmsg or data.message or data.msg
            if err_code ~= nil then
                table.insert(parts, "error_code=" .. tostring(err_code))
            end
            if err_message ~= nil then
                local message = tostring(err_message):gsub("[%c]+", " "):sub(1, 200)
                table.insert(parts, "error_message=" .. message)
            end
        end
    end
    return table.concat(parts, ", ")
end

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function table_summary(value)
    if type(value) ~= "table" then
        return type(value)
    end
    local count = 0
    for _key in pairs(value) do
        count = count + 1
    end
    return "table(" .. tostring(count) .. ")"
end

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function log_response(label, context, text)
    context = context or {}
    text = text or ""
    logger.err(
        label,
        "method=", tostring(context.method or "unknown"),
        "url=", tostring(context.url or "unknown"),
        "api=", tostring(context.api_name or "unknown"),
        "status=", tostring(context.code or "unknown"),
        "content_type=", tostring(header_value(context.headers, "content-type") or "unknown"),
        "body_bytes=", tostring(#text),
        "response_body=", text
    )
end

local function merge_req_opts(default_opts, user_opts)
    default_opts = default_opts or {}
    if not user_opts then
        return deepcopy(default_opts)
    end
    local result = deepcopy(default_opts)
    for k, v in pairs(user_opts) do
        if k == "headers" and type(v) == "table" then
            result.headers = result.headers or {}
            for hk, hv in pairs(v) do
                local target = hk:lower()
                for existing_k, _ in pairs(result.headers) do
                    if type(existing_k) == "string" and existing_k:lower() == target then
                        result.headers[existing_k] = nil
                    end
                end
                result.headers[hk] = deepcopy(hv)
            end
        else
            result[k] = deepcopy(v)
        end
    end
    return result
end

local function absolute_url(base_url, location)
    if type(location) ~= "string" or location == "" then
        return nil
    end
    if location:match("^https?://") then
        return location
    end
    local scheme, host = tostring(base_url or ""):match("^(https?)://([^/]+)")
    if not scheme then
        return location
    end
    if location:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. location
    end
    local prefix = base_url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return prefix .. location
end

local function url_origin(url)
    local scheme, authority = tostring(url or ""):match("^(https?)://([^/]+)")
    if not scheme then
        return nil
    end
    return scheme:lower() .. "://" .. authority:lower()
end

local function clear_cross_origin_headers(headers)
    for key in pairs(headers or {}) do
        local name = tostring(key):lower()
        if name == "authorization" or name == "cookie" or name == "origin" then
            headers[key] = nil
        end
    end
end

function Client:new(settings)
    return setmetatable({
        settings = settings,
    }, self)
end

function Client:json_encode(data)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(data)
    end
    return json:encode(data)
end

function Client:json_decode(text)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(text)
    end
    return json:decode(text)
end

function Client:decode_http_json(text, context)
    local ok, data = pcall(self.json_decode, self, text)
    if not ok then
        log_response("HTTP JSON decode failed:", context, text)
        error(data, 0)
    end

    if type(data) == "table" then
        local err_code = data.errCode or data.errcode
        local failed_succ = data.succ ~= nil
            and data.succ ~= true
            and tonumber(data.succ) ~= 1
        if (err_code ~= nil and tonumber(err_code) ~= 0) or failed_succ then
            log_response("API response reported an error:", context, text)
        end
    end
    return data
end

function Client:request(opts)
    opts = opts or {}
    local body = opts.body
    local response
    local headers = {
        ["User-Agent"] = WeRead.USER_AGENT,
        ["Accept"] = "application/json, text/plain, */*"
    }

    if body then
        headers["Content-Length"] = tostring(#body)
    end
    local block_timeout = DEFAULT_TIMEOUT_SECONDS
    local total_timeout = -1
    if type(opts.timeout) == "table" and opts.timeout[1] then
        block_timeout = opts.timeout[1]
        total_timeout = opts.timeout[2] or block_timeout
    elseif type(opts.timeout) == "number" then
        block_timeout = opts.timeout
    end
    socketutil:set_timeout(block_timeout, total_timeout)

    local sink_to_use = opts.sink
    if not sink_to_use then
        response = {}
        sink_to_use = socketutil.table_sink(response)
    end

    local req_opts = merge_req_opts({
        method = body and "POST" or "GET",
        source = body and ltn12.source.string(body) or nil,
        sink = sink_to_use,
        headers = headers,
    }, opts)
    -- Redirects are handled explicitly by request_follow so credentials can be
    -- rebuilt for every destination instead of being copied across origins.
    req_opts.redirect = false
    local diagnostic_api = req_opts.diagnostic_api
    req_opts.diagnostic_api = nil
    local log_http_errors = req_opts.log_http_errors
    req_opts.log_http_errors = nil
    req_opts.skip_cookie = nil
    req_opts.persist_response_cookies = nil

    local results = { pcall(http.request, req_opts) }
    socketutil:reset_timeout()
    if not results[1] then
        logger.err(
            "HTTP transport failed:",
            "method=", tostring(req_opts.method),
            "url=", tostring(req_opts.url),
            "api=", tostring(diagnostic_api or "unknown"),
            "error=", tostring(results[2])
        )
        error(results[2])
    end
    local _, raw_code, resp_headers, status = results[2], results[3], results[4], results[5]
    if status == nil and type(raw_code) == "string" then
        status = raw_code
    end

    if not opts.sink then response = table.concat(response) end

    local code = tonumber(raw_code)
    if code and code >= 400 and log_http_errors ~= false then
        log_response("HTTP response failed:", {
            method = req_opts.method,
            url = req_opts.url,
            api_name = diagnostic_api,
            code = code,
            headers = resp_headers,
        }, type(response) == "string" and response or "")
    elseif not code then
        log_response("HTTP response unavailable:", {
            method = req_opts.method,
            url = req_opts.url,
            api_name = diagnostic_api,
            code = status or raw_code,
            headers = resp_headers,
        }, type(response) == "string" and response or "")
    end

    return response, code, resp_headers or {}, status
end

function Client:request_follow(opts, max_redirects)
    local request_opts = deepcopy(opts or {})
    local on_redirect = request_opts.on_redirect
    request_opts.on_redirect = nil
    max_redirects = max_redirects or request_opts.maxredirects or 5
    request_opts.maxredirects = nil
    local url = request_opts.url

    for _redirect_index = 0, max_redirects do
        request_opts.url = url
        local text, code, headers, status = self:request(request_opts)
        local is_redirect = code == 301 or code == 302 or code == 303
            or code == 307 or code == 308
        if not is_redirect then
            return text, code, headers, status, url
        end

        local next_url = absolute_url(url, header_value(headers, "location"))
        if not next_url then
            return text, code, headers, status, url
        end
        if on_redirect then
            on_redirect(url, next_url, code)
        end
        if url_origin(url) ~= url_origin(next_url) then
            clear_cross_origin_headers(request_opts.headers)
        end
        if code == 303 or ((code == 301 or code == 302)
            and request_opts.method ~= "GET" and request_opts.method ~= "HEAD") then
            request_opts.method = "GET"
            request_opts.body = nil
            request_opts.source = nil
            if request_opts.headers then
                for key in pairs(request_opts.headers) do
                    if tostring(key):lower() == "content-length" then
                        request_opts.headers[key] = nil
                    end
                end
            end
        end
        url = next_url
    end
    error("Too many redirects")
end

-- Download a response directly to disk. The sink deliberately stays open when
-- LuaSocket signals end-of-response because request_follow may need to reuse it
-- after a redirect. On every redirect the partial response body is discarded.
function Client:download_to_file(url, path, opts)
    opts = opts or {}
    local part_path = path .. ".part"
    pcall(os.remove, part_path)
    local handle, open_err = io.open(part_path, "wb")
    if not handle then error(open_err or "could not create download file") end

    local bytes = 0
    local max_bytes = tonumber(opts.max_bytes)
    local function reopen()
        if handle then handle:close() end
        handle, open_err = io.open(part_path, "wb")
        if not handle then error(open_err or "could not reset download file") end
        bytes = 0
    end
    local function sink(chunk)
        if not chunk then return 1 end
        if max_bytes and bytes + #chunk > max_bytes then
            return nil, "download exceeds size limit"
        end
        local ok, err = handle:write(chunk)
        if not ok then return nil, err end
        bytes = bytes + #chunk
        return 1
    end

    local request_opts = merge_req_opts(opts, {
        url = url,
        method = "GET",
        maxredirects = 5,
        sink = sink,
        on_redirect = function()
            reopen()
        end,
        headers = {
            ["Accept"] = header_value(opts.headers, "Accept") or opts.accept or "*/*",
            ["Referer"] = header_value(opts.headers, "Referer") or opts.referer or "https://weread.qq.com/",
        },
    })
    request_opts.max_bytes = nil
    request_opts.accept = nil
    request_opts.referer = nil

    local ok, text, code, resp_headers = pcall(function()
        return self:request_follow(request_opts)
    end)
    if handle then handle:close() end
    handle = nil
    if not ok then
        pcall(os.remove, part_path)
        error(text, 0)
    end
    if not code or code < 200 or code >= 300 then
        pcall(os.remove, part_path)
        error(http_error(self, code, text, resp_headers))
    end
    if bytes == 0 then
        pcall(os.remove, part_path)
        error("download returned an empty body")
    end
    pcall(os.remove, path)
    local renamed, rename_err = os.rename(part_path, path)
    if not renamed then
        pcall(os.remove, part_path)
        error(rename_err or "could not commit downloaded file")
    end
    return path, bytes, resp_headers
end

function Client:get_public_text(url, opts)
    opts = opts or {}
    local req_opts = merge_req_opts(opts, {
        maxredirects = 5,
        headers = {
            ["Accept"] = header_value(opts.headers, "Accept") or opts.accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = header_value(opts.headers, "Referer") or opts.referer or "https://mp.weixin.qq.com/",
        }
    })
    local text, code, resp_headers, _status, final_url = self:request_follow(
        merge_req_opts(req_opts, { url = url, method = "GET" })
    )
    if not code or code < 200 or code >= 300 then
        error(http_error(self, code, text, resp_headers))
    end
    return text, {
        code = code,
        content_type = header_value(resp_headers, "content-type"),
        length = #(text or ""),
        url = final_url or url,
    }
end

function Client:get_binary(url, opts)
    opts = opts or {}
    local req_opts = merge_req_opts(opts, {
        maxredirects = 5,
        headers = {
            ["Accept"] = header_value(opts.headers, "Accept") or opts.accept or "*/*",
            ["Referer"] = header_value(opts.headers, "Referer") or opts.referer or "https://weread.qq.com/",
        }
    })
    local text, code, resp_headers = self:request_follow(
        merge_req_opts(req_opts, { url = url, method = "GET" })
    )
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:get_shelf()
    logger.info("shelf sync request:", "api=/shelf/sync", "auth=eink")
    local ok, result, code = pcall(self.eink_json, self, "/shelf/sync", {})
    if not ok then
        logger.err("shelf sync failed:", "api=/shelf/sync", "error=", log_error(result))
        error(result, 0)
    end

    logger.info(
        "shelf sync completed:",
        "api=/shelf/sync",
        "http_status=", tostring(code or "unknown"),
        "response=", table_summary(result),
        "books=", table_summary(type(result) == "table" and result.books or nil),
        "archive=", table_summary(type(result) == "table" and result.archive or nil),
        "albums=", table_summary(type(result) == "table" and result.albums or nil),
        "mp=", table_summary(type(result) == "table" and result.mp or nil)
    )
    return result, code
end

function Client:get_book_info(book_id)
    return self:eink_json("/book/info", { bookId = tostring(book_id) })
end

function Client:get_book_reviews(book_id, review_list_type, count, review_type, synckey)
    local params = {
        bookId = tostring(book_id),
        listType = review_list_type or 3,
        count = tonumber(count) or 20,
    }
    if review_type ~= nil then
        params.type = review_type
    end
    if synckey ~= nil then params.synckey = synckey end
    return self:eink_json("/review/list", params)
end

function Client:get_progress(book_id)
    return self:eink_json("/book/getProgress", { bookId = tostring(book_id) })
end

function Client:search_store(keyword, count)
    return self:eink_json("/store/search", {
        keyword = tostring(keyword or ""),
        count = tonumber(count) or 10,
    })
end

-- Reading statistics detail.
-- mode: "weekly" | "monthly" | "annually" | "overall"
-- base_time: optional Unix timestamp; server normalizes it to the period start
--            (Monday / 1st of month / Jan 1st). Pass 0/nil for the current period.
function Client:get_read_stats(mode, base_time)
    local params = { mode = mode or "monthly" }
    if base_time and tonumber(base_time) and tonumber(base_time) > 0 then
        params.baseTime = tonumber(base_time)
    end
    return self:eink_json("/readdata/detail", params)
end

function Client:report_read(payload, _referer)
    return self:eink_post_json("/book/read", payload)
end

-- ReportService.READ_TROUBLE: fetched once from GET /config and reused for the
-- anti-replay signature (batch / markFinishReading), not for /book/read.
function Client:encrypt_param_token()
    if self._encrypt_param_token then
        return self._encrypt_param_token
    end
    local token = ""
    local ok, result = pcall(function()
        return self:eink_json("/config", { token = 1 })
    end)
    if ok and type(result) == "table" then
        token = tostring(result.token or "")
    end
    self._encrypt_param_token = token
    return token
end

-- APK path when the hour ledger spans more than one bucket
-- (ReportService.m39updateProgress$lambda45 -> batchUploadProgress). The
-- per-book body keeps its own guest-token signature; the top-level signature is
-- the plain anti-replay one derived from the /config token.
function Client:report_read_batch(payload)
    local AntiReplay = require("weread.lib.anti_replay")
    local timestamp = os.time()
    local random = math.random(0, 999)
    return self:eink_post_json("/book/batchUploadProgress", {
        books = { payload },
        timestamp = timestamp,
        random = random,
        signature = AntiReplay.anti_replay_signature(
            self:encrypt_param_token(), timestamp, random),
        recordCreateTimeZone = payload.recordCreateTimeZone,
    })
end

local function eink_payload_error(data)
    if type(data) ~= "table" then return nil end
    local err = data.errCode or data.errcode
    if err ~= nil and tostring(err) ~= "0" then return err end
    return nil
end

local function merge_chapter_underlines(rows, seen, items, chapter_uid)
    local data = Eink.underlines_for_chapter(items, chapter_uid)
    for _, row in ipairs(data.underlines or {}) do
        local key = tostring(row.range or "")
        if key ~= "" and not seen[key] then
            seen[key] = true
            rows[#rows + 1] = row
        end
    end
end

local function merge_own_and_popular(popular, own_items, chapter_uid)
    local rows, seen = {}, {}
    merge_chapter_underlines(rows, seen, popular, chapter_uid)
    merge_chapter_underlines(rows, seen, own_items, chapter_uid)
    return rows
end

function Client:get_chapter_underlines(book_id, chapter_uid)
    if not book_id or tostring(book_id) == "" then
        return false, nil, "empty book_id"
    end
    if not chapter_uid then
        return false, nil, "empty chapter_uid"
    end
    if not self:can_eink_download() then
        return false, nil, "eink credentials missing"
    end

    local own_items
    local ok_own, own = pcall(function()
        return self:eink_bookmarklist(book_id)
    end)
    if ok_own and type(own) == "table" and not eink_payload_error(own) then
        own_items = own.updated
    elseif not self:can_eink_download() then
        return false, nil, tostring(not ok_own and own or eink_payload_error(own) or "eink bookmarklist failed")
    end

    local heat = {}
    if self:can_eink_download() then
        local ok_heat, payload = pcall(function()
            return self:eink_chapter_underlines(book_id, chapter_uid)
        end)
        if ok_heat and type(payload) == "table" and not eink_payload_error(payload) then
            heat = Eink.collect_bookmark_items(payload, chapter_uid)
        else
            logger.warn("eink /book/underlines failed:",
                tostring(not ok_heat and payload
                    or eink_payload_error(payload) or "invalid"))
        end
    end
    local rows = merge_own_and_popular(heat, own_items, chapter_uid)
    logger.info("chapter underlines via eink",
        "book=", tostring(book_id), "chapter=", tostring(chapter_uid),
        "count=", tostring(#rows), "source=underlines")
    return true, { chapterUid = chapter_uid, underlines = rows }
end

function Client:build_chapter_review_batches(ranges)
    local BATCH_SIZE = 30
    local batches = {}
    for batch_start = 1, #(ranges or {}), BATCH_SIZE do
        local batch = {}
        for index = batch_start, math.min(batch_start + BATCH_SIZE - 1, #ranges) do
            batch[#batch + 1] = {
                range = ranges[index],
                maxIdx = 0,
                count = 30,
                synckey = 0,
            }
        end
        batches[#batches + 1] = batch
    end
    return batches
end

function Client:get_chapter_reviews_batch(book_id, chapter_uid, batch)
    if not book_id or tostring(book_id) == "" then
        return false, nil, "empty book_id"
    end
    if not chapter_uid then
        return false, nil, "empty chapter_uid"
    end
    if type(batch) ~= "table" or #batch == 0 then
        return true, { reviews = {} }
    end

    if not self:can_eink_download() then
        return false, nil, "eink credentials missing"
    end
    local ok, result = pcall(function()
        return self:eink_post_json("/book/readreviews", {
            bookId = tostring(book_id),
            chapterUid = chapter_uid,
            reviews = batch,
        })
    end)
    if not ok then
        return false, nil, tostring(result)
    end
    if type(result) ~= "table" or type(result.reviews) ~= "table"
        or eink_payload_error(result) then
        return false, nil, tostring(eink_payload_error(result) or "readreviews: invalid data")
    end
    logger.info("chapter thoughts via eink",
        "book=", tostring(book_id), "chapter=", tostring(chapter_uid),
        "reviews=", tostring(#result.reviews))
    return true, result
end

function Client:get_chapter_reviews(book_id, chapter_uid, ranges)
    if type(ranges) ~= "table" or #ranges == 0 then
        return true, { reviews = {} }
    end

    local all_reviews = {}
    local batches = self:build_chapter_review_batches(ranges)
    local socket_ok, socket = pcall(require, "socket")

    for batch_index, batch in ipairs(batches) do
        local ok, result = self:get_chapter_reviews_batch(book_id, chapter_uid, batch)
        if ok and type(result) == "table" and type(result.reviews) == "table" then
            for _, review in ipairs(result.reviews) do
                all_reviews[#all_reviews + 1] = review
            end
        end

        if batch_index < #batches and socket_ok and socket.sleep then
            socket.sleep(0.3)
        end
    end

    return true, { reviews = all_reviews }
end

function Client:eink_credentials()
    local eink = self.settings:get("eink", {}) or {}
    local vid = tostring(eink.vid or "")
    local token = tostring(eink['access_token'] or "")
    if vid == "" or token == "" then
        return nil
    end
    return vid, token
end

function Client:mark_eink_auth_failed()
    if self._eink_auth_failed then return end
    self._eink_auth_failed = true
    self._eink_refresh_exhausted = true
    local settings = self.settings
    if settings and type(settings.get) == "function" and type(settings.set) == "function" then
        local eink = settings:get("eink", {}) or {}
        eink.auth_failed = true
        settings:set("eink", eink)
        if type(settings.flush) == "function" then settings:flush() end
    end
    logger.warn("eink login expired; scan the eink QR code again")
end

function Client:can_eink_download()
    if not self:eink_credentials() then return false end
    return self._eink_refresh_exhausted ~= true
end

local function eink_login_signature(timestamp_ms, device_id, random_value)
    local Crypto = require("weread.lib.crypto")
    return Crypto.sha256_hex(
        tostring(timestamp_ms) .. tostring(device_id) .. tostring(random_value)
    )
end

function Client:eink_refresh_session()
    if self._eink_refreshing or self._eink_refresh_exhausted then return false end
    local settings = self.settings
    if not settings or type(settings.get) ~= "function" then return false end
    local eink = settings:get("eink", {}) or {}
    local refresh = tostring(eink.refresh_token or "")
    local device_id = tostring(eink.device_id or "")
    if refresh == "" or device_id == "" then
        logger.warn("eink refresh skipped: missing refresh_token or device_id")
        return false
    end
    self._eink_refreshing = true
    local timestamp = os.time() * 1000
    local random_value = math.random(0, 999)
    local ok, body, code = pcall(function()
        return self:request({
            url = "https://i.weread.qq.com/login",
            method = "POST",
            skip_cookie = true,
            persist_response_cookies = false,
            log_http_errors = false,
            timeout = { 15, 25 },
            headers = {
                ["User-Agent"] = Eink.USER_AGENT,
                ["Accept"] = "*/*",
                ["Content-Type"] = "application/json;charset=UTF-8",
                ["appver"] = Eink.APPVER,
                ["basever"] = Eink.APPVER,
                ["baseapi"] = "30",
                ["osver"] = "11",
                ["channelId"] = "900",
                ["vid"] = tostring(eink.vid or ""),
            },
            body = self:json_encode({
                refreshToken = refresh,
                deviceId = device_id,
                deviceName = "BOOX",
                random = random_value,
                signature = eink_login_signature(timestamp, device_id, random_value),
                timestamp = timestamp,
                deviceType = 3,
            }),
            diagnostic_api = "/login",
        })
    end)
    self._eink_refreshing = false
    if not ok or not code or code < 200 or code >= 300 then
        logger.warn("eink refresh failed:", tostring(not ok and body or code))
        return false
    end
    local parsed_ok, parsed = pcall(self.decode_http_json, self, body, {
        method = "POST", url = "/login", code = code,
    })
    local token = parsed_ok and type(parsed) == "table" and tostring(parsed.accessToken or "") or ""
    if token == "" then
        logger.warn("eink refresh returned no accessToken")
        return false
    end
    eink.access_token = token
    if parsed.refreshToken and tostring(parsed.refreshToken) ~= "" then
        eink.refresh_token = tostring(parsed.refreshToken)
    end
    eink.auth_failed = nil
    eink.login_time = tostring(os.time())
    if type(settings.set) == "function" then settings:set("eink", eink) end
    if type(settings.flush) == "function" then settings:flush() end
    self._eink_auth_failed = nil
    logger.info("eink session refreshed")
    return true
end

local function eink_body_preview(body)
    if type(body) == "table" then
        local errcode = body.errcode or body.errCode or body.code
        local errmsg = body.errmsg or body.errMsg or body.errlog
        local bits = {}
        if errcode ~= nil then bits[#bits + 1] = "errcode=" .. tostring(errcode) end
        if errmsg ~= nil then bits[#bits + 1] = "errmsg=" .. tostring(errmsg) end
        if #bits > 0 then
            return table.concat(bits, " ")
        end
        return "json-object"
    end
    if type(body) ~= "string" or body == "" then
        return tostring(body)
    end
    local prefix = body:sub(1, 180):gsub("[%c]+", " ")
    return prefix
end

function Client:eink_request(path, params)
    local vid, token = self:eink_credentials()
    if not vid then
        error("eink credentials are missing")
    end
    local query = {}
    for key, value in pairs(params or {}) do
        query[#query + 1] = WeRead.urlencode(tostring(key)) .. "=" .. WeRead.urlencode(tostring(value))
    end
    table.sort(query)
    local url = "https://i.weread.qq.com" .. path
    if #query > 0 then
        url = url .. "?" .. table.concat(query, "&")
    end
    local body, code, headers = self:request({
        url = url,
        method = "GET",
        skip_cookie = true,
        persist_response_cookies = false,
        timeout = { 30, 180 },
        headers = {
            ["User-Agent"] = Eink.USER_AGENT,
            ["Accept"] = "*/*",
            ["vid"] = vid,
            ["accessToken"] = token,
            ["appver"] = Eink.APPVER,
            ["basever"] = Eink.APPVER,
            ["baseapi"] = "30",
            ["osver"] = "11",
            ["channelId"] = "900",
        },
        diagnostic_api = path,
        log_http_errors = false,
    })
    if tonumber(code) == 401 and self:eink_refresh_session() then
        vid, token = self:eink_credentials()
        body, code, headers = self:request({
            url = url,
            method = "GET",
            skip_cookie = true,
            persist_response_cookies = false,
            timeout = { 30, 180 },
            headers = {
                ["User-Agent"] = Eink.USER_AGENT,
                ["Accept"] = "*/*",
                ["vid"] = vid,
                ["accessToken"] = token,
                ["appver"] = Eink.APPVER,
                ["basever"] = Eink.APPVER,
                ["baseapi"] = "30",
                ["osver"] = "11",
                ["channelId"] = "900",
            },
            diagnostic_api = path,
            log_http_errors = false,
        })
    end
    if tonumber(code) == 401 then self:mark_eink_auth_failed() end
    return body, code, headers or {}
end

function Client:eink_json(path, params)
    local body, code = self:eink_request(path, params)
    if not code or code < 200 or code >= 300 then
        error("eink " .. path .. " failed: HTTP " .. tostring(code or "unknown"))
    end
    return self:decode_http_json(body, {
        method = "GET",
        url = path,
        code = code,
    }), code
end

function Client:eink_post_json(path, payload)
    local vid, token = self:eink_credentials()
    if not vid then
        error("eink credentials are missing")
    end
    local body, code = self:request({
        url = "https://i.weread.qq.com" .. path,
        method = "POST",
        skip_cookie = true,
        persist_response_cookies = false,
        timeout = { 30, 180 },
        headers = {
            ["User-Agent"] = Eink.USER_AGENT,
            ["Accept"] = "*/*",
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["vid"] = vid,
            ["accessToken"] = token,
            ["appver"] = Eink.APPVER,
            ["basever"] = Eink.APPVER,
            ["baseapi"] = "30",
            ["osver"] = "11",
            ["channelId"] = "900",
        },
        body = self:json_encode(payload or {}),
        diagnostic_api = path,
        log_http_errors = false,
    })
    if tonumber(code) == 401 and self:eink_refresh_session() then
        vid, token = self:eink_credentials()
        body, code = self:request({
            url = "https://i.weread.qq.com" .. path,
            method = "POST",
            skip_cookie = true,
            persist_response_cookies = false,
            timeout = { 30, 180 },
            headers = {
                ["User-Agent"] = Eink.USER_AGENT,
                ["Accept"] = "*/*",
                ["Content-Type"] = "application/json;charset=UTF-8",
                ["vid"] = vid,
                ["accessToken"] = token,
                ["appver"] = Eink.APPVER,
                ["basever"] = Eink.APPVER,
                ["baseapi"] = "30",
                ["osver"] = "11",
                ["channelId"] = "900",
            },
            body = self:json_encode(payload or {}),
            diagnostic_api = path,
            log_http_errors = false,
        })
    end
    if tonumber(code) == 401 then self:mark_eink_auth_failed() end
    if not code or code < 200 or code >= 300 then
        error("eink POST " .. path .. " failed: HTTP " .. tostring(code or "unknown"))
    end
    return self:decode_http_json(body, {
        method = "POST",
        url = path,
        code = code,
    })
end

function Client:eink_chapterinfo(book_id)
    local body, code = self:eink_request("/book/chapterinfo", { bookId = tostring(book_id) })
    if not code or code < 200 or code >= 300 then
        error("eink chapterinfo failed: HTTP " .. tostring(code or "unknown"))
    end
    return self:decode_http_json(body, {
        method = "GET",
        url = "/book/chapterinfo",
        code = code,
    })
end

function Client:eink_chapter_underlines(book_id, chapter_uid)
    book_id = tostring(book_id or "")
    local cache_key = book_id .. ":" .. tostring(chapter_uid or "")
    self._eink_underlines_cache = self._eink_underlines_cache or {}
    if self._eink_underlines_cache[cache_key] then
        return self._eink_underlines_cache[cache_key]
    end
    local data = self:eink_json("/book/underlines", {
        bookId = book_id,
        chapterUid = chapter_uid,
    })
    local err = eink_payload_error(data)
    if err then
        error("eink underlines errCode=" .. tostring(err))
    end
    self._eink_underlines_cache[cache_key] = data
    return data
end

-- APK NoteService.loadUserBookReviewList: USER_NOTE=11, mine=1, listMode=0.
-- synckey/hasMore are an incremental cursor, not an offset or a page number.
function Client:eink_own_reviews(book_id, synckey)
    assert(book_id and tostring(book_id) ~= "", "missing own-note bookId")
    return self:eink_json("/review/list", {
        bookId = tostring(book_id), listType = 11, mine = 1,
        listMode = 0, synckey = tonumber(synckey) or 0,
    })
end

function Client:eink_bookmarklist(book_id, refresh)
    book_id = tostring(book_id or "")
    self._eink_bookmark_cache = self._eink_bookmark_cache or {}
    if not refresh and self._eink_bookmark_cache[book_id] then
        return self._eink_bookmark_cache[book_id]
    end
    local body, code = self:eink_request("/book/bookmarklist", { bookId = book_id, synckey = 0 })
    if not code or code < 200 or code >= 300 then
        error("eink bookmarklist failed: HTTP " .. tostring(code or "unknown"))
    end
    local data = self:decode_http_json(body, {
        method = "GET",
        url = "/book/bookmarklist",
        code = code,
    })
    self._eink_bookmark_cache[book_id] = data
    return data
end

local function is_http_401(err)
    return tostring(err or ""):find("HTTP 401", 1, true) ~= nil
end

function Client:eink_download_to_file(book_id, chapters_param, path)
    local function attempt()
        local vid, token = self:eink_credentials()
        if not vid then
            error("eink credentials are missing")
        end
        local query = {
            "bookId=" .. WeRead.urlencode(tostring(book_id)),
            "chapters=" .. WeRead.urlencode(tostring(chapters_param)),
        }
        table.sort(query)
        local url = "https://i.weread.qq.com/book/chapterdownload?" .. table.concat(query, "&")
        return self:download_to_file(url, path, {
            skip_cookie = true,
            persist_response_cookies = false,
            timeout = { 30, 300 },
            headers = {
                ["User-Agent"] = Eink.USER_AGENT,
                ["Accept"] = "*/*",
                ["vid"] = vid,
                ["accessToken"] = token,
                ["appver"] = Eink.APPVER,
                ["basever"] = Eink.APPVER,
                ["baseapi"] = "30",
                ["osver"] = "11",
                ["channelId"] = "900",
            },
            diagnostic_api = "/book/chapterdownload",
        })
    end
    local ok, a, b, c = pcall(attempt)
    if not ok and is_http_401(a) and self:eink_refresh_session() then
        ok, a, b, c = pcall(attempt)
    end
    if not ok then
        if is_http_401(a) then self:mark_eink_auth_failed() end
        error(a, 0)
    end
    return a, b, c
end

function Client:eink_download_zip(book_id, chapters_param)
    local vid = self:eink_credentials()
    local body, code, headers = self:eink_request("/book/chapterdownload", {
        bookId = tostring(book_id),
        chapters = tostring(chapters_param),
    })
    if not code or code < 200 or code >= 300 then
        error("eink chapterdownload failed: HTTP " .. tostring(code or "unknown")
            .. " " .. eink_body_preview(body))
    end
    if type(body) == "string" and body:sub(1, 1) == "{" then
        local ok_errjson, parsed = pcall(self.json_decode, self, body)
        if ok_errjson then
            error("eink chapterdownload did not return a ZIP: HTTP "
                .. tostring(code) .. " " .. eink_body_preview(parsed))
        end
    end
    if type(body) == "string" and Eink.is_tar(body) then
        return Eink.untar(body)
    end
    if type(body) ~= "string" or body:sub(1, 2) ~= "PK" then
        error("eink chapterdownload did not return a ZIP: HTTP "
            .. tostring(code) .. " " .. eink_body_preview(body))
    end
    local encrypt_key = header_value(headers, "encryptKey") or header_value(headers, "encryptkey")
    if not encrypt_key or encrypt_key == "" then
        error("eink chapterdownload missing encryptKey header")
    end
    local password = Eink.decrypt_zip_password(encrypt_key, vid)
    return Eink.unzip_encrypted(body, password)
end

local ADD_BOOKMARK_KEYS = {
    "bookId", "chapterUid", "type", "range", "markText", "bookVersion", "style",
}
local ADD_REVIEW_KEYS = {
    "bookId", "chapterUid", "type", "range", "content", "abstract",
    "bookVersion", "isPrivate", "friendship", "htmlContent", "title",
    "notVisibleToFriends",
}
local USEREDIT_REVIEW_KEYS = {
    "reviewId", "content", "isPrivate", "friendship", "notVisibleToFriends",
    "type", "bookId", "chapterUid", "range", "abstract",
}
local COMMENT_REVIEW_KEYS = {
    "reviewId", "content", "isPrivate", "friendship", "htmlContent",
}

local function copy_known_keys(source, keys)
    local payload = {}
    for _, key in ipairs(keys) do
        if source and source[key] ~= nil then
            payload[key] = source[key]
        end
    end
    return payload
end

function Client:eink_add_bookmark(fields)
    local payload = copy_known_keys(fields, ADD_BOOKMARK_KEYS)
    payload.bookId = tostring(payload.bookId or "")
    payload.chapterUid = tonumber(payload.chapterUid)
    payload.type = tonumber(payload.type) or 1
    payload.range = tostring(payload.range or "")
    payload.markText = tostring(payload.markText or "")
    payload.bookVersion = tonumber(payload.bookVersion) or 0
    payload.style = tonumber(payload.style) or 0
    if payload.bookId == "" or not payload.chapterUid
        or payload.range == "" or payload.markText == "" then
        error("eink addBookmark missing bookId/chapterUid/range/markText")
    end
    local data = self:eink_post_json("/book/addBookmark", payload)
    self._eink_bookmark_cache = nil
    return data
end

function Client:eink_remove_bookmark(bookmark_id)
    bookmark_id = tostring(bookmark_id or "")
    if bookmark_id == "" then
        error("eink removeBookmark missing bookmarkId")
    end
    local data = self:eink_post_json("/book/removeBookmark", {
        bookmarkId = bookmark_id,
    })
    self._eink_bookmark_cache = nil
    return data
end

function Client:eink_add_review(fields)
    local payload = copy_known_keys(fields, ADD_REVIEW_KEYS)
    payload.bookId = tostring(payload.bookId or "")
    payload.chapterUid = tonumber(payload.chapterUid)
    payload.type = tonumber(payload.type) or 1
    payload.range = tostring(payload.range or "")
    payload.content = tostring(payload.content or "")
    payload.bookVersion = tonumber(payload.bookVersion) or 0
    payload.isPrivate = tonumber(payload.isPrivate) or 0
    payload.friendship = tonumber(payload.friendship) or 0
    payload.notVisibleToFriends = tonumber(payload.notVisibleToFriends) or 0
    if payload.htmlContent == nil then payload.htmlContent = "" end
    if payload.title == nil then payload.title = "" end
    if payload.bookId == "" or not payload.chapterUid
        or payload.range == "" or payload.content == "" then
        error("eink review/add missing bookId/chapterUid/range/content")
    end
    local data = self:eink_post_json("/review/add", payload)
    self._eink_bookmark_cache = nil
    return data
end

function Client:eink_useredit_review(fields)
    local payload = copy_known_keys(fields, USEREDIT_REVIEW_KEYS)
    payload.reviewId = tostring(payload.reviewId or "")
    payload.content = tostring(payload.content or "")
    if payload.reviewId == "" or payload.content == "" then
        error("eink review/useredit missing reviewId/content")
    end
    if payload.chapterUid ~= nil then
        payload.chapterUid = tonumber(payload.chapterUid)
    end
    if payload.type ~= nil then
        payload.type = tonumber(payload.type) or 1
    end
    local data = self:eink_post_json("/review/useredit", payload)
    self._eink_bookmark_cache = nil
    return data
end

function Client:eink_comment_review(fields)
    local payload = copy_known_keys(fields, COMMENT_REVIEW_KEYS)
    payload.reviewId = tostring(payload.reviewId or "")
    payload.content = tostring(payload.content or "")
    if payload.reviewId == "" or payload.content == "" then
        error("eink review/comment missing reviewId/content")
    end
    payload.isPrivate = tonumber(payload.isPrivate) or 0
    payload.friendship = tonumber(payload.friendship) or 0
    if payload.htmlContent == nil then payload.htmlContent = "" end
    local at_vid = fields and (fields.atUserVid or fields.authorVid)
    if at_vid and tostring(at_vid) ~= "" then
        payload.atUserVids = { tostring(at_vid) }
    end
    local data = self:eink_post_json("/review/comment", payload)
    self._eink_bookmark_cache = nil
    return data
end

function Client:eink_delete_review(review_id)
    review_id = tostring(review_id or "")
    if review_id == "" then
        error("eink review/delete missing reviewId")
    end
    local data = self:eink_post_json("/review/delete", {
        reviewId = review_id,
    })
    self._eink_bookmark_cache = nil
    return data
end

function Client:eink_mp_list(list_type, synckey, count)
    local params = {
        listType = tonumber(list_type) or 1,
        count = tonumber(count) or 20,
    }
    if synckey and tonumber(synckey) and tonumber(synckey) > 0 then
        params.synckey = tonumber(synckey)
    end
    return self:eink_json("/mp/list", params)
end

function Client:eink_report_mp_read(article, is_delete)
    if type(article) ~= "table" then
        error("eink report mp read missing article")
    end
    local payload = {
        bookId = tostring(article.bookId or article.book_id or ""),
        reviewId = tostring(article.reviewId or article.review_id or ""),
        url = tostring((article.url and article.url ~= "" and article.url)
            or article.sourceUrl or ""),
        title = tostring(article.title or ""),
        thumbUrl = tostring(article.thumbUrl or article.thumb_url or ""),
        account = tostring(article.account or article.mpName or ""),
        isDelete = is_delete and 1 or 0,
    }
    return self:eink_post_json("/mp/read", payload)
end

return Client

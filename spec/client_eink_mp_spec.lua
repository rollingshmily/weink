-- Tests for WeRead Eink MP article client methods: mp_list, report_mp_read, mp_notifications.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["ltn12"] = function() return {} end
package.preload["socketutil"] = function() return {} end
package.preload["socket.http"] = function() return {} end
package.preload["json"] = function()
    return {
        encode = function(v)
            if type(v) == "table" then
                local parts = {}
                for k, val in pairs(v) do
                    parts[#parts + 1] = string.format("%q:%s", tostring(k), type(val) == "string" and string.format("%q", val) or tostring(val))
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end
            return "{}"
        end,
        decode = function() return {} end,
    }
end
package.preload["weread.lib.cookie"] = function() return {} end
package.preload["weread.lib.protocol"] = function()
    return { urlencode = function(value) return tostring(value) end }
end
package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end

local Client = require("weread.lib.client")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local function make_client(overrides)
    local client = setmetatable({}, { __index = Client })
    for key, value in pairs(overrides or {}) do
        client[key] = value
    end
    return client
end

-- 1. eink_mp_list formats query parameters correctly and returns decoded payload
do
    local requested_path, requested_params
    local client = make_client {
        eink_json = function(_self, path, params)
            requested_path = path
            requested_params = params
            return {
                lists = {
                    { title = "Article 1", account = "Account 1", reviewId = "rev1" },
                    { title = "Article 2", account = "Account 2", reviewId = "rev2" },
                },
                synckey = 12345,
            }
        end,
    }
    local res = client:eink_mp_list(2, 100, 15)
    expect(requested_path == "/mp/list", "eink_mp_list path mismatch")
    expect(requested_params.listType == 2, "listType mismatch")
    expect(requested_params.synckey == 100, "synckey mismatch")
    expect(requested_params.count == 15, "count mismatch")
    expect(#res.lists == 2, "lists length mismatch")
    expect(res.synckey == 12345, "synckey return mismatch")
end

-- 2. eink_report_mp_read builds correct JSON payload
do
    local posted_path, posted_payload
    local client = make_client {
        eink_post_json = function(_self, path, payload)
            posted_path = path
            posted_payload = payload
            return { succ = 1 }
        end,
    }
    local article = {
        bookId = "MP_WXS_12345",
        reviewId = "MP_WXS_12345_abc",
        url = "https://mp.weixin.qq.com/s/test",
        title = "Test Article",
        thumbUrl = "https://mmbiz.qpic.cn/thumb.jpg",
        account = "Test MP",
    }
    local res = client:eink_report_mp_read(article, false)
    expect(posted_path == "/mp/read", "report_mp_read path mismatch")
    expect(posted_payload.bookId == "MP_WXS_12345", "bookId payload mismatch")
    expect(posted_payload.reviewId == "MP_WXS_12345_abc", "reviewId payload mismatch")
    expect(posted_payload.url == "https://mp.weixin.qq.com/s/test", "url payload mismatch")
    expect(posted_payload.title == "Test Article", "title payload mismatch")
    expect(posted_payload.account == "Test MP", "account payload mismatch")
    expect(posted_payload.isDelete == 0, "isDelete false mismatch")
    expect(res.succ == 1, "result mismatch")

    -- delete action
    client:eink_report_mp_read(article, true)
    expect(posted_payload.isDelete == 1, "isDelete true mismatch")
end

-- 3. eink_mp_notifications query format
do
    local notif_path, notif_params
    local client = make_client {
        eink_json = function(_self, path, params)
            notif_path = path
            notif_params = params
            return { todayNew = 1, favourite = 2, floating = 3 }
        end,
    }
    local res = client:eink_mp_notifications(1, 2, 3)
    expect(notif_path == "/mp/notifications", "notifications path mismatch")
    expect(notif_params.todayNew == 1 and notif_params.favourite == 2 and notif_params.floating == 3, "params mismatch")
    expect(res.floating == 3, "response mismatch")
end

if failures > 0 then
    error(string.format("%d checks failed in client_eink_mp_spec", failures))
end
print(string.format("client_eink_mp_spec: %d checks, 0 failure(s)", checks))

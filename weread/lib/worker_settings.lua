local M = {}

local function eink_fields(settings)
    local eink = {}
    if settings and type(settings.get) == "function" then
        eink = settings:get("eink", {}) or {}
    end
    return {
        vid = tostring(eink.vid or ""),
        access_token = tostring(eink.access_token or ""),
        refresh_token = tostring(eink.refresh_token or ""),
        device_id = tostring(eink.device_id or ""),
        skey = tostring(eink.skey or ""),
    }
end

local function auth_fingerprint(settings)
    local eink = eink_fields(settings)
    return table.concat({
        "vid=" .. eink.vid,
        "access_token=" .. eink.access_token,
        "refresh_token=" .. eink.refresh_token,
        "device_id=" .. eink.device_id,
        "skey=" .. eink.skey,
    }, ";")
end

function M.capture(settings)
    local changed = false
    settings.flush = function() end
    local update_auth = settings.update_auth
    if type(update_auth) == "function" then
        settings.update_auth = function(object, credentials, options)
            changed = true
            options = options or {}
            options.flush = false
            return update_auth(object, credentials, options)
        end
    end
    return function()
        if not changed or type(settings.get) ~= "function" then return nil end
        return {
            eink = settings:get("eink", {}),
        }
    end
end

function M.fingerprint(settings)
    return auth_fingerprint(settings)
end

function M.merge(settings, expected_fingerprint, auth)
    if type(auth) ~= "table" then return false end
    if not settings or type(settings.update_auth) ~= "function" then return false end
    if auth_fingerprint(settings) ~= expected_fingerprint then return false end
    local eink = auth.eink
    if type(eink) ~= "table" then
        return false
    end
    settings:update_auth({ eink = eink })
    return true
end

return M

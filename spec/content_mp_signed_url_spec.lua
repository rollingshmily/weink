-- MP article URL signing specs.
-- WeChat answers article links that carry no `chksm` signature (the
-- scene=58&subscene=0 form WeRead returns for floating/saved articles) with its
-- POC verification page, which has no js_content and can never be passed by a
-- JS-less client. fetch_article_html must normalise such links through
-- /review/single's mpInfo.doc_url, and must name the challenge explicitly.
-- Run with: luajit spec/content_mp_signed_url_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weink.lib.crypto"] = function()
    return { sha256_hex = function(value) return string.rep("a", 64) end }
end
package.preload["weink.lib.reader_state"] = function() return {} end
package.preload["weink.lib.thoughts"] = function() return {} end

local Content = require("weink.lib.content")

local SIGNED = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=b&chksm=" .. string.rep("c", 64)
local UNSIGNED = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=b&scene=58&subscene=0"
local DOC_URL = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=b&chksm=" .. string.rep("d", 64) .. "#rd"
local ARTICLE_BODY = '<div id="js_content"><p>正文</p></div><script></script>'

local settings = { data_dir = "/tmp/weink-signed-url-spec" }

-- 1) an already signed link is fetched as-is, without an extra API round trip
local requested
local signed_client = {
    eink_json = function() error("signed links must not hit /review/single") end,
    get_public_text = function(_self, url)
        requested = url
        return ARTICLE_BODY, { content_type = "text/html", length = #ARTICLE_BODY, url = url }
    end,
}
local signed_path = Content.fetch_article_html(signed_client, settings, nil,
    { reviewId = "r-1", title = "signed", url = SIGNED })
expect(requested == SIGNED, "signed URL must be fetched as-is")
expect(Content.is_valid_article_cache(signed_path), "signed article cache missing")

-- 2) an unsigned link is normalised to the freshly signed doc_url
local resolve_calls = 0
local normalised_calls = 0
local unsigned_client = {
    eink_json = function(_self, path, params)
        resolve_calls = resolve_calls + 1
        expect(path == "/review/single", "wrong resolve endpoint: " .. tostring(path))
        expect(params.reviewId == "r-2", "wrong reviewId passed to resolve")
        return { review = { mpInfo = { doc_url = DOC_URL } } }
    end,
    get_public_text = function(_self, url)
        requested = url
        if not url:find("chksm=", 1, true) then
            normalised_calls = normalised_calls + 1
            local challenge = "<html><body>poc_token=abc</body></html>"
            return challenge, { content_type = "text/html", length = #challenge,
                url = "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?poc_token=abc" }
        end
        return ARTICLE_BODY, { content_type = "text/html", length = #ARTICLE_BODY, url = url }
    end,
}
local unsigned_path = Content.fetch_article_html(unsigned_client, settings, nil,
    { reviewId = "r-2", title = "unsigned", url = UNSIGNED })
expect(resolve_calls == 1, "unsigned URL did not resolve a signed form")
expect(normalised_calls == 0, "unsigned URL must never be requested")
expect(requested == DOC_URL, "unsigned URL was not replaced by the signed doc_url")
expect(Content.is_valid_article_cache(unsigned_path), "normalised article cache missing")

-- 3) the challenge page is reported as a verification, not as a broken article
local challenged_client = {
    eink_json = function() return {} end,
    get_public_text = function(_self, url)
        local challenge = "<html><body>poc_token=x</body></html>"
        return challenge, { content_type = "text/html", length = #challenge,
            url = "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?poc_token=x" }
    end,
}
local ok, err = pcall(Content.fetch_article_html, challenged_client, settings, nil,
    { reviewId = "r-3", title = "challenged",
      url = "https://mp.weixin.qq.com/s?__biz=a&mid=2&idx=1&sn=c&scene=58&subscene=0" })
expect(not ok, "challenge page must not be treated as article content")
expect(tostring(err):find("verification", 1, true) ~= nil,
    "challenge error must mention the WeChat verification, got: " .. tostring(err))

print("content_mp_signed_url_spec: " .. checks .. " checks passed")

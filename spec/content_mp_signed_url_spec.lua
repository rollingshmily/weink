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

-- 4) /review/single repeats the unsigned stored form on most calls (measured
--    15% signed on 2026-10-08), so the lookup must keep asking until WeChat
--    hands back a signed doc_url instead of giving up after one try.
local retry_calls = 0
local retry_client = {
    eink_json = function(_self, path, params)
        retry_calls = retry_calls + 1
        expect(path == "/review/single", "wrong retry endpoint: " .. tostring(path))
        expect(params.reviewId == "r-4", "wrong retry reviewId: " .. tostring(params.reviewId))
        if retry_calls < 3 then
            return { review = { mpInfo = { doc_url = UNSIGNED } } }
        end
        return { review = { mpInfo = { doc_url = DOC_URL } } }
    end,
    get_public_text = function(_self, url)
        requested = url
        if not url:find("chksm=", 1, true) then
            local challenge = "<html><body>poc_token=abc</body></html>"
            return challenge, { content_type = "text/html", length = #challenge,
                url = "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?poc_token=***" }
        end
        return ARTICLE_BODY, { content_type = "text/html", length = #ARTICLE_BODY, url = url }
    end,
}
local retry_path = Content.fetch_article_html(retry_client, settings, nil,
    { reviewId = "r-4", title = "retry", url = UNSIGNED })
expect(retry_calls == 3, "unsigned doc_url must be retried, got " .. retry_calls .. " calls")
expect(requested == DOC_URL, "retry must fetch the signed doc_url, got " .. tostring(requested))
expect(Content.is_valid_article_cache(retry_path), "retried article cache missing")

-- 5) When every attempt stays unsigned the stored link is what gets fetched
--    (and named as a verification), rather than silently claiming success.
local exhausted_calls = 0
local exhausted_client = {
    eink_json = function() exhausted_calls = exhausted_calls + 1; return {} end,
    get_public_text = function(_self, url)
        local challenge = "<html><body>poc_token=x</body></html>"
        return challenge, { content_type = "text/html", length = #challenge,
            url = "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?poc_token=***" }
    end,
}
local resolved = Content.resolve_mp_article_url(exhausted_client,
    { reviewId = "r-5", url = UNSIGNED })
expect(resolved == UNSIGNED, "exhausted lookup must fall back to the stored link")
expect(exhausted_calls > 1, "exhausted lookup must have retried, got " .. exhausted_calls)

-- 6) a resolved link is cached, so a second download of the same article does
--    not re-run the 15%-hit-rate lookup (that is what the tap-to-open path and
--    the background prefetch share)
local cache_lookups = 0
local cache_client = {
    eink_json = function(_self, path, params)
        cache_lookups = cache_lookups + 1
        return { review = { mpInfo = { doc_url = DOC_URL } } }
    end,
    get_public_text = function(_self, url)
        return ARTICLE_BODY, { content_type = "text/html", length = #ARTICLE_BODY, url = url }
    end,
}
Content.fetch_article_html(cache_client, settings, nil,
    { reviewId = "r-6", title = "cache", url = UNSIGNED })
Content.fetch_article_html(cache_client, settings, nil,
    { reviewId = "r-6", title = "cache", url = UNSIGNED })
expect(cache_lookups == 1, "signed link must be cached across downloads, got "
    .. cache_lookups .. " lookups")
expect(Content.cached_mp_article_url("r-6") == DOC_URL,
    "cached signed link must be readable")

-- 7) a cached link that WeChat now challenges must be dropped, so the retry
--    asks for a fresh signature instead of repeating the dead one
Content.remember_mp_article_url("r-7", DOC_URL)
local fresh_doc = "https://mp.weixin.qq.com/s?__biz=a&mid=1&idx=1&sn=b&chksm="
    .. string.rep("e", 64) .. "#rd"
local stale_lookups = 0
local stale_client = {
    eink_json = function(_self, path, params)
        stale_lookups = stale_lookups + 1
        return { review = { mpInfo = { doc_url = fresh_doc } } }
    end,
    get_public_text = function(_self, url)
        requested = url
        if url == DOC_URL then
            local challenge = "<html><body>poc_token=abc</body></html>"
            return challenge, { content_type = "text/html", length = #challenge,
                url = "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?poc_token=***" }
        end
        return ARTICLE_BODY, { content_type = "text/html", length = #ARTICLE_BODY, url = url }
    end,
}
local stale_path = Content.fetch_article_html(stale_client, settings, nil,
    { reviewId = "r-7", title = "stale", url = UNSIGNED })
expect(Content.is_valid_article_cache(stale_path), "refreshed article cache missing")
expect(stale_lookups >= 1, "stale cached link must trigger a fresh lookup")
expect(requested == fresh_doc, "stale cached link must be replaced, got "
    .. tostring(requested))
expect(Content.cached_mp_article_url("r-7") == fresh_doc,
    "refreshed link must replace the stale cache entry")

print("content_mp_signed_url_spec: " .. checks .. " checks passed")

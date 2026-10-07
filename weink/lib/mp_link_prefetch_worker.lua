-- Silent prefetch of signed WeChat article links.
--
-- WeRead returns the unsigned (scene=58&subscene=0) form for most saved
-- articles, and /review/single only hands back a freshly signed doc_url on a
-- fraction of calls (measured 15%, 6/40 on 2026-10-08), so resolving a link at
-- tap time costs several round trips. Resolving the articles already on screen
-- inside the background worker keeps the tap-to-open path fast.
local Content = require("weink.lib.content")

local M = {}

M.DEFAULT_LIMIT = 6
M.DEFAULT_ATTEMPTS = 8

local function stored_url(article)
    return tostring((article and article.url and article.url ~= "" and article.url)
        or (article and article.sourceUrl) or "")
end

function M.candidates(articles, limit)
    local picked = {}
    local max = tonumber(limit) or M.DEFAULT_LIMIT
    for _, article in ipairs(articles or {}) do
        if #picked >= max then break end
        local review_id = article and (article.reviewId or article.review_id)
        local url = stored_url(article)
        if review_id and tostring(review_id) ~= "" and url ~= ""
            and not Content.mp_url_is_signed(url)
            and not Content.cached_mp_article_url(review_id) then
            picked[#picked + 1] = article
        end
    end
    return picked
end

-- Runs in the background worker's child process: the parent keeps the cache.
function M.run(settings, client, articles, context)
    local links = {}
    local total = #(articles or {})
    local resolved = 0
    for index, article in ipairs(articles or {}) do
        context.checkCancelled()
        context.emit { stage = "links", current = index - 1, count = total }
        local review_id = article and (article.reviewId or article.review_id)
        local stored = stored_url(article)
        local url = Content.resolve_mp_article_url(client, article,
            { attempts = M.DEFAULT_ATTEMPTS })
        if review_id and Content.mp_url_is_signed(url) and url ~= stored then
            links[tostring(review_id)] = url
            resolved = resolved + 1
        end
        context.emit { stage = "links", current = index, count = total }
    end
    return { links = links, attempted = total, resolved = resolved }
end

return M

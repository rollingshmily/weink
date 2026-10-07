-- Silent prefetch of signed WeChat article links.
--
-- WeRead returns the unsigned (scene=58&subscene=0) form for most saved
-- articles, and /review/single only hands back a freshly signed doc_url on a
-- fraction of calls (measured 15%, 6/40 on 2026-10-08), so resolving a link at
-- tap time costs several round trips. Resolving the articles already on screen
-- inside the background worker keeps the tap-to-open path fast.
--
-- Attempts are interleaved round-robin instead of resolving one article
-- completely before the next: at a 15% hit rate a sequential pass would spend
-- its whole budget on the first article while the user is tapping the fifth.
local Content = require("weink.lib.content")
local WorkerSettings = require("weink.lib.worker_settings")

local M = {}

M.DEFAULT_LIMIT = 6
M.DEFAULT_ROUNDS = 5

local function stored_url(article)
    return tostring((article and article.url and article.url ~= "" and article.url)
        or (article and article.sourceUrl) or "")
end

local function review_id_of(article)
    local review_id = article and (article.reviewId or article.review_id)
    if not review_id or tostring(review_id) == "" then return nil end
    return tostring(review_id)
end

local function needs_signed_link(article)
    local review_id = review_id_of(article)
    if not review_id then return false end
    local url = stored_url(article)
    if url == "" or Content.mp_url_is_signed(url) then return false end
    return Content.cached_mp_article_url(review_id) == nil
end

function M.candidates(articles, limit)
    local picked = {}
    local max = tonumber(limit) or M.DEFAULT_LIMIT
    for _, article in ipairs(articles or {}) do
        if #picked >= max then break end
        if needs_signed_link(article) then picked[#picked + 1] = article end
    end
    return picked
end

-- Runs in the background worker's child process: the parent owns the cache and
-- merges the returned links itself.
function M.run(settings, client, articles, context)
    local auth_result = WorkerSettings.capture(settings)
    local total = 0
    for _, article in ipairs(articles or {}) do
        if needs_signed_link(article) then total = total + 1 end
    end
    local ok, result = xpcall(function()
        local pending = {}
        for _, article in ipairs(articles or {}) do
            if needs_signed_link(article) then pending[#pending + 1] = article end
        end
        local rounds = tonumber(M.DEFAULT_ROUNDS) or 5
        local links = {}
        for round = 1, rounds do
            if #pending == 0 then break end
            context.checkCancelled()
            context.emit { stage = "links", round = round, rounds = rounds,
                pending = #pending, count = total }
            local still_pending = {}
            for _, article in ipairs(pending) do
                context.checkCancelled()
                local review_id = review_id_of(article)
                local url = Content.try_mp_article_url(client, review_id)
                if url then
                    links[review_id] = url
                else
                    still_pending[#still_pending + 1] = article
                end
            end
            pending = still_pending
        end
        local resolved = 0
        for _ in pairs(links) do resolved = resolved + 1 end
        return { links = links, attempted = total, resolved = resolved,
            rounds = rounds, auth = auth_result() }
    end, debug.traceback)
    if not ok then error(result, 0) end
    return result
end

return M

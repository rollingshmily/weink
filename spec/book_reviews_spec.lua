-- Unit tests for weread/lib/book_reviews.lua.
-- Run from the repo root with a plain Lua interpreter:
--   lua spec/book_reviews_spec.lua

package.path = "./?.lua;" .. package.path
local BookReviews = require("weread.lib.book_reviews")

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

test("normalizes nested gateway reviews", function()
    local result = BookReviews.normalize_list({
        reviewsCnt = 12,
        reviewsHasMore = 1,
        reviews = {
            {
                idx = 7,
                review = {
                    review = {
                        reviewId = "r1",
                        author = { nick = "读者甲" },
                        content = "第一段<br>第二段 &amp; 尾声",
                        star = 100,
                        createTime = 1700000000,
                        isFinish = 1,
                    },
                },
            },
        },
    })
    eq(result.total_count, 12, "total count")
    eq(result.has_more, true, "has more")
    eq(#result.items, 1, "item count")
    eq(result.items[1].author, "读者甲", "author")
    eq(result.items[1].content, "第一段\n第二段 & 尾声", "plain content")
    eq(result.items[1].rating, 10, "100-point star normalized to 10")
    eq(result.items[1].is_finish, true, "finished")
    eq(result.items[1].idx, 7, "idx")
end)

test("uses html content when plain content is empty", function()
    local item = BookReviews.normalize_item({
        review = {
            review = {
                htmlContent = "<p>很好</p><p>值得读&#33;</p>",
                author = "某读者",
            },
        },
    })
    eq(item.content, "很好\n\n值得读!", "html fallback")
    eq(item.author, "某读者", "string author")
end)

test("truncates previews by UTF-8 characters", function()
    eq(BookReviews.preview("一二三四五", 3), "一二三…", "Chinese preview")
    eq(BookReviews.preview("abc", 3), "abc", "exact preview")
end)

test("formats review ratings on a ten-point scale", function()
    eq(BookReviews.normalize_item({ star = 60 }).rating, 6, "60 becomes 6")
    eq(BookReviews.normalize_item({ star = 100 }).rating, 10, "100 becomes 10")
    eq(BookReviews.format_rating(6), "6.0", "one decimal place")
end)

test("formats string and millisecond dates", function()
    eq(BookReviews.format_date("2026/7/9 00:00:00"), "2026-07-09", "string date")
    eq(BookReviews.format_date("2026年7月"), "2026年7月", "displayable date text")
    eq(
        BookReviews.format_date(1700000000000),
        os.date("%Y-%m-%d", 1700000000),
        "millisecond timestamp"
    )
end)

test("keeps review type and can drop underlines", function()
    local mixed = BookReviews.normalize_list({
        reviews = {
            { type = 1, content = "我的划线", author = "me" },
            {
                review = {
                    type = 4,
                    content = "推荐书评",
                    author = { nick = "读者乙" },
                    star = 80,
                },
            },
        },
    }, { only_type = 4 })
    eq(#mixed.items, 1, "underlines filtered out")
    eq(mixed.items[1].content, "推荐书评", "kept book review")
    eq(mixed.items[1].review_type, 4, "review type preserved")
end)

test("filters empty rendered bodies without removing short reviews", function()
    local empty = { false, "", " \t\r\n", "<p><br /></p>", "<div>&nbsp;&#160;&#x3000;</div>",
        "　 ", "&#x200B;&#x200C;&#x200D;&#xFEFF;", "&ensp;&emsp;&thinsp;&zwnj;&zwj;&ZeroWidthSpace;",
        "<!-- no visible content -->", "<style>p { color: black }</style><script>placeholder()</script>",
        "<img src='rating.png'>", {},
    }
    local rows = { { type = 4, star = 100 } } -- missing body
    for _, body in ipairs(empty) do rows[#rows + 1] = { type = 4, content = body } end
    rows[#rows + 1] = { type = 4, content = "好" }
    rows[#rows + 1] = { type = 4, content = "<p> </p>", htmlContent = "<div>短评</div>" }
    rows[#rows + 1] = { type = 4, content = "👩‍💻" }
    rows[#rows + 1] = { type = 4, content = "0" }
    rows[#rows + 1] = { type = 1, content = "not a book review" }
    local result = BookReviews.normalize_list({ reviews = rows, totalCount = 1087, hasMore = 1, synckey = 12 },
        { only_type = 4 })
    eq(#result.items, 4, "only real bodies retained")
    eq(result.items[1].content, "好", "single character retained")
    eq(result.items[2].content, "短评", "HTML fallback after empty plain body")
    eq(result.items[3].content, "👩‍💻", "emoji joiner preserved")
    eq(result.items[4].content, "0", "literal zero is real text")
    eq(result.total_count, 1087, "eink totalCount remains server total")
    eq(result.raw_count, #rows, "raw count includes filtered entries")
    eq(result.has_more, true, "eink hasMore survives filtering")
    eq(result.synckey, 12, "cursor retained")
    local all_empty = BookReviews.normalize_list({ reviews = { { content = " " } }, hasMore = true, synckey = 99 })
    eq(#all_empty.items, 0, "empty page")
    eq(all_empty.has_more, true, "empty page is not end of list")
    eq(all_empty.total_count, 1, "fallback count is unfiltered")
end)

if failures > 0 then
    error(string.format("%d/%d checks failed", failures, checks))
end
print(string.format("OK: %d checks", checks))

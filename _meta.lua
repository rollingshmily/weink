local I18n = require("weink.lib.i18n")

local function _(text)
    return I18n.tr(text)
end

return {
    fullname = _("WeRead"),
    description = _([[Read WeRead books in KOReader, cache chapters, and sync reading progress.]]),
    version = "2.7.7"
}

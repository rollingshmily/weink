local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template

local I18n = require("weread.lib.i18n")

local ProgressSyncDialog = {}

local function _(text)
    return I18n.tr(text)
end

local function percent(position)
    return string.format("%.0f", tonumber(position and position.percent) or 0)
end

function ProgressSyncDialog.show_choice(context)
    local message
    if context.position_uncertain then
        message = T(_(
            "Cannot precisely compare chapter offsets for \"%1\".\n\n"
            .. "KOReader: %2%\nWeRead: %3%\n\n"
            .. "The local offset is estimated. Choose which position to keep."
        ), context.book_title, percent(context.local_position), percent(context.remote_position))
    elseif context.source_conflict then
        message = T(_(
            "WeRead's two progress sources disagree for \"%1\".\n\n"
            .. "KOReader: %2%\nSelected cloud position: %3%\n\n"
            .. "Choose which position to keep."
        ), context.book_title, percent(context.local_position),
            percent(context.remote_position))
    else
        message = T(_(
            "Reading progress differs for \"%1\".\n\n"
            .. "KOReader: %2%\nWeRead: %3%\n\n"
            .. "Choose which position to keep."
        ), context.book_title, percent(context.local_position),
            percent(context.remote_position))
    end

    UIManager:show(ConfirmBox:new{
        title = _("Reading progress sync"),
        text = message,
        ok_text = _("Use WeRead progress"),
        cancel_text = _("Keep KOReader progress"),
        ok_callback = context.use_remote,
        cancel_callback = context.keep_local,
    })
end

function ProgressSyncDialog.notify(code, data)
    data = data or {}
    local text
    if code == "upload_success" then
        text = T(_("WeRead accepted the progress request: %1%."),
            percent(data.position))
    elseif code == "upload_unconfirmed" then
        text = T(_("WeRead accepted the progress request: %1%, but the cloud record has not caught up yet; the next sync will retry."),
            percent(data.position))
    elseif code == "upload_failed" then
        text = T(_("Progress upload failed:\n%1"), tostring(data.error or ""))
    elseif code == "already_synced" then
        text = _("The reported coordinates match the cloud record.")
    elseif code == "remote_applied" then
        text = T(_("Opened WeRead's chapter near %1%. The within-chapter position is estimated."),
            percent(data.position))
    elseif code == "local_kept" then
        text = _("Kept the current KOReader position.")
    elseif code == "pull_failed" then
        text = T(_("Could not fetch WeRead progress:\n%1"),
            tostring(data.error or ""))
    elseif code == "jump_failed" then
        text = T(_("Could not jump to WeRead progress:\n%1"),
            tostring(data.error or ""))
    elseif code == "local_unavailable" then
        local reason = tostring(data.error or "")
        if reason == "document_not_weread" or reason == "no_document" then
            -- No WeRead document is open: a normal skip, never a user-facing error.
            return
        elseif reason == "document_chapter_unmapped" or reason == "document_chapter_ambiguous" then
            text = _("This chapter could not be matched with WeRead's catalog; sync is paused and will resume on the next page.")
        elseif reason == "document_toc_unavailable" then
            text = _("This document has no usable table of contents; position sync is paused.")
        else
            text = T(_("Could not determine the current reading position:\n%1"), reason)
        end
    elseif code == "authentication_required" then
        text = _("Please scan the QR code to log in first.")
    elseif code == "offline" then
        text = _("No network connection. Please connect Wi-Fi and try again.")
    else
        return
    end
    UIManager:show(InfoMessage:new{ text = text })
end

return ProgressSyncDialog

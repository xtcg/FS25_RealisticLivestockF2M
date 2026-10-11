--[[
    RLFeedRationDialog.lua
    A cattle pen's ration settings in the real-equivalent nutrition mode (FEED-08), opened from the
    RL menu's Info tab. The view of RLFeedRationModel: the pickers edit the model's draft, every
    change shows the draft's preview, Apply sends it (a client's pen shows it once the server has
    applied it), Back drops it. Read-only, with the reason, while the pen cannot be edited.
]]

local Log = RmLogging.getLogger("RLRM")

RLFeedRationDialog = {}

local RLFeedRationDialog_mt = Class(RLFeedRationDialog, MessageDialog)
local modDirectory = g_currentModDirectory

local COLUMNS = { "Title", "Month", "Share", "Stock", "Lasts" }
local ROW_FIELDS = { Title = "title", Month = "perMonth", Share = "dmShare", Stock = "stock", Lasts = "lasts" }


function RLFeedRationDialog.register()
    local dialog = RLFeedRationDialog.new()
    g_gui:loadGui(modDirectory .. "gui/RLFeedRationDialog.xml", "RLFeedRationDialog", dialog)
    RLFeedRationDialog.INSTANCE = dialog
    Log:trace("RLFeedRationDialog.register: dialog registered")
end


function RLFeedRationDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or RLFeedRationDialog_mt)
    self.placeable = nil
    self.model = nil
    self.callback = nil
    self.callbackTarget = nil
    return self
end


--- Open the dialog for a cattle pen.
--- @param placeable table
--- @param callback function|nil fn(target, sent) when the dialog closes
--- @param target table|nil
function RLFeedRationDialog.show(placeable, callback, target)
    if placeable == nil or placeable.spec_husbandryFood == nil then return end
    if RLFeedRationDialog.INSTANCE == nil then RLFeedRationDialog.register() end
    local dialog = RLFeedRationDialog.INSTANCE
    dialog.placeable, dialog.callback, dialog.callbackTarget = placeable, callback, target
    g_gui:showDialog("RLFeedRationDialog")
end


function RLFeedRationDialog:onGuiSetupFinished()
    RLFeedRationDialog:superClass().onGuiSetupFinished(self)
    for _, id in ipairs({ "titleText", "statusText", "targetPicker", "grainPicker", "sharePicker", "substitutePicker", "shareText",
        "intakeText", "emptyText", "noteText", "applyButton" }) do
        self[id] = self:getDescendantById(id)
        if self[id] == nil then Log:warning("RLFeedRationDialog: element %s missing", id) end
    end
    self.rows = {}
    for i = 1, RLFeedRationModel.MAX_ROWS do
        local row = {}
        for _, column in ipairs(COLUMNS) do row[column] = self:getDescendantById(string.format("row%d%s", i, column)) end
        self.rows[i] = row
    end
end


function RLFeedRationDialog:onOpen()
    RLFeedRationDialog:superClass().onOpen(self)
    self.model = RLFeedRationModel.new(self.placeable)
    local model = self.model
    self.targetPicker:setTexts(model:getTargetTexts())
    self.targetPicker:setState(model:getTargetIndex(), false)
    self.grainPicker:setTexts(model:getGrainTexts())
    self.grainPicker:setState(model:getGrainIndex(), false)
    self.sharePicker:setTexts(model:getShareTexts())
    self.sharePicker:setState(model:getShareIndex(), false)
    self.substitutePicker:setTexts(model:getSubstituteTexts())
    self.substitutePicker:setState(model:getSubstituteIndex(), false)
    local name = self.placeable.getName ~= nil and self.placeable:getName() or nil
    self.titleText:setText(name ~= nil and string.format("%s - %s", g_i18n:getText("rl_feed_dialogTitle"), name)
        or g_i18n:getText("rl_feed_dialogTitle"))
    self:refresh()
end


function RLFeedRationDialog:onClose()
    RLFeedRationDialog:superClass().onClose(self)
    self.model = nil
end


--- Show the access state and the draft's preview.
function RLFeedRationDialog:refresh()
    local model = self.model
    if model == nil then return end
    local editable, reason = model:getAccess()
    if editable then
        self.statusText:setText(g_currentMission ~= nil and g_currentMission:getIsClient() and not g_currentMission:getIsServer()
            and g_i18n:getText("rl_feed_statusClient") or "")
    else
        local reasonText = reason == "NO_PERMISSION" and g_i18n:getText("rl_feed_reason_NO_PERMISSION") or RLFeedInfoService.getReasonText(reason)
        self.statusText:setText(string.format(g_i18n:getText("rl_feed_readOnly"), reasonText))
    end
    for _, picker in ipairs({ self.targetPicker, self.grainPicker, self.sharePicker, self.substitutePicker }) do
        picker:setDisabled(not editable)
    end
    self.applyButton:setDisabled(not editable or not model:isChanged())

    local texts = model:getPreviewTexts()
    self.shareText:setText(texts.share or "")
    self.intakeText:setText(texts.intake or "")
    for i, row in ipairs(self.rows) do
        local data = texts.rows[i]
        for _, column in ipairs(COLUMNS) do
            local element = row[column]
            if element ~= nil then
                element:setText(data ~= nil and data[ROW_FIELDS[column]] or "")
                element:setVisible(data ~= nil)
            end
        end
    end
    self.emptyText:setText(texts.empty or "")
    self.emptyText:setVisible(texts.empty ~= nil)
    local note = g_i18n:getText("rl_feed_previewNote")
    if texts.more > 0 then note = string.format("%s %s", string.format(g_i18n:getText("rl_feed_previewMore"), texts.more), note) end
    if texts.warning ~= nil then note = string.format("%s · %s", texts.warning, note) end
    self.noteText:setText(note)
end


function RLFeedRationDialog:onTargetChanged(state)
    if self.model == nil then return end
    self.model:setTargetIndex(state)
    self:refresh()
end


function RLFeedRationDialog:onGrainChanged(state)
    if self.model == nil then return end
    self.model:setGrainIndex(state)
    self:refresh()
end


function RLFeedRationDialog:onShareChanged(state)
    if self.model == nil then return end
    self.model:setShareIndex(state)
    self:refresh()
end


function RLFeedRationDialog:onSubstituteChanged(state)
    if self.model == nil then return end
    self.model:setSubstituteIndex(state)
    self:refresh()
end


function RLFeedRationDialog:onClickApply()
    local model = self.model
    if model == nil then return end
    -- Checked again at the click: the mode, the pen or the permission may have changed while the
    -- dialog was open.
    local sent = model:apply()
    Log:debug("RLFeedRationDialog:onClickApply: %s target=%s grain=%s share=%s substitute=%s sent=%s",
        self.placeable.getName ~= nil and self.placeable:getName() or "?", tostring(model.draft.target), tostring(model.draft.grain),
        tostring(model.draft.share), tostring(model.draft.substitute), tostring(sent))
    if not sent and model:isChanged() then
        self:refresh()
        return
    end
    self:close()
    if self.callback ~= nil then self.callback(self.callbackTarget, sent) end
end


function RLFeedRationDialog:onClickBack()
    self:close()
    if self.callback ~= nil then self.callback(self.callbackTarget, false) end
end

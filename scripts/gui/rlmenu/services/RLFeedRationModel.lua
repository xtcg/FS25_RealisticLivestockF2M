--[[
    RLFeedRationModel.lua
    The ration dialog's state (RLFeedRationDialog), without any GUI: a cattle pen's ration settings
    as a draft the player edits - what the animals eat for, which concentrate, the concentrate
    share target (AUTO, or 0-80 % of the DM in steps of 5) and whether another grain stands in -
    the options each picker offers, whether the pen may be edited and why not, the draft's preview
    (RLFeedInfoService.previewRation, worked out once per draft and hour) and its texts.

    The draft is the dialog's own: nothing about the pen changes until apply(), which sends it
    (RLFeedRationEvent). A server applies it there and then; a client asks the server, and the
    pen's ration changes only when the server sends back what it applied. Read-only while the mode
    is off, while the pen keeps the old rules, or without the tradeAnimals permission (the server
    would refuse it).
]]

RLFeedRationModel = {}
local RLFeedRationModel_mt = { __index = RLFeedRationModel }

--- Steps of the concentrate share target.
RLFeedRationModel.SHARE_STEP = 0.05
--- Most rows the preview table shows.
RLFeedRationModel.MAX_ROWS = 8


local function getText(key)
    return g_i18n ~= nil and g_i18n:getText(key) or key
end


local function copyRation(ration)
    return { target = ration.target, grain = ration.grain, share = ration.share, substitute = ration.substitute }
end


local function sameShare(a, b)
    if a == nil or b == nil then return a == b end
    return math.abs(a - b) < 1e-6
end


local function sameRation(a, b)
    return a.target == b.target and a.grain == b.grain and sameShare(a.share, b.share) and a.substitute == b.substitute
end


--- @param placeable table A cattle pen
function RLFeedRationModel.new(placeable)
    local self = setmetatable({ placeable = placeable }, RLFeedRationModel_mt)
    self.current = copyRation(RLFeed.sanitizeRation(RLFeed.getRation(placeable)))
    self.draft = copyRation(self.current)
    self:buildOptions()
    return self
end


-- =============================================================================
-- Options
-- =============================================================================

--- The pickers' options: targets, concentrates (AUTO, NONE and each grain the pen's trough takes;
--- the pen's own choice kept even when the trough no longer takes it), shares (AUTO, 0 to MAX_SHARE
--- in SHARE_STEP; the pen's own value kept when it is off that grid) and substitution.
function RLFeedRationModel:buildOptions()
    self.targets = {}
    for _, target in ipairs(RLFeed.TARGETS) do table.insert(self.targets, target) end

    local spec = self.placeable.spec_husbandryFood
    self.grains = { "AUTO", "NONE" }
    for _, grain in ipairs(RLFeed.GRAINS) do
        local index = g_fillTypeManager:getFillTypeIndexByName(grain)
        local supported = index ~= nil and spec ~= nil and spec.supportedFillTypes ~= nil and spec.supportedFillTypes[index]
        if supported or grain == self.draft.grain then table.insert(self.grains, grain) end
    end

    -- false stands for AUTO (nil cannot sit in a list).
    self.shares = { false }
    local steps = math.floor(RLFeed.MAX_SHARE / RLFeedRationModel.SHARE_STEP + 0.5)
    local own = self.draft.share
    for i = 0, steps do
        -- Rounded, so 35 % is 0.35 and not 7 x 0.05.
        local share = math.floor(i * RLFeedRationModel.SHARE_STEP * 1000 + 0.5) / 1000
        if own ~= nil and own < share - 1e-6 and (i == 0 or own > share - RLFeedRationModel.SHARE_STEP + 1e-6) then
            table.insert(self.shares, own)
        end
        table.insert(self.shares, share)
    end
    self.substitutes = { true, false }
end


local function indexOf(list, value, same)
    for i, entry in ipairs(list) do
        if (same ~= nil and same(entry, value)) or entry == value then return i end
    end
    return 1
end


function RLFeedRationModel:getTargetIndex() return indexOf(self.targets, self.draft.target) end
function RLFeedRationModel:getGrainIndex() return indexOf(self.grains, self.draft.grain) end
function RLFeedRationModel:getShareIndex()
    return indexOf(self.shares, self.draft.share or false, function(a, b)
        if a == false or b == false then return a == b end
        return sameShare(a, b)
    end)
end
function RLFeedRationModel:getSubstituteIndex() return indexOf(self.substitutes, self.draft.substitute ~= false) end


function RLFeedRationModel:setTargetIndex(i) self.draft.target = self.targets[i] or self.draft.target end
function RLFeedRationModel:setGrainIndex(i) self.draft.grain = self.grains[i] or self.draft.grain end
function RLFeedRationModel:setShareIndex(i)
    local share = self.shares[i]
    if share == nil then return end
    self.draft.share = share ~= false and share or nil
end
function RLFeedRationModel:setSubstituteIndex(i)
    local value = self.substitutes[i]
    if value ~= nil then self.draft.substitute = value end
end


--- The pickers' texts.
function RLFeedRationModel:getTargetTexts()
    local texts = {}
    for i, target in ipairs(self.targets) do texts[i] = RLFeedInfoService.getTargetText(target) end
    return texts
end

function RLFeedRationModel:getGrainTexts()
    local texts = {}
    for i, grain in ipairs(self.grains) do texts[i] = RLFeedInfoService.getGrainText({ grain = grain }) end
    return texts
end

function RLFeedRationModel.formatShare(share)
    if share == nil or share == false then return getText("rl_feed_share_AUTO") end
    return string.format("%.0f%%", share * 100)
end

function RLFeedRationModel:getShareTexts()
    local texts = {}
    for i, share in ipairs(self.shares) do texts[i] = RLFeedRationModel.formatShare(share) end
    return texts
end

function RLFeedRationModel:getSubstituteTexts()
    return { getText("rl_feed_substitute_on"), getText("rl_feed_substitute_off") }
end


-- =============================================================================
-- Access, apply
-- =============================================================================

--- Whether the player may change this pen's ration now, and why not: the reason the pen cannot
--- run the model this hour (RLFeed.evaluatePen; a client's is the server's), NO_PERMISSION.
--- @return boolean editable
--- @return string reason
function RLFeedRationModel:getAccess()
    local state = RLFeedInfoService.getPenState(self.placeable)
    if not state.active then return false, state.reason or "UNKNOWN" end
    if RLPermissionHelper ~= nil and RLPermissionHelper.hasLocalPermission ~= nil
        and not RLPermissionHelper.hasLocalPermission("tradeAnimals") then
        return false, "NO_PERMISSION"
    end
    return true, "OK"
end


function RLFeedRationModel:isChanged()
    return not sameRation(self.draft, self.current)
end


--- Send the draft when it may be applied and differs from the pen's ration.
--- @return boolean sent
function RLFeedRationModel:apply()
    if not self:getAccess() or not self:isChanged() then return false end
    RLFeedRationEvent.sendEvent(self.placeable, copyRation(self.draft))
    return true
end


-- =============================================================================
-- Preview
-- =============================================================================

--- The draft's preview, worked out again when the draft, the hour or the trough's stock changes.
--- @return table|nil preview (RLFeedInfoService.previewRation), nil with an error key when it
---         cannot be worked out
--- @return string|nil error
function RLFeedRationModel:getPreview()
    local placeable = self.placeable
    local total = placeable.getTotalFood ~= nil and placeable:getTotalFood() or 0
    local key = string.format("%s|%s|%s|%s|%s|%.3f", self.draft.target, self.draft.grain, tostring(self.draft.share),
        tostring(self.draft.substitute), tostring(RLBodyCondition.getTickId()), total)
    if self.previewKey == key then return self.preview, self.previewError end
    local ok, preview, err = pcall(RLFeedInfoService.previewRation, placeable, self.draft)
    if not ok then
        RmLogging.getLogger("RLRM"):warning("RLFeedRationModel: preview failed in %s (%s)",
            placeable.getName ~= nil and placeable:getName() or "?", tostring(preview))
        preview, err = nil, "ERROR"
    end
    self.previewKey, self.preview, self.previewError = key, preview, err
    return preview, err
end


--- The preview as texts: the share line (target, now, once adapted, each with what limits it), the
--- intake line, and up to MAX_ROWS feed rows { title, perMonth, dmShare, stock, lasts }.
--- @return table { share, intake, rows, more (rows left out), empty (a text instead of rows) }
function RLFeedRationModel:getPreviewTexts()
    local preview, err = self:getPreview()
    local out = { rows = {}, more = 0 }
    if preview == nil then
        -- A pen's reason (a species off, sows or piglets) as its text; only a failed plan is an error.
        out.empty = (err ~= nil and err ~= "ERROR") and RLFeedInfoService.getReasonText(err) or getText("rl_feed_previewError")
        return out
    end

    local function shareWithLimit(share, limit)
        if share == nil then return "-" end
        return string.format("%.0f%% (%s)", share * 100, RLFeedInfoService.getLimitText(limit))
    end
    if self.draft.grain == "NONE" then
        out.share = string.format("%s: %s", getText("rl_feed_labelGrain"), RLFeedInfoService.getGrainText(self.draft))
    else
        out.share = string.format("%s %s · %s %s · %s %s", getText("rl_feed_previewTarget"), RLFeedRationModel.formatShare(self.draft.share),
            getText("rl_feed_previewNow"), shareWithLimit(preview.share, preview.limit),
            getText("rl_feed_previewAdapted"), shareWithLimit(preview.adaptedShare, preview.adaptedLimit))
    end

    if preview.animals == 0 then
        out.empty = getText("rl_feed_previewNoAnimals")
        return out
    end
    out.intake = string.format(getText("rl_feed_previewIntake"), preview.animals, preview.kgPerHeadDay,
        math.clamp(preview.coverage or 0, 0, 9.99) * 100)
    if (preview.calvesWithoutMilk or 0) > 0 then out.warning = string.format(getText("rl_feed_calfMilkNone"), preview.calvesWithoutMilk) end

    local function volume(liters)
        return g_i18n ~= nil and g_i18n.formatVolume ~= nil and g_i18n:formatVolume(liters, 0) or string.format("%.0f l", liters)
    end
    for i, row in ipairs(preview.rows) do
        if i > RLFeedRationModel.MAX_ROWS then
            out.more = #preview.rows - RLFeedRationModel.MAX_ROWS
            break
        end
        table.insert(out.rows, { name = row.name, title = row.title, perMonth = volume(row.perMonth),
            dmShare = string.format("%.0f%%", row.dmShare * 100), stock = volume(row.available),
            lasts = RLFeedInfoService.formatMonths(row.monthsLeft) })
    end
    if #out.rows == 0 then out.empty = getText("rl_feed_previewNoFeed") end
    return out
end

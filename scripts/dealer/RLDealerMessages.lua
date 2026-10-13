-- Dealer v2 T5: reasons the server or the client gives -> the player's sentence (an l10n key, with its
-- fallback text). The main flow never shows implementation words; the reason code is kept for the
-- diagnostics line. Unknown reasons fall back to a generic sentence, never to the raw code.
RLDealerMessages = {}
local M = RLDealerMessages

local table_ = {
    STALE_REVISION = "rl_dealer_v2_stale", SALE_NOT_LISTED = "rl_dealer_v2_stale", NOT_LISTED = "rl_dealer_v2_stale", SALE_LOCKED = "rl_dealer_v2_stale",
    STALE_SNAPSHOT = "rl_dealer_v2_stale",
    QUOTE_EXPIRED = "rl_dealer_v2_quote_expired", QUOTE_TIMEOUT = "rl_dealer_v2_quote_expired", SERVER_PRICE_CHANGED = "rl_dealer_v2_quote_expired",
    CAPACITY = "rl_dealer_v2_capacity", NO_CAPACITY = "rl_dealer_v2_capacity", DESTINATION_NOT_OWNED = "rl_dealer_v2_no_permission",
    NO_PERMISSION = "rl_dealer_v2_no_permission", NO_PLAYER_FARM = "rl_dealer_v2_no_permission",
    INSUFFICIENT_FUNDS = "rl_dealer_v2_funds",
    SOURCE_NOT_CURRENT = "rl_dealer_v2_updating", CURRENT_CLOCK_CHANGED = "rl_dealer_v2_updating",
    UNCERTAIN = "rl_dealer_v2_checking", RECOVERY_REQUIRED = "rl_dealer_v2_checking", PURCHASE_TIMEOUT = "rl_dealer_v2_checking",
    PENDING = "rl_dealer_v2_checking",
    DEALER_V2_DISABLED = "rl_dealer_v2_closed", MULTIPLAYER_NOT_VERIFIED = "rl_dealer_v2_closed",
    SELECTION_LIMIT = "rl_dealer_v2_limit",
}
M.FALLBACK = "rl_dealer_v2_generic"
M.KEYS = { "rl_dealer_v2_stale", "rl_dealer_v2_quote_expired", "rl_dealer_v2_capacity", "rl_dealer_v2_no_permission", "rl_dealer_v2_funds",
    "rl_dealer_v2_updating", "rl_dealer_v2_checking", "rl_dealer_v2_closed", "rl_dealer_v2_limit", "rl_dealer_v2_generic" }

--- The l10n key for a reason code. Capacity-type reasons that carry detail ("CAPACITY_UNSAFE:...") match on their head.
function M.key(reason)
    if type(reason) ~= "string" then return M.FALLBACK end
    if table_[reason] then return table_[reason] end
    local head = reason:match("^([A-Z_]+)")
    if head and table_[head] then return table_[head] end
    if reason:find("^CAPACITY") or reason:find("PROFILE") then return "rl_dealer_v2_capacity" end
    return M.FALLBACK
end

--- The sentence: g_i18n when present, the key itself never.
function M.text(reason)
    local key = M.key(reason)
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(key) then return g_i18n:getText(key) end
    return key
end

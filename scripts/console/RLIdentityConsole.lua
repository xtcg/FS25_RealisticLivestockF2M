--[[
    RLIdentityConsole.lua
    Commands of the animal identity ledger (RLAnimalIdentity*). Lines start with "RLIDENTITY" for grep.
      rlIdentityStatus          mode, state, generation, counts, shadow collisions (read-only)
      rlIdentityReport          what a switch to ON would find: per domain live keys, counters, reasons (read-only)
      rlIdentityActivate [accept]   switch the ledger on; `accept` takes the weaker MIGRATION_POINT guarantee
                                for domains whose counter history cannot be proven (server only)
      rlIdentityMode <OFF|SHADOW>   back to the old counters or to observing only (server only)
      rlIdentityRecoveryClear   after reading the evidence, leave RECOVERY_REQUIRED (server only)
]]

RLIdentityConsole = {}
local C = RLIdentityConsole
local Log = RmLogging.getLogger("RLRM")


local function say(text)
    Log:info("%s", text)
    return text
end


function C.status()
    local R, K = RLAnimalIdentityRuntime, RLAnimalIdentityCheckpoint
    local l = R.ledger
    local domains, keys = 0, 0
    if l ~= nil then
        for _ in pairs(l.domains) do domains = domains + 1 end
        for _ in pairs(l.keys) do keys = keys + 1 end
    end
    local sh = R.shadow
    local byEntry = {}
    for entry, n in pairs(sh.byEntry) do byEntry[#byEntry + 1] = entry .. "=" .. n end
    table.sort(byEntry)
    return say(string.format("RLIDENTITY STATUS mode=%s state=%s(%s) checkpoint=%s(%s) lineage=%s generation=%s committed=%s ledger=%s domains=%d keys=%d journal=%d shadow observed=%d collisions=%d [%s]",
        tostring(R.mode), tostring(R.state), tostring(R.reason), tostring(K.state), tostring(K.reason), tostring(K.lineage or R.lineage),
        tostring(K.generation), tostring(K.committed), l ~= nil and "yes" or "no", domains, keys, #R.journalKeys(),
        sh.observed, sh.collisions, table.concat(byEntry, " ")))
end


local function reportLines(report)
    local lines = {}
    for dk, d in pairs(report.domains) do
        local types = {}
        for t in pairs(d.types) do types[#types + 1] = t end
        table.sort(types)
        lines[#lines + 1] = string.format("RLIDENTITY DOMAIN %s status=%s live=%d maxNext=%d reasons=[%s] types=[%s]",
            dk, tostring(d.status), d.live, d.maxNext or 0, table.concat(d.reasons, ","), table.concat(types, ","))
    end
    table.sort(lines)
    local dups = 0
    for _ in pairs(report.duplicates) do dups = dups + 1 end
    local foreign = 0
    for _ in pairs(report.foreign) do foreign = foreign + 1 end
    lines[#lines + 1] = string.format("RLIDENTITY REPORT duplicates=%d placeholders=%d foreign=%d", dups, #report.placeholders, foreign)
    return lines
end


function C.report()
    local R = RLAnimalIdentityRuntime
    if not R.server then return "RLIDENTITY: server only" end
    local scan = RLAnimalIdentityWorld.scan(g_currentMission)
    local lines = reportLines(R.report(scan))
    for _, line in ipairs(lines) do say(line) end
    if #scan.partial > 0 then say("RLIDENTITY PARTIAL " .. table.concat(scan.partial, "; ")) end
    return string.format("%d records, %d counters; %d line(s) in the log", #scan.records, #scan.counters, #lines)
end


function C.activate(arg)
    local R, K = RLAnimalIdentityRuntime, RLAnimalIdentityCheckpoint
    if not R.server then return "RLIDENTITY: server only" end
    local scan = RLAnimalIdentityWorld.scan(g_currentMission)
    if #scan.partial > 0 then return say("RLIDENTITY: world scan partial, not activated: " .. table.concat(scan.partial, "; ")) end
    local ok, why, unproven, report = R.activate(scan, { accept = arg == "accept" })
    if not ok then
        if report ~= nil then for _, line in ipairs(reportLines(report)) do say(line) end end
        if why == "UNPROVEN_DOMAINS" then
            return say(string.format("RLIDENTITY: not activated - %d domain(s) have no provable counter history: %s. Run rlIdentityActivate accept to take the weaker guarantee (keys of animals that exist now are protected, older keys of sold or dead animals are not).",
                #unproven, table.concat(unproven, ", ")))
        end
        return say("RLIDENTITY: not activated: " .. tostring(why))
    end
    local armed, armWhy = K.arm()
    if not armed then return say("RLIDENTITY: switched on but the checkpoint did not arm: " .. tostring(armWhy)) end
    return say(string.format("RLIDENTITY: ON. %d live key(s) imported, %d domain(s) under the weaker guarantee. Save the game to make it permanent.", #scan.records, #unproven))
end


function C.mode(mode)
    local R = RLAnimalIdentityRuntime
    if not R.server then return "RLIDENTITY: server only" end
    mode = mode ~= nil and string.upper(mode) or nil
    local ok, why = R.setMode(mode)
    if not ok then return "RLIDENTITY: mode must be OFF or SHADOW (" .. tostring(why) .. ")" end
    return say("RLIDENTITY: mode " .. mode)
end


function C.recoveryClear()
    if not RLAnimalIdentityRuntime.server then return "RLIDENTITY: server only" end
    local ok, why = RLAnimalIdentityCheckpoint.recoveryClear()
    if not ok then return say("RLIDENTITY: " .. tostring(why)) end
    return say("RLIDENTITY: recovery cleared; the ledger as loaded is in use")
end


-- ---- dealer v2 channel (singleplayer cattle only) -------------------------------------------------
function C.dealerStatus()
    local D, K = RLDealerRuntime, RLDealerCheckpoint
    local ok, reason = D.gate()
    local listed, sources = 0, 0
    if D.store ~= nil then
        for _, row in pairs(D.store.listings.records) do if row.state == "LISTED" then listed = listed + 1 end end
        for _ in pairs(D.store.farm.sources) do sources = sources + 1 end
    end
    return say(string.format("RLDEALERV2 STATUS enabled=%s state=%s(%s) gate=%s(%s) checkpoint=%s(%s) generation=%s listed=%d sources=%d identity=%s",
        tostring(D.CHANNEL_ENABLED), tostring(D.state), tostring(D.reason), tostring(ok), tostring(reason), tostring(K.state), tostring(K.reason),
        tostring(K.generation), listed, sources, tostring(RLAnimalIdentityRuntime.authoritative())))
end

function C.dealerEnable()
    if not RLAnimalIdentityRuntime.server then return "RLDEALERV2: server only" end
    local ok, why = RLDealerRuntime.enable()
    if not ok then return say("RLDEALERV2: not enabled: " .. tostring(why)) end
    return say("RLDEALERV2: enabled for this session (singleplayer cattle). Save the game once so the first checkpoint verifies; purchases open after it.")
end

function C.dealerDisable()
    RLDealerRuntime.disable()
    return say("RLDEALERV2: disabled; stock, ledger and orders stay as they are")
end


-- ---- dealer v2 singleplayer test route (no GUI yet): list, detail, pens, quote, confirm, order ----------
local function service()
    local s = RLDealerRuntime.service
    if s == nil or s.localBrowse == nil then return nil, "RLDEALERV2: not enabled (rlDealerV2Enable)" end
    return s
end

function C.dealerList(cursor, sort)
    local s, why = service(); if not s then return why end
    local P = RLDealerCatalogProtocol
    local page = s.localBrowse(P.PAGE, { cursor = tonumber(cursor) or 0, pageSize = 20, sort = sort or "price" })
    if page.status ~= "OK" then return say("RLDEALERV2 LIST " .. tostring(page.status) .. " " .. tostring(page.reason)) end
    for _, r in ipairs(page.rows) do
        say(string.format("RLDEALERV2 ROW sale=%s rev=%d %s %s %s age=%dm w=%.1fkg parity=%d%s price=%.2f", r.saleId, r.revision, r.breed, r.gender, r.purpose,
            r.ageMonths, r.weightKg, r.parity, r.pregnant and " PREGNANT" or "", r.price))
    end
    return say(string.format("RLDEALERV2 LIST total=%d shown=%d next=%s snapshot=%s", page.total, #page.rows, tostring(page.nextCursor), tostring(page.snapshotSequence)))
end

function C.dealerDetail(saleId)
    local s, why = service(); if not s then return why end
    local P = RLDealerCatalogProtocol
    local page = s.localBrowse(P.PAGE, { pageSize = 50 })
    local revision
    for _, r in ipairs(page.rows or {}) do if r.saleId == saleId then revision = r.revision end end
    if revision == nil then return say("RLDEALERV2 DETAIL not listed: " .. tostring(saleId)) end
    local d = s.localBrowse(P.DETAIL, { saleId = saleId, revision = revision })
    return say("RLDEALERV2 DETAIL " .. RLTradePersistence.canonical(d))
end

function C.dealerPens(...)
    local s, why = service(); if not s then return why end
    local ids = { ... }
    if #ids == 0 then return "usage: rlDealerV2Pens <saleId> [saleId...]" end
    local r = s.localBrowse(RLDealerCatalogProtocol.DESTINATIONS, { saleIds = ids })
    if r.status ~= "OK" then return say("RLDEALERV2 PENS " .. tostring(r.status) .. " " .. tostring(r.reason)) end
    for _, d in ipairs(r.destinations) do
        say(string.format("RLDEALERV2 PEN ref=%s name=%s free=%d usable=%s %s", d.ref, tostring(d.name), d.freeSlots, tostring(d.usable), d.reason or ""))
    end
    return "RLDEALERV2 PENS " .. #r.destinations
end

function C.dealerQuote(destination, ...)
    local s, why = service(); if not s then return why end
    local ids = { ... }
    if destination == nil or #ids == 0 then return "usage: rlDealerV2Quote <penRef> <saleId> [saleId...]" end
    local page = s.localBrowse(RLDealerCatalogProtocol.PAGE, { pageSize = 50 })
    local revisions = {}
    for _, r in ipairs(page.rows or {}) do revisions[r.saleId] = r.revision end
    local items = {}
    for _, id in ipairs(ids) do
        if revisions[id] == nil then return say("RLDEALERV2 QUOTE not listed: " .. id) end
        items[#items + 1] = { saleId = id, revision = revisions[id] }
    end
    local quote, failure = s.localQuote({ destination = destination, items = items })
    if not quote then return say("RLDEALERV2 QUOTE refused: " .. tostring(failure) .. " (" .. RLDealerMessages.text(failure) .. ")") end
    C.lastQuote = { destination = destination, items = items, credential = quote.credential }
    return say(string.format("RLDEALERV2 QUOTE animals=%d subtotal=%.2f transport=%.2f total=%.2f valid=%dms - confirm with rlDealerV2Confirm", #items,
        quote.subtotal, quote.transportFee, quote.amount, quote.ttlMs or 0))
end

function C.dealerConfirm()
    local s, why = service(); if not s then return why end
    local q = C.lastQuote
    if q == nil then return "RLDEALERV2: no quote; use rlDealerV2Quote first" end
    C.orderSeq = (C.orderSeq or 0) + 1
    local requestId = string.format("console-%s-%d", tostring(RLAnimalIdentityCheckpoint.lineage or "x"), C.orderSeq)
    local result, failure = s.localExecute({ requestId = requestId, destination = q.destination, items = q.items, quoteCredential = q.credential })
    C.lastQuote = nil
    C.lastOrder = requestId
    if not result then return say("RLDEALERV2 ORDER " .. requestId .. " refused: " .. tostring(failure) .. " (" .. RLDealerMessages.text(failure) .. ")") end
    return say(string.format("RLDEALERV2 ORDER %s %s amount=%.2f", requestId, result.status, result.amount or 0))
end

function C.dealerOrder(requestId)
    local s, why = service(); if not s then return why end
    requestId = requestId or C.lastOrder
    if requestId == nil then return "usage: rlDealerV2Order <orderId>" end
    local result, failure = s.localLookup(requestId)
    if not result then return say("RLDEALERV2 ORDER " .. requestId .. " " .. tostring(failure)) end
    return say(string.format("RLDEALERV2 ORDER %s %s amount=%s", requestId, result.status, tostring(result.amount)))
end


-- ---- evidence for the test cards: one line per live key and per ledger key, and the money of the host farm ----
function C.dump()
    local R = RLAnimalIdentityRuntime
    if not R.server then return "RLIDENTITY: server only" end
    local scan = RLAnimalIdentityWorld.scan(g_currentMission)
    for _, r in ipairs(scan.records) do
        say(string.format("RLIDENTITY LIVE %s %s %s %s", tostring(r.farmId), tostring(r.uniqueId), tostring(r.country), tostring(r.where)))
    end
    local ledgerKeys = 0
    if R.ledger ~= nil then
        for key, rec in pairs(R.ledger.keys) do
            ledgerKeys = ledgerKeys + 1
            say(string.format("RLIDENTITY LEDGER %s %s", key, rec.state))
        end
    end
    local farm = g_farmManager:getFarmById(g_currentMission:getFarmId())
    say(string.format("RLIDENTITY DUMP live=%d ledger=%d mode=%s generation=%s money=%.2f", #scan.records, ledgerKeys, tostring(R.mode),
        tostring(RLAnimalIdentityCheckpoint.generation), farm ~= nil and farm.money or -1))
    return string.format("%d live keys, %d ledger keys; see the log", #scan.records, ledgerKeys)
end

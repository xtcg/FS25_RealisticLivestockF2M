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

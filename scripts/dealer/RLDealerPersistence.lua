-- Dealer stock checkpoint document. Integrity is corruption detection, NOT atomic
-- source/target/money ownership. Every game participant must provide matching markers.
RLDealerPersistence = {}
local D = RLDealerPersistence
D.VERSION, D.SCHEMA = 1, 1
D.FILENAME, D.ROOT = "rm_RlDealerStockCheckpoint.xml", "rlDealerStockCheckpoint"
D.LIMITS = { maxNodes = 400000, maxString = 262144, maxDepth = 32 }
D.MAX_ENCODED_BYTES = 32 * 1024 * 1024
D.REQUIRED_PARTICIPANTS = { "placeables", "vehicles", "farms" }
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function integer(v) return finite(v) and v >= 0 and v % 1 == 0 end
local function str(v) return type(v) == "string" and #v > 0 and #v <= 4096 end
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local function exactKeys(t, allowed)
    if type(t) ~= "table" then return false end
    for k in pairs(t) do if not allowed[k] then return false end end
    return true
end
local snapshotKeys = { version=true, scope=true, lineage=true, generation=true, parentGeneration=true,
    checkpointId=true, clock=true, listings=true, sources=true, purchase=true, participants=true, sourceOwnership=true }
local markerKeys = { lineage=true, generation=true, checkpointId=true, digest=true }
local function header(s)
    return s.version == D.VERSION and s.scope == "DEALER_STOCK_ONLY" and str(s.lineage)
        and s.lineage:match("^DL[%w%-]+$") ~= nil and integer(s.generation) and s.generation >= 1
        and integer(s.parentGeneration) and s.parentGeneration == s.generation - 1 and str(s.checkpointId)
        and s.checkpointId == s.lineage .. ":" .. tostring(s.generation)
end
function D.marker(lineage, generation, participantData)
    if not str(lineage) or not lineage:match("^DL[%w%-]+$") or not integer(generation) or generation < 1
        or RLTradePersistence.check(participantData, D.LIMITS) then return nil, "BAD_PARTICIPANT" end
    return { lineage=lineage, generation=generation, checkpointId=lineage .. ":" .. tostring(generation),
        digest=RLTradePersistence.checksum(RLTradePersistence.canonical(participantData)) }
end
local function markerOK(marker, s)
    return exactKeys(marker, markerKeys) and marker.lineage == s.lineage and marker.generation == s.generation
        and marker.checkpointId == s.checkpointId and type(marker.digest) == "string"
        and #marker.digest == 16 and marker.digest:match("^%x+$") ~= nil
end
-- Actual markers must be read from placeables.xml, vehicles.xml and farms.xml,
-- not copied from this document. No invented source/target participant files.
function D.validateParticipants(snapshot, actual)
    if type(actual) ~= "table" or RLTradePersistence.check(actual, D.LIMITS) then return nil, "PARTICIPANTS_REQUIRED" end
    if type(snapshot) ~= "table" or type(snapshot.participants) ~= "table" then return nil, "BAD_PARTICIPANTS" end
    for _, role in ipairs(D.REQUIRED_PARTICIPANTS) do
        if snapshot.participants[role] == nil then return nil, "MISSING_PARTICIPANT:" .. role end
    end
    local whitelist = { placeables=true, vehicles=true, farms=true }
    for role, marker in pairs(snapshot.participants) do
        if not whitelist[role] then return nil, "UNKNOWN_PARTICIPANT:" .. tostring(role) end
        if not str(role) or not markerOK(marker, snapshot) then return nil, "BAD_PARTICIPANT:" .. tostring(role) end
        local other = actual[role]
        if not markerOK(other, snapshot) or other.digest ~= marker.digest then return nil, "PARTICIPANT_MISMATCH:" .. role end
    end
    for role in pairs(actual) do if snapshot.participants[role] == nil then return nil, "UNEXPECTED_PARTICIPANT:" .. tostring(role) end end
    return true
end
function D.validateSnapshot(s, actualParticipants, resolver, ownershipContext)
    local why = RLTradePersistence.check(s, D.LIMITS)
    if why then return nil, "BAD_SNAPSHOT:" .. why end
    if not exactKeys(s, snapshotKeys) or not header(s) then return nil, "BAD_SNAPSHOT_HEADER" end
    local clock; clock, why = RLDealerClock.restore(s.clock); if not clock then return nil, "CLOCK:" .. tostring(why) end
    local listings; listings, why = RLDealerListingRegistry.restore(s.listings)
    if not listings then return nil, "LISTINGS:" .. tostring(why) end
    local purchase; purchase, why = RLDealerPurchase.import(s.purchase)
    if not purchase then return nil, "PURCHASE:" .. tostring(why) end
    if type(s.sources) ~= "table" then return nil, "BAD_SOURCES" end
    local restoredSources = {}
    for id, record in pairs(s.sources) do
        if not str(id) then return nil, "BAD_SOURCE_ID" end
        local ok, reason = RLDealerSourceState.validate(record)
        if not ok then return nil, "SOURCE:" .. id .. ":" .. tostring(reason) end
        if record.cursorMonths > clock.months + 1e-8 then return nil, "SOURCE_FUTURE_CURSOR:" .. id end
        if resolver ~= nil then
            local restored, failure = RLDealerSourceState.restore(record, resolver)
            if not restored then return nil, "SOURCE_RESOLVE:" .. id .. ":" .. tostring(failure.reason) end
            restoredSources[id] = restored
        end
    end
    for id, listing in pairs(s.listings.records) do
        if listing.lastUpdatedAtMonths > clock.months + 1e-8 then return nil, "LISTING_FUTURE_CURSOR:" .. id end
        local sourceId = listing.payload.sourceId
        local retired=type(s.sourceOwnership)=="table" and type(s.sourceOwnership.retiredSources)=="table"
            and s.sourceOwnership.retiredSources[sourceId] or nil
        if sourceId ~= nil and (not str(sourceId) or (s.sources[sourceId] == nil and listing.state ~= "SOLD"
            and not (type(retired)=="table" and (listing.state=="WITHDRAWN" or listing.state=="QUARANTINED")))) then return nil, "LISTING_SOURCE_MISSING:" .. id end
        if sourceId ~= nil and s.sources[sourceId] ~= nil then
            local sourceCursor = s.sources[sourceId].cursorMonths
            if listing.lastProgressedAtMonths > sourceCursor or
                ((listing.state == "LISTED" or listing.state == "RESERVED") and listing.lastProgressedAtMonths ~= sourceCursor) then
                return nil, "LISTING_SOURCE_CURSOR:" .. id
            end
        end
    end
    for requestId, transaction in pairs(s.purchase.records) do
        if transaction.context.currentClock > clock.months + 1e-8 then return nil, "PURCHASE_FUTURE_CURSOR:" .. requestId end
        for _, item in ipairs(transaction.request.items) do
            local listing = s.listings.records[item.saleId]
            if listing == nil then return nil, "PURCHASE_LISTING_MISSING:" .. item.saleId end
            if transaction.stage == "COMMITTED" and (listing.state ~= "SOLD" or listing.soldRequestId ~= requestId) then
                return nil, "PURCHASE_SOLD_MISMATCH:" .. item.saleId
            end
            if listing.state == "SOLD" and listing.soldRequestId == requestId and transaction.stage == "ROLLED_BACK" then
                return nil, "PURCHASE_ROLLBACK_MISMATCH:" .. item.saleId
            end
        end
    end
    local owned, ownedResolution
    if s.sourceOwnership ~= nil then
        if RLDealerOwnedStock == nil then return nil, "OWNED_STOCK_CAPABILITY" end
        owned, why = RLDealerOwnedStock.validate(s.sourceOwnership, s.sources, clock.months)
        if not owned then return nil, why end
        ownedResolution = "NOT_CHECKED"
        if resolver ~= nil and ownershipContext ~= nil then
            owned, why = RLDealerOwnedStock.restore(s.sourceOwnership, s.sources, clock.months, resolver, ownershipContext)
            if not owned then return nil, "OWNED_STOCK_RESOLVE:" .. tostring(why) end
            ownedResolution = "RESOLVED"
        end
    end
    local verified; verified, why = D.validateParticipants(s, actualParticipants)
    if not verified then return nil, why end
    return { clock=clock, listings=listings, purchase=purchase, sources=copy(s.sources), restoredSources=restoredSources,
        ownedStock=owned, ownershipResolution=ownedResolution,
        recoveryRequired=purchase.recoveryRequired or (owned and owned.recoveryRequired == true)
            or #RLDealerListingRegistry.listRecords(listings,"QUARANTINED") > 0 }
end
-- capture takes authoritative participant stores, never animals from a client.
function D.capture(meta, clock, listings, sources, purchase, participantMarkers, sourceOwnership)
    if type(meta) ~= "table" then return nil, "BAD_META" end
    local raw = { version=D.VERSION, scope="DEALER_STOCK_ONLY", lineage=meta.lineage,
        generation=meta.generation, parentGeneration=meta.parentGeneration, checkpointId=meta.checkpointId,
        clock=clock, listings=listings, sources=sources, purchase=purchase, participants=participantMarkers,
        sourceOwnership=sourceOwnership }
    local why = RLTradePersistence.check(raw,D.LIMITS)
    if why then return nil,"BAD_SNAPSHOT:" .. why end
    local s = copy(raw)
    local valid; valid, why = D.validateSnapshot(s, participantMarkers)
    if not valid then return nil,why end
    return s
end
local function quarantine(reason, raw)
    return nil, reason, { state="QUARANTINED", scope="DEALER_STOCK_ONLY", reason=reason, raw=raw }
end
function D.writeDocument(xml, snapshot, actualParticipants)
    local validated, why = D.validateSnapshot(snapshot,actualParticipants)
    if not validated then return nil,why end
    local canonical = RLTradePersistence.canonical(snapshot)
    local encoded = RLTradePersistence.encodeText(canonical)
    if #encoded > D.MAX_ENCODED_BYTES then return nil,"DOCUMENT_TOO_LARGE" end
    local digest = RLTradePersistence.checksum(canonical)
    -- Fresh XMLFile is required: reusing a document can retain stale chunk nodes.
    xml:setString(D.ROOT .. "#schema",tostring(D.SCHEMA))
    xml:setString(D.ROOT .. "#lineage",snapshot.lineage)
    xml:setString(D.ROOT .. "#generation",tostring(snapshot.generation))
    xml:setString(D.ROOT .. "#checkpointId",snapshot.checkpointId)
    xml:setString(D.ROOT .. "#digest",digest)
    xml:setString(D.ROOT .. ".data#length",tostring(#encoded))
    local index=0
    for start=1,#encoded,RLTradePersistence.CHUNK do
        xml:setString(string.format("%s.data.chunk(%d)#v",D.ROOT,index),encoded:sub(start,start+RLTradePersistence.CHUNK-1))
        index=index+1
    end
    return true,digest
end
-- Career marker is written only after the complete game save pass. The dealer
-- document digest is external to its own payload, avoiding a self-hash cycle.
function D.commitMarker(snapshot, documentDigest)
    if type(snapshot) ~= "table" or RLTradePersistence.check(snapshot,D.LIMITS) or not header(snapshot)
        or not D.validateParticipants(snapshot,snapshot.participants) or type(documentDigest) ~= "string"
        or #documentDigest ~= 16 or not documentDigest:match("^%x+$") then return nil,"BAD_COMMIT_MARKER" end
    return { lineage=snapshot.lineage, generation=snapshot.generation, checkpointId=snapshot.checkpointId,
        dealerStockDigest=documentDigest, participantsDigest=RLTradePersistence.checksum(RLTradePersistence.canonical(snapshot.participants)) }
end
function D.validateCommit(snapshot, documentDigest, careerMarker)
    local expected,why=D.commitMarker(snapshot,documentDigest)
    if not expected then return nil,why end
    if type(careerMarker) ~= "table" or RLTradePersistence.check(careerMarker,D.LIMITS) then return nil,"CAREER_COMMIT_REQUIRED" end
    if RLTradePersistence.canonical(expected) ~= RLTradePersistence.canonical(careerMarker) then return nil,"CAREER_COMMIT_MISMATCH" end
    return true
end
function D.readDocument(xml, actualParticipants, resolver, careerMarker, ownershipContext)
    local raw = { schema=xml:getString(D.ROOT .. "#schema"), lineage=xml:getString(D.ROOT .. "#lineage"),
        generation=xml:getString(D.ROOT .. "#generation"), checkpointId=xml:getString(D.ROOT .. "#checkpointId"),
        digest=xml:getString(D.ROOT .. "#digest"), encoded="" }
    local parts, size, overflow = {},0,false
    xml:iterate(D.ROOT .. ".data.chunk",function(_,key)
        local part=xml:getString(key .. "#v")
        if type(part) ~= "string" then overflow=true; return end
        size=size+#part
        if size > D.MAX_ENCODED_BYTES then overflow=true; return end
        parts[#parts+1]=part
    end)
    raw.encoded=table.concat(parts)
    if overflow then return quarantine("DOCUMENT_TOO_LARGE_OR_MISSING_CHUNK",raw) end
    if tonumber(raw.schema) ~= D.SCHEMA then return quarantine("UNKNOWN_SCHEMA",raw) end
    if tonumber(xml:getString(D.ROOT .. ".data#length")) ~= #raw.encoded then return quarantine("BAD_LENGTH",raw) end
    local text=RLTradePersistence.decodeText(raw.encoded)
    if not text then return quarantine("BAD_ENCODING",raw) end
    if RLTradePersistence.checksum(text) ~= raw.digest then return quarantine("DIGEST_MISMATCH",raw) end
    local s,why=RLTradePersistence.parse(text,D.LIMITS)
    if not s then return quarantine("BAD_DATA:" .. tostring(why),raw) end
    if s.version ~= D.VERSION then return quarantine("UNKNOWN_SNAPSHOT_VERSION",raw) end
    if s.lineage ~= raw.lineage or s.generation ~= tonumber(raw.generation) or s.checkpointId ~= raw.checkpointId then return quarantine("HEADER_MISMATCH",raw) end
    local restored; restored,why=D.validateSnapshot(s,actualParticipants,resolver,ownershipContext)
    if not restored then return quarantine(why,raw) end
    local committed; committed,why=D.validateCommit(s,raw.digest,careerMarker)
    if not committed then return quarantine(why,raw) end
    return { state="VERIFIED", data=s, restored=restored, digest=raw.digest,
        sourceResolution=resolver ~= nil and "RESOLVED" or "NOT_CHECKED" }
end

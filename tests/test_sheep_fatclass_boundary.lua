-- SHEEP-FATCLASS-BOUNDARY-01: a ewe lamb's reserve 0.49999996 was saved and read back as 0.5, so
-- her fat class flipped 3L -> 3H across a reload (3H starts at 0.50) and the meat yield could follow.
-- Every reading now uses the reserve on a 1e-6 grid (RLBodyCondition.getReserve), the savegame and
-- the stream carry that value, and the model's own step keeps its unrounded number. Stable on both
-- sides of 0.5, over repeated reloads and repeated quotes.

loadMod("tests/sheepsim.lua")

local B = RLBodyCondition

FeedSim.setMode(true)
SheepSim.enable(true)
GrowthSim.setDaysPerPeriod(1)

-- The engine's savegame float: single precision.
local function float32(v) return string.unpack("f", string.pack("f", v)) end
local function xmlStore()
    local store = {}
    return {
        setFloat = function(_, k, v) store[k] = float32(v) end, setInt = function(_, k, v) store[k] = v end,
        setString = function(_, k, v) store[k] = v end,
        getFloat = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
        getInt = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
        getString = function(_, k, d) local v = store[k]; if v == nil then return d end return v end,
    }
end

local function reading(animal)
    return { fat = B.getFatClass(animal), reserve = B.getReserve(animal), score = B.getFinishScore(animal),
        yield = B.getYieldFactor(animal), market = B.getMarketFactor(animal), text = (B.getInfoText(animal)) }
end
local function same(a, b)
    return a.fat == b.fat and a.reserve == b.reserve and a.score == b.score and a.yield == b.yield and a.market == b.market and a.text == b.text
end

local lamb = SheepSim.grown("SHEEP_LANDRACE", "FB1", 5)
SheepSim.makePen({ lamb }, { GRASS_WINDROW = 3000 })
B.ensureState(lamb, "legacy")

check("boundary: the quantum is 1e-6 and quantizing twice changes nothing",
    B.RESERVE_QUANTUM == 1e-6 and B.quantizeReserve(B.quantizeReserve(0.123456789)) == B.quantizeReserve(0.123456789)
    and B.quantizeReserve(0.49999996) == 0.5 and B.quantizeReserve(0.4999994) == 0.499999)

for _, case in ipairs({ { 0.49999996, "3H" }, { 0.5, "3H" }, { 0.50000004, "3H" }, { 0.4999994, "3L" }, { 0.499999, "3L" },
    { 0.3799999996, "3L" }, { 0.37999949, "2" } }) do
    local raw, expected = case[1], case[2]
    lamb.bodyCondition.reserve = raw
    local live = reading(lamb)
    local stable, reads = true, {}
    local state = lamb.bodyCondition
    for i = 1, 5 do
        local xml = xmlStore()
        B.saveToXMLFile(state, xml, "a")
        state = B.loadFromXMLFile(xml, "a")
        lamb.bodyCondition = state
        reads[i] = reading(lamb)
        stable = stable and same(reads[i], live)
    end
    -- A quote is a reading: asking again changes nothing.
    local quotes = { reading(lamb), reading(lamb) }
    check(string.format("boundary: reserve %.10g is fat class %s live and after 5 reloads, yield %.6f, quotes repeat (got %s / %s)",
        raw, expected, live.yield, tostring(live.fat), tostring(reads[5].fat)),
        live.fat == expected and stable and same(quotes[1], live) and same(quotes[2], live))
    lamb.bodyCondition = { version = B.STATE_VERSION, reserve = raw, capacityKg = state.capacityKg, balanceEMA = 0, lossRateEMA = 0,
        lastTick = -1, source = "legacy" }
end

-- The stream carries the same canonical value (a client shows what the server classifies).
do
    lamb.bodyCondition.reserve = 0.49999996
    local stream, readAt = {}, 0
    streamWriteBool = function(_, v) stream[#stream + 1] = v end
    streamWriteFloat32 = function(_, v) stream[#stream + 1] = float32(v) end
    streamWriteInt32 = function(_, v) stream[#stream + 1] = v end
    local function r() readAt = readAt + 1; return stream[readAt] end
    streamReadBool, streamReadFloat32, streamReadInt32 = r, r, r
    local server = reading(lamb)
    B.writeStream(lamb.bodyCondition, 1)
    local client = SheepSim.grown("SHEEP_LANDRACE", "FB2", 5)
    SheepSim.makePen({ client }, { GRASS_WINDROW = 3000 })
    client.bodyCondition = B.readStream(1)
    check("boundary: a client reads the fat class the server shows", same(reading(client), server) and server.fat == "3H")
end

-- The model's step keeps the unrounded reserve: only readings, the savegame and the stream round.
do
    lamb.bodyCondition.reserve = 0.4999999612
    check("boundary: the live state keeps its own unrounded reserve", lamb.bodyCondition.reserve == 0.4999999612 and B.getReserve(lamb) == 0.5)
end

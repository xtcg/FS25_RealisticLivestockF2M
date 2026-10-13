-- Dealer v2 T3: the generation random stream. A job gets its own stream from a persistent job id and
-- an attempt number, so generation never shares math.random with the game, a retry of the same
-- attempt draws the same numbers, and a new attempt draws new ones. Park-Miller (exact in doubles,
-- Lua 5.1 safe); not for anything but picking stock.
RLDealerRng = {}
local G = RLDealerRng
local M, A = 2147483647, 48271

local function seedFrom(text)
    local h = RLTradePersistence.checksum(text)
    local n = tonumber(h:sub(1, 7), 16) or 1
    n = n % (M - 1) + 1
    return n
end

function G.new(label)
    local self = { state = seedFrom(tostring(label)), draws = 0 }
    local function step()
        self.state = (self.state * A) % M
        self.draws = self.draws + 1
        return self.state
    end
    -- random(): float in (0,1); random(m): 1..m; random(m, n): m..n (math.random's contract)
    function self.random(m, n)
        local u = step() / M
        if m == nil then return u end
        if n == nil then m, n = 1, m end
        if n < m then error("interval is empty", 2) end
        return m + math.floor(u * (n - m + 1))
    end
    function self.getState() return { state = self.state, draws = self.draws } end
    return self
end


--- Run fn with math.random replaced by the stream, restoring it on every exit. For game functions that
--- draw from the global stream (birth weight, genetics) and must not touch it from the dealer.
function G.with(rng, fn)
    local saved = math.random
    math.random = rng.random
    local ok, a, b, c = pcall(fn)
    math.random = saved
    if not ok then error(a, 0) end
    return a, b, c
end

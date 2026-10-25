-- Shared production invariants. Numerical/species-specific cash-flow assertions
-- stay in test_marketcattle/pig/sheep; these are independent contract checks.
loadMod("tests/fixtures/market_production.lua")
local F,D=MarketProductionFixture,RLMarketData
for _,member in ipairs(RLSpeciesCatalog.marketMembers()) do
    local model=_G[member.marketModel]
    local function fixture()return F.snapshot(member.key),F.input() end
    local s,input=fixture()
    local before=assert(D.fingerprint({s,input}))
    local base=assert(model.evaluate(s,"TERMINAL",input))
    check("market contract: finite nonnegative reference "..member.key,type(base.referenceValue)=="number" and base.referenceValue>=0 and base.referenceValue<math.huge)
    check("market contract: inputs unchanged "..member.key,D.fingerprint({s,input})==before)
    local savedMission,savedRandom=g_currentMission,math.random
    g_currentMission=nil;math.random=function()error("production must be deterministic")end
    local okay,value=pcall(model.evaluate,s,"TERMINAL",input)
    g_currentMission,math.random=savedMission,savedRandom
    check("market contract: pure and deterministic "..member.key,okay and value and D.fingerprint(value)==D.fingerprint(base))
    for _,objective in ipairs({"TERMINAL","MATERNAL"}) do
        s,input=fixture();s.genes.fertility=0
        check("market contract: infertile excluded "..member.key..objective,model.evaluate(s,objective,input)==nil)
        s,input=fixture();s.castrated=true
        check("market contract: castrated excluded "..member.key..objective,model.evaluate(s,objective,input)==nil)
    end
    s,input=fixture();input.costBasis=nil
    check("market contract: unknown cost is not free "..member.key,model.evaluate(s,"TERMINAL",input)==nil)
    s,input=fixture();s.speciesKey="GOAT"
    check("market contract: no cross-species fallback "..member.key,model.evaluate(s,"TERMINAL",input)==nil)
    s,input=fixture();input.params.exitAge=s.ageMonths-1
    check("market contract: exit age excludes breeding "..member.key,model.evaluate(s,"MATERNAL",input)==nil)
end

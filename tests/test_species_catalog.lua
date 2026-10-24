loadMod("tests/feedsim.lua")
loadMod("tests/fixtures/market_production.lua")
loadMod("scripts/market/RLMarketSpecies.lua")
local C=RLSpeciesCatalog
local registry=RLAnimalValueProvider.new()
assert(RLMarketProviders.register(registry))
local seen={}
for _,member in ipairs(C.members()) do
    check("species catalog: unique member "..member.key,not seen[member.key])
    seen[member.key]=true
    -- Shipped nutrition sections must match membership. This reads the actual
    -- parsers rather than asserting that two copies of a manifest are equal.
    local feed=RLFeedProfiles.getConfig()
    local body=RLBodyConditionConfig.get()
    if member.configKey~="COW" and member.key~="MILKCOW" then
        check("species catalog: feed section "..member.key,feed.species and feed.species[member.configKey]~=nil)
        check("species catalog: body section "..member.key,body.species and body.species[member.configKey]~=nil)
    end
    if member.weightBinding then
        local binding=RLWeightProfiles.getBinding(member.engineType)
        check("species catalog: map curve binding "..member.key,binding and binding.profile==member.weightBinding)
    elseif member.weightType~="COW" then
        check("species catalog: weight type "..member.key,RLWeightProfiles.getTypeEntry(member.weightType)~=nil)
    end
    local original=member.configKey;member.configKey="MUTATED"
    check("species catalog: returned rows isolated "..member.key,C.get(member.key).configKey==original)
end
check("species catalog: unknown member is not admitted",C.get("NEW_SPECIES")==nil)
check("species catalog: goat remains distinct in market",C.marketKey("SHEEP","GOAT")=="GOAT")
check("species catalog: nutrition uses policy, not breed spelling",C.configKey("SHEEP","DAIRY_GOAT")=="GOAT" and C.configKey("SHEEP","MEAT")=="SHEEP")
for _,member in ipairs(C.members()) do
    if not member.marketModel then
        local s=MarketProductionFixture.snapshot(member.key)
        local value,reason=registry:evaluate(s,MarketProductionFixture.context(s,MarketProductionFixture.input()))
        check("species catalog: no borrowed market provider "..member.key,value==nil and reason=="UNSUPPORTED")
    end
end
for _,package in ipairs(C.packages()) do
    local o={allowedProductionClasses=package.kind=="cattleLactating" and {"DAIRY"} or {"BEEF"},
        requiredBreedId=package.species..":TEST",breedingObjective="MATERNAL",finishingStages={"FINISHING"},
        breedingStages={"BREEDING_READY"},indexWeights={fertility=.6,health=.4}}
    if package.group=="GROWER" then o.requiredBreedId=nil end
    local raw=assert(RLBrokerConditionPackage.candidate(package.kind,o))
    local compiled=assert(RLBrokerConditionPackage.compile(raw))
    check("species catalog: executable package "..package.kind,compiled.speciesKey==package.species and compiled.purposeGroup==package.group)
end

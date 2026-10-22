-- Deliberately synthetic contract fixtures, never a U51 model admission report.
-- Month publication requires allowTestCatalog=true to use this catalog.
loadMod("scripts/market/RLMarketData.lua")
loadMod("scripts/market/RLMarketMoney.lua")
loadMod("scripts/market/RLMarketCurve.lua")
loadMod("scripts/market/RLMarketConfig.lua")
loadMod("scripts/market/RLBrokerConditionPackage.lua")
loadMod("scripts/market/RLBrokerDemand.lua")
BrokerDemandFixture={}
local F=BrokerDemandFixture
function F.copy(v)return assert(RLMarketData.copy(v))end
function F.balance()
    return assert(RLMarketConfig.parse(assert(loadXMLFileFromDisk(REPO.."xml/livestockMarket.xml")))).brokerBalance
end
function F.entry(kind,species,breed,scope,tier)
    local options={id=kind..":"..breed..":"..scope..":"..tier,allowedProductionClasses={"BEEF"},
        breedScope=scope,requiredBreedId=scope=="SPECIFIC" and species..":"..breed or nil,breedingObjective="MATERNAL",tier=tier,
        finishingStages={"FINISHING"},breedingStages={"BREEDING_READY"},indexWeights={fertility=.6,health=.4}}
    local p=assert(RLBrokerConditionPackage.compile(assert(RLBrokerConditionPackage.candidate(kind,options))))
    return {speciesKey=species,breedId=species..":"..breed,package=p,packageRevision=p.revision,verified=true,
        verificationType="MODEL_REACHABILITY",evidenceRef="fixture-only:not-a-real-model-report:"..p.id,
        classRevision="classes:1",traitMappingRevision="traits:1",formulaVersion="formula:1",priceRevision="prices:1",
        priceBasis={basisId="fixture-only:basis",currencyBasis="CURRENT",assumptions={station="fixture-only"}}}
end
function F.catalog()
    local entries={}
    local kinds={COW={"cattleStore","cattleFinished","cattleReplacement","cattleSire"},
        SHEEP={"lambGrower","lambFinished","eweReplacement","ramSire"},PIG={"pigGrower","pigFinished","pigReplacement","pigSire"}}
    for _,species in ipairs({"COW","SHEEP","PIG"})do
        for _,breed in ipairs({"ALPHA","BETA","GAMMA","DELTA"})do
            for _,kind in ipairs(kinds[species])do
                local grower=kind=="cattleStore" or kind=="lambGrower" or kind=="pigGrower"
                entries[#entries+1]=F.entry(kind,species,breed,"SPECIFIC","standard")
                if grower then entries[#entries+1]=F.entry(kind,species,breed,"ANY","standard") end
                if kind=="cattleSire" or kind=="ramSire" or kind=="pigSire" then entries[#entries+1]=F.entry(kind,species,breed,"SPECIFIC","elite") end
            end
        end
    end
    return {schemaVersion=1,configRevision="test-config:1",calendarOriginMonth=1,testOnly=true,entries=entries}
end

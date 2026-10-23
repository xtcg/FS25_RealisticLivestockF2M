loadMod("tests/fixtures/market_production.lua")
local F=MarketProductionFixture
local registry=RLAnimalValueProvider.new()
assert(RLMarketProviders.register(registry))
local s,i=F.snapshot("COW"),F.input()
local context=F.context(s,i)
local commodity=assert(registry:evaluate(s,context))
check("providers: explicit commodity registration with real missing/zero semantics",commodity.commodityValue==100 and commodity.productionReference==nil and not commodity.capabilities.breeding)
context.breedingObjective="DAIRY"
local production=assert(registry:evaluate(s,context))
check("providers: separate raw reference and objective breakdown",production.productionReference==230 and production.breeding.byObjective.DAIRY.ownDelta==0)
context.referenceInputs.production.params.offspringBaseNet=nil
local unsupported,why=registry:evaluate(s,context)
check("providers: missing calibrated economics is unsupported with reason",unsupported==nil and why=="MISSING_PRODUCTION_offspringBaseNet")
context=F.context(s,F.input());context.referenceInputs.stateRevision="stale"
unsupported,why=registry:evaluate(s,context)
check("providers: cannot reuse another animal-state reference",unsupported==nil and why=="REFERENCE_SCOPE_MISMATCH")
s.speciesKey="GOAT"
unsupported,why=registry:evaluate(s,F.context(s,F.input()))
check("providers: goat stays unregistered rather than borrowing sheep",unsupported==nil and why=="UNSUPPORTED")
-- Actual shipped curves -> detached inputs. The adapter does not manufacture the
-- missing production costs, litter economics or breeder service scale.
loadMod("tests/breedingvalue_fixture.lua")
loadMod("scripts/core/RLConstants.lua")
loadMod("scripts/animal/RLAnimalIdentity.lua")
loadMod("scripts/dealer/RLDealerStockPolicy.lua")
loadMod("scripts/market/RLMarketSpecies.lua")
loadMod("scripts/market/RLMarketSnapshot.lua")
g_diseaseManager = { diseasesEnabled = true }
local a=bvAnimal("BULL_HOLSTEIN",17,{farmId="123",uniqueId="12345",birthday={country=2},isDead=false,isIndividual=true,birthCount=0})
a.getSellPrice=function() error("live price forbidden") end
a.getCurvePrice=function() error("live curve price forbidden") end
local snap=assert(RLMarketSnapshot.capture(a,{classRevision="c1",traitMappingRevision="t1"},{diseasesEnabled=true}))
local ctx=F.context(snap,F.input())
local inputs=assert(RLMarketValueAdapter.capture(a,snap,ctx))
check("adapter: actual subtype raw XML curve captured in HARD",inputs.facts.rawSellCurve.values[19]==1954 and inputs.currencyBasis=="HARD")
check("adapter: male gestation is verified from female counterpart",inputs.production.params.gestationMonths==10 and inputs.production.params.minBreedingAge==12)
ctx.referenceInputs=inputs;ctx.breedingObjective="DAIRY"
unsupported,why=registry:evaluate(snap,ctx)
check("adapter: default missing economic parameters close production",unsupported==nil and why:find("MISSING_PRODUCTION",1,true)~=nil)
ctx.breedingObjective=nil
unsupported,why=registry:evaluate(snap,ctx)
check("adapter: no guessed slaughter station or free rearing costs",unsupported==nil and why=="COMMODITY_UNSUPPORTED")
local female=BV_SUB.COW_HOLSTEIN
local saved=female.output.milk
female.output.milk={fillType=saved.fillType,curve=saved}
local wrapped=assert(RLMarketSnapshot.capture(a,{classRevision="c1",traitMappingRevision="t1"},{diseasesEnabled=true}))
check("adapter: real engine wrapped AnimCurve verifies milk capability",wrapped.traitCapabilities.milkProductivity)
local adapterInput=F.input();adapterInput.params.gestationMonths=10
local captured=assert(RLMarketValueAdapter.capture(a,wrapped,ctx,{productionBySpecies={COW=adapterInput},milkPriceHard=0.5,milkNetShare=0.25}))
check("adapter: raw data contains no live curve or callback",RLMarketData.fingerprint(captured)~=nil)
female.output.milk=saved
local stable=assert(RLMarketSnapshot.capture(a,{classRevision="c1",traitMappingRevision="t1"},{diseasesEnabled=true}))
a.weight=a.weight+1
local staleInputs,staleReason=RLMarketValueAdapter.capture(a,stable,ctx)
check("adapter: animal changed after snapshot cannot carry stale identity revision",staleInputs==nil and staleReason=="REFERENCE_STATE_CHANGED")
a.weight=a.weight-1
local wrongBasis,wrongReason=RLMarketValueAdapter.capture(a,stable,ctx,{productionBySpecies={COW={currencyBasis="CURRENT"}}})
check("adapter: current money cannot be relabeled as HARD",wrongBasis==nil and wrongReason=="PRODUCTION_BASIS_REQUIRED")
local target=F.snapshot("COW");local tooLight=F.context(target,F.input());tooLight.breedingObjective="DAIRY";target.weightKg=100
local light=assert(registry:evaluate(target,tooLight))
check("providers: raw reference does not waive real breeding weight",not light.breeding.byObjective.DAIRY.eligible and light.breeding.byObjective.DAIRY.reasons[1]=="TOO_LIGHT")
local conflicting,conflictReason=RLMarketValueAdapter.capture(a,stable,ctx,{productionBySpecies={COW=F.input()}})
check("adapter: explicit economics cannot replace observed gestation",conflicting==nil and conflictReason=="REFERENCE_GESTATION_CONFLICT")
local economics=F.input();economics.params.gestationMonths=10;economics.lactationNetByMonth=nil;economics.lactationIncrementNetByMonth=nil
local actualMilk=assert(RLMarketValueAdapter.capture(a,stable,ctx,{productionBySpecies={COW=economics},milkPriceHard=0.5,milkNetShare=0.25,milkIncrementNetShare=0.4}))
local raw=BV_SUB.COW_HOLSTEIN.output.milk:get(RLMilkParity.MATURE_AGE_MONTHS)
local scale=RLBreedTraits.get(BV_SUB.COW_HOLSTEIN,"milkScale")*RLBreedTraits.getMilkCollect(BV_SUB.COW_HOLSTEIN)
check("adapter: real milk output and collection factors produce HARD net flows",near(actualMilk.production.lactationNetByMonth[1],raw*scale*RLLactation.getYieldFactor(0)*0.5*0.25,1e-9)
    and near(actualMilk.production.lactationIncrementNetByMonth[1],raw*scale*RLLactation.getYieldFactor(0)*0.5*0.4,1e-9))
check("adapter: missing economics are explicitly enumerated",#inputs.missing.productionFields>0 and inputs.missing.productionFields[1]=="costBasis")
local indexAnimal=F.snapshot("COW");indexAnimal.genes.productivity=1.5
local indexContext=F.context(indexAnimal,F.input());indexContext.breedingObjective="DAIRY"
local indexValue=assert(registry:evaluate(indexAnimal,indexContext)).breeding.byObjective.DAIRY
check("providers: fixed dairy selection index differs from economic valuation score",near(indexValue.selectionIndex,1.2,1e-12) and indexValue.valuationScore==1.5)

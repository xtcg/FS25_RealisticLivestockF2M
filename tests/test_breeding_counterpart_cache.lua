loadMod("tests/breedingvalue_fixture.lua")
local V=RLBreedingValue
local source={name="SAME",breed="A",typeIndex=1,gender="female"}
local a={name="MALE_A",breed="A",typeIndex=1,gender="male",sellPrice={}}
local b={name="MALE_B",breed="B",typeIndex=1,gender="male",sellPrice={}}
g_currentMission=nil
check("counterpart cache: pre-load lookup is unavailable",V.getCounterpart(source,"male")==nil)
local registry={source,a,b};g_currentMission={animalSystem={subTypes=registry}}
check("counterpart cache: early miss cannot hide a later subtype",V.getCounterpart(source,"male")==a)
local other={name="SAME",breed="B",typeIndex=1,gender="female"}
check("counterpart cache: same display name cannot alias different breed",V.getCounterpart(other,"male")==b)
local replacement={name="MALE_A_NEW",breed="A",typeIndex=1,gender="male",sellPrice={}}
registry[2]=replacement
check("counterpart cache: in-place registry replacement invalidates hit",V.getCounterpart(source,"male")==replacement)
replacement.breed="B"
check("counterpart cache: changed target classification cannot reuse hit",V.getCounterpart(source,"male")==nil)
registry[#registry+1]=a
check("counterpart cache: missing counterpart can appear later",V.getCounterpart(source,"male")==a)
g_currentMission.animalSystem.subTypes={source,replacement};replacement.breed="A"
check("counterpart cache: replacement registry invalidates old world reference",V.getCounterpart(source,"male")==replacement)
g_currentMission={animalSystem={subTypes={source,a}}}
check("counterpart cache: replacement AnimalSystem invalidates cached subtype",V.getCounterpart(source,"male")==a)
source.breed="B";g_currentMission.animalSystem.subTypes[3]=b
check("counterpart cache: changed source classification resolves anew",V.getCounterpart(source,"male")==b)
local observed=setmetatable({g_currentMission.animalSystem}, {__mode="v"})
g_currentMission=nil;registry=nil;source=nil;other=nil
collectgarbage("collect");collectgarbage("collect")
check("counterpart cache: cache does not retain old AnimalSystem",observed[1]==nil)

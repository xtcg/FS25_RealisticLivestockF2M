loadMod("scripts/market/RLBrokerHBSupport.lua")
local H=RLBrokerHBSupport
local module={}
_G.FS25_HofBergmann={LivestockTrailerSpecial=module}
local mod={version="1.5.0.0 Beta1"}
g_modManager={getModByName=function(_,name) return name=="FS25_HofBergmann" and mod or nil end}
check("broker HB: exact audited installed module accepted",H.trustedCompanion("FS25_HofBergmann.livestockTrailerSpecial",module))
check("broker HB: copied name cannot authorize different writer",not H.trustedCompanion("FS25_HofBergmann.livestockTrailerSpecial",{}))
mod.version="1.6.0.0"
check("broker HB: unreviewed map version refused",not H.trustedCompanion("FS25_HofBergmann.livestockTrailerSpecial",module))
mod.version="1.5.0.0 Beta1"
check("broker HB: another map and unknown animal layout refused",not H.trustedCompanion("OtherMap.livestockTrailerSpecial",module) and not H.trustedCompanion("FS25_HofBergmann.animalStore",module))

FSBaseMission={}
Utils={prependedFunction=function(_,fn) return fn end}
loadMod("scripts/core/RealisticLivestock_FSBaseMission.lua")
local M=RealisticLivestock_FSBaseMission
local rows={{farmId="9",uniqueId="123",country=3},{farmId="9",uniqueId="123",country=3},{farmId="1",uniqueId="1",country=3}}
local report=M._inspectIdentityConflicts(rows)
check("startup identity: reports duplicate group and placeholder",report.count==2 and report.duplicates["9 123 3"]==2 and #report.placeholders==1)
check("startup identity: old IDs remain intact",rows[1].uniqueId=="123" and rows[2].uniqueId=="123" and rows[3].uniqueId=="1")
local h=assert(io.open(REPO.."scripts/core/RealisticLivestock_FSBaseMission.lua","r"));local text=h:read("*a");h:close()
check("startup identity: no automatic renumbering call",not text:find("pcall(RLAnimalIdentityRepair.run",1,true)
    and not text:find("animal:setUniqueId()",1,true))

--[[
    RLFeedUnits.lua
    The one conversion between real nutrition and game feed (xml/feedProfiles.xml). Pure.

        s    resourceScale: game liters per real-equivalent liter
        D    realDaysPerPeriod: model days in a game month
        d    the game's days per month
        rho  a feed's kg as fed per game liter, dm its dry matter share

        real days one game hour stands for   D / (24 d)
        game liters for kg of real DM          s x kgDM / (rho x dm)
        kg of real DM a game liter restores    liters x rho x dm / s

    s appears once on each side: a plan is turned into liters by kgToLiters, what was eaten back
    into DM by litersToKg, and nothing in between scales by it again.
]]

RLFeedUnits = {}


--- Real days one game hour stands for.
--- @param realDaysPerPeriod number D
--- @param daysPerPeriod number|nil d (at least 1)
--- @return number
function RLFeedUnits.getHourDays(realDaysPerPeriod, daysPerPeriod)
    return realDaysPerPeriod / (24 * math.max(daysPerPeriod or 1, 1))
end


--- Game liters of a feed that hold `kg` of real dry matter.
--- @param kg number kg DM
--- @param scale number s
--- @param density number kg as fed per liter
--- @param dm number dry matter share
--- @return number liters
function RLFeedUnits.kgToLiters(kg, scale, density, dm)
    return scale * kg / (density * dm)
end


--- Real dry matter (kg) game liters of a feed restore.
--- @param liters number
--- @param scale number s
--- @param density number
--- @param dm number
--- @return number kg DM
function RLFeedUnits.litersToKg(liters, scale, density, dm)
    return liters * density * dm / scale
end


--- Game liters a month of a feed takes: s x intake (kg DM a real day) x share x D / (rho x dm).
--- @return number liters per game month
function RLFeedUnits.getMonthlyLiters(intakeKgPerDay, share, scale, realDaysPerPeriod, density, dm)
    return RLFeedUnits.kgToLiters(intakeKgPerDay * share * realDaysPerPeriod, scale, density, dm)
end


--- ME (MJ/kg DM) of a TDN (%) by NRC 1996/2000: DE = 0.04409 x TDN Mcal/kg, ME = 0.82 x DE.
RLFeedUnits.MCAL_TO_MJ = 4.184

function RLFeedUnits.getMEFromTDN(tdn)
    return tdn * 0.04409 * 0.82 * RLFeedUnits.MCAL_TO_MJ
end

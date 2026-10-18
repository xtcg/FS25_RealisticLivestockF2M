--[[
    Dealer v2 T4: the dealer modules' view of the running game - the world the planner draws from, the
    eligibility rule of a shelf listing, the rules entry of a source, the date of a source birth. Plain
    functions over injected objects (defaults: the mission's animal system and environment), so they run
    in tests against stand-ins. Reads only; the one thing it changes is the stream it is handed.

    Eligibility is the dealer's own shelf rule (RLDealerStockPolicy.validate with onShelf) applied to the
    animal the source's physiology stands for now: a listing that no longer fits its purpose, falls ill,
    is too far along in pregnancy, or whose model cannot be resolved is not offered and not sold.
]]

RLDealerGameBinding = { VERSION = 1 }
local B = RLDealerGameBinding


--- The generation world for one animal type (cattle first). `now` = { day, month, year, daysPerMonth }.
function B.generationWorld(animalSystem, typeIndex, now)
    local animalType = animalSystem:getTypeByIndex(typeIndex)
    if animalType == nil then return nil, "NO_ANIMAL_TYPE" end
    local subTypes = {}
    for _, index in ipairs(animalType.subTypes) do
        local st = animalSystem:getSubTypeByIndex(index)
        if st ~= nil and st.visuals ~= nil then
            for _, visual in ipairs(st.visuals) do
                if visual.store ~= nil and visual.store.canBeBought then
                    subTypes[#subTypes + 1] = { index = index, name = st.name, breed = st.breed, gender = st.gender }
                    break
                end
            end
        end
    end
    if #subTypes == 0 then return nil, "NO_BUYABLE_SUBTYPES" end
    local world = {
        config = RLDealerStockPolicy.getConfig(), typeName = animalType.name, typeIndex = typeIndex, subTypes = subTypes,
        getSubType = function(index) return animalSystem:getSubTypeByIndex(index) end,
        getSaleAgeContext = function(subType) return animalSystem:getSaleAgeContext(animalType, subType) end,
        now = now,
    }
    world.pickSourceFarm = function(rng)
        -- The map country first (88%), else any country with a farm that keeps the type: the old dealer's rule.
        local tried, attempts = {}, 0
        for _ = 1, #animalSystem.countries do
            local countryIndex
            if attempts == 0 and rng.random() >= 0.12 then
                countryIndex = RealisticLivestock.getMapCountryIndex()
            else
                countryIndex = rng.random(1, #animalSystem.countries)
                local guard = 0
                while tried[countryIndex] and guard < 50 do countryIndex = rng.random(1, #animalSystem.countries); guard = guard + 1 end
            end
            tried[countryIndex] = true
            attempts = attempts + 1
            local country = animalSystem.countries[countryIndex]
            local valid = {}
            for _, farm in ipairs(country and country.farms or {}) do
                if farm.ids[typeIndex] ~= nil then valid[#valid + 1] = farm end
            end
            if #valid > 0 then return { countryIndex = countryIndex, farm = valid[rng.random(1, #valid)] } end
        end
        return nil
    end
    world.drawGenetics = function(rng)
        local traits = (typeIndex == AnimalType.COW or typeIndex == AnimalType.SHEEP or typeIndex == AnimalType.CHICKEN)
            and RLGeneticsDraw.TRAITS_WITH_PRODUCTIVITY or RLGeneticsDraw.TRAITS_BASE
        local genetics = RLGeneticsDraw.draw(traits, rng.random)
        local preset = RLDealerQualityResolver.getActiveIndex()
        local reshaped = RLDealerRng.with(rng, function() return RLDealerQualityModel.reshapeGenetics(genetics, preset) end)
        return reshaped or genetics
    end
    world.generateOffspring = function(subType, genetics, rng, age)
        local fertilityValue = genetics.fertility * (animalType.fertility:get(age) / 100)
        if rng.random() >= fertilityValue then return 0 end
        local factor = 0.75 + genetics.fertility / 4
        if rng.random() >= 0.25 then return animalType.pregnancy.average end
        return animalType.pregnancy.get(rng.random() * factor)
    end
    world.randomName = function(gender, rng)
        return RLDealerRng.with(rng, function() return g_currentMission.animalNameSystem:getRandomName(gender) end)
    end
    return world
end


--- The rules entry of a source (what RLDealerReplay needs): the stock policy entry for its subtype.
function B.resolveEntry(world)
    return function(subTypeName)
        for _, st in ipairs(world.subTypes) do
            if st.name == subTypeName then
                return RLDealerStockPolicy.getEntry(world.config, world.getSubType(st.index), world.typeName)
            end
        end
        return nil
    end
end


--- The shelf rule: `source` is the source record, `listing` the registry row.
function B.eligible(world, resolveSubType)
    return function(source, listing, context)
        local resolved, failure = RLDealerSourceState.restore(source, function(name) local sub = resolveSubType(name); return sub end)
        if not resolved then return false, "SOURCE_RESTORE:" .. tostring(failure and failure.reason) end
        local animal = resolved.animal
        local subType = animal:getSubType()
        local entry = RLDealerStockPolicy.getEntry(world.config, subType, world.typeName)
        local purpose = RLDealerStockPolicy.findPurpose(entry, subType.gender, listing.payload and listing.payload.purpose)
        if entry.status ~= RLDealerStockPolicy.COVERED or purpose == nil then return false, "PURPOSE_GONE" end
        animal.sale = { source = source.history and source.history.source, parity = animal.birthCount, purpose = purpose.id }
        local policyPurpose = {}
        for k, v in pairs(purpose) do policyPurpose[k] = v end
        policyPurpose.breedingWeight = false
        local ok, reasons = RLDealerStockPolicy.validate(animal, policyPurpose, entry, subType, world.getSaleAgeContext(subType), true)
        if not ok then return false, reasons[1] end
        return true
    end
end


--- The game date as the generation world's `now`: { day, month, year, daysPerMonth }.
function B.now(environment)
    local day, month, year = RLCalendar.getDate(environment)
    return { day = day, month = month, year = year, daysPerMonth = environment.daysPerPeriod }
end


--- A source birth's identity and date: the game date at the interval's end, stable per source and cursor.
function B.birthDate(environment)
    return function(sourceId, cursorMonths)
        local day, month, year = RLCalendar.getDate(environment)
        return { eventId = string.format("B%s@%.6f", tostring(sourceId), cursorMonths), day = day, month = month, year = year }
    end
end

-- Hourly production delegates. Animal owns persistent state and public methods;
-- this module owns input/output calculations. Source before Animal, like
-- AnimalHealth/Reproduction. Pricing, serialization and random streams stay outside.
AnimalProduction = {}
local Log=RmLogging.getLogger("RLRM")

function AnimalProduction.updateInput(self)
    local subType = self:getSubType()


    for fillType, input in pairs(subType.input) do
        local litersPerDay = input:get(self.age)

        if fillType == "food" then
            local numPregnancies = (self.pregnancy ~= nil and self.pregnancy.pregnancies ~= nil)
                and #self.pregnancy.pregnancies or 0
            litersPerDay = Animal._computeDailyFood(
                self.age,
                self.isLactating,
                self.reproduction,
                numPregnancies,
                self:getIntakeGene(),
                litersPerDay,
                RealisticLivestock_PlaceableHusbandryFood.foodScale,
                self:getFeedModifier()
            )
            -- Real-equivalent nutrition (RLFeed): the liters a month its pen's last plan gave it,
            -- in place of the curve (foodScale and the old feed factors are not applied to it).
            local planned = RLFeed ~= nil and RLFeed.getRequestLitersPerPeriod(self) or nil
            if planned ~= nil then litersPerDay = planned end
        end

        if fillType == "water" then
            if self.isLactating then litersPerDay = litersPerDay * 1.5 end

            if self.reproduction ~= nil and self.reproduction > 0 and self.pregnancy ~= nil and self.pregnancy.pregnancies ~= nil then
                litersPerDay = litersPerDay * math.min(math.pow(1 + ((self.reproduction / 100) / 5), #self.pregnancy.pregnancies), 2.0)
            end
        end

        self.input[fillType] = litersPerDay / 24
    end

    if self.isLactating or self.isPregnant then
        local pregCount = (self.pregnancy ~= nil and self.pregnancy.pregnancies ~= nil) and #self.pregnancy.pregnancies or 0
        Log:trace("updateInput: animal=%s food/h=%.4f water/h=%.4f isLactating=%s isPregnant=%s reproduction=%d pregnancies=%d",
            tostring(self.uniqueId), self.input.food or 0, self.input.water or 0,
            tostring(self.isLactating), tostring(self.isPregnant), self.reproduction or 0, pregCount)
    end
end

function AnimalProduction.updateOutput(self,temp)
    local subType = self:getSubType()

    -- Resolved above the fill-type loop so every fill type reads the same multipliers.
    local multipliers, contributors = self:getDiseaseMultipliers("updateOutput")

    if multipliers ~= nil then
        if contributors > 0 then
            Log:trace("updateOutput: animal=%s/%s disease multipliers milk=%s pallets=%s manure=%s "
                .. "liquidManure=%s (contributors=%s)",
                tostring(self.farmId), tostring(self.uniqueId), tostring(multipliers.milk),
                tostring(multipliers.pallets), tostring(multipliers.manure),
                tostring(multipliers.liquidManure), tostring(contributors))
        else
            Log:trace("updateOutput: animal=%s/%s holds disease records but none contributes "
                .. "(none symptomatic or incubating, or an unregistered title), output unscaled",
                tostring(self.farmId), tostring(self.uniqueId))
        end
    end

    for fillType, output in pairs(subType.output) do
        local litersPerDay = 0
        local palletMilkCurve

        -- Cattle's milk is read at its mature age: the lactation number sets the level, not a step of the curve.
        local cattleMilk = self:isCattleMilkOutput(fillType, output)
        local curveAge = cattleMilk and RLMilkParity.getCurveAge(self.age) or self.age
        local parityFactor = cattleMilk and self:getParityFactor() or 1
        -- A breed whose milk curve is not on this mod's scale (a pack's own animals.xml) is scaled to it (breedTraits milkScale).
        local milkScale = cattleMilk and RLBreedTraits.get(subType, "milkScale") or 1
        -- Beef cattle give no milk output at all (RLRearingPolicy): no curve, no milk gene, nothing for a
        -- store. What a beef cow's calves drink is the nutrition she pays for them (RLFeed nursing),
        -- never this curve.
        if cattleMilk and RLRearingPolicy ~= nil and RLRearingPolicy.isBeef(subType) then milkScale = 0 end

        litersPerDay = RLAnimalOutput.curve(output):get(curveAge)

        if litersPerDay == nil then
            Log:warning("updateOutput: nil litersPerDay for '%s' output '%s' (age=%d, hasCurve=%s, subType='%s')",
                tostring(self.uniqueId), fillType, self.age, tostring(output.curve ~= nil), tostring(subType.name))
            litersPerDay = 0
        end
        litersPerDay = litersPerDay * milkScale

        if fillType == "pallets" then
            local fillTypeIndex = output.fillType
            local productivity = self.genetics.productivity or 1

            if fillTypeIndex == FillType.WOOL then
                -- A fleece grows every month (sheep S3, 2026-10-11): a curve breedTraits woolScale configured is
                -- 1.2 x the real fleece a year spread over 12 months, with no cold gate, as Hof Bergmann's
                -- SHEEPWOOL_SHEARED, never gated, already was. A wool curve nothing configured (an old breedTraits
                -- copy in modSettings, a sheep pack the file does not list) is still on the raw scale, 100x real
                -- and more, so it keeps the old gate: no wool below a 12 C minimum.
                local configured = RLCurveScale ~= nil and RLCurveScale.isConfigured(output.curve)
                if not configured then
                    if temp < 12 then litersPerDay = 0 end
                    Animal.warnUnscaledWool(subType)
                end
                Log:trace("updateOutput[wool]: animal=%s/%s temp=%s configured=%s", tostring(self.farmId),
                    tostring(self.uniqueId), tostring(temp), tostring(configured))
            elseif Animal.isLactationPalletFillType(fillTypeIndex) then
                -- Milk sold in cans or pallets: goat milk, and cow and buffalo milk in Hof
                -- Bergmann's pallet-spawner cattle buildings. Gated like the tank milk below, so a
                -- dry or never-calved animal fills none.
                local factor = self:getLactationFactor() * parityFactor
                palletMilkCurve = litersPerDay * parityFactor

                litersPerDay = litersPerDay * factor

                Log:trace("updateOutput[palletMilk]: animal=%s/%s fillType=%s months=%s isLactating=%s isParent=%s factor=%s",
                    tostring(self.farmId), tostring(self.uniqueId),
                    tostring(g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)),
                    tostring(self.monthsSinceLastBirth), tostring(self.isLactating), tostring(self.isParent),
                    tostring(factor))
            end

            litersPerDay = litersPerDay * productivity
        end

        -- Milk diagnostics: capture the gate breakdown here and log it AFTER the disease multiplier,
        -- because a disease zeroing milk and a lactation-gate failure both read 0 from the husbandry side.
        local isMilk = fillType == "milk"
        local milkCurve, milkFactor, milkProductivity, milkPreDisease

        if isMilk and Animal.isSemenFillType(output.fillType) then
            -- Hof Bergmann models bull semen as the milk output of its BULL subtype. Semen is not
            -- lactation, so the mother gate below would zero it for good; the sire's fertility
            -- scales it instead, and a castrated or infertile sire produces none. Only a semen fill
            -- type takes this branch, so no other male starts producing milk. A month in which
            -- the sire was collected into a dewar (RLSemenCollection) yields nothing here, and
            -- nothing at all while Animal.MAP_SEMEN_OUTPUT is off (the default). The age
            -- shape is dewar collection's (RLSemenCollection.getAgeOutputFactor); the XML curve
            -- only sets the peak amount.
            local collectedThisMonth = RLSemenCollection.isCollectedThisMonth(self)
            local fertility = (self.isCastrated or collectedThisMonth or not Animal.MAP_SEMEN_OUTPUT) and 0
                or (self.genetics.fertility or 1)
            local ageFactor = RLSemenCollection.getAgeOutputFactor(self)
            local curveLitersPerDay = litersPerDay

            litersPerDay = litersPerDay * fertility * ageFactor

            Log:trace("updateOutput[semen]: animal=%s/%s subType=%s age=%d curve(l/day)=%.3f fertility=%.3f ageFactor=%.3f castrated=%s collectedThisMonth=%s -> l/day=%.3f",
                tostring(self.farmId), tostring(self.uniqueId), tostring(subType.name), self.age or -1,
                curveLitersPerDay, fertility, ageFactor, tostring(self.isCastrated), tostring(collectedThisMonth), litersPerDay)

            isMilk = false
        elseif isMilk then
            local factor = self:getLactationFactor() * parityFactor
            local productivity = self.genetics.productivity or 1
            local curveLitersPerDay = litersPerDay * parityFactor

            litersPerDay = litersPerDay * factor * productivity

            milkCurve, milkFactor, milkProductivity, milkPreDisease = curveLitersPerDay, factor, productivity, litersPerDay
        end

        local diseaseFactor, healthyLitersPerDay = 1, litersPerDay
        if multipliers ~= nil then
            -- Cow and buffalo milk cans are the same milk as a tank, so a disease scales them the
            -- same. Goat milk keeps the pallets modifier: sheep diseases set only that one.
            local diseaseOutput = fillType
            if fillType == "pallets" and Animal.isCowMilkPalletFillType(output.fillType) then diseaseOutput = "milk" end
            diseaseFactor = multipliers[diseaseOutput]
            litersPerDay = litersPerDay * diseaseFactor
        end

        -- Cattle milk under the body condition rules: litersPerDay is what a cow on full feed gives.
        -- It is recorded for her budget; in an hour the budget covers, the store deposits what
        -- the budget paid for instead (RLBodyCondition.depositMilk), otherwise this as before.
        if isMilk then
            litersPerDay = RLBodyCondition.applyMilk(self, litersPerDay, milkCurve, diseaseFactor, healthyLitersPerDay)
        elseif palletMilkCurve ~= nil and Animal.isLactationPalletFillType(output.fillType) then
            -- Milk in cans or pallets (cow and buffalo cans, goat milk): recorded for the budget the same
            -- way, so a covered dam's store gets what her budget paid after her young drank (RLFeed).
            litersPerDay = RLBodyCondition.applyMilk(self, litersPerDay, palletMilkCurve, diseaseFactor, healthyLitersPerDay)
        end
        -- A suckler (beef) breed's milk is for her calf, not the store (breedTraits milkCollect 0):
        -- the store takes only that share. The budget above still has her full milk (her calf's).
        if cattleMilk then
            litersPerDay = litersPerDay * RLBreedTraits.getMilkCollect(subType)
        end

        if isMilk then
            -- litersPerDay is now the FINAL value (post lactation gate AND disease).
            -- TRACE the full breakdown for every cow every recompute; there is no
            -- debugger, so this is the only way to see why a lactating cow yields no milk.
            Log:trace("updateOutput[milk]: animal=%s/%s subType=%s age=%d curve(l/day)=%.3f isLactating=%s isParent=%s months=%s factor=%.3f productivity=%.3f diseases=%d diseaseMilk=%s -> preDisease l/h=%.4f final l/h=%.4f",
                tostring(self.farmId), tostring(self.uniqueId), tostring(subType.name), self.age or -1,
                milkCurve, tostring(self.isLactating), tostring(self.isParent),
                tostring(self.monthsSinceLastBirth), milkFactor, milkProductivity, #self.diseases,
                tostring(multipliers ~= nil and multipliers.milk or nil),
                milkPreDisease / 24, litersPerDay / 24)

            -- Smoking-gun DEBUG: client shows "lactating" but the FINAL server output is 0.
            -- reason= attributes it - "disease" (gate produced milk, a disease zeroed it)
            -- vs a specific gate term. Surfaces at the default dev level.
            if self.isLactating and litersPerDay <= 0 then
                local reason = (milkPreDisease > 0 and "disease")
                    or (milkCurve <= 0 and "curve=0(age?)")
                    or (not self.isParent and "notParent")
                    or ((self.monthsSinceLastBirth or 12) >= 10 and "months>=10")
                    or (milkProductivity <= 0 and "productivity=0")
                    or (milkFactor <= 0 and "factor=0")
                    or "unknown"
                Log:debug("updateOutput[milk]: animal=%s/%s is LACTATING but produces 0 milk (age=%d curve=%.3f isParent=%s months=%s productivity=%.3f diseases=%d preDisease l/h=%.4f) reason=%s",
                    tostring(self.farmId), tostring(self.uniqueId), self.age or -1, milkCurve,
                    tostring(self.isParent), tostring(self.monthsSinceLastBirth), milkProductivity,
                    #self.diseases, milkPreDisease / 24, reason)
            end
        end

        self.output[fillType] = litersPerDay / 24
    end
end

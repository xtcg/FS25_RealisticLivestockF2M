-- S5's first dependency: physiology belongs to the animal's species. Sheep stay off until
-- the feed, maternal milk and body-condition calibration is complete.
loadMod("tests/growthsim.lua")
local G, W = RLGrowth, RLWeightProfiles
local config = W.getConfig()
local root, entry = config.settings, config.types.SHEEP
local sheepType
for _, sub in ipairs(Economics.subTypes) do
    if sub.typeName == "SHEEP" then sheepType = sub.typeIndex end
end
local eweSub = { name = "SHEEP_LANDRACE", breed = "LANDRACE", gender = "female", typeIndex = sheepType }
local ramSub = { name = "RAM_LANDRACE", breed = "LANDRACE", gender = "male", typeIndex = sheepType }
local goatSub = { name = "GOAT", breed = "GOAT", gender = "female", typeIndex = sheepType }
local cowSub = select(2, Economics.find("BULL_ANGUS"))
local function animal(sub, fields)
    local a = { getSubType = function() return sub end, genetics = { metabolism = 1 }, gender = sub.gender,
        isIndividual = true, animalTypeIndex = sub.typeIndex, age = 0, weight = 30 }
    for k, v in pairs(fields or {}) do a[k] = v end
    return a
end

check("S5 shipped: sheep still OFF, own wether speed 0.86, cattle steer speed 0.90",
    not entry.enabled and entry.settings ~= root and entry.settings.castratedSpeed == 0.86 and root.castratedSpeed == 0.90)
check("settings: type name, subtype, binding and individual resolve the same table",
    G.getSettings("SHEEP") == entry.settings and G.getSettings(eweSub) == entry.settings
    and G.getSettings({ typeName = "SHEEP", profile = "SHEEP:LANDRACE", sex = "male" }) == entry.settings
    and G.getSettings(animal(eweSub)) == entry.settings)
check("settings: cattle, proxy types, excluded goats and unknown types keep exact root table",
    G.getSettings() == root and G.getSettings(cowSub) == root and G.getSettings("MILKCOW") == root
    and G.getSettings(goatSub) == root and G.getSettings("PIG") == root and G.getSettings(nil) == root)

-- Parse independent overrides from an actual shipped file through the engine XML interface.
local xml = XMLFile.loadIfExists("s5", REPO .. "xml/weightProfiles.xml")
local baseFloat, baseBool = xml.getFloat, xml.getBool
local overrides = { castratedSpeed = 0.81, maleBirthFactor = 1.2, birthFadeMonths = 2,
    transitionMonths = 0.2, migrationBlendMonths = 2, gravidTermRatio = 1.5, gravidExponent = 4,
    lactationIntakeStrength = 0.2, lactationCapacityStrength = 0.1, earlyMilkMobilizeMonths = 1,
    earlyMilkMobilizeShare = 0.25, litter2 = 0.7, litter3 = 0.6, birthWeightCV = 0.1,
    birthTruncateSD = 1, sizeGeneEffect = 0.1, speedGeneEffect = 0.15, maintenanceGeneEffect = 0.1,
    birthGeneEffect = 0.05, underweightRatio = 0.3, frameFloorRatio = 0.2 }
function xml:getFloat(key, default)
    local field = key:match("^weightProfiles%.animalType%(0%)#(.+)$")
    if field ~= nil and overrides[field] ~= nil then return overrides[field] end
    return baseFloat(self, key, default)
end
function xml:getBool(key, default)
    if key == "weightProfiles.animalType(0)#enabled" then return true end
    return baseBool(self, key, default)
end
local parsed = W.parse(xml)
check("parser: each type override independent, root remains exact", parsed.types.SHEEP.settings.gravidTermRatio == 1.5
    and parsed.types.SHEEP.settings.birthFadeMonths == 2 and parsed.settings.gravidTermRatio == root.gravidTermRatio
    and parsed.settings.birthFadeMonths == root.birthFadeMonths)
check("parser: a profile's own maleBirthFactor wins over the type", near(parsed.profiles["SHEEP:LANDRACE"].knots.male[1][2],
    config.profiles["SHEEP:LANDRACE"].knots.male[1][2], 1e-12))
-- Remove profile-local birth factors to check the type's fallback, without changing the source file.
local withProfileFactor = xml.getFloat
function xml:getFloat(key, default)
    if key:match("^weightProfiles%.profile%(%d+%)#maleBirthFactor$") then return default end
    return withProfileFactor(self, key, default)
end
local fallback = W.parse(xml)
check("parser: missing profile-local birth factor uses the type's factor",
    near(fallback.profiles["SHEEP:LANDRACE"].knots.male[1][2], fallback.profiles["SHEEP:LANDRACE"].birthFemaleKg * 1.2, 1e-12))
overrides.castratedSpeed = 0
local bad = W.parse(xml)
check("parser: bad sheep coefficients disable sheep alone, keep cattle and a useful reason",
    not bad.types.SHEEP.enabled and bad.types.SHEEP.invalidReason ~= nil and bad.enabled
    and bad.settings.castratedSpeed == root.castratedSpeed)
overrides.castratedSpeed = 0.81
-- Expected error from deliberately invalid input is not a runtime failure.
LOG = {}

W.config = parsed
G.resetCaches()
local s = parsed.types.SHEEP.settings
local ewe = animal(eweSub, { isParent = true, bodyCondition = { reserve = 0.6 } })
local ram = animal(ramSub, { isCastrated = true })
ewe.isPregnant, ewe.reproduction = true, 80
ewe.pregnancy = { pregnancies = { { getSubType = function() return ramSub end }, { getSubType = function() return ramSub end } } }
local fetusMean = G.getBirthMeanFor(ramSub, { damBreed = ewe.breed, litterSize = 2, firstBirth = false, dam = ewe, metabolism = 1 })
check("pregnancy: sheep term ratio and exponent", near(G.getGravidTarget(ewe), fetusMean * 2 * 1.5 * 0.8 ^ 4, 1e-12))
check("stage speed: sheep override and cow root", G.getStageSpeed(ram) == s.castratedSpeed
    and G.getStageSpeed(animal(cowSub, { isCastrated = true })) == root.castratedSpeed)
local size, speed, maint, birth = G.getGeneFactors(1.75, ewe)
check("genes: all four effects use sheep settings", near(size, 1.1, 1e-12) and near(speed, 1.15, 1e-12)
    and near(maint, 1.1, 1e-12) and near(birth, 1.0375, 1e-12))
check("litter: twins and triplets use sheep factors", G.getLitterFactor(2, eweSub) == 0.7
    and G.getLitterFactor(3, eweSub) == 0.6 and G.getLitterFactor(2, cowSub) == root.litter2)
local mean = G.getBirthMeanFor(ramSub, { litterSize = 2, firstBirth = true, metabolism = 1.75 })
check("birth mean: litter, parity and genes use child species", near(mean,
    G.getBirthMean(G.getBinding(ramSub)) * 0.7 * s.firstBirthFactor * birth, 1e-12))
local zSource = function() return 0.5 end
local w, z, drawnMean = G.drawBirthWeight(ramSub, { litterSize = 1 }, zSource)
check("birth draw: sheep truncateSD and CV", math.abs(z) <= 1 and near(w, drawnMean * (1 + 0.1 * z), 1e-12))
local faded = G.buildCurve(G.getBinding(ramSub), G.getAdultReference(G.getBinding(ramSub)), 10)
local nominal = G.getNominalCurve(G.getBinding(ramSub))
check("curve: actual birth delta fades by sheep birthFadeMonths", near(faded:value(2.6), nominal:value(2.6), 1e-12))
local state = { legacyAnchor = {}, anchorElapsedMonths = 0.5 }
check("migration: species blend duration in remaining share and sanitization", near(G.getAnchorRemaining(ewe, state), 0.75, 1e-12)
    and G.sanitizeState(nil, { legacyAnchor = {}, anchorElapsedMonths = 100 }).anchorElapsedMonths == root.migrationBlendMonths)
ewe.isLactating, ewe.monthsSinceLastBirth = true, 0
local months = G.getLactationMonths(ewe)
local nrc = 1 - math.exp(-s.lactationIntakeRate * (months * s.lactationWeeksPerMonth + s.lactationIntakeOffset))
check("lactation: real and legacy appetite use sheep strengths", near(G.getLactationFactor(ewe), 1 - 0.2 * (1 - nrc), 1e-12)
    and near(G.getLactationFactor(ewe, nil, true), 1 - 0.1 * (1 - nrc), 1e-12))
check("lactation: reserve mobilization uses sheep period", near(G.getMilkMobilizeShare(ewe),
    RLBodyCondition.getConfig().milkMobilizeShare + math.max(s.earlyMilkMobilizeShare - RLBodyCondition.getConfig().milkMobilizeShare, 0)
        * math.max(1 - months / s.earlyMilkMobilizeMonths, 0), 1e-12))
local report = W.describe(eweSub)
check("report: effective settings are copied for review", report.settings.castratedSpeed == 0.81 and report.settings ~= s)
check("report: excluded goats show cattle-compatible root settings", W.describe(goatSub).settings.castratedSpeed == root.castratedSpeed)
local live = GrowthSim.makeAnimal("RAM_LANDRACE")
live.isCastrated = true
local result, input = G.advanceBudget(live, { intakeLiters = G.getReferenceIntake(live), milkShare = 1 }, 0.05, 1)
check("live step: sheep stage transition and frame floor use sheep settings (and the sheep body condition section)", result ~= nil
    and near(live.rlGrowth.speedFactor, 0.81 + 0.19 * math.exp(-3 * 0.05 / 0.2), 1e-12)
    and near(input.frameFloorKg, 0.2 * live.rlGrowth.birthWeightKg / (1 + RLBodyCondition.getConfig(live).referenceReserve * G.getKappa(live)), 1e-12)
    and RLBodyCondition.getConfig(live).reserveCapacityRatio == 0.48)
local healthCalls, oldHealth = 0, RLFeed.addHealth
RLFeed.addHealth = function() healthCalls = healthCalls + 1 end
s.underweightRatio = 0
RLFeed.applyUnderweight(live, 0.1)
s.underweightRatio, RLFeed.addHealth = 0.3, oldHealth
check("health: a valid zero underweight ratio disables the check without NaN", healthCalls == 0)
W.config = config
G.resetCaches()
check("S5 completion: production switch is still OFF", not W.getConfig().types.SHEEP.enabled)

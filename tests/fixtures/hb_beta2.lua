-- Hof Bergmann 1.5.0.0 Beta2 animal recipes, copied from the map (FS25_HofBergmann.zip, sha256
-- c3d7f71b57f57a2e050a02a37f32f7f8b1ac06b624fcb94b28f85930698d8dd1):
--   placeables/contractProductionPoints/slaughterhouse/slaughterhouse.xml (sha256 39d4c46e...513ca)
--   placeables/productionPoints/farmButcher/farmButcher.xml               (sha256 2097bee3...d1b21)
-- and stand-ins built the way the map's scripts load them
-- (PlaceableContractProductionService:onLoad recipes, PlaceableContractProductionAnimalInput
-- adapter mapping every subtype of a type, ProductionPoint productions). Only the numbers and
-- table shapes come from the map; the methods are stubs.

HB = {}

--- Public slaughterhouse contract recipes: id, input fill type, output fill type and amount, fee per batch.
HB.CONTRACT_RECIPES = {
    { id = "pigs_processing", input = "PIGS", output = "PORKMEAT", amount = 500, fee = 50 },
    { id = "cows_processing", input = "BEEF", output = "BEEFMEAT", amount = 1000, fee = 100 },
    { id = "horse_processing", input = "HORSES", output = "HORSEMEAT", amount = 1000, fee = 100 },
    { id = "poultry_processing", input = "POULTRY", output = "POULTRYMEAT", amount = 100, fee = 5 },
    { id = "goose_processing", input = "GOOSE", output = "GOOSEMEAT", amount = 100, fee = 5 },
    { id = "sheepGoat_processing", input = "SHEEPGOAT", output = "SHEEPGOATMEAT", amount = 400, fee = 40 },
    { id = "rabbit_processing", input = "RABBITS", output = "RABBITMEAT", amount = 50, fee = 5 },
}

--- Public slaughterhouse animalInput: animal type -> input fill type. Beta2 added MILKCOW on BEEF.
HB.CONTRACT_ANIMALS = { PIG = "PIGS", COW = "BEEF", MILKCOW = "BEEF", HORSE = "HORSES", CHICKEN = "POULTRY",
    GOOSE = "GOOSE", SHEEP = "SHEEPGOAT", RABBIT = "RABBITS" }
HB.CONTRACT_MAX_ANIMALS_PER_TYPE = 100000

--- Farm butcher productions: input amount -> meat amount + waste, 2.0 per active hour, 1 cycle per hour.
HB.BUTCHER_PRODUCTIONS = {
    { id = "pigs_processing", input = "PIGS", inputAmount = 240, output = "PORKMEAT", amount = 150, waste = 50 },
    { id = "cows_processing", input = "BEEF", inputAmount = 1500, output = "BEEFMEAT", amount = 900, waste = 300 },
    { id = "poultry_processing", input = "POULTRY", inputAmount = 100, output = "POULTRYMEAT", amount = 60, waste = 20 },
    { id = "goose_processing", input = "GOOSE", inputAmount = 90, output = "GOOSEMEAT", amount = 55, waste = 20 },
    { id = "sheepGoat_processing", input = "SHEEPGOAT", inputAmount = 160, output = "SHEEPGOATMEAT", amount = 100, waste = 30 },
    { id = "rabbit_processing", input = "RABBITS", inputAmount = 70, output = "RABBITMEAT", amount = 40, waste = 15 },
}
HB.BUTCHER_COSTS_PER_ACTIVE_HOUR, HB.BUTCHER_CYCLES_PER_HOUR = 2.0, 1

--- Farm butcher animalInput: animal type -> input fill type and units per animal.
HB.BUTCHER_ANIMALS = { PIG = { "PIGS", 120 }, COW = { "BEEF", 750 }, CHICKEN = { "POULTRY", 10 },
    GOOSE = { "GOOSE", 15 }, SHEEP = { "SHEEPGOAT", 80 }, RABBIT = { "RABBITS", 10 } }

HB.FILLTYPES = { PIGS = 101, BEEF = 102, HORSES = 103, POULTRY = 104, GOOSE = 105, SHEEPGOAT = 106, RABBITS = 107,
    PORKMEAT = 201, BEEFMEAT = 202, HORSEMEAT = 203, POULTRYMEAT = 204, GOOSEMEAT = 205, SHEEPGOATMEAT = 206,
    RABBITMEAT = 207, SLAUGHTERHOUSE_WASTE = 301, LEATHER = 302, COW_HOLSTEIN = 401, MILK_COW = 402 }
HB.FILLTYPE_NAMES = {}
for name, index in pairs(HB.FILLTYPES) do HB.FILLTYPE_NAMES[index] = name end


--- subTypeToFillType from a type -> fill type name map, every subtype of each type (as the adapter does).
--- @param animals table typeName -> fill type name
--- @param subTypes table index -> {typeName}
function HB.mapSubTypes(animals, subTypes)
    local map = {}
    for index, sub in pairs(subTypes) do
        local entry = animals[sub.typeName]
        local name = type(entry) == "table" and entry[1] or entry
        if name ~= nil then map[index] = HB.FILLTYPES[name] end
    end
    return map
end


--- The public slaughterhouse as the contract placeable: recipes as onLoad builds them, the
--- animal mapping, orders, and the delivery calls RLRM uses (stubs with the map's arithmetic).
--- @param subTypes table index -> {typeName, typeIndex}
--- @param fields table|nil Overrides (isServer, recipes, animals)
function HB.newSlaughterhouse(subTypes, fields)
    fields = fields or {}
    local spec = { serviceId = "slaughterhouse", recipes = {}, recipeById = {}, orders = {} }
    for _, def in ipairs(fields.recipes or HB.CONTRACT_RECIPES) do
        local recipe = { id = def.id, feePerBatch = def.fee, inputs = {}, outputs = {} }
        local inputType = HB.FILLTYPES[def.input]
        recipe.inputs[inputType] = { fillTypeIndex = inputType, amount = def.inputAmount or 1 }
        recipe.feeInputFillTypeIndex = inputType
        local outputType = HB.FILLTYPES[def.output]
        recipe.outputs[outputType] = { fillTypeIndex = outputType, amount = def.amount }
        recipe.primaryOutputFillTypeIndex = outputType
        for _, extra in ipairs(def.extraInputs or {}) do
            local t = HB.FILLTYPES[extra[1]]
            recipe.inputs[t] = { fillTypeIndex = t, amount = extra[2] }
        end
        table.insert(spec.recipes, recipe)
        spec.recipeById[recipe.id] = recipe
    end

    local animals = fields.animals or HB.CONTRACT_ANIMALS
    local typeData = {}
    for _, sub in pairs(subTypes) do
        if animals[sub.typeName] ~= nil then
            typeData[sub.typeIndex] = { minimumAge = sub.typeName == "HORSE" and 12 or 6, maximumAge = 60,
                maxNumAnimals = HB.CONTRACT_MAX_ANIMALS_PER_TYPE, fillTypeIndex = HB.FILLTYPES[animals[sub.typeName]] }
        end
    end

    local placeable = {
        isServer = fields.isServer ~= false,
        spec_contractProductionService = spec,
        animalSubTypeToFillType = HB.mapSubTypes(animals, subTypes),
        animalsTypeData = typeData,
        calls = {},
    }
    function placeable:getName() return "Slaughterhouse" end
    function placeable:getCapacity() return HB.CONTRACT_MAX_ANIMALS_PER_TYPE end
    function placeable:contractProductionAddAnimals() self.calls[#self.calls + 1] = "addAnimals" return 1 end
    function placeable:contractProductionGetAnimalFreeSlots() return 100 end
    -- PlaceableContractProductionService:contractProductionDeliver, money and visuals left out.
    function placeable:contractProductionDeliver(farmId, fillType, amount)
        self.calls[#self.calls + 1] = "deliver"
        local orders = {}
        for _, order in pairs(spec.orders) do if order.farmId == farmId then orders[#orders + 1] = order end end
        table.sort(orders, function(a, b) return a.id < b.id end)
        for _, order in ipairs(orders) do
            local recipe = spec.recipeById[order.recipeId]
            if recipe ~= nil and recipe.inputs[fillType] ~= nil then
                local fee = fillType == recipe.feeInputFillTypeIndex and amount / recipe.inputs[fillType].amount * recipe.feePerBatch or 0
                local credit = math.min(math.max(order.feeCredit or 0, 0), fee)
                order.feeCredit = (order.feeCredit or 0) - credit
                order.cashCharged = (order.cashCharged or 0) + fee - credit
                order.inputs[fillType].buffered = (order.inputs[fillType].buffered or 0) + amount
                return amount
            end
        end
        return 0
    end
    return placeable
end


--- Opens an order on the slaughterhouse for a recipe.
function HB.addOrder(placeable, id, farmId, recipeId, feeCredit)
    local spec = placeable.spec_contractProductionService
    local recipe = spec.recipeById[recipeId]
    local inputs = {}
    for fillType in pairs(recipe.inputs) do inputs[fillType] = { buffered = 0 } end
    spec.orders[#spec.orders + 1] = { id = id, farmId = farmId, recipeId = recipeId, feeCredit = feeCredit, inputs = inputs }
    return spec.orders[#spec.orders]
end


--- The farm butcher's production point: productions, scaled unit inputs and storage.
--- @param subTypes table index -> {typeName, typeIndex}
--- @param fields table|nil Overrides (isServer, productions, eao_specs)
function HB.newFarmButcher(subTypes, fields)
    fields = fields or {}
    local productions = {}
    for _, def in ipairs(fields.productions or HB.BUTCHER_PRODUCTIONS) do
        table.insert(productions, { id = def.id, cyclesPerHour = HB.BUTCHER_CYCLES_PER_HOUR,
            costsPerActiveHour = HB.BUTCHER_COSTS_PER_ACTIVE_HOUR,
            inputs = { { type = HB.FILLTYPES[def.input], amount = def.inputAmount } },
            outputs = { { type = HB.FILLTYPES[def.output], amount = def.amount },
                { type = HB.FILLTYPES.SLAUGHTERHOUSE_WASTE, amount = def.waste } } })
    end
    local units, typeData = {}, {}
    for typeName, entry in pairs(HB.BUTCHER_ANIMALS) do units[HB.FILLTYPES[entry[1]]] = entry[2] end
    for _, sub in pairs(subTypes) do
        if HB.BUTCHER_ANIMALS[sub.typeName] ~= nil then
            typeData[sub.typeIndex] = { minimumAge = 6, maximumAge = 60, maxNumAnimals = 100 }
        end
    end
    local pp = {
        isServer = fields.isServer ~= false,
        name = "Farm butcher",
        animalsTypeData = typeData,
        animalSubTypeToFillType = HB.mapSubTypes(HB.BUTCHER_ANIMALS, subTypes),
        eppAnimalInputUnitsByFillType = units,
        eppHasScaledAnimalInputs = true,
        productions = fields.productions ~= false and productions or nil,
        eao_specs = fields.eao_specs,
        level = 0,
        calls = {},
    }
    function pp:getCapacity() return 1e6 end
    function pp:getFillLevel() return self.level end
    function pp:addCluster(cluster)
        self.calls[#self.calls + 1] = "addCluster"
        local fillType = self.animalSubTypeToFillType[cluster.subTypeIndex]
        self.level = self.level + (self.eppAnimalInputUnitsByFillType[fillType] or 1)
        cluster:changeNumAnimals(-1)
    end
    return pp
end

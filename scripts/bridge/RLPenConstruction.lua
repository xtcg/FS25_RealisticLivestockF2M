--[[
    RLPenConstruction.lua
    Whether a husbandry that is built through a construction state machine (PlaceableConstructible)
    can take animals yet.

    Hof Bergmann's calf igloos are husbandries from the moment they are placed, but stay in SETUP
    until 1000 CALFIGLU are delivered, then pass FINALIZE to DONE. The engine and the map check
    nothing about construction when an animal is bought or moved in, so RLRM does: every way in
    (buy, move, herdsman buy and move, the destination lists) asks canAdmit first.

    The same holds for a production point that takes animals (Hof Bergmann's farm butcher, built
    SETUP -> STATE_1-3 -> FINALIZE -> DONE). The map hides its animal trigger until FINALIZE, but
    RLRM's move menu and herdsman reach the production point directly, so they ask canAdmit too.

    Which states take animals is a bridge decision, never a guess: husbandryProfiles.xml names
    them per building (<construction filename="..." readyStates="DONE"/>), and the names are
    resolved to the placeable's own state indices each time, so no index is hard coded.

    Status of a husbandry:
        READY       not constructible (reason NO_CONSTRUCTION), or in a ready state (READY_STATE)
        NOT_READY   a defined building in a state that is not ready (UNFINISHED_STATE)
        UNKNOWN     the state cannot be read (NO_STATE), the bridge's names match none of the
                    building's states (DEFINITION_UNRESOLVED), or a building no bridge defines is
                    still under construction (NO_DEFINITION)
        UNCHECKED   a building no bridge defines, in its final state (NO_DEFINITION_FINAL_STATE)
    READY and UNCHECKED take animals; NOT_READY and UNKNOWN do not.

    The state is read live on every call and never cached, so a pen opens the moment its
    construction finishes. Only animals coming in are gated: animals already in an unbuilt pen
    stay, are logged (INVALID_RESIDENT_UNBUILT) and can be moved out, and births are not blocked.
    Delivering construction material is untouched.
]]

RLPenConstruction = {}

local Log = RmLogging.getLogger("RLRM")

RLPenConstruction.READY = "READY"
RLPenConstruction.NOT_READY = "NOT_READY"
RLPenConstruction.UNKNOWN = "UNKNOWN"
RLPenConstruction.UNCHECKED = "UNCHECKED"

--- Reason RLHusbandryProfiles.checkAnimal gives for a pen that cannot take animals yet.
RLPenConstruction.REJECT = "PEN_NOT_BUILT"

--- Set once the mission has started: state changes before that are the load replaying the saved
--- state, not construction progress.
RLPenConstruction.started = false


--- The bridge's construction entry for a placeable. Cached on the placeable (the config does not
--- change in a session); the state itself is never cached.
--- @return table|nil {filename, readyStates = {NAME = true}, names = {...}, source}
function RLPenConstruction.getDefinition(placeable)
    if placeable == nil then return nil end
    if placeable.rlPenConstruction ~= nil then return placeable.rlPenConstruction or nil end

    local definition = false
    local configFileName = placeable.configFileName ~= nil and placeable.configFileName:gsub("\\", "/"):lower() or nil
    if configFileName ~= nil then
        for _, entry in ipairs(RLHusbandryProfiles.getConfig().constructions or {}) do
            if configFileName:sub(-#entry.filename) == entry.filename then
                definition = entry
                break
            end
        end
    end

    -- A read-only scope (RLHusbandryProfiles.read) writes nothing on the placeable.
    if not RLHusbandryProfiles.reading() then placeable.rlPenConstruction = definition end
    return definition or nil
end


local function stateIndexByName(placeable, spec, name)
    if placeable.getConstructibleStateIndexByName ~= nil then return placeable:getConstructibleStateIndexByName(name) end
    return spec.stateNameToIndex ~= nil and spec.stateNameToIndex[name:upper()] or nil
end


--- Inputs of the current state still to be delivered.
local function unfinishedInputs(state)
    local list = {}
    for _, input in ipairs(state ~= nil and state.inputs or {}) do
        if (input.remainingAmount or 0) > 0 then
            list[#list + 1] = {
                fillType = input.fillType ~= nil and input.fillType.name or nil,
                remaining = input.remainingAmount,
                amount = input.amount,
            }
        end
    end
    return list
end


--- Whether a state index has no transition onward (the end of construction).
local function isFinalState(spec, stateIndex)
    return spec.stateTransitions ~= nil and spec.stateTransitions[stateIndex] == nil
end


--- The construction status of a husbandry, read live. Read-only.
--- @param placeable table
--- @return table {status, admit, reason, present, stateName, stateIndex, numStates, readyStates, unfinishedInputs, source}
function RLPenConstruction.getStatus(placeable)
    local spec = placeable ~= nil and placeable.spec_constructible or nil
    if spec == nil then
        return { status = RLPenConstruction.READY, admit = true, reason = "NO_CONSTRUCTION", present = false }
    end

    local stateIndex = spec.stateIndex
    local state = (stateIndex ~= nil and spec.stateMachine ~= nil) and spec.stateMachine[stateIndex] or nil
    local result = {
        present = true,
        stateIndex = stateIndex,
        stateName = state ~= nil and state.name or nil,
        numStates = spec.stateMachine ~= nil and #spec.stateMachine or nil,
        unfinishedInputs = unfinishedInputs(state),
    }

    local definition = RLPenConstruction.getDefinition(placeable)
    if definition ~= nil then
        result.readyStates = definition.names
        result.source = definition.source
    end

    if state == nil then
        result.status, result.admit, result.reason = RLPenConstruction.UNKNOWN, false, "NO_STATE"
        return result
    end

    if definition == nil then
        if isFinalState(spec, stateIndex) and #result.unfinishedInputs == 0 then
            result.status, result.admit, result.reason = RLPenConstruction.UNCHECKED, true, "NO_DEFINITION_FINAL_STATE"
        else
            result.status, result.admit, result.reason = RLPenConstruction.UNKNOWN, false, "NO_DEFINITION"
        end
        return result
    end

    local resolved = false
    for _, name in ipairs(definition.names) do
        local index = stateIndexByName(placeable, spec, name)
        if index ~= nil then
            resolved = true
            if index == stateIndex then
                result.status, result.admit, result.reason = RLPenConstruction.READY, true, "READY_STATE"
                return result
            end
        end
    end

    if not resolved then
        result.status, result.admit, result.reason = RLPenConstruction.UNKNOWN, false, "DEFINITION_UNRESOLVED"
    else
        result.status, result.admit, result.reason = RLPenConstruction.NOT_READY, false, "UNFINISHED_STATE"
    end
    return result
end


--- The building whose construction decides whether animals may come into an object: a husbandry,
--- an extended production point placeable (butcher), or the placeable owning a production point
--- that takes animals (what AnimalMoveEvent carries as an EPP target). nil for anything else.
--- @param object table|nil
--- @return table|nil placeable
function RLPenConstruction.getBuilding(object)
    if object == nil then return nil end
    if object.spec_husbandryAnimals ~= nil or object.spec_extendedProductionPoint ~= nil then return object end
    if object.animalsTypeData ~= nil and object.owningPlaceable ~= nil then return object.owningPlaceable end
    return nil
end


--- Whether a husbandry or an animal-taking production point may take animals now. True for
--- anything else.
--- @return boolean
--- @return table|nil status getStatus, when it is such a building
function RLPenConstruction.canAdmit(object)
    local building = RLPenConstruction.getBuilding(object)
    if building == nil then return true end
    local status = RLPenConstruction.getStatus(building)
    return status.admit, status
end


--- The status for a log record: nil fields dropped, the input list only when there is one.
--- A production point is described by the placeable that owns it.
--- @return table
function RLPenConstruction.describe(placeable)
    local status = RLPenConstruction.getStatus(RLPenConstruction.getBuilding(placeable) or placeable)
    if not status.present then return { present = false, status = status.status, ready = true, reason = status.reason } end
    return {
        present = true,
        status = status.status,
        ready = status.admit,
        reason = status.reason,
        stateName = status.stateName,
        stateIndex = status.stateIndex,
        numStates = status.numStates,
        readyStates = status.readyStates,
        unfinishedInputs = #status.unfinishedInputs > 0 and status.unfinishedInputs or nil,
        source = status.source,
    }
end


--- Detail text for a refusal (checkAnimal's third value).
function RLPenConstruction.detail(status)
    return string.format("construction %s %s (%s)", tostring(status.status), tostring(status.stateName), tostring(status.reason))
end


-- =============================================================================
-- Records: state changes and residents of pens that cannot take animals
-- =============================================================================

--- A constructible husbandry, or a constructible production point that takes animals.
local function isRecordedPen(placeable)
    if placeable == nil or placeable.spec_constructible == nil then return false end
    if placeable.spec_husbandryAnimals ~= nil then return true end
    local epp = placeable.spec_extendedProductionPoint
    return epp ~= nil and epp.productionPoint ~= nil and epp.productionPoint.animalsTypeData ~= nil
end


--- Record a construction state change of a husbandry or butcher (server, after the mission has started).
--- A CHANGE on a husbandry with no state recorded yet is its first state after being placed (PLACED).
--- @param placeable table
--- @param trigger string LOAD or CHANGE
function RLPenConstruction.onStateChanged(placeable, trigger)
    if not isRecordedPen(placeable) then return end
    local spec = placeable.spec_constructible
    local previous = placeable.rlConstructionState
    local stateIndex = spec.stateIndex
    if trigger ~= "LOAD" and previous ~= nil and previous.index == stateIndex then return end
    if trigger == "CHANGE" and previous == nil then trigger = "PLACED" end

    local current = RLPenConstruction.describe(placeable)
    local data = {
        pen = RLPenLog.pen(placeable),
        trigger = trigger,
        construction = current,
    }
    if previous ~= nil and trigger ~= "LOAD" then
        data.from = { stateName = previous.name, stateIndex = previous.index, ready = previous.ready }
        data.direction = (stateIndex or 0) < (previous.index or 0) and "BACK" or "FORWARD"
        data.opened = previous.ready == false and current.ready == true
        data.closed = previous.ready == true and current.ready == false
    end
    placeable.rlConstructionState = { index = stateIndex, name = current.stateName, ready = current.ready }
    RLPenLog.emit("CONSTRUCTION_STATE", data, current.status == RLPenConstruction.UNKNOWN or data.closed == true)
end


--- What the pen's trough holds, by fill type name, for a resident record.
local function troughLevels(placeable)
    local food = placeable.spec_husbandryFood
    if food == nil or food.fillLevels == nil then return nil end
    local levels = {}
    for fillTypeIndex, level in pairs(food.fillLevels) do
        local name = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex) or tostring(fillTypeIndex)
        levels[name] = level
    end
    return levels
end


local function residentKey(animal)
    return tostring(animal.farmId) .. " " .. tostring(animal.uniqueId)
end


local function isBornHere(animal, residents)
    if (animal.age or 0) ~= 0 or animal.motherId == nil then return false end
    for _, other in pairs(residents) do
        if other ~= animal and other.getIdentifiers ~= nil and other:getIdentifiers() == animal.motherId then return true end
    end
    return false
end


--- Log the animals of a husbandry that cannot take animals: identity, age, health, weight, the
--- trough and the construction inputs still missing. Server only; nothing is moved, sold, healed
--- or built. At LOAD every resident is INVALID_RESIDENT_UNBUILT; on later days a resident not seen
--- before is a birth (RESIDENT_BORN_UNBUILT, its mother in the pen) or an animal that got in some
--- other way (ADMITTED_WHILE_UNBUILT, which no path should allow).
--- @param placeable table
--- @param trigger string LOAD or DAY
--- @return number residents logged
function RLPenConstruction.checkResidents(placeable, trigger)
    local spec = placeable ~= nil and placeable.spec_husbandryAnimals or nil
    if spec == nil or spec.clusterSystem == nil or placeable.spec_constructible == nil then return 0 end

    local admit, status = RLPenConstruction.canAdmit(placeable)
    if admit then
        placeable.rlUnbuiltResidents = nil
        return 0
    end

    local known = placeable.rlUnbuiltResidents
    local seen, count = {}, 0
    local residents = spec.clusterSystem:getClusters() or {}
    local construction, trough = nil, nil
    for _, animal in pairs(residents) do
        if not animal.isDead then
            count = count + 1
            local key = residentKey(animal)
            seen[key] = true
            local kind = "INVALID_RESIDENT_UNBUILT"
            local isNew = known == nil or not known[key]
            if trigger ~= "LOAD" and known ~= nil and isNew then
                kind = isBornHere(animal, residents) and "RESIDENT_BORN_UNBUILT" or "ADMITTED_WHILE_UNBUILT"
            end
            construction = construction or RLPenConstruction.describe(placeable)
            trough = trough or troughLevels(placeable)
            local record = RLPenLog.animal(animal)
            record.health = animal.health
            RLPenLog.emit(kind, {
                pen = RLPenLog.pen(placeable),
                animal = record,
                construction = construction,
                trough = trough,
                trigger = trigger,
            }, isNew)
        end
    end
    placeable.rlUnbuiltResidents = seen
    return count
end


--- Record every constructible husbandry's and butcher's state, and the husbandries' residents (after loading).
function RLPenConstruction.checkAll(trigger)
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    local total = 0
    for _, placeable in ipairs(placeableSystem ~= nil and placeableSystem.placeables or {}) do
        if isRecordedPen(placeable) then
            RLPenConstruction.onStateChanged(placeable, trigger)
            total = total + RLPenConstruction.checkResidents(placeable, trigger)
        end
    end
    return total
end


--- Mission start (server): from now on state changes are construction progress.
function RLPenConstruction.onMissionStarted()
    local count = RLPenConstruction.checkAll("LOAD")
    RLPenConstruction.started = true
    if count > 0 then
        Log:warning("RLPenConstruction: %d animal(s) live in husbandries that are not built yet (left where they are)", count)
    end
end


-- Every construction state change goes through ConstructibleState:activate (the building and
-- finalize states call it as their super), after spec.stateIndex holds the new state.
if ConstructibleState ~= nil and ConstructibleState.activate ~= nil then
    ConstructibleState.activate = Utils.appendedFunction(ConstructibleState.activate, function(state)
        local placeable = state.constructible
        if RLPenConstruction.started and placeable ~= nil and placeable.isServer then
            RmSafeUtils.safeCall("RLPenConstruction.onStateChanged", function()
                RLPenConstruction.onStateChanged(placeable, "CHANGE")
            end)
        end
    end)
end

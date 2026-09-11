--[[
    Abandoned Taiga - Construction Lifecycle Fix
    FS25

    Purpose:
      * unfinished constructible production points are hidden from the production manager;
      * all non-construction load/unload/production interaction triggers are blocked until DONE;
      * the info trigger shows only construction-related information while building;
      * finished ProductionPoint + ObjectStorage composites get grouped HUD sections;
      * optional #StateName is shown as the human-readable stage name;
      * leftover palletizable construction materials are spawned as pallets before GIANTS empties
        the construction storage during finalizeConstruction().

    Designed to coexist with FS25_ConstructionProgressDisplay.
]]

TaigaConstructionLifecycleFix = TaigaConstructionLifecycleFix or {}
local TCLF = TaigaConstructionLifecycleFix

TCLF.VERSION = "0.1.5"
TCLF.LOG_PREFIX = "[TaigaConstructionLifecycleFix]"
TCLF.SCAN_INTERVAL_MS = 1000
TCLF.SPAWN_SPACING = 1.8
TCLF.SPAWN_COLUMNS = 4
TCLF.SPAWN_FORWARD_OFFSET = 2.5

TCLF.scanTimer = 0
TCLF.palletQueue = TCLF.palletQueue or {}
TCLF.currentPalletJob = nil
TCLF.hooksInstalled = false

local function logInfo(formatString, ...)
    Logging.info("%s %s", TCLF.LOG_PREFIX, string.format(formatString, ...))
end

local function logWarning(formatString, ...)
    Logging.warning("%s %s", TCLF.LOG_PREFIX, string.format(formatString, ...))
end

local function getPlaceableName(placeable)
    if placeable == nil then
        return "<nil>"
    end

    if placeable.getName ~= nil then
        local name = placeable:getName()
        if name ~= nil and name ~= "" then
            return tostring(name)
        end
    end

    return tostring(placeable.configFileName or placeable)
end

-- A constructible is considered unfinished while its current state has a transition.
-- In the stock state machine FINALIZE -> DONE still has a transition, while DONE has none.
function TCLF.isUnderConstruction(placeable)
    if placeable == nil then
        return false
    end

    local spec = placeable.spec_constructible
    if spec == nil or spec.stateIndex == nil or spec.stateIndex < 1 then
        return false
    end

    return spec.stateTransitions ~= nil and spec.stateTransitions[spec.stateIndex] ~= nil
end

function TCLF.isConstructionUnloadingStation(placeable, station)
    local spec = placeable ~= nil and placeable.spec_constructible or nil
    return spec ~= nil and spec.unloadingStation ~= nil and station == spec.unloadingStation
end

-- Blocks stations belonging to an unfinished constructible, except the construction-material
-- unloading station itself. That exception is essential: players must still be able to deliver
-- materials required by the current construction stage.
function TCLF.isBlockedStation(station)
    if station == nil then
        return false
    end

    local placeable = station.owningPlaceable
    if placeable == nil or not TCLF.isUnderConstruction(placeable) then
        return false
    end

    return not TCLF.isConstructionUnloadingStation(placeable, station)
end

function TCLF.isBlockedLoadTrigger(trigger)
    return trigger ~= nil and TCLF.isBlockedStation(trigger.source)
end

function TCLF.isBlockedUnloadTrigger(trigger)
    return trigger ~= nil and TCLF.isBlockedStation(trigger.target)
end

-- Finished composite HUD ---------------------------------------------------
--
-- Some placeables combine more than one fully-fledged facility specialization in
-- the same physical building.  The first supported combination is:
--   * PlaceableProductionPoint (liquid/bulk production storage + productions)
--   * PlaceableObjectStorage   (physical pallet/bale warehouse)
--
-- This is deliberately detected by specialization presence, never by placeable
-- type or XML filename.  A future composite can therefore reuse the same logic.
function TCLF.isProductionObjectStorageComposite(placeable)
    if placeable == nil then
        return false
    end

    local productionSpec = placeable.spec_productionPoint
    local objectStorageSpec = placeable.spec_objectStorage

    return productionSpec ~= nil
        and productionSpec.productionPoint ~= nil
        and objectStorageSpec ~= nil
end

function TCLF.useFinishedCompositeInfo(placeable)
    if not TCLF.isProductionObjectStorageComposite(placeable) then
        return false
    end

    -- A constructible composite keeps the construction-only HUD until DONE.
    -- A non-constructible production+objectStorage can use the grouped HUD immediately.
    return not TCLF.isUnderConstruction(placeable)
end

local function addHudSection(infoTable, title)
    -- Stock FS25 uses accentuate=true for informational ProductionPoint section
    -- headers. On the desktop HUD this gives the familiar green section heading
    -- (and the stock field-info marker), visually separating the following rows.
    table.insert(infoTable, {
        title = title,
        accentuate = true
    })
end

local function addCompositeOwnerInfo(productionPoint, infoTable)
    if productionPoint == nil or g_farmManager == nil then
        return
    end

    local ownerFarm = g_farmManager:getFarmById(productionPoint:getOwnerFarmId())
    if ownerFarm ~= nil and not string.isNilOrWhitespace(ownerFarm.name) then
        table.insert(infoTable, {
            title = g_i18n:getText("fieldInfo_ownedBy"),
            text = ownerFarm.name
        })
    end
end

local function addCompositeProductionInfo(productionPoint, infoTable)
    addHudSection(infoTable, "Производство")

    local activeProductions = productionPoint.activeProductions or {}
    if #activeProductions > 0 then
        for i = 1, #activeProductions do
            local production = activeProductions[i]
            local status = productionPoint:getProductionStatus(production.id)
            local statusKey = ProductionPoint.PROD_STATUS_TO_L10N[status]
            local statusText = statusKey ~= nil and g_i18n:getText(statusKey) or tostring(status or "")

            table.insert(infoTable, {
                title = production.name
                    or g_fillTypeManager:getFillTypeTitleByIndex(production.primaryProductFillType),
                text = statusText
            })
        end
    else
        table.insert(infoTable, {
            title = "",
            text = g_i18n:getText("infohud_noActiveProduction")
        })
    end
end

local function addCompositeProductionStorageInfo(productionPoint, infoTable)
    addHudSection(infoTable, "Производственное хранилище")

    local displayed = false
    local seenFillTypes = {}

    local function addFillType(fillTypeIndex)
        if fillTypeIndex == nil or seenFillTypes[fillTypeIndex] then
            return
        end
        seenFillTypes[fillTypeIndex] = true

        local fillLevel = productionPoint:getFillLevel(fillTypeIndex)
        if fillLevel ~= nil and fillLevel > 0.1 then
            table.insert(infoTable, {
                title = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex),
                text = g_i18n:formatVolume(fillLevel, 0)
            })
            displayed = true
        end
    end

    for i = 1, #(productionPoint.inputFillTypeIdsArray or {}) do
        addFillType(productionPoint.inputFillTypeIdsArray[i])
    end
    for i = 1, #(productionPoint.outputFillTypeIdsArray or {}) do
        addFillType(productionPoint.outputFillTypeIdsArray[i])
    end

    if not displayed then
        table.insert(infoTable, {
            title = "",
            text = g_i18n:getText("infohud_storageIsEmpty")
        })
    end

    -- This is a real warning, so keeping the native warning accent is intentional.
    if productionPoint.palletLimitReached and productionPoint.infoTables ~= nil
        and productionPoint.infoTables.palletLimitReached ~= nil then
        table.insert(infoTable, productionPoint.infoTables.palletLimitReached)
    end
end

local function normalizeFilename(filename)
    if filename == nil then
        return nil
    end
    return string.lower(string.gsub(tostring(filename), "\\", "/"))
end

local function filenameBasename(filename)
    filename = normalizeFilename(filename)
    if filename == nil then
        return nil
    end
    return string.match(filename, "([^/]+)$") or filename
end

local function normalizeFillTypeIndex(value)
    if type(value) == "number" then
        local fillType = g_fillTypeManager:getFillTypeByIndex(value)
        return fillType ~= nil and value or nil
    end

    if type(value) == "table" and type(value.index) == "number" then
        return value.index
    end

    return nil
end

local function tryGetAbstractObjectFillTypeIndex(placeable, abstractObject)
    if abstractObject == nil then
        return nil
    end

    -- Different abstract object classes expose their fill type differently.
    -- Prefer direct metadata when available and keep every probe protected so a
    -- third-party abstract storage object cannot break the HUD.
    local directFields = {"fillTypeIndex", "fillTypeId", "fillType"}
    for _, fieldName in ipairs(directFields) do
        local index = normalizeFillTypeIndex(abstractObject[fieldName])
        if index ~= nil then
            return index
        end
    end

    local methodNames = {"getFillTypeIndex", "getFillType"}
    for _, methodName in ipairs(methodNames) do
        local method = abstractObject[methodName]
        if type(method) == "function" then
            local ok, value = pcall(method, abstractObject)
            if ok then
                local index = normalizeFillTypeIndex(value)
                if index ~= nil then
                    return index
                end
            end
        end
    end

    -- Pallet abstract objects always retain their source XML filename.  Match it
    -- to fillType.palletFilename so the warehouse shows "Говядина" instead of
    -- "Поддон (Говядина 1 000 л)".  Start with the storage's supported fill types
    -- and fall back to the manager table for storages that accept every fill type.
    local objectFilename = nil
    if type(abstractObject.getXMLFilename) == "function" then
        local ok, value = pcall(abstractObject.getXMLFilename, abstractObject)
        if ok then
            objectFilename = value
        end
    end

    local normalizedObjectFilename = normalizeFilename(objectFilename)
    local objectBasename = filenameBasename(objectFilename)
    if normalizedObjectFilename == nil then
        return nil
    end

    local function matchesFillType(fillTypeIndex)
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillType == nil or fillType.palletFilename == nil then
            return false
        end

        local palletFilename = normalizeFilename(fillType.palletFilename)
        if palletFilename == normalizedObjectFilename then
            return true
        end

        return filenameBasename(palletFilename) == objectBasename
    end

    local objectStorageSpec = placeable.spec_objectStorage
    if objectStorageSpec ~= nil and objectStorageSpec.supportedFillTypes ~= nil then
        for _, fillTypeIndex in ipairs(objectStorageSpec.supportedFillTypes) do
            if matchesFillType(fillTypeIndex) then
                return fillTypeIndex
            end
        end
    end

    -- The stock FillTypeManager exposes its registered fill types as a table.
    -- Use it only as a fallback when the object storage did not restrict fill types.
    if g_fillTypeManager.fillTypes ~= nil then
        for key, fillType in pairs(g_fillTypeManager.fillTypes) do
            local fillTypeIndex = type(fillType) == "table" and fillType.index or key
            if type(fillTypeIndex) == "number" and matchesFillType(fillTypeIndex) then
                return fillTypeIndex
            end
        end
    end

    return nil
end

local function getCompositeObjectStorageTitle(placeable, abstractObject)
    local fillTypeIndex = tryGetAbstractObjectFillTypeIndex(placeable, abstractObject)
    if fillTypeIndex ~= nil then
        return g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)
    end

    if abstractObject ~= nil and type(abstractObject.getDialogText) == "function" then
        local ok, title = pcall(abstractObject.getDialogText, abstractObject)
        if ok and title ~= nil and title ~= "" then
            title = tostring(title)
            if utf8Strlen(title) > 32 then
                title = utf8Substr(title, 0, 32) .. "..."
            end
            return title
        end
    end

    return "Объект"
end

local function addCompositeObjectStorageInfo(placeable, infoTable)
    local spec = placeable.spec_objectStorage
    if spec == nil then
        return
    end

    addHudSection(
        infoTable,
        string.format(
            "Складское хранилище (%d / %d)",
            spec.numStoredObjects or 0,
            spec.capacity or 0
        )
    )

    -- Native ObjectStorage groups "identical" abstract objects. For pallets that
    -- can still split the same product into multiple rows when the fill level differs.
    -- The composite HUD groups them by fill type/display title so e.g. three beef
    -- pallets are shown as one row: "Говядина ... 3".
    local groupedEntries = {}
    local groupedByKey = {}
    local objectInfos = spec.objectInfos or {}

    for i = 1, #objectInfos do
        local objectInfo = objectInfos[i]
        local abstractObject = objectInfo ~= nil and objectInfo.objects ~= nil and objectInfo.objects[1] or nil
        if abstractObject ~= nil then
            local fillTypeIndex = tryGetAbstractObjectFillTypeIndex(placeable, abstractObject)
            local title = fillTypeIndex ~= nil
                and g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)
                or getCompositeObjectStorageTitle(placeable, abstractObject)
            local key = fillTypeIndex ~= nil
                and ("fillType:" .. tostring(fillTypeIndex))
                or ("title:" .. tostring(title))
            local count = objectInfo.numObjects or #objectInfo.objects

            local groupedEntry = groupedByKey[key]
            if groupedEntry == nil then
                groupedEntry = {
                    title = title,
                    count = 0
                }
                groupedByKey[key] = groupedEntry
                table.insert(groupedEntries, groupedEntry)
            end
            groupedEntry.count = groupedEntry.count + count
        end
    end

    local maxEntries = PlaceableObjectStorage ~= nil
        and PlaceableObjectStorage.MAX_HUD_INFO_ENTRIES
        or #groupedEntries
    local numEntries = math.min(#groupedEntries, maxEntries)

    for i = 1, numEntries do
        local entry = groupedEntries[i]
        table.insert(infoTable, {
            title = entry.title,
            text = tostring(entry.count)
        })
    end

    if #groupedEntries > maxEntries then
        local sumOthers = 0
        for i = maxEntries + 1, #groupedEntries do
            sumOthers = sumOthers + groupedEntries[i].count
        end

        table.insert(infoTable, {
            title = spec.texts ~= nil and spec.texts.otherElements or "Прочее",
            text = tostring(sumOthers)
        })
    end
end

function TCLF.addFinishedCompositeInfo(placeable, infoTable)
    if not TCLF.useFinishedCompositeInfo(placeable) then
        return
    end

    local productionSpec = placeable.spec_productionPoint
    local productionPoint = productionSpec ~= nil and productionSpec.productionPoint or nil
    if productionPoint == nil then
        return
    end

    addCompositeOwnerInfo(productionPoint, infoTable)
    addCompositeProductionInfo(productionPoint, infoTable)
    addCompositeProductionStorageInfo(productionPoint, infoTable)
    addCompositeObjectStorageInfo(placeable, infoTable)
end

local function getConfiguredStateDisplayName(placeable, stateIndex)
    if placeable == nil or placeable.xmlFile == nil or stateIndex == nil or stateIndex < 1 then
        return nil
    end

    local key = string.format(
        "placeable.constructible.stateMachine.states.state(%d)#StateName",
        stateIndex - 1
    )

    local value = nil
    if placeable.xmlFile.getI18NValue ~= nil then
        value = placeable.xmlFile:getI18NValue(key, nil, placeable.customEnvironment, false)
    else
        value = placeable.xmlFile:getValue(key)
    end

    if value == nil then
        return nil
    end

    value = tostring(value)
    if string.match(value, "^%s*$") then
        return nil
    end

    return value
end

local function addConstructionInfo(placeable, infoTable)
    local spec = placeable.spec_constructible
    if spec == nil then
        return
    end

    local finishedStates, numConstructibleStates = placeable:getNumFinishedConstructibleStates()
    if finishedStates < numConstructibleStates then
        local stateName = getConfiguredStateDisplayName(placeable, spec.stateIndex)
        local progressText = string.format("(%d / %d)", finishedStates, numConstructibleStates)

        if stateName ~= nil then
            progressText = string.format("%s %s", stateName, progressText)
        end

        table.insert(infoTable, {
            title = g_i18n:getText("ui_construction_state"),
            text = progressText
        })
    end

    -- Only the dedicated construction storage is shown here. We deliberately do not call the
    -- normal specialization chain while building, because that chain also adds silo/production
    -- storage rows that belong to the future finished facility.
    spec.fillTypesAndLevelsAuxiliary = spec.fillTypesAndLevelsAuxiliary or {}
    spec.fillTypeToFillTypeStorageTable = spec.fillTypeToFillTypeStorageTable or {}
    spec.infoTriggerFillTypesAndLevels = spec.infoTriggerFillTypesAndLevels or {}

    table.clear(spec.fillTypesAndLevelsAuxiliary)
    for fillType, fillLevel in pairs(spec.storage:getFillLevels()) do
        spec.fillTypesAndLevelsAuxiliary[fillType] =
            (spec.fillTypesAndLevelsAuxiliary[fillType] or 0) + fillLevel
    end

    table.clear(spec.infoTriggerFillTypesAndLevels)
    for fillType, fillLevel in pairs(spec.fillTypesAndLevelsAuxiliary) do
        if fillLevel > 0.1 then
            local entry = spec.fillTypeToFillTypeStorageTable[fillType]
            if entry == nil then
                entry = {
                    fillType = fillType,
                    fillLevel = fillLevel
                }
                spec.fillTypeToFillTypeStorageTable[fillType] = entry
            end

            entry.fillLevel = fillLevel
            table.insert(spec.infoTriggerFillTypesAndLevels, entry)
        end
    end
    table.clear(spec.fillTypesAndLevelsAuxiliary)

    table.sort(spec.infoTriggerFillTypesAndLevels, function(a, b)
        return a.fillLevel > b.fillLevel
    end)

    -- Vanilla PlaceableConstructible limits the info HUD to the 7 largest fill levels.
    -- On this map the construction storage can contain more material types (NAILS, OSB, etc.),
    -- so the smaller entries disappeared from the HUD although they were really stored.
    -- For unfinished constructibles show every non-empty construction material.
    local numEntries = #spec.infoTriggerFillTypesAndLevels
    if numEntries > 0 then
        if spec.infoTableEntryStorage ~= nil then
            table.insert(infoTable, spec.infoTableEntryStorage)
        end

        for i = 1, numEntries do
            local entry = spec.infoTriggerFillTypesAndLevels[i]
            table.insert(infoTable, {
                title = g_fillTypeManager:getFillTypeTitleByIndex(entry.fillType),
                text = g_i18n:formatVolume(entry.fillLevel, 0)
            })
        end
    end

    local state = spec.stateMachine ~= nil and spec.stateMachine[spec.stateIndex] or nil
    if state ~= nil and state.updateInfo ~= nil then
        state:updateInfo(infoTable)
    end
end

local function suspendProductionPoint(placeable)
    local spec = placeable.spec_productionPoint
    local productionPoint = spec ~= nil and spec.productionPoint or nil
    if productionPoint == nil then
        return
    end

    if not placeable.tclfProductionSuspended then
        placeable.tclfProductionSuspended = true
        placeable.tclfProductionDefaultAllowMissions =
            productionPoint.unloadingStation ~= nil and productionPoint.unloadingStation.allowMissions or nil

        logInfo("Suspending unfinished production: %s", getPlaceableName(placeable))
    end

    -- Correct even XMLs that forgot productionPoint#isFinalized="false".
    spec.isFinalized = false
    productionPoint.isFinalized = false

    if productionPoint.unloadingStation ~= nil then
        productionPoint.unloadingStation.hideFromPricesMenu = true
        productionPoint.unloadingStation.allowMissions = false
    end

    -- Keep this idempotent and repeat it during the scan. Other ownership/setup code is allowed
    -- to re-register a ProductionPoint; the next scan removes it again while construction is active.
    local manager = g_currentMission ~= nil and g_currentMission.productionChainManager or nil
    if manager ~= nil then
        manager:removeProductionPoint(productionPoint)
    end

    if productionPoint.updateFxState ~= nil then
        productionPoint:updateFxState()
    end
end

local function clearSuspendedFlag(placeable)
    if not placeable.tclfProductionSuspended then
        return
    end

    local spec = placeable.spec_productionPoint
    local productionPoint = spec ~= nil and spec.productionPoint or nil

    -- Normally PlaceableProductionPoint:finalizeConstruction() has already done the actual
    -- re-registration. These assignments only make the state explicit if another mod reordered hooks.
    if productionPoint ~= nil then
        spec.isFinalized = true
        productionPoint.isFinalized = true
        if productionPoint.unloadingStation ~= nil then
            productionPoint.unloadingStation.hideFromPricesMenu = false
            if spec.unloadingStationDefaultAllowMissions ~= nil then
                productionPoint.unloadingStation.allowMissions = spec.unloadingStationDefaultAllowMissions
            elseif placeable.tclfProductionDefaultAllowMissions ~= nil then
                productionPoint.unloadingStation.allowMissions = placeable.tclfProductionDefaultAllowMissions
            end
        end
        if productionPoint.updateFxState ~= nil then
            productionPoint:updateFxState()
        end
    end

    placeable.tclfProductionSuspended = false
    placeable.tclfProductionDefaultAllowMissions = nil
    logInfo("Construction finished, production released: %s", getPlaceableName(placeable))
end

function TCLF.scanPlaceables()
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then
        return
    end

    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        if placeable.spec_constructible ~= nil and placeable.spec_productionPoint ~= nil then
            if TCLF.isUnderConstruction(placeable) then
                suspendProductionPoint(placeable)
            else
                clearSuspendedFlag(placeable)
            end
        end
    end
end

local function getPalletDefinition(fillTypeIndex)
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType == nil or fillType.palletFilename == nil or fillType.palletFilename == "" then
        return nil
    end

    local palletXml = XMLFile.load("tclfPalletXml", fillType.palletFilename, Vehicle.xmlSchema)
    if palletXml == nil then
        return nil
    end

    local capacity = FillUnit.getCapacityFromXml(palletXml)
    palletXml:delete()

    if capacity == nil or capacity <= 0 then
        return nil
    end

    return {
        filename = fillType.palletFilename,
        capacity = capacity,
        title = fillType.title or g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)
    }
end

local function getSpawnAnchor(placeable)
    local node = nil
    local spec = placeable.spec_constructible

    if spec ~= nil and spec.unloadingStation ~= nil and spec.unloadingStation.unloadTriggers ~= nil then
        local trigger = spec.unloadingStation.unloadTriggers[1]
        if trigger ~= nil then
            node = trigger.exactFillRootNode or trigger.triggerNode or trigger.rootNode
        end
    end

    if node == nil or node == 0 then
        node = placeable.rootNode or (placeable.components ~= nil and placeable.components[1] ~= nil and placeable.components[1].node or nil)
    end

    if node == nil or node == 0 then
        return nil
    end

    return node
end

local function enqueueResidualPallets(placeable, fillTypeIndex, amount, palletDefinition, startSlot)
    local farmId = placeable:getOwnerFarmId()
    local anchorNode = getSpawnAnchor(placeable)
    if anchorNode == nil then
        logWarning(
            "Cannot spawn leftover %s (%.1f L) for %s: no anchor node",
            tostring(palletDefinition.title),
            amount,
            getPlaceableName(placeable)
        )
        return startSlot
    end

    local remaining = amount
    local slot = startSlot
    while remaining > 0.1 do
        local chunk = math.min(remaining, palletDefinition.capacity)
        table.insert(TCLF.palletQueue, {
            placeable = placeable,
            placeableName = getPlaceableName(placeable),
            anchorNode = anchorNode,
            fillTypeIndex = fillTypeIndex,
            amount = chunk,
            filename = palletDefinition.filename,
            title = palletDefinition.title,
            farmId = farmId,
            slot = slot
        })
        remaining = remaining - chunk
        slot = slot + 1
    end

    return slot
end

function TCLF.captureConstructionResiduals(placeable)
    if placeable == nil or not placeable.isServer then
        return
    end

    local spec = placeable.spec_constructible
    if spec == nil or spec.storage == nil then
        return
    end

    local slot = 0
    local queued = 0

    for fillTypeIndex, amount in pairs(spec.storage:getFillLevels()) do
        if amount ~= nil and amount > 0.1 then
            local palletDefinition = getPalletDefinition(fillTypeIndex)
            if palletDefinition ~= nil then
                local oldSlot = slot
                slot = enqueueResidualPallets(placeable, fillTypeIndex, amount, palletDefinition, slot)
                queued = queued + (slot - oldSlot)
            else
                logWarning(
                    "Leftover material cannot be palletized and will be cleared by vanilla finalize: %s = %.1f L (%s)",
                    tostring(g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)),
                    amount,
                    getPlaceableName(placeable)
                )
            end
        end
    end

    if queued > 0 then
        logInfo("Queued %d residual pallet(s) before finalizing %s", queued, getPlaceableName(placeable))
    end
end

function TCLF.finalizeConstruction(placeable, superFunc)
    -- Must happen before superFunc: vanilla PlaceableConstructible:finalizeConstruction()
    -- starts by emptying spec_constructible.storage.
    TCLF.captureConstructionResiduals(placeable)
    return superFunc(placeable)
end

local function getPalletSpawnPosition(job)
    local column = job.slot % TCLF.SPAWN_COLUMNS
    local row = math.floor(job.slot / TCLF.SPAWN_COLUMNS)

    local centerColumn = (TCLF.SPAWN_COLUMNS - 1) * 0.5
    local offsetX = (column - centerColumn) * TCLF.SPAWN_SPACING
    local offsetZ = TCLF.SPAWN_FORWARD_OFFSET + row * TCLF.SPAWN_SPACING

    local x, _, z = localToWorld(job.anchorNode, offsetX, 0, offsetZ)
    local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.25

    local _, rotY, _ = getWorldRotation(job.anchorNode)
    return x, terrainY, z, rotY
end

function TCLF:startNextPalletJob()
    if TCLF.currentPalletJob ~= nil or #TCLF.palletQueue == 0 then
        return
    end

    local job = TCLF.palletQueue[1]

    if g_currentMission == nil or g_currentMission.slotSystem == nil then
        return
    end

    if not g_currentMission.slotSystem:getCanAddLimitedObjects(SlotSystem.LIMITED_OBJECT_PALLET, 1) then
        logWarning(
            "Pallet limit reached. Leftover pallet not spawned: %s %.1f L (%s)",
            tostring(job.title),
            job.amount,
            job.placeableName
        )
        table.remove(TCLF.palletQueue, 1)
        return
    end

    if job.anchorNode == nil or job.anchorNode == 0 or not entityExists(job.anchorNode) then
        logWarning("Residual pallet anchor disappeared for %s", job.placeableName)
        table.remove(TCLF.palletQueue, 1)
        return
    end

    local x, y, z, rotY = getPalletSpawnPosition(job)
    TCLF.currentPalletJob = job

    local data = VehicleLoadingData.new()
    data:setFilename(job.filename)
    data:setPosition(x, y, z)
    data:setRotation(0, rotY, 0)
    data:setPropertyState(VehiclePropertyState.OWNED)
    data:setOwnerFarmId(job.farmId)
    data:setCustomParameter("spawnEmpty", true)
    data:load(TCLF.onResidualPalletLoaded, TCLF)
end

function TCLF:onResidualPalletLoaded(vehicles, vehicleLoadState)
    local job = TCLF.currentPalletJob
    TCLF.currentPalletJob = nil
    table.remove(TCLF.palletQueue, 1)

    if job == nil then
        return
    end

    if vehicleLoadState ~= VehicleLoadingState.OK or vehicles == nil or vehicles[1] == nil then
        logWarning("Failed to load residual pallet %s for %s", tostring(job.title), job.placeableName)
        return
    end

    local pallet = vehicles[1]
    if pallet.getFirstValidFillUnitToFill == nil or pallet.addFillUnitFillLevel == nil then
        logWarning("Spawned object is not a fillable pallet for %s", tostring(job.title))
        pallet:delete()
        return
    end

    local fillUnitIndex = pallet:getFirstValidFillUnitToFill(job.fillTypeIndex)
    if fillUnitIndex == nil then
        logWarning("No compatible fill unit on pallet %s for %s", tostring(job.title), job.placeableName)
        pallet:delete()
        return
    end

    local added = pallet:addFillUnitFillLevel(
        job.farmId,
        fillUnitIndex,
        job.amount,
        job.fillTypeIndex,
        ToolType.UNDEFINED,
        nil
    )

    if added == nil or added <= 0 then
        logWarning("Could not fill residual pallet %s for %s", tostring(job.title), job.placeableName)
        pallet:delete()
        return
    end

    if math.abs(added - job.amount) > 0.1 then
        logWarning(
            "Residual pallet accepted only %.1f / %.1f L of %s (%s)",
            added,
            job.amount,
            tostring(job.title),
            job.placeableName
        )
    end
end

-- -------------------------------------------------------------------------
-- Trigger guards
-- -------------------------------------------------------------------------

function TCLF.productionInteractionTriggerCallback(productionPoint, superFunc, ...)
    if productionPoint ~= nil and TCLF.isUnderConstruction(productionPoint.owningPlaceable) then
        return
    end
    return superFunc(productionPoint, ...)
end

function TCLF.loadTriggerCallback(trigger, superFunc, ...)
    if TCLF.isBlockedLoadTrigger(trigger) then
        if trigger.isLoading and trigger.setIsLoading ~= nil then
            trigger:setIsLoading(false)
        end
        return
    end
    return superFunc(trigger, ...)
end

function TCLF.loadTriggerUpdate(trigger, superFunc, dt)
    if TCLF.isBlockedLoadTrigger(trigger) then
        if trigger.isLoading and trigger.setIsLoading ~= nil then
            trigger:setIsLoading(false)
        end
        return
    end
    return superFunc(trigger, dt)
end

function TCLF.loadTriggerGetIsFillTypeSupported(trigger, superFunc, fillType)
    if TCLF.isBlockedLoadTrigger(trigger) then
        return false
    end
    return superFunc(trigger, fillType)
end

function TCLF.unloadTriggerGetIsFillTypeSupported(trigger, superFunc, fillType)
    if TCLF.isBlockedUnloadTrigger(trigger) then
        return false
    end
    return superFunc(trigger, fillType)
end

function TCLF.unloadTriggerGetFillUnitFreeCapacity(trigger, superFunc, ...)
    if TCLF.isBlockedUnloadTrigger(trigger) then
        return 0
    end
    return superFunc(trigger, ...)
end

function TCLF.unloadTriggerAddFillUnitFillLevel(trigger, superFunc, ...)
    if TCLF.isBlockedUnloadTrigger(trigger) then
        return 0
    end
    return superFunc(trigger, ...)
end

-- -------------------------------------------------------------------------
-- Info-HUD guards for specializations of the FUTURE finished facility.
--
-- PlaceableConstructible:updateInfo() can suppress specializations that are
-- earlier in the updateInfo chain by not calling its superFunc. However, a
-- specialization registered AFTER constructible can still call the
-- constructible chain and then append its own rows afterwards. ObjectStorage
-- is one such specialization (e.g. "Total capacity 0 / 120").
--
-- These wrappers preserve the native specialization signature
--     updateInfo(self, superFunc, infoTable)
-- and, while the object is unfinished, call only superFunc so the construction
-- HUD remains visible but the future specialization contributes no rows.
-- -------------------------------------------------------------------------

local function installFutureFacilityInfoGuard(classTable, className)
    if classTable == nil or classTable.updateInfo == nil then
        return false
    end

    local guardName = "tclfConstructionInfoGuardInstalled"
    if classTable[guardName] then
        return false
    end

    local isProductionPointClass = classTable == PlaceableProductionPoint
    local isObjectStorageClass = classTable == PlaceableObjectStorage
    local originalUpdateInfo = classTable.updateInfo

    classTable.updateInfo = function(placeable, superFunc, infoTable)
        if TCLF.isUnderConstruction(placeable) then
            return superFunc(placeable, infoTable)
        end

        if TCLF.useFinishedCompositeInfo(placeable) then
            -- Suppress the native ProductionPoint block.  Otherwise it would still
            -- inject owner + production + "building storage" into one flat section.
            if isProductionPointClass then
                return superFunc(placeable, infoTable)
            end

            -- ObjectStorage is our single injection point for the grouped composite
            -- HUD. This remains correct regardless of whether ProductionPoint is
            -- registered before or after ObjectStorage in the specialization chain.
            if isObjectStorageClass then
                local result = superFunc(placeable, infoTable)
                TCLF.addFinishedCompositeInfo(placeable, infoTable)
                return result
            end
        end

        return originalUpdateInfo(placeable, superFunc, infoTable)
    end

    classTable[guardName] = true
    logInfo("%s info HUD construction/composite guard installed", className)
    return true
end

-- ObjectStorage has its own player/object triggers and does not necessarily
-- use LoadTrigger/UnloadTrigger. Keep those triggers inert until construction
-- reaches DONE, otherwise an invisible warehouse can already accept objects.
local function installObjectStorageConstructionGuards()
    if PlaceableObjectStorage == nil or PlaceableObjectStorage.tclfConstructionTriggerGuardsInstalled then
        return
    end

    if PlaceableObjectStorage.onObjectStoragePlayerTriggerCallback ~= nil then
        local original = PlaceableObjectStorage.onObjectStoragePlayerTriggerCallback
        PlaceableObjectStorage.onObjectStoragePlayerTriggerCallback = function(placeable, ...)
            if TCLF.isUnderConstruction(placeable) then
                local spec = placeable.spec_objectStorage
                local system = g_currentMission ~= nil and g_currentMission.activatableObjectsSystem or nil
                if spec ~= nil and system ~= nil then
                    if spec.activatable ~= nil then
                        system:removeActivatable(spec.activatable)
                    end
                    if spec.manualStoreActivatable ~= nil then
                        system:removeActivatable(spec.manualStoreActivatable)
                    end
                end
                return
            end
            return original(placeable, ...)
        end
    end

    if PlaceableObjectStorage.onObjectStorageObjectTriggerCallback ~= nil then
        local original = PlaceableObjectStorage.onObjectStorageObjectTriggerCallback
        PlaceableObjectStorage.onObjectStorageObjectTriggerCallback = function(placeable, ...)
            if TCLF.isUnderConstruction(placeable) then
                return
            end
            return original(placeable, ...)
        end
    end

    if PlaceableObjectStorage.updateManualStoreActivatable ~= nil then
        local original = PlaceableObjectStorage.updateManualStoreActivatable
        PlaceableObjectStorage.updateManualStoreActivatable = function(placeable, ...)
            if TCLF.isUnderConstruction(placeable) then
                local spec = placeable.spec_objectStorage
                local system = g_currentMission ~= nil and g_currentMission.activatableObjectsSystem or nil
                if spec ~= nil then
                    spec.lastPendingManualObjectsState = false
                    if system ~= nil and spec.manualStoreActivatable ~= nil then
                        system:removeActivatable(spec.manualStoreActivatable)
                    end
                end
                return
            end
            return original(placeable, ...)
        end
    end

    PlaceableObjectStorage.tclfConstructionTriggerGuardsInstalled = true
    logInfo("ObjectStorage construction trigger guards installed")
end

-- Some silos have a separate player action trigger (refill/buy), independent
-- of the loading/unloading station trigger classes guarded below.
local function installSiloPlayerActionGuard()
    if PlaceableSilo == nil
        or PlaceableSilo.onPlayerActionTriggerCallback == nil
        or PlaceableSilo.tclfConstructionPlayerActionGuardInstalled then
        return
    end

    local original = PlaceableSilo.onPlayerActionTriggerCallback
    PlaceableSilo.onPlayerActionTriggerCallback = function(placeable, ...)
        if TCLF.isUnderConstruction(placeable) then
            local spec = placeable.spec_silo
            local system = g_currentMission ~= nil and g_currentMission.activatableObjectsSystem or nil
            if spec ~= nil and system ~= nil and spec.activatable ~= nil then
                system:removeActivatable(spec.activatable)
            end
            return
        end
        return original(placeable, ...)
    end

    PlaceableSilo.tclfConstructionPlayerActionGuardInstalled = true
    logInfo("Silo player-action construction guard installed")
end

local function installStateNameSchemaHook()
    -- Reuse the same guard name as FS25_ConstructionProgressDisplay so both scripts can coexist
    -- without registering the XML path twice.
    if PlaceableConstructible ~= nil
        and PlaceableConstructible.registerXMLPaths ~= nil
        and not PlaceableConstructible.cpdStateNameXMLHookInstalled then

        PlaceableConstructible.cpdStateNameXMLHookInstalled = true
        PlaceableConstructible.registerXMLPaths = Utils.appendedFunction(
            PlaceableConstructible.registerXMLPaths,
            function(schema, basePath)
                schema:register(
                    XMLValueType.L10N_STRING,
                    basePath .. ".constructible.stateMachine.states.state(?)#StateName",
                    "Optional human-readable construction stage name"
                )
            end
        )
        logInfo("StateName XML schema hook installed")
    end
end

function TCLF.installHooks()
    if TCLF.hooksInstalled then
        return
    end

    installStateNameSchemaHook()

    -- Hide HUD sections that belong to the future finished facility.  The
    -- constructible section itself is handled separately below.
    installFutureFacilityInfoGuard(PlaceableProductionPoint, "PlaceableProductionPoint")
    installFutureFacilityInfoGuard(PlaceableSilo, "PlaceableSilo")
    installFutureFacilityInfoGuard(PlaceableObjectStorage, "PlaceableObjectStorage")
    installObjectStorageConstructionGuards()
    installSiloPlayerActionGuard()

    if PlaceableConstructible ~= nil and PlaceableConstructible.updateInfo ~= nil then
        -- updateInfo is already an overwritten specialization method. Preserve its native
        -- (self, superFunc, infoTable) calling convention instead of adding another superFunc.
        local vanillaConstructibleUpdateInfo = PlaceableConstructible.updateInfo
        PlaceableConstructible.updateInfo = function(placeable, superFunc, infoTable)
            if type(infoTable) ~= "table" then
                return vanillaConstructibleUpdateInfo(placeable, superFunc, infoTable)
            end

            if TCLF.isUnderConstruction(placeable) then
                addConstructionInfo(placeable, infoTable)
                return
            end

            return vanillaConstructibleUpdateInfo(placeable, superFunc, infoTable)
        end
        logInfo("Constructible info HUD hook installed")
    end

    if PlaceableConstructible ~= nil and PlaceableConstructible.finalizeConstruction ~= nil then
        PlaceableConstructible.finalizeConstruction = Utils.overwrittenFunction(
            PlaceableConstructible.finalizeConstruction,
            TCLF.finalizeConstruction
        )
    end

    if ProductionPoint ~= nil and ProductionPoint.interactionTriggerCallback ~= nil then
        ProductionPoint.interactionTriggerCallback = Utils.overwrittenFunction(
            ProductionPoint.interactionTriggerCallback,
            TCLF.productionInteractionTriggerCallback
        )
    end

    if LoadTrigger ~= nil then
        if LoadTrigger.loadTriggerCallback ~= nil then
            LoadTrigger.loadTriggerCallback = Utils.overwrittenFunction(
                LoadTrigger.loadTriggerCallback,
                TCLF.loadTriggerCallback
            )
        end
        if LoadTrigger.update ~= nil then
            LoadTrigger.update = Utils.overwrittenFunction(
                LoadTrigger.update,
                TCLF.loadTriggerUpdate
            )
        end
        if LoadTrigger.getIsFillTypeSupported ~= nil then
            LoadTrigger.getIsFillTypeSupported = Utils.overwrittenFunction(
                LoadTrigger.getIsFillTypeSupported,
                TCLF.loadTriggerGetIsFillTypeSupported
            )
        end
    end

    if UnloadTrigger ~= nil then
        if UnloadTrigger.getIsFillTypeSupported ~= nil then
            UnloadTrigger.getIsFillTypeSupported = Utils.overwrittenFunction(
                UnloadTrigger.getIsFillTypeSupported,
                TCLF.unloadTriggerGetIsFillTypeSupported
            )
        end
        if UnloadTrigger.getFillUnitFreeCapacity ~= nil then
            UnloadTrigger.getFillUnitFreeCapacity = Utils.overwrittenFunction(
                UnloadTrigger.getFillUnitFreeCapacity,
                TCLF.unloadTriggerGetFillUnitFreeCapacity
            )
        end
        if UnloadTrigger.addFillUnitFillLevel ~= nil then
            UnloadTrigger.addFillUnitFillLevel = Utils.overwrittenFunction(
                UnloadTrigger.addFillUnitFillLevel,
                TCLF.unloadTriggerAddFillUnitFillLevel
            )
        end
    end

    TCLF.hooksInstalled = true
    logInfo("Loaded v%s", TCLF.VERSION)
end

function TCLF:loadMap(mapName)
    self.scanTimer = 0
end

function TCLF:update(dt)
    if not self.hooksInstalled then
        self.installHooks()
    end

    if g_currentMission == nil then
        return
    end

    self.scanTimer = self.scanTimer - dt
    if self.scanTimer <= 0 then
        self.scanTimer = self.SCAN_INTERVAL_MS
        self.scanPlaceables()
    end

    if g_server ~= nil and self.currentPalletJob == nil and #self.palletQueue > 0 then
        self:startNextPalletJob()
    end
end

function TCLF:deleteMap()
    self.scanTimer = 0
    self.currentPalletJob = nil
    table.clear(self.palletQueue)
end

TCLF.installHooks()
addModEventListener(TCLF)

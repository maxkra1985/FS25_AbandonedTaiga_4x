--[[
    ObjectStorageAreaFillTypeFilter.lua

    Adds an optional fillTypes filter to each vanilla ObjectStorage storageArea.

    XML:
        <storageArea startNode="..." endNode="..."
                     fillTypes="BEEF PORK MUTTON"/>

    Areas with the same effective set are packed together, so different pallet
    products that share the lower shelves do not overlap. Areas without
    #fillTypes keep vanilla behaviour and accept every supported object.

    This script changes only the visual placement of abstract stored objects.
    Savegame/network serialization remains completely vanilla.
]]

ObjectStorageAreaFillTypeFilter = ObjectStorageAreaFillTypeFilter or {}
ObjectStorageAreaFillTypeFilter.VERSION = "0.1.0.0"
ObjectStorageAreaFillTypeFilter.DEBUG = false

local LOG_PREFIX = "[ObjectStorageAreaFilter]"

local function debugLog(formatString, ...)
    if ObjectStorageAreaFillTypeFilter.DEBUG then
        Logging.info(LOG_PREFIX .. " " .. formatString, ...)
    end
end

local function registerXMLPaths(schema, basePath)
    schema:register(
        XMLValueType.STRING,
        basePath .. ".objectStorage.storageAreas.storageArea(?)#fillTypes",
        "Optional whitespace-separated list of fillTypes allowed in this visual storage area"
    )
end

local function parseFillTypeSet(xmlFile, key)
    local names = xmlFile:getValue(key .. "#fillTypes")
    if names == nil or string.isNilOrWhitespace(names) then
        return nil
    end

    local result = {}
    local count = 0

    for name in string.gmatch(names, "%S+") do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(name)
        if fillTypeIndex == nil or fillTypeIndex == FillType.UNKNOWN then
            Logging.xmlWarning(
                xmlFile,
                "%s Unknown fillType '%s' in '%s'.",
                LOG_PREFIX,
                tostring(name),
                tostring(key)
            )
        else
            result[fillTypeIndex] = true
            count = count + 1
        end
    end

    if count == 0 then
        return {}
    end

    return result
end

local function loadAreaFilters(placeable)
    local spec = placeable.spec_objectStorage
    if spec == nil or spec.storageArea == nil or spec.storageArea.area == nil then
        return
    end

    local areaIndex = 0
    local filteredAreaCount = 0

    placeable.xmlFile:iterate("placeable.objectStorage.storageAreas.storageArea", function(_, areaKey)
        areaIndex = areaIndex + 1
        local area = spec.storageArea.area[areaIndex]
        if area ~= nil then
            area.objectStorageAllowedFillTypes = parseFillTypeSet(placeable.xmlFile, areaKey)
            if area.objectStorageAllowedFillTypes ~= nil then
                filteredAreaCount = filteredAreaCount + 1
            end
        end
    end)

    spec.objectStorageHasAreaFillTypeFilters = filteredAreaCount > 0

    if filteredAreaCount > 0 then
        debugLog(
            "'%s': loaded filters for %d/%d storage areas",
            tostring(placeable.configFileName),
            filteredAreaCount,
            #spec.storageArea.area
        )
    end
end

local function getAbstractObjectFillType(abstractObject)
    if abstractObject == nil then
        return nil
    end

    if abstractObject.palletAttributes ~= nil then
        return abstractObject.palletAttributes.fillType
    end

    if abstractObject.baleAttributes ~= nil then
        return abstractObject.baleAttributes.fillType
    end

    return nil
end

local function getAreaBucket(storageArea, fillTypeIndex)
    local areas = {}
    local indices = {}

    for index, area in ipairs(storageArea.area or {}) do
        local allowed = area.objectStorageAllowedFillTypes
        local isAllowed = allowed == nil or (fillTypeIndex ~= nil and allowed[fillTypeIndex] == true)

        if isAllowed then
            table.insert(areas, area)
            table.insert(indices, index)
        end
    end

    if #areas == 0 then
        return nil, nil
    end

    return areas, table.concat(indices, ",")
end

local function newCursor(areas)
    return {
        areas = areas,
        spawnAreaIndex = 1,
        spawnAreaData = {0, 0, 0, 0, 0, math.huge}
    }
end

function ObjectStorageAreaFillTypeFilter.updateObjectStorageVisualAreas(placeable, superFunc)
    local spec = placeable.spec_objectStorage
    if spec == nil or not spec.objectStorageHasAreaFillTypeFilters then
        return superFunc(placeable)
    end

    local storageArea = spec.storageArea
    local oldSpawnNode = storageArea.spawnNode
    storageArea.spawnNode = createTransformGroup("storageAreaSpawnNode")
    link(placeable.rootNode, storageArea.spawnNode)
    setVisibility(storageArea.spawnNode, false)

    local pendingVisualAreaUpdate = {
        oldSpawnNode = oldSpawnNode,
        newSpawnNode = storageArea.spawnNode,
        objectInfosToSpawn = {}
    }

    pendingVisualAreaUpdate.spawnNextObjectInfo = function()
        if #pendingVisualAreaUpdate.objectInfosToSpawn <= 0 then
            delete(pendingVisualAreaUpdate.oldSpawnNode)
            if entityExists(pendingVisualAreaUpdate.newSpawnNode) then
                setVisibility(pendingVisualAreaUpdate.newSpawnNode, true)
            end
            return false
        end

        local objectInfo = pendingVisualAreaUpdate.objectInfosToSpawn[1]
        objectInfo.objects[1]:spawnVisualObjects(objectInfo.visualSpawnInfos)
        table.remove(pendingVisualAreaUpdate.objectInfosToSpawn, 1)
        return true
    end

    -- One packing cursor per distinct set of allowed areas. In the slaughterhouse
    -- all ordinary products share Row1..Row3, while a dedicated fillType can use Row4. This also
    -- remains generic for any future storage layout.
    local cursorsByAreaSignature = {}

    for _, objectInfo in ipairs(spec.objectInfos or {}) do
        objectInfo.visualSpawnInfos = {}

        local prototype = objectInfo.objects[1]
        local fillTypeIndex = getAbstractObjectFillType(prototype)
        local allowedAreas, signature = getAreaBucket(storageArea, fillTypeIndex)

        if allowedAreas == nil then
            Logging.warning(
                "%s No visual storageArea accepts fillType '%s' in '%s'; object remains stored but has no shelf visual.",
                LOG_PREFIX,
                fillTypeIndex ~= nil and tostring(g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)) or "UNKNOWN",
                tostring(placeable.configFileName)
            )
        else
            local cursor = cursorsByAreaSignature[signature]
            if cursor == nil then
                cursor = newCursor(allowedAreas)
                cursorsByAreaSignature[signature] = cursor
            end

            -- Stock code resets max stack height for every objectInfo group.
            cursor.spawnAreaData[6] = math.huge

            local ox, oy, oz, width, height, length, maxStackHeight = prototype:getSpawnInfo()
            local effectiveMaxStackHeight = maxStackHeight > 1.001 and math.huge or maxStackHeight

            for _ = 1, objectInfo.numObjects do
                local areaIndex, spawnX, spawnY, spawnZ,
                    offsetX, offsetY, offsetZ, nextOffsetX, nextOffsetZ, stackIndex =
                    PlaceableObjectStorage.getNextSpawnAreaAndOffset(
                        cursor.areas,
                        cursor.spawnAreaIndex,
                        cursor.spawnAreaData[1],
                        cursor.spawnAreaData[2],
                        cursor.spawnAreaData[3],
                        cursor.spawnAreaData[4],
                        cursor.spawnAreaData[5],
                        width,
                        height,
                        length,
                        effectiveMaxStackHeight,
                        cursor.spawnAreaData[6],
                        true
                    )

                if areaIndex ~= nil then
                    cursor.spawnAreaIndex = areaIndex
                    cursor.spawnAreaData[1] = offsetX
                    cursor.spawnAreaData[2] = offsetY
                    cursor.spawnAreaData[3] = offsetZ
                    cursor.spawnAreaData[4] = nextOffsetX
                    cursor.spawnAreaData[5] = nextOffsetZ
                    cursor.spawnAreaData[6] = stackIndex

                    local spawnArea = cursor.areas[cursor.spawnAreaIndex]
                    local cx, cy, cz = localToLocal(
                        spawnArea.startNode,
                        storageArea.spawnNode,
                        spawnX + ox,
                        spawnY + oy,
                        spawnZ + oz
                    )
                    local rx, ry, rz = localRotationToLocal(
                        spawnArea.startNode,
                        storageArea.spawnNode,
                        0,
                        0,
                        0
                    )

                    table.insert(objectInfo.visualSpawnInfos, {
                        storageArea.spawnNode,
                        cx,
                        cy,
                        cz,
                        rx,
                        ry,
                        rz
                    })
                end
            end
        end

        if #objectInfo.visualSpawnInfos > 0 then
            table.insert(pendingVisualAreaUpdate.objectInfosToSpawn, objectInfo)
        end
    end

    if pendingVisualAreaUpdate.spawnNextObjectInfo() then
        table.insert(spec.pendingVisualAreaUpdates, pendingVisualAreaUpdate)
        placeable:raiseActive()
    end
end

function ObjectStorageAreaFillTypeFilter.install()
    if ObjectStorageAreaFillTypeFilter.installed then
        return
    end

    ObjectStorageAreaFillTypeFilter.installed = true

    PlaceableObjectStorage.registerXMLPaths = Utils.appendedFunction(
        PlaceableObjectStorage.registerXMLPaths,
        registerXMLPaths
    )

    PlaceableObjectStorage.onLoad = Utils.appendedFunction(
        PlaceableObjectStorage.onLoad,
        loadAreaFilters
    )

    PlaceableObjectStorage.updateObjectStorageVisualAreas = Utils.overwrittenFunction(
        PlaceableObjectStorage.updateObjectStorageVisualAreas,
        ObjectStorageAreaFillTypeFilter.updateObjectStorageVisualAreas
    )

    Logging.info("%s installed v%s", LOG_PREFIX, ObjectStorageAreaFillTypeFilter.VERSION)
end

ObjectStorageAreaFillTypeFilter.install()

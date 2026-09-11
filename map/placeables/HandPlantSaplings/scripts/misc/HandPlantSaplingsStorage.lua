--[[
Copyright (C) GtX (Andy), 2018

Author: GtX | Andy
Date: 15.03.2018
Revision: FS25-01

Contact:
https://forum.giants-software.com
https://github.com/GtX-Andy

Important:
Not to be added to any mods / maps or modified from its current release form.
No modifications may be made to this script, including conversion to other game versions without written permission from GtX | Andy
Copying or removing any part of this code for external use without written permission from GtX | Andy is prohibited.

Darf nicht zu Mods / Maps hinzugefügt oder von der aktuellen Release-Form geändert werden.
Ohne schriftliche Genehmigung von GtX | Andy dürfen keine Änderungen an diesem Skript vorgenommen werden, einschließlich der Konvertierung in andere Spielversionen
Das Kopieren oder Entfernen irgendeines Teils dieses Codes zur externen Verwendung ohne schriftliche Genehmigung von GtX | Andy ist verboten.
]]


HandPlantSaplingsStorage = {}

local HandPlantSaplingsStorage_mt = Class(HandPlantSaplingsStorage, Object)
InitObjectClass(HandPlantSaplingsStorage, "HandPlantSaplingsStorage")

function HandPlantSaplingsStorage.registerXMLPaths(schema, basePath)
    schema:register(XMLValueType.INT, basePath .. "#capacity", "The capacity.", 10)
    schema:register(XMLValueType.STRING_LIST, basePath .. "#avoidTreeTypes", "A list of tree type name separated by a single white space that will be blocked from storage.")

    schema:register(XMLValueType.FLOAT, basePath .. ".saplingNodes#snowScale", "The snow scale applied to all saplings, useful when storage is indoors.", 1.0)
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".saplingNodes#node", "Main visibility node.")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".saplingNodes.saplingNode(?)#node", "Sapling link node.")

    schema:register(XMLValueType.BOOL, basePath .. ".saplingNodes.saplingNode(?)#randomRotation", "Randomise rotation of saplings.", true)
    schema:register(XMLValueType.BOOL, basePath .. ".saplingNodes.saplingNode(?)#randomScale", "Randomise scale of saplings.", true)
    schema:register(XMLValueType.INT, basePath .. ".saplingNodes.saplingNode(?)#minScale", "The minimum scale randomly applied. Only when 'randomScale' is true.", 80)
    schema:register(XMLValueType.INT, basePath .. ".saplingNodes.saplingNode(?)#maxScale", "The maximum scale randomly applied. Only when 'randomScale' is true.", 100)

    schema:register(XMLValueType.STRING, basePath .. ".saplingNodes.saplingNode(?).variation(?)#name", "The name of the variation that will use this translation.", "")
    schema:register(XMLValueType.VECTOR_TRANS, basePath .. ".saplingNodes.saplingNode(?).variation(?)#translation", "The translation (x y z) that will be used when this variation is stored on this node.", "DEFAULT")
end

function HandPlantSaplingsStorage.registerSavegameXMLPaths(savegameSchema, basePath)
    savegameSchema:register(XMLValueType.STRING, basePath .. ".node(?)#treeType", "The tree type name.")
    savegameSchema:register(XMLValueType.STRING, basePath .. ".node(?)#treeVariation", "The tree type variation name.")
    savegameSchema:register(XMLValueType.INT, basePath .. ".node(?)#fillLevel", "The fill level.")
end

function HandPlantSaplingsStorage.new(isServer, isClient, customMt)
    local self = Object.new(isServer, isClient, customMt or HandPlantSaplingsStorage_mt)

    self.parent = nil
    self.shovel = nil

    self.fillLevels = {}
    self.treeTypes = {}
    self.sortedTreeTypes = {}

    self.saplingNodes = {}
    self.isSaplingStorage = true

    return self
end

function HandPlantSaplingsStorage:load(parent, shovel, xmlFile, key, components, i3dMappings)
    if parent == nil then
        Logging.xmlError(xmlFile, "Failed to load storage, required parent is missing! (%s)", key)

        return false
    end

    self.parent = parent
    self.shovel = shovel

    self.singleTreeType = shovel ~= nil
    self.capacity = xmlFile:getValue(key .. "#capacity", 10)

    local manager = g_handPlantSaplingsManager

    local avoidTreeTypes = {}
    local avoidTreeTypeNames = xmlFile:getValue(key .. "#avoidTreeTypes")

    if avoidTreeTypeNames ~= nil then
        for _, treeTypeName in ipairs (avoidTreeTypeNames) do
            avoidTreeTypes[treeTypeName:upper()] = true
        end
    end

    local treeTypes = manager:getTreeTypes()

    for treeTypeKey, treeType in pairs (treeTypes) do
        if avoidTreeTypes[treeType.name] == nil then
            self.fillLevels[treeTypeKey] = 0
            self.treeTypes[treeTypeKey] = true

            table.insert(self.sortedTreeTypes, treeTypeKey)
        end
    end

    table.sort(self.sortedTreeTypes, function(a, b)
        local treeTypeA = treeTypes[a]
        local treeTypeB = treeTypes[b]

        if treeTypeA.typeIndex == treeTypeB.typeIndex then
            return treeTypeA.variationIndex < treeTypeB.variationIndex
        end

        return treeTypeA.typeIndex < treeTypeB.typeIndex
    end)

    self.snowScale = xmlFile:getValue(key .. ".saplingNodes#snowScale", 1.0)

    self.visibilityNode = xmlFile:getValue(key .. ".saplingNodes#node", nil, components, i3dMappings)

    for _, saplingNodeKey in xmlFile:iterator(key .. ".saplingNodes.saplingNode") do
        if #self.saplingNodes >= self.capacity then
            Logging.xmlWarning(xmlFile, "Number of sapling nodes given at '%s' is greater than capacity or '%d', these will be ignored.", saplingNodeKey, self.capacity)

            break
        end

        local node = xmlFile:getValue(saplingNodeKey .. "#node", nil, components, i3dMappings)

        if node ~= nil then
            if xmlFile:getValue(saplingNodeKey .. "#randomRotation", true) then
                setRotation(node, 0, math.random(0, math.pi * 2), 0)
            end

            if xmlFile:getValue(saplingNodeKey .. "#randomScale", true) then
                local minScale = math.max(xmlFile:getValue(saplingNodeKey .. "#minScale", 80), 1)
                local maxScale = math.max(xmlFile:getValue(saplingNodeKey .. "#maxScale", 100), minScale)

                local sx, _, sz = getScale(node)
                setScale(node, sx, math.random(minScale, maxScale) / 100, sz)
            end

            local variations = nil

            if xmlFile:hasProperty(saplingNodeKey .. ".variation(0)") then
                variations = {
                    HPS_DEFAULT = {getTranslation(node)}
                }

                for _, variationKey in xmlFile:iterator(saplingNodeKey .. ".variation") do
                    local name = xmlFile:getValue(variationKey .. "#name")

                    if name ~= nil then
                        variations[name:upper()] = xmlFile:getValue(variationKey .. "#translation", variations.HPS_DEFAULT, true)
                    end
                end

                if table.size(variations) == 1 then
                    variations = nil
                end
            end

            table.insert(self.saplingNodes, {
                node = node,
                variations = variations,
                saplingShape = nil,
                treeTypeKey = nil
            })

            setVisibility(node, false)
        end
    end

    self.dirtyFlag = self:getNextDirtyFlag()

    g_messageCenter:subscribe(MessageType.FARM_DELETED, self.onFarmDestroyed, self)

    return true
end

function HandPlantSaplingsStorage:delete()
    g_messageCenter:unsubscribeAll(self)

    if self.saplingNodes ~= nil then
        for _, saplingNode in ipairs(self.saplingNodes) do
            if saplingNode.saplingShape ~= nil then
                delete(saplingNode.saplingShape)
                saplingNode.saplingShape = nil
            end
        end
    end

    HandPlantSaplingsStorage:superClass().delete(self)
end

function HandPlantSaplingsStorage:readStream(streamId, connection)
    HandPlantSaplingsStorage:superClass().readStream(self, streamId, connection)

    for _, treeTypeKey in ipairs(self.sortedTreeTypes) do
        local fillLevel = streamReadUInt8(streamId)

        self:setFillLevel(fillLevel, nil, nil, treeTypeKey)
    end
end

function HandPlantSaplingsStorage:writeStream(streamId, connection)
    HandPlantSaplingsStorage:superClass().writeStream(self, streamId, connection)

    for _, treeTypeKey in ipairs(self.sortedTreeTypes) do
        local fillLevel = self.fillLevels[treeTypeKey] or 0

        streamWriteUInt8(streamId, fillLevel)
    end
end

function HandPlantSaplingsStorage:readUpdateStream(streamId, timestamp, connection)
    HandPlantSaplingsStorage:superClass().readUpdateStream(self, streamId, timestamp, connection)

    if connection:getIsServer() and streamReadBool(streamId) then
        for _, treeTypeKey in ipairs(self.sortedTreeTypes) do
            local fillLevel = streamReadUInt8(streamId)

            self:setFillLevel(fillLevel, nil, nil, treeTypeKey)
        end
    end
end

function HandPlantSaplingsStorage:writeUpdateStream(streamId, connection, dirtyMask)
    HandPlantSaplingsStorage:superClass().writeUpdateStream(self, streamId, connection, dirtyMask)

    if not connection:getIsServer() and streamWriteBool(streamId, bit32.btest(dirtyMask, self.dirtyFlag)) then
        for _, treeTypeKey in ipairs(self.sortedTreeTypes) do
            local fillLevel = self.fillLevels[treeTypeKey] or 0

            streamWriteUInt8(streamId, fillLevel)
        end
    end
end

function HandPlantSaplingsStorage:saveToXMLFile(xmlFile, key)
    local manager = g_handPlantSaplingsManager
    local index = 0

    for treeTypeKey, fillLevel in pairs(self.fillLevels) do
        if fillLevel > 0 then
            local treeTypeName, variationName = manager:getTreeTypeNameAndVariationName(treeTypeKey)

            if treeTypeName ~= nil then
                local fillLevelKey = string.format("%s.node(%d)", key, index)

                xmlFile:setValue(fillLevelKey .. "#treeType", treeTypeName)

                if variationName ~= nil then
                    xmlFile:setValue(fillLevelKey .. "#treeVariation", variationName)
                end

                xmlFile:setValue(fillLevelKey .. "#fillLevel", fillLevel)
            end

            index += 1
        end
    end
end

function HandPlantSaplingsStorage:loadFromXMLFile(xmlFile, key, isReset)
    if xmlFile:hasProperty(key) then
        local treePlantManager = g_treePlantManager

        for _, fillLevelKey in xmlFile:iterator(key .. ".node") do
            local treeTypeName = xmlFile:getValue(fillLevelKey .. "#treeType")
            local fillLevel = xmlFile:getValue(fillLevelKey .. "#fillLevel", 0)

            if treeTypeName ~= nil and fillLevel > 0 then
                local variationName = xmlFile:getValue(fillLevelKey .. "#treeVariation")
                local treeTypeIndex, treeVariationIndex = treePlantManager:getTreeTypeIndexAndVariationFromName(treeTypeName, 1, variationName)

                if treeTypeIndex ~= nil then
                    self:setFillLevel(fillLevel, treeTypeIndex, treeVariationIndex)
                end
            end
        end
    end
end

function HandPlantSaplingsStorage:setVisibility(visible)
    if self.visibilityNode ~= nil then
        if visible then
            self:updateSaplingNodes()

            setVisibility(self.visibilityNode, true)
        else
            setVisibility(self.visibilityNode, false)
        end
    end
end

function HandPlantSaplingsStorage:addFillLevel(delta, typeIndex, variationIndex, treeTypeKey)
    if treeTypeKey == nil then
        treeTypeKey = HandPlantSaplingsManager.getTreeTypeKey(typeIndex, variationIndex)
    end

    local oldFillLevel = self.fillLevels[treeTypeKey]

    if oldFillLevel ~= nil then
        local freeCapacity = self:getFreeCapacity(nil, nil, treeTypeKey)

        if freeCapacity > 0 then
            return self:setFillLevel(oldFillLevel + math.min(math.abs(delta), freeCapacity), nil, nil, treeTypeKey) - oldFillLevel
        end
    end

    return delta
end

function HandPlantSaplingsStorage:removeFillLevel(delta, typeIndex, variationIndex, treeTypeKey)
    if treeTypeKey == nil then
        treeTypeKey = HandPlantSaplingsManager.getTreeTypeKey(typeIndex, variationIndex)
    end

    local oldFillLevel = self.fillLevels[treeTypeKey] or 0

    if oldFillLevel > 0 then
        return oldFillLevel - self:setFillLevel(oldFillLevel - math.abs(delta), nil, nil, treeTypeKey)
    end

    return delta
end

function HandPlantSaplingsStorage:setFillLevel(fillLevel, typeIndex, variationIndex, treeTypeKey)
    if treeTypeKey == nil then
        treeTypeKey = HandPlantSaplingsManager.getTreeTypeKey(typeIndex, variationIndex)
    end

    fillLevel = math.clamp(fillLevel or 0, 0, self.capacity)

    if self.fillLevels[treeTypeKey] ~= nil and self.fillLevels[treeTypeKey] ~= fillLevel then
        self.fillLevels[treeTypeKey] = fillLevel

        if self.isServer then
            self:raiseDirtyFlags(self.dirtyFlag)
        end

        self:updateSaplingNodes()

        return fillLevel
    end

    return 0
end

function HandPlantSaplingsStorage:updateSaplingNodes()
    if self.saplingNodes == nil or #self.saplingNodes == 0 then
        return
    end

    local manager = g_handPlantSaplingsManager
    local fillLevels, saplingNodes = self.fillLevels, self.saplingNodes
    local index, targetIndex, maxIndex = 0, 0, #saplingNodes

    for i = 1, maxIndex do
        setVisibility(saplingNodes[i].node, false)
    end

    -- This is a beauty this one, the base game caches the shader nodes for placeables but does not entity check or refresh when you enter or leave the construction screen.
    -- So if the sapling nodes are changed then I just set the cached nodes to nil so they are rebuilt.
    self.parent.overlayColorNodes = nil

    for _, treeTypeKey in ipairs(self.sortedTreeTypes) do
        local fillLevel = fillLevels[treeTypeKey] or 0

        if fillLevel > 0 then
            targetIndex = math.min(fillLevel + index, maxIndex)

            while index < targetIndex do
                index += 1

                local saplingNode = saplingNodes[index]

                if saplingNode ~= nil then
                    if saplingNode.treeTypeKey ~= treeTypeKey then
                        saplingNode.treeTypeKey = treeTypeKey

                        manager:cloneSharedSapling(treeTypeKey, saplingNode, self.onCloneSharedSaplingFinished, self)

                        if saplingNode.variations ~= nil then
                            local _, variationName = manager:getTreeTypeNameAndVariationName(treeTypeKey)
                            local translation = saplingNode.variations[variationName] or saplingNode.variations.HPS_DEFAULT

                            if translation ~= nil then
                                setTranslation(saplingNode.node, translation[1], translation[2], translation[3])
                            end
                        end
                    end

                    setVisibility(saplingNode.node, true)
                end
            end

            if index == maxIndex then
                break
            end
        end
    end
end

function HandPlantSaplingsStorage:onCloneSharedSaplingFinished(saplingNode, saplingShape, treeTypeKey, args)
    if saplingNode ~= nil then
        if saplingNode.saplingShape ~= nil then
            delete(saplingNode.saplingShape)
            saplingNode.saplingShape = nil
        end

        if saplingShape ~= nil then
            saplingNode.treeTypeKey = treeTypeKey
            saplingNode.saplingShape = saplingShape

            if self.snowScale < 1.0 then
                setShaderParameterRecursive(saplingShape, "snowScale", self.snowScale, 0, 0, 0, false, -1)
            end

            link(saplingNode.node, saplingShape)
        end
    elseif saplingShape ~= nil then
        delete(saplingShape)
    end
end

function HandPlantSaplingsStorage:onFarmDestroyed(farmId)
    if self:getOwnerFarmId() == farmId then
        for treeTypeKey in pairs(self.treeTypes) do
            self:setFillLevel(0, nil, nil, treeTypeKey)
        end
    end
end

function HandPlantSaplingsStorage:getSupportedTreeTypes(typeAndVariations)
    if typeAndVariations then
        local manager = g_handPlantSaplingsManager
        local treeTypes = {}

        for _, treeTypeKey in ipairs(self.sortedTreeTypes) do
            local treeType = manager:getTreeType(nil, nil, treeTypeKey)

            if treeType ~= nil then
                if treeTypes[treeType.typeIndex] == nil then
                    treeTypes[treeType.typeIndex] = {}
                end

                table.addElement(treeTypes[treeType.typeIndex], treeType.variationIndex)
            end
        end

        return treeTypes
    end

    return self.treeTypes
end

function HandPlantSaplingsStorage:getFillLevels()
    return self.fillLevels
end

function HandPlantSaplingsStorage:getCapacity()
    return self.capacity
end

function HandPlantSaplingsStorage:getFreeCapacity(typeIndex, variationIndex, treeTypeKey)
    if treeTypeKey == nil then
        treeTypeKey = HandPlantSaplingsManager.getTreeTypeKey(typeIndex, variationIndex)
    end

    if self.fillLevels[treeTypeKey] == nil then
        return 0
    end

    local usedCapacity = 0

    if self.singleTreeType then
        for usedTreeTypeKey, usedFillLevel in pairs(self.fillLevels) do
            if usedTreeTypeKey == treeTypeKey then
                usedCapacity = usedFillLevel

                break
            elseif usedFillLevel > 0 then
                return 0
            end
        end


    else
        for _, fillLevel in pairs(self.fillLevels) do
            usedCapacity += fillLevel
        end
    end

    return math.max(self.capacity - usedCapacity, 0)
end

function HandPlantSaplingsStorage:getFillLevel(typeIndex, variationIndex, treeTypeKey)
    if treeTypeKey == nil then
        treeTypeKey = self:getTreeTypeKey(typeIndex, variationIndex)
    end

    return self.fillLevels[treeTypeKey] or 0
end

function HandPlantSaplingsStorage:getTreeTypeAccepted(typeIndex, variationIndex, treeTypeKey)
    local currentTreeTypeKey = nil

    if treeTypeKey == nil then
        currentTreeTypeKey = self:getTreeTypeKey(typeIndex, variationIndex)
        treeTypeKey = HandPlantSaplingsManager.getTreeTypeKey(typeIndex, variationIndex)
    end

    if currentTreeTypeKey == nil or currentTreeTypeKey == treeTypeKey then
        return self.treeTypes[treeTypeKey] == true
    end

    return false
end

function HandPlantSaplingsStorage:getTreeTypeKey(typeIndex, variationIndex)
    if self.singleTreeType then
        for treeTypeKey, fillLevel in pairs(self.fillLevels) do
            if fillLevel > 0 then
                return treeTypeKey
            end
        end
    end

    return HandPlantSaplingsManager.getTreeTypeKey(typeIndex, variationIndex)
end

function HandPlantSaplingsStorage:getTreeTypeIndexAndVariationIndex(treeTypeKey)
    if treeTypeKey == nil then
        treeTypeKey = self:getTreeTypeKey()
    end

    local typeIndex, variationIndex = g_handPlantSaplingsManager:getTreeTypeIndexAndVariationIndex(treeTypeKey)

    return typeIndex, variationIndex, treeTypeKey
end

function HandPlantSaplingsStorage:getTreeTypeTitle(typeIndex, variationIndex, treeTypeKey)
    if treeTypeKey == nil then
        treeTypeKey = self:getTreeTypeKey(typeIndex, variationIndex)
    end

    return g_handPlantSaplingsManager:getTreeTypeTitle(nil, nil, treeTypeKey)
end

function HandPlantSaplingsStorage:getName()
    return self.parent:getName()
end

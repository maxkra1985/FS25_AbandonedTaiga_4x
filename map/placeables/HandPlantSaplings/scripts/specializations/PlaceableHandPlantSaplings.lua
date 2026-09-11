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


PlaceableHandPlantSaplings = {}

PlaceableHandPlantSaplings.MOD_NAME = g_currentModName
PlaceableHandPlantSaplings.MOD_DIRECTORY = g_currentModDirectory

PlaceableHandPlantSaplings.MOD_NAME = g_currentModName
PlaceableHandPlantSaplings.SPEC_NAME = string.format("%s.handPlantSaplings", g_currentModName)
PlaceableHandPlantSaplings.SPEC_TABLE_NAME = string.format("spec_%s", PlaceableHandPlantSaplings.SPEC_NAME)

PlaceableHandPlantSaplings.HOLDER_TYPE = "HPS_LINKED_SHOVEL"
PlaceableHandPlantSaplings.MAX_INFO_HUD_STORAGE_VALUES = 6

local specEntryName = PlaceableHandPlantSaplings.SPEC_TABLE_NAME

function PlaceableHandPlantSaplings.prerequisitesPresent(specializations)
    if HandPlantSaplingsStorage == nil then
        Logging.error("Class 'HandPlantSaplingsStorage' is required for placeable specialisation 'PlaceableHandPlantSaplings' but has failed to load!")

        return false
    end

    return SpecializationUtil.hasSpecialization(PlaceableInfoTrigger, specializations) and SpecializationUtil.hasSpecialization(PlaceableHandToolHolders, specializations)
end

function PlaceableHandPlantSaplings.registerEvents(placeableType)
    SpecializationUtil.registerEvent(placeableType, "onShovelStoredInHolder")
    SpecializationUtil.registerEvent(placeableType, "onShovelTakenFromHolder")
end

function PlaceableHandPlantSaplings.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType, "onDeleteShovelHolder", PlaceableHandPlantSaplings.onDeleteShovelHolder)
    SpecializationUtil.registerFunction(placeableType, "getSaplingStorage", PlaceableHandPlantSaplings.getSaplingStorage)
    SpecializationUtil.registerFunction(placeableType, "getSaplingBackpack", PlaceableHandPlantSaplings.getSaplingBackpack)
end

function PlaceableHandPlantSaplings.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "onHandToolHolderFinished", PlaceableHandPlantSaplings.onHandToolHolderFinished)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "setOwnerFarmId", PlaceableHandPlantSaplings.setOwnerFarmId)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "updateInfo", PlaceableHandPlantSaplings.updateInfo)
    SpecializationUtil.registerOverwrittenFunction(placeableType, "canBeSold", PlaceableHandPlantSaplings.canBeSold)
end

function PlaceableHandPlantSaplings.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onPreLoad", PlaceableHandPlantSaplings)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableHandPlantSaplings)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", PlaceableHandPlantSaplings)

    SpecializationUtil.registerEventListener(placeableType, "onDelete", PlaceableHandPlantSaplings)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", PlaceableHandPlantSaplings)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream", PlaceableHandPlantSaplings)
    SpecializationUtil.registerEventListener(placeableType, "onRegistered", PlaceableHandPlantSaplings)
    SpecializationUtil.registerEventListener(placeableType, "onSell", PlaceableHandPlantSaplings)
end

function PlaceableHandPlantSaplings.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("HandPlantSaplings")

    schema:register(XMLValueType.NODE_INDEX, "placeable.handToolHolders.handToolHolder(?).trigger#distanceNode", "The node used to calculate the distance between the player and accessing the hand tool.")
    schema:register(XMLValueType.BOOL, "placeable.handToolHolders.handToolHolder(?).holder#isOutdoors", "When true and the shovel is in the holder the snowScale shader value will be set to 1 otherwise 0 when a player is holding.", false)

    if HandPlantSaplingsStorage ~= nil then
        HandPlantSaplingsStorage.registerXMLPaths(schema, "placeable.handPlantSaplings.storage")
        HandPlantSaplingsStorage.registerXMLPaths(schema, "placeable.handPlantSaplings.backpacks.backpack(?)")
    end

    schema:setXMLSpecializationType()
end

function PlaceableHandPlantSaplings.registerSavegameXMLPaths(savegameSchema, basePath)
    savegameSchema:setXMLSpecializationType("HandPlantSaplings")

    if HandPlantSaplingsStorage ~= nil then
        HandPlantSaplingsStorage.registerSavegameXMLPaths(savegameSchema, basePath .. ".storage")

        savegameSchema:register(XMLValueType.INT, basePath .. ".backpacks.backpack(?)#index", "The backpack index")
        HandPlantSaplingsStorage.registerSavegameXMLPaths(savegameSchema, basePath .. ".backpacks.backpack(?)")
    end

    savegameSchema:setXMLSpecializationType()
end

function PlaceableHandPlantSaplings.initSpecialization()
    g_storeManager:addSpecType("handPlantSaplingsCapacity", "shopListAttributeIconFillTypes", PlaceableHandPlantSaplings.loadSpecValueCapacity, PlaceableHandPlantSaplings.getSpecValueCapacity, StoreSpecies.PLACEABLE)
end

function PlaceableHandPlantSaplings:onPreLoad(savegame)
    self.spec_handPlantSaplings = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

    if self.spec_handPlantSaplings == nil then
        Logging.xmlError(self.xmlFile, "Specialisation with name 'handPlantSaplings' was not found in modDesc!")
        self:setLoadingState(PlaceableLoadingState.ERROR)

        return
    end

    local spec = self.spec_handPlantSaplings

    spec.totalFillTypeSellPrice = 0
    spec.storage = nil

    spec.shovelHolders = {}
    spec.storageAreas = {}

    spec.backpacks = {}
    spec.backpacksByShovelUniqueId = {}

    spec.infoTableStorageValues = {}

    spec.infoTables = {
        ownedBy = {
            title = g_i18n:getText("fieldInfo_ownedBy"),
            text = "N/A"
        },
        storageTitle = {
            accentuate = true,
            formatTitle = g_i18n:getText("statistic_storage") .. "  %d / %d",
            title = "Storage"
        },
        storageEmpty = {
            title = g_i18n:getText("category_palletForestry"),
            text = "0"
        }
    }

    spec.isValid = g_handPlantSaplingsManager ~= nil and HandPlantSaplingsStorage ~= nil

    -- Need to remove this so I can add the distance node and also pass the key with the arguments.
    SpecializationUtil.removeEventListener(self, "onLoad", PlaceableHandToolHolders)
end

function PlaceableHandPlantSaplings:onLoad(savegame)
    local handToolHoldersSpec = self.spec_handToolHolders

    -- Replaces the 'PlaceableHandToolHolders.onLoad' for this placeable only.
    if handToolHoldersSpec ~= nil then
        if handToolHoldersSpec.handToolHolders ~= nil then
            for _, handToolHolder in ipairs(handToolHoldersSpec.handToolHolders) do
                handToolHolder:delete()
            end
        end

        handToolHoldersSpec.handToolHolders = {}

        local holderName = string.format(g_i18n:getText("ui_handToolHolderPlaceable"), self:getName())

        for nodeIndex, key in self.xmlFile:iterator("placeable.handToolHolders.handToolHolder") do
            local handToolHolder = HandToolHolder.new(self, self.isServer, self.isClient)

            handToolHolder:setHolderName(holderName)

            local args = {
                loadingTask = self:createLoadingTask(self),
                xmlFile = self.xmlFile,
                savegame = savegame,
                key = key
            }

            handToolHolder:load(self.xmlFile, key, self.onHandToolHolderFinished, self, args, self.components, self.i3dMappings, self.baseDirectory, self.customEnvironment)
        end
    end

    local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

    if spec.isValid and self.xmlFile:hasProperty("placeable.handPlantSaplings.storage") then
        local storage = HandPlantSaplingsStorage.new(self.isServer, self.isClient)

        if storage:load(self, nil, self.xmlFile, "placeable.handPlantSaplings.storage", self.components, self.i3dMappings) then
            spec.storage = storage

            table.insert(spec.storageAreas, storage)
        else
            storage:delete()

            Logging.xmlError(self.xmlFile, "Failed to load storage!")
            self:setLoadingState(PlaceableLoadingState.ERROR)
        end
    end
end

function PlaceableHandPlantSaplings:onFinalizePlacement()
    local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

    if spec.storageAreas ~= nil then
        local ownerFarmId = self:getOwnerFarmId()

        for _, storageArea in ipairs (spec.storageAreas) do
            storageArea:setOwnerFarmId(ownerFarmId)
        end
    end
end

function PlaceableHandPlantSaplings:onDelete()
    local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

    if g_handPlantSaplingsManager ~= nil then
        g_handPlantSaplingsManager:removeObjectInRange(nil, self)
    end

    if spec.storageAreas ~= nil then
        for _, storageArea in ipairs (spec.storageAreas) do
            storageArea:delete()
        end
    end

    table.clear(spec.infoTableStorageValues)
end

function PlaceableHandPlantSaplings:onReadStream(streamId, connection)
    local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

    if spec.storageAreas ~= nil then
        for _, storageArea in ipairs (spec.storageAreas) do
            local storageAreaId = NetworkUtil.readNodeObjectId(streamId)
            storageArea:readStream(streamId, connection)
            g_client:finishRegisterObject(storageArea, storageAreaId)
        end
    end
end

function PlaceableHandPlantSaplings:onWriteStream(streamId, connection)
    local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

    if spec.storageAreas ~= nil then
        for _, storageArea in ipairs (spec.storageAreas) do
            NetworkUtil.writeNodeObjectId(streamId, NetworkUtil.getObjectId(storageArea))
            storageArea:writeStream(streamId, connection)
            g_server:registerObjectInStream(connection, storageArea)
        end
    end
end

function PlaceableHandPlantSaplings:onRegistered(alreadySent)
    local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

    if spec.storageAreas ~= nil then
        for _, storageArea in ipairs (spec.storageAreas) do
            storageArea:register(true)
        end
    end
end

function PlaceableHandPlantSaplings:onDeleteShovelHolder(object)
    local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

    if spec.shovelHolders ~= nil and object ~= nil then
        table.removeElement(spec.shovelHolders, object)
    end
end

function PlaceableHandPlantSaplings:loadFromXMLFile(xmlFile, key, isReset)
    local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

    if spec.storage ~= nil then
        spec.storage:loadFromXMLFile(xmlFile, key .. ".storage", isReset)
    end

    if spec.backpacks ~= nil then
        for _, backpackKey in xmlFile:iterator(key .. ".backpacks.backpack") do
            local index = xmlFile:getValue(backpackKey .. "#index", 0)
            local backpack = spec.backpacks[index]

            if backpack ~= nil then
                backpack:loadFromXMLFile(xmlFile, backpackKey, isReset)
            end
        end
    end
end

function PlaceableHandPlantSaplings:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

    if spec.storage ~= nil then
        spec.storage:saveToXMLFile(xmlFile, key .. ".storage")
    end

    if spec.backpacks ~= nil then
        for i, backpack in ipairs (spec.backpacks) do
            local backpackKey = string.format("%s.backpacks.backpack(%d)", key, i - 1)

            xmlFile:setValue(backpackKey .. "#index", i)
            backpack:saveToXMLFile(xmlFile, backpackKey)
        end
    end
end

function PlaceableHandPlantSaplings:getSaplingStorage()
    return self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME].storage
end

function PlaceableHandPlantSaplings:getSaplingBackpack(shovel)
    local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

    if shovel ~= nil and spec.backpacksByShovelUniqueId ~= nil then
        return spec.backpacksByShovelUniqueId[shovel:getUniqueId()]
    end

    return nil
end

function PlaceableHandPlantSaplings:updateInfo(superFunc, infoTable)
    local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]
    local handPlantSaplingsManager = g_handPlantSaplingsManager

    if spec.isValid and handPlantSaplingsManager ~= nil then
        local owningFarm = g_farmManager:getFarmById(self:getOwnerFarmId())
        spec.infoTables.ownedBy.text = owningFarm ~= nil and owningFarm.name or "N/A"

        table.insert(infoTable, spec.infoTables.ownedBy)

        if spec.storage ~= nil then
            local totalFillLevel = 0

            table.clear(spec.infoTableStorageValues)

            for treeTypeKey, fillLevel in pairs (spec.storage:getFillLevels()) do
                if fillLevel > 0 then
                    table.insert(spec.infoTableStorageValues, {
                        title = handPlantSaplingsManager:getTreeTypeTitle(nil, nil, treeTypeKey),
                        text = string.format("%d", fillLevel)
                    })

                    totalFillLevel += fillLevel
                end
            end

            spec.infoTables.storageTitle.title = string.format(spec.infoTables.storageTitle.formatTitle, totalFillLevel, spec.storage:getCapacity())
            table.insert(infoTable, spec.infoTables.storageTitle)

            local numStorageValues = #spec.infoTableStorageValues

            if numStorageValues > 0 then
                table.sort(spec.infoTableStorageValues, function (a, b)
                    return a.title < b.title
                end)

                for i = 1, math.min(numStorageValues, PlaceableHandPlantSaplings.MAX_INFO_HUD_STORAGE_VALUES) do
                    table.insert(infoTable, spec.infoTableStorageValues[i])
                end
            else
                table.insert(infoTable, spec.infoTables.storageEmpty)
            end
        end

        if spec.backpacks ~= nil then
            for i, backpack in ipairs (spec.backpacks) do
                if backpack.shovel ~= nil and backpack.infoTableTitle ~= nil and backpack.infoTablePlayer ~= nil then
                    table.insert(infoTable, backpack.infoTableTitle)

                    local holder = backpack.shovel:getHolder()
                    local holderIsPlayer = holder ~= nil and holder:isa(Player)

                    if holderIsPlayer then
                        backpack.infoTablePlayer.text = holder:getNickname()
                        table.insert(infoTable, backpack.infoTablePlayer)
                    end

                    if not holderIsPlayer or holder == g_localPlayer then
                        local treeTypeKey = backpack:getTreeTypeKey()
                        local fillLevel = backpack:getFillLevel(nil, nil, treeTypeKey)

                        if fillLevel > 0 then
                            table.insert(infoTable, {
                                title = handPlantSaplingsManager:getTreeTypeTitle(nil, nil, treeTypeKey),
                                text = string.format("%d / %d", fillLevel, backpack:getCapacity())
                            })
                        else
                            table.insert(infoTable, {
                                title = spec.infoTables.storageEmpty.title,
                                text = string.format("0 / %d", backpack:getCapacity())
                            })
                        end
                    end
                end
            end
        end
    else
        table.insert(infoTable, {
            title = "Hand Plant Saplings - Failed to validate!",
            accentuate = true
        })
    end

    superFunc(self, infoTable)
end

function PlaceableHandPlantSaplings:setOwnerFarmId(superFunc, ownerFarmId, noEventSend)
    local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

    superFunc(self, ownerFarmId, noEventSend)

    if spec.storageAreas ~= nil then
        for _, storageArea in ipairs (spec.storageAreas) do
            storageArea:setOwnerFarmId(ownerFarmId, true)
        end
    end
end

function PlaceableHandPlantSaplings:onHandToolHolderFinished(superFunc, handToolHolder, args)
    if handToolHolder ~= nil and args.key ~= nil then
        if handToolHolder.activatable ~= nil and handToolHolder.activationTrigger ~= nil then
            local distanceNode = self.xmlFile:getValue(args.key .. ".trigger#distanceNode", nil, self.components, self.i3dMappings)

            if distanceNode ~= nil then
                handToolHolder.distanceNode = distanceNode
                handToolHolder.activatable.distanceNode = distanceNode

                local oldActivatableGetDistance = handToolHolder.activatable.getDistance

                handToolHolder.activatable.getDistance = function(activatable, positionX, positionY, positionZ)
                    if activatable.distanceNode ~= nil then
                        local x, y, z = getWorldTranslation(activatable.distanceNode)
                        local distance = MathUtil.vector3Length(positionX - x, positionY - y, positionZ - z)

                        return distance
                    end

                    return oldActivatableGetDistance(activatable, positionX, positionY, positionZ)
                end
            end
        end

        if handToolHolder.holderType == PlaceableHandPlantSaplings.HOLDER_TYPE then
            if handToolHolder.activationTrigger ~= nil then
                local spawnedHandTool = handToolHolder.spawnedHandTool

                if spawnedHandTool ~= nil and spawnedHandTool.spec_hpsShovel ~= nil then
                    local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

                    if spec.isValid then
                        local backpackIndex = #spec.backpacks
                        local backpackKey = string.format("placeable.handPlantSaplings.backpacks.backpack(%d)", backpackIndex)

                        local backpack = HandPlantSaplingsStorage.new(self.isServer, self.isClient)

                        if backpack:load(self, spawnedHandTool, self.xmlFile, backpackKey, self.components, self.i3dMappings) then
                            backpack.infoTableTitle = {
                                accentuate = true,
                                title = string.format("%s  #%d", g_i18n:getText("ui_ingameMissionSpecs"), backpackIndex + 1)
                            }

                            backpack.infoTablePlayer = {
                                title = g_i18n:getText("ui_playerCharacter"),
                                text = "N/A"
                            }

                            table.insert(spec.backpacks, backpack)
                            table.insert(spec.storageAreas, backpack)

                            local uniqueId = spawnedHandTool:getUniqueId()

                            if uniqueId ~= nil then
                                spec.backpacksByShovelUniqueId[uniqueId] = backpack
                            end

                            spawnedHandTool:setAttachedBackpack(backpack)

                            handToolHolder:setStoreCallback(function(shovel)
                                if backpack ~= nil then
                                    backpack:setVisibility(true)
                                end

                                SpecializationUtil.raiseEvent(self, "onShovelStoredInHolder", shovel, handToolHolder, backpack)
                            end)

                            handToolHolder:setPickupCallback(function(shovel)
                                if backpack ~= nil then
                                    backpack:setVisibility(false)
                                end

                                SpecializationUtil.raiseEvent(self, "onShovelTakenFromHolder", shovel, handToolHolder, backpack)
                            end)

                            if handToolHolder.activatable ~= nil then
                                local oldActivatableRun = handToolHolder.activatable.run

                                handToolHolder.activatable.run = function(activatable)
                                    local holderHandTool = activatable.handToolHolder:getHandTool()
                                    local localPlayer = g_localPlayer

                                    if (holderHandTool ~= nil and holderHandTool.spec_hpsShovel ~= nil) and (localPlayer ~= nil and localPlayer.carriedHandTools ~= nil) then
                                        for _, handTool in ipairs(localPlayer.carriedHandTools) do
                                            if handTool.spec_hpsShovel ~= nil then
                                                g_currentMission:showBlinkingWarning(g_i18n:getText("hps_messageDuplicateEquipment", PlaceableHandPlantSaplings.MOD_NAME))

                                                return
                                            end
                                        end
                                    end

                                    oldActivatableRun(activatable)
                                end

                                if handToolHolder.setPlayerInRange ~= nil then
                                    local oldSetPlayerInRange = handToolHolder.setPlayerInRange

                                    handToolHolder.setPlayerInRange = function(holder, isInRange)
                                        oldSetPlayerInRange(holder, isInRange)

                                        if g_handPlantSaplingsManager ~= nil then
                                            if isInRange then
                                                g_handPlantSaplingsManager:addObjectInRange(holder.activatable, self)
                                            else
                                                g_handPlantSaplingsManager:removeObjectInRange(holder.activatable, self)
                                            end
                                        end
                                    end
                                end
                            end
                        end

                        local isOutdoors = self.xmlFile:getValue(args.key .. ".holder#isOutdoors", false)
                        spawnedHandTool.spec_hpsShovel.storedOutdoors = isOutdoors

                        if spawnedHandTool.graphicalNode ~= nil then
                            setShaderParameterRecursive(spawnedHandTool.graphicalNode, "snowScale", isOutdoors and 1 or 0, 0, 0, 0, false, -1)
                        end

                        if handToolHolder.addDeleteListener ~= nil then
                            handToolHolder:addDeleteListener(self, "onDeleteShovelHolder")
                        end

                        table.insert(spec.shovelHolders, handToolHolder)
                    else
                        handToolHolder:delete()
                        handToolHolder = nil

                        Logging.xmlError(self.xmlFile, "Hand plant saplings failed to validate, hand tool '%s' failed to load.", args.key)
                    end
                else
                    handToolHolder:delete()
                    handToolHolder = nil

                    Logging.xmlError(self.xmlFile, "Hand tool spawned at '%s' is not a valid shovel.", args.key)
                end
            else
                handToolHolder:delete()
                handToolHolder = nil

                Logging.xmlError(self.xmlFile, "Missing required activation trigger for hand tool holder at '%s'.", args.key)
            end
        end
    end

    superFunc(self, handToolHolder, args)
end

function PlaceableHandPlantSaplings:onSell()
    if self.isServer then
        local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]

        if spec.totalFillTypeSellPrice > 0 then
            g_currentMission:addMoney(spec.totalFillTypeSellPrice, self:getOwnerFarmId(), MoneyType.PURCHASE_SAPLINGS, true, true)
        end

        spec.totalFillTypeSellPrice = 0
    end
end

function PlaceableHandPlantSaplings:canBeSold(superFunc)
    local canBeSold, warning = superFunc(self)

    if canBeSold and g_handPlantSaplingsManager ~= nil then
        local spec = self[PlaceableHandPlantSaplings.SPEC_TABLE_NAME]
        local manager = g_handPlantSaplingsManager

        local totalFillLevel = 0
        local totalSellPrice = 0

        if spec.backpacks ~= nil then
            for _, backpack in ipairs (spec.backpacks) do
                local treeTypeKey = backpack:getTreeTypeKey()
                local _, variationName = manager:getTreeTypeNameAndVariationName(treeTypeKey)

                if variationName ~= nil then
                    local fillLevel = backpack:getFillLevel(nil, nil, treeTypeKey)

                    if fillLevel > 0 then
                        totalFillLevel += fillLevel
                        totalSellPrice += ((variationName == "DEFAULT" and 25 or 15) * fillLevel) -- Fixed sale price, 50% of the per sapling price
                    end
                end
            end
        end

        if spec.storage ~= nil then
            for treeTypeKey, fillLevel in pairs (spec.storage:getFillLevels()) do
                local _, variationName = manager:getTreeTypeNameAndVariationName(treeTypeKey)

                if variationName ~= nil then
                    totalFillLevel += fillLevel
                    totalSellPrice += ((variationName == "DEFAULT" and 25 or 15) * fillLevel) -- Fixed sale price, 50% of the per sapling price
                end
            end
        end

        if totalFillLevel > 0 then
            local warning = g_i18n:getText("hps_messageSellNotEmpty", self.customEnvironment)
            local unitPieces = g_i18n:getText("unit_pieces")
            local sellValue = g_i18n:getText("ui_sellValue")

            spec.totalFillTypeSellPrice = totalSellPrice

            -- For some silly reason the warning is no longer shown when trying to sell unless using 'Demolition Mode', bit of a backwards step in my view.
            -- Just return true and give some money back or users will not know why they can't sell this placeable.
            return true, string.format("%s (%d %s) - %s: %s", warning, totalFillLevel, unitPieces, sellValue, g_i18n:formatMoney(totalSellPrice, 0, true, true))
        end
    end

    return canBeSold, warning
end

function PlaceableHandPlantSaplings.loadSpecValueCapacity(xmlFile, customEnvironment, baseDir)
    return xmlFile:getInt("placeable.handPlantSaplings#storeCapacity") -- Manually set to allow exclusion when required. (i.e combined silo and hps mod.)
end

function PlaceableHandPlantSaplings.getSpecValueCapacity(storeItem, realItem)
    if storeItem.specs.handPlantSaplingsCapacity ~= nil then
        return string.format("%d %s", storeItem.specs.handPlantSaplingsCapacity, g_i18n:getText("unit_pieces"))
    end

    return nil
end

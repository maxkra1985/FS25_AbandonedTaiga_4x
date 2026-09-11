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

HandToolHPSShovelInteractEvent = {}

HandToolHPSShovelInteractEvent.MOD_NAME = g_currentModName
HandToolHPSShovelInteractEvent.WARNING_IDENTIFIER = getMD5((tostring(HandToolHPSShovelInteractEvent)))

HandToolHPSShovelInteractEvent.ERROR_CODE_SUCCESS = 0
HandToolHPSShovelInteractEvent.ERROR_CODE_FAILED = 1
HandToolHPSShovelInteractEvent.ERROR_CODE_STORAGE_FULL = 2
HandToolHPSShovelInteractEvent.ERROR_CODE_STORAGE_EMPTY = 3
HandToolHPSShovelInteractEvent.ERROR_CODE_BACKPACK_FULL = 4
HandToolHPSShovelInteractEvent.ERROR_CODE_BACKPACK_EMPTY = 5
HandToolHPSShovelInteractEvent.ERROR_CODE_PALLET_FULL = 6
HandToolHPSShovelInteractEvent.ERROR_CODE_PALLET_EMPTY = 7
HandToolHPSShovelInteractEvent.ERROR_CODE_TREE_NOT_SUPPORTED = 8
HandToolHPSShovelInteractEvent.ERROR_CODE_INVALID_PALLET = 9

local HandToolHPSShovelInteractEvent_mt = Class(HandToolHPSShovelInteractEvent, Event)
InitEventClass(HandToolHPSShovelInteractEvent, "HandToolHPSShovelInteractEvent")

function HandToolHPSShovelInteractEvent.emptyNew()
    return Event.new(HandToolHPSShovelInteractEvent_mt)
end

function HandToolHPSShovelInteractEvent.new(addToBackpack, backpack, object, treeTypeIndex, treeVariationIndex)
    local self = HandToolHPSShovelInteractEvent.emptyNew()

    self.addToBackpack = addToBackpack

    self.backpack = backpack
    self.object = object

    self.treeTypeIndex = treeTypeIndex
    self.treeVariationIndex = treeVariationIndex

    return self
end

function HandToolHPSShovelInteractEvent.newServerToClient(errorCode)
    local self = HandToolHPSShovelInteractEvent.emptyNew()

    self.errorCode = errorCode

    return self
end

function HandToolHPSShovelInteractEvent:readStream(streamId, connection)
    if not connection:getIsServer() then
        self.addToBackpack = streamReadBool(streamId)

        self.backpack = NetworkUtil.readNodeObject(streamId)
        self.object = NetworkUtil.readNodeObject(streamId)

        self.treeTypeIndex = streamReadUInt8(streamId)
        self.treeVariationIndex = streamReadUIntN(streamId, TreePlantManager.VARIATION_NUM_BITS)
    else
        self.errorCode = streamReadUIntN(streamId, 4)
    end

    self:run(connection)
end

function HandToolHPSShovelInteractEvent:writeStream(streamId, connection)
    if connection:getIsServer() then
        streamWriteBool(streamId, self.addToBackpack)

        NetworkUtil.writeNodeObject(streamId, self.backpack)
        NetworkUtil.writeNodeObject(streamId, self.object)

        streamWriteUInt8(streamId, self.treeTypeIndex)
        streamWriteUIntN(streamId, self.treeVariationIndex, TreePlantManager.VARIATION_NUM_BITS)
    else
        streamWriteUIntN(streamId, self.errorCode, 4)
    end
end

function HandToolHPSShovelInteractEvent:run(connection)
    if not connection:getIsServer() then
        local errorCode = HandToolHPSShovelInteractEvent.validate(self.addToBackpack, self.backpack, self.object, self.treeTypeIndex, self.treeVariationIndex)

        if errorCode == HandToolHPSShovelInteractEvent.ERROR_CODE_SUCCESS then
            if self.object.isPallet then
                local palletFillUnit = self.object:getFillUnitByIndex(self.object.spec_treeSaplingPallet.fillUnitIndex or 1)
                local palletFillTypeIndex = palletFillUnit.fillType

                if palletFillTypeIndex == nil or palletFillTypeIndex == FillType.UNKNOWN then
                    palletFillTypeIndex = FillType.TREESAPLINGS
                end

                if self.addToBackpack then
                    local numSaplings = math.min(palletFillUnit.fillLevel, self.backpack:getFreeCapacity(self.treeTypeIndex, self.treeVariationIndex))
                    numSaplings = math.abs(self.object:addFillUnitFillLevel(self.backpack:getOwnerFarmId(), palletFillUnit.fillUnitIndex, -numSaplings, palletFillTypeIndex, ToolType.UNDEFINED) or 0)

                    if numSaplings > 0 then
                        self.backpack:addFillLevel(numSaplings, self.treeTypeIndex, self.treeVariationIndex)
                    end

                    return
                end

                local numSaplings = math.min(self.backpack:getFillLevel(self.treeTypeIndex, self.treeVariationIndex), palletFillUnit.capacity - palletFillUnit.fillLevel)
                numSaplings = math.abs(self.object:addFillUnitFillLevel(self.backpack:getOwnerFarmId(), palletFillUnit.fillUnitIndex, numSaplings, palletFillTypeIndex, ToolType.UNDEFINED) or 0)

                if numSaplings > 0 then
                    self.backpack:removeFillLevel(numSaplings, self.treeTypeIndex, self.treeVariationIndex)
                end

                return
            end

            if self.addToBackpack then
                local numSaplings = self.object:removeFillLevel(self.backpack:getFreeCapacity(self.treeTypeIndex, self.treeVariationIndex), self.treeTypeIndex, self.treeVariationIndex)

                if numSaplings > 0 then
                    self.backpack:addFillLevel(numSaplings, self.treeTypeIndex, self.treeVariationIndex)
                end

                return
            end

            local numSaplings = self.object:addFillLevel(self.backpack:getFillLevel(self.treeTypeIndex, self.treeVariationIndex), self.treeTypeIndex, self.treeVariationIndex)

            if numSaplings > 0 then
                self.backpack:removeFillLevel(numSaplings, self.treeTypeIndex, self.treeVariationIndex)
            end
        else
            connection:sendEvent(HandToolHPSShovelInteractEvent.newServerToClient(errorCode))
        end
    else
        HandToolHPSShovelInteractEvent.showBlinkingErrorMessage(self.errorCode)
    end
end

function HandToolHPSShovelInteractEvent.validate(addToBackpack, backpack, object, treeTypeIndex, treeVariationIndex)
    if backpack == nil or object == nil or treeTypeIndex == nil or treeVariationIndex == nil then
        return HandToolHPSShovelInteractEvent.ERROR_CODE_FAILED
    end

    if addToBackpack then
        if object.isPallet then
            if object.spec_treeSaplingPallet == nil then
                return HandToolHPSShovelInteractEvent.ERROR_CODE_INVALID_PALLET
            end

            if object:getFillUnitFillLevel(object.spec_treeSaplingPallet.fillUnitIndex or 1) == 0 then
                return HandToolHPSShovelInteractEvent.ERROR_CODE_PALLET_EMPTY
            end
        elseif object.isSaplingStorage then
            if object:getFillLevel(treeTypeIndex, treeVariationIndex) == 0 then
                return HandToolHPSShovelInteractEvent.ERROR_CODE_STORAGE_EMPTY
            end
        else
            return HandToolHPSShovelInteractEvent.ERROR_CODE_FAILED
        end

        if not backpack:getTreeTypeAccepted(treeTypeIndex, treeVariationIndex) then
            return HandToolHPSShovelInteractEvent.ERROR_CODE_TREE_NOT_SUPPORTED
        end

        if backpack:getFreeCapacity(treeTypeIndex, treeVariationIndex) == 0 then
            return HandToolHPSShovelInteractEvent.ERROR_CODE_BACKPACK_FULL
        end
    else
        if backpack:getFillLevel() == 0 then
            return HandToolHPSShovelInteractEvent.ERROR_CODE_BACKPACK_EMPTY
        end

        if object.isPallet then
            if object.spec_treeSaplingPallet == nil then
                return HandToolHPSShovelInteractEvent.ERROR_CODE_INVALID_PALLET
            end

            local typeIndex, variationIndex = backpack:getTreeTypeIndexAndVariationIndex()

            if typeIndex ~= treeTypeIndex or variationIndex ~= treeVariationIndex then
                return HandToolHPSShovelInteractEvent.ERROR_CODE_TREE_NOT_SUPPORTED
            end

            if object:getFillUnitFreeCapacity(object.spec_treeSaplingPallet.fillUnitIndex or 1) == 0 then
                return HandToolHPSShovelInteractEvent.ERROR_CODE_PALLET_FULL
            end
        elseif object.isSaplingStorage then
            if not object:getTreeTypeAccepted(treeTypeIndex, treeVariationIndex) then
                return HandToolHPSShovelInteractEvent.ERROR_CODE_TREE_NOT_SUPPORTED
            end

            if object:getFreeCapacity(treeTypeIndex, treeVariationIndex) == 0 then
                return HandToolHPSShovelInteractEvent.ERROR_CODE_STORAGE_FULL
            end
        else
            return HandToolHPSShovelInteractEvent.ERROR_CODE_FAILED
        end
    end

    return HandToolHPSShovelInteractEvent.ERROR_CODE_SUCCESS
end

function HandToolHPSShovelInteractEvent.showBlinkingErrorMessage(errorCode)
    if errorCode == nil or errorCode == HandToolHPSShovelInteractEvent.ERROR_CODE_SUCCESS then
        return
    end

    local errorMessage

    if errorCode == HandToolHPSShovelInteractEvent.ERROR_CODE_FAILED then
        errorMessage = g_i18n:getText("hps_warningFailed", HandToolHPSShovelInteractEvent.MOD_NAME)
    elseif errorCode == HandToolHPSShovelInteractEvent.ERROR_CODE_STORAGE_FULL then
        errorMessage = g_i18n:getText("hps_warningStorageCapacityReached", HandToolHPSShovelInteractEvent.MOD_NAME)
    elseif errorCode == HandToolHPSShovelInteractEvent.ERROR_CODE_STORAGE_EMPTY then
        errorMessage = g_i18n:getText("hps_warningStorageEmpty", HandToolHPSShovelInteractEvent.MOD_NAME)
    elseif errorCode == HandToolHPSShovelInteractEvent.ERROR_CODE_BACKPACK_FULL then
        errorMessage = g_i18n:getText("hps_warningBackpackCapacityReached", HandToolHPSShovelInteractEvent.MOD_NAME)
    elseif errorCode == HandToolHPSShovelInteractEvent.ERROR_CODE_BACKPACK_EMPTY then
        errorMessage = g_i18n:getText("hps_warningBackpackEmpty", HandToolHPSShovelInteractEvent.MOD_NAME)
    elseif errorCode == HandToolHPSShovelInteractEvent.ERROR_CODE_PALLET_FULL then
        errorMessage = g_i18n:getText("hps_warningPalletCapacityReached", HandToolHPSShovelInteractEvent.MOD_NAME)
    elseif errorCode == HandToolHPSShovelInteractEvent.ERROR_CODE_PALLET_EMPTY then
        errorMessage = g_i18n:getText("hps_warningPalletEmpty", HandToolHPSShovelInteractEvent.MOD_NAME)
    elseif errorCode == HandToolHPSShovelInteractEvent.ERROR_CODE_TREE_NOT_SUPPORTED then
        errorMessage = g_i18n:getText("hps_warningTreeTypeOrVariation", HandToolHPSShovelInteractEvent.MOD_NAME)
    elseif errorCode == HandToolHPSShovelInteractEvent.ERROR_CODE_INVALID_PALLET then
        errorMessage = g_i18n:getText("warning_toolNotCompatible")
    end

    if errorMessage ~= nil then
        g_currentMission:showBlinkingWarning(errorMessage, 2000, HandToolHPSShovelInteractEvent.WARNING_IDENTIFIER)
    end
end

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


HandToolHPSShovel = {}

HandToolHPSShovel.MOD_NAME = g_currentModName
HandToolHPSShovel.SPEC_NAME = string.format("%s.hpsShovel", g_currentModName)
HandToolHPSShovel.SPEC_TABLE_NAME = string.format("spec_%s", HandToolHPSShovel.SPEC_NAME)

HandToolHPSShovel.COLLISION_MASK = CollisionFlag.STATIC_OBJECT + CollisionFlag.TERRAIN + CollisionFlag.TERRAIN_DELTA + CollisionFlag.BUILDING + CollisionFlag.ROAD + CollisionFlag.TREE + CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.VEHICLE + CollisionFlag.PLAYER + CollisionFlag.ANIMAL
HandToolHPSShovel.MINIMUM_PLACEHOLDER_DISTANCE = 0.06
HandToolHPSShovel.MINIMUM_PLANT_DISTANCE = 1.995

function HandToolHPSShovel.prerequisitesPresent(specializations)
    -- 'setAttachedHolder' is included here directly as this is all that I require so they holder spawns the hand tool with the placeable or vehicle.
    return not SpecializationUtil.hasSpecialization(HandToolTethered, specializations)
end

function HandToolHPSShovel.registerXMLPaths(xmlSchema)
    xmlSchema:setXMLSpecializationType("HandToolHPSShovel")

    xmlSchema:register(XMLValueType.NODE_INDEX, "handTool.hpsShovel.animation#node", "Animation node")
    xmlSchema:register(XMLValueType.FLOAT, "handTool.hpsShovel.animation#autoPlantTime", "Auto plant key time", "Default 0, no auto plant")
    xmlSchema:register(XMLValueType.FLOAT, "handTool.hpsShovel.animation#duration", "Animation duration (sec.)", 4)

    xmlSchema:register(XMLValueType.VECTOR_TRANS, "handTool.hpsShovel.animation.graphics#translation", "Graphics node translation when animation is playing")
    xmlSchema:register(XMLValueType.VECTOR_ROT, "handTool.hpsShovel.animation.graphics#rotation", "Graphics node rotation when animation is playing")
    xmlSchema:register(XMLValueType.VECTOR_SCALE, "handTool.hpsShovel.animation.graphics#scale", "Graphics node scale when animation is playing")

    xmlSchema:register(XMLValueType.FLOAT, "handTool.hpsShovel.animation.keyFrames.keyFrame(?)#time", "Key time")
    xmlSchema:register(XMLValueType.VECTOR_TRANS, "handTool.hpsShovel.animation.keyFrames.keyFrame(?)#translation", "Key translation")
    xmlSchema:register(XMLValueType.VECTOR_ROT, "handTool.hpsShovel.animation.keyFrames.keyFrame(?)#rotation", "Key rotation")
    xmlSchema:register(XMLValueType.VECTOR_SCALE, "handTool.hpsShovel.animation.keyFrames.keyFrame(?)#scale", "Key scale")

    SoundManager.registerSampleXMLPaths(xmlSchema, "handTool.hpsShovel.sounds", "digging")

    xmlSchema:register(XMLValueType.STRING, "handTool.hpsShovel.placeholder#filename", "Placeholder I3D filename")
    xmlSchema:register(XMLValueType.INT, "handTool.hpsShovel.placeholder#dirtNode", "Placeholder dirt node, only with auto plant time > 0")

    xmlSchema:setXMLSpecializationType()
end

function HandToolHPSShovel.registerFunctions(handToolType)
    SpecializationUtil.registerFunction(handToolType, "startShovelDigging", HandToolHPSShovel.startShovelDigging)
    SpecializationUtil.registerFunction(handToolType, "stopShovelDigging", HandToolHPSShovel.stopShovelDigging)
    SpecializationUtil.registerFunction(handToolType, "shovelCreateTree", HandToolHPSShovel.shovelCreateTree)
    SpecializationUtil.registerFunction(handToolType, "setAttachedHolder", HandToolHPSShovel.setAttachedHolder)
    SpecializationUtil.registerFunction(handToolType, "setAttachedBackpack", HandToolHPSShovel.setAttachedBackpack)
    SpecializationUtil.registerFunction(handToolType, "setShovelState", HandToolHPSShovel.setShovelState)
    SpecializationUtil.registerFunction(handToolType, "setShovelAnimationTime", HandToolHPSShovel.setShovelAnimationTime)
    SpecializationUtil.registerFunction(handToolType, "updateShovelSaplingPlaceholder", HandToolHPSShovel.updateShovelSaplingPlaceholder)
    SpecializationUtil.registerFunction(handToolType, "updateShovelInfoBox", HandToolHPSShovel.updateShovelInfoBox)
    SpecializationUtil.registerFunction(handToolType, "getBackpack", HandToolHPSShovel.getBackpack)
    SpecializationUtil.registerFunction(handToolType, "getSaplingPalletInRange", HandToolHPSShovel.getSaplingPalletInRange)
    SpecializationUtil.registerFunction(handToolType, "getSaplingStorageInRange", HandToolHPSShovel.getSaplingStorageInRange)
end

function HandToolHPSShovel.registerOverwrittenFunctions(handToolType)
    SpecializationUtil.registerOverwrittenFunction(handToolType, "getShowInHandToolsOverview", HandToolHPSShovel.getShowInHandToolsOverview)
    SpecializationUtil.registerOverwrittenFunction(handToolType, "setHolder", HandToolHPSShovel.setHolder)
end

function HandToolHPSShovel.registerEventListeners(handToolType)
    SpecializationUtil.registerEventListener(handToolType, "onLoad", HandToolHPSShovel)
    SpecializationUtil.registerEventListener(handToolType, "onDelete", HandToolHPSShovel)
    SpecializationUtil.registerEventListener(handToolType, "onUpdate", HandToolHPSShovel)
    SpecializationUtil.registerEventListener(handToolType, "onRegisterActionEvents", HandToolHPSShovel)
    SpecializationUtil.registerEventListener(handToolType, "onHeldStart", HandToolHPSShovel)
    SpecializationUtil.registerEventListener(handToolType, "onHeldEnd", HandToolHPSShovel)
    SpecializationUtil.registerEventListener(handToolType, "onCarryingPlayerLeftGame", HandToolHPSShovel)
    SpecializationUtil.registerEventListener(handToolType, "onDebugDraw", HandToolHPSShovel)
end

function HandToolHPSShovel:onLoad(xmlFile, baseDirectory)
    self.spec_hpsShovel = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    if self.spec_hpsShovel == nil then
        Logging.error("[%s] Specialisation with name 'hpsShovel' was not found in modDesc!", HandToolHPSShovel.MOD_NAME)
        self:setLoadingState(HandToolLoadingState.ERROR)

        return
    end

    local spec = self.spec_hpsShovel

    spec.storedOutdoors = false

    spec.isPlanting = false
    spec.isAutoPlanting = false

    spec.plantedTreeCount = 0
    spec.targetLocation = {0, 0, 0}
    spec.currentShovelState = HandToolHPSShovelState.NONE

    spec.attachedObject = nil
    spec.attachedHolder = nil

    spec.warningIdentifier = getMD5(tostring(self))

    spec.texts = {
        infoBoxTitle = g_i18n:getText("ui_ingameMissionSpecs"),
        infoBoxPlantedTrees = g_i18n:getText("statistic_plantedTreeCount"),
        infoBoxRange = g_i18n:getText("infohud_range"),
        infoBoxLandNotOwned = g_i18n:getText("warning_youDontHaveAccessToThisLand"),
        infoBoxActionNotAllowedHere = g_i18n:getText("warning_actionNotAllowedHere"),
        infoBoxRangeTooShort = g_i18n:getText("ui_construction_distanceTooShort"),
        infoBoxFlightModeActive = g_i18n:getText("hps_messageFlightState", HandToolHPSShovel.MOD_NAME),
        actionAddToStorage = g_i18n:getText("hps_addToStorage", HandToolHPSShovel.MOD_NAME),
        actionRemoveFromStorage = g_i18n:getText("hps_removeFromStorage", HandToolHPSShovel.MOD_NAME),
        actionAddToPallet = g_i18n:getText("hps_addToPallet", HandToolHPSShovel.MOD_NAME),
        actionRemoveFromPallet = g_i18n:getText("hps_removeFromPallet", HandToolHPSShovel.MOD_NAME),
        resetCounter = g_i18n:getText("hps_resetcounter", HandToolHPSShovel.MOD_NAME),
        freeModeOn = g_i18n:getText("hps_freeModeOn", HandToolHPSShovel.MOD_NAME),
        actionPlantTree = g_i18n:getText("action_plantTree"),
        saplingTitle = g_i18n:getText("category_palletForestry")
    }

    spec.animation = {
        node = nil,
        duration = 1000,
        autoPlantTime = 0,
        currentTime = 0,
        valid = false,
        graphics = {
            node = self.graphicalNode,
            translation = {0, 0, 0},
            rotation = {0, 0, 0},
            scale = {1, 1, 1}
        }
    }

    if xmlFile:hasProperty("handTool.hpsShovel.animation") then
        local animationNode = xmlFile:getValue("handTool.hpsShovel.animation#node", nil, self.components, self.i3dMappings)

        if animationNode == nil then
            Logging.xmlWarning(xmlFile, "Missing node at 'handTool.hpsShovel.animation#node'!")
            self:setLoadingState(HandToolLoadingState.ERROR)

            return
        end

        spec.animation.node = animationNode
        spec.animation.duration = math.max(xmlFile:getValue("handTool.hpsShovel.animation#duration", 1), 1) * 1000
        spec.animation.autoPlantTime = xmlFile:getValue("handTool.hpsShovel.animation#autoPlantTime", 0)

        local nodeTranslation = {getTranslation(animationNode)}
        local nodeRotation = {getRotation(animationNode)}
        local nodeScale = {getScale(animationNode)}
        local animationCurve = AnimCurve.new(linearInterpolatorN)

        for keyFrameIndex, keyFrameKey in xmlFile:iterator("handTool.hpsShovel.animation.keyFrames.keyFrame") do
            local keyTime = xmlFile:getValue(keyFrameKey .. "#time")

            if keyTime ~= nil then
                local x, y, z = xmlFile:getValue(keyFrameKey .. "#translation", nodeTranslation)
                local rx, ry, rz = xmlFile:getValue(keyFrameKey .. "#rotation", nodeRotation)
                local sx, sy, sz = xmlFile:getValue(keyFrameKey .. "#scale", nodeScale)

                animationCurve:addKeyframe({x, y, z, rx, ry, rz, sx, sy, sz, time = keyTime})
            end
        end

        if animationCurve.numKeyframes > 0 then
            local translation = spec.animation.graphics.translation
            local rotation = spec.animation.graphics.rotation
            local scale = spec.animation.graphics.scale

            translation[1], translation[2], translation[3] = xmlFile:getValue("handTool.hpsShovel.animation.graphics#translation", "0 0 0", false)
            rotation[1], rotation[2], rotation[3] = xmlFile:getValue("handTool.hpsShovel.animation.graphics#rotation", "0 0 0", false)
            scale[1], scale[2], scale[3] = xmlFile:getValue("handTool.hpsShovel.animation.graphics#scale", "1 1 1", false)

            spec.animation.curve = animationCurve
            spec.animation.valid = true
        elseif animationCurve.delete ~= nil then
            animationCurve:delete()
        end
    end

    local placeholderFilename = xmlFile:getValue("handTool.hpsShovel.placeholder#filename")

    if placeholderFilename ~= nil then
        placeholderFilename = Utils.getFilename(placeholderFilename, baseDirectory)

        local dirtNode = xmlFile:getValue("handTool.hpsShovel.placeholder#dirtNode")

        spec.sharedLoadRequestIdPlaceholder = g_i3DManager:loadSharedI3DFileAsync(placeholderFilename, true, false, HandToolHPSShovel.onPlaceholderLoaded, self, dirtNode)
        spec.placeholderLoadingTask = self:createLoadingTask(spec)
    end

    if self.isClient then
        spec.infoBox = g_currentMission.hud.infoDisplay:createBox(InfoDisplayKeyValueBox)
        spec.diggingSample = g_soundManager:loadSampleFromXML(xmlFile, "handTool.hpsShovel.sounds", "digging", baseDirectory, self.components, 1, AudioGroup.VEHICLE, self.i3dMappings, self)
    end

    -- These values do not need to change so hard coded here to be safe
    self.canBeSaved = false
    self.mustBeHeld = false
    self.canBeDropped = true
    self.shouldLockFirstPerson = true
end

function HandToolHPSShovel:onDelete()
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    if spec.placeholder ~= nil then
        delete(spec.placeholder)

        spec.placeholder = nil
    end

    if spec.sharedLoadRequestIdPlaceholder ~= nil then
        g_i3DManager:releaseSharedI3DFile(spec.sharedLoadRequestIdPlaceholder)
        spec.sharedLoadRequestIdPlaceholder = nil
    end

    if self.isClient then
        if spec.infoBox ~= nil then
            if g_currentMission ~= nil and g_currentMission.hud ~= nil then
                g_currentMission.hud.infoDisplay:destroyBox(spec.infoBox)
            end

            spec.infoBox = nil
        end

        g_soundManager:deleteSample(spec.diggingSample)
    end
end

function HandToolHPSShovel:onUpdate(dt)
    local carryingPlayer = self:getCarryingPlayer()

    if carryingPlayer ~= nil and self:getIsHeld() then
        local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

        if carryingPlayer.isOwner then
            if spec.isPlanting or spec.isAutoPlanting then
                if spec.animation.autoPlantTime > 0 then
                    spec.isAutoPlanting = spec.animation.currentTime >= spec.animation.autoPlantTime
                end

                if self:setShovelAnimationTime(spec.animation.currentTime + dt / spec.animation.duration) == 1 then
                    self:stopShovelDigging(true, true)
                end
            else
                local shovelState, plantActionEventActive, plantActionEventText, secondryActionEventText = HandToolHPSShovelState.NONE, true, spec.texts.actionPlantTree, nil

                spec.palletInRange = nil
                spec.storageInRange = nil
                spec.objectInRange = nil
                spec.hitObjectId = nil

                if g_gui.currentGuiName ~= "ConstructionScreen" then
                    if carryingPlayer.mover == nil or not carryingPlayer.mover.isFlightActive then
                        spec.palletInRange = self:getSaplingPalletInRange()

                        if spec.palletInRange == nil then
                            spec.storageInRange, spec.objectInRange = self:getSaplingStorageInRange()

                            if spec.objectInRange == nil then
                                local hitObjectId, hitX, hitY, hitZ = HandToolHPSShovel.getTargetedLocation(carryingPlayer, 2, 2, 2)

                                if spec.lastTreePos ~= nil then
                                    spec.lastDistance = MathUtil.vector3Length(hitX - spec.lastTreePos[1], hitY - spec.lastTreePos[2], hitZ - spec.lastTreePos[3])
                                end

                                if hitObjectId ~= nil then
                                    local lastDistance = spec.lastDistance or HandToolHPSShovel.MINIMUM_PLANT_DISTANCE

                                    if lastDistance >= HandToolHPSShovel.MINIMUM_PLACEHOLDER_DISTANCE then
                                        shovelState = HandToolHPSShovelState.INVALID
                                    end

                                    local object = g_currentMission:getNodeObject(hitObjectId)

                                    if object == nil then
                                        if spec.plantAnywhereActive or g_currentMission.accessHandler:canFarmAccessLand(carryingPlayer.farmId, hitX, hitZ) then
                                            if not PlacementUtil.isInsideRestrictedZone(g_currentMission.restrictedZones, hitX, hitY, hitZ, true) then
                                                if hitObjectId == g_terrainNode then
                                                    if lastDistance >= HandToolHPSShovel.MINIMUM_PLANT_DISTANCE then
                                                        local _, _, _, _, surfaceId = getTerrainAttributesAtWorldPos(hitObjectId, hitX, hitY, hitZ, true, true, true, true, false)

                                                        -- TO_DO: Improve in case of mod map changes, but then it would be bad practice to not match base game with something like this.
                                                        if surfaceId < 7 then
                                                            shovelState = HandToolHPSShovelState.READY
                                                        end
                                                    end
                                                end
                                            else
                                                shovelState = HandToolHPSShovelState.RESTICTED_ZONE
                                            end
                                        else
                                            shovelState = HandToolHPSShovelState.UNOWNED_LAND
                                        end
                                    elseif object:isa(Vehicle) and object.isPallet and object.spec_treeSaplingPallet ~= nil and object.getTreeSaplingPalletType ~= nil then
                                        for fillUnitIndex, fillUnit in pairs(object:getFillUnits()) do
                                            -- If the object is a sapling pallet then access it without requiring hud updater focus
                                            if fillUnit.fillType == FillType.TREESAPLINGS and fillUnit.fillLevel > 0 then
                                                spec.palletInRange = object

                                                plantActionEventText = spec.texts.actionAddToPallet
                                                secondryActionEventText = spec.texts.actionRemoveFromPallet

                                                shovelState = HandToolHPSShovelState.STORAGE_IN_RANGE

                                                break
                                            end
                                        end
                                    end

                                    spec.targetLocation[1] = hitX
                                    spec.targetLocation[2] = hitY
                                    spec.targetLocation[3] = hitZ

                                    spec.hitObjectId = hitObjectId
                                end
                            else
                                plantActionEventActive = spec.storageInRange ~= nil

                                if plantActionEventActive then
                                    plantActionEventText = spec.texts.actionAddToStorage
                                    secondryActionEventText = spec.texts.actionRemoveFromStorage
                                end

                                shovelState = HandToolHPSShovelState.STORAGE_IN_RANGE
                            end
                        else
                            plantActionEventText = spec.texts.actionAddToPallet
                            secondryActionEventText = spec.texts.actionRemoveFromPallet

                            shovelState = HandToolHPSShovelState.STORAGE_IN_RANGE
                        end
                    else
                        shovelState = HandToolHPSShovelState.FLIGHT_ACTIVE
                    end
                else
                    shovelState = HandToolHPSShovelState.CONSTRUCTION_SCREEN_OPEN
                end

                self:setShovelState(shovelState)

                if spec.plantAnywhereActionEventId ~= nil then
                    if self.isServer or g_currentMission.isMasterUser then
                        local actionText = string.format(g_i18n:getText("input_CONSTRUCTION_FREEMODE"), g_i18n:getText(spec.plantAnywhereActive and "ui_on" or "ui_off"))

                        g_inputBinding:setActionEventText(spec.plantAnywhereActionEventId, actionText)
                        g_inputBinding:setActionEventActive(spec.plantAnywhereActionEventId, true)
                    else
                        g_inputBinding:setActionEventActive(spec.plantAnywhereActionEventId, false)
                    end
                end

                if spec.storageInteractActionEventId ~= nil then
                    if secondryActionEventText ~= nil then
                        g_inputBinding:setActionEventText(spec.storageInteractActionEventId, secondryActionEventText)
                        g_inputBinding:setActionEventActive(spec.storageInteractActionEventId, true)
                    else
                        g_inputBinding:setActionEventActive(spec.storageInteractActionEventId, false)
                    end
                end

                if spec.resetPlantedTreesActionEventId ~= nil then
                    g_inputBinding:setActionEventTextVisibility(spec.resetPlantedTreesActionEventId, spec.plantedTreeCount ~= 0)
                end

                g_inputBinding:setActionEventText(spec.plantActionEventId, plantActionEventText)
                g_inputBinding:setActionEventActive(spec.plantActionEventId, plantActionEventActive)
                -- g_inputBinding:setActionEventActive(spec.plantActionEventId, shovelState == HandToolHPSShovelState.STORAGE_IN_RANGE or g_currentMission.activatableObjectsSystem:getActivatable() == nil)
            end

            self:updateShovelInfoBox()
            self:updateShovelSaplingPlaceholder()
        end
    end
end

function HandToolHPSShovel:onDebugDraw(x, y, textSize)
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    y = DebugUtil.renderNewLine(y, textSize)
    y = DebugUtil.renderTextLine(x, y, textSize * 1.5, "HPS Shovel", nil, true)

    local ownerName = "None"

    if spec.attachedObject ~= nil and not spec.attachedObject.isDeleted then
        ownerName = (spec.attachedObject:isa(Placeable) and "Placeable: " or "Vehicle: ") .. tostring(spec.attachedObject:getName())
    end

    y = DebugUtil.renderTextLine(x, y, textSize, string.format("%s (%s)", ownerName, tostring(spec.attachedObject or " - ")), nil, false)

    local state = spec.currentShovelState or HandToolHPSShovelState.NONE
    local stateName = HandToolHPSShovelState.getName(state)
    local stateTextColour = HandToolHPSShovelState.getColour(state)

    y = DebugUtil.renderTextLine(x, y, textSize, string.format("State: %s", tostring(stateName)), nil, false, stateTextColour)

    if spec.animation.autoPlantTime > 0 then
        y = DebugUtil.renderTextLine(x, y, textSize, string.format("Auto Plant Time: %.2f  (%.3f)", spec.animation.duration * spec.animation.autoPlantTime, spec.animation.autoPlantTime))
        y = DebugUtil.renderTextLine(x, y, textSize, string.format("Animation Time: %.2f / %.2f  (%.3f)", spec.animation.duration * spec.animation.currentTime, spec.animation.duration, spec.animation.currentTime))
    end

    y = DebugUtil.renderTextLine(x, y, textSize, string.format("Auto Planting: %s", tostring(spec.isAutoPlanting)))

    local hitObject = spec.hitObjectId ~= nil
    local hitObjectName = tostring(hitObject and getName(spec.hitObjectId) or "No Target")
    y = DebugUtil.renderTextLine(x, y, textSize, string.format("Hit Object: %s", hitObjectName))

    if hitObject then
        DebugUtil.drawDebugGizmoAtWorldPos(spec.targetLocation[1], spec.targetLocation[2], spec.targetLocation[3], 0, 0, 1, 0, 1, 0, hitObjectName, false)
    end

    y = DebugUtil.renderTextLine(x, y, textSize, string.format("Pallet in range: %s", tostring(spec.palletInRange ~= nil)))
    y = DebugUtil.renderTextLine(x, y, textSize, string.format("Storage in range: %s", tostring(spec.storageInRange ~= nil)))

    return y
end

function HandToolHPSShovel:onRegisterActionEvents()
    if self:getIsActiveForInput(true) then
        local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

        -- inputAction, target, callback, triggerUp, triggerDown, triggerAlways, startActive, callbackState, customIconName, reportAnyDeviceCollision
        local _, actionEventId = self:addActionEvent(InputAction.HPS_TOGGLE_FREE_PLANT, self, HandToolHPSShovel.actionEventPlantAnywhere, false, true, false, false, nil)
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_HIGH)
        spec.plantAnywhereActionEventId = actionEventId

        _, actionEventId = self:addActionEvent(InputAction.BALE_COUNTER_RESET, self, HandToolHPSShovel.actionEventResetPlantedTrees, false, true, false, true, nil)
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventText(actionEventId, spec.texts.resetCounter)
        spec.resetPlantedTreesActionEventId = actionEventId

        _, actionEventId = self:addActionEvent(InputAction.HPS_ACTION_SECONDRY, self, HandToolHPSShovel.actionEventStorageInteract, false, true, false, false, nil)
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_VERY_HIGH)
        spec.storageInteractActionEventId = actionEventId

        _, actionEventId = self:addActionEvent(InputAction.ACTIVATE_HANDTOOL, self, HandToolHPSShovel.actionEventPlant, true, true, false, true, nil)
        g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventText(actionEventId, spec.texts.actionPlantTree)
        spec.plantActionEventId = actionEventId
    end
end

function HandToolHPSShovel:onPlaceholderLoaded(node, failedReason, dirtNode)
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    self:finishLoadingTask(spec.placeholderLoadingTask)
    spec.placeholderLoadingTask = nil

    if node ~= nil and node ~= 0 then
        if not self.isDeleted then
            spec.placeholder = getChildAt(node, 0)

            if dirtNode ~= nil then
                spec.placeholderDirt = getChildAt(spec.placeholder, dirtNode)
                setVisibility(spec.placeholderDirt, false)
            end

            setVisibility(spec.placeholder, false)
            link(g_terrainNode, spec.placeholder)
        end

        delete(node)
    else
        Logging.error("Failed to load sapling placeholder for shovel!")
    end
end

function HandToolHPSShovel:onHeldStart()
    self:setShovelState(HandToolHPSShovelState.NONE, true)
    self:updateShovelSaplingPlaceholder()

    if self.graphicalNode ~= nil then
        setTranslation(self.graphicalNode, 0, 0, 0)
        setRotation(self.graphicalNode, 0, 0, 0)
        setScale(self.graphicalNode, 1, 1, 1)

        local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

        if spec.storedOutdoors then
            setShaderParameterRecursive(self.graphicalNode, "snowScale", 0, 0, 0, 0, false, -1)
        end
    end
end

function HandToolHPSShovel:onHeldEnd()
    self:setShovelState(HandToolHPSShovelState.NONE, true)
    self:updateShovelSaplingPlaceholder()

    if self.graphicalNode ~= nil then
        local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

        if spec.storedOutdoors then
            setShaderParameterRecursive(self.graphicalNode, "snowScale", 1, 0, 0, 0, false, -1)
        end
    end

    self:stopShovelDigging(false, true)
end

function HandToolHPSShovel:onCarryingPlayerLeftGame()
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    if spec.attachedHolder ~= nil then
        self:setHolder(spec.attachedHolder, noEventSend)
    end
end

function HandToolHPSShovel:startShovelDigging()
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]
    local carryingPlayer = self:getCarryingPlayer()

    if carryingPlayer and carryingPlayer.isOwner then
        if spec.currentShovelState == HandToolHPSShovelState.READY then
            if not g_treePlantManager:canPlantTree() then
                g_currentMission:showBlinkingWarning(g_i18n:getText("warning_tooManyTrees"), nil, spec.warningIdentifier)

                return
            elseif spec.backpack == nil or spec.backpack:getFillLevel() <= 0 then
                g_currentMission:showBlinkingWarning(g_i18n:getText("info_firstFillTheTool"), nil, spec.warningIdentifier)

                return
            end

            if carryingPlayer.inputComponent ~= nil then
                carryingPlayer.inputComponent:lock()
            end

            if spec.animation.valid then
                if self.graphicalNode ~= nil then
                    local data = spec.animation.graphics
                    local targetLocation = spec.targetLocation

                    link(g_terrainNode, self.graphicalNode)

                    setTranslation(self.graphicalNode, targetLocation[1] + data.translation[1], targetLocation[2] +  data.translation[2], targetLocation[3] + data.translation[3])
                    setRotation(self.graphicalNode, data.rotation[1], carryingPlayer:getYaw() + data.rotation[2], data.rotation[3])
                    setScale(self.graphicalNode, data.scale[1], data.scale[2], data.scale[3])
                end
            end

            spec.isAutoPlanting = false
            spec.isPlanting = true

            self:setShovelState(HandToolHPSShovelState.PLANTING)

            g_inputBinding:setActionEventTextVisibility(spec.plantActionEventId, false)
        else
            if spec.currentShovelState == HandToolHPSShovelState.FLIGHT_ACTIVE then
                g_currentMission:showBlinkingWarning(string.format("%s\n\n(%s)", g_i18n:getText("warning_actionNotAllowedNow"), spec.texts.infoBoxFlightModeActive), 2000, spec.warningIdentifier)
            elseif spec.currentShovelState == HandToolHPSShovelState.UNOWNED_LAND then
                g_currentMission:showBlinkingWarning(spec.texts.infoBoxLandNotOwned, 2000, spec.warningIdentifier)
            elseif spec.currentShovelState == HandToolHPSShovelState.RESTICTED_ZONE then
                g_currentMission:showBlinkingWarning(spec.texts.infoBoxActionNotAllowedHere, 2000, spec.warningIdentifier)
            elseif spec.backpack == nil or spec.backpack:getFillLevel() == 0 then
                g_currentMission:showBlinkingWarning(g_i18n:getText("info_firstFillTheTool"), 2000, spec.warningIdentifier)
            elseif spec.lastDistance ~= nil and spec.lastDistance < HandToolHPSShovel.MINIMUM_PLANT_DISTANCE then
                g_currentMission:showBlinkingWarning(string.format("%s\n\n(%s)", g_i18n:getText("warning_actionNotAllowedNow"), spec.texts.infoBoxRangeTooShort), 2000, spec.warningIdentifier)
            else
                g_currentMission:showBlinkingWarning(g_i18n:getText("warning_actionNotAllowedNow"), 2000, spec.warningIdentifier)
            end
        end
    end
end

function HandToolHPSShovel:stopShovelDigging(plantTree, forceStop)
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]
    local carryingPlayer = self:getCarryingPlayer()

    if carryingPlayer and carryingPlayer.isOwner then
        if not spec.isAutoPlanting or forceStop then
            local x, y, z = unpack(spec.targetLocation)

            spec.isPlanting = false
            spec.isAutoPlanting = false

            self:setShovelAnimationTime(0)

            if self.graphicalNodeParent ~= nil and self.graphicalNode ~= nil then
                link(self.graphicalNodeParent, self.graphicalNode)

                setTranslation(self.graphicalNode, 0, 0, 0)
                setRotation(self.graphicalNode, 0, 0, 0)
                setScale(self.graphicalNode, 1, 1, 1)
            end

            if carryingPlayer.inputComponent ~= nil then
                carryingPlayer.inputComponent:unlock()
            end

            g_inputBinding:setActionEventTextVisibility(spec.plantActionEventId, true)

            if plantTree then
                self:shovelCreateTree(x, y, z)
            end
        end
    end
end

function HandToolHPSShovel:shovelCreateTree(x, y, z, noEventSend)
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]
    local treeTypeIndex, variationIndex, treeTypeKey

    if spec.backpack ~= nil then
        treeTypeIndex, treeVariationIndex, treeTypeKey = spec.backpack:getTreeTypeIndexAndVariationIndex()
    end

    if treeTypeIndex == nil or treeVariationIndex == nil then
        Logging.error("Failed to plant tree. Tree type not found. (treeType %s, variation %s)", tostring(treeTypeIndex), tostring(treeVariationIndex))

        return
    end

    if x == nil or y == nil or z == nil then
        Logging.error("Failed to plant tree. Invalid location given x: %s | y: %s | z: %s", tostring(x), tostring(y), tostring(z))

        return
    end

    if self.isServer then
        local yRot = math.random() * 2 * math.pi

        g_treePlantManager:plantTree(treeTypeIndex, x, y, z, 0, yRot, 0, 1, treeVariationIndex)

        spec.backpack:removeFillLevel(1, treeTypeIndex, treeVariationIndex, treeTypeKey)

        g_farmManager:updateFarmStats(self:getOwnerFarmId(), "plantedTreeCount", 1)
    end

    HandToolHPSShovelPlantEvent.sendEvent(self, x, y, z, noEventSend)

    if spec.lastTreePos == nil then
        spec.lastTreePos = {x, y, z}
    else
        spec.lastTreePos[1], spec.lastTreePos[2], spec.lastTreePos[3] = x, y, z
    end

    spec.plantedTreeCount += 1
end

function HandToolHPSShovel.shovelInteractWithObject(addToBackpack, backpack, object)
    if backpack ~= nil and object ~= nil then
        local treeTypeIndex, treeVariationIndex = 0, 1

        if object.spec_treeSaplingPallet ~= nil then
            local treeTypeName, variationName = object:getTreeSaplingPalletType()

            treeTypeIndex, treeVariationIndex = g_treePlantManager:getTreeTypeIndexAndVariationFromName(treeTypeName, 1, variationName)
        else
            if addToBackpack then
                local manager = g_handPlantSaplingsManager
                local options, numOptions = nil, 0

                for treeTypeKey, fillLevel in pairs (object:getFillLevels()) do
                    if fillLevel > 0 then
                        if options == nil then
                            options = {}
                        end

                        local option = {
                            treeTypeKey = treeTypeKey,
                            treeTypeTitle = manager:getTreeTypeTitle(nil, nil, treeTypeKey)
                        }

                        option.treeTypeIndex, option.treeVariationIndex = manager:getTreeTypeIndexAndVariationIndex(treeTypeKey)

                        table.insert(options, option)

                        numOptions += 1
                    end
                end

                if numOptions > 0 then
                    if numOptions == 1 then
                        treeTypeIndex, treeVariationIndex = options[1].treeTypeIndex, options[1].treeVariationIndex
                    else
                        local showOptions = true

                        treeTypeIndex, treeVariationIndex = backpack:getTreeTypeIndexAndVariationIndex()

                        if treeTypeIndex ~= 0 then
                            for _, option in ipairs(options) do
                                if treeTypeIndex == option.treeTypeIndex and treeVariationIndex == option.treeVariationIndex then
                                    showOptions = false

                                    break
                                end
                            end
                        end

                        if showOptions then
                            table.sort(options, function (a, b)
                                return a.treeTypeTitle < b.treeTypeTitle
                            end)

                            local titles = {}

                            for _, option in pairs(options) do
                                table.insert(titles, option.treeTypeTitle)
                            end

                            local function onSelectedCallback(index)
                                if index ~= nil and index > 0 then
                                    local option = options[index]

                                    if option ~= nil then
                                        local errorCode = HandToolHPSShovelInteractEvent.validate(addToBackpack, backpack, object, option.treeTypeIndex, option.treeVariationIndex)

                                        if errorCode == HandToolHPSShovelInteractEvent.ERROR_CODE_SUCCESS then
                                            g_client:getServerConnection():sendEvent(HandToolHPSShovelInteractEvent.new(addToBackpack, backpack, object, option.treeTypeIndex, option.treeVariationIndex))
                                        else
                                            HandToolHPSShovelInteractEvent.showBlinkingErrorMessage(errorCode)
                                        end
                                    end
                                end
                            end

                            OptionDialog.show(onSelectedCallback, g_i18n:getText("hps_removeFromStorageDialog", HandToolHPSShovel.MOD_NAME), object:getName(), titles)

                            return
                        end
                    end
                else
                    HandToolHPSShovelInteractEvent.showBlinkingErrorMessage(HandToolHPSShovelInteractEvent.ERROR_CODE_STORAGE_EMPTY)
                end
            else
                treeTypeIndex, treeVariationIndex = backpack:getTreeTypeIndexAndVariationIndex()
            end
        end

        local errorCode = HandToolHPSShovelInteractEvent.validate(addToBackpack, backpack, object, treeTypeIndex, treeVariationIndex)

        if errorCode == HandToolHPSShovelInteractEvent.ERROR_CODE_SUCCESS then
            g_client:getServerConnection():sendEvent(HandToolHPSShovelInteractEvent.new(addToBackpack, backpack, object, treeTypeIndex, treeVariationIndex))
        else
            HandToolHPSShovelInteractEvent.showBlinkingErrorMessage(errorCode)
        end
    else
        HandToolHPSShovelInteractEvent.showBlinkingErrorMessage(HandToolHPSShovelInteractEvent.ERROR_CODE_FAILED)
    end
end

function HandToolHPSShovel:actionEventPlant(_, inputValue)
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    if inputValue > 0 then
        if spec.currentShovelState == HandToolHPSShovelState.STORAGE_IN_RANGE then
            HandToolHPSShovel.shovelInteractWithObject(false, self:getBackpack(), spec.palletInRange or spec.storageInRange)
        else
            self:startShovelDigging()
        end
    elseif spec.isPlanting then
        self:stopShovelDigging(false)
    end
end

function HandToolHPSShovel:actionEventStorageInteract(_, inputValue)
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    if spec.currentShovelState == HandToolHPSShovelState.STORAGE_IN_RANGE then
        HandToolHPSShovel.shovelInteractWithObject(true, self:getBackpack(), spec.palletInRange or spec.storageInRange)
    end
end

function HandToolHPSShovel:actionEventPlantAnywhere(_, inputValue)
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    if not spec.isPlanting then
        if self.isServer or g_currentMission.isMasterUser then
            spec.plantAnywhereActive = not spec.plantAnywhereActive
        else
            spec.plantAnywhereActive = false
        end
    end
end

function HandToolHPSShovel:actionEventResetPlantedTrees(_, inputValue)
    self[HandToolHPSShovel.SPEC_TABLE_NAME].plantedTreeCount = 0
end

function HandToolHPSShovel:setAttachedHolder(holder)
    if holder ~= nil then
        local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

        if spec.attachedHolder == nil then
            local parent = holder.parent

            if parent.spec_handPlantSaplings ~= nil then
                spec.attachedObject = parent
                spec.attachedHolder = holder
            else
                Logging.devWarning("Failed to set attached holder, missing required 'handPlantSaplings' specialisation!")
            end
        else
            Logging.devWarning("Failed to set attached holder, this has already been completed. (%s)", tostring(spec.attachedHolder))
        end
    end
end

function HandToolHPSShovel:setAttachedBackpack(backpack)
    if backpack ~= nil then
        local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

        if spec.backpack == nil then
            if backpack.isSaplingStorage then
                spec.backpack = backpack
            else
                Logging.devWarning("Failed to set attached backpack, object (%s) is not a valid sapling storage!", tostring(backpack))
            end
        else
            Logging.devWarning("Failed to set attached backpack, this has already been completed. (%s)", tostring(spec.backpack))
        end
    end
end

function HandToolHPSShovel:setShovelState(shovelState, noEventSend)
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    if spec.currentShovelState ~= shovelState then
        spec.currentShovelState = shovelState

        local shovelVisible = shovelState ~= HandToolHPSShovelState.CONSTRUCTION_SCREEN_OPEN

        if spec.shovelVisible ~= shovelVisible then
            spec.shovelVisible = shovelVisible

            if self.graphicalNode ~= nil then
                setVisibility(self.graphicalNode, shovelVisible)
            end
        end

        -- HandToolHPSShovelStateEvent.sendEvent(self, shovelState, noEventSend)
    end
end

function HandToolHPSShovel:setShovelAnimationTime(currentTime)
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    currentTime = math.clamp(currentTime or 0, 0, 1)

    if spec.animation.valid ~= nil then
        local x, y, z, rx, ry, rz, sx, sy, sz = spec.animation.curve:get(currentTime)

        setTranslation(spec.animation.node, x, y, z)
        setRotation(spec.animation.node, rx, ry, rz)
        setScale(spec.animation.node, sx, sy, sz)
    end

    spec.animation.currentTime = currentTime

    local diggingSamplePlaying = currentTime > 0

    if spec.diggingSamplePlaying ~= diggingSamplePlaying then
        spec.diggingSamplePlaying = diggingSamplePlaying

        if diggingSamplePlaying then
            g_soundManager:playSample(spec.diggingSample)
        else
            g_soundManager:stopSample(spec.diggingSample)
        end
    end

    return currentTime
end

function HandToolHPSShovel:updateShovelSaplingPlaceholder()
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    if spec.placeholder ~= nil then
        local visible = spec.currentShovelState < HandToolHPSShovelState.NONE

        setVisibility(spec.placeholder, visible)

        if spec.placeholderDirt ~= nil then
            setVisibility(spec.placeholderDirt, visible and spec.isAutoPlanting)
        end

        if visible then
            local targetLocation = spec.targetLocation
            local colour = HandToolHPSShovelState.getColour(spec.currentShovelState)

            setTranslation(spec.placeholder, targetLocation[1], targetLocation[2], targetLocation[3])
            setShaderParameter(spec.placeholder, "colorScale", colour.r, colour.g, colour.b, colour.a, false)
        end
    end
end

function HandToolHPSShovel:updateShovelInfoBox()
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    if spec.storageInRange ~= nil then
        return
    end

    local infoBox, texts = spec.infoBox, spec.texts

    if infoBox ~= nil and texts ~= nil then
        infoBox:clear()
        infoBox:setTitle(texts.infoBoxTitle)

        infoBox:addLine(texts.infoBoxPlantedTrees, tostring(spec.plantedTreeCount or 0), false)

        local manager = g_handPlantSaplingsManager
        local backpack, fillLevel, treeTypeKey = spec.backpack, 0, nil

        if backpack ~= nil then
            treeTypeKey = backpack:getTreeTypeKey()
            fillLevel = backpack:getFillLevel(nil, nil, treeTypeKey)
        end

        if fillLevel > 0 then
            infoBox:addLine(manager:getTreeTypeTitle(nil, nil, treeTypeKey), string.format("%d / %d", fillLevel, backpack:getCapacity()), false)
        else
            infoBox:addLine(g_i18n:getText("info_firstFillTheTool"), "", true)
        end

        if spec.currentShovelState ~= HandToolHPSShovelState.FLIGHT_ACTIVE then
            if fillLevel > 0 and spec.lastDistance ~= nil then
                if g_i18n.useFahrenheit then
                    infoBox:addLine(texts.infoBoxRange, string.format("%.2f %s", spec.lastDistance * 3.28084, g_i18n:getText("unit_ftShort")), false)
                else
                    infoBox:addLine(texts.infoBoxRange, string.format("%.2f %s", spec.lastDistance, g_i18n:getText("unit_mShort")), false)
                end

                if spec.plantAnywhereActive then
                    infoBox:addLine(texts.freeModeOn, "", true)

                    if spec.lastDistance < HandToolHPSShovel.MINIMUM_PLANT_DISTANCE then
                        infoBox:addLine(texts.infoBoxRangeTooShort, "", true)
                    end
                elseif spec.currentShovelState == HandToolHPSShovelState.UNOWNED_LAND then
                    infoBox:addLine(texts.infoBoxLandNotOwned, "", true)
                elseif spec.currentShovelState == HandToolHPSShovelState.RESTICTED_ZONE then
                    infoBox:addLine(texts.infoBoxActionNotAllowedHere, "", true)
                elseif spec.lastDistance < HandToolHPSShovel.MINIMUM_PLANT_DISTANCE then
                    infoBox:addLine(texts.infoBoxRangeTooShort, "", true)
                end
            elseif spec.plantAnywhereActive then
                infoBox:addLine(texts.freeModeOn, "", true)
            elseif spec.currentShovelState == HandToolHPSShovelState.UNOWNED_LAND and spec.palletInRange == nil then
                infoBox:addLine(texts.infoBoxLandNotOwned, "", true)
            elseif spec.currentShovelState == HandToolHPSShovelState.RESTICTED_ZONE then
                infoBox:addLine(texts.infoBoxActionNotAllowedHere, "", true)
            end
        else
            infoBox:addLine(texts.infoBoxFlightModeActive, "", true)
        end

        infoBox:showNextFrame()
    end
end

function HandToolHPSShovel:getBackpack()
    -- local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    -- if spec.attachedObject ~= nil then
        -- return spec.attachedObject:getSaplingBackpack(self)
    -- end

    return self[HandToolHPSShovel.SPEC_TABLE_NAME].backpack
end

function HandToolHPSShovel:getSaplingPalletInRange()
    local carryingPlayer = self:getCarryingPlayer()

    if carryingPlayer ~= nil and carryingPlayer.isOwner then
        local hudUpdater = carryingPlayer.hudUpdater

        if hudUpdater ~= nil and hudUpdater.isPallet and hudUpdater.object ~= nil then
            local object = hudUpdater.object

            if object.spec_treeSaplingPallet ~= nil and object.getTreeSaplingPalletType ~= nil then
                for fillUnitIndex, fillUnit in pairs(object:getFillUnits()) do
                    if fillUnit.fillType == FillType.TREESAPLINGS and fillUnit.fillLevel > 0 then
                    -- if object:getFillUnitFillType(fillUnitIndex) == FillType.TREESAPLINGS and object:getFillUnitFillLevel(fillUnitIndex) > 0 then
                        return object
                    end
                end
            end
        end
    end

    return nil
end

function HandToolHPSShovel:getSaplingStorageInRange()
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    if g_handPlantSaplingsManager ~= nil then
        return g_handPlantSaplingsManager:getObjectInRange()
    end

    return nil, nil
end

function HandToolHPSShovel.getTargetedLocation(player, offsetX, offsetY, offsetZ)
    local px, py, pz = player:getPosition()
    local dx, dz = player:getCurrentFacingDirection()

    local x, y, z = px + dx * (offsetX or 2), py + (offsetY or 2), pz + dz * (offsetZ or 2)
    local hitObjectId, hitX, hitY, hitZ = RaycastUtil.raycastClosest(px + dx * 2, py + 2, pz + dz * 2, 0, -1, 0, 15, HandToolHPSShovel.COLLISION_MASK)

    if hitObjectId ~= nil then
        return hitObjectId, hitX, hitY, hitZ
    end

    return nil, x, getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.1, z
end

function HandToolHPSShovel:getShowInHandToolsOverview(superFunc)
    return false
end

function HandToolHPSShovel:setHolder(superFunc, holder, noEventSend)
    local spec = self[HandToolHPSShovel.SPEC_TABLE_NAME]

    -- Only allow Players or owning holder to be set no mater what trigger or activatable
    if holder == nil or not holder:isa(Player) then
        if spec.attachedHolder == nil then
            return
        end

        holder = spec.attachedHolder
    end

    spec.plantAnywhereActive = false -- reset plant anywhere when returned to storage or picked up
    spec.plantedTreeCount = 0 -- reset the planted tree counter when returned to storage or picked up

    superFunc(self, holder, noEventSend)
end

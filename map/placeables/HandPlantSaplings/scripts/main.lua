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


HandPlantSaplingsManager = {}
HandPlantSaplingsManager.USE_COLORBLIND_MODE = false

local HandPlantSaplingsManager_mt = Class(HandPlantSaplingsManager, AbstractManager)
local consoleCommandsGtX = StartParams.getIsSet("consoleCommandsGtX")

local modName = g_currentModName
local modDirectory = g_currentModDirectory

local versionString = "0.0.0.0"
local buildId = 1

local validationFail

function HandPlantSaplingsManager.new(customMt)
	local self = AbstractManager.new(customMt or HandPlantSaplingsManager_mt)

	self.modName = modName
	self.modDirectory = modDirectory

	self.versionString = versionString
	self.buildId = buildId

	return self
end

function HandPlantSaplingsManager:initDataStructures()
	self.treeTypes = {}
	self.treeTypeTitles = {}

	self.avoidTreeTypeNames = {
		DEADWOOD = true,
		TRANSPORT = true,
		RAVAGED = true
	}

	self.pendingCloneRequests = {}
	self.objectsInRange = {}

	self.defaultTitle = ""
	self.treePlantManager = g_treePlantManager

	self.debugEnabled = buildId < 1
	self.showSharedData = false
end

function HandPlantSaplingsManager:loadMapData(xmlFile, missionInfo, baseDirectory)
	HandPlantSaplingsManager:superClass().loadMapData(self)

	self.defaultTitle = g_i18n:getText("category_palletForestry")
	self.backupFilename = Utils.getFilename("$data/maps/trees/saplings/dummy/treeSapling02.i3d")

	if not fileExists(self.backupFilename) then
		self.backupFilename = nil

		Logging.info("Base game files have changed, backup tree sapling with path '%s' no longer exists!")
	end

	for _, treeTypeDesc in ipairs (self.treePlantManager.treeTypes) do
		if not self.avoidTreeTypeNames[treeTypeDesc.name] then
			local stage = treeTypeDesc.stages[1]

			if stage ~= nil then
				local defaultUsed, risutecUsed = false, false

				for variationIndex, variation in ipairs (stage) do
					local treeType = {
						key = HandPlantSaplingsManager.getTreeTypeKey(treeTypeDesc.index, variationIndex),
						name = treeTypeDesc.name,
						variationName = variation.name,
						typeIndex = treeTypeDesc.index,
						variationIndex = variationIndex,
						filename = variation.filename or self.backupFilename,
						sharedLoadRequestId = nil,
						sharedShape = nil
					}

					if treeType.variationName == "DEFAULT" and not defaultUsed then
						treeType.title = treeTypeDesc.title
						defaultUsed = true
					elseif treeType.variationName == "RISUTECSKB240" and not risutecUsed then
						treeType.title = string.format("%s (%s)", treeTypeDesc.title, g_i18n:getText("configuration_valueSmall"))
						risutecUsed = true
					else
						treeType.title = string.format("%s (%d)", treeTypeDesc.title, variationIndex)
					end

					self.treeTypes[treeType.key] = treeType
					self.treeTypeTitles[treeType.key] = treeType.title
				end
			end
		elseif self.debugEnabled then
			Logging.devInfo("[HandPlantSaplingsManager] Ignoring tree type with name '%s'", treeTypeDesc.name)
		end
	end

	if consoleCommandsGtX then
		addConsoleCommand("gtxHandPlantSaplingsDebug", "Toggles HPS debug", "consoleCommandDebug", self)
		addConsoleCommand("gtxHandPlantSaplingsShowSharedData", "Shows all shared data ", "consoleCommandShowSharedData", self)
		addConsoleCommand("gtxHandPlantSaplingsClearSharedData", "Clears shared sapling shapes and all releases relevant I3D files", "consoleCommandClearSharedData", self, "verbose[default=false]")
	end

	HandPlantSaplingsManager.USE_COLORBLIND_MODE = Utils.getNoNil(g_gameSettings:getValue(GameSettings.SETTING.USE_COLORBLIND_MODE), false)
	g_messageCenter:subscribe(MessageType.SETTING_CHANGED[GameSettings.SETTING.USE_COLORBLIND_MODE], self.onColorBlindModeChanged, self)

	return true
end

function HandPlantSaplingsManager:unloadMapData()
	g_messageCenter:unsubscribeAll(self)

	if consoleCommandsGtX then
		removeConsoleCommand("gtxHandPlantSaplingsDebug")
		removeConsoleCommand("gtxHandPlantSaplingsShowSharedData")
		removeConsoleCommand("gtxHandPlantSaplingsClearSharedData")
	end

	self:clearSharedData(self.debugEnabled)

	HandPlantSaplingsManager:superClass().unloadMapData(self)
end

function HandPlantSaplingsManager:cloneSharedSapling(treeTypeKey, saplingNode, callback, target, arguments)
	local treeType = self.treeTypes[treeTypeKey]

	if treeType ~= nil and callback ~= nil then
		if treeType.sharedShape == nil then
			if self.pendingCloneRequests[treeTypeKey] == nil then
				self.pendingCloneRequests[treeTypeKey] = {}

				if treeType.sharedLoadRequestId ~= nil then
					g_i3DManager:releaseSharedI3DFile(treeType.sharedLoadRequestId)
					treeType.sharedLoadRequestId = nil
				end

				treeType.sharedLoadRequestId = g_i3DManager:loadSharedI3DFileAsync(treeType.filename, false, false, self.onSharedSaplingLoaded, self, treeType)
			end

			table.insert(self.pendingCloneRequests[treeTypeKey], {
				saplingNode = saplingNode,
				callback = callback,
				target = target,
				args = arguments
			})

			if self.debugEnabled then
				Logging.devInfo("Added shared sapling '%s' clone request to queue at index %d.", treeTypeKey, #self.pendingCloneRequests[treeTypeKey])
			end

			return true -- isQueued
		end

		local sharedShape = clone(treeType.sharedShape, false, false, false)

		if target ~= nil then
			callback(target, saplingNode, sharedShape, treeType.key, arguments)
		else
			callback(saplingNode, sharedShape, treeType.key, arguments)
		end
	end

	return false
end

function HandPlantSaplingsManager:onSharedSaplingLoaded(i3dNode, failedReason, treeType)
	if i3dNode ~= 0 then
		if treeType ~= nil then
			if treeType.sharedShape == nil then
				treeType.sharedShape = clone(getChildAt(i3dNode, 0), false, false, false)
			end

			local treeTypeKey = treeType.key
			local pendingRequests = self.pendingCloneRequests[treeTypeKey]

			if pendingRequests ~= nil then
				for _, request in ipairs (pendingRequests) do
					if request.sharedShape == nil then
						request.sharedShape = clone(treeType.sharedShape, false, false, false)

						if request.target ~= nil then
							request.callback(request.target, request.saplingNode, request.sharedShape, treeTypeKey, request.arguments)
						else
							request.callback(request.saplingNode, request.sharedShape, treeTypeKey, request.arguments)
						end
					end
				end

				self.pendingCloneRequests[treeTypeKey] = nil

				if self.debugEnabled then
					Logging.devInfo("Shared sapling '%s' clone requests complete.", treeTypeKey)
				end
			end
		end

		delete(i3dNode)
	end
end

function HandPlantSaplingsManager:onColorBlindModeChanged(useColourBlindMode)
	HandPlantSaplingsManager.USE_COLORBLIND_MODE = Utils.getNoNil(useColourBlindMode, false)
end

function HandPlantSaplingsManager:drawDebug()
	if self.showSharedData then
		setTextColor(1, 1, 1, 1)
		setTextBold(true)

		local numSaplingTypes = 0
		local sortedTreeTypes = {}

		for _, treeType in pairs(self.treeTypes) do
			if treeType.sharedShape ~= nil then
				table.insert(sortedTreeTypes, treeType)
			end

			numSaplingTypes += 1
		end

		local avoidTreeTypeNames = nil

		for treeTypeName in pairs (self.avoidTreeTypeNames) do
			if avoidTreeTypeNames == nil then
				avoidTreeTypeNames = treeTypeName
			else
				avoidTreeTypeNames = avoidTreeTypeNames .. ", " .. treeTypeName
			end
		end

		renderText(0.02, 0.7, 0.015, "Hand Plant Saplings Manager")
		setTextBold(false)

		renderText(0.02, 0.68, 0.015, string.format(" numSaplingTypes: %d", numSaplingTypes))
		renderText(0.02, 0.66, 0.015, string.format(" avoidTreeTypeNames: %s", avoidTreeTypeNames))
		renderText(0.02, 0.64, 0.015, string.format(" numSharedShapes: %d", #sortedTreeTypes))

		local index = 0

		for _, treeType in ipairs(sortedTreeTypes) do
			renderText(0.02, 0.62 - index * 0.02, 0.015, string.format("    Sapling: %s (key: %s,  sharedShape: %s,  sharedLoadRequestId: %s,  filename: %s)", treeType.name, treeType.key, tostring(treeType.sharedShape or -1), tostring(treeType.sharedLoadRequestId or -1), treeType.filename))
			index += 1
		end
	end
end

function HandPlantSaplingsManager:clearSharedData(verbose)
	if verbose then
		Logging.devInfo("[HandPlantSaplingsManager] Clearing all shared data...")
	end

	for _, treeType in pairs(self.treeTypes) do
		if treeType.sharedLoadRequestId ~= nil then
			if verbose then
				Logging.devInfo("    Releasing I3D File:  Load Request - %s  |  Key - %s  |  Name - %s  |  Filename - %s", treeType.sharedLoadRequestId, treeType.key, treeType.name, tostring(treeType.filename))
			end

			g_i3DManager:releaseSharedI3DFile(treeType.sharedLoadRequestId, verbose)
			treeType.sharedLoadRequestId = nil
		end

		if treeType.sharedShape ~= nil then
			if verbose then
				Logging.devInfo("    Deleting Shape:  ID - %s  |  Key - %s  |  Name - %s", tostring(treeType.sharedShape), treeType.key, treeType.name)
			end

			delete(treeType.sharedShape)
			treeType.sharedShape = nil
		end
	end
end

function HandPlantSaplingsManager:addAvoidTreeTypeName(treeTypeName)
	if treeTypeName ~= nil and type(treeTypeName) == "string" then
		self.avoidTreeTypeNames[treeTypeName:upper()] = true

		return true
	end

	return false
end

function HandPlantSaplingsManager:addObjectInRange(activatable, object)
	if activatable ~= nil and self.objectsInRange[activatable] == nil then
		self.objectsInRange[activatable] = object
	end

	self.hasObjectsInRange = next(self.objectsInRange) ~= nil
end

function HandPlantSaplingsManager:removeObjectInRange(activatable, object)
	if activatable ~= nil then
		if self.objectsInRange[activatable] ~= nil then
			self.objectsInRange[activatable] = nil
		end
	elseif object ~= nil then
		for activatable, objectInRange in pairs (self.objectsInRange) do
			if objectInRange == object then
				self.objectsInRange[activatable] = nil
			end
		end
	end

	self.hasObjectsInRange = next(self.objectsInRange) ~= nil
end

function HandPlantSaplingsManager:getObjectInRange()
	if self.hasObjectsInRange then
		local activatableObjectsSystem = g_currentMission.activatableObjectsSystem
		local activatable = activatableObjectsSystem:getActivatable()

		if activatable == nil then
			local posX, posY, posZ = activatableObjectsSystem.posX, activatableObjectsSystem.posY, activatableObjectsSystem.posZ

			if posX ~= nil and activatableObjectsSystem.objects ~= nil then
				local nearestDistance = math.huge
				local farmId = g_localPlayer.farmId

				for _, object in pairs(activatableObjectsSystem.objects) do
					local objectInRange = self.objectsInRange[object]

					if objectInRange ~= nil and objectInRange:getOwnerFarmId() == farmId then
						local distance = nearestDistance

						if object.getDistance ~= nil then
							distance = object:getDistance(posX, posY, posZ)
						end

						if activatable == nil or distance < nearestDistance then
							activatable = object
							nearestDistance = distance
						end
					end
				end
			end
		end

		if activatable ~= nil then
			local objectInRange = self.objectsInRange[activatable]

			if objectInRange ~= nil and objectInRange.getSaplingStorage ~= nil then
				return objectInRange:getSaplingStorage(), objectInRange
			end
		end
	end

	return nil, nil
end

function HandPlantSaplingsManager:getTreeType(typeIndex, variationIndex, treeTypeKey)
	if treeTypeKey == nil then
		treeTypeKey = HandPlantSaplingsManager.getTreeTypeKey(typeIndex, variationIndex)
	end

	return self.treeTypes[treeTypeKey]
end

function HandPlantSaplingsManager:getTreeTypeTitle(typeIndex, variationIndex, treeTypeKey)
	if treeTypeKey == nil then
		treeTypeKey = HandPlantSaplingsManager.getTreeTypeKey(typeIndex, variationIndex)
	end

	return self.treeTypeTitles[treeTypeKey] or self.defaultTitle
end

function HandPlantSaplingsManager.getTreeTypeKey(typeIndex, variationIndex)
	return (tonumber(typeIndex) or 0) .. "_" .. (tonumber(variationIndex) or 1)
end

function HandPlantSaplingsManager:getTreeTypeIndexAndVariationIndex(treeTypeKey)
	local treeType = self.treeTypes[treeTypeKey]

	if treeType ~= nil then
		return treeType.typeIndex, treeType.variationIndex
	end

	return 0, 1
end

function HandPlantSaplingsManager:getTreeTypeNameAndVariationName(treeTypeKey)
	local treeType = self.treeTypes[treeTypeKey]

	if treeType ~= nil then
		return treeType.name, treeType.variationName
	end

	return nil, nil
end

function HandPlantSaplingsManager:getTreeTypes()
	return self.treeTypes
end

function HandPlantSaplingsManager:consoleCommandDebug()
	self.debugEnabled = not self.debugEnabled

	return "Debug enabled: " .. tostring(self.debugEnabled)
end

function HandPlantSaplingsManager:consoleCommandShowSharedData()
	self.showSharedData = not self.showSharedData

	if g_debugManager ~= nil then
		if self.showSharedData then
			g_debugManager:addDrawable(self)
		else
			g_debugManager:removeDrawable(self)
		end
	end

	return "Show shared data: " .. tostring(self.showSharedData)
end

function HandPlantSaplingsManager:consoleCommandClearSharedData(verbose)
	self:clearSharedData(Utils.stringToBoolean(verbose))

	return "Cleared shared data"
end

local function validateMod()
	addModEventListener(HandPlantSaplingsManager)
	return true
end

local function treePlantManagerLoadMapData(self, superFunc, xmlFile, missionInfo, baseDirectory)
	local success = superFunc(self, xmlFile, missionInfo, baseDirectory)

	if success and g_handPlantSaplingsManager ~= nil then
		g_handPlantSaplingsManager:loadMapData(xmlFile, missionInfo, baseDirectory)
	end

	return success
end

local function treePlantManagerUnloadMapData(self)
	if g_handPlantSaplingsManager ~= nil then
		g_handPlantSaplingsManager:unloadMapData()
	end

	if g_globalMods ~= nil then
		g_globalMods.handPlantSaplingsManager = nil
	end

	g_handPlantSaplingsManager = nil
end

local function init()
	if g_globalMods == nil then
		g_globalMods = {}
	end

	if g_globalMods.handPlantSaplingsManager then
		Logging.error("Failed to load mod '%s', 'HandPlantSaplingsManager' was already loaded by '%s'!", modName, g_globalMods.handPlantSaplingsManager.modName or "N/A")

		return
	end

	source(modDirectory .. "map/placeables/HandPlantSaplings/scripts/misc/HandPlantSaplingsStorage.lua")
	source(modDirectory .. "map/placeables/HandPlantSaplings/scripts/misc/HandToolHPSShovelState.lua")

	source(modDirectory .. "map/placeables/HandPlantSaplings/scripts/events/HandToolHPSShovelInteractEvent.lua")
	source(modDirectory .. "map/placeables/HandPlantSaplings/scripts/events/HandToolHPSShovelPlantEvent.lua")

	g_handPlantSaplingsManager = HandPlantSaplingsManager.new()
	g_globalMods.handPlantSaplingsManager = g_handPlantSaplingsManager

	TreePlantManager.loadMapData = Utils.overwrittenFunction(TreePlantManager.loadMapData, treePlantManagerLoadMapData)
	TreePlantManager.unloadMapData = Utils.appendedFunction(TreePlantManager.unloadMapData, treePlantManagerUnloadMapData)
end

init()

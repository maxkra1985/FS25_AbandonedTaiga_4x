-- FS25_DynamicRoadMap
-- Adds player-painted asphalt/gravel roads to the in-game overview/minimap.
--
-- v. 1.0.0.4 architecture:
--   * The base map is left completely untouched.
--   * Existing-road import is prepared automatically in the background after load.
--   * Only terrain areas modified through Landscaping PAINT are recorded.
--   * The road mask is persisted per savegame (dynamicRoadMap.grle).
--   * A dedicated "Roads" map section controls asphalt/gravel/legacy-import visibility.
--   * Legacy import scans pre-existing asphalt/gravel into a separate mask value.

DynamicRoadMap = {}

DynamicRoadMap.MOD_NAME = g_currentModName or "FS25_DynamicRoadMap"
DynamicRoadMap.LOG_PREFIX = "[DynamicRoadMap]"
DynamicRoadMap.DATA_VERSION = 8
DynamicRoadMap.LEGACY_IMPORT_VERSION = 4

-- One mask pixel represents roughly one world metre on normal/4x maps.
-- 2048 m -> 2048 px, 4096 m -> 4096 px. Larger maps are capped at 4096.
DynamicRoadMap.METRES_PER_MASK_PIXEL = 1
DynamicRoadMap.MIN_MASK_RESOLUTION = 1024
DynamicRoadMap.MAX_MASK_RESOLUTION = 4096

-- Full-map scanning is used only for legacy/imported roads. New Landscaping
-- paints are written directly from the engine's modifiedAreas.
DynamicRoadMap.SCAN_CELLS_PER_FRAME = 8192
DynamicRoadMap.ROAD_WEIGHT_THRESHOLD = 0.15
DynamicRoadMap.DIRTY_RESCAN_DELAY_MS = 500
DynamicRoadMap.PAINT_BATCH_TIMEOUT_MS = 750
DynamicRoadMap.MAX_PAINT_AREAS_PER_EVENT = 4096
DynamicRoadMap.DIRTY_MARGIN_METRES = 2
DynamicRoadMap.LEGACY_IMPORT_STEP = 2
DynamicRoadMap.LEGACY_CONTINUITY_OFFSET_METRES = 3

DynamicRoadMap.ROAD_VALUE_NONE = 0
DynamicRoadMap.ROAD_VALUE_ASPHALT = 1
DynamicRoadMap.ROAD_VALUE_GRAVEL = 2
-- Value 3 may still exist in old v0.4-v0.7 player masks. v0.8 ignores it.
DynamicRoadMap.ROAD_VALUE_OLD_IMPORTED = 3
DynamicRoadMap.ROAD_NUM_CHANNELS = 2

-- Legacy/imported roads are now stored separately so imported asphalt and
-- imported gravel retain their own map colors.
DynamicRoadMap.LEGACY_VALUE_NONE = 0
DynamicRoadMap.LEGACY_VALUE_ASPHALT = 1
DynamicRoadMap.LEGACY_VALUE_GRAVEL = 2
DynamicRoadMap.LEGACY_NUM_CHANNELS = 2

-- Map/UI colors.
-- GIANTS GUI/density-overlay color inputs are linear RGB. These values are the
-- sRGB->linear conversions of the exact requested on-screen colors:
--   asphalt: RGB 148,142,141 (#948E8D)
--   gravel : RGB 148,134,107 (#94866B)
DynamicRoadMap.ASPHALT_COLOR = {0.2961382708, 0.2704977910, 0.2663556048}
DynamicRoadMap.GRAVEL_COLOR = {0.2961382708, 0.2383975738, 0.1470272665}
DynamicRoadMap.OVERLAY_ALPHA = 1.0

DynamicRoadMap.showAsphalt = true
DynamicRoadMap.showGravel = true
DynamicRoadMap.showImported = false
DynamicRoadMap.legacyImportCompleted = false
DynamicRoadMap.legacyImportRequested = false
DynamicRoadMap.legacyImportVersion = 0
DynamicRoadMap.settingsLoaded = false
DynamicRoadMap.mapMenuHooksInstalled = false
DynamicRoadMap.mapMenuConstantsShifted = false
DynamicRoadMap.savegameHookInstalled = false

-- -------------------------------------------------------------------------
-- Сетевые события
-- -------------------------------------------------------------------------

-- Клиент использует это событие только как запрос актуального состояния.
-- Сканирование и формирование дорожных масок всегда остаются на сервере.
DynamicRoadMapSyncRequestEvent = {}
local DynamicRoadMapSyncRequestEvent_mt = Class(DynamicRoadMapSyncRequestEvent, Event)
InitEventClass(DynamicRoadMapSyncRequestEvent, "DynamicRoadMapSyncRequestEvent")

function DynamicRoadMapSyncRequestEvent.emptyNew()
	return Event.new(DynamicRoadMapSyncRequestEvent_mt)
end

function DynamicRoadMapSyncRequestEvent.new()
	return DynamicRoadMapSyncRequestEvent.emptyNew()
end

function DynamicRoadMapSyncRequestEvent:writeStream(streamId, connection)
end

function DynamicRoadMapSyncRequestEvent:readStream(streamId, connection)
	self:run(connection)
end

--- Обрабатывает запрос клиента на серверной стороне.
function DynamicRoadMapSyncRequestEvent:run(connection)
	if connection ~= nil and not connection:getIsServer() then
		DynamicRoadMap:onNetworkSyncRequest(connection)
	end
end

-- Полная синхронизация использует штатную сериализацию InfoLayer/BitVectorMap.
-- Незавершённая legacy-маска не передаётся: клиент получает её только после
-- окончания серверного сканирования.
DynamicRoadMapFullSyncEvent = {}
local DynamicRoadMapFullSyncEvent_mt = Class(DynamicRoadMapFullSyncEvent, Event)
InitEventClass(DynamicRoadMapFullSyncEvent, "DynamicRoadMapFullSyncEvent")

function DynamicRoadMapFullSyncEvent.emptyNew()
	return Event.new(DynamicRoadMapFullSyncEvent_mt)
end

function DynamicRoadMapFullSyncEvent.new(roadInfoLayer, legacyInfoLayer, legacyReady, maskResolution, legacyImportVersion, revision)
	local self = DynamicRoadMapFullSyncEvent.emptyNew()
	self.roadInfoLayer = roadInfoLayer
	self.legacyInfoLayer = legacyInfoLayer
	self.legacyReady = legacyReady == true
	self.maskResolution = maskResolution
	self.legacyImportVersion = legacyImportVersion or 0
	self.revision = revision or 0
	return self
end

function DynamicRoadMapFullSyncEvent:writeStream(streamId, connection)
	streamWriteUIntN(streamId, DynamicRoadMap.DATA_VERSION, 8)
	streamWriteUIntN(streamId, self.maskResolution or 0, 13)
	streamWriteBool(streamId, self.legacyReady)
	streamWriteUIntN(streamId, self.legacyImportVersion or 0, 8)
	streamWriteUIntN(streamId, self.revision or 0, 24)

	self.roadInfoLayer:writeStream(streamId, connection)
	if self.legacyReady and self.legacyInfoLayer ~= nil then
		self.legacyInfoLayer:writeStream(streamId, connection)
	end
end

function DynamicRoadMapFullSyncEvent:readStream(streamId, connection)
	self.dataVersion = streamReadUIntN(streamId, 8)
	self.maskResolution = streamReadUIntN(streamId, 13)
	self.legacyReady = streamReadBool(streamId)
	self.legacyImportVersion = streamReadUIntN(streamId, 8)
	self.revision = streamReadUIntN(streamId, 24)

	self.roadInfoLayer = InfoLayer.new("dynamicRoadMapNetworkRoad", "")
	self.roadInfoLayer:create(
		self.maskResolution,
		self.maskResolution,
		DynamicRoadMap.ROAD_NUM_CHANNELS,
		false
	)
	self.roadInfoLayer:readStream(streamId, connection)

	if self.legacyReady then
		self.legacyInfoLayer = InfoLayer.new("dynamicRoadMapNetworkLegacy", "")
		self.legacyInfoLayer:create(
			self.maskResolution,
			self.maskResolution,
			DynamicRoadMap.LEGACY_NUM_CHANNELS,
			false
		)
		self.legacyInfoLayer:readStream(streamId, connection)
	end

	self:run(connection)
end

--- Устанавливает на клиенте уже готовые серверные дорожные маски.
function DynamicRoadMapFullSyncEvent:run(connection)
	if connection ~= nil and connection:getIsServer() then
		DynamicRoadMap:applyNetworkFullSync(self)
	end
end

-- Инкрементальная синхронизация новых покрасок. Передаются именно
-- modifiedAreas, которые серверный Landscaping уже подтвердил и применил.
DynamicRoadMapPaintEvent = {}
local DynamicRoadMapPaintEvent_mt = Class(DynamicRoadMapPaintEvent, Event)
InitEventClass(DynamicRoadMapPaintEvent, "DynamicRoadMapPaintEvent")

function DynamicRoadMapPaintEvent.emptyNew()
	-- Дельты дорожной маски относятся к тому же типу трафика, что и штатная
	-- деформация terrain. Выделенный канал не блокируется большой full-sync маской.
	return Event.new(DynamicRoadMapPaintEvent_mt, NetworkNode.CHANNEL_TERRAIN_DEFORMATION)
end

function DynamicRoadMapPaintEvent.new(areas, roadValue, revision, clearLegacy)
	local self = DynamicRoadMapPaintEvent.emptyNew()
	self.areas = areas or {}
	self.roadValue = roadValue or DynamicRoadMap.ROAD_VALUE_NONE
	self.revision = revision or 0
	self.clearLegacy = clearLegacy == true
	return self
end

function DynamicRoadMapPaintEvent:writeStream(streamId, connection)
	local count = math.min(#self.areas, 65535)
	streamWriteUIntN(streamId, self.roadValue, DynamicRoadMap.ROAD_NUM_CHANNELS)
	streamWriteUIntN(streamId, self.revision or 0, 24)
	streamWriteBool(streamId, self.clearLegacy == true)
	streamWriteUIntN(streamId, count, 16)

	for i = 1, count do
		local area = self.areas[i]
		for j = 1, 6 do
			streamWriteFloat32(streamId, area[j] or 0)
		end
	end
end

function DynamicRoadMapPaintEvent:readStream(streamId, connection)
	self.roadValue = streamReadUIntN(streamId, DynamicRoadMap.ROAD_NUM_CHANNELS)
	self.revision = streamReadUIntN(streamId, 24)
	self.clearLegacy = streamReadBool(streamId)
	local count = streamReadUIntN(streamId, 16)
	self.areas = {}

	for i = 1, count do
		self.areas[i] = {
			streamReadFloat32(streamId),
			streamReadFloat32(streamId),
			streamReadFloat32(streamId),
			streamReadFloat32(streamId),
			streamReadFloat32(streamId),
			streamReadFloat32(streamId)
		}
	end

	self:run(connection)
end

--- Применяет подтверждённую сервером покраску только к клиентской маске.
function DynamicRoadMapPaintEvent:run(connection)
	if connection ~= nil and connection:getIsServer() then
		DynamicRoadMap:applyNetworkPaintAreas(self.areas, self.roadValue, self.revision, self.clearLegacy)
	end
end

-- Клиент посылает это событие один раз при отпускании кнопки покраски.
-- Сервер к этому моменту уже применил все LandscapingSculptEvent и накопил
-- соответствующие modifiedAreas, поэтому в обратную сторону передаётся только
-- короткий сигнал завершения мазка.
DynamicRoadMapPaintCommitEvent = {}
local DynamicRoadMapPaintCommitEvent_mt = Class(DynamicRoadMapPaintCommitEvent, Event)
InitEventClass(DynamicRoadMapPaintCommitEvent, "DynamicRoadMapPaintCommitEvent")

function DynamicRoadMapPaintCommitEvent.emptyNew()
	return Event.new(DynamicRoadMapPaintCommitEvent_mt, NetworkNode.CHANNEL_TERRAIN_DEFORMATION)
end

function DynamicRoadMapPaintCommitEvent.new()
	return DynamicRoadMapPaintCommitEvent.emptyNew()
end

function DynamicRoadMapPaintCommitEvent:writeStream(streamId, connection)
end

function DynamicRoadMapPaintCommitEvent:readStream(streamId, connection)
	self:run(connection)
end

--- Завершает накопленную сервером пачку покраски конкретного клиента.
function DynamicRoadMapPaintCommitEvent:run(connection)
	if connection ~= nil and not connection:getIsServer() then
		DynamicRoadMap:onNetworkPaintCommit(connection)
	end
end

function DynamicRoadMap:log(message, ...)
	if select("#", ...) > 0 then
		print(string.format("%s %s", self.LOG_PREFIX, string.format(message, ...)))
	else
		print(string.format("%s %s", self.LOG_PREFIX, tostring(message)))
	end
end

--- Возвращает true только для сервера, listen-server или одиночной игры.
function DynamicRoadMap:getIsServer()
	return g_currentMission ~= nil
		and g_currentMission.getIsServer ~= nil
		and g_currentMission:getIsServer()
end

function DynamicRoadMap:getLocalizedText(id)
	local ru = g_languageShort == "ru"

	if id == "roads" then
		return ru and "ДОРОГИ" or "ROADS"
	elseif id == "asphalt" then
		return ru and "Асфальтовые дороги" or "Asphalt roads"
	elseif id == "gravel" then
		return ru and "Гравийные дороги" or "Gravel roads"
	elseif id == "imported" then
		return ru and "Старые дороги (импорт)" or "Imported old roads"
	elseif id == "scanWait" then
		return ru
			and "Дождитесь окончания сканирования гравия и асфальта на карте"
			or "Please wait until gravel and asphalt scanning on the map is complete"
	elseif id == "scanProgress" then
		return ru and "Сканирование: %d%%" or "Scanning: %d%%"
	end

	return tostring(id)
end

function DynamicRoadMap:getSavegameDirectory()
	if g_currentMission ~= nil
		and g_currentMission.missionInfo ~= nil
		and g_currentMission.missionInfo.isValid
		and g_currentMission.missionInfo.savegameDirectory ~= nil then
		return g_currentMission.missionInfo.savegameDirectory
	end

	return nil
end

function DynamicRoadMap:getMaskFilename()
	local dir = self:getSavegameDirectory()
	return dir ~= nil and (dir .. "/dynamicRoadMap.grle") or nil
end

function DynamicRoadMap:getLegacyMaskFilename()
	local dir = self:getSavegameDirectory()
	return dir ~= nil and (dir .. "/dynamicRoadMapLegacy.grle") or nil
end

function DynamicRoadMap:getSettingsFilename()
	local dir = self:getSavegameDirectory()
	return dir ~= nil and (dir .. "/dynamicRoadMap.xml") or nil
end

function DynamicRoadMap:loadSettings()
	if self.settingsLoaded then
		return
	end

	self.settingsLoaded = true
	local filename = self:getSettingsFilename()

	if filename ~= nil and fileExists(filename) then
		local xml = loadXMLFile("dynamicRoadMapSettings", filename)
		if xml ~= nil and xml ~= 0 then
			local asphalt = getXMLBool(xml, "dynamicRoadMap.settings#showAsphalt")
			local gravel = getXMLBool(xml, "dynamicRoadMap.settings#showGravel")
			local imported = getXMLBool(xml, "dynamicRoadMap.settings#showImported")
			local legacyImportCompleted = nil
			local legacyImportVersion = nil

			-- Состояние импорта является серверным. Клиент может читать только
			-- локальные настройки видимости, но не решать, нужен ли ему скан.
			if self:getIsServer() then
				legacyImportCompleted = getXMLBool(xml, "dynamicRoadMap.import#completed")
				legacyImportVersion = getXMLInt(xml, "dynamicRoadMap.import#version")
			end

			if asphalt ~= nil then
				self.showAsphalt = asphalt
			end
			if gravel ~= nil then
				self.showGravel = gravel
			end
			if imported ~= nil then
				self.showImported = imported
			end
			if legacyImportCompleted ~= nil then
				self.legacyImportCompleted = legacyImportCompleted
			end
			if legacyImportVersion ~= nil then
				self.legacyImportVersion = legacyImportVersion
			end

			delete(xml)
		end
	end

	if self:getIsServer()
		and self.legacyImportCompleted
		and self.legacyImportVersion < self.LEGACY_IMPORT_VERSION then
		self:log(
			"Legacy import algorithm changed (%d -> %d); imported layer will be rebuilt automatically after load",
			self.legacyImportVersion,
			self.LEGACY_IMPORT_VERSION
		)
		self.legacyImportCompleted = false
	end

	self:log(
		"Road filters: asphalt=%s gravel=%s imported=%s legacyImportCompleted=%s",
		tostring(self.showAsphalt),
		tostring(self.showGravel),
		tostring(self.showImported),
		tostring(self.legacyImportCompleted)
	)
end

function DynamicRoadMap:saveSettingsToDirectory(directory)
	if directory == nil then
		return false
	end

	local filename = directory .. "/dynamicRoadMap.xml"
	local xml = createXMLFile("dynamicRoadMapSettings", filename, "dynamicRoadMap")
	if xml ~= nil and xml ~= 0 then
		setXMLInt(xml, "dynamicRoadMap#version", self.DATA_VERSION)
		setXMLBool(xml, "dynamicRoadMap.settings#showAsphalt", self.showAsphalt)
		setXMLBool(xml, "dynamicRoadMap.settings#showGravel", self.showGravel)
		setXMLBool(xml, "dynamicRoadMap.settings#showImported", self.showImported)
		setXMLBool(xml, "dynamicRoadMap.import#completed", self.legacyImportCompleted)
		setXMLInt(xml, "dynamicRoadMap.import#version", self.legacyImportVersion or 0)
		setXMLInt(xml, "dynamicRoadMap.mask#resolution", self.maskResolution or 0)
		saveXMLFile(xml)
		delete(xml)
		return true
	end

	return false
end

function DynamicRoadMap:saveSettings()
	return self:saveSettingsToDirectory(self:getSavegameDirectory())
end

function DynamicRoadMap:saveRoadMaskToDirectory(directory, reason)
	if self.roadInfoLayer == nil or directory == nil then
		return false
	end

	-- FSCareerMissionInfo.saveToXMLFile can also run on a multiplayer client.
	-- Road masks are server-authoritative, so only the server/listen-server
	-- writes the sidecar files into the savegame.
	if g_currentMission ~= nil
		and g_currentMission.getIsServer ~= nil
		and not g_currentMission:getIsServer() then
		return false
	end

	self.roadInfoLayer:saveToFile(directory .. "/dynamicRoadMap.grle")

	if self.legacyInfoLayer ~= nil then
		self.legacyInfoLayer:saveToFile(directory .. "/dynamicRoadMapLegacy.grle")
	end

	self:saveSettingsToDirectory(directory)

	if reason ~= nil then
		self:log("Road masks saved (%s)", tostring(reason))
	else
		self:log("Road masks saved")
	end

	return true
end

function DynamicRoadMap:saveRoadMask()
	return self:saveRoadMaskToDirectory(self:getSavegameDirectory(), nil)
end

function DynamicRoadMap:onSavegameWrite(missionInfo)
	if not self.initialized or self.roadInfoLayer == nil then
		return
	end

	local directory = nil
	if missionInfo ~= nil then
		directory = missionInfo.savegameDirectory
	end
	if directory == nil then
		directory = self:getSavegameDirectory()
	end

	if directory ~= nil then
		self:log("Savegame hook: persisting Dynamic Road Map data")
		self:saveRoadMaskToDirectory(directory, "savegame hook")
	else
		self:log("Savegame hook: savegame directory unavailable; road data was not written")
	end
end

function DynamicRoadMap:installSavegameHook()
	if self.savegameHookInstalled then
		return
	end

	-- FS25 calls FSCareerMissionInfo.saveToXMLFile as part of every career
	-- save. Writing our sidecar files from this hook keeps them inside the
	-- final savegame even when the game rebuilds/cleans the save directory.
	if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
		FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
			FSCareerMissionInfo.saveToXMLFile,
			function(missionInfo, ...)
				DynamicRoadMap:onSavegameWrite(missionInfo)
			end
		)
		self.savegameHookInstalled = true
		self:log("Installed savegame persistence hook on FSCareerMissionInfo.saveToXMLFile")
	end
end

function DynamicRoadMap:loadMap(mapName)
	self.mapName = mapName
	self.initialized = false
	self.roadInfoLayer = nil
	self.legacyInfoLayer = nil
	self.roadOverlay = nil
	self.roadOverlayReady = false
	self.roadOverlayGenerating = false
	self.roadOverlayDirty = false
	self.roadTerrainLayers = {}
	self.roadTerrainLayerValues = {}
	self.roadTerrainLayerEntries = {}
	self.loggedPaintLayers = {}
	self.playerMaskChanged = false
	self.playerMaskCommitTimer = 0
	self.currentScan = nil
	self.pendingDirtyBounds = nil
	self.pendingDirtyTimer = 0
	self.settingsLoaded = false
	self.showImported = false
	self.legacyImportCompleted = false
	self.legacyImportRequested = false
	self.legacyImportVersion = 0
	self.networkSyncRequested = false
	self.networkSyncReceived = false
	self.networkLegacyReady = false
	self.networkRevision = 0
	self.pendingNetworkPaintEvents = {}
	self.pendingServerPaintBatches = {}

	self:installMapMenuHooks()
	self:installHooks()

	self:log("============================================================")
	self:log("Dynamic Road Map v1.0.0.4 loaded")
	self:log("Map: %s", tostring(mapName))
	self:log("Mode: player Landscaping roads + background legacy terrain import")
	self:log("============================================================")
end

function DynamicRoadMap:deleteMap()
	if self.roadOverlay ~= nil then
		delete(self.roadOverlay)
		self.roadOverlay = nil
	end

	if self.roadInfoLayer ~= nil then
		self.roadInfoLayer:delete()
		self.roadInfoLayer = nil
	end

	if self.legacyInfoLayer ~= nil then
		self.legacyInfoLayer:delete()
		self.legacyInfoLayer = nil
	end

	self.initialized = false
	self.currentScan = nil
	self.pendingDirtyBounds = nil
	self.playerMaskChanged = false
	self.playerMaskCommitTimer = 0
	self.loggedPaintLayers = {}
	self.roadTerrainLayers = {}
	self.roadTerrainLayerValues = {}
	self.roadTerrainLayerEntries = {}
	self.networkSyncRequested = false
	self.networkSyncReceived = false
	self.networkLegacyReady = false
	self.networkRevision = 0
	self.pendingNetworkPaintEvents = {}
	self.pendingServerPaintBatches = {}
end

function DynamicRoadMap:installHooks()
	self:installSavegameHook()

	if not self.ingameMapHookInstalled and IngameMap ~= nil and IngameMap.drawFields ~= nil then
		IngameMap.drawFields = Utils.appendedFunction(IngameMap.drawFields, function(ingameMap)
			DynamicRoadMap:drawRoadOverlay(ingameMap)
		end)
		self.ingameMapHookInstalled = true
		self:log("Installed IngameMap overlay hook")
	end

	-- Захватываем реальный terrain layer в той же функции GIANTS, которая
	-- настраивает PAINT и формирует modifiedAreas. Это работает одинаково
	-- для действий хоста и для LandscapingSculptEvent, пришедшего от клиента.
	if not self.landscapingAssignPaintHookInstalled
		and Landscaping ~= nil
		and Landscaping.assignPaintingParameters ~= nil then
		local oldAssignPaintingParameters = Landscaping.assignPaintingParameters
		Landscaping.assignPaintingParameters = function(landscaping, deform, x, z, radius, brushShape, layerIndex)
			if DynamicRoadMap:getIsServer() then
				landscaping.dynamicRoadMapTerrainPaintingLayer = layerIndex
			end

			return oldAssignPaintingParameters(landscaping, deform, x, z, radius, brushShape, layerIndex)
		end
		self.landscapingAssignPaintHookInstalled = true
		self:log("Installed Landscaping paint-parameter capture hook")
	end

	-- Резервный захват слоя на входе sculpt(). Основным источником является
	-- assignPaintingParameters(), но этот хук оставляем для совместимости.
	if not self.landscapingSculptHookInstalled and Landscaping ~= nil and Landscaping.sculpt ~= nil then
		local oldSculpt = Landscaping.sculpt
		Landscaping.sculpt = function(
			landscaping, x, y, z, nx, ny, nz, d, minY, maxY, radius, strength,
			brushShape, operation, smoothingDistance, terrainPaintingLayer,
			terrainFoliageLayer, terrainFoliageValue
		)
			if operation == Landscaping.OPERATION.PAINT and DynamicRoadMap:getIsServer() then
				landscaping.dynamicRoadMapTerrainPaintingLayer = terrainPaintingLayer
			end

			return oldSculpt(
				landscaping, x, y, z, nx, ny, nz, d, minY, maxY, radius, strength,
				brushShape, operation, smoothingDistance, terrainPaintingLayer,
				terrainFoliageLayer, terrainFoliageValue
			)
		end
		self.landscapingSculptHookInstalled = true
		self:log("Installed Landscaping terrain-paint layer capture hook")
	end

	if not self.landscapingHookInstalled and Landscaping ~= nil and Landscaping.onSculptingApplied ~= nil then
		Landscaping.onSculptingApplied = Utils.appendedFunction(
			Landscaping.onSculptingApplied,
			function(landscaping, errorCode, displacedVolumeOrArea, unused)
				DynamicRoadMap:onLandscapingApplied(landscaping, errorCode)
			end
		)
		self.landscapingHookInstalled = true
		self:log("Installed Landscaping paint hook")
	end

	-- В штатной ConstructionBrushPaint отпускание кнопки лишь сбрасывает lastX.
	-- Отдельного сетевого события об окончании мазка GIANTS не отправляет, поэтому
	-- добавляем собственный короткий commit после завершения исходной обработки.
	if not self.constructionBrushPaintHookInstalled
		and ConstructionBrushPaint ~= nil
		and ConstructionBrushPaint.onButtonPrimary ~= nil then
		ConstructionBrushPaint.onButtonPrimary = Utils.appendedFunction(
			ConstructionBrushPaint.onButtonPrimary,
			function(brush, isDown, isDrag, isUp)
				if isUp then
					DynamicRoadMap:onPaintBrushReleased()
				end
			end
		)
		self.constructionBrushPaintHookInstalled = true
		self:log("Installed ConstructionBrushPaint release hook")
	end
end

-- -------------------------------------------------------------------------
-- Dedicated "Roads" section in the map overview selector
-- -------------------------------------------------------------------------

-- Important: Roads is inserted BEFORE HOTSPOTS, not after it.
-- InGameMenuMapFrame treats all selector states <= MAP_HOTSPOTS as normal
-- filter-list pages and refreshes filterList automatically in its own
-- onClickMapOverviewSelector(). Putting Roads in this range means we can use
-- the stock dataTables/filterStates/list lifecycle instead of trying to
-- force-refresh SmoothList from a mod callback.
function DynamicRoadMap:shiftMapMenuConstants()
	if self.mapMenuConstantsShifted or InGameMenuMapFrame == nil then
		return false
	end

	local oldHotspots = InGameMenuMapFrame.MAP_HOTSPOTS
	local oldFarmlands = InGameMenuMapFrame.MAP_FARMLANDS
	local oldCreateJob = InGameMenuMapFrame.AI_CREATE_JOB
	local oldWorkerList = InGameMenuMapFrame.AI_WORKER_LIST

	InGameMenuMapFrame.MAP_ROADS = oldHotspots
	InGameMenuMapFrame.MAP_HOTSPOTS = oldHotspots + 1
	InGameMenuMapFrame.MAP_FARMLANDS = oldFarmlands + 1
	InGameMenuMapFrame.AI_CREATE_JOB = oldCreateJob + 1
	InGameMenuMapFrame.AI_WORKER_LIST = oldWorkerList + 1

	self.MAP_ROADS_STATE = InGameMenuMapFrame.MAP_ROADS
	self.mapMenuConstantsShifted = true

	self:log(
		"Map selector states extended in native filter range: ROADS=%d HOTSPOTS=%d FARMLANDS=%d CREATE_JOB=%d WORKERS=%d",
		InGameMenuMapFrame.MAP_ROADS,
		InGameMenuMapFrame.MAP_HOTSPOTS,
		InGameMenuMapFrame.MAP_FARMLANDS,
		InGameMenuMapFrame.AI_CREATE_JOB,
		InGameMenuMapFrame.AI_WORKER_LIST
	)

	return true
end

function DynamicRoadMap:getRoadFilterItems()
	local asphalt = {self.ASPHALT_COLOR[1], self.ASPHALT_COLOR[2], self.ASPHALT_COLOR[3], 1}
	local gravel = {self.GRAVEL_COLOR[1], self.GRAVEL_COLOR[2], self.GRAVEL_COLOR[3], 1}

	return {
		{
			description = self:getLocalizedText("asphalt"),
			colors = {[false] = {asphalt}, [true] = {asphalt}}
		},
		{
			description = self:getLocalizedText("gravel"),
			colors = {[false] = {gravel}, [true] = {gravel}}
		},
		{
			description = self:getLocalizedText("imported"),
			-- One switch controls both imported types, but the swatch shows both
			-- exact road colors.
			colors = {[false] = {asphalt, gravel}, [true] = {asphalt, gravel}}
		}
	}
end

function DynamicRoadMap:ensureRoadFilterState(frame)
	if frame == nil or self.MAP_ROADS_STATE == nil then
		return
	end

	-- In the stock constructor filterStates[4] is hotspotStateFilter. Roads now
	-- occupies state 4, while HOTSPOTS was shifted to state 5, so move the
	-- original hotspot filter to its new slot once.
	if not frame.dynamicRoadMapFilterSlotsPrepared then
		frame.filterStates[InGameMenuMapFrame.MAP_HOTSPOTS] = frame.hotspotStateFilter
		frame.numSelectedFilters[InGameMenuMapFrame.MAP_HOTSPOTS] =
			frame.numSelectedFilters[self.MAP_ROADS_STATE] or 0

		frame.roadStateFilter = {}
		frame.filterStates[self.MAP_ROADS_STATE] = frame.roadStateFilter
		frame.numSelectedFilters[self.MAP_ROADS_STATE] = 0
		frame.dynamicRoadMapFilterSlotsPrepared = true
	end

	frame.roadStateFilter = frame.roadStateFilter or {}
	frame.roadStateFilter[1] = self.showAsphalt
	frame.roadStateFilter[2] = self.showGravel
	frame.roadStateFilter[3] = self.showImported

	frame.filterStates[self.MAP_ROADS_STATE] = frame.roadStateFilter
	frame.dataTables[self.MAP_ROADS_STATE] = self:getRoadFilterItems()
	frame.numSelectedFilters[self.MAP_ROADS_STATE] =
		(self.showAsphalt and 1 or 0) +
		(self.showGravel and 1 or 0) +
		(self.showImported and 1 or 0)
end

function DynamicRoadMap:ensureRoadSelectorDots(frame)
	if frame == nil or frame.subCategoryDotBox == nil then
		return
	end

	local box = frame.subCategoryDotBox
	local elements = box.elements
	if elements == nil or #elements == 0 then
		return
	end

	while #elements < 8 do
		local template = elements[#elements]
		if template == nil or template.clone == nil then
			break
		end
		template:clone(box)
		elements = box.elements
	end

	for i, dot in ipairs(elements) do
		local stateIndex = i
		dot.getIsSelected = function()
			return frame.mapOverviewSelector ~= nil and frame.mapOverviewSelector:getState() == stateIndex
		end
	end

	box:invalidateLayout()
end

function DynamicRoadMap:setupRoadSelector(frame)
	if frame == nil or frame.mapOverviewSelector == nil or frame.mapSelectorTexts == nil then
		return
	end

	if not frame.dynamicRoadMapSelectorAdded then
		-- Insert before HOTSPOTS. This is deliberate: stock map GUI refreshes
		-- every filter-list state through MAP_HOTSPOTS automatically.
		table.insert(frame.mapSelectorTexts, self.MAP_ROADS_STATE, self:getLocalizedText("roads"))
		frame.mapOverviewSelector:setTexts(frame.mapSelectorTexts)
		frame.dynamicRoadMapSelectorAdded = true
	end

	self:ensureRoadFilterState(frame)
	self:ensureRoadSelectorDots(frame)
end

function DynamicRoadMap:onRoadFiltersChanged(frame)
	if frame == nil or frame.roadStateFilter == nil then
		return
	end

	self:setRoadVisibility(
		frame.roadStateFilter[1] == true,
		frame.roadStateFilter[2] == true,
		frame.roadStateFilter[3] == true
	)
end

function DynamicRoadMap:handleRoadDeselectAll(frame, exceptionIndex)
	self:ensureRoadFilterState(frame)

	local filters = frame.roadStateFilter
	local selected = (filters[1] and 1 or 0) + (filters[2] and 1 or 0) + (filters[3] and 1 or 0)
	local selectAll = selected == 0

	for i = 1, 3 do
		if exceptionIndex == i then
			filters[i] = not selectAll
		else
			filters[i] = selectAll
		end
	end

	local count = (filters[1] and 1 or 0) + (filters[2] and 1 or 0) + (filters[3] and 1 or 0)
	frame.numSelectedFilters[self.MAP_ROADS_STATE] = count

	if count == 0 then
		frame.buttonDeselectAllText:setText(g_i18n:getText(InGameMenuMapFrame.L10N_SYMBOL.SELECT_ALL))
	else
		frame.buttonDeselectAllText:setText(g_i18n:getText(InGameMenuMapFrame.L10N_SYMBOL.DESELECT_ALL))
	end

	frame.filterList:reloadData(true)
	self:onRoadFiltersChanged(frame)
end

function DynamicRoadMap:installMapMenuHooks()
	if self.mapMenuHooksInstalled or InGameMenuMapFrame == nil then
		return
	end

	if not self:shiftMapMenuConstants() then
		return
	end

	local oldSetupMapOverview = InGameMenuMapFrame.setupMapOverview
	InGameMenuMapFrame.setupMapOverview = function(frame, ...)
		oldSetupMapOverview(frame, ...)
		DynamicRoadMap:setupRoadSelector(frame)
	end

	local oldOnLoadMapFinished = InGameMenuMapFrame.onLoadMapFinished
	InGameMenuMapFrame.onLoadMapFinished = function(frame, ...)
		oldOnLoadMapFinished(frame, ...)
		DynamicRoadMap:ensureRoadFilterState(frame)
	end

	-- Stock loadFilters stores the hotspot selected-count in the literal
	-- numSelectedFilters[4]. State 4 is Roads now, so temporarily let the stock
	-- function use that slot, then move its result to shifted HOTSPOTS and
	-- restore the Road count.
	local oldLoadFilters = InGameMenuMapFrame.loadFilters
	InGameMenuMapFrame.loadFilters = function(frame, ...)
		DynamicRoadMap:ensureRoadFilterState(frame)

		frame.numSelectedFilters[DynamicRoadMap.MAP_ROADS_STATE] = 0
		oldLoadFilters(frame, ...)

		local hotspotCount = frame.numSelectedFilters[DynamicRoadMap.MAP_ROADS_STATE] or 0
		frame.numSelectedFilters[InGameMenuMapFrame.MAP_HOTSPOTS] = hotspotCount

		DynamicRoadMap:ensureRoadFilterState(frame)
	end

	local oldOnFrameOpen = InGameMenuMapFrame.onFrameOpen
	InGameMenuMapFrame.onFrameOpen = function(frame, ...)
		DynamicRoadMap:ensureRoadFilterState(frame)
		DynamicRoadMap:ensureRoadSelectorDots(frame)
		oldOnFrameOpen(frame, ...)
		DynamicRoadMap:setupRoadSelector(frame)
	end

	-- Roads needs the same crop/field background overlay that HOTSPOTS used to
	-- get, but after moving Roads before HOTSPOTS the stock generator has no
	-- branch for state 4. Handle just this state explicitly.
	local oldGenerateOverviewOverlay = InGameMenuMapFrame.generateOverviewOverlay
	InGameMenuMapFrame.generateOverviewOverlay = function(frame, ...)
		if frame.mapOverviewSelector ~= nil
			and frame.mapOverviewSelector:getState() == DynamicRoadMap.MAP_ROADS_STATE then

			if frame.isMapOverviewInitialized then
				if frame.foliageStateOverlay == nil then
					frame.foliageStateOverlayIsReady = false
				end

				frame.dynamicMapImageLoadingBg:setVisible(true)

				local generator = g_currentMission ~= nil and g_currentMission.mapOverlayGenerator or nil
				if generator ~= nil then
					generator:generateFruitTypeOverlay(
						frame.overviewOverlayFinishedCallback,
						frame.fruitTypeFilter
					)
				else
					frame.dynamicMapImageLoadingBg:setVisible(false)
				end
			end
			return
		end

		return oldGenerateOverviewOverlay(frame, ...)
	end

	local oldOnClickDeselectAll = InGameMenuMapFrame.onClickDeselectAll
	InGameMenuMapFrame.onClickDeselectAll = function(frame, exceptionSection, exceptionIndex, ...)
		if frame.mapOverviewSelector ~= nil
			and frame.mapOverviewSelector:getState() == DynamicRoadMap.MAP_ROADS_STATE then
			DynamicRoadMap:handleRoadDeselectAll(frame, exceptionIndex)
			return
		end

		return oldOnClickDeselectAll(frame, exceptionSection, exceptionIndex, ...)
	end

	local oldSaveFilters = InGameMenuMapFrame.saveFilters
	InGameMenuMapFrame.saveFilters = function(frame, ...)
		oldSaveFilters(frame, ...)
		if frame.mapOverviewSelector ~= nil
			and frame.mapOverviewSelector:getState() == DynamicRoadMap.MAP_ROADS_STATE then
			DynamicRoadMap:onRoadFiltersChanged(frame)
		end
	end

	self.mapMenuHooksInstalled = true
	self:log("Installed native Roads filter-page hooks (Roads inserted before Hotspots)")
end

-- -------------------------------------------------------------------------
-- Road mask / terrain handling
-- -------------------------------------------------------------------------

function DynamicRoadMap:canInitialize()
	return g_currentMission ~= nil
		and g_terrainNode ~= nil
		and g_currentMission.terrainSize ~= nil
		and g_currentMission.terrainSize > 0
		and InfoLayer ~= nil
		and createDensityMapVisualizationOverlay ~= nil
		and getTerrainNumOfLayers ~= nil
		and getTerrainLayerName ~= nil
		and getTerrainLayerAtWorldPos ~= nil
		and getTerrainHeightAtWorldPos ~= nil
		and setBitVectorMapParallelogram ~= nil
		and getBitVectorMapPoint ~= nil
end

function DynamicRoadMap:calculateMaskResolution(terrainSize)
	local resolution = math.floor(terrainSize / self.METRES_PER_MASK_PIXEL + 0.5)
	resolution = math.max(self.MIN_MASK_RESOLUTION, resolution)
	resolution = math.min(self.MAX_MASK_RESOLUTION, resolution)
	return resolution
end

function DynamicRoadMap:createOrLoadRoadInfoLayer()
	local filename = self:getMaskFilename()
	local layer = InfoLayer.new("dynamicRoadMap", "")
	local loaded = false

	if self:getIsServer() and filename ~= nil and fileExists(filename) then
		loaded = layer:load(filename, self.ROAD_NUM_CHANNELS)
		if loaded and (layer.width ~= self.maskResolution or layer.height ~= self.maskResolution) then
			self:log(
				"Stored road mask resolution %dx%d does not match %dx%d; starting a new mask",
				layer.width,
				layer.height,
				self.maskResolution,
				self.maskResolution
			)
			layer:delete()
			layer = InfoLayer.new("dynamicRoadMap", "")
			loaded = false
		end
	end

	if not loaded then
		layer:create(self.maskResolution, self.maskResolution, self.ROAD_NUM_CHANNELS, false)
		self:log("Created new empty player-road mask")
	else
		self:log("Loaded player-road mask: %s", filename)
	end

	self.roadInfoLayer = layer
	self.roadMaskWasLoaded = loaded
end

function DynamicRoadMap:createOrLoadLegacyInfoLayer()
	local filename = self:getLegacyMaskFilename()
	local layer = InfoLayer.new("dynamicRoadMapLegacy", "")
	local loaded = false

	if self:getIsServer() and filename ~= nil and fileExists(filename) then
		loaded = layer:load(filename, self.LEGACY_NUM_CHANNELS)
		if loaded and (layer.width ~= self.maskResolution or layer.height ~= self.maskResolution) then
			self:log(
				"Stored legacy road mask resolution %dx%d does not match %dx%d; rebuilding",
				layer.width, layer.height, self.maskResolution, self.maskResolution
			)
			layer:delete()
			layer = InfoLayer.new("dynamicRoadMapLegacy", "")
			loaded = false
		end
	end

	if not loaded then
		layer:create(self.maskResolution, self.maskResolution, self.LEGACY_NUM_CHANNELS, false)
		self:log("Created new empty typed legacy-road mask")
	else
		self:log("Loaded typed legacy-road mask: %s", filename)
	end

	self.legacyInfoLayer = layer
	self.legacyMaskWasLoaded = loaded
end

function DynamicRoadMap:initialize()
	if self.initialized or not self:canInitialize() then
		return false
	end

	local isServer = self:getIsServer()

	self.terrainSize = g_currentMission.terrainSize
	self.terrainHalfSize = self.terrainSize * 0.5
	self.maskResolution = self:calculateMaskResolution(self.terrainSize)
	self.metresPerPixel = self.terrainSize / self.maskResolution

	self:loadSettings()

	-- Определение дорожных terrain-слоёв нужно только стороне, которая
	-- формирует маску. Клиент работает исключительно с готовым InfoLayer.
	if isServer then
		self:discoverRoadTerrainLayers()
	end

	self:createOrLoadRoadInfoLayer()
	self:createOrLoadLegacyInfoLayer()

	if isServer then
		if not self.legacyMaskWasLoaded and self.legacyImportCompleted then
			self:log("Typed legacy-road mask is missing/new; legacy import completion flag reset")
			self.legacyImportCompleted = false
		end

		-- Полное сканирование старых дорог выполняется только сервером.
		if not self.legacyImportCompleted then
			self:requestLegacyImport()
			self:log("Legacy-road background import scheduled at savegame load (server only)")
		end
	else
		-- Клиент не доверяет локальным sidecar-файлам и не запускает импорт.
		-- Готовое состояние придёт отдельным сетевым событием от сервера.
		self.legacyImportCompleted = false
		self.legacyImportVersion = 0
	end

	self.roadOverlay = createDensityMapVisualizationOverlay(
		"dynamicRoadMap",
		self.maskResolution,
		self.maskResolution
	)

	self.initialized = true

	self:log("Terrain size: %.0f m", self.terrainSize)
	self:log(
		"Road mask: %dx%d (%.2f m/pixel)",
		self.maskResolution,
		self.maskResolution,
		self.metresPerPixel
	)
	self:log("Network role: %s", isServer and "SERVER" or "CLIENT")

	if isServer then
		self:requestOverlayRegeneration()
	else
		self:requestNetworkSync()
	end

	self:syncOpenMapFrame()
	return true
end

--- Отправляет клиентский запрос на первичную синхронизацию дорожных масок.
function DynamicRoadMap:requestNetworkSync(force)
	-- Обычный запрос допустим только до получения первого полного состояния.
	-- force используется при обнаружении разрыва ревизий и позволяет запросить
	-- полную маску повторно уже после успешной первоначальной синхронизации.
	if self:getIsServer()
		or ((self.networkSyncReceived or self.networkSyncRequested) and force ~= true)
		or g_client == nil then
		return false
	end

	local connection = g_client:getServerConnection()
	if connection == nil then
		return false
	end

	connection:sendEvent(DynamicRoadMapSyncRequestEvent.new())
	self.networkSyncRequested = true
	self:log("Requested road-map state from server")
	return true
end

--- Формирует полное серверное состояние для одного клиента.
function DynamicRoadMap:sendNetworkFullSync(connection)
	if not self:getIsServer()
		or connection == nil
		or self.roadInfoLayer == nil then
		return false
	end

	local legacyReady = self.legacyImportCompleted == true
		and self.currentScan == nil
		and self.legacyInfoLayer ~= nil

	connection:sendEvent(DynamicRoadMapFullSyncEvent.new(
		self.roadInfoLayer,
		legacyReady and self.legacyInfoLayer or nil,
		legacyReady,
		self.maskResolution,
		self.legacyImportVersion,
		self.networkRevision or 0
	))

	self:log(
		"Sent road-map state to client (legacyReady=%s revision=%d)",
		tostring(legacyReady),
		self.networkRevision or 0
	)
	return true
end

--- Обрабатывает запрос первичной синхронизации от клиента.
function DynamicRoadMap:onNetworkSyncRequest(connection)
	if not self:getIsServer() then
		return
	end

	if not self.initialized then
		self:initialize()
	end

	self:sendNetworkFullSync(connection)
end

--- Рассылает всем клиентам полное состояние после завершения legacy-скана.
function DynamicRoadMap:broadcastNetworkFullSync()
	if not self:getIsServer()
		or g_server == nil
		or self.roadInfoLayer == nil
		or self.legacyInfoLayer == nil
		or not self.legacyImportCompleted then
		return
	end

	g_server:broadcastEvent(DynamicRoadMapFullSyncEvent.new(
		self.roadInfoLayer,
		self.legacyInfoLayer,
		true,
		self.maskResolution,
		self.legacyImportVersion,
		self.networkRevision or 0
	), false)

	self:log("Broadcast completed road-map state to clients")
end

--- Принимает полную серверную маску и заменяет клиентские локальные данные.
function DynamicRoadMap:applyNetworkFullSync(event)
	if self:getIsServer() or event == nil or event.roadInfoLayer == nil then
		return
	end

	if event.dataVersion ~= self.DATA_VERSION then
		self:log(
			"Network data version differs: server=%s client=%s",
			tostring(event.dataVersion),
			tostring(self.DATA_VERSION)
		)
	end

	-- На одинаковой карте разрешение совпадает. Если нет, пересоздаём overlay
	-- по серверному размеру, чтобы данные InfoLayer отображались корректно.
	if event.maskResolution ~= nil
		and event.maskResolution > 0
		and event.maskResolution ~= self.maskResolution then
		self.maskResolution = event.maskResolution
		self.metresPerPixel = self.terrainSize / self.maskResolution

		if self.roadOverlay ~= nil then
			delete(self.roadOverlay)
		end
		self.roadOverlay = createDensityMapVisualizationOverlay(
			"dynamicRoadMap",
			self.maskResolution,
			self.maskResolution
		)
		self.roadOverlayReady = false
		self.roadOverlayGenerating = false
	end

	-- Overlay хранит ссылки на DensityMap/BitVectorMap. Перед заменой InfoLayer
	-- явно отвязываем старые карты, иначе движок вынужден аварийно сбрасывать
	-- overlay при delete() и пишет предупреждение на каждой полной синхронизации.
	if self.roadOverlay ~= nil then
		resetDensityMapVisualizationOverlay(self.roadOverlay)
		self.roadOverlayReady = false
		self.roadOverlayGenerating = false
	end

	if self.roadInfoLayer ~= nil then
		self.roadInfoLayer:delete()
	end
	self.roadInfoLayer = event.roadInfoLayer
	event.roadInfoLayer = nil

	if self.legacyInfoLayer ~= nil then
		self.legacyInfoLayer:delete()
	end

	if event.legacyReady and event.legacyInfoLayer ~= nil then
		self.legacyInfoLayer = event.legacyInfoLayer
		event.legacyInfoLayer = nil
	else
		self.legacyInfoLayer = InfoLayer.new("dynamicRoadMapLegacy", "")
		self.legacyInfoLayer:create(
			self.maskResolution,
			self.maskResolution,
			self.LEGACY_NUM_CHANNELS,
			false
		)
	end

	self.roadMaskWasLoaded = true
	self.legacyMaskWasLoaded = event.legacyReady == true
	self.legacyImportCompleted = event.legacyReady == true
	self.legacyImportVersion = event.legacyImportVersion or 0
	self.networkSyncReceived = true
	self.networkLegacyReady = event.legacyReady == true
	self.networkRevision = event.revision or 0
	self.networkSyncRequested = false

	-- Если изменение пришло во время передачи большой полной маски, применяем
	-- его после full-sync. Ревизия не позволяет старому full-sync затереть
	-- более новую покраску.
	local pending = self.pendingNetworkPaintEvents or {}
	self.pendingNetworkPaintEvents = {}
	table.sort(pending, function(a, b)
		return (a.revision or 0) < (b.revision or 0)
	end)
	for _, pendingEvent in ipairs(pending) do
		if (pendingEvent.revision or 0) > self.networkRevision then
			self:applyNetworkPaintAreas(
				pendingEvent.areas,
				pendingEvent.roadValue,
				pendingEvent.revision,
				pendingEvent.clearLegacy
			)
		end
	end

	self:requestOverlayRegeneration()
	self:syncOpenMapFrame()
	self:log(
		"Received road-map state from server (legacyReady=%s revision=%d)",
		tostring(event.legacyReady),
		self.networkRevision
	)
end

--- Рассылает клиентам только подтверждённые сервером изменения масок.
-- Большой мазок режется на ограниченные пакеты, чтобы один event не разрастался
-- до десятков тысяч parallelogram-описаний.
function DynamicRoadMap:broadcastPaintAreas(areas, roadValue, clearLegacy)
	if not self:getIsServer() or g_server == nil or areas == nil or #areas == 0 then
		return false
	end

	local total = #areas
	local offset = 1
	local sent = 0

	while offset <= total do
		local last = math.min(offset + self.MAX_PAINT_AREAS_PER_EVENT - 1, total)
		local chunk = {}
		for i = offset, last do
			chunk[#chunk + 1] = areas[i]
		end

		self.networkRevision = (self.networkRevision or 0) + 1
		g_server:broadcastEvent(
			DynamicRoadMapPaintEvent.new(chunk, roadValue, self.networkRevision, clearLegacy),
			false
		)

		sent = sent + #chunk
		offset = last + 1
	end

	self:log(
		"Broadcast road-paint batch (revision=%d areas=%d value=%d clearLegacy=%s)",
		self.networkRevision,
		sent,
		roadValue,
		tostring(clearLegacy == true)
	)
	return true
end

--- Возвращает соединение клиента, породившего серверный LandscapingSculptEvent.
function DynamicRoadMap:getLandscapingSourceConnection(landscaping)
	if landscaping == nil then
		return nil
	end

	local callbackTarget = landscaping.callbackFunctionTarget
	if callbackTarget ~= nil and callbackTarget.runConnection ~= nil then
		return callbackTarget.runConnection
	end

	return nil
end

--- Добавляет подтверждённые сервером области в пачку конкретного клиента.
function DynamicRoadMap:queueServerPaintBatch(connection, areas, roadValue, clearLegacy)
	if connection == nil or areas == nil or #areas == 0 then
		return false
	end

	self.pendingServerPaintBatches = self.pendingServerPaintBatches or {}
	local batch = self.pendingServerPaintBatches[connection]

	-- В пределах одного удержания кнопки тип terrain layer не меняется. Если
	-- всё же пришёл другой тип, сначала отправляем предыдущую законченную пачку.
	if batch ~= nil
		and (batch.roadValue ~= roadValue or batch.clearLegacy ~= (clearLegacy == true)) then
		self:flushServerPaintBatch(connection, "paint type changed")
		batch = nil
	end

	if batch == nil then
		batch = {
			areas = {},
			roadValue = roadValue,
			clearLegacy = clearLegacy == true,
			timer = self.PAINT_BATCH_TIMEOUT_MS
		}
		self.pendingServerPaintBatches[connection] = batch
	end

	-- Копируем координаты: исходный Landscaping после callback больше нам не нужен.
	for _, area in ipairs(areas) do
		batch.areas[#batch.areas + 1] = {
			area[1], area[2], area[3], area[4], area[5], area[6]
		}
	end
	batch.timer = self.PAINT_BATCH_TIMEOUT_MS
	return true
end

--- Отправляет накопленную пачку одного клиента всем участникам сетевой игры.
function DynamicRoadMap:flushServerPaintBatch(connection, reason)
	if not self:getIsServer() or connection == nil then
		return false
	end

	local batches = self.pendingServerPaintBatches
	local batch = batches ~= nil and batches[connection] or nil
	if batch == nil then
		return false
	end

	batches[connection] = nil
	if batch.areas == nil or #batch.areas == 0 then
		return false
	end

	local sent = self:broadcastPaintAreas(batch.areas, batch.roadValue, batch.clearLegacy)
	if sent then
		self:log(
			"Committed client road-paint batch (%s): areas=%d value=%d",
			tostring(reason or "commit"),
			#batch.areas,
			batch.roadValue
		)
	end
	return sent
end

--- Сервер принимает короткое уведомление клиента об отпускании кисти.
function DynamicRoadMap:onNetworkPaintCommit(connection)
	if not self:getIsServer() then
		return
	end

	self:flushServerPaintBatch(connection, "brush released")
end

--- Клиент уведомляет сервер, что текущий непрерывный мазок завершён.
function DynamicRoadMap:onPaintBrushReleased()
	if g_client == nil then
		return
	end

	local connection = g_client:getServerConnection()
	if connection ~= nil then
		connection:sendEvent(DynamicRoadMapPaintCommitEvent.new())
	end
end

--- Аварийно отправляет пачки, для которых не пришёл release-event.
function DynamicRoadMap:updateServerPaintBatches(dt)
	if not self:getIsServer() or self.pendingServerPaintBatches == nil then
		return
	end

	local expired = {}
	for connection, batch in pairs(self.pendingServerPaintBatches) do
		batch.timer = (batch.timer or self.PAINT_BATCH_TIMEOUT_MS) - dt
		if batch.timer <= 0 then
			expired[#expired + 1] = connection
		end
	end

	for _, connection in ipairs(expired) do
		self:flushServerPaintBatch(connection, "timeout")
	end
end

--- Применяет на клиенте изменение, уже рассчитанное и подтверждённое сервером.
function DynamicRoadMap:applyNetworkPaintAreas(areas, roadValue, revision, clearLegacy)
	if self:getIsServer() or not self.initialized or areas == nil then
		return
	end

	revision = revision or 0

	-- Пока полная маска ещё не получена, не пишем изменение во временную
	-- пустую маску: сохраняем delta и применим её поверх server full-sync.
	if not self.networkSyncReceived then
		table.insert(self.pendingNetworkPaintEvents, {
			areas = areas,
			roadValue = roadValue,
			revision = revision,
			clearLegacy = clearLegacy == true
		})
		self:log("Queued road-paint update until full sync (revision=%d)", revision)
		return
	end

	if revision > 0 and revision <= (self.networkRevision or 0) then
		return
	end

	-- На надёжном ordered-канале разрыва быть не должно. Если он всё же
	-- обнаружен, просим полную маску вместо самостоятельного сканирования.
	if revision > 0
		and self.networkRevision ~= nil
		and revision > self.networkRevision + 1 then
		self:log(
			"Road-map revision gap detected (%d -> %d); requesting full server sync",
			self.networkRevision,
			revision
		)
		self.networkSyncReceived = false
		self.networkSyncRequested = false
		table.insert(self.pendingNetworkPaintEvents, {
			areas = areas,
			roadValue = roadValue,
			revision = revision,
			clearLegacy = clearLegacy == true
		})
		self:requestNetworkSync(true)
		return
	end

	local changed = self:applyPaintAreasToPlayerMask(areas, roadValue, false)
	if clearLegacy then
		changed = self:applyPaintAreasToLegacyMask(areas, self.LEGACY_VALUE_NONE, false) or changed
	end

	if revision > 0 then
		self.networkRevision = revision
	end

	if changed then
		self:requestOverlayRegeneration()
		self:log(
			"Applied server road-paint update (revision=%d areas=%d value=%d clearLegacy=%s)",
			revision,
			#areas,
			roadValue,
			tostring(clearLegacy == true)
		)
	end
end

function DynamicRoadMap:classifyRoadText(text)
	local lower = string.lower(tostring(text or ""))

	if string.find(lower, "asphalt", 1, true) ~= nil
		or string.find(lower, "асфальт", 1, true) ~= nil then
		return self.ROAD_VALUE_ASPHALT, "ASPHALT"
	end

	if string.find(lower, "gravel", 1, true) ~= nil
		or string.find(lower, "грав", 1, true) ~= nil then
		return self.ROAD_VALUE_GRAVEL, "GRAVEL"
	end

	return nil, nil
end

function DynamicRoadMap:registerRoadTerrainLayer(layerIndex, layerName, roadValue, roadType, source)
	if layerIndex == nil or roadValue == nil then
		return
	end

	-- If several ground types point to the same layer, any asphalt/gravel
	-- mapping is enough to classify that layer as a road material.
	self.roadTerrainLayerValues[layerIndex] = roadValue

	if self.roadTerrainLayerEntries[layerIndex] == nil then
		local entry = {
			index = layerIndex,
			name = layerName or getTerrainLayerName(g_terrainNode, layerIndex),
			value = roadValue,
			roadType = roadType or (roadValue == self.ROAD_VALUE_ASPHALT and "ASPHALT" or "GRAVEL")
		}
		self.roadTerrainLayerEntries[layerIndex] = entry
		table.insert(self.roadTerrainLayers, entry)
		self:log(
			"Road terrain layer: layer[%d]=%s -> %s (%s)",
			layerIndex, tostring(entry.name), entry.roadType, tostring(source or "terrainName")
		)
	end
end

function DynamicRoadMap:discoverRoadTerrainLayers()
	self.roadTerrainLayers = {}
	self.roadTerrainLayerValues = {}
	self.roadTerrainLayerEntries = {}

	-- Primary universal source for Landscaping paints: GroundTypeManager.
	-- A map may call the actual terrain layer anything (e.g. TARMAC) while
	-- mapping it to typeName=asphalt. Use the same mappings the game uses to
	-- populate Construction -> Painting.
	if g_groundTypeManager ~= nil and g_groundTypeManager.groundTypeMappings ~= nil then
		for typeName, mapping in pairs(g_groundTypeManager.groundTypeMappings) do
			local roadValue, roadType = self:classifyRoadText(typeName)

			if roadValue == nil and mapping ~= nil then
				roadValue, roadType = self:classifyRoadText(mapping.layerName)
			end
			if roadValue == nil and mapping ~= nil then
				roadValue, roadType = self:classifyRoadText(mapping.title)
			end

			if roadValue ~= nil and mapping ~= nil then
				local layerIndex = nil
				if g_groundTypeManager.getTerrainLayerByType ~= nil then
					layerIndex = g_groundTypeManager:getTerrainLayerByType(typeName)
				elseif g_groundTypeManager.terrainLayerMapping ~= nil then
					layerIndex = g_groundTypeManager.terrainLayerMapping[mapping.layerName]
				end

				if layerIndex ~= nil then
					local actualName = getTerrainLayerName(g_terrainNode, layerIndex)
					self:registerRoadTerrainLayer(
						layerIndex,
						actualName or mapping.layerName,
						roadValue,
						roadType,
						"groundType:" .. tostring(typeName)
					)
				end
			end
		end
	end

	-- Fallback for maps/layers that are not registered in GroundTypeManager:
	-- names such as asphalt01, ASPHALTALPINE, gravel02.
	local numLayers = getTerrainNumOfLayers(g_terrainNode)
	for layerIndex = 0, numLayers - 1 do
		if self.roadTerrainLayerValues[layerIndex] == nil then
			local layerName = getTerrainLayerName(g_terrainNode, layerIndex)
			local roadValue, roadType = self:classifyRoadText(layerName)
			if roadValue ~= nil then
				self:registerRoadTerrainLayer(layerIndex, layerName, roadValue, roadType, "terrainNameFallback")
			end
		end
	end
end

function DynamicRoadMap:getRoadValueForTerrainPaintingLayer(layerIndex)
	if layerIndex == nil then
		return self.ROAD_VALUE_NONE
	end

	local roadValue = self.roadTerrainLayerValues ~= nil and self.roadTerrainLayerValues[layerIndex] or nil
	if roadValue ~= nil then
		return roadValue
	end

	-- Last-resort fallback if a custom map added/initialized a layer after our
	-- first discovery pass.
	local layerName = getTerrainLayerName(g_terrainNode, layerIndex)
	local detectedValue, roadType = self:classifyRoadText(layerName)
	if detectedValue ~= nil then
		self:registerRoadTerrainLayer(layerIndex, layerName, detectedValue, roadType, "paintFallback")
		return detectedValue
	end

	-- Try GroundTypeManager again by resolved terrain-layer index. This covers
	-- generic names such as TARMAC even if initialization order was unusual.
	if g_groundTypeManager ~= nil and g_groundTypeManager.groundTypeMappings ~= nil then
		for typeName, mapping in pairs(g_groundTypeManager.groundTypeMappings) do
			local resolvedLayer = nil
			if g_groundTypeManager.getTerrainLayerByType ~= nil then
				resolvedLayer = g_groundTypeManager:getTerrainLayerByType(typeName)
			elseif g_groundTypeManager.terrainLayerMapping ~= nil and mapping ~= nil then
				resolvedLayer = g_groundTypeManager.terrainLayerMapping[mapping.layerName]
			end

			if resolvedLayer == layerIndex then
				local value, kind = self:classifyRoadText(typeName)
				if value == nil and mapping ~= nil then
					value, kind = self:classifyRoadText(mapping.layerName)
				end
				if value == nil and mapping ~= nil then
					value, kind = self:classifyRoadText(mapping.title)
				end
				if value ~= nil then
					self:registerRoadTerrainLayer(layerIndex, layerName, value, kind, "paintGroundTypeFallback")
					return value
				end
			end
		end
	end

	return self.ROAD_VALUE_NONE
end

function DynamicRoadMap:startScan(minX, maxX, minY, maxY, reason)
	minX = math.clamp(math.floor(minX), 0, self.maskResolution - 1)
	maxX = math.clamp(math.floor(maxX), 0, self.maskResolution - 1)
	minY = math.clamp(math.floor(minY), 0, self.maskResolution - 1)
	maxY = math.clamp(math.floor(maxY), 0, self.maskResolution - 1)

	if maxX < minX or maxY < minY then
		return
	end

	local scanReason = reason or "update"
	local step = scanReason == "legacyImport" and self.LEGACY_IMPORT_STEP or 1
	local countX = math.floor((maxX - minX) / step) + 1
	local countY = math.floor((maxY - minY) / step) + 1

	self.currentScan = {
		minX = minX,
		maxX = maxX,
		minY = minY,
		maxY = maxY,
		x = minX,
		y = minY,
		step = step,
		reason = scanReason,
		total = countX * countY,
		processed = 0,
		lastProgress = -1
	}

	self:log(
		"Road rescan started (%s): x=%d..%d y=%d..%d (%d cells)",
		self.currentScan.reason,
		minX,
		maxX,
		minY,
		maxY,
		self.currentScan.total
	)
end

function DynamicRoadMap:maskCellToWorld(cellX, cellY)
	local worldX = -self.terrainHalfSize + (cellX + 0.5) * self.metresPerPixel
	local worldZ = -self.terrainHalfSize + (cellY + 0.5) * self.metresPerPixel
	return worldX, worldZ
end

function DynamicRoadMap:detectRoadValueAtWorldPosition(worldX, worldZ)
	local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, worldX, 0, worldZ)
	local bestValue = self.ROAD_VALUE_NONE
	local bestWeight = self.ROAD_WEIGHT_THRESHOLD

	for _, layer in ipairs(self.roadTerrainLayers) do
		local weight = getTerrainLayerAtWorldPos(g_terrainNode, layer.index, worldX, terrainY, worldZ)

		if weight ~= nil and weight > bestWeight then
			bestWeight = weight
			bestValue = layer.value
		end
	end

	return bestValue
end

function DynamicRoadMap:isLegacyRoadContinuous(worldX, worldZ, roadValue)
	if roadValue == self.ROAD_VALUE_NONE then
		return false
	end

	local d = self.LEGACY_CONTINUITY_OFFSET_METRES
	local function same(dx, dz)
		return self:detectRoadValueAtWorldPosition(worldX + dx, worldZ + dz) == roadValue
	end

	-- A road is locally line-like: at least one approximately opposite pair
	-- must still be the same road material a few metres away. Tiny decorative
	-- paint dabs do not satisfy this test and therefore disappear from import.
	if same(-d, 0) and same(d, 0) then
		return true
	end
	if same(0, -d) and same(0, d) then
		return true
	end
	if same(-d, -d) and same(d, d) then
		return true
	end
	if same(-d, d) and same(d, -d) then
		return true
	end

	return false
end

function DynamicRoadMap:setMaskCell(cellX, cellY, value)
	setBitVectorMapParallelogram(
		self.roadInfoLayer:getId(),
		cellX, cellY, 1, 0, 0, 1,
		0, self.ROAD_NUM_CHANNELS, value, nil
	)
end

function DynamicRoadMap:getMaskCell(cellX, cellY)
	return self.roadInfoLayer:getValueAtPos(cellX, cellY, 0, self.ROAD_NUM_CHANNELS)
end

function DynamicRoadMap:setLegacyMaskCell(cellX, cellY, value)
	setBitVectorMapParallelogram(
		self.legacyInfoLayer:getId(),
		cellX, cellY, 1, 0, 0, 1,
		0, self.LEGACY_NUM_CHANNELS, value, nil
	)
end

function DynamicRoadMap:clearLegacyMaskBlock(cellX, cellY, step)
	for dy = 0, step - 1 do
		for dx = 0, step - 1 do
			local x = cellX + dx
			local y = cellY + dy
			if x < self.maskResolution and y < self.maskResolution then
				self:setLegacyMaskCell(x, y, self.LEGACY_VALUE_NONE)
			end
		end
	end
end

function DynamicRoadMap:setLegacyMaskBlock(cellX, cellY, step, roadValue)
	local legacyValue = roadValue == self.ROAD_VALUE_ASPHALT
		and self.LEGACY_VALUE_ASPHALT
		or self.LEGACY_VALUE_GRAVEL

	for dy = 0, step - 1 do
		for dx = 0, step - 1 do
			local x = cellX + dx
			local y = cellY + dy
			if x < self.maskResolution and y < self.maskResolution then
				self:setLegacyMaskCell(x, y, legacyValue)
			end
		end
	end
end

function DynamicRoadMap:requestLegacyImport()
	if not self:getIsServer() then
		return
	end

	if self.legacyImportCompleted or self.legacyImportRequested then
		return
	end

	self.legacyImportRequested = true
	self:log("Legacy-road background import requested; full terrain scan will start when idle")
end

function DynamicRoadMap:startLegacyImport()
	if not self:getIsServer() then
		return
	end

	if self.legacyImportCompleted or self.currentScan ~= nil then
		return
	end

	self.legacyImportRequested = false
	self:startScan(0, self.maskResolution - 1, 0, self.maskResolution - 1, "legacyImport")
end

function DynamicRoadMap:advanceScanCell(scan)
	scan.x = scan.x + scan.step
	if scan.x > scan.maxX then
		scan.x = scan.minX
		scan.y = scan.y + scan.step
	end
end

function DynamicRoadMap:processCurrentScan()
	if not self:getIsServer() then
		return
	end

	local scan = self.currentScan
	if scan == nil then
		return
	end

	local budget = self.SCAN_CELLS_PER_FRAME

	while budget > 0 and scan.y <= scan.maxY do
		local worldX, worldZ = self:maskCellToWorld(scan.x, scan.y)
		local detectedValue = self:detectRoadValueAtWorldPosition(worldX, worldZ)

		if scan.reason == "legacyImport" then
			-- Legacy roads live in their own typed mask. This preserves whether
			-- an imported road is asphalt or gravel while keeping player roads
			-- completely independent.
			self:clearLegacyMaskBlock(scan.x, scan.y, scan.step)
			if detectedValue ~= self.ROAD_VALUE_NONE
				and self:isLegacyRoadContinuous(worldX, worldZ, detectedValue) then
				self:setLegacyMaskBlock(scan.x, scan.y, scan.step, detectedValue)
			end
		else
			self:setMaskCell(scan.x, scan.y, detectedValue)
		end

		scan.processed = scan.processed + 1
		self:advanceScanCell(scan)
		budget = budget - 1
	end

	if scan.reason == "legacyImport" and scan.total > 0 then
		local progress = math.floor(scan.processed / scan.total * 10) * 10
		progress = math.min(progress, 100)
		if progress > scan.lastProgress and progress % 10 == 0 then
			scan.lastProgress = progress
			self:log("Legacy-road import: %d%%", progress)
		end
	end

	if scan.y > scan.maxY then
		local reason = scan.reason
		self.currentScan = nil

		if reason == "legacyImport" then
			self.legacyImportCompleted = true
			self.legacyImportVersion = self.LEGACY_IMPORT_VERSION
			self:log("Legacy-road import complete (filtered continuity import v%d)", self.LEGACY_IMPORT_VERSION)
		else
			self:log("Road rescan complete (%s)", tostring(reason))
		end

		self:requestOverlayRegeneration()
		self:saveRoadMask()

		if reason == "legacyImport" then
			self:broadcastNetworkFullSync()
		end
	end
end

function DynamicRoadMap:requestOverlayRegeneration()
	self.roadOverlayDirty = true
end

function DynamicRoadMap:setRoadVisibility(showAsphalt, showGravel, showImported)
	local changed = self.showAsphalt ~= showAsphalt
		or self.showGravel ~= showGravel
		or self.showImported ~= showImported

	self.showAsphalt = showAsphalt
	self.showGravel = showGravel
	self.showImported = showImported

	if changed then
		self:log(
			"Road visibility changed: asphalt=%s gravel=%s imported=%s",
			tostring(showAsphalt),
			tostring(showGravel),
			tostring(showImported)
		)
		self:requestOverlayRegeneration()
		self:saveSettings()
	end
end

function DynamicRoadMap:regenerateOverlay()
	if self.roadOverlay == nil
		or self.roadInfoLayer == nil
		or self.legacyInfoLayer == nil
		or self.roadOverlayGenerating then
		return
	end

	resetDensityMapVisualizationOverlay(self.roadOverlay)

	if self.showAsphalt then
		setDensityMapVisualizationOverlayStateColor(
			self.roadOverlay, self.roadInfoLayer:getId(),
			0, 0, 0, self.ROAD_NUM_CHANNELS, self.ROAD_VALUE_ASPHALT,
			unpack(self.ASPHALT_COLOR)
		)
	end

	if self.showGravel then
		setDensityMapVisualizationOverlayStateColor(
			self.roadOverlay, self.roadInfoLayer:getId(),
			0, 0, 0, self.ROAD_NUM_CHANNELS, self.ROAD_VALUE_GRAVEL,
			unpack(self.GRAVEL_COLOR)
		)
	end

	if self.showImported then
		setDensityMapVisualizationOverlayStateColor(
			self.roadOverlay, self.legacyInfoLayer:getId(),
			0, 0, 0, self.LEGACY_NUM_CHANNELS, self.LEGACY_VALUE_ASPHALT,
			unpack(self.ASPHALT_COLOR)
		)
		setDensityMapVisualizationOverlayStateColor(
			self.roadOverlay, self.legacyInfoLayer:getId(),
			0, 0, 0, self.LEGACY_NUM_CHANNELS, self.LEGACY_VALUE_GRAVEL,
			unpack(self.GRAVEL_COLOR)
		)
	end

	generateDensityMapVisualizationOverlay(self.roadOverlay)

	self.roadOverlayDirty = false
	self.roadOverlayReady = false
	self.roadOverlayGenerating = true
end

function DynamicRoadMap:updateOverlayState()
	if self.roadOverlayGenerating
		and self.roadOverlay ~= nil
		and getIsDensityMapVisualizationOverlayReady(self.roadOverlay) then
		self.roadOverlayGenerating = false
		self.roadOverlayReady = true
		self:log("Road map overlay ready")
	end
end

function DynamicRoadMap:worldToMask(worldX, worldZ)
	local x = math.floor((worldX + self.terrainHalfSize) / self.terrainSize * self.maskResolution)
	local y = math.floor((worldZ + self.terrainHalfSize) / self.terrainSize * self.maskResolution)
	return x, y
end

function DynamicRoadMap:queueDirtyWorldBounds(minX, maxX, minZ, maxZ)
	if not self.initialized then
		return
	end

	local margin = math.max(self.DIRTY_MARGIN_METRES, self.metresPerPixel)
	minX = minX - margin
	maxX = maxX + margin
	minZ = minZ - margin
	maxZ = maxZ + margin

	if self.pendingDirtyBounds == nil then
		self.pendingDirtyBounds = {minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ}
	else
		self.pendingDirtyBounds.minX = math.min(self.pendingDirtyBounds.minX, minX)
		self.pendingDirtyBounds.maxX = math.max(self.pendingDirtyBounds.maxX, maxX)
		self.pendingDirtyBounds.minZ = math.min(self.pendingDirtyBounds.minZ, minZ)
		self.pendingDirtyBounds.maxZ = math.max(self.pendingDirtyBounds.maxZ, maxZ)
	end

	self.pendingDirtyTimer = self.DIRTY_RESCAN_DELAY_MS
end

function DynamicRoadMap:queueDirtyAreas(areas)
	if areas == nil then
		return
	end

	local minX = math.huge
	local maxX = -math.huge
	local minZ = math.huge
	local maxZ = -math.huge

	for _, area in pairs(areas) do
		local x0, z0, x1, z1, x2, z2 = unpack(area)
		if x0 ~= nil then
			local x3 = x2 + (x1 - x0)
			local z3 = z2 + (z1 - z0)

			minX = math.min(minX, x0, x1, x2, x3)
			maxX = math.max(maxX, x0, x1, x2, x3)
			minZ = math.min(minZ, z0, z1, z2, z3)
			maxZ = math.max(maxZ, z0, z1, z2, z3)
		end
	end

	if minX ~= math.huge then
		self:queueDirtyWorldBounds(minX, maxX, minZ, maxZ)
	end
end

function DynamicRoadMap:applyPaintAreasToPlayerMask(areas, roadValue, markForCommit)
	if self.roadInfoLayer == nil or areas == nil then
		return false
	end

	local changed = false
	for _, area in pairs(areas) do
		local x0, z0, x1, z1, x2, z2 = unpack(area)
		if x0 ~= nil then
			-- modifiedAreas is generated by Landscaping itself and exactly
			-- describes the terrain area accepted by the engine. Store that
			-- parallelogram directly instead of re-sampling blended terrain.
			self.roadInfoLayer:setValueAtWorldParallelogram(
				x0, z0, x1, z1, x2, z2,
				0, self.ROAD_NUM_CHANNELS, roadValue, nil
			)
			changed = true
		end
	end

	if changed then
		if markForCommit == false then
			-- Клиент только обновляет визуальный слой; сохранение и формирование
			-- данных остаются обязанностью сервера.
			self:requestOverlayRegeneration()
		else
			self.playerMaskChanged = true
			self.playerMaskCommitTimer = self.DIRTY_RESCAN_DELAY_MS
		end
	end

	return changed
end

--- Применяет world-space modifiedAreas к отдельной маске импортированных дорог.
-- Сейчас используется для удаления старой импортированной дороги, когда игрок
-- перекрашивает этот участок в траву/грунт/другой не-дорожный материал.
function DynamicRoadMap:applyPaintAreasToLegacyMask(areas, legacyValue, markForCommit)
	if self.legacyInfoLayer == nil or areas == nil then
		return false
	end

	local changed = false
	for _, area in pairs(areas) do
		local x0, z0, x1, z1, x2, z2 = unpack(area)
		if x0 ~= nil then
			self.legacyInfoLayer:setValueAtWorldParallelogram(
				x0, z0, x1, z1, x2, z2,
				0, self.LEGACY_NUM_CHANNELS, legacyValue, nil
			)
			changed = true
		end
	end

	if changed and markForCommit ~= false then
		self.playerMaskChanged = true
		self.playerMaskCommitTimer = self.DIRTY_RESCAN_DELAY_MS
	end

	return changed
end

function DynamicRoadMap:onLandscapingApplied(landscaping, errorCode)
	if not self.initialized
		or not self:getIsServer()
		or landscaping == nil
		or Landscaping == nil
		or TerrainDeformation == nil then
		return
	end

	if errorCode ~= TerrainDeformation.STATE_SUCCESS
		or landscaping.validateOnly
		or landscaping.sculptingOperation ~= Landscaping.OPERATION.PAINT then
		return
	end

	local layerIndex = landscaping.dynamicRoadMapTerrainPaintingLayer
	if layerIndex == nil then
		-- Не угадываем тип дороги: повторно строим таблицу terrain layers и
		-- оставляем NON_ROAD, если GIANTS не передал layerIndex.
		self:discoverRoadTerrainLayers()
		self:log("Warning: server paint completed without captured terrainPaintingLayer")
	end
	local roadValue = self:getRoadValueForTerrainPaintingLayer(layerIndex)

	-- Любая ручная PAINT-операция заменяет исходное состояние terrain. Поэтому
	-- в изменённой области legacy-слой всегда очищается: новая дорога остаётся
	-- в player-mask, а трава/грунт дают ROAD_VALUE_NONE. Так старый импорт не
	-- может перекрыть свежую покраску другим типом дороги.
	local clearLegacy = true
	local changed = self:applyPaintAreasToPlayerMask(landscaping.modifiedAreas, roadValue, true)
	changed = self:applyPaintAreasToLegacyMask(
		landscaping.modifiedAreas,
		self.LEGACY_VALUE_NONE,
		true
	) or changed

	if changed then
		local sourceConnection = self:getLandscapingSourceConnection(landscaping)
		if sourceConnection ~= nil then
			-- Для сетевого клиента копим все подтверждённые мазки до отпускания кисти.
			self:queueServerPaintBatch(
				sourceConnection,
				landscaping.modifiedAreas,
				roadValue,
				clearLegacy
			)
		else
			-- Серверная/скриптовая покраска без LandscapingSculptEvent не имеет
			-- клиентского release-сигнала, поэтому её отправляем сразу.
			self:broadcastPaintAreas(landscaping.modifiedAreas, roadValue, clearLegacy)
		end
	end

	self.loggedPaintLayers = self.loggedPaintLayers or {}
	local logKey = tostring(layerIndex) .. ":" .. tostring(roadValue)
	if not self.loggedPaintLayers[logKey] then
		self.loggedPaintLayers[logKey] = true
		local layerName = layerIndex ~= nil and getTerrainLayerName(g_terrainNode, layerIndex) or "nil"
		local roadType = roadValue == self.ROAD_VALUE_ASPHALT and "ASPHALT"
			or (roadValue == self.ROAD_VALUE_GRAVEL and "GRAVEL" or "NON_ROAD")
		self:log(
			"Landscaping paint captured directly: layer[%s]=%s -> %s",
			tostring(layerIndex), tostring(layerName), roadType
		)
	end
end

function DynamicRoadMap:startPendingDirtyScan()
	if not self:getIsServer() then
		return
	end

	local bounds = self.pendingDirtyBounds
	if bounds == nil or self.currentScan ~= nil then
		return
	end

	local minX, minY = self:worldToMask(bounds.minX, bounds.minZ)
	local maxX, maxY = self:worldToMask(bounds.maxX, bounds.maxZ)

	self.pendingDirtyBounds = nil
	self:startScan(minX, maxX, minY, maxY, "landscaping")
end

function DynamicRoadMap:syncOpenMapFrame()
	if g_inGameMenu ~= nil and g_inGameMenu.pageMapOverview ~= nil then
		local frame = g_inGameMenu.pageMapOverview
		self:setupRoadSelector(frame)

		-- If initialization happens while the map is already open on Roads,
		-- refresh through the stock list data source. Normal selector changes
		-- are handled entirely by InGameMenuMapFrame itself.
		if frame.mapOverviewSelector ~= nil
			and frame.filterList ~= nil
			and frame.mapOverviewSelector:getState() == self.MAP_ROADS_STATE then
			frame.filterList:reloadData(true)
		end
	end
end

function DynamicRoadMap:update(dt)
	self:installMapMenuHooks()
	self:installHooks()

	if not self.initialized then
		self:initialize()
		if not self.initialized then
			return
		end
	end

	self:updateOverlayState()

	-- Клиент не сканирует terrain, не формирует маски и не сохраняет их.
	-- Он только запрашивает/принимает серверное состояние и строит свой overlay.
	if not self:getIsServer() then
		-- После успешного full-sync networkSyncRequested снова становится false,
		-- поэтому одного этого флага недостаточно. Повторный запрос нужен только
		-- пока серверное состояние ещё не было получено.
		if not self.networkSyncReceived and not self.networkSyncRequested then
			self:requestNetworkSync()
		end

		if self.roadOverlayDirty and not self.roadOverlayGenerating then
			self:regenerateOverlay()
		end
		return
	end

	if self.currentScan ~= nil then
		self:processCurrentScan()
	end

	self:updateServerPaintBatches(dt)

	if self.pendingDirtyBounds ~= nil then
		self.pendingDirtyTimer = self.pendingDirtyTimer - dt
		if self.pendingDirtyTimer <= 0 and self.currentScan == nil then
			self:startPendingDirtyScan()
		end
	end

	if self.playerMaskChanged then
		self.playerMaskCommitTimer = self.playerMaskCommitTimer - dt
		if self.playerMaskCommitTimer <= 0 and self.currentScan == nil then
			self.playerMaskChanged = false
			self:requestOverlayRegeneration()
			self:saveRoadMask()
		end
	end

	if self.currentScan == nil
		and self.pendingDirtyBounds == nil
		and self.legacyImportRequested
		and not self.legacyImportCompleted then
		self:startLegacyImport()
	end

	if self.currentScan == nil
		and self.pendingDirtyBounds == nil
		and self.roadOverlayDirty
		and not self.roadOverlayGenerating then
		self:regenerateOverlay()
	end
end

function DynamicRoadMap:getLegacyScanProgress()
	local scan = self.currentScan
	if scan ~= nil and scan.reason == "legacyImport" and scan.total ~= nil and scan.total > 0 then
		return math.clamp(math.floor(scan.processed / scan.total * 100 + 0.5), 0, 100)
	end

	if self.legacyImportRequested and not self.legacyImportCompleted then
		return 0
	end

	return nil
end

function DynamicRoadMap:draw()
	if not self.initialized or not self:getIsServer() then
		return
	end

	local progress = self:getLegacyScanProgress()
	if progress == nil then
		return
	end

	-- Keep the notice independent of the normal HUD and map UI. The legacy
	-- import may take a noticeable amount of time on 4x/16x maps, so show a
	-- persistent centered message until the scan is actually complete.
	local boxX = 0.17
	local boxY = 0.455
	local boxW = 0.66
	local boxH = 0.095

	drawFilledRect(boxX, boxY, boxW, boxH, 0, 0, 0, 0.72)

	setTextAlignment(RenderText.ALIGN_CENTER)
	setTextColor(1, 1, 1, 1)
	setTextBold(true)
	renderText(0.5, 0.515, 0.023, self:getLocalizedText("scanWait"))

	setTextBold(false)
	renderText(0.5, 0.478, 0.019, string.format(self:getLocalizedText("scanProgress"), progress))

	setTextAlignment(RenderText.ALIGN_LEFT)
	setTextColor(1, 1, 1, 1)
end

function DynamicRoadMap:drawRoadOverlay(ingameMap)
	if not self.initialized
		or not self.roadOverlayReady
		or self.roadOverlay == nil
		or ingameMap == nil
		or ingameMap.layout == nil
		or (not self.showAsphalt and not self.showGravel and not self.showImported) then
		return
	end

	local width, height = ingameMap.layout:getMapSize()
	if width == 0 or height == 0 then
		return
	end

	local x, y = ingameMap.layout:getMapPosition()
	local pivotX, pivotY = ingameMap.layout:getMapPivot()
	local absolutePivotX = pivotX + x
	local absolutePivotY = pivotY + y

	local posX = x + width * ingameMap.mapExtensionOffsetX
	local posY = y + height * ingameMap.mapExtensionOffsetZ
	local rotationPivotX = absolutePivotX - posX
	local rotationPivotY = absolutePivotY - posY
	local sizeX = width * ingameMap.mapExtensionScaleFactor
	local sizeY = height * ingameMap.mapExtensionScaleFactor

	local clipped = false

	if ingameMap.clipX1 ~= nil then
		local u1, v1, u2, v2, u3, v3, u4, v4
		posX, posY, sizeX, sizeY, u1, v1, u2, v2, u3, v3, u4, v4 = Overlay.getClippingUVs(
			Overlay.DEFAULT_UVS,
			posX,
			posY,
			sizeX,
			sizeY,
			ingameMap.clipX1,
			ingameMap.clipY1,
			ingameMap.clipX2,
			ingameMap.clipY2
		)

		if u1 == nil then
			return
		end

		setOverlayUVs(self.roadOverlay, u1, v1, u2, v2, u3, v3, u4, v4)
		clipped = true
	end

	setOverlayRotation(
		self.roadOverlay,
		ingameMap.layout:getMapRotation(),
		rotationPivotX,
		rotationPivotY
	)

	local mapAlpha = ingameMap.layout:getMapAlpha()
	setOverlayColor(self.roadOverlay, 1, 1, 1, math.sqrt(mapAlpha) * self.OVERLAY_ALPHA)
	renderOverlay(self.roadOverlay, posX, posY, sizeX, sizeY)

	if clipped then
		setOverlayUVs(self.roadOverlay, unpack(Overlay.DEFAULT_UVS))
	end
end

-- Try to patch the menu as early as possible. update()/loadMap() retry if the class
-- is not yet available at extraSourceFiles load time.
DynamicRoadMap:installMapMenuHooks()

addModEventListener(DynamicRoadMap)

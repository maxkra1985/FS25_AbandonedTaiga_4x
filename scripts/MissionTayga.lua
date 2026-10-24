--[[
    Abandoned Taiga - MissionTayga

    Класс миссии карты. Наследует штатный Mission00 и служит центральной
    точкой для глобальных систем карты, которым нужен lifecycle миссии.
]]

MissionTayga = {}
local MissionTayga_mt = Class(MissionTayga, Mission00)

MissionTayga.MAX_NUM_TREES = 130000
MissionTayga.LICENSE_PLATE_FONTS_XML = "map/russianLicensePlates/fonts.xml"
MissionTayga.loggingContractorModulesLoaded = false


-- Загружает модули системы подрядчиков один раз при создании MissionTayga.
-- Сетевые Event-классы загружаются здесь до создания g_currentMission, потому
-- что GIANTS разрешает InitEventClass только на этапе компиляции скриптов.
function MissionTayga.loadLoggingContractorModules(baseDirectory)
    if MissionTayga.loggingContractorModulesLoaded then
        LoggingContractorDialog.setBaseDirectory(baseDirectory)
        return
    end

    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorJob.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/events/LoggingContractorResultEvent.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/events/LoggingContractorProgressEvent.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/events/LoggingContractorSyncRequestEvent.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/events/LoggingContractorStartEvent.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorDialog.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorTrigger.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractor.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorExecution.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorPersistence.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorRules.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorTreePhysics.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorTreeProcessing.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorOakChainsawRecorder.lua", baseDirectory))

    LoggingContractorDialog.setBaseDirectory(baseDirectory)
    MissionTayga.loggingContractorModulesLoaded = true
end


-- Загружает материалы русского шрифта перед штатной загрузкой конфигурации
-- номерных знаков. Сам licensePlates.xml полностью обрабатывает код GIANTS.
function MissionTayga.licensePlateManagerLoadMapData(manager, superFunc, xmlFile, missionInfo, baseDirectory)
    local fontsFilename = Utils.getFilename(MissionTayga.LICENSE_PLATE_FONTS_XML, baseDirectory)
    g_materialManager:loadFontMaterialsXML(fontsFilename, nil, baseDirectory)

    return superFunc(manager, xmlFile, missionInfo, baseDirectory)
end


-- Формирует собственные подписи вариантов российских номерных знаков.
function MissionTayga.licensePlateDialogUpdateVariations(dialog, superFunc)
    local texts = {}

    for i = 1, #dialog.licensePlate.variations do
        table.insert(texts, g_i18n:getText("ui_licensePlateType" .. i))
    end

    dialog.typeOption:setTexts(texts)
    dialog.typeOption:setState(dialog.currentVariation)
end


-- Возвращает допустимую область размещения номера для его формы и типа техники.
-- Значения перенесены без изменения из прежнего licensePlatesStandalone.lua.
function MissionTayga.getLicensePlatePlacementArea(vehicle, licensePlate)
    if licensePlate.preferedType == LicensePlateManager.PLATE_TYPE.ELONGATED then
        return {0.06, 0.265, 0.07, 0.265}
    end

    local hotspotType = vehicle.xmlFile:getValue("vehicle.base.mapHotspot#type", "OTHER")
    if licensePlate.preferedType == LicensePlateManager.PLATE_TYPE.SQUARISH
        and hotspotType ~= "TRUCK"
        and hotspotType ~= "CAR" then
        return {0.11, 0.15, 0.10, 0.15}
    end

    return {0.09, 0.15, 0.10, 0.15}
end


-- Применяет размеры номерного знака карты к уже созданному штатным
-- LicensePlates:onLoad объекту. Загрузка XML, objectChanges, savegame и сеть
-- при этом остаются полностью на стороне стандартного кода игры.
function MissionTayga.applyLicensePlatePlacement(vehicle, licensePlate)
    local data = licensePlate.data
    if data == nil or data.node == nil then
        return
    end

    local placementArea = MissionTayga.getLicensePlatePlacementArea(vehicle, licensePlate)
    licensePlate.placementArea = placementArea

    local widthPos = data.rawWidth * 0.5 + data.widthOffsetLeft
    local widthNeg = data.rawWidth * 0.5 + data.widthOffsetRight
    local heightPos = data.rawHeight * 0.5 + data.heightOffsetTop
    local heightNeg = data.rawHeight * 0.5 + data.heightOffsetBot

    local scaleFactorWidth = (placementArea[2] + placementArea[4]) / (widthPos + widthNeg)
    local scaleFactorHeight = (placementArea[1] + placementArea[3]) / (heightPos + heightNeg)
    local scaleFactor = math.clamp(math.min(scaleFactorWidth, scaleFactorHeight), 0, 1)

    -- setScale задаёт абсолютный масштаб и тем самым заменяет возможный масштаб,
    -- который штатный onLoad успел рассчитать по стандартной placementArea.
    setScale(data.node, scaleFactor, scaleFactor, scaleFactor)

    widthPos = widthPos * scaleFactor
    widthNeg = widthNeg * scaleFactor
    heightPos = heightPos * scaleFactor
    heightNeg = heightNeg * scaleFactor

    local moveX = -math.max(widthPos - placementArea[2], 0)
        + math.max(widthNeg - placementArea[4], 0)
    local moveY = -math.max(heightPos - placementArea[1], 0)
        + math.max(heightNeg - placementArea[3], 0)

    setTranslation(data.node, moveX, moveY, 0)
end


-- Сначала выполняет штатную загрузку LicensePlates, затем корректирует только
-- область размещения уже созданных российских номеров.
function MissionTayga.licensePlatesOnLoad(vehicle, superFunc, savegame)
    superFunc(vehicle, savegame)

    local spec = vehicle.spec_licensePlates
    if spec == nil or spec.licensePlates == nil then
        return
    end

    for _, licensePlate in ipairs(spec.licensePlates) do
        MissionTayga.applyLicensePlatePlacement(vehicle, licensePlate)
    end
end


-- Устанавливает hooks номерных знаков при создании MissionTayga.
-- Флаги нужны только как защита от повторного оборачивания функций,
-- если установка hooks будет вызвана более одного раза.
function MissionTayga.installLicensePlateHooks()
    if LicensePlateManager ~= nil and not LicensePlateManager.taigaMissionLoadMapDataHookInstalled then
        LicensePlateManager.loadMapData = Utils.overwrittenFunction(
            LicensePlateManager.loadMapData,
            MissionTayga.licensePlateManagerLoadMapData
        )
        LicensePlateManager.taigaMissionLoadMapDataHookInstalled = true
    end

    if LicensePlateDialog ~= nil and not LicensePlateDialog.taigaMissionVariationsHookInstalled then
        LicensePlateDialog.updateVariations = Utils.overwrittenFunction(
            LicensePlateDialog.updateVariations,
            MissionTayga.licensePlateDialogUpdateVariations
        )
        LicensePlateDialog.taigaMissionVariationsHookInstalled = true
    end

    if LicensePlates ~= nil and not LicensePlates.taigaMissionOnLoadHookInstalled then
        LicensePlates.onLoad = Utils.overwrittenFunction(
            LicensePlates.onLoad,
            MissionTayga.licensePlatesOnLoad
        )
        LicensePlates.taigaMissionOnLoadHookInstalled = true
    end

    Logging.info("[MissionTayga] License plate hooks installed")
end


-- Создаёт экземпляр миссии карты, загружает собственные модули и сохраняет
-- полный штатный lifecycle Mission00.
function MissionTayga.new(baseDirectory, customMt)
    MissionTayga.loadLoggingContractorModules(baseDirectory)
    MissionTayga.installLicensePlateHooks()

    -- Классы и обработчики рейтинга загружаем до запуска игровой миссии.
    if ContractRatingRuntime == nil then
        source(Utils.getFilename("scripts/ContractRatingSystem/ContractRatingLedger.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/events/ContractRatingSyncEvent.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/events/ContractRatingSyncRequestEvent.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/events/ContractRatingAccessDeniedEvent.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/ContractRatingAccess.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/ContractRatingRuntime.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/ContractSupplyRotation.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/ContractSupplyCalendar.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/TaigaSupplyMission.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/ContractSupplyStations.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/ContractSupplyVolumes.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/ContractSupplyEconomy.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/ContractSupplySeasonality.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/ContractSupplyCustomers.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/ContractDetailsLayout.lua", baseDirectory))
        source(Utils.getFilename("scripts/ContractRatingSystem/ContractSupplyUnload.lua", baseDirectory))
    end
    ContractRatingRuntime.installSaveHook()
    ContractSupplyCalendar.installSaveHook()
    if not ContractSupplyEconomy.loadConfig(baseDirectory) then
        Logging.warning("[ContractRating] Supply economy configuration invalid")
    end
    if not ContractSupplyVolumes.loadConfig(baseDirectory) then
        Logging.warning("[ContractRating] Supply volume configuration invalid")
    end
    ContractSupplyUnload.install()
    ContractDetailsLayout.install()
    -- Тип должен существовать до инициализации XML-схем менеджера миссий.
    if g_missionManager:getMissionType(TaigaSupplyMission.TYPE_NAME) == nil then
        g_missionManager:registerMissionType(TaigaSupplyMission, TaigaSupplyMission.TYPE_NAME, 3)
    end
    ContractRatingAccess.loadConfig(baseDirectory)
    ContractRatingAccess.install()

    -- Интервал попыток генерации контрактов: 30 игровых минут.
    MissionManager.MISSION_GENERATION_INTERVAL = 1800000
	
    local mission = MissionTayga:superClass().new(baseDirectory, customMt or MissionTayga_mt)
    -- Подключаем радиостанцию к конкретному SoundPlayer до регистрации
    -- пользовательских действий и до старта миссии.
    mission.taigaRadio = TaigaRadio.new(baseDirectory)
    mission.taigaRadio:install()

    -- Реестр подвижных приёмников наполняется только после загрузки map.i3d.
    mission.taigaRadioMapReceivers = TaigaRadioMapReceivers.new(mission)
    return mission
end


-- Регистрирует ровно три переносных радио как сетевые PhysicsObject.
-- Штатная findDynamicObjects продолжает обслуживать остальные объекты карты.
-- Кратковременная смена типа нужна, чтобы базовая функция не удалила
-- их динамическую физику при отсутствии mpCreatePhysicsObject в I3D.
function MissionTayga:findDynamicObjects(node)
    if not self.missionDynamicInfo.isMultiplayer then
        return MissionTayga:superClass().findDynamicObjects(self, node)
    end

    local radios = {}
    for i = 0, getNumOfChildren(node) - 1 do
        local child = getChildAt(node, i)
        if getRigidBodyType(child) == RigidBodyType.DYNAMIC
            and getUserAttribute(child, "mpCreatePhysicsObject") ~= true then
            local body, display, trigger = TaigaRadioMapReceivers.findModelNodes(child)
            if body ~= nil and display ~= nil and trigger ~= nil then
                setRigidBodyType(child, RigidBodyType.KINEMATIC)
                radios[#radios + 1] = child
            end
        end
    end

    MissionTayga:superClass().findDynamicObjects(self, node)

    for _, child in ipairs(radios) do
        local object = PhysicsObject.new(self:getIsServer(), self:getIsClient())
        self.onCreateObjectSystem:add(object)
        object:loadOnCreate(child)
        object:register(true)
        Logging.info("[TaigaRadio] Сетевая физика приёмника зарегистрирована: %s", getName(child))
    end
end


-- Получает от стандартного загрузчика готовый корневой узел map.i3d.
-- Обнаружение динамических приёмников не требует правки большого I3D-файла.
function MissionTayga:loadMission00Finished(node, arguments)
    if not self.cancelLoading and self.taigaRadioMapReceivers ~= nil then
        self.taigaRadioMapReceivers:discover(node)
    end

    MissionTayga:superClass().loadMission00Finished(self, node, arguments)
end


-- Запускает миссию, применяет увеличенный лимит деревьев и после штатного
-- запуска регистрирует систему подрядчиков на лесоповал.
function MissionTayga:onStartMission()
    if g_treePlantManager ~= nil then
        g_treePlantManager.maxNumTrees = MissionTayga.MAX_NUM_TREES
        Logging.info("Лимит деревьев установлен в 130 000")
    else
        Logging.warning("MissionTayga: g_treePlantManager не найден")
    end

    MissionTayga:superClass().onStartMission(self)

    -- После полной клиентской загрузки повторяем запрос снимка состояния.
    -- Повторное состояние не перезапускает уже звучащий трек.
    if self:getIsClient() and not self:getIsServer() then
        TaigaRadioMapReceiverEvent.requestSnapshot()
    end

    self.loggingContractor = LoggingContractor.new(self)
    self.loggingContractor:initialize()
    self.loggingContractor:loadFromSavegame()

    -- Рейтинг загружается только на сервере, результаты обрабатываются после старта.
    self.contractRatingRuntime = ContractRatingRuntime.new(self)
    self.contractRatingRuntime:start()
    -- К этому моменту типы продукции карты и сторонних модов уже зарегистрированы.
    if not ContractSupplySeasonality.loadConfig(self.baseDirectory) then
        Logging.warning("[ContractRating] Seasonal product configuration invalid after map load")
    end
    if not ContractSupplyCustomers.loadConfig(self.baseDirectory) then
        Logging.warning("[ContractRating] Supply customer configuration invalid")
    end
    self.contractSupplyCalendar = ContractSupplyCalendar.new(self)
    self.contractSupplyCalendar:start()
    -- GUI может загрузиться позднее конструктора миссии.
    if not ContractDetailsLayout.install() then
        Logging.info("[ContractRating] Contracts GUI hook not installed at mission start")
    end
    if self:getIsClient() and not self:getIsServer() then
        ContractRatingSyncRequestEvent.sendEvent()
    end
end


-- Отдаёт новому игроку текущее состояние радио в штатной фазе синхронизации.
function MissionTayga:sendInitialClientState(connection, user, farm)
    MissionTayga:superClass().sendInitialClientState(self, connection, user, farm)
    if self.taigaRadioMapReceivers ~= nil then
        self.taigaRadioMapReceivers:sendSnapshot(connection)
    end
end


-- После штатной отправки split-shape update открывает подрядчику следующий
-- сетевой шаг изменения древесины.
function MissionTayga:onConnectionsUpdateTick(dt)
    MissionTayga:superClass().onConnectionsUpdateTick(self, dt)

    if self.loggingContractor ~= nil then
        self.loggingContractor:onNetworkUpdateTick()
    end
end


-- Передаёт серверный update в систему подрядчиков после штатного update миссии.
function MissionTayga:update(dt)
    MissionTayga:superClass().update(self, dt)

    if self.loggingContractor ~= nil then
        self.loggingContractor:update(dt)
    end

    if self.taigaRadioMapReceivers ~= nil then
        self.taigaRadioMapReceivers:update(dt)
    end
end


-- Рисует штатный HUD, затем поверх него компактный прогресс активных договоров.
function MissionTayga:draw()
    MissionTayga:superClass().draw(self)

    if self.loggingContractor ~= nil then
        self.loggingContractor:draw()
    end
end


-- Освобождает ресурсы собственных систем карты перед удалением Mission00.
function MissionTayga:delete()
    if self.contractSupplyCalendar ~= nil then
        self.contractSupplyCalendar:delete()
        self.contractSupplyCalendar = nil
    end

    if self.contractRatingRuntime ~= nil then
        self.contractRatingRuntime:delete()
        self.contractRatingRuntime = nil
    end

    if self.loggingContractor ~= nil then
        self.loggingContractor:delete()
        self.loggingContractor = nil
    end

    if self.taigaRadioMapReceivers ~= nil then
        self.taigaRadioMapReceivers:delete()
        self.taigaRadioMapReceivers = nil
    end

    if self.taigaRadio ~= nil then
        self.taigaRadio:delete()
        self.taigaRadio = nil
    end

    MissionTayga:superClass().delete(self)
end

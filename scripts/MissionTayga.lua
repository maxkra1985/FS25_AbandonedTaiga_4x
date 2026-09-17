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
    source(Utils.getFilename("scripts/loggingContractor/events/LoggingContractorStartEvent.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorDialog.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorTrigger.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractor.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorExecution.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorTreePhysics.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorBranchFix.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorTrunkScan.lua", baseDirectory))
    source(Utils.getFilename("scripts/loggingContractor/LoggingContractorVisualFix.lua", baseDirectory))

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

    return MissionTayga:superClass().new(baseDirectory, customMt or MissionTayga_mt)
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

    self.loggingContractor = LoggingContractor.new(self)
    self.loggingContractor:initialize()
end


-- Передаёт серверный update в систему подрядчиков после штатного update миссии.
function MissionTayga:update(dt)
    MissionTayga:superClass().update(self, dt)

    if self.loggingContractor ~= nil then
        self.loggingContractor:update(dt)
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
    if self.loggingContractor ~= nil then
        self.loggingContractor:delete()
        self.loggingContractor = nil
    end

    MissionTayga:superClass().delete(self)
end
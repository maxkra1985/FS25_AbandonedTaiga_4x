--[[
    Abandoned Taiga - MissionTayga

    Класс миссии карты. Наследует штатный Mission00 и служит центральной
    точкой для глобальных систем карты, которым нужен lifecycle миссии.
]]

MissionTayga = {}
local MissionTayga_mt = Class(MissionTayga, Mission00)

MissionTayga.MAX_NUM_TREES = 130000
MissionTayga.LICENSE_PLATE_FONTS_XML = "map/russianLicensePlates/fonts.xml"
MissionTayga.LICENSE_PLATE_FONT_NAME = "LICENSE_PLATE_RUS"


-- Проверяет, относится ли текущий LicensePlateManager к этой карте.
-- Hooks остаются установленными до завершения игры, поэтому проверка не даёт
-- настройкам Тайги повлиять на другую карту, загруженную в той же сессии.
function MissionTayga.isCurrentLicensePlateContext()
    return g_licensePlateManager ~= nil
        and MissionTayga.baseDirectory ~= nil
        and g_licensePlateManager.baseDirectory == MissionTayga.baseDirectory
        and g_licensePlateManager.fontName == MissionTayga.LICENSE_PLATE_FONT_NAME
end


-- Загружает материалы русского шрифта перед штатной загрузкой конфигурации
-- номерных знаков. Сам licensePlates.xml полностью обрабатывает код GIANTS.
function MissionTayga.licensePlateManagerLoadMapData(manager, superFunc, xmlFile, missionInfo, baseDirectory)
    if baseDirectory == MissionTayga.baseDirectory then
        local fontsFilename = Utils.getFilename(MissionTayga.LICENSE_PLATE_FONTS_XML, baseDirectory)
        g_materialManager:loadFontMaterialsXML(fontsFilename, nil, baseDirectory)
    end

    return superFunc(manager, xmlFile, missionInfo, baseDirectory)
end


-- Формирует подписи вариантов российских номерных знаков.
-- Для остальных карт используется штатная реализация LicensePlateDialog.
function MissionTayga.licensePlateDialogUpdateVariations(dialog, superFunc)
    if not MissionTayga.isCurrentLicensePlateContext() then
        return superFunc(dialog)
    end

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


-- Применяет тайговые размеры номерного знака к уже созданному штатным
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

    if not MissionTayga.isCurrentLicensePlateContext() then
        return
    end

    local spec = vehicle.spec_licensePlates
    if spec == nil or spec.licensePlates == nil then
        return
    end

    for _, licensePlate in ipairs(spec.licensePlates) do
        MissionTayga.applyLicensePlatePlacement(vehicle, licensePlate)
    end
end


-- Устанавливает глобальные hooks номерных знаков один раз за игровую сессию.
-- Флаги хранятся на штатных классах, поэтому повторная загрузка карты не
-- оборачивает одни и те же функции повторно.
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


-- Создаёт экземпляр миссии карты, сохраняя полный штатный lifecycle Mission00.
function MissionTayga.new(baseDirectory, customMt)
    MissionTayga.baseDirectory = baseDirectory
    MissionTayga.installLicensePlateHooks()

    return MissionTayga:superClass().new(baseDirectory, customMt or MissionTayga_mt)
end


-- Запускает миссию и до штатного события CURRENT_MISSION_START применяет
-- увеличенный лимит деревьев карты. Благодаря этому TreePlantManager и другие
-- подписчики события сразу получают окончательное значение лимита.
function MissionTayga:onStartMission()
    if g_treePlantManager ~= nil then
        g_treePlantManager.maxNumTrees = MissionTayga.MAX_NUM_TREES
        Logging.info("Лимит деревьев установлен в 130 000")
    else
        Logging.warning("MissionTayga: g_treePlantManager не найден")
    end

    MissionTayga:superClass().onStartMission(self)
end

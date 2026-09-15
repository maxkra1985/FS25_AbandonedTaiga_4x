--[[
    Abandoned Taiga - Construction Info HUD
    FS25

    Формирует контекстное информационное меню производственных и constructible-placeable.
    Основной specialization-hook устанавливает координатор, а этот модуль дополнительно
    подменяет штатный ProductionPoint:updateInfo(), чтобы единый секционный HUD работал
    для всех производств, в том числе без ObjectStorage.
]]

TaigaConstructionInfoHUD = TaigaConstructionInfoHUD or {}
local HUD = TaigaConstructionInfoHUD

HUD.VERSION = "1.0.3"
HUD.LOG_PREFIX = "[TaigaConstructionInfoHUD]"

HUD.L10N_PRODUCTION = "taiga_cl_infoProduction"
HUD.L10N_PRODUCTION_STORAGE = "taiga_cl_infoProductionStorage"
HUD.L10N_WAREHOUSE_STORAGE = "taiga_cl_infoWarehouseStorage"
HUD.L10N_OBJECT = "taiga_cl_infoObject"

-- Геометрия строки штатного InfoDisplayKeyValueBox:
-- 340 px ширина блока - 30 px левый отступ - 14 px правый отступ.
HUD.CONSTRUCTION_STATE_TEXT_SIZE_PX = 14
HUD.CONSTRUCTION_STATE_MAX_WIDTH_PX = 296

local function getLifecycle()
    return TaigaConstructionLifecycle
end

-- Возвращает пользовательскую строку подсистемы, пока отсутствующий ключ
-- безопасно подменяется штатным текстом GIANTS. Собственные RU/EN/DE ключи
-- добавляются в языковые XML отдельно от логики HUD.
local function getText(customKey, fallbackKey, hardFallback)
    if g_i18n ~= nil then
        if customKey ~= nil and g_i18n:hasText(customKey) then
            return g_i18n:getText(customKey)
        end

        if fallbackKey ~= nil and g_i18n:hasText(fallbackKey) then
            return g_i18n:getText(fallbackKey)
        end
    end

    return hardFallback
end

local function addSection(infoTable, title)
    table.insert(infoTable, {
        title = title,
        accentuate = true
    })
end

-- Разбивает текст по словам с учётом фактической ширины шрифта GIANTS.
-- Если отдельное слово само шире доступной строки, оно делится по UTF-8 символам.
function HUD.wrapTextToWidth(text, textSize, maxWidth)
    local value = tostring(text or "")
    if value == ""
        or type(textSize) ~= "number"
        or type(maxWidth) ~= "number"
        or maxWidth <= 0 then
        return {value}
    end

    local lines = {}
    local currentLine = ""

    local function flushCurrentLine()
        if currentLine ~= "" then
            table.insert(lines, currentLine)
            currentLine = ""
        end
    end

    -- Помещает слишком длинное одиночное слово в несколько строк без потери текста.
    local function appendLongWord(word)
        local remaining = word

        while remaining ~= "" and getTextWidth(textSize, remaining) > maxWidth do
            local fitLength = getTextLineLength(textSize, remaining, maxWidth)
            if fitLength == nil or fitLength <= 0 then
                fitLength = 1
            end

            table.insert(lines, utf8Substr(remaining, 0, fitLength))
            remaining = utf8Substr(remaining, fitLength) or ""
        end

        currentLine = remaining
    end

    for word in string.gmatch(value, "%S+") do
        if currentLine == "" then
            if getTextWidth(textSize, word) <= maxWidth then
                currentLine = word
            else
                appendLongWord(word)
            end
        else
            local candidate = currentLine .. " " .. word
            if getTextWidth(textSize, candidate) <= maxWidth then
                currentLine = candidate
            else
                flushCurrentLine()

                if getTextWidth(textSize, word) <= maxWidth then
                    currentLine = word
                else
                    appendLongWord(word)
                end
            end
        end
    end

    flushCurrentLine()

    if #lines == 0 then
        table.insert(lines, value)
    end

    return lines
end

-- Возвращает реальные экранные размеры строки InfoDisplay для текущего UI scale.
local function getConstructionStateTextMetrics()
    local infoDisplay = g_currentMission ~= nil
        and g_currentMission.hud ~= nil
        and g_currentMission.hud.infoDisplay
        or nil

    if infoDisplay == nil
        or type(infoDisplay.scalePixelToScreenHeight) ~= "function"
        or type(infoDisplay.scalePixelToScreenWidth) ~= "function" then
        return nil, nil
    end

    return infoDisplay:scalePixelToScreenHeight(HUD.CONSTRUCTION_STATE_TEXT_SIZE_PX),
        infoDisplay:scalePixelToScreenWidth(HUD.CONSTRUCTION_STATE_MAX_WIDTH_PX)
end

local function normalizeFillTypeIndex(value)
    if type(value) == "number" then
        local fillType = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByIndex(value) or nil
        return fillType ~= nil and value or nil
    end

    if type(value) == "table" and type(value.index) == "number" then
        local fillType = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByIndex(value.index) or nil
        return fillType ~= nil and value.index or nil
    end

    return nil
end

local function normalizeFilename(filename)
    if filename == nil then
        return nil
    end

    return string.lower(string.gsub(tostring(filename), "\\", "/"))
end

local function getFilenameBasename(filename)
    filename = normalizeFilename(filename)
    if filename == nil then
        return nil
    end

    return string.match(filename, "([^/]+)$") or filename
end

local function getAbstractObjectFilename(abstractObject)
    if abstractObject == nil then
        return nil
    end

    if abstractObject.palletAttributes ~= nil then
        local filename = abstractObject.palletAttributes.configFileName
            or abstractObject.palletAttributes.xmlFilename
        if filename ~= nil then
            return filename
        end
    end

    if abstractObject.baleAttributes ~= nil and abstractObject.baleAttributes.xmlFilename ~= nil then
        return abstractObject.baleAttributes.xmlFilename
    end

    if type(abstractObject.getXMLFilename) == "function" then
        local ok, filename = pcall(abstractObject.getXMLFilename, abstractObject)
        if ok then
            return filename
        end
    end

    return abstractObject.configFileName or abstractObject.xmlFilename
end

-- Возвращает канонический fillType абстрактного объекта ObjectStorage.
-- Сначала читаются поля, реально используемые штатными AbstractPalletObject и
-- AbstractBaleObject; filename-сопоставление оставлено только последним fallback.
function HUD.getAbstractObjectFillTypeIndex(placeable, abstractObject)
    if abstractObject == nil or g_fillTypeManager == nil then
        return nil
    end

    -- PlaceableObjectStorage.AbstractPalletObject хранит тип продукта здесь.
    if abstractObject.palletAttributes ~= nil then
        local index = normalizeFillTypeIndex(abstractObject.palletAttributes.fillType)
        if index ~= nil then
            return index
        end
    end

    -- AbstractBaleObject после абстрагирования тюка хранит те же данные в baleAttributes.
    if abstractObject.baleAttributes ~= nil then
        local index = normalizeFillTypeIndex(abstractObject.baleAttributes.fillType)
        if index ~= nil then
            return index
        end
    end

    -- Пока реальный тюк ещё существует, штатный объект позволяет получить тип напрямую.
    if abstractObject.baleObject ~= nil and type(abstractObject.baleObject.getFillType) == "function" then
        local ok, value = pcall(abstractObject.baleObject.getFillType, abstractObject.baleObject)
        if ok then
            local index = normalizeFillTypeIndex(value)
            if index ~= nil then
                return index
            end
        end
    end

    -- Поддержка сторонних abstract object классов с обычными полями/методами.
    local directFields = {"fillTypeIndex", "fillTypeId", "fillType"}
    for _, fieldName in ipairs(directFields) do
        local index = normalizeFillTypeIndex(abstractObject[fieldName])
        if index ~= nil then
            return index
        end
    end

    local methodNames = {"getFillTypeIndex", "getFillType"}
    for _, methodName in ipairs(methodNames) do
        local method = abstractObject[methodName]
        if type(method) == "function" then
            local ok, value = pcall(method, abstractObject)
            if ok then
                local index = normalizeFillTypeIndex(value)
                if index ~= nil then
                    return index
                end
            end
        end
    end

    -- Последний fallback для паллет: сопоставление XML с palletFilename fillType.
    local objectFilename = normalizeFilename(getAbstractObjectFilename(abstractObject))
    if objectFilename == nil then
        return nil
    end

    local objectBasename = getFilenameBasename(objectFilename)
    local function matchesFillType(fillTypeIndex)
        local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillType == nil or fillType.palletFilename == nil then
            return false
        end

        local palletFilename = normalizeFilename(fillType.palletFilename)
        return palletFilename == objectFilename
            or getFilenameBasename(palletFilename) == objectBasename
    end

    local objectStorageSpec = placeable ~= nil and placeable.spec_objectStorage or nil
    if objectStorageSpec ~= nil and objectStorageSpec.supportedFillTypes ~= nil then
        for _, fillTypeIndex in ipairs(objectStorageSpec.supportedFillTypes) do
            if matchesFillType(fillTypeIndex) then
                return fillTypeIndex
            end
        end
    end

    if g_fillTypeManager.fillTypes ~= nil then
        for key, fillType in pairs(g_fillTypeManager.fillTypes) do
            local fillTypeIndex = type(fillType) == "table" and fillType.index or key
            if type(fillTypeIndex) == "number" and matchesFillType(fillTypeIndex) then
                return fillTypeIndex
            end
        end
    end

    return nil
end

local function getAbstractObjectDialogTitle(abstractObject)
    if abstractObject ~= nil and type(abstractObject.getDialogText) == "function" then
        local ok, title = pcall(abstractObject.getDialogText, abstractObject)
        if ok and title ~= nil and title ~= "" then
            title = tostring(title)
            if utf8Strlen(title) > 32 then
                title = utf8Substr(title, 0, 32) .. "..."
            end
            return title
        end
    end

    return getText(HUD.L10N_OBJECT, nil, "Object")
end

-- Возвращает стабильный ключ группы склада. Для известных паллет/тюков это fillType;
-- для сторонних объектов — класс+XML, поэтому разный fillLevel не дробит одну позицию.
local function getObjectStorageGroupKey(abstractObject, fillTypeIndex)
    if fillTypeIndex ~= nil then
        return "fillType:" .. tostring(fillTypeIndex)
    end

    local className = abstractObject ~= nil and abstractObject.REFERENCE_CLASS_NAME or nil
    local filename = normalizeFilename(getAbstractObjectFilename(abstractObject))
    if className ~= nil or filename ~= nil then
        return string.format("object:%s:%s", tostring(className or ""), tostring(filename or ""))
    end

    return "title:" .. getAbstractObjectDialogTitle(abstractObject)
end

-- Проверяет наличие штатного ProductionPoint у placeable.
function HUD.isProductionPlaceable(placeable)
    if placeable == nil then
        return false
    end

    local productionSpec = placeable.spec_productionPoint
    return productionSpec ~= nil and productionSpec.productionPoint ~= nil
end

-- Проверяет составной объект ProductionPoint + ObjectStorage без привязки к XML filename/type.
function HUD.isProductionObjectStorageComposite(placeable)
    return HUD.isProductionPlaceable(placeable)
        and placeable.spec_objectStorage ~= nil
end

-- Единый производственный HUD используется для любого обычного ProductionPoint сразу,
-- а для constructible-производства — только после полного завершения строительства.
function HUD.useFinishedProductionInfo(placeable)
    if not HUD.isProductionPlaceable(placeable) then
        return false
    end

    if placeable.spec_constructible == nil then
        return true
    end

    local lifecycle = getLifecycle()
    return lifecycle ~= nil and lifecycle.isFinished(placeable)
end

-- Составной HUD отличается от обычного производства только дополнительным ObjectStorage.
function HUD.useFinishedCompositeInfo(placeable)
    return HUD.useFinishedProductionInfo(placeable)
        and HUD.isProductionObjectStorageComposite(placeable)
end

-- Во время строительства любая будущая специализация должна пропустить собственные строки HUD.
function HUD.shouldSuppressFutureFacilityInfo(placeable)
    local lifecycle = getLifecycle()
    return placeable ~= nil
        and placeable.spec_constructible ~= nil
        and lifecycle ~= nil
        and lifecycle.isUnderConstruction(placeable)
end

local function addOwnerInfo(productionPoint, infoTable)
    if productionPoint == nil or g_farmManager == nil then
        return
    end

    local ownerFarm = g_farmManager:getFarmById(productionPoint:getOwnerFarmId())
    if ownerFarm ~= nil and not string.isNilOrWhitespace(ownerFarm.name) then
        table.insert(infoTable, {
            title = g_i18n:getText("fieldInfo_ownedBy"),
            text = ownerFarm.name
        })
    end
end

local function addProductionInfo(productionPoint, infoTable)
    addSection(
        infoTable,
        getText(HUD.L10N_PRODUCTION, "infohud_activeProductions", "Production")
    )

    local activeProductions = productionPoint.activeProductions or {}
    if #activeProductions == 0 then
        if productionPoint.infoTables ~= nil and productionPoint.infoTables.noActiveProd ~= nil then
            table.insert(infoTable, productionPoint.infoTables.noActiveProd)
        else
            table.insert(infoTable, {
                title = "",
                text = g_i18n:getText("infohud_noActiveProduction")
            })
        end
        return
    end

    -- Формат строки и статус совпадают со штатным ProductionPoint:updateInfo().
    for _, production in ipairs(activeProductions) do
        local status = productionPoint:getProductionStatus(production.id)
        local statusKey = ProductionPoint.PROD_STATUS_TO_L10N[status]
        local statusText = statusKey ~= nil and g_i18n:getText(statusKey) or tostring(status or "")

        table.insert(infoTable, {
            title = production.name
                or g_fillTypeManager:getFillTypeTitleByIndex(production.primaryProductFillType),
            text = statusText
        })
    end
end

local function addProductionStorageInfo(productionPoint, infoTable)
    addSection(
        infoTable,
        getText(HUD.L10N_PRODUCTION_STORAGE, "ui_productions_buildingStorage", "Production storage")
    )

    local displayed = false
    local displayedFillTypes = {}

    local function addFillType(fillTypeIndex)
        if fillTypeIndex == nil or displayedFillTypes[fillTypeIndex] then
            return
        end
        displayedFillTypes[fillTypeIndex] = true

        local fillLevel = productionPoint:getFillLevel(fillTypeIndex)
        if fillLevel ~= nil and fillLevel > 1 then
            table.insert(infoTable, {
                title = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex),
                text = g_i18n:formatVolume(fillLevel, 0)
            })
            displayed = true
        end
    end

    for _, fillTypeIndex in ipairs(productionPoint.inputFillTypeIdsArray or {}) do
        addFillType(fillTypeIndex)
    end
    for _, fillTypeIndex in ipairs(productionPoint.outputFillTypeIdsArray or {}) do
        addFillType(fillTypeIndex)
    end

    if not displayed then
        if productionPoint.infoTables ~= nil and productionPoint.infoTables.storageEmpty ~= nil then
            table.insert(infoTable, productionPoint.infoTables.storageEmpty)
        else
            table.insert(infoTable, {
                title = "",
                text = g_i18n:getText("infohud_storageIsEmpty")
            })
        end
    end

    if productionPoint.palletLimitReached
        and productionPoint.infoTables ~= nil
        and productionPoint.infoTables.palletLimitReached ~= nil then
        table.insert(infoTable, productionPoint.infoTables.palletLimitReached)
    end
end

local function addObjectStorageInfo(placeable, infoTable)
    local spec = placeable.spec_objectStorage
    if spec == nil then
        return
    end

    local storageTitle = getText(HUD.L10N_WAREHOUSE_STORAGE, "statistic_storage", "Warehouse storage")
    addSection(
        infoTable,
        string.format(
            "%s (%d / %d)",
            storageTitle,
            spec.numStoredObjects or 0,
            spec.capacity or 0
        )
    )

    local groupedEntries = {}
    local groupedByKey = {}

    for _, objectInfo in ipairs(spec.objectInfos or {}) do
        local abstractObject = objectInfo ~= nil
            and objectInfo.objects ~= nil
            and objectInfo.objects[1]
            or nil

        if abstractObject ~= nil then
            local fillTypeIndex = HUD.getAbstractObjectFillTypeIndex(placeable, abstractObject)
            local title = fillTypeIndex ~= nil
                and g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)
                or getAbstractObjectDialogTitle(abstractObject)
            local groupKey = getObjectStorageGroupKey(abstractObject, fillTypeIndex)
            local count = objectInfo.numObjects or #objectInfo.objects

            local groupedEntry = groupedByKey[groupKey]
            if groupedEntry == nil then
                groupedEntry = {
                    title = title,
                    count = 0
                }
                groupedByKey[groupKey] = groupedEntry
                table.insert(groupedEntries, groupedEntry)
            end

            groupedEntry.count = groupedEntry.count + count
        end
    end

    local maxEntries = PlaceableObjectStorage ~= nil
        and PlaceableObjectStorage.MAX_HUD_INFO_ENTRIES
        or #groupedEntries
    local displayedEntries = math.min(#groupedEntries, maxEntries)

    for index = 1, displayedEntries do
        local entry = groupedEntries[index]
        table.insert(infoTable, {
            title = entry.title,
            text = tostring(entry.count)
        })
    end

    if #groupedEntries > maxEntries then
        local others = 0
        for index = maxEntries + 1, #groupedEntries do
            others = others + groupedEntries[index].count
        end

        table.insert(infoTable, {
            title = spec.texts ~= nil and spec.texts.otherElements
                or getText(nil, "helpLine_IconOverview_Others", "Other"),
            text = tostring(others)
        })
    end
end

-- Добавляет единый HUD готового ProductionPoint:
-- владелец -> производство -> производственное хранилище.
function HUD.addFinishedProductionInfo(placeable, infoTable)
    if type(infoTable) ~= "table" or not HUD.useFinishedProductionInfo(placeable) then
        return false
    end

    local productionPoint = placeable.spec_productionPoint.productionPoint
    addOwnerInfo(productionPoint, infoTable)
    addProductionInfo(productionPoint, infoTable)
    addProductionStorageInfo(productionPoint, infoTable)

    return true
end

-- Добавляет HUD готового ProductionPoint + ObjectStorage. Производственная часть
-- полностью совпадает с обычным производством, склад объектов идёт отдельным разделом ниже.
function HUD.addFinishedCompositeInfo(placeable, infoTable)
    if type(infoTable) ~= "table" or not HUD.useFinishedCompositeInfo(placeable) then
        return false
    end

    HUD.addFinishedProductionInfo(placeable, infoTable)
    addObjectStorageInfo(placeable, infoTable)

    return true
end

-- Подменяет штатный ProductionPoint:updateInfo() для производств без ObjectStorage.
-- Составные ProductionPoint + ObjectStorage по-прежнему собираются координатором
-- одним блоком, поэтому здесь они намеренно пропускаются во избежание дублирования.
function HUD.installProductionPointInfoHook()
    if ProductionPoint == nil
        or ProductionPoint.updateInfo == nil
        or ProductionPoint.taigaConstructionInfoHUDInstalled then
        return false
    end

    local originalUpdateInfo = ProductionPoint.updateInfo
    ProductionPoint.updateInfo = function(productionPoint, infoTable)
        local placeable = productionPoint ~= nil and productionPoint.owningPlaceable or nil

        if HUD.useFinishedProductionInfo(placeable)
            and not HUD.isProductionObjectStorageComposite(placeable) then
            HUD.addFinishedProductionInfo(placeable, infoTable)
            return
        end

        return originalUpdateInfo(productionPoint, infoTable)
    end

    ProductionPoint.taigaConstructionInfoHUDInstalled = true
    return true
end

-- Перехватывает только уведомления, сформированные ConstructionLifecycleFix.
-- Убирает повтор названия объекта и использует обе штатные строки TopNotification.
function HUD.gameNotificationLayout(mission, superFunc, title, text, info, iconFilename, duration)
    local fix = TaigaConstructionLifecycleFix
    local titleText = title ~= nil and tostring(title) or nil
    local prefix = titleText ~= nil and titleText ~= "" and titleText .. ": " or nil

    local isConstructionNotification = fix ~= nil
        and duration == fix.NOTIFICATION_DURATION_MS
        and info == ""
        and iconFilename == nil
        and type(text) == "string"
        and prefix ~= nil
        and string.sub(text, 1, #prefix) == prefix

    if not isConstructionNotification then
        return superFunc(mission, title, text, info, iconFilename, duration)
    end

    local notificationText = string.sub(text, #prefix + 1)
    local upperText = utf8ToUpper(notificationText)
    local topNotification = mission ~= nil
        and mission.hud ~= nil
        and mission.hud.topNotification
        or nil

    if topNotification == nil
        or topNotification.bgScale == nil
        or type(topNotification.textSize) ~= "number"
        or type(topNotification.infoTextSize) ~= "number"
        or type(topNotification.bgScale.width) ~= "number" then
        return superFunc(mission, title, notificationText, "", iconFilename, duration)
    end

    -- text и info в штатном TopNotification имеют одинаковую доступную ширину.
    -- Берём больший размер шрифта, чтобы обе получившиеся строки гарантированно помещались.
    local wrapTextSize = math.max(topNotification.textSize, topNotification.infoTextSize)
    local lines = HUD.wrapTextToWidth(upperText, wrapTextSize, topNotification.bgScale.width)
    local firstLine = lines[1] or upperText
    local secondLine = ""

    if #lines > 1 then
        secondLine = table.concat(lines, " ", 2)
    end

    return superFunc(mission, title, firstLine, secondLine, iconFilename, duration)
end

-- Устанавливает layout-hook до загрузки координатора. Сам фильтр проверяется
-- в момент показа уведомления, когда ConstructionLifecycleFix уже существует.
function HUD.installConstructionNotificationLayoutHook()
    if BaseMission == nil
        or BaseMission.addGameNotification == nil
        or BaseMission.taigaConstructionNotificationLayoutInstalled then
        return false
    end

    BaseMission.addGameNotification = Utils.overwrittenFunction(
        BaseMission.addGameNotification,
        HUD.gameNotificationLayout
    )

    BaseMission.taigaConstructionNotificationLayoutInstalled = true
    return true
end

-- Добавляет только сведения строительной части объекта. Никакая production/husbandry/
-- silo/objectStorage специализация здесь намеренно не вызывается.
function HUD.addConstructionInfo(placeable, infoTable)
    if type(infoTable) ~= "table" then
        return false
    end

    local lifecycle = getLifecycle()
    local spec = placeable ~= nil and placeable.spec_constructible or nil
    if lifecycle == nil or spec == nil or not lifecycle.isUnderConstruction(placeable) then
        return false
    end

    local finishedStates, totalStates = lifecycle.getConstructionProgress(placeable)
    if finishedStates < totalStates then
        local progressText = string.format("(%d / %d)", finishedStates, totalStates)
        local stateName = lifecycle.getConfiguredStateDisplayName(placeable, spec.stateIndex)

        -- Прогресс оставляем в штатной строке, чтобы короткое числовое значение
        -- не пересекалось с длинным пользовательским названием строительного этапа.
        table.insert(infoTable, {
            title = g_i18n:getText("ui_construction_state"),
            text = progressText
        })

        -- Название этапа, если оно задано через #StateName, переносится по фактической
        -- ширине штатного InfoDisplay. Каждая часть становится отдельной строкой,
        -- поэтому высота блока автоматически увеличивается штатным кодом GIANTS.
        if stateName ~= nil then
            local textSize, maxWidth = getConstructionStateTextMetrics()
            local lines = textSize ~= nil and maxWidth ~= nil
                and HUD.wrapTextToWidth(stateName, textSize, maxWidth)
                or {stateName}

            for _, line in ipairs(lines) do
                table.insert(infoTable, {
                    title = line
                })
            end
        end
    end

    -- Показываем только отдельное хранилище строительных материалов.
    -- В отличие от vanilla лимит в 7 строк здесь не используется: карта содержит
    -- этапы с большим количеством разных строительных fillType.
    local storageEntries = {}
    if spec.storage ~= nil then
        for fillTypeIndex, fillLevel in pairs(spec.storage:getFillLevels()) do
            if fillLevel ~= nil and fillLevel > 0.1 then
                table.insert(storageEntries, {
                    fillType = fillTypeIndex,
                    fillLevel = fillLevel
                })
            end
        end
    end

    table.sort(storageEntries, function(a, b)
        return a.fillLevel > b.fillLevel
    end)

    if #storageEntries > 0 then
        local storageHeader = spec.infoTableEntryStorage
        if storageHeader ~= nil then
            table.insert(infoTable, storageHeader)
        else
            addSection(infoTable, g_i18n:getText("statistic_storage"))
        end

        for _, entry in ipairs(storageEntries) do
            table.insert(infoTable, {
                title = g_fillTypeManager:getFillTypeTitleByIndex(entry.fillType),
                text = g_i18n:formatVolume(entry.fillLevel, 0)
            })
        end
    end

    -- ConstructibleState может добавлять прогресс текущей фазы. Это строительная,
    -- а не будущая функциональность объекта, поэтому сохраняем штатный вызов.
    local state = spec.stateMachine ~= nil and spec.stateMachine[spec.stateIndex] or nil
    if state ~= nil and type(state.updateInfo) == "function" then
        state:updateInfo(infoTable)
    end

    return true
end

HUD.installProductionPointInfoHook()
HUD.installConstructionNotificationLayoutHook()

Logging.info("%s loaded, version %s", HUD.LOG_PREFIX, HUD.VERSION)
--[[
    Abandoned Taiga - Construction Trigger Registry
    FS25

    Реестр связывает интерактивные объекты и trigger-ноды составного placeable
    с их владельцем и назначением. Модуль сам не устанавливает глобальные hooks:
    он предоставляет единую точку определения, должна ли конкретная интеракция
    быть разрешена в текущем состоянии строительства.
]]

TaigaConstructionTriggerRegistry = TaigaConstructionTriggerRegistry or {}
local Registry = TaigaConstructionTriggerRegistry

Registry.VERSION = "1.0.0"
Registry.LOG_PREFIX = "[TaigaConstructionTriggerRegistry]"

Registry.PURPOSE_CONSTRUCTION = "construction"
Registry.PURPOSE_PRODUCTION = "production"
Registry.PURPOSE_HUSBANDRY = "husbandry"
Registry.PURPOSE_OBJECT_STORAGE = "objectStorage"
Registry.PURPOSE_SILO = "silo"
Registry.PURPOSE_FACILITY = "facility"

local PURPOSE_PRIORITY = {
    [Registry.PURPOSE_FACILITY] = 10,
    [Registry.PURPOSE_SILO] = 20,
    [Registry.PURPOSE_OBJECT_STORAGE] = 30,
    [Registry.PURPOSE_PRODUCTION] = 40,
    [Registry.PURPOSE_HUSBANDRY] = 50,
    [Registry.PURPOSE_CONSTRUCTION] = 100
}

Registry.entriesByObject = Registry.entriesByObject or setmetatable({}, {__mode = "k"})
Registry.entriesByNode = Registry.entriesByNode or {}
Registry.recordsByPlaceable = Registry.recordsByPlaceable or setmetatable({}, {__mode = "k"})

local function isValidNode(node)
    return node ~= nil and node ~= 0
end

local function getPurposePriority(purpose)
    return PURPOSE_PRIORITY[purpose] or 0
end

local function createEntry(placeable, purpose, source, ownerObject)
    return {
        placeable = placeable,
        purpose = purpose,
        source = source,
        ownerObject = ownerObject
    }
end

local function getPlaceableRecord(placeable)
    local record = Registry.recordsByPlaceable[placeable]
    if record == nil then
        record = {
            objects = setmetatable({}, {__mode = "k"}),
            nodes = {}
        }
        Registry.recordsByPlaceable[placeable] = record
    end
    return record
end

local function shouldReplaceEntry(existingEntry, placeable, purpose)
    if existingEntry == nil then
        return true
    end

    -- Повторно использованный engine node/object всегда должен принадлежать новому владельцу.
    if existingEntry.placeable ~= placeable then
        return true
    end

    return getPurposePriority(purpose) >= getPurposePriority(existingEntry.purpose)
end

-- Регистрирует произвольный Lua-объект как часть интерактивной подсистемы placeable.
function Registry.registerObject(object, placeable, purpose, source, ownerObject)
    if object == nil or placeable == nil or purpose == nil then
        return nil
    end

    local existingEntry = Registry.entriesByObject[object]
    if not shouldReplaceEntry(existingEntry, placeable, purpose) then
        return existingEntry
    end

    local entry = createEntry(placeable, purpose, source, ownerObject or object)
    Registry.entriesByObject[object] = entry
    getPlaceableRecord(placeable).objects[object] = true

    return entry
end

-- Регистрирует engine node, используемый как callback-trigger или зона взаимодействия.
function Registry.registerNode(node, placeable, purpose, source, ownerObject)
    if not isValidNode(node) or placeable == nil or purpose == nil then
        return nil
    end

    local existingEntry = Registry.entriesByNode[node]
    if not shouldReplaceEntry(existingEntry, placeable, purpose) then
        return existingEntry
    end

    local entry = createEntry(placeable, purpose, source, ownerObject)
    Registry.entriesByNode[node] = entry
    getPlaceableRecord(placeable).nodes[node] = true

    return entry
end

-- Регистрирует LoadTrigger/UnloadTrigger и известные дополнительные trigger-ноды его подклассов.
function Registry.registerTrigger(trigger, placeable, purpose, source)
    if trigger == nil then
        return
    end

    Registry.registerObject(trigger, placeable, purpose, source, trigger)

    if trigger.activatable ~= nil then
        Registry.registerObject(
            trigger.activatable,
            placeable,
            purpose,
            source .. ".activatable",
            trigger
        )
    end

    Registry.registerNode(trigger.triggerNode, placeable, purpose, source .. ".triggerNode", trigger)
    Registry.registerNode(trigger.exactFillRootNode, placeable, purpose, source .. ".exactFillRootNode", trigger)

    -- WoodUnloadTrigger использует отдельную player activation zone.
    Registry.registerNode(trigger.activationTrigger, placeable, purpose, source .. ".activationTrigger", trigger)
    Registry.registerNode(trigger.activationTriggerNode, placeable, purpose, source .. ".activationTriggerNode", trigger)
end

-- Регистрирует LoadingStation/UnloadingStation вместе со всеми созданными ими triggers.
function Registry.registerStation(station, placeable, purpose, source)
    if station == nil then
        return
    end

    Registry.registerObject(station, placeable, purpose, source, station)

    if station.loadTriggers ~= nil then
        for index, trigger in ipairs(station.loadTriggers) do
            Registry.registerTrigger(
                trigger,
                placeable,
                purpose,
                string.format("%s.loadTriggers[%d]", source, index)
            )
        end
    end

    if station.unloadTriggers ~= nil then
        for index, trigger in ipairs(station.unloadTriggers) do
            Registry.registerTrigger(
                trigger,
                placeable,
                purpose,
                string.format("%s.unloadTriggers[%d]", source, index)
            )
        end
    end
end

-- Регистрирует штатную строительную разгрузочную станцию constructible.
local function registerConstruction(placeable)
    local spec = placeable.spec_constructible
    if spec == nil then
        return
    end

    Registry.registerStation(
        spec.unloadingStation,
        placeable,
        Registry.PURPOSE_CONSTRUCTION,
        "spec_constructible.unloadingStation"
    )
end

-- Регистрирует ProductionPoint, его player trigger и обе station-подсистемы.
local function registerProduction(placeable)
    local spec = placeable.spec_productionPoint
    local productionPoint = spec ~= nil and spec.productionPoint or nil
    if productionPoint == nil then
        return
    end

    Registry.registerObject(
        productionPoint,
        placeable,
        Registry.PURPOSE_PRODUCTION,
        "spec_productionPoint.productionPoint",
        productionPoint
    )

    if productionPoint.activatable ~= nil then
        Registry.registerObject(
            productionPoint.activatable,
            placeable,
            Registry.PURPOSE_PRODUCTION,
            "spec_productionPoint.productionPoint.activatable",
            productionPoint
        )
    end

    Registry.registerNode(
        productionPoint.interactionTriggerNode,
        placeable,
        Registry.PURPOSE_PRODUCTION,
        "spec_productionPoint.productionPoint.interactionTriggerNode",
        productionPoint
    )

    Registry.registerStation(
        productionPoint.unloadingStation,
        placeable,
        Registry.PURPOSE_PRODUCTION,
        "spec_productionPoint.productionPoint.unloadingStation"
    )
    Registry.registerStation(
        productionPoint.loadingStation,
        placeable,
        Registry.PURPOSE_PRODUCTION,
        "spec_productionPoint.productionPoint.loadingStation"
    )
end

-- Регистрирует базовые и специализированные husbandry triggers.
local function registerHusbandry(placeable)
    local husbandrySpec = placeable.spec_husbandry
    if husbandrySpec ~= nil then
        Registry.registerStation(
            husbandrySpec.unloadingStation,
            placeable,
            Registry.PURPOSE_HUSBANDRY,
            "spec_husbandry.unloadingStation"
        )
        Registry.registerStation(
            husbandrySpec.loadingStation,
            placeable,
            Registry.PURPOSE_HUSBANDRY,
            "spec_husbandry.loadingStation"
        )
    end

    -- Кормушки создают UnloadTrigger с callback-таблицей без owningPlaceable,
    -- поэтому их обязательно регистрируем напрямую по самому trigger-объекту.
    local foodSpec = placeable.spec_husbandryFood
    if foodSpec ~= nil and foodSpec.feedingTroughs ~= nil then
        for index, trigger in ipairs(foodSpec.feedingTroughs) do
            Registry.registerTrigger(
                trigger,
                placeable,
                Registry.PURPOSE_HUSBANDRY,
                string.format("spec_husbandryFood.feedingTroughs[%d]", index)
            )
        end
    end

    -- AnimalLoadingTrigger является отдельным классом и не наследуется от LoadTrigger.
    local animalsSpec = placeable.spec_husbandryAnimals
    local animalTrigger = animalsSpec ~= nil and animalsSpec.animalLoadingTrigger or nil
    if animalTrigger ~= nil then
        Registry.registerObject(
            animalTrigger,
            placeable,
            Registry.PURPOSE_HUSBANDRY,
            "spec_husbandryAnimals.animalLoadingTrigger",
            animalTrigger
        )
        if animalTrigger.activatable ~= nil then
            Registry.registerObject(
                animalTrigger.activatable,
                placeable,
                Registry.PURPOSE_HUSBANDRY,
                "spec_husbandryAnimals.animalLoadingTrigger.activatable",
                animalTrigger
            )
        end
        Registry.registerNode(
            animalTrigger.triggerNode,
            placeable,
            Registry.PURPOSE_HUSBANDRY,
            "spec_husbandryAnimals.animalLoadingTrigger.triggerNode",
            animalTrigger
        )
    end

    -- Некоторые husbandry производят паллеты и используют собственные callback-ноды.
    local palletsSpec = placeable.spec_husbandryPallets
    if palletsSpec ~= nil and palletsSpec.palletSpawner ~= nil then
        for spawnerIndex, spawnerData in ipairs(palletsSpec.palletSpawner) do
            if spawnerData.palletTriggers ~= nil then
                for triggerIndex, triggerData in ipairs(spawnerData.palletTriggers) do
                    Registry.registerNode(
                        triggerData.node,
                        placeable,
                        Registry.PURPOSE_HUSBANDRY,
                        string.format(
                            "spec_husbandryPallets.palletSpawner[%d].palletTriggers[%d]",
                            spawnerIndex,
                            triggerIndex
                        ),
                        triggerData
                    )
                end
            end
        end
    end
end

-- Регистрирует player/object trigger большого физического ObjectStorage.
local function registerObjectStorage(placeable)
    local spec = placeable.spec_objectStorage
    if spec == nil then
        return
    end

    Registry.registerNode(
        spec.playerTriggerNode,
        placeable,
        Registry.PURPOSE_OBJECT_STORAGE,
        "spec_objectStorage.playerTriggerNode",
        placeable
    )
    Registry.registerNode(
        spec.objectTriggerNode,
        placeable,
        Registry.PURPOSE_OBJECT_STORAGE,
        "spec_objectStorage.objectTriggerNode",
        placeable
    )

    if spec.activatable ~= nil then
        Registry.registerObject(
            spec.activatable,
            placeable,
            Registry.PURPOSE_OBJECT_STORAGE,
            "spec_objectStorage.activatable",
            placeable
        )
    end
    if spec.manualStoreActivatable ~= nil then
        Registry.registerObject(
            spec.manualStoreActivatable,
            placeable,
            Registry.PURPOSE_OBJECT_STORAGE,
            "spec_objectStorage.manualStoreActivatable",
            placeable
        )
    end
end

-- Регистрирует silo stations и отдельный player-action trigger.
local function registerSilo(placeable)
    local spec = placeable.spec_silo
    if spec == nil then
        return
    end

    Registry.registerStation(
        spec.unloadingStation,
        placeable,
        Registry.PURPOSE_SILO,
        "spec_silo.unloadingStation"
    )
    Registry.registerStation(
        spec.loadingStation,
        placeable,
        Registry.PURPOSE_SILO,
        "spec_silo.loadingStation"
    )
    Registry.registerNode(
        spec.playerActionTrigger,
        placeable,
        Registry.PURPOSE_SILO,
        "spec_silo.playerActionTrigger",
        placeable
    )

    if spec.activatable ~= nil then
        Registry.registerObject(
            spec.activatable,
            placeable,
            Registry.PURPOSE_SILO,
            "spec_silo.activatable",
            placeable
        )
    end
end

-- Регистрирует специализированные buying/selling stations, если они входят в constructible type.
local function registerStandaloneFacilityStations(placeable)
    local sellingSpec = placeable.spec_sellingStation
    if sellingSpec ~= nil then
        Registry.registerStation(
            sellingSpec.sellingStation,
            placeable,
            Registry.PURPOSE_FACILITY,
            "spec_sellingStation.sellingStation"
        )
    end

    local buyingSpec = placeable.spec_buyingStation
    if buyingSpec ~= nil then
        Registry.registerStation(
            buyingSpec.buyingStation,
            placeable,
            Registry.PURPOSE_FACILITY,
            "spec_buyingStation.buyingStation"
        )
    end
end

-- Полностью удаляет записи одного placeable, чтобы node ids не оставались после удаления объекта.
function Registry.unregisterPlaceable(placeable)
    local record = Registry.recordsByPlaceable[placeable]
    if record == nil then
        return
    end

    for object in pairs(record.objects) do
        local entry = Registry.entriesByObject[object]
        if entry ~= nil and entry.placeable == placeable then
            Registry.entriesByObject[object] = nil
        end
    end

    for node in pairs(record.nodes) do
        local entry = Registry.entriesByNode[node]
        if entry ~= nil and entry.placeable == placeable then
            Registry.entriesByNode[node] = nil
        end
    end

    Registry.recordsByPlaceable[placeable] = nil
end

-- Пересобирает все известные trigger-связи одного constructible placeable.
function Registry.registerPlaceable(placeable)
    if placeable == nil or placeable.spec_constructible == nil then
        return false
    end

    Registry.unregisterPlaceable(placeable)

    -- Строительная станция регистрируется первой и имеет максимальный приоритет.
    registerConstruction(placeable)

    -- Конечные функции объекта регистрируются независимо друг от друга:
    -- составной placeable может одновременно иметь несколько специализаций.
    registerProduction(placeable)
    registerHusbandry(placeable)
    registerObjectStorage(placeable)
    registerSilo(placeable)
    registerStandaloneFacilityStations(placeable)

    return true
end

-- Очищает весь реестр. Вызывается при смене карты или полной пересборке.
function Registry.clear()
    Registry.entriesByObject = setmetatable({}, {__mode = "k"})
    Registry.entriesByNode = {}
    Registry.recordsByPlaceable = setmetatable({}, {__mode = "k"})
end

-- Пересобирает реестр по всем constructible-объектам текущей миссии.
function Registry.rebuildMissionRegistry()
    Registry.clear()

    if g_currentMission == nil or g_currentMission.placeableSystem == nil then
        return 0
    end

    local count = 0
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables or {}) do
        if Registry.registerPlaceable(placeable) then
            count = count + 1
        end
    end

    return count
end

-- Определяет назначение station по фактическому объекту специализации.
function Registry.inferStationPurpose(placeable, station)
    if placeable == nil or station == nil then
        return nil
    end

    local lifecycle = TaigaConstructionLifecycle
    if lifecycle ~= nil
        and lifecycle.isConstructionUnloadingStation ~= nil
        and lifecycle.isConstructionUnloadingStation(placeable, station) then
        return Registry.PURPOSE_CONSTRUCTION
    end

    local productionSpec = placeable.spec_productionPoint
    local productionPoint = productionSpec ~= nil and productionSpec.productionPoint or nil
    if productionPoint ~= nil
        and (station == productionPoint.unloadingStation or station == productionPoint.loadingStation) then
        return Registry.PURPOSE_PRODUCTION
    end

    local husbandrySpec = placeable.spec_husbandry
    if husbandrySpec ~= nil
        and (station == husbandrySpec.unloadingStation or station == husbandrySpec.loadingStation) then
        return Registry.PURPOSE_HUSBANDRY
    end

    local siloSpec = placeable.spec_silo
    if siloSpec ~= nil
        and (station == siloSpec.unloadingStation or station == siloSpec.loadingStation) then
        return Registry.PURPOSE_SILO
    end

    local sellingSpec = placeable.spec_sellingStation
    if sellingSpec ~= nil and station == sellingSpec.sellingStation then
        return Registry.PURPOSE_FACILITY
    end

    local buyingSpec = placeable.spec_buyingStation
    if buyingSpec ~= nil and station == buyingSpec.buyingStation then
        return Registry.PURPOSE_FACILITY
    end

    return nil
end

local function resolveEntry(subject, visited)
    if subject == nil then
        return nil
    end

    if type(subject) == "number" then
        return Registry.entriesByNode[subject]
    end

    local directEntry = Registry.entriesByObject[subject]
    if directEntry ~= nil then
        return directEntry
    end

    if type(subject) ~= "table" then
        return nil
    end

    visited = visited or {}
    if visited[subject] then
        return nil
    end
    visited[subject] = true

    -- LoadingStation/UnloadingStation штатно содержат owningPlaceable.
    if subject.owningPlaceable ~= nil then
        local purpose = Registry.inferStationPurpose(subject.owningPlaceable, subject)
        if purpose ~= nil then
            return createEntry(subject.owningPlaceable, purpose, "inferred.owningPlaceable", subject)
        end
    end

    -- AnimalLoadingTrigger хранит husbandry напрямую.
    if subject.husbandry ~= nil and subject.husbandry.spec_husbandry ~= nil then
        return createEntry(
            subject.husbandry,
            Registry.PURPOSE_HUSBANDRY,
            "inferred.husbandry",
            subject
        )
    end

    -- Activatable обычно содержит owner; LoadTrigger/UnloadTrigger — source/target.
    -- Проверяем поля отдельно: в Lua ipairs остановился бы на первом nil.
    local linkedEntry = resolveEntry(subject.owner, visited)
    if linkedEntry ~= nil then
        return linkedEntry
    end

    linkedEntry = resolveEntry(subject.source, visited)
    if linkedEntry ~= nil then
        return linkedEntry
    end

    linkedEntry = resolveEntry(subject.target, visited)
    if linkedEntry ~= nil then
        return linkedEntry
    end

    return nil
end

-- Возвращает запись для trigger/station/activatable/node, включая безопасный fallback по связям GIANTS.
function Registry.getEntry(subject)
    return resolveEntry(subject, nil)
end

-- Возвращает placeable-владельца зарегистрированной интеракции.
function Registry.getPlaceable(subject)
    local entry = Registry.getEntry(subject)
    return entry ~= nil and entry.placeable or nil
end

-- Возвращает назначение зарегистрированной интеракции.
function Registry.getPurpose(subject)
    local entry = Registry.getEntry(subject)
    return entry ~= nil and entry.purpose or nil
end

-- Проверяет разрешённость конкретного назначения для constructible placeable.
function Registry.isPurposeAllowed(placeable, purpose)
    if placeable == nil or placeable.spec_constructible == nil then
        return true
    end

    local lifecycle = TaigaConstructionLifecycle
    if lifecycle == nil then
        -- Без ядра нельзя надёжно определить стадию; безопаснее не ломать штатную механику.
        return true
    end

    if purpose == Registry.PURPOSE_CONSTRUCTION then
        return lifecycle.isUnderConstruction(placeable)
    end

    -- Любая конечная функция constructible разрешается только после реального DONE.
    return lifecycle.isFinished(placeable)
end

-- Проверяет, может ли сейчас работать зарегистрированный trigger/station/activatable/node.
-- Неизвестные объекты не блокируются: их должен отдельно зарегистрировать соответствующий модуль.
function Registry.isInteractionAllowed(subject)
    local entry = Registry.getEntry(subject)
    if entry == nil then
        return true
    end

    return Registry.isPurposeAllowed(entry.placeable, entry.purpose)
end

-- Удобная проверка для hooks: true означает, что интеракцию необходимо погасить.
function Registry.isInteractionBlocked(subject)
    return not Registry.isInteractionAllowed(subject)
end

Logging.info("%s loaded, version %s", Registry.LOG_PREFIX, Registry.VERSION)

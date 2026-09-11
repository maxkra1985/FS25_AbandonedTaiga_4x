--[[
    Abandoned Taiga - Construction Facility Lifecycle
    FS25

    Контроллер фактического состояния составных constructible-объектов.
    Он синхронизирует регистрации ProductionPoint/Husbandry, состояние строительной
    station и очищает зависшие activatable-объекты. Глобальные hooks устанавливаются
    отдельно координатором ConstructionLifecycleFix.lua.
]]

TaigaConstructionFacilityLifecycle = TaigaConstructionFacilityLifecycle or {}
local FacilityLifecycle = TaigaConstructionFacilityLifecycle

FacilityLifecycle.VERSION = "1.0.0"
FacilityLifecycle.LOG_PREFIX = "[TaigaConstructionFacilityLifecycle]"

FacilityLifecycle.runtimeByPlaceable = FacilityLifecycle.runtimeByPlaceable
    or setmetatable({}, {__mode = "k"})

local function getLifecycle()
    return TaigaConstructionLifecycle
end

local function getRegistry()
    return TaigaConstructionTriggerRegistry
end

local function getPlaceableName(placeable)
    local lifecycle = getLifecycle()
    if lifecycle ~= nil and lifecycle.getPlaceableName ~= nil then
        return lifecycle.getPlaceableName(placeable)
    end

    return tostring(placeable)
end

local function getRuntime(placeable)
    local runtime = FacilityLifecycle.runtimeByPlaceable[placeable]
    if runtime == nil then
        runtime = {
            lifecycleState = nil,
            registryInitialized = false,
            production = {},
            husbandry = {}
        }
        FacilityLifecycle.runtimeByPlaceable[placeable] = runtime
    end

    return runtime
end

local function containsElement(array, element)
    if array == nil then
        return false
    end

    for _, value in ipairs(array) do
        if value == element then
            return true
        end
    end

    return false
end

local function removeActivatable(activatable)
    if activatable == nil
        or g_currentMission == nil
        or g_currentMission.activatableObjectsSystem == nil then
        return
    end

    g_currentMission.activatableObjectsSystem:removeActivatable(activatable)
end

-- Удаляет возможный activatable конкретного trigger и останавливает активную загрузку.
local function suppressTriggerInteraction(trigger)
    if trigger == nil then
        return
    end

    removeActivatable(trigger.activatable)

    if trigger.isLoading and type(trigger.setIsLoading) == "function" then
        trigger:setIsLoading(false)
    end
end

-- Очищает activatable-объекты всех load/unload triggers station.
local function suppressStationInteractions(station)
    if station == nil then
        return
    end

    if station.loadTriggers ~= nil then
        for _, trigger in ipairs(station.loadTriggers) do
            suppressTriggerInteraction(trigger)
        end
    end

    if station.unloadTriggers ~= nil then
        for _, trigger in ipairs(station.unloadTriggers) do
            suppressTriggerInteraction(trigger)
        end
    end
end

local function isSellingStationInEconomyManager(economyManager, station)
    if economyManager == nil or station == nil or economyManager.sellingStations == nil then
        return false
    end

    for _, data in ipairs(economyManager.sellingStations) do
        if data.station == station then
            return true
        end
    end

    return false
end

-- В состоянии строительства construction station обязана присутствовать в штатных менеджерах.
-- Это также восстанавливает её после штатного resetConstructibleToState().
local function ensureConstructionStationRegistered(placeable)
    if g_currentMission == nil then
        return
    end

    local spec = placeable.spec_constructible
    local station = spec ~= nil and spec.unloadingStation or nil
    if station == nil then
        return
    end

    local storageSystem = g_currentMission.storageSystem
    if storageSystem ~= nil
        and type(storageSystem.getIsUnloadingStationAvailable) == "function"
        and not storageSystem:getIsUnloadingStationAvailable(station) then
        storageSystem:addUnloadingStation(station, placeable)
    end

    local economyManager = g_currentMission.economyManager
    if economyManager ~= nil and not isSellingStationInEconomyManager(economyManager, station) then
        economyManager:addSellingStation(station)
    end
end

-- После DONE строительная station должна исчезнуть из систем игры.
-- Сам объект station не удаляется: он нужен savegame/network-коду PlaceableConstructible,
-- а оставшиеся физические triggers дополнительно блокируются через ConstructionTriggerRegistry.
local function ensureConstructionStationRemoved(placeable)
    if g_currentMission == nil then
        return
    end

    local spec = placeable.spec_constructible
    local station = spec ~= nil and spec.unloadingStation or nil
    if station == nil then
        return
    end

    local storageSystem = g_currentMission.storageSystem
    if storageSystem ~= nil then
        local isRegistered = type(storageSystem.getIsUnloadingStationAvailable) ~= "function"
            or storageSystem:getIsUnloadingStationAvailable(station)

        if isRegistered then
            storageSystem:removeUnloadingStation(station, placeable)
        end
    end

    local economyManager = g_currentMission.economyManager
    if isSellingStationInEconomyManager(economyManager, station) then
        economyManager:removeSellingStation(station)
    end

    suppressStationInteractions(station)
end

local function isProductionPointRegistered(manager, productionPoint)
    if manager == nil or productionPoint == nil then
        return false
    end

    if manager.reverseProductionPoint ~= nil then
        return manager.reverseProductionPoint[productionPoint] == true
    end

    return containsElement(manager.productionPoints, productionPoint)
end

-- Запоминает исходные настройки production station перед первым принудительным отключением.
local function captureProductionDefaults(runtime, productionPoint)
    local productionRuntime = runtime.production
    if productionRuntime.defaultsCaptured then
        return
    end

    local station = productionPoint.unloadingStation
    productionRuntime.defaultsCaptured = true
    productionRuntime.hideFromPricesMenu = station ~= nil and station.hideFromPricesMenu or nil
    productionRuntime.allowMissions = station ~= nil and station.allowMissions or nil
end

-- Полностью исключает незавершённый ProductionPoint из production chain.
local function suspendProduction(placeable, runtime)
    local spec = placeable.spec_productionPoint
    local productionPoint = spec ~= nil and spec.productionPoint or nil
    if productionPoint == nil then
        return
    end

    captureProductionDefaults(runtime, productionPoint)
    runtime.production.suspended = true

    -- Исправляет в том числе XML, где для constructible забыли isFinalized="false".
    spec.isFinalized = false
    productionPoint.isFinalized = false

    local station = productionPoint.unloadingStation
    if station ~= nil then
        station.hideFromPricesMenu = true
        station.allowMissions = false
    end

    local manager = g_currentMission ~= nil and g_currentMission.productionChainManager or nil
    if manager ~= nil then
        manager:removeProductionPoint(productionPoint)
    end

    removeActivatable(productionPoint.activatable)
    suppressStationInteractions(productionPoint.loadingStation)
    suppressStationInteractions(productionPoint.unloadingStation)

    if type(productionPoint.updateFxState) == "function" then
        productionPoint:updateFxState()
    end
end

-- Возвращает ProductionPoint в штатную production chain после завершения строительства.
local function releaseProduction(placeable, runtime)
    local spec = placeable.spec_productionPoint
    local productionPoint = spec ~= nil and spec.productionPoint or nil
    if productionPoint == nil then
        return
    end

    spec.isFinalized = true
    productionPoint.isFinalized = true

    local station = productionPoint.unloadingStation
    if station ~= nil then
        if runtime.production.defaultsCaptured then
            if runtime.production.hideFromPricesMenu ~= nil then
                station.hideFromPricesMenu = runtime.production.hideFromPricesMenu
            else
                station.hideFromPricesMenu = false
            end

            if runtime.production.allowMissions ~= nil then
                station.allowMissions = runtime.production.allowMissions
            elseif spec.unloadingStationDefaultAllowMissions ~= nil then
                station.allowMissions = spec.unloadingStationDefaultAllowMissions
            end
        else
            -- Штатный PlaceableProductionPoint:finalizeConstruction() делает station видимой.
            station.hideFromPricesMenu = false
            if spec.unloadingStationDefaultAllowMissions ~= nil then
                station.allowMissions = spec.unloadingStationDefaultAllowMissions
            end
        end
    end

    local manager = g_currentMission ~= nil and g_currentMission.productionChainManager or nil
    if manager ~= nil and not isProductionPointRegistered(manager, productionPoint) then
        local ownerFarmId = type(placeable.getOwnerFarmId) == "function"
            and placeable:getOwnerFarmId()
            or AccessHandler.EVERYONE

        if type(productionPoint.getOwnerFarmId) == "function"
            and productionPoint:getOwnerFarmId() ~= ownerFarmId
            and type(productionPoint.setOwnerFarmId) == "function" then
            -- setOwnerFarmId сам выполняет remove/add и синхронизирует владельцев station/storage.
            productionPoint:setOwnerFarmId(ownerFarmId, true)
        else
            manager:addProductionPoint(productionPoint)
        end
    end

    if type(productionPoint.updateFxState) == "function" then
        productionPoint:updateFxState()
    end

    runtime.production.suspended = false
end

local function captureAnimalTriggerDefaults(runtime, animalTrigger)
    local husbandryRuntime = runtime.husbandry
    if husbandryRuntime.animalTriggerDefaultsCaptured or animalTrigger == nil then
        return
    end

    husbandryRuntime.animalTriggerDefaultsCaptured = true
    husbandryRuntime.animalTriggerEnabled = animalTrigger.isEnabled
end

-- Убирает незавершённое husbandry из HusbandrySystem и гасит animal interaction trigger.
local function suspendHusbandry(placeable, runtime)
    if placeable.spec_husbandry == nil then
        return
    end

    runtime.husbandry.suspended = true

    local husbandrySystem = g_currentMission ~= nil and g_currentMission.husbandrySystem or nil
    if husbandrySystem ~= nil then
        husbandrySystem:removePlaceable(placeable)
    end

    local spec = placeable.spec_husbandry
    suppressStationInteractions(spec.loadingStation)
    suppressStationInteractions(spec.unloadingStation)

    local animalsSpec = placeable.spec_husbandryAnimals
    local animalTrigger = animalsSpec ~= nil and animalsSpec.animalLoadingTrigger or nil
    if animalTrigger ~= nil then
        captureAnimalTriggerDefaults(runtime, animalTrigger)
        animalTrigger.isEnabled = false
        animalTrigger.isPlayerInRange = false

        if animalTrigger.loadingVehicle ~= nil and type(animalTrigger.setLoadingTrailer) == "function" then
            animalTrigger:setLoadingTrailer(nil)
        end

        removeActivatable(animalTrigger.activatable)
    end

    local foodSpec = placeable.spec_husbandryFood
    if foodSpec ~= nil and foodSpec.feedingTroughs ~= nil then
        for _, trigger in ipairs(foodSpec.feedingTroughs) do
            suppressTriggerInteraction(trigger)
        end
    end
end

-- Возвращает завершённое husbandry в HusbandrySystem.
local function releaseHusbandry(placeable, runtime)
    if placeable.spec_husbandry == nil then
        return
    end

    local husbandrySystem = g_currentMission ~= nil and g_currentMission.husbandrySystem or nil
    if husbandrySystem ~= nil and not containsElement(husbandrySystem.placeables, placeable) then
        husbandrySystem:addPlaceable(placeable)
    end

    local animalsSpec = placeable.spec_husbandryAnimals
    local animalTrigger = animalsSpec ~= nil and animalsSpec.animalLoadingTrigger or nil
    if animalTrigger ~= nil
        and runtime.husbandry.animalTriggerDefaultsCaptured
        and runtime.husbandry.animalTriggerEnabled ~= nil then
        animalTrigger.isEnabled = runtime.husbandry.animalTriggerEnabled
    end

    runtime.husbandry.suspended = false
end

-- Удаляет activatable-объекты конечных специализаций, которые могли быть добавлены
-- callback'ами до очередной синхронизации lifecycle.
local function suppressFinishedFacilityActivatables(placeable)
    local productionSpec = placeable.spec_productionPoint
    local productionPoint = productionSpec ~= nil and productionSpec.productionPoint or nil
    if productionPoint ~= nil then
        removeActivatable(productionPoint.activatable)
        suppressStationInteractions(productionPoint.loadingStation)
        suppressStationInteractions(productionPoint.unloadingStation)
    end

    local objectStorageSpec = placeable.spec_objectStorage
    if objectStorageSpec ~= nil then
        removeActivatable(objectStorageSpec.activatable)
        removeActivatable(objectStorageSpec.manualStoreActivatable)
    end

    local siloSpec = placeable.spec_silo
    if siloSpec ~= nil then
        removeActivatable(siloSpec.activatable)
        suppressStationInteractions(siloSpec.loadingStation)
        suppressStationInteractions(siloSpec.unloadingStation)
    end

    local sellingSpec = placeable.spec_sellingStation
    if sellingSpec ~= nil then
        suppressStationInteractions(sellingSpec.sellingStation)
    end

    local buyingSpec = placeable.spec_buyingStation
    if buyingSpec ~= nil then
        suppressStationInteractions(buyingSpec.buyingStation)
    end
end

-- Возвращает true только для готового constructible либо для обычного нестроительного placeable.
-- Эту функцию используют hooks производственных/животноводческих обновлений.
function FacilityLifecycle.isFinalFacilityOperationAllowed(placeable)
    if placeable == nil or placeable.spec_constructible == nil then
        return true
    end

    local lifecycle = getLifecycle()
    return lifecycle ~= nil and lifecycle.isFinished(placeable)
end

-- Возвращает true только пока активна строительная часть constructible.
function FacilityLifecycle.isConstructionOperationAllowed(placeable)
    if placeable == nil or placeable.spec_constructible == nil then
        return false
    end

    local lifecycle = getLifecycle()
    return lifecycle ~= nil and lifecycle.isUnderConstruction(placeable)
end

-- Синхронизирует один constructible с его фактическим lifecycle-состоянием.
-- Возвращает: changed, previousState, currentState.
function FacilityLifecycle.synchronizePlaceable(placeable)
    local lifecycle = getLifecycle()
    if lifecycle == nil or placeable == nil or placeable.spec_constructible == nil then
        return false, nil, nil
    end

    local currentState = lifecycle.getLifecycleState(placeable)
    if currentState == lifecycle.STATE_NONE then
        return false, nil, currentState
    end

    local runtime = getRuntime(placeable)
    local previousState = runtime.lifecycleState
    local stateChanged = previousState ~= nil and previousState ~= currentState

    local registry = getRegistry()
    if registry ~= nil and (not runtime.registryInitialized or stateChanged) then
        registry.registerPlaceable(placeable)
        runtime.registryInitialized = true
    end

    if currentState == lifecycle.STATE_UNDER_CONSTRUCTION then
        ensureConstructionStationRegistered(placeable)
        suspendProduction(placeable, runtime)
        suspendHusbandry(placeable, runtime)
        suppressFinishedFacilityActivatables(placeable)
    elseif currentState == lifecycle.STATE_FINISHED then
        ensureConstructionStationRemoved(placeable)
        releaseProduction(placeable, runtime)
        releaseHusbandry(placeable, runtime)
    end

    runtime.lifecycleState = currentState

    if stateChanged then
        Logging.info(
            "%s lifecycle changed for %s: %s -> %s",
            FacilityLifecycle.LOG_PREFIX,
            getPlaceableName(placeable),
            tostring(previousState),
            tostring(currentState)
        )
    end

    return stateChanged, previousState, currentState
end

-- Периодически подтверждает lifecycle-инварианты для всех constructible текущей миссии.
-- Повторная синхронизация намеренна: сторонний код может повторно зарегистрировать subsystem.
function FacilityLifecycle.synchronizeMission()
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then
        return 0, 0
    end

    local processed = 0
    local changed = 0

    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables or {}) do
        if placeable.spec_constructible ~= nil then
            processed = processed + 1
            local stateChanged = FacilityLifecycle.synchronizePlaceable(placeable)
            if stateChanged then
                changed = changed + 1
            end
        end
    end

    return processed, changed
end

-- Удаляет runtime/registry-записи placeable при его удалении.
function FacilityLifecycle.unregisterPlaceable(placeable)
    FacilityLifecycle.runtimeByPlaceable[placeable] = nil

    local registry = getRegistry()
    if registry ~= nil then
        registry.unregisterPlaceable(placeable)
    end
end

-- Очищает transient-состояние при выгрузке карты.
function FacilityLifecycle.clear()
    FacilityLifecycle.runtimeByPlaceable = setmetatable({}, {__mode = "k"})

    local registry = getRegistry()
    if registry ~= nil then
        registry.clear()
    end
end

Logging.info("%s loaded, version %s", FacilityLifecycle.LOG_PREFIX, FacilityLifecycle.VERSION)

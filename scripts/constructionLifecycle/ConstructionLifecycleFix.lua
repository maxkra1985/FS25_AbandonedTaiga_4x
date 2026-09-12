--[[
    Abandoned Taiga - Construction Lifecycle Fix
    FS25

    Координатор подсистемы constructible lifecycle.

    Назначение файла:
      * установить глобальные guards/hooks поверх штатных классов GIANTS;
      * связать ConstructionLifecycle, ConstructionTriggerRegistry,
        ConstructionFacilityLifecycle и ConstructionInfoHUD;
      * отслеживать реальные переходы строительной state machine;
      * показывать уведомления о завершении этапов строительства;
      * сохранить существующую механику возврата остаточных стройматериалов паллетами.

    Файл должен загружаться после остальных модулей каталога constructionLifecycle.
]]

TaigaConstructionLifecycleFix = TaigaConstructionLifecycleFix or {}
local Fix = TaigaConstructionLifecycleFix

Fix.VERSION = "1.0.1"
Fix.LOG_PREFIX = "[TaigaConstructionLifecycleFix]"

Fix.SYNC_INTERVAL_MS = 1000
Fix.NOTIFICATION_ARM_DELAY_MS = 1500
Fix.NOTIFICATION_DURATION_MS = 7000

Fix.SPAWN_SPACING = 1.8
Fix.SPAWN_COLUMNS = 4
Fix.SPAWN_FORWARD_OFFSET = 2.5

Fix.syncTimer = 0
Fix.notificationArmTimer = Fix.NOTIFICATION_ARM_DELAY_MS
Fix.notificationStates = Fix.notificationStates or setmetatable({}, {__mode = "k"})
Fix.palletQueue = Fix.palletQueue or {}
Fix.currentPalletJob = Fix.currentPalletJob or nil
Fix.hooksInstalled = false

local function logInfo(formatString, ...)
    Logging.info("%s %s", Fix.LOG_PREFIX, string.format(formatString, ...))
end

local function logWarning(formatString, ...)
    Logging.warning("%s %s", Fix.LOG_PREFIX, string.format(formatString, ...))
end

local function getLifecycle()
    return TaigaConstructionLifecycle
end

local function getRegistry()
    return TaigaConstructionTriggerRegistry
end

local function getFacilityLifecycle()
    return TaigaConstructionFacilityLifecycle
end

local function getInfoHUD()
    return TaigaConstructionInfoHUD
end

local function getText(key, fallback)
    if g_i18n ~= nil and key ~= nil and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end

    return fallback
end

local function getPlaceableName(placeable)
    local lifecycle = getLifecycle()
    if lifecycle ~= nil and lifecycle.getPlaceableName ~= nil then
        return lifecycle.getPlaceableName(placeable)
    end

    return tostring(placeable)
end

local function removeActivatable(activatable)
    if activatable == nil
        or g_currentMission == nil
        or g_currentMission.activatableObjectsSystem == nil then
        return
    end

    g_currentMission.activatableObjectsSystem:removeActivatable(activatable)
end

local function isInteractionBlocked(subject)
    local registry = getRegistry()
    return registry ~= nil
        and registry.isInteractionBlocked ~= nil
        and registry.isInteractionBlocked(subject)
end

local function isFinalFacilityBlocked(placeable)
    local facilityLifecycle = getFacilityLifecycle()
    if facilityLifecycle == nil then
        return false
    end

    return not facilityLifecycle.isFinalFacilityOperationAllowed(placeable)
end

-- -------------------------------------------------------------------------
-- XML schema
-- -------------------------------------------------------------------------

-- Регистрирует пользовательский #StateName до построения placeableTypes.
-- Используется тот же guard, что и у ConstructionProgressDisplay, чтобы оба
-- скрипта могли сосуществовать без двойной регистрации XML path.
local function installStateNameSchemaHook()
    if PlaceableConstructible == nil
        or PlaceableConstructible.registerXMLPaths == nil
        or PlaceableConstructible.cpdStateNameXMLHookInstalled then
        return false
    end

    PlaceableConstructible.cpdStateNameXMLHookInstalled = true
    PlaceableConstructible.registerXMLPaths = Utils.appendedFunction(
        PlaceableConstructible.registerXMLPaths,
        function(schema, basePath)
            schema:register(
                XMLValueType.L10N_STRING,
                basePath .. ".constructible.stateMachine.states.state(?)#StateName",
                "Optional human-readable construction stage name"
            )
        end
    )

    return true
end

-- -------------------------------------------------------------------------
-- Context info HUD
-- -------------------------------------------------------------------------

-- Устанавливает guard для specialization.updateInfo.
-- Во время строительства специализация будущего объекта вызывает только superFunc,
-- не добавляя собственных строк. Для ProductionPoint + ObjectStorage дополнительно
-- подавляется штатный плоский ProductionPoint HUD и один раз вставляется наш grouped HUD.
local function installFutureFacilityInfoGuard(classTable, className)
    if classTable == nil
        or classTable.updateInfo == nil
        or classTable.taigaConstructionInfoGuardInstalled then
        return false
    end

    local originalUpdateInfo = classTable.updateInfo
    local isProductionPointClass = classTable == PlaceableProductionPoint
    local isObjectStorageClass = classTable == PlaceableObjectStorage

    classTable.updateInfo = function(placeable, superFunc, infoTable)
        local infoHUD = getInfoHUD()
        if infoHUD == nil then
            return originalUpdateInfo(placeable, superFunc, infoTable)
        end

        if infoHUD.shouldSuppressFutureFacilityInfo(placeable) then
            return superFunc(placeable, infoTable)
        end

        if infoHUD.useFinishedCompositeInfo(placeable) then
            if isProductionPointClass then
                -- Составной HUD сам добавит production section в единой точке.
                return superFunc(placeable, infoTable)
            end

            if isObjectStorageClass then
                local result = superFunc(placeable, infoTable)
                infoHUD.addFinishedCompositeInfo(placeable, infoTable)
                return result
            end
        end

        return originalUpdateInfo(placeable, superFunc, infoTable)
    end

    classTable.taigaConstructionInfoGuardInstalled = true
    logInfo("%s info HUD guard installed", className)
    return true
end

-- Подменяет только строительный участок updateInfo цепочки.
-- UNDER_CONSTRUCTION: выводится исключительно ConstructionInfoHUD.
-- FINISHED: штатный блок PlaceableConstructible полностью обходится, чтобы даже
-- остаточные данные construction storage не могли появиться в готовом объекте.
local function installConstructibleInfoHook()
    if PlaceableConstructible == nil
        or PlaceableConstructible.updateInfo == nil
        or PlaceableConstructible.taigaConstructionInfoHookInstalled then
        return false
    end

    local originalUpdateInfo = PlaceableConstructible.updateInfo

    PlaceableConstructible.updateInfo = function(placeable, superFunc, infoTable)
        local lifecycle = getLifecycle()
        local infoHUD = getInfoHUD()

        if lifecycle == nil or infoHUD == nil or type(infoTable) ~= "table" then
            return originalUpdateInfo(placeable, superFunc, infoTable)
        end

        if lifecycle.isUnderConstruction(placeable) then
            infoHUD.addConstructionInfo(placeable, infoTable)
            return
        end

        if lifecycle.isFinished(placeable) then
            -- После DONE construction storage/state больше не являются частью HUD.
            return superFunc(placeable, infoTable)
        end

        return originalUpdateInfo(placeable, superFunc, infoTable)
    end

    PlaceableConstructible.taigaConstructionInfoHookInstalled = true
    logInfo("Constructible info HUD hook installed")
    return true
end

local function installInfoHUDHooks()
    installConstructibleInfoHook()

    installFutureFacilityInfoGuard(PlaceableProductionPoint, "PlaceableProductionPoint")
    installFutureFacilityInfoGuard(PlaceableSilo, "PlaceableSilo")
    installFutureFacilityInfoGuard(PlaceableObjectStorage, "PlaceableObjectStorage")

    -- Все specialization, добавляемые после parent=constructible в коровнике карты,
    -- должны подавить собственные строки, пока объект ещё строится.
    installFutureFacilityInfoGuard(PlaceableHusbandryAnimals, "PlaceableHusbandryAnimals")
    installFutureFacilityInfoGuard(PlaceableHusbandryFood, "PlaceableHusbandryFood")
    installFutureFacilityInfoGuard(PlaceableHusbandryWater, "PlaceableHusbandryWater")
    installFutureFacilityInfoGuard(PlaceableHusbandryStraw, "PlaceableHusbandryStraw")
    installFutureFacilityInfoGuard(PlaceableHusbandryMilk, "PlaceableHusbandryMilk")
    installFutureFacilityInfoGuard(PlaceableHusbandryLiquidManure, "PlaceableHusbandryLiquidManure")

    -- Оставлено для возможных constructible husbandry с паллетным output.
    installFutureFacilityInfoGuard(PlaceableHusbandryPallets, "PlaceableHusbandryPallets")
end

-- -------------------------------------------------------------------------
-- Generic LoadTrigger / UnloadTrigger guards
-- -------------------------------------------------------------------------

function Fix.loadTriggerCallback(trigger, superFunc, ...)
    if isInteractionBlocked(trigger) then
        if trigger.isLoading and type(trigger.setIsLoading) == "function" then
            trigger:setIsLoading(false)
        end
        return
    end

    return superFunc(trigger, ...)
end

function Fix.loadTriggerUpdate(trigger, superFunc, dt)
    if isInteractionBlocked(trigger) then
        if trigger.isLoading and type(trigger.setIsLoading) == "function" then
            trigger:setIsLoading(false)
        end
        return
    end

    return superFunc(trigger, dt)
end

function Fix.loadTriggerGetIsFillTypeSupported(trigger, superFunc, fillType)
    if isInteractionBlocked(trigger) then
        return false
    end

    return superFunc(trigger, fillType)
end

function Fix.unloadTriggerGetIsFillTypeSupported(trigger, superFunc, fillType)
    if isInteractionBlocked(trigger) then
        return false
    end

    return superFunc(trigger, fillType)
end

function Fix.unloadTriggerGetFillUnitFreeCapacity(trigger, superFunc, ...)
    if isInteractionBlocked(trigger) then
        return 0
    end

    return superFunc(trigger, ...)
end

function Fix.unloadTriggerAddFillUnitFillLevel(trigger, superFunc, ...)
    if isInteractionBlocked(trigger) then
        return 0
    end

    return superFunc(trigger, ...)
end

local function installGenericTriggerGuards()
    if LoadTrigger ~= nil and not LoadTrigger.taigaConstructionLifecycleGuardsInstalled then
        if LoadTrigger.loadTriggerCallback ~= nil then
            LoadTrigger.loadTriggerCallback = Utils.overwrittenFunction(
                LoadTrigger.loadTriggerCallback,
                Fix.loadTriggerCallback
            )
        end

        if LoadTrigger.update ~= nil then
            LoadTrigger.update = Utils.overwrittenFunction(
                LoadTrigger.update,
                Fix.loadTriggerUpdate
            )
        end

        if LoadTrigger.getIsFillTypeSupported ~= nil then
            LoadTrigger.getIsFillTypeSupported = Utils.overwrittenFunction(
                LoadTrigger.getIsFillTypeSupported,
                Fix.loadTriggerGetIsFillTypeSupported
            )
        end

        LoadTrigger.taigaConstructionLifecycleGuardsInstalled = true
        logInfo("LoadTrigger guards installed")
    end

    if UnloadTrigger ~= nil and not UnloadTrigger.taigaConstructionLifecycleGuardsInstalled then
        if UnloadTrigger.getIsFillTypeSupported ~= nil then
            UnloadTrigger.getIsFillTypeSupported = Utils.overwrittenFunction(
                UnloadTrigger.getIsFillTypeSupported,
                Fix.unloadTriggerGetIsFillTypeSupported
            )
        end

        if UnloadTrigger.getFillUnitFreeCapacity ~= nil then
            UnloadTrigger.getFillUnitFreeCapacity = Utils.overwrittenFunction(
                UnloadTrigger.getFillUnitFreeCapacity,
                Fix.unloadTriggerGetFillUnitFreeCapacity
            )
        end

        if UnloadTrigger.addFillUnitFillLevel ~= nil then
            UnloadTrigger.addFillUnitFillLevel = Utils.overwrittenFunction(
                UnloadTrigger.addFillUnitFillLevel,
                Fix.unloadTriggerAddFillUnitFillLevel
            )
        end

        UnloadTrigger.taigaConstructionLifecycleGuardsInstalled = true
        logInfo("UnloadTrigger guards installed")
    end
end

-- -------------------------------------------------------------------------
-- ProductionPoint interaction
-- -------------------------------------------------------------------------

function Fix.productionInteractionTriggerCallback(productionPoint, superFunc, ...)
    if isInteractionBlocked(productionPoint) then
        removeActivatable(productionPoint ~= nil and productionPoint.activatable or nil)
        return
    end

    return superFunc(productionPoint, ...)
end

local function installProductionInteractionGuard()
    if ProductionPoint == nil
        or ProductionPoint.interactionTriggerCallback == nil
        or ProductionPoint.taigaConstructionInteractionGuardInstalled then
        return
    end

    ProductionPoint.interactionTriggerCallback = Utils.overwrittenFunction(
        ProductionPoint.interactionTriggerCallback,
        Fix.productionInteractionTriggerCallback
    )

    ProductionPoint.taigaConstructionInteractionGuardInstalled = true
    logInfo("ProductionPoint interaction guard installed")
end

-- -------------------------------------------------------------------------
-- ObjectStorage guards
-- -------------------------------------------------------------------------

local function installObjectStorageGuards()
    if PlaceableObjectStorage == nil or PlaceableObjectStorage.taigaConstructionTriggerGuardsInstalled then
        return
    end

    if PlaceableObjectStorage.onObjectStoragePlayerTriggerCallback ~= nil then
        local original = PlaceableObjectStorage.onObjectStoragePlayerTriggerCallback
        PlaceableObjectStorage.onObjectStoragePlayerTriggerCallback = function(placeable, ...)
            if isFinalFacilityBlocked(placeable) then
                local spec = placeable.spec_objectStorage
                if spec ~= nil then
                    removeActivatable(spec.activatable)
                    removeActivatable(spec.manualStoreActivatable)
                end
                return
            end

            return original(placeable, ...)
        end
    end

    if PlaceableObjectStorage.onObjectStorageObjectTriggerCallback ~= nil then
        local original = PlaceableObjectStorage.onObjectStorageObjectTriggerCallback
        PlaceableObjectStorage.onObjectStorageObjectTriggerCallback = function(placeable, ...)
            if isFinalFacilityBlocked(placeable) then
                return
            end

            return original(placeable, ...)
        end
    end

    if PlaceableObjectStorage.updateManualStoreActivatable ~= nil then
        local original = PlaceableObjectStorage.updateManualStoreActivatable
        PlaceableObjectStorage.updateManualStoreActivatable = function(placeable, ...)
            if isFinalFacilityBlocked(placeable) then
                local spec = placeable.spec_objectStorage
                if spec ~= nil then
                    spec.lastPendingManualObjectsState = false
                    removeActivatable(spec.manualStoreActivatable)
                end
                return
            end

            return original(placeable, ...)
        end
    end

    if PlaceableObjectStorage.storePendingManualObjects ~= nil then
        local original = PlaceableObjectStorage.storePendingManualObjects
        PlaceableObjectStorage.storePendingManualObjects = function(placeable, ...)
            if isFinalFacilityBlocked(placeable) then
                return
            end

            return original(placeable, ...)
        end
    end

    if PlaceableObjectStorage.getObjectStorageCanStoreObject ~= nil then
        local original = PlaceableObjectStorage.getObjectStorageCanStoreObject
        PlaceableObjectStorage.getObjectStorageCanStoreObject = function(placeable, ...)
            if isFinalFacilityBlocked(placeable) then
                return false
            end

            return original(placeable, ...)
        end
    end

    PlaceableObjectStorage.taigaConstructionTriggerGuardsInstalled = true
    logInfo("ObjectStorage guards installed")
end

-- -------------------------------------------------------------------------
-- Silo player-action guard
-- -------------------------------------------------------------------------

local function installSiloGuard()
    if PlaceableSilo == nil
        or PlaceableSilo.onPlayerActionTriggerCallback == nil
        or PlaceableSilo.taigaConstructionPlayerActionGuardInstalled then
        return
    end

    local original = PlaceableSilo.onPlayerActionTriggerCallback
    PlaceableSilo.onPlayerActionTriggerCallback = function(placeable, ...)
        if isFinalFacilityBlocked(placeable) then
            local spec = placeable.spec_silo
            removeActivatable(spec ~= nil and spec.activatable or nil)
            return
        end

        return original(placeable, ...)
    end

    PlaceableSilo.taigaConstructionPlayerActionGuardInstalled = true
    logInfo("Silo player-action guard installed")
end

-- -------------------------------------------------------------------------
-- AnimalLoadingTrigger / husbandry runtime guards
-- -------------------------------------------------------------------------

local function installAnimalLoadingTriggerGuards()
    if AnimalLoadingTrigger ~= nil and not AnimalLoadingTrigger.taigaConstructionGuardsInstalled then
        if AnimalLoadingTrigger.triggerCallback ~= nil then
            local original = AnimalLoadingTrigger.triggerCallback
            AnimalLoadingTrigger.triggerCallback = function(trigger, ...)
                if isInteractionBlocked(trigger) then
                    trigger.isPlayerInRange = false
                    if trigger.loadingVehicle ~= nil and type(trigger.setLoadingTrailer) == "function" then
                        trigger:setLoadingTrailer(nil)
                    end
                    removeActivatable(trigger.activatable)
                    return
                end

                return original(trigger, ...)
            end
        end

        if AnimalLoadingTrigger.openAnimalMenu ~= nil then
            local original = AnimalLoadingTrigger.openAnimalMenu
            AnimalLoadingTrigger.openAnimalMenu = function(trigger, ...)
                if isInteractionBlocked(trigger) then
                    removeActivatable(trigger.activatable)
                    return
                end

                return original(trigger, ...)
            end
        end

        AnimalLoadingTrigger.taigaConstructionGuardsInstalled = true
        logInfo("AnimalLoadingTrigger guards installed")
    end

    if AnimalLoadingTriggerActivatable ~= nil
        and not AnimalLoadingTriggerActivatable.taigaConstructionGuardsInstalled then

        if AnimalLoadingTriggerActivatable.getIsActivatable ~= nil then
            local original = AnimalLoadingTriggerActivatable.getIsActivatable
            AnimalLoadingTriggerActivatable.getIsActivatable = function(activatable, ...)
                if isInteractionBlocked(activatable.owner) then
                    return false
                end

                return original(activatable, ...)
            end
        end

        if AnimalLoadingTriggerActivatable.run ~= nil then
            local original = AnimalLoadingTriggerActivatable.run
            AnimalLoadingTriggerActivatable.run = function(activatable, ...)
                if isInteractionBlocked(activatable.owner) then
                    return
                end

                return original(activatable, ...)
            end
        end

        AnimalLoadingTriggerActivatable.taigaConstructionGuardsInstalled = true
    end
end

-- Блокирует животноводческое производство/кормление по времени, даже если
-- PlaceableHusbandry уже подписан на hourly/day/period events штатной игры.
local function installHusbandryRuntimeGuards()
    if PlaceableHusbandry ~= nil and not PlaceableHusbandry.taigaConstructionRuntimeGuardsInstalled then
        if PlaceableHusbandry.getNeedHourChanged ~= nil then
            local original = PlaceableHusbandry.getNeedHourChanged
            PlaceableHusbandry.getNeedHourChanged = function(placeable, superFunc, ...)
                if isFinalFacilityBlocked(placeable) then
                    return false
                end

                return original(placeable, superFunc, ...)
            end
        end

        if PlaceableHusbandry.onHourChanged ~= nil then
            local original = PlaceableHusbandry.onHourChanged
            PlaceableHusbandry.onHourChanged = function(placeable, ...)
                if isFinalFacilityBlocked(placeable) then
                    return
                end

                return original(placeable, ...)
            end
        end

        PlaceableHusbandry.taigaConstructionRuntimeGuardsInstalled = true
        logInfo("Husbandry hourly guards installed")
    end

    if PlaceableHusbandryAnimals ~= nil
        and not PlaceableHusbandryAnimals.taigaConstructionRuntimeGuardsInstalled then

        if PlaceableHusbandryAnimals.getNeedDayChanged ~= nil then
            local original = PlaceableHusbandryAnimals.getNeedDayChanged
            PlaceableHusbandryAnimals.getNeedDayChanged = function(placeable, superFunc, ...)
                if isFinalFacilityBlocked(placeable) then
                    return false
                end

                return original(placeable, superFunc, ...)
            end
        end

        if PlaceableHusbandryAnimals.onDayChanged ~= nil then
            local original = PlaceableHusbandryAnimals.onDayChanged
            PlaceableHusbandryAnimals.onDayChanged = function(placeable, ...)
                if isFinalFacilityBlocked(placeable) then
                    return
                end

                return original(placeable, ...)
            end
        end

        if PlaceableHusbandryAnimals.onPeriodChanged ~= nil then
            local original = PlaceableHusbandryAnimals.onPeriodChanged
            PlaceableHusbandryAnimals.onPeriodChanged = function(placeable, ...)
                if isFinalFacilityBlocked(placeable) then
                    return
                end

                return original(placeable, ...)
            end
        end

        PlaceableHusbandryAnimals.taigaConstructionRuntimeGuardsInstalled = true
        logInfo("Husbandry animal day/period guards installed")
    end
end

-- -------------------------------------------------------------------------
-- WoodUnloadTrigger guards
-- -------------------------------------------------------------------------

local function installWoodUnloadTriggerGuards()
    if WoodUnloadTrigger ~= nil and not WoodUnloadTrigger.taigaConstructionGuardsInstalled then
        if WoodUnloadTrigger.woodTriggerCallback ~= nil then
            local original = WoodUnloadTrigger.woodTriggerCallback
            WoodUnloadTrigger.woodTriggerCallback = function(trigger, triggerId, otherId, ...)
                if isInteractionBlocked(trigger) then
                    if trigger.woodInTrigger ~= nil then
                        trigger.woodInTrigger[otherId] = nil
                    end
                    if trigger.vehiclesInTrigger ~= nil then
                        trigger.vehiclesInTrigger[otherId] = nil
                    end
                    return
                end

                return original(trigger, triggerId, otherId, ...)
            end
        end

        if WoodUnloadTrigger.woodSellTriggerCallback ~= nil then
            local original = WoodUnloadTrigger.woodSellTriggerCallback
            WoodUnloadTrigger.woodSellTriggerCallback = function(trigger, ...)
                if isInteractionBlocked(trigger) then
                    removeActivatable(trigger.activatable)
                    return
                end

                return original(trigger, ...)
            end
        end

        if WoodUnloadTrigger.getCanProcessWood ~= nil then
            local original = WoodUnloadTrigger.getCanProcessWood
            WoodUnloadTrigger.getCanProcessWood = function(trigger, ...)
                if isInteractionBlocked(trigger) then
                    return false
                end

                return original(trigger, ...)
            end
        end

        WoodUnloadTrigger.taigaConstructionGuardsInstalled = true
        logInfo("WoodUnloadTrigger guards installed")
    end

    if WoodUnloadTriggerActivatable ~= nil
        and not WoodUnloadTriggerActivatable.taigaConstructionGuardsInstalled then

        if WoodUnloadTriggerActivatable.getIsActivatable ~= nil then
            local original = WoodUnloadTriggerActivatable.getIsActivatable
            WoodUnloadTriggerActivatable.getIsActivatable = function(activatable, ...)
                if isInteractionBlocked(activatable.woodUnloadTrigger) then
                    return false
                end

                return original(activatable, ...)
            end
        end

        if WoodUnloadTriggerActivatable.run ~= nil then
            local original = WoodUnloadTriggerActivatable.run
            WoodUnloadTriggerActivatable.run = function(activatable, ...)
                if isInteractionBlocked(activatable.woodUnloadTrigger) then
                    return
                end

                return original(activatable, ...)
            end
        end

        WoodUnloadTriggerActivatable.taigaConstructionGuardsInstalled = true
    end
end

-- -------------------------------------------------------------------------
-- Construction phase notifications
-- -------------------------------------------------------------------------

local function canShowNotification()
    return g_client ~= nil
        and g_currentMission ~= nil
        and g_currentMission.hud ~= nil
        and type(g_currentMission.addGameNotification) == "function"
end

-- Показывает строительное уведомление. Название объекта включается в текст,
-- чтобы формулировка оставалась однозначной даже при нескольких стройках одновременно.
local function showConstructionNotification(placeable, text)
    if not canShowNotification() then
        return
    end

    local placeableName = getPlaceableName(placeable)
    local notificationText = string.format("%s: %s", placeableName, text)

    g_currentMission:addGameNotification(
        placeableName,
        notificationText,
        "",
        nil,
        Fix.NOTIFICATION_DURATION_MS
    )
end

local function showCompletedPhaseNotification(placeable, completedStateIndex, phaseNumber)
    local lifecycle = getLifecycle()
    if lifecycle == nil then
        return
    end

    local phaseName = lifecycle.getConfiguredStateDisplayName(placeable, completedStateIndex)
    local text

    if phaseName ~= nil then
        local formatText = getText(
            "taiga_cl_phaseCompletedNamed",
            "phase \"%s\" completed"
        )
        text = string.format(formatText, phaseName)
    else
        local formatText = getText(
            "taiga_cl_phaseCompletedNumbered",
            "phase #%d completed"
        )
        text = string.format(formatText, phaseNumber or completedStateIndex or 0)
    end

    showConstructionNotification(placeable, text)
end

local function showConstructionCompletedNotification(placeable)
    showConstructionNotification(
        placeable,
        getText("taiga_cl_constructionCompleted", "construction completed")
    )
end

-- Отслеживает реальные переходы state machine каждый кадр.
-- Это надёжнее notification-hook на setConstructibleState: при загрузке savegame
-- GIANTS последовательно проигрывает уже сохранённые состояния, и такой hook
-- ошибочно сообщил бы игроку о давно завершённых фазах.
local function updateConstructionStateTracking(allowNotifications)
    if g_currentMission == nil or g_currentMission.placeableSystem == nil then
        return
    end

    local lifecycle = getLifecycle()
    local facilityLifecycle = getFacilityLifecycle()
    if lifecycle == nil then
        return
    end

    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables or {}) do
        if placeable.spec_constructible ~= nil then
            local currentStateIndex = lifecycle.getStateIndex(placeable)
            if currentStateIndex ~= nil then
                local tracked = Fix.notificationStates[placeable]

                if tracked == nil then
                    Fix.notificationStates[placeable] = {
                        stateIndex = currentStateIndex
                    }

                    -- Первый увиденный кадр объекта одновременно является самым ранним
                    -- безопасным моментом для регистрации его trigger-связей.
                    if facilityLifecycle ~= nil then
                        facilityLifecycle.synchronizePlaceable(placeable)
                    end
                elseif tracked.stateIndex ~= currentStateIndex then
                    local previousStateIndex = tracked.stateIndex
                    local spec = placeable.spec_constructible
                    local expectedNextState = spec.stateTransitions ~= nil
                        and spec.stateTransitions[previousStateIndex]
                        or nil
                    local isForwardCompletion = expectedNextState == currentStateIndex

                    tracked.stateIndex = currentStateIndex

                    -- Реальный lifecycle переключается сразу, уведомление не должно ждать
                    -- периодического защитного scan.
                    if facilityLifecycle ~= nil then
                        facilityLifecycle.synchronizePlaceable(placeable)
                    end

                    if allowNotifications and isForwardCompletion then
                        if lifecycle.isFinished(placeable) then
                            -- FINALIZE -> DONE: игрок получает одно итоговое сообщение.
                            showConstructionCompletedNotification(placeable)
                        else
                            local finishedStates, totalStates = lifecycle.getConstructionProgress(placeable)

                            -- Когда завершён последний содержательный этап, GIANTS обычно
                            -- переходит в технический FINALIZE, а следующим кадром в DONE.
                            -- Не показываем фазовое сообщение на несколько миллисекунд:
                            -- оно было бы тут же затёрто итоговым уведомлением.
                            if finishedStates < totalStates then
                                showCompletedPhaseNotification(
                                    placeable,
                                    previousStateIndex,
                                    finishedStates
                                )
                            end
                        end
                    end
                end
            end
        end
    end
end

-- -------------------------------------------------------------------------
-- Residual construction materials
-- -------------------------------------------------------------------------

local function getPalletDefinition(fillTypeIndex)
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType == nil or fillType.palletFilename == nil or fillType.palletFilename == "" then
        return nil
    end

    local palletXml = XMLFile.load("taigaConstructionResidualPalletXml", fillType.palletFilename, Vehicle.xmlSchema)
    if palletXml == nil then
        return nil
    end

    local capacity = FillUnit.getCapacityFromXml(palletXml)
    palletXml:delete()

    if capacity == nil or capacity <= 0 then
        return nil
    end

    return {
        filename = fillType.palletFilename,
        capacity = capacity,
        title = fillType.title or g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)
    }
end

local function getResidualSpawnAnchor(placeable)
    local node = nil
    local spec = placeable.spec_constructible

    if spec ~= nil and spec.unloadingStation ~= nil and spec.unloadingStation.unloadTriggers ~= nil then
        local trigger = spec.unloadingStation.unloadTriggers[1]
        if trigger ~= nil then
            node = trigger.exactFillRootNode or trigger.triggerNode or trigger.rootNode
        end
    end

    if node == nil or node == 0 then
        node = placeable.rootNode
            or (placeable.components ~= nil
                and placeable.components[1] ~= nil
                and placeable.components[1].node
                or nil)
    end

    if node == nil or node == 0 then
        return nil
    end

    return node
end

local function enqueueResidualPallets(placeable, fillTypeIndex, amount, palletDefinition, startSlot)
    local anchorNode = getResidualSpawnAnchor(placeable)
    if anchorNode == nil then
        logWarning(
            "Cannot spawn leftover %s (%.1f L) for %s: no anchor node",
            tostring(palletDefinition.title),
            amount,
            getPlaceableName(placeable)
        )
        return startSlot
    end

    local farmId = placeable:getOwnerFarmId()
    local remaining = amount
    local slot = startSlot

    while remaining > 0.1 do
        local chunk = math.min(remaining, palletDefinition.capacity)
        table.insert(Fix.palletQueue, {
            placeable = placeable,
            placeableName = getPlaceableName(placeable),
            anchorNode = anchorNode,
            fillTypeIndex = fillTypeIndex,
            amount = chunk,
            filename = palletDefinition.filename,
            title = palletDefinition.title,
            farmId = farmId,
            slot = slot
        })

        remaining = remaining - chunk
        slot = slot + 1
    end

    return slot
end

-- Снимает содержимое construction storage до вызова vanilla finalizeConstruction(),
-- потому что штатный код первым действием вызывает storage:empty().
function Fix.captureConstructionResiduals(placeable)
    if placeable == nil or not placeable.isServer then
        return
    end

    local spec = placeable.spec_constructible
    if spec == nil or spec.storage == nil then
        return
    end

    local slot = 0
    local queued = 0

    for fillTypeIndex, amount in pairs(spec.storage:getFillLevels()) do
        if amount ~= nil and amount > 0.1 then
            local palletDefinition = getPalletDefinition(fillTypeIndex)
            if palletDefinition ~= nil then
                local oldSlot = slot
                slot = enqueueResidualPallets(
                    placeable,
                    fillTypeIndex,
                    amount,
                    palletDefinition,
                    slot
                )
                queued = queued + (slot - oldSlot)
            else
                logWarning(
                    "Leftover construction material cannot be palletized and vanilla finalize will clear it: %s = %.1f L (%s)",
                    tostring(g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)),
                    amount,
                    getPlaceableName(placeable)
                )
            end
        end
    end

    if queued > 0 then
        logInfo(
            "Queued %d residual pallet(s) before finalizing %s",
            queued,
            getPlaceableName(placeable)
        )
    end
end

function Fix.finalizeConstruction(placeable, superFunc)
    Fix.captureConstructionResiduals(placeable)
    return superFunc(placeable)
end

local function installResidualMaterialHook()
    if PlaceableConstructible == nil
        or PlaceableConstructible.finalizeConstruction == nil
        or PlaceableConstructible.taigaConstructionResidualHookInstalled then
        return
    end

    PlaceableConstructible.finalizeConstruction = Utils.overwrittenFunction(
        PlaceableConstructible.finalizeConstruction,
        Fix.finalizeConstruction
    )

    PlaceableConstructible.taigaConstructionResidualHookInstalled = true
    logInfo("Construction residual-material hook installed")
end

local function getResidualPalletSpawnPosition(job)
    local column = job.slot % Fix.SPAWN_COLUMNS
    local row = math.floor(job.slot / Fix.SPAWN_COLUMNS)
    local centerColumn = (Fix.SPAWN_COLUMNS - 1) * 0.5
    local offsetX = (column - centerColumn) * Fix.SPAWN_SPACING
    local offsetZ = Fix.SPAWN_FORWARD_OFFSET + row * Fix.SPAWN_SPACING

    local x, _, z = localToWorld(job.anchorNode, offsetX, 0, offsetZ)
    local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.25
    local _, rotY, _ = getWorldRotation(job.anchorNode)

    return x, terrainY, z, rotY
end

function Fix.startNextPalletJob()
    if Fix.currentPalletJob ~= nil or #Fix.palletQueue == 0 then
        return
    end

    local job = Fix.palletQueue[1]
    if g_currentMission == nil or g_currentMission.slotSystem == nil then
        return
    end

    if not g_currentMission.slotSystem:getCanAddLimitedObjects(
        SlotSystem.LIMITED_OBJECT_PALLET,
        1
    ) then
        logWarning(
            "Pallet limit reached. Leftover pallet not spawned: %s %.1f L (%s)",
            tostring(job.title),
            job.amount,
            job.placeableName
        )
        table.remove(Fix.palletQueue, 1)
        return
    end

    if job.anchorNode == nil or job.anchorNode == 0 or not entityExists(job.anchorNode) then
        logWarning("Residual pallet anchor disappeared for %s", job.placeableName)
        table.remove(Fix.palletQueue, 1)
        return
    end

    local x, y, z, rotY = getResidualPalletSpawnPosition(job)
    Fix.currentPalletJob = job

    local data = VehicleLoadingData.new()
    data:setFilename(job.filename)
    data:setPosition(x, y, z)
    data:setRotation(0, rotY, 0)
    data:setPropertyState(VehiclePropertyState.OWNED)
    data:setOwnerFarmId(job.farmId)
    data:setCustomParameter("spawnEmpty", true)
    data:load(Fix.onResidualPalletLoaded, Fix)
end

function Fix:onResidualPalletLoaded(vehicles, vehicleLoadState)
    local job = Fix.currentPalletJob
    Fix.currentPalletJob = nil
    table.remove(Fix.palletQueue, 1)

    if job == nil then
        return
    end

    if vehicleLoadState ~= VehicleLoadingState.OK or vehicles == nil or vehicles[1] == nil then
        logWarning(
            "Failed to load residual pallet %s for %s",
            tostring(job.title),
            job.placeableName
        )
        return
    end

    local pallet = vehicles[1]
    if pallet.getFirstValidFillUnitToFill == nil or pallet.addFillUnitFillLevel == nil then
        logWarning("Spawned object is not a fillable pallet for %s", tostring(job.title))
        pallet:delete()
        return
    end

    local fillUnitIndex = pallet:getFirstValidFillUnitToFill(job.fillTypeIndex)
    if fillUnitIndex == nil then
        logWarning(
            "No compatible fill unit on pallet %s for %s",
            tostring(job.title),
            job.placeableName
        )
        pallet:delete()
        return
    end

    local added = pallet:addFillUnitFillLevel(
        job.farmId,
        fillUnitIndex,
        job.amount,
        job.fillTypeIndex,
        ToolType.UNDEFINED,
        nil
    )

    if added == nil or added <= 0 then
        logWarning(
            "Could not fill residual pallet %s for %s",
            tostring(job.title),
            job.placeableName
        )
        pallet:delete()
        return
    end

    if math.abs(added - job.amount) > 0.1 then
        logWarning(
            "Residual pallet accepted only %.1f / %.1f L of %s (%s)",
            added,
            job.amount,
            tostring(job.title),
            job.placeableName
        )
    end
end

-- -------------------------------------------------------------------------
-- Registry/lifecycle maintenance
-- -------------------------------------------------------------------------

local function pruneRemovedPlaceables()
    local registry = getRegistry()
    if registry == nil
        or registry.recordsByPlaceable == nil
        or g_currentMission == nil
        or g_currentMission.placeableSystem == nil then
        return
    end

    local activePlaceables = {}
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables or {}) do
        activePlaceables[placeable] = true
    end

    local removed = {}
    for placeable in pairs(registry.recordsByPlaceable) do
        if not activePlaceables[placeable] then
            table.insert(removed, placeable)
        end
    end

    local facilityLifecycle = getFacilityLifecycle()
    for _, placeable in ipairs(removed) do
        if facilityLifecycle ~= nil then
            facilityLifecycle.unregisterPlaceable(placeable)
        else
            registry.unregisterPlaceable(placeable)
        end
        Fix.notificationStates[placeable] = nil
    end
end

function Fix.synchronizeMission()
    local facilityLifecycle = getFacilityLifecycle()
    if facilityLifecycle ~= nil then
        facilityLifecycle.synchronizeMission()
    end

    pruneRemovedPlaceables()
end

-- -------------------------------------------------------------------------
-- Hook installation / ModEventListener
-- -------------------------------------------------------------------------

function Fix.installHooks()
    installStateNameSchemaHook()
    installInfoHUDHooks()
    installGenericTriggerGuards()
    installProductionInteractionGuard()
    installObjectStorageGuards()
    installSiloGuard()
    installAnimalLoadingTriggerGuards()
    installHusbandryRuntimeGuards()
    installWoodUnloadTriggerGuards()
    installResidualMaterialHook()

    Fix.hooksInstalled = true
end

function Fix:loadMap(mapName)
    self.syncTimer = 0
    self.notificationArmTimer = self.NOTIFICATION_ARM_DELAY_MS
    self.notificationStates = setmetatable({}, {__mode = "k"})
    self.currentPalletJob = nil
    table.clear(self.palletQueue)

    self.installHooks()
end

function Fix:update(dt)
    if not self.hooksInstalled then
        self.installHooks()
    end

    if g_currentMission == nil then
        return
    end

    if self.notificationArmTimer > 0 then
        self.notificationArmTimer = math.max(self.notificationArmTimer - dt, 0)
    end

    -- State transitions отслеживаются каждый кадр, потому что технический
    -- FINALIZE может существовать всего один update перед переходом в DONE.
    updateConstructionStateTracking(self.notificationArmTimer <= 0)

    self.syncTimer = self.syncTimer - dt
    if self.syncTimer <= 0 then
        self.syncTimer = self.SYNC_INTERVAL_MS
        self.synchronizeMission()
    end

    if g_server ~= nil and self.currentPalletJob == nil and #self.palletQueue > 0 then
        self.startNextPalletJob()
    end
end

function Fix:deleteMap()
    self.syncTimer = 0
    self.notificationArmTimer = self.NOTIFICATION_ARM_DELAY_MS
    self.notificationStates = setmetatable({}, {__mode = "k"})
    self.currentPalletJob = nil
    table.clear(self.palletQueue)

    local facilityLifecycle = getFacilityLifecycle()
    if facilityLifecycle ~= nil then
        facilityLifecycle.clear()
    end
end

Fix.installHooks()
addModEventListener(Fix)

logInfo("Loaded v%s", Fix.VERSION)

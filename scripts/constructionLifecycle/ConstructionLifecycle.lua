--[[
    Abandoned Taiga - Construction Lifecycle
    FS25

    Ядро подсистемы строительства. Файл не устанавливает глобальные hooks и не меняет HUD:
    он только определяет состояние constructible-объекта и предоставляет общие данные остальным
    модулям подсистемы.
]]

TaigaConstructionLifecycle = TaigaConstructionLifecycle or {}
local Lifecycle = TaigaConstructionLifecycle

Lifecycle.VERSION = "1.0.0"
Lifecycle.LOG_PREFIX = "[TaigaConstructionLifecycle]"

Lifecycle.STATE_NONE = 0
Lifecycle.STATE_UNDER_CONSTRUCTION = 1
Lifecycle.STATE_FINISHED = 2

-- Возвращает отображаемое имя placeable для журналирования и уведомлений игроку.
function Lifecycle.getPlaceableName(placeable)
    if placeable == nil then
        return "<nil>"
    end

    if type(placeable.getName) == "function" then
        local name = placeable:getName()
        if name ~= nil and name ~= "" then
            return tostring(name)
        end
    end

    if placeable.configFileName ~= nil then
        return tostring(placeable.configFileName)
    end

    return tostring(placeable)
end

-- Возвращает constructible-специализацию только для корректно инициализированного объекта.
function Lifecycle.getConstructibleSpec(placeable)
    if placeable == nil then
        return nil
    end

    return placeable.spec_constructible
end

-- Возвращает текущий индекс состояния state machine либо nil, пока она не инициализирована.
function Lifecycle.getStateIndex(placeable)
    local spec = Lifecycle.getConstructibleSpec(placeable)
    if spec == nil or spec.stateIndex == nil or spec.stateIndex < 1 then
        return nil
    end

    return spec.stateIndex
end

-- Возвращает объект текущего состояния constructible state machine.
function Lifecycle.getState(placeable, stateIndex)
    local spec = Lifecycle.getConstructibleSpec(placeable)
    if spec == nil or spec.stateMachine == nil then
        return nil
    end

    stateIndex = stateIndex or Lifecycle.getStateIndex(placeable)
    if stateIndex == nil then
        return nil
    end

    return spec.stateMachine[stateIndex]
end

-- Возвращает индекс следующего состояния. Отсутствие перехода является штатным признаком DONE.
function Lifecycle.getNextStateIndex(placeable, stateIndex)
    local spec = Lifecycle.getConstructibleSpec(placeable)
    if spec == nil or spec.stateTransitions == nil then
        return nil
    end

    stateIndex = stateIndex or Lifecycle.getStateIndex(placeable)
    if stateIndex == nil then
        return nil
    end

    return spec.stateTransitions[stateIndex]
end

-- Определяет lifecycle-состояние объекта по штатной state machine GIANTS.
-- FINALIZE ещё имеет переход в DONE и потому относится к строящемуся объекту.
function Lifecycle.getLifecycleState(placeable)
    local stateIndex = Lifecycle.getStateIndex(placeable)
    if stateIndex == nil then
        return Lifecycle.STATE_NONE
    end

    if Lifecycle.getNextStateIndex(placeable, stateIndex) ~= nil then
        return Lifecycle.STATE_UNDER_CONSTRUCTION
    end

    return Lifecycle.STATE_FINISHED
end

-- Проверяет, находится ли constructible в любой незавершённой фазе, включая FINALIZE.
function Lifecycle.isUnderConstruction(placeable)
    return Lifecycle.getLifecycleState(placeable) == Lifecycle.STATE_UNDER_CONSTRUCTION
end

-- Проверяет, достиг ли constructible конечного состояния без дальнейшего перехода.
function Lifecycle.isFinished(placeable)
    return Lifecycle.getLifecycleState(placeable) == Lifecycle.STATE_FINISHED
end

-- Возвращает количество завершённых строительных фаз и общее количество фаз.
-- Используется штатный метод PlaceableConstructible, чтобы не дублировать правила GIANTS.
function Lifecycle.getConstructionProgress(placeable)
    if placeable == nil or type(placeable.getNumFinishedConstructibleStates) ~= "function" then
        return 0, 0
    end

    return placeable:getNumFinishedConstructibleStates()
end

-- Читает пользовательское имя фазы из #StateName.
-- Атрибут оставлен расширением карты и не подменяет штатное техническое #name.
function Lifecycle.getConfiguredStateDisplayName(placeable, stateIndex)
    if placeable == nil or placeable.xmlFile == nil or stateIndex == nil or stateIndex < 1 then
        return nil
    end

    local key = string.format(
        "placeable.constructible.stateMachine.states.state(%d)#StateName",
        stateIndex - 1
    )

    local value
    if type(placeable.xmlFile.getI18NValue) == "function" then
        value = placeable.xmlFile:getI18NValue(key, nil, placeable.customEnvironment, false)
    else
        value = placeable.xmlFile:getValue(key)
    end

    if value == nil then
        return nil
    end

    value = tostring(value)
    if string.match(value, "^%s*$") then
        return nil
    end

    return value
end

-- Возвращает имя фазы для интерфейса. Сначала используется #StateName,
-- затем техническое имя state machine как безопасный fallback.
function Lifecycle.getStateDisplayName(placeable, stateIndex)
    stateIndex = stateIndex or Lifecycle.getStateIndex(placeable)
    if stateIndex == nil then
        return nil
    end

    local configuredName = Lifecycle.getConfiguredStateDisplayName(placeable, stateIndex)
    if configuredName ~= nil then
        return configuredName
    end

    local state = Lifecycle.getState(placeable, stateIndex)
    if state ~= nil and state.name ~= nil and state.name ~= "" then
        return tostring(state.name)
    end

    return nil
end

-- Возвращает порядковый номер завершённой фазы после перехода в новое состояние.
-- Значение строится на штатном getNumFinishedConstructibleStates(), поэтому совпадает с HUD игры.
function Lifecycle.getCompletedPhaseNumber(placeable)
    local finishedStates = Lifecycle.getConstructionProgress(placeable)
    return math.max(finishedStates or 0, 0)
end

-- Проверяет, принадлежит ли station строительной разгрузочной станции конкретного placeable.
function Lifecycle.isConstructionUnloadingStation(placeable, station)
    local spec = Lifecycle.getConstructibleSpec(placeable)
    return spec ~= nil and spec.unloadingStation ~= nil and station == spec.unloadingStation
end

-- Возвращает владельца штатной station, если GIANTS связал её через owningPlaceable.
-- Более сложные trigger-target связи будут централизованы в ConstructionTriggerRegistry.lua.
function Lifecycle.getStationPlaceable(station)
    if station == nil then
        return nil
    end

    return station.owningPlaceable
end

Logging.info("%s loaded, version %s", Lifecycle.LOG_PREFIX, Lifecycle.VERSION)

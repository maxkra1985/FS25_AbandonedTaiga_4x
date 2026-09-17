--[[
    LoggingContractorTrigger

    Модуль триггера подрядчиков на лесоповал.

    Текущий этап:
    - привязка к trigger-node карты с атрибутом loggingContractor=true;
    - добавление действия по кнопке R через ActivatableObjectsSystem;
    - открытие окна подрядчиков при активации.

    В дальнейшем сюда будет добавлена проверка доступности действия с учётом
    состояния активного договора и прав игрока.
]]

LoggingContractorTrigger = {}
local LoggingContractorTrigger_mt = Class(LoggingContractorTrigger)

LoggingContractorTriggerActivatable = {}
local LoggingContractorTriggerActivatable_mt = Class(LoggingContractorTriggerActivatable)


-- Создаёт объект триггера и регистрирует callback для локального клиента.
function LoggingContractorTrigger.new(triggerNode)
    local self = setmetatable({}, LoggingContractorTrigger_mt)
    self.triggerNode = triggerNode
    self.activatable = LoggingContractorTriggerActivatable.new(self)

    addTrigger(triggerNode, "triggerCallback", self)

    return self
end


-- Удаляет callback триггера и возможное активное действие из HUD.
function LoggingContractorTrigger:delete()
    if self.activatable ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(self.activatable)
        self.activatable = nil
    end

    if self.triggerNode ~= nil then
        removeTrigger(self.triggerNode)
        self.triggerNode = nil
    end
end


-- Добавляет или убирает действие по кнопке R при входе/выходе локального игрока.
function LoggingContractorTrigger:triggerCallback(triggerId, otherId, onEnter, onLeave, onStay)
    if g_localPlayer == nil or otherId ~= g_localPlayer.rootNode then
        return
    end

    if onEnter then
        g_currentMission.activatableObjectsSystem:addActivatable(self.activatable)
    elseif onLeave then
        g_currentMission.activatableObjectsSystem:removeActivatable(self.activatable)
    end
end


-- Создаёт activatable, отображаемый системой действий игрока.
function LoggingContractorTriggerActivatable.new(trigger)
    local self = setmetatable({}, LoggingContractorTriggerActivatable_mt)
    self.trigger = trigger
    self.activateText = "Подрядчики на лесоповал"

    return self
end


-- Разрешает действие только пешему игроку, состоящему в обычной ферме.
function LoggingContractorTriggerActivatable:getIsActivatable()
    if g_localPlayer == nil or g_localPlayer:getIsInVehicle() then
        return false
    end

    return g_currentMission:getFarmId() ~= FarmManager.SPECTATOR_FARM_ID
end


-- Открывает окно подрядчиков.
function LoggingContractorTriggerActivatable:run()
    LoggingContractorDialog.show()
end

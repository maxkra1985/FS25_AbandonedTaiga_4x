--[[
    LoggingContractor

    Главный модуль системы подрядчиков на лесоповал.

    В дальнейшем модуль будет отвечать за:
    - поиск и регистрацию специального триггера карты;
    - подготовку списка принадлежащих ферме участков;
    - сканирование деревьев выбранного участка и группировку по породам;
    - расчёт количества техники, длительности и стоимости договора;
    - создание, восстановление и завершение активного LoggingContractorJob;
    - синхронизацию состояния договора между сервером и клиентами.
]]

LoggingContractor = {}
local LoggingContractor_mt = Class(LoggingContractor)


-- Создаёт менеджер подрядчиков для текущей миссии.
function LoggingContractor.new(mission)
    local self = setmetatable({}, LoggingContractor_mt)
    self.mission = mission
    self.trigger = nil

    return self
end


-- Ищет единственный trigger-node карты, помеченный атрибутом loggingContractor=true.
function LoggingContractor:findTriggerNode()
    local rootNode = getRootNode()
    if rootNode == nil or rootNode == 0 then
        return nil
    end

    local nodes = {rootNode}
    while #nodes > 0 do
        local node = table.remove(nodes)

        if getUserAttribute(node, "loggingContractor") == true then
            return node
        end

        for i = 0, getNumOfChildren(node) - 1 do
            table.insert(nodes, getChildAt(node, i))
        end
    end

    return nil
end


-- Регистрирует клиентский activatable на специальном триггере карты.
function LoggingContractor:initialize()
    if not self.mission:getIsClient() then
        return
    end

    local triggerNode = self:findTriggerNode()
    if triggerNode == nil then
        Logging.warning("[LoggingContractor] Trigger with loggingContractor=true was not found")
        return
    end

    self.trigger = LoggingContractorTrigger.new(triggerNode)
    Logging.info("[LoggingContractor] Trigger registered: %s", getName(triggerNode))
end


-- Удаляет зарегистрированный триггер при завершении миссии.
function LoggingContractor:delete()
    if self.trigger ~= nil then
        self.trigger:delete()
        self.trigger = nil
    end
end

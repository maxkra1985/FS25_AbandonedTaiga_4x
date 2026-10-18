--[[
    LoggingContractorStartEvent

    Клиентский запрос серверу на заключение договора на лесоповал.

    Клиент передаёт участок, количество техники, длину распила и режим обрезки.
    Ферму отправителя, принадлежность участка, количество деревьев, стоимость и
    баланс сервер определяет и проверяет самостоятельно.
]]

LoggingContractorStartEvent = {}
local LoggingContractorStartEvent_mt = Class(LoggingContractorStartEvent, Event)
InitEventClass(LoggingContractorStartEvent, "LoggingContractorStartEvent")


-- Создаёт пустое сетевое событие для десериализации GIANTS Engine.
function LoggingContractorStartEvent.emptyNew()
    return Event.new(LoggingContractorStartEvent_mt)
end


-- Создаёт клиентский запрос с параметрами, которые пользователь действительно
-- выбирает в интерфейсе. Расчётные значения намеренно не передаются.
function LoggingContractorStartEvent.new(farmlandId, equipmentCount, logLength, onlyMarkedTrees, pruneLargeBranches, selectedSpecies)
    local self = LoggingContractorStartEvent.emptyNew()
    self.farmlandId = farmlandId
    self.equipmentCount = equipmentCount
    self.logLength = logLength
    self.onlyMarkedTrees = onlyMarkedTrees == true
    self.pruneLargeBranches = pruneLargeBranches ~= false
    self.selectedSpecies = selectedSpecies

    return self
end


-- Сериализует минимальный набор пользовательских параметров договора.
function LoggingContractorStartEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.farmlandId, g_farmlandManager.numberOfBits)
    streamWriteUInt32(streamId, self.equipmentCount)
    streamWriteUInt8(streamId, self.logLength)
    streamWriteBool(streamId, self.onlyMarkedTrees)
    streamWriteBool(streamId, self.pruneLargeBranches)
    streamWriteBool(streamId, self.selectedSpecies ~= nil)
    if self.selectedSpecies ~= nil then
        streamWriteUInt8(streamId, #self.selectedSpecies)
        for _, name in ipairs(self.selectedSpecies) do
            streamWriteString(streamId, name)
        end
    end
end


-- Читает запрос клиента и передаёт его серверной обработке.
function LoggingContractorStartEvent:readStream(streamId, connection)
    self.farmlandId = streamReadUIntN(streamId, g_farmlandManager.numberOfBits)
    self.equipmentCount = streamReadUInt32(streamId)
    self.logLength = streamReadUInt8(streamId)
    self.onlyMarkedTrees = streamReadBool(streamId)
    self.pruneLargeBranches = streamReadBool(streamId)
    if streamReadBool(streamId) then
        self.selectedSpecies = {}
        local count = streamReadUInt8(streamId)
        for _ = 1, count do
            table.insert(self.selectedSpecies, streamReadString(streamId))
        end
    end
    self:run(connection)
end


-- На сервере выполняет полный набор проверок и возвращает результат только
-- тому соединению, которое запросило заключение договора.
function LoggingContractorStartEvent:run(connection)
    if connection:getIsServer() then
        return
    end

    local contractor = g_currentMission ~= nil and g_currentMission.loggingContractor or nil
    local state = LoggingContractorResultEvent.STATE_INTERNAL_ERROR
    local data = nil

    if contractor ~= nil then
        state, data = contractor:startContract(
            connection,
            self.farmlandId,
            self.equipmentCount,
            self.logLength,
            self.onlyMarkedTrees,
            self.pruneLargeBranches,
            self.selectedSpecies
        )
    end

    connection:sendEvent(LoggingContractorResultEvent.new(state, data))
end


-- Отправляет запрос текущему серверу. Метод используется GUI и одинаково
-- работает для обычного клиента и локального клиента хоста.
function LoggingContractorStartEvent.sendEvent(farmlandId, equipmentCount, logLength, onlyMarkedTrees, pruneLargeBranches, selectedSpecies)
    if g_client == nil then
        return false
    end

    local connection = g_client:getServerConnection()
    if connection == nil then
        return false
    end

    connection:sendEvent(LoggingContractorStartEvent.new(
        farmlandId, equipmentCount, logLength, onlyMarkedTrees, pruneLargeBranches, selectedSpecies
    ))
    return true
end

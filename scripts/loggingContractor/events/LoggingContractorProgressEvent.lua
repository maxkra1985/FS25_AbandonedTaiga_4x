--[[
    LoggingContractorProgressEvent

    Серверная синхронизация состояния активного договора на лесоповал.
    Событие передаёт только состояние уже созданного LoggingContractorJob и
    используется клиентами для HUD и завершения локального представления задачи.
]]

LoggingContractorProgressEvent = {}
local LoggingContractorProgressEvent_mt = Class(LoggingContractorProgressEvent, Event)
InitEventClass(LoggingContractorProgressEvent, "LoggingContractorProgressEvent")


-- Создаёт пустое сетевое событие для десериализации GIANTS Engine.
function LoggingContractorProgressEvent.emptyNew()
    return Event.new(LoggingContractorProgressEvent_mt)
end


-- Создаёт снимок текущего состояния серверной задачи.
function LoggingContractorProgressEvent.new(job)
    local self = LoggingContractorProgressEvent.emptyNew()
    self.jobId = job.jobId
    self.farmId = job.farmId
    self.farmlandId = job.farmlandId
    self.plannedTrees = job.plannedTrees
    self.contractorCutTrees = job.contractorCutTrees or 0
    self.remainingTrees = job.remainingTrees or job.plannedTrees
    self.equipmentCount = job.equipmentCount
    self.logLength = job.logLength
    self.state = job.state

    return self
end


-- Сериализует состояние договора для клиентов.
function LoggingContractorProgressEvent:writeStream(streamId, connection)
    streamWriteUInt32(streamId, self.jobId)
    streamWriteUIntN(streamId, self.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    streamWriteUIntN(streamId, self.farmlandId, g_farmlandManager.numberOfBits)
    streamWriteUInt32(streamId, self.plannedTrees)
    streamWriteUInt32(streamId, self.contractorCutTrees)
    streamWriteUInt32(streamId, self.remainingTrees)
    streamWriteUInt32(streamId, self.equipmentCount)
    streamWriteUInt8(streamId, self.logLength)
    streamWriteUInt8(streamId, self.state)
end


-- Читает состояние договора и передаёт его клиентскому менеджеру подрядчиков.
function LoggingContractorProgressEvent:readStream(streamId, connection)
    self.jobId = streamReadUInt32(streamId)
    self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self.farmlandId = streamReadUIntN(streamId, g_farmlandManager.numberOfBits)
    self.plannedTrees = streamReadUInt32(streamId)
    self.contractorCutTrees = streamReadUInt32(streamId)
    self.remainingTrees = streamReadUInt32(streamId)
    self.equipmentCount = streamReadUInt32(streamId)
    self.logLength = streamReadUInt8(streamId)
    self.state = streamReadUInt8(streamId)

    self:run(connection)
end


-- Применяет событие только на клиенте, получившем его от сервера.
function LoggingContractorProgressEvent:run(connection)
    if not connection:getIsServer() then
        return
    end

    local contractor = g_currentMission ~= nil and g_currentMission.loggingContractor or nil
    if contractor ~= nil then
        contractor:onJobProgress(self)
    end
end

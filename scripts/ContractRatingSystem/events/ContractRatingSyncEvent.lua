--[[
    ContractRatingSyncEvent
    Передаёт начало снимка и отдельные записи рейтингового журнала.
    Каждая запись отправляется отдельным событием без ограничения общей истории.
]]
ContractRatingSyncEvent = {}
local ContractRatingSyncEvent_mt = Class(ContractRatingSyncEvent, Event)
InitEventClass(ContractRatingSyncEvent, "ContractRatingSyncEvent")

-- Создаёт пустое событие для чтения из потока.
function ContractRatingSyncEvent.emptyNew()
    return Event.new(ContractRatingSyncEvent_mt)
end

-- Создаёт событие очистки клиентского снимка (kind=0) или передачи операции (kind=1).
function ContractRatingSyncEvent.new(kind, entry)
    local self = ContractRatingSyncEvent.emptyNew()
    self.kind = kind
    self.entry = entry
    return self
end

-- Записывает операцию рейтинга в сетевой поток.
function ContractRatingSyncEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.kind)
    if self.kind == 1 then
        local entry = self.entry
        streamWriteString(streamId, entry.id)
        streamWriteUIntN(streamId, entry.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteString(streamId, entry.attemptId)
        streamWriteFloat32(streamId, entry.delta)
        streamWriteString(streamId, entry.reason)
    end
end

-- Читает операцию рейтинга и применяет её к клиентскому представлению.
function ContractRatingSyncEvent:readStream(streamId, connection)
    self.kind = streamReadUInt8(streamId)
    if self.kind == 1 then
        self.entry = {
            id = streamReadString(streamId),
            farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS),
            attemptId = streamReadString(streamId),
            delta = streamReadFloat32(streamId),
            reason = streamReadString(streamId)
        }
    end
    self:run(connection)
end

-- Клиент принимает данные только с серверного соединения.
function ContractRatingSyncEvent:run(connection)
    if not connection:getIsServer() then
        return
    end
    local mission = g_currentMission
    local runtime = mission ~= nil and mission.contractRatingRuntime or nil
    if runtime ~= nil then
        runtime:receiveSync(self.kind, self.entry)
    end
end

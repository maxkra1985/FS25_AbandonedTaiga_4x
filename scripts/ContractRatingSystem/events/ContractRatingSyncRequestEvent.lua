--[[
    ContractRatingSyncRequestEvent
    Пустой запрос журнала: сервер самостоятельно выбирает соединение получателя.
]]
ContractRatingSyncRequestEvent = {}
local ContractRatingSyncRequestEvent_mt = Class(ContractRatingSyncRequestEvent, Event)
InitEventClass(ContractRatingSyncRequestEvent, "ContractRatingSyncRequestEvent")

-- Создаёт запрос снимка.
function ContractRatingSyncRequestEvent.new()
    return Event.new(ContractRatingSyncRequestEvent_mt)
end

-- Запрос не содержит данных, предоставляемых клиентом.
function ContractRatingSyncRequestEvent:writeStream(streamId, connection)
end

-- После десериализации запускает серверный обработчик.
function ContractRatingSyncRequestEvent:readStream(streamId, connection)
    self:run(connection)
end

-- Отвечает журналом только запрашивающему соединению.
function ContractRatingSyncRequestEvent:run(connection)
    if connection:getIsServer() then
        return
    end
    local mission = g_currentMission
    local runtime = mission ~= nil and mission.contractRatingRuntime or nil
    if runtime ~= nil then
        runtime:sendSnapshot(connection)
    end
end

-- Запрашивает актуальный журнал после готовности клиентской миссии.
function ContractRatingSyncRequestEvent.sendEvent()
    if g_client == nil then
        return false
    end
    local connection = g_client:getServerConnection()
    if connection == nil then
        return false
    end
    connection:sendEvent(ContractRatingSyncRequestEvent.new())
    return true
end

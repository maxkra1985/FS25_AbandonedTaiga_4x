--[[
    LoggingContractorSyncRequestEvent

    Клиентский запрос текущего состояния активных договоров своей фермы.
    Используется после входа в ферму и после повторного подключения к серверу,
    чтобы восстановленные из savegame договоры появились в клиентском HUD.
]]

LoggingContractorSyncRequestEvent = {}
local LoggingContractorSyncRequestEvent_mt = Class(LoggingContractorSyncRequestEvent, Event)
InitEventClass(LoggingContractorSyncRequestEvent, "LoggingContractorSyncRequestEvent")


-- Создаёт пустое событие для отправки запроса и десериализации GIANTS Engine.
function LoggingContractorSyncRequestEvent.emptyNew()
    return Event.new(LoggingContractorSyncRequestEvent_mt)
end


-- Создаёт запрос без пользовательских данных: ферма определяется сервером
-- по сетевому соединению отправителя.
function LoggingContractorSyncRequestEvent.new()
    return LoggingContractorSyncRequestEvent.emptyNew()
end


-- У запроса нет полезной нагрузки.
function LoggingContractorSyncRequestEvent:writeStream(streamId, connection)
end


-- После чтения сразу передаёт запрос серверной обработке.
function LoggingContractorSyncRequestEvent:readStream(streamId, connection)
    self:run(connection)
end


-- Сервер отправляет клиенту все активные договоры только его текущей фермы.
function LoggingContractorSyncRequestEvent:run(connection)
    if connection:getIsServer() then
        return
    end

    local contractor = g_currentMission ~= nil and g_currentMission.loggingContractor or nil
    if contractor ~= nil then
        contractor:syncActiveJobsToConnection(connection)
    end
end


-- Отправляет запрос текущему серверу.
function LoggingContractorSyncRequestEvent.sendEvent()
    if g_client == nil then
        return false
    end

    local connection = g_client:getServerConnection()
    if connection == nil then
        return false
    end

    connection:sendEvent(LoggingContractorSyncRequestEvent.new())
    return true
end

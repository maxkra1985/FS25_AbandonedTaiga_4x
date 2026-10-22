-- Сетевые события трёх подвижных радиоприёмников карты.
-- Управляющие запросы идут клиент -> сервер; состояние только сервер -> клиенты.
TaigaRadioMapReceiverEvent = {}
local TaigaRadioMapReceiverEvent_mt = Class(TaigaRadioMapReceiverEvent, Event)
InitEventClass(TaigaRadioMapReceiverEvent, "TaigaRadioMapReceiverEvent")

TaigaRadioMapReceiverEvent.TYPE_ACTION = 1
TaigaRadioMapReceiverEvent.TYPE_STATE = 2
TaigaRadioMapReceiverEvent.TYPE_SNAPSHOT_REQUEST = 3

TaigaRadioMapReceiverEvent.ACTION_TOGGLE = 1
TaigaRadioMapReceiverEvent.ACTION_NEXT = 2
TaigaRadioMapReceiverEvent.ACTION_PREVIOUS = 3
TaigaRadioMapReceiverEvent.ACTION_VOLUME_UP = 4
TaigaRadioMapReceiverEvent.ACTION_VOLUME_DOWN = 5

-- Создаёт пустой экземпляр события для потокового чтения.
function TaigaRadioMapReceiverEvent.emptyNew()
    return Event.new(TaigaRadioMapReceiverEvent_mt)
end

-- Формирует запрос на действие возле одного из приёмников.
function TaigaRadioMapReceiverEvent.newAction(receiverId, action)
    local self = TaigaRadioMapReceiverEvent.emptyNew()
    self.eventType = TaigaRadioMapReceiverEvent.TYPE_ACTION
    self.receiverId = receiverId
    self.action = action
    return self
end

-- Формирует серверное подтверждение текущего состояния приёмника.
function TaigaRadioMapReceiverEvent.newState(receiver)
    local self = TaigaRadioMapReceiverEvent.emptyNew()
    self.eventType = TaigaRadioMapReceiverEvent.TYPE_STATE
    self.receiverId = receiver.id
    self.enabled = receiver.enabled
    self.trackIndex = receiver.trackIndex
    self.volumeSteps = math.floor(receiver.volume * 10 + 0.5)
    self.elapsedMs = receiver.elapsedMs
    return self
end

-- Создаёт запрос повторной отправки состояния после входа клиента в игру.
function TaigaRadioMapReceiverEvent.newSnapshotRequest()
    local self = TaigaRadioMapReceiverEvent.emptyNew()
    self.eventType = TaigaRadioMapReceiverEvent.TYPE_SNAPSHOT_REQUEST
    return self
end

-- Записывает тип сообщения, затем только соответствующие ему данные.
function TaigaRadioMapReceiverEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.eventType)
    if self.eventType == TaigaRadioMapReceiverEvent.TYPE_ACTION then
        streamWriteUInt8(streamId, self.receiverId)
        streamWriteUInt8(streamId, self.action)
    elseif self.eventType == TaigaRadioMapReceiverEvent.TYPE_STATE then
        streamWriteUInt8(streamId, self.receiverId)
        streamWriteBool(streamId, self.enabled)
        streamWriteUInt16(streamId, self.trackIndex)
        streamWriteUInt8(streamId, self.volumeSteps)
        streamWriteFloat32(streamId, self.elapsedMs)
    end
end

-- Восстанавливает данные и передаёт их обработчику соответствующей стороны.
function TaigaRadioMapReceiverEvent:readStream(streamId, connection)
    self.eventType = streamReadUInt8(streamId)
    if self.eventType == TaigaRadioMapReceiverEvent.TYPE_ACTION then
        self.receiverId = streamReadUInt8(streamId)
        self.action = streamReadUInt8(streamId)
    elseif self.eventType == TaigaRadioMapReceiverEvent.TYPE_STATE then
        self.receiverId = streamReadUInt8(streamId)
        self.enabled = streamReadBool(streamId)
        self.trackIndex = streamReadUInt16(streamId)
        self.volumeSteps = streamReadUInt8(streamId)
        self.elapsedMs = streamReadFloat32(streamId)
    end
    self:run(connection)
end

-- Разделяет неподтверждённые запросы и авторитетное состояние сервера.
function TaigaRadioMapReceiverEvent:run(connection)
    local mission = g_currentMission
    local system = mission ~= nil and mission.taigaRadioMapReceivers or nil
    if system == nil then
        return
    end

    if self.eventType == TaigaRadioMapReceiverEvent.TYPE_ACTION then
        if not connection:getIsServer() and mission:getIsServer() then
            system:handleRemoteAction(connection, self.receiverId, self.action)
        end
    elseif self.eventType == TaigaRadioMapReceiverEvent.TYPE_STATE then
        if connection:getIsServer() and mission:getIsClient() then
            system:applyNetworkState(
                self.receiverId, self.enabled, self.trackIndex,
                self.volumeSteps * 0.1, self.elapsedMs
            )
        end
    elseif self.eventType == TaigaRadioMapReceiverEvent.TYPE_SNAPSHOT_REQUEST then
        if not connection:getIsServer() and mission:getIsServer() then
            system:sendSnapshot(connection)
        end
    end
end

-- Отправляет команду от сетевого клиента, не изменяя локальное состояние.
function TaigaRadioMapReceiverEvent.sendAction(receiverId, action)
    if g_client == nil or g_client:getServerConnection() == nil then
        return false
    end
    g_client:getServerConnection():sendEvent(
        TaigaRadioMapReceiverEvent.newAction(receiverId, action)
    )
    return true
end

-- Рассылает подтверждённое изменение состояния от сервера всем клиентам.
function TaigaRadioMapReceiverEvent.broadcastState(receiver)
    if g_server ~= nil then
        g_server:broadcastEvent(TaigaRadioMapReceiverEvent.newState(receiver), false)
    end
end

-- Дополнительно запрашивает полное состояние после начала клиентской миссии.
function TaigaRadioMapReceiverEvent.requestSnapshot()
    if g_client ~= nil and g_client:getServerConnection() ~= nil then
        g_client:getServerConnection():sendEvent(
            TaigaRadioMapReceiverEvent.newSnapshotRequest()
        )
    end
end

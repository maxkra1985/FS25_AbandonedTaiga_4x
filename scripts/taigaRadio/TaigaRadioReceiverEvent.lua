-- Синхронизация состояния стационарных радиоприёмников.
-- Клиент отправляет запрос, сервер рассылает выбранный трек и позицию.
TaigaRadioReceiverEvent = {}
local TaigaRadioReceiverEvent_mt = Class(TaigaRadioReceiverEvent, Event)
InitEventClass(TaigaRadioReceiverEvent, "TaigaRadioReceiverEvent")

-- Создаёт пустое событие для движка.
function TaigaRadioReceiverEvent.emptyNew()
    return Event.new(TaigaRadioReceiverEvent_mt)
end

-- Создаёт запрос переключения либо серверное сообщение о новом состоянии.
function TaigaRadioReceiverEvent.new(placeable, isRequest, enabled, trackIndex, elapsedMs)
    local self = TaigaRadioReceiverEvent.emptyNew()
    self.placeable = placeable
    self.isRequest = isRequest == true
    self.enabled = enabled == true
    self.trackIndex = trackIndex or 0
    self.elapsedMs = elapsedMs or 0
    return self
end

-- Записывает ссылку на приёмник и состояние.
function TaigaRadioReceiverEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    streamWriteBool(streamId, self.isRequest)
    if not self.isRequest then
        streamWriteBool(streamId, self.enabled)
        streamWriteUInt16(streamId, self.trackIndex)
        streamWriteFloat32(streamId, self.elapsedMs)
    end
end

-- Читает событие и исполняет на соответствующей стороне сети.
function TaigaRadioReceiverEvent:readStream(streamId, connection)
    self.placeable = NetworkUtil.readNodeObject(streamId)
    self.isRequest = streamReadBool(streamId)
    if not self.isRequest then
        self.enabled = streamReadBool(streamId)
        self.trackIndex = streamReadUInt16(streamId)
        self.elapsedMs = streamReadFloat32(streamId)
    end
    self:run(connection)
end

-- Клиентские запросы исполняет только сервер, результат получают все клиенты.
function TaigaRadioReceiverEvent:run(connection)
    local placeable = self.placeable
    if placeable == nil or placeable.taigaRadioReceiverSetState == nil then
        return
    end
    if self.isRequest then
        if connection:getIsServer() or not placeable.isServer then
            return
        end
        local spec = placeable[PlaceableTaigaRadioReceiver.SPEC_TABLE]
        if spec == nil then
            return
        end
        local radio = g_currentMission ~= nil and g_currentMission.taigaRadio or nil
        local trackIndex = radio ~= nil and PlaceableTaigaRadioReceiver.getNextTrack(radio, 0) or nil
        if trackIndex == nil then
            return
        end
        placeable:taigaRadioReceiverSetState(not spec.enabled, trackIndex, 0, true)
    elseif connection:getIsServer() then
        placeable:taigaRadioReceiverSetState(self.enabled, self.trackIndex, self.elapsedMs, false)
    end
end

-- Отправляет серверу запрос на нажатие кнопки приёмника.
function TaigaRadioReceiverEvent.sendRequest(placeable)
    if g_client ~= nil and g_client:getServerConnection() ~= nil then
        g_client:getServerConnection():sendEvent(
            TaigaRadioReceiverEvent.new(placeable, true)
        )
        return true
    end
    return false
end

-- Рассылает подтверждённое состояние приёмника всем клиентам.
function TaigaRadioReceiverEvent.broadcast(placeable, enabled, trackIndex, elapsedMs)
    if g_server ~= nil then
        g_server:broadcastEvent(TaigaRadioReceiverEvent.new(
            placeable, false, enabled, trackIndex, elapsedMs
        ), false)
    end
end

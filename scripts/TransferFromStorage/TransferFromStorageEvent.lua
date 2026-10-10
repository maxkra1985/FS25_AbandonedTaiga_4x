-- Передача одного виртуального объекта со склада в целевое хранилище.
-- Запрос отправляется клиентом, проверяется и исполняется только сервером.
TransferFromStorageEvent = {}
local TransferFromStorageEvent_mt = Class(TransferFromStorageEvent, Event)
InitEventClass(TransferFromStorageEvent, "TransferFromStorageEvent")

function TransferFromStorageEvent.emptyNew()
    return Event.new(TransferFromStorageEvent_mt)
end

-- Создаёт запрос на перемещение одного целого тюка или поддона.
function TransferFromStorageEvent.newRequest(placeable, isBale, fillType, amount)
    local self = TransferFromStorageEvent.emptyNew()
    self.placeable = placeable
    self.isResponse = false
    self.isBale = isBale
    self.fillType = fillType
    self.amount = amount
    return self
end

-- Создаёт адресный ответ игроку, запрашивавшему передачу.
function TransferFromStorageEvent.newResult(placeable, success, message)
    local self = TransferFromStorageEvent.emptyNew()
    self.placeable = placeable
    self.isResponse = true
    self.success = success
    self.message = message or ""
    return self
end

-- Сериализует запрос и ответ через штатный NetworkUtil.
function TransferFromStorageEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.placeable)
    streamWriteBool(streamId, self.isResponse)
    if self.isResponse then
        streamWriteBool(streamId, self.success)
        streamWriteString(streamId, self.message)
    else
        streamWriteBool(streamId, self.isBale)
        streamWriteUIntN(streamId, self.fillType, FillTypeManager.SEND_NUM_BITS)
        streamWriteFloat32(streamId, self.amount)
    end
end

-- Получает пакет и передаёт его обработчику нужной стороны сети.
function TransferFromStorageEvent:readStream(streamId, connection)
    self.placeable = NetworkUtil.readNodeObject(streamId)
    self.isResponse = streamReadBool(streamId)
    if self.isResponse then
        self.success = streamReadBool(streamId)
        self.message = streamReadString(streamId)
    else
        self.isBale = streamReadBool(streamId)
        self.fillType = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
        self.amount = streamReadFloat32(streamId)
    end
    self:run(connection)
end

-- Никогда не доверяет клиентским объёмам и правам: сервер перепроверяет всё.
function TransferFromStorageEvent:run(connection)
    if self.isResponse then
        if connection:getIsServer() and TransferFromStorageDialog ~= nil then
            TransferFromStorageDialog.onTransferResult(self.placeable, self.success, self.message)
        end
        return
    end
    if connection:getIsServer() then
        return
    end

    local success, message = false, "Объект передачи недоступен."
    if self.placeable ~= nil and self.placeable.transferFromStorageExecute ~= nil then
        success, message = self.placeable:transferFromStorageExecute(
            connection, self.isBale, self.fillType, self.amount
        )
    end
    connection:sendEvent(TransferFromStorageEvent.newResult(
        self.placeable, success, message
    ))
end

-- Отправляет запрос через серверное соединение текущего клиента.
function TransferFromStorageEvent.sendRequest(placeable, isBale, fillType, amount)
    if g_client == nil or g_client:getServerConnection() == nil then
        return false
    end
    g_client:getServerConnection():sendEvent(
        TransferFromStorageEvent.newRequest(placeable, isBale, fillType, amount)
    )
    return true
end

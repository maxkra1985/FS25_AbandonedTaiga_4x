--[[
    ContractRatingProductionNoticeEvent
    Серверное уведомление о недоступном рецепте или его автоматическом
    отключении после снижения рейтинга. Получатель не может изменять рейтинг.
]]
ContractRatingProductionNoticeEvent = {}
local ContractRatingProductionNoticeEvent_mt =
    Class(ContractRatingProductionNoticeEvent, Event)
InitEventClass(ContractRatingProductionNoticeEvent, "ContractRatingProductionNoticeEvent")

ContractRatingProductionNoticeEvent.DENIED = 1
ContractRatingProductionNoticeEvent.DISABLED = 2
ContractRatingProductionNoticeEvent.PERMISSION = 3

-- Создаёт сообщение для конкретного игрока фермы.
function ContractRatingProductionNoticeEvent.new(kind, productionName, required, current)
    local self = Event.new(ContractRatingProductionNoticeEvent_mt)
    self.kind = kind
    self.productionName = productionName or ""
    self.required = required or 0
    self.current = current or 0
    return self
end

-- Передаёт только текст рецепта и числовые параметры рейтинга.
function ContractRatingProductionNoticeEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.kind)
    streamWriteString(streamId, self.productionName)
    streamWriteInt32(streamId, self.required)
    streamWriteFloat32(streamId, self.current)
end

-- Принимает уведомления исключительно от сервера.
function ContractRatingProductionNoticeEvent:readStream(streamId, connection)
    self.kind = streamReadUInt8(streamId)
    self.productionName = streamReadString(streamId)
    self.required = streamReadInt32(streamId)
    self.current = streamReadFloat32(streamId)
    self:run(connection)
end

-- Выводит отказ отдельным предупреждением, а принудительное отключение в HUD.
function ContractRatingProductionNoticeEvent:run(connection)
    if not connection:getIsServer() or g_currentMission == nil then return end

    local name = self.productionName ~= "" and self.productionName or "Производственный рецепт"
    if self.kind == ContractRatingProductionNoticeEvent.PERMISSION then
        InfoDialog.show("Недостаточно прав для управления производством: " .. name,
            nil, nil, DialogElement.TYPE_WARNING)
        return
    end

    local message = string.format(
        "%s: требуется рейтинг %d, текущий %g.",
        name, self.required, self.current)

    if self.kind == ContractRatingProductionNoticeEvent.DISABLED then
        g_currentMission:addIngameNotification(
            FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            "Рецепт автоматически отключён. " .. message)
    else
        InfoDialog.show("Недостаточно рейтинга для включения рецепта. " .. message,
            nil, nil, DialogElement.TYPE_WARNING)
    end
end

--[[ Сетевое сообщение о нехватке рейтинга при принятии контракта. ]]
ContractRatingAccessDeniedEvent = {}
local ContractRatingAccessDeniedEvent_mt = Class(ContractRatingAccessDeniedEvent, Event)
InitEventClass(ContractRatingAccessDeniedEvent, "ContractRatingAccessDeniedEvent")

-- Создаёт сетевое событие с причиной отказа.
function ContractRatingAccessDeniedEvent.new(required, current)
    local self = Event.new(ContractRatingAccessDeniedEvent_mt)
    self.required = required
    self.current = current
    return self
end

-- Записывает значения рейтинга в ответ сервера.
function ContractRatingAccessDeniedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.required)
    streamWriteInt32(streamId, self.current)
end

-- Десериализует причину отказа и показывает сообщение.
function ContractRatingAccessDeniedEvent:readStream(streamId, connection)
    self.required = streamReadInt32(streamId)
    self.current = streamReadInt32(streamId)
    self:run(connection)
end

-- Доверяет только серверному соединению, не принимает клиентские сообщения.
function ContractRatingAccessDeniedEvent:run(connection)
    if not connection:getIsServer() then
        return
    end
    InfoDialog.show(
        string.format(
            "Недостаточно рейтинга для принятия контракта. Требуется: %d; текущий: %d.",
            self.required, self.current
        ),
        nil, nil, DialogElement.TYPE_WARNING
    )
end

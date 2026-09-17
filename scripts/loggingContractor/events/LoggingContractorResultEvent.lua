--[[
    LoggingContractorResultEvent

    Ответ сервера на запрос заключения договора на лесоповал.
    Клиент получает только результат серверной проверки и рассчитанные сервером
    параметры созданной задачи; клиентские стоимость и количество деревьев не
    считаются доверенными данными.
]]

LoggingContractorResultEvent = {}
local LoggingContractorResultEvent_mt = Class(LoggingContractorResultEvent, Event)
InitEventClass(LoggingContractorResultEvent, "LoggingContractorResultEvent")

LoggingContractorResultEvent.STATE_SUCCESS = 0
LoggingContractorResultEvent.STATE_NO_PERMISSION = 1
LoggingContractorResultEvent.STATE_FARM_NOT_FOUND = 2
LoggingContractorResultEvent.STATE_FARMLAND_NOT_FOUND = 3
LoggingContractorResultEvent.STATE_FARMLAND_NOT_OWNED = 4
LoggingContractorResultEvent.STATE_NO_TREES = 5
LoggingContractorResultEvent.STATE_INVALID_EQUIPMENT = 6
LoggingContractorResultEvent.STATE_INVALID_LOG_LENGTH = 7
LoggingContractorResultEvent.STATE_NOT_ENOUGH_MONEY = 8
LoggingContractorResultEvent.STATE_ALREADY_ACTIVE = 9
LoggingContractorResultEvent.STATE_INTERNAL_ERROR = 10


-- Создаёт пустое сетевое событие для десериализации GIANTS Engine.
function LoggingContractorResultEvent.emptyNew()
    return Event.new(LoggingContractorResultEvent_mt)
end


-- Создаёт ответ сервера. Для успешного ответа data содержит только уже
-- проверенные сервером параметры созданного LoggingContractorJob.
function LoggingContractorResultEvent.new(state, data)
    local self = LoggingContractorResultEvent.emptyNew()
    self.state = state or LoggingContractorResultEvent.STATE_INTERNAL_ERROR

    if self.state == LoggingContractorResultEvent.STATE_SUCCESS and data ~= nil then
        self.jobId = data.jobId
        self.farmId = data.farmId
        self.farmlandId = data.farmlandId
        self.plannedTrees = data.plannedTrees
        self.equipmentCount = data.equipmentCount
        self.logLength = data.logLength
        self.workHours = data.workHours
        self.billableHours = data.billableHours
        self.rentCost = data.rentCost
        self.equipmentWorkCost = data.equipmentWorkCost
        self.workerCost = data.workerCost
        self.totalCost = data.totalCost
    end

    return self
end


-- Сериализует результат. Полный набор параметров передаётся только при успехе.
function LoggingContractorResultEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.state)

    if self.state ~= LoggingContractorResultEvent.STATE_SUCCESS then
        return
    end

    streamWriteUInt32(streamId, self.jobId)
    streamWriteUIntN(streamId, self.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    streamWriteUIntN(streamId, self.farmlandId, g_farmlandManager.numberOfBits)
    streamWriteUInt32(streamId, self.plannedTrees)
    streamWriteUInt32(streamId, self.equipmentCount)
    streamWriteUInt8(streamId, self.logLength)
    streamWriteFloat32(streamId, self.workHours)
    streamWriteUInt32(streamId, self.billableHours)
    streamWriteUInt32(streamId, self.rentCost)
    streamWriteUInt32(streamId, self.equipmentWorkCost)
    streamWriteUInt32(streamId, self.workerCost)
    streamWriteUInt32(streamId, self.totalCost)
end


-- Читает ответ сервера и передаёт его клиентскому менеджеру подрядчиков.
function LoggingContractorResultEvent:readStream(streamId, connection)
    self.state = streamReadUInt8(streamId)

    if self.state == LoggingContractorResultEvent.STATE_SUCCESS then
        self.jobId = streamReadUInt32(streamId)
        self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
        self.farmlandId = streamReadUIntN(streamId, g_farmlandManager.numberOfBits)
        self.plannedTrees = streamReadUInt32(streamId)
        self.equipmentCount = streamReadUInt32(streamId)
        self.logLength = streamReadUInt8(streamId)
        self.workHours = streamReadFloat32(streamId)
        self.billableHours = streamReadUInt32(streamId)
        self.rentCost = streamReadUInt32(streamId)
        self.equipmentWorkCost = streamReadUInt32(streamId)
        self.workerCost = streamReadUInt32(streamId)
        self.totalCost = streamReadUInt32(streamId)
    end

    self:run(connection)
end


-- Применяет серверный ответ только на клиентской стороне.
function LoggingContractorResultEvent:run(connection)
    if not connection:getIsServer() then
        return
    end

    local contractor = g_currentMission ~= nil and g_currentMission.loggingContractor or nil
    if contractor ~= nil then
        contractor:onStartContractResult(self)
    end
end

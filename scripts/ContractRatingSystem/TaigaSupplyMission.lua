--[[
    TaigaSupplyMission
    Штатная миссия поставки продукции.
    Генератор намеренно не публикует контракт без разрешённой точки,
    fillType и объёма. Контроль разгрузки подключается отдельно.
]]
TaigaSupplyMission = {}
local TaigaSupplyMission_mt = Class(TaigaSupplyMission, AbstractMission)
TaigaSupplyMission.TYPE_NAME = "taigaSupplyMission"

-- Регистрирует дополнительные XML-поля для сохранения миссий.
function TaigaSupplyMission.registerSavegameXMLPaths(schema, key)
    AbstractMission.registerSavegameXMLPaths(schema, key)
    schema:register(XMLValueType.STRING, key .. ".supply#stationKind", "Supply station category")
    schema:register(XMLValueType.STRING, key .. ".supply#stationId", "Target station unique id")
    schema:register(XMLValueType.STRING, key .. ".supply#fillType", "Required fill type")
    schema:register(XMLValueType.FLOAT, key .. ".supply#required", "Required liters")
    schema:register(XMLValueType.FLOAT, key .. ".supply#delivered", "Delivered liters")
    schema:register(XMLValueType.INT, key .. ".supply#monthIndex", "Generated month")
end

-- Создаёт экземпляр без выдачи награды и без доступного товара.
function TaigaSupplyMission.new(isServer, isClient)
    local self = AbstractMission.new(
        isServer, isClient, "Поставка продукции",
        "Доставьте указанную продукцию в назначенную точку приёма.",
        TaigaSupplyMission_mt
    )
    self.stationKind = nil
    self.stationId = nil
    self.fillTypeName = nil
    self.requiredLiters = 0
    self.deliveredLiters = 0
    self.monthIndex = nil
    self.vehiclesToLoad = {}
    self.vehicleGroupIdentifier = -1
    return self
end

-- Возвращает имя зарегистрированного типа миссии.
function TaigaSupplyMission:getMissionTypeName()
    return TaigaSupplyMission.TYPE_NAME
end

-- Не предлагает аренду: доставка выполняется техникой игрока.
function TaigaSupplyMission:getVehicleGroup()
    return {}, -1
end

-- Возвращает текущий прогресс реальной доставки.
function TaigaSupplyMission:getCompletion()
    if self.requiredLiters <= 0 then
        return 0
    end
    return math.min(self.deliveredLiters / self.requiredLiters, 1)
end

-- Проверяет содержательность задания и штатный срок действия.
function TaigaSupplyMission:validate()
    return self.stationId ~= nil
        and self.stationKind ~= nil
        and self.fillTypeName ~= nil
        and self.requiredLiters > 0
        and AbstractMission.validate(self)
end

-- Учитывает только подтверждённые сервером литры от назначенной фермы.
-- Вызывающий обработчик триггера должен гарантировать принятый объём.
function TaigaSupplyMission:addDeliveredLiters(farmId, stationId, fillTypeName, liters)
    if not self.isServer or self.status ~= MissionStatus.RUNNING
        or farmId ~= self.farmId or stationId ~= self.stationId
        or fillTypeName ~= self.fillTypeName or type(liters) ~= "number"
        or liters <= 0 or liters ~= liters then
        return 0
    end
    local accepted = math.min(liters, self.requiredLiters - self.deliveredLiters)
    if accepted <= 0 then
        return 0
    end
    self.deliveredLiters = self.deliveredLiters + accepted
    self.completion = self:getCompletion()
    self:raiseDirtyFlags(self.missionDirtyFlag)
    if self.completion >= 1 then
        self:finish(MissionFinishState.SUCCESS)
    end
    return accepted
end

-- Сохраняет собственные параметры вместе со штатным состоянием миссии.
function TaigaSupplyMission:saveToXMLFile(xmlFile, key)
    AbstractMission.saveToXMLFile(self, xmlFile, key)
    xmlFile:setValue(key .. ".supply#stationKind", self.stationKind)
    xmlFile:setValue(key .. ".supply#stationId", self.stationId)
    xmlFile:setValue(key .. ".supply#fillType", self.fillTypeName)
    xmlFile:setValue(key .. ".supply#required", self.requiredLiters)
    xmlFile:setValue(key .. ".supply#delivered", self.deliveredLiters)
    xmlFile:setValue(key .. ".supply#monthIndex", self.monthIndex)
end

-- Загружает данные поставки, отвергая пустые или повреждённые задания.
function TaigaSupplyMission:loadFromXMLFile(xmlFile, key)
    if not AbstractMission.loadFromXMLFile(self, xmlFile, key) then
        return false
    end
    self.stationKind = xmlFile:getValue(key .. ".supply#stationKind")
    self.stationId = xmlFile:getValue(key .. ".supply#stationId")
    self.fillTypeName = xmlFile:getValue(key .. ".supply#fillType")
    self.requiredLiters = xmlFile:getValue(key .. ".supply#required", 0)
    self.deliveredLiters = xmlFile:getValue(key .. ".supply#delivered", 0)
    self.monthIndex = xmlFile:getValue(key .. ".supply#monthIndex")
    return self:validate() and self.deliveredLiters >= 0
        and self.deliveredLiters <= self.requiredLiters
end

-- Передаёт параметры задания при подключении сетевого клиента.
function TaigaSupplyMission:writeStream(streamId, connection)
    AbstractMission.writeStream(self, streamId, connection)
    streamWriteString(streamId, self.stationKind or "")
    streamWriteString(streamId, self.stationId or "")
    streamWriteString(streamId, self.fillTypeName or "")
    streamWriteFloat32(streamId, self.requiredLiters)
    streamWriteFloat32(streamId, self.deliveredLiters)
    streamWriteInt32(streamId, self.monthIndex or -1)
end

-- Восстанавливает параметры задания из серверного сетевого потока.
function TaigaSupplyMission:readStream(streamId, connection)
    AbstractMission.readStream(self, streamId, connection)
    self.stationKind = streamReadString(streamId)
    self.stationId = streamReadString(streamId)
    self.fillTypeName = streamReadString(streamId)
    self.requiredLiters = streamReadFloat32(streamId)
    self.deliveredLiters = streamReadFloat32(streamId)
    self.monthIndex = streamReadInt32(streamId)
end

-- Не создаёт необеспеченных предложений без проверенной станции и товара.
function TaigaSupplyMission.tryGenerateMission()
    return nil
end

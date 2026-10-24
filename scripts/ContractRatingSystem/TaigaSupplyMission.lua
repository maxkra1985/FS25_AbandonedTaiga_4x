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
    schema:register(XMLValueType.STRING, key .. ".supply#category", "Supply duration category")
    schema:register(XMLValueType.STRING, key .. ".supply#customer", "External buyer organization")
    schema:register(XMLValueType.INT, key .. ".supply#baseAmount", "Fixed base value")
    schema:register(XMLValueType.INT, key .. ".supply#deliveryPremium", "Fixed delivery premium")
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
    self.supplyCategory = nil
    self.customerName = nil
    self.baseAmount = nil
    self.deliveryPremium = nil
    self.vehiclesToLoad = nil
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

-- Запрещает штатному GUI предлагать аренду даже при восстановлении старого сохранения.
function TaigaSupplyMission:hasLeasableVehicles()
    return false
end

-- Контракты поставки не арендуют технику и не имеют расходов на аренду.
function TaigaSupplyMission:getVehicleCosts()
    return 0
end

-- Возвращает текущий прогресс реальной доставки.
function TaigaSupplyMission:getCompletion()
    if self.requiredLiters <= 0 then
        return 0
    end
    return math.min(self.deliveredLiters / self.requiredLiters, 1)
end

-- Названия точек и типов сроков для штатного меню контрактов.
TaigaSupplyMission.STATION_NAMES = {
    elevator = "Элеватор Степаныча",
    wood = "Лесник Михалыч",
    pallets = "Скупка продукции у Дмитрича"
}
TaigaSupplyMission.CATEGORY_NAMES = {
    short = "Краткосрочный (1/12 месяца)",
    medium = "Среднесрочный (1 месяц)",
    long = "Долгосрочный (3 месяца)"
}

-- Подставляет существующего персонажа карты для выбранного предприятия.
function TaigaSupplyMission:getNPC()
    local profiles = {
        elevator = {title = "Степаныч", filename = "map/npc/helper.png"},
        wood = {title = "Михалыч", filename = "map/npc/forester.png"},
        pallets = {title = "Дмитрич", filename = "map/npc/farmer.png"}
    }
    local profile = profiles[self.stationKind]
    local mission = g_currentMission
    if profile == nil or mission == nil or mission.baseDirectory == nil then
        return nil
    end
    return {
        title = profile.title,
        imageFilename = Utils.getFilename(profile.filename, mission.baseDirectory)
    }
end

-- Центрирует мини-карту контракта на его пункте приёма, а не на (0, 0).
-- Координаты берутся из фактически загруженного placeable на клиенте.
function TaigaSupplyMission:getWorldPosition()
    local _, placeable = ContractSupplyStations.resolve(self.stationKind)
    if placeable ~= nil and placeable.uniqueId == self.stationId
        and placeable.rootNode ~= nil and placeable.rootNode ~= 0 then
        local x, _, z = getWorldTranslation(placeable.rootNode)
        return x, z
    end
    -- При отсутствии объекта не центрируем карту на случайной позиции.
    return nil, nil
end

-- Возвращает читаемое название товара, используя зарегистрированный fillType.
function TaigaSupplyMission:getProductName()
    if self.fillTypeName == "WOOD" then
        return "Древесина"
    end
    local fillType = self.fillTypeName ~= nil
        and g_fillTypeManager:getFillTypeByName(self.fillTypeName) or nil
    if fillType ~= nil then
        return fillType.title or fillType.name
    end
    return self.fillTypeName or "Не указано"
end

-- Формирует заголовок контракта после загрузки и для сетевых клиентов.
function TaigaSupplyMission:getTitle()
    return "Поставка: " .. self:getProductName()
end

-- Указывает реальную точку, а не пустую стандартную локацию.
function TaigaSupplyMission:getLocation()
    return TaigaSupplyMission.STATION_NAMES[self.stationKind] or "Неизвестная точка"
end

-- Описывает товар, объём, пункт назначения и сроки выполнения.
function TaigaSupplyMission:getDescription()
    local product = self:getProductName()
    local destination = self:getLocation()
    local category = TaigaSupplyMission.CATEGORY_NAMES[self.supplyCategory] or "Не указана"
    local opening
    if self.customerName ~= nil and self.customerName ~= "" then
        opening = string.format("Организация «%s» закупает продукцию «%s». Посредником выступает %s.",
            self.customerName, product,
            ({elevator = "Степаныч", wood = "Михалыч", pallets = "Дмитрич"})[self.stationKind] or "местный представитель")
    else
        opening = string.format("Внешний заказчик закупает продукцию «%s» через местного посредника.", product)
    end
    return string.format("%s Доставьте %s в пункт «%s». Объём: %.0f л. %s. Срок с момента принятия.",
        opening, product, destination, self.requiredLiters or 0, category)
end

-- Возвращает разбивку итоговой суммы. Старые сохранения не содержат полей. 
function TaigaSupplyMission:getPaymentBreakdown()
    if self.baseAmount ~= nil and self.deliveryPremium ~= nil then
        return self.baseAmount, self.deliveryPremium
    end
    local category = ContractSupplyEconomy.categories[self.supplyCategory]
    if category == nil or type(self.reward) ~= "number" then
        return nil, nil
    end
    -- Для старых предложений восстанавливаем суммы из зафиксированной награды;
    -- исходная цена не сохранялась, поэтому возможна разница округления на 1 евро.
    local base = math.floor(self.reward / (1 + category.premium) + 0.5)
    return base, self.reward - base
end

-- Показывает условия поставки в деталях; аренда техники недоступна.
function TaigaSupplyMission:getDetails()
    local required = self.requiredLiters or 0
    local delivered = self.deliveredLiters or 0
    local base, premium = self:getPaymentBreakdown()
    local details = {
        {title = "Продукция", value = self:getProductName()},
        {title = "Пункт приёма", value = self:getLocation()},
        {title = "Категория", value = TaigaSupplyMission.CATEGORY_NAMES[self.supplyCategory] or "Не указана"},
        {title = "Требуется", value = string.format("%.0f л", required)},
        {title = "Поставлено", value = string.format("%.0f л", delivered)}
    }
    if self.customerName ~= nil and self.customerName ~= "" then
        table.insert(details, 1, {title = "Заказчик", value = self.customerName})
    end
    if base ~= nil then
        details[#details + 1] = {title = "Стоимость продукции", value = g_i18n:formatMoney(base, 0, true, true)}
        details[#details + 1] = {title = "Премия за доставку", value = g_i18n:formatMoney(premium, 0, true, true)}
    end
    details[#details + 1] = {title = "Итого", value = g_i18n:formatMoney(self:getReward(), 0, true, true)}
    return details
end

-- Отображает текущую поставку рядом с индикатором прогресса.
function TaigaSupplyMission:getExtraProgressText()
    return string.format("%.0f / %.0f л",
        self.deliveredLiters or 0, self.requiredLiters or 0)
end

-- Возвращает сумму, зафиксированную при генерации предложения.
function TaigaSupplyMission:getReward()
    return self.reward or 0
end

-- Назначает срок выполнения от момента принятия, сохраняя штатный запуск.
function TaigaSupplyMission:start(spawnVehicles)
    local duration = ContractSupplyEconomy.getDuration(
        self.supplyCategory, g_currentMission.environment.daysPerPeriod)
    if duration == nil then return false end
    self:setEndDateByOffset(duration)
    return AbstractMission.start(self, spawnVehicles)
end

-- Проверяет содержательность задания и штатный срок действия.
function TaigaSupplyMission:validate()
    return self.stationId ~= nil
        and self.stationKind ~= nil
        and self.fillTypeName ~= nil
        and self.requiredLiters > 0
        and ContractSupplyEconomy.categories[self.supplyCategory] ~= nil
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
    xmlFile:setValue(key .. ".supply#category", self.supplyCategory)
    if self.customerName ~= nil then
        xmlFile:setValue(key .. ".supply#customer", self.customerName)
    end
    if self.baseAmount ~= nil then
        xmlFile:setValue(key .. ".supply#baseAmount", self.baseAmount)
        xmlFile:setValue(key .. ".supply#deliveryPremium", self.deliveryPremium)
    end
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
    self.supplyCategory = xmlFile:getValue(key .. ".supply#category")
    self.customerName = xmlFile:getValue(key .. ".supply#customer")
    self.baseAmount = xmlFile:getValue(key .. ".supply#baseAmount")
    self.deliveryPremium = xmlFile:getValue(key .. ".supply#deliveryPremium")
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
    streamWriteString(streamId, self.supplyCategory or "")
    streamWriteString(streamId, self.customerName or "")
    local base, premium = self:getPaymentBreakdown()
    streamWriteInt32(streamId, base or -1)
    streamWriteInt32(streamId, premium or -1)
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
    self.supplyCategory = streamReadString(streamId)
    self.customerName = streamReadString(streamId)
    local base = streamReadInt32(streamId)
    local premium = streamReadInt32(streamId)
    self.baseAmount = base >= 0 and base or nil
    self.deliveryPremium = premium >= 0 and premium or nil
end

-- Не создаёт необеспеченных предложений без проверенной станции и товара.
function TaigaSupplyMission.tryGenerateMission()
    return nil
end

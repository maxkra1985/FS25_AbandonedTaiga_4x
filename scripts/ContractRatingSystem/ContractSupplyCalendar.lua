--[[
    ContractSupplyCalendar
    Серверный наблюдатель игрового календаря и сохранения квартальной ротации.
    До появления полноценной миссии только определяет ожидаемую категорию;
    не помечает месяц сгенерированным и не создаёт пустое предложение.
]]
ContractSupplyCalendar = {}
ContractSupplyCalendar.__index = ContractSupplyCalendar

-- Создаёт обработчик календаря для конкретной миссии.
function ContractSupplyCalendar.new(mission)
    return setmetatable({
        mission = mission,
        rotation = ContractSupplyRotation.new(),
        lastObservedMonth = nil,
        regenerationDelayMs = nil,
        previousDaysPerPeriod = mission.environment.daysPerPeriod
    }, ContractSupplyCalendar)
end

-- Возвращает абсолютный индекс месяца по штатным currentYear/currentPeriod.
-- Индекс первого месяца первого года равен нулю.
function ContractSupplyCalendar.getMonthIndex(environment)
    if environment == nil or type(environment.currentYear) ~= "number"
        or type(environment.currentPeriod) ~= "number" then
        return nil
    end
    local year = environment.currentYear
    local period = environment.currentPeriod
    if year < 1 or year % 1 ~= 0 or period < 1
        or period > Environment.PERIODS_IN_YEAR or period % 1 ~= 0 then
        return nil
    end
    return (year - 1) * Environment.PERIODS_IN_YEAR + period - 1
end

-- Отслеживает текущий месяц, не выдавая задание без полноценного генератора.
function ContractSupplyCalendar:checkCurrentPeriod()
    local environment = self.mission.environment
    local index = ContractSupplyCalendar.getMonthIndex(environment)
    if index == nil or index == self.lastObservedMonth then
        return
    end
    self.lastObservedMonth = index
    if not self.rotation:canGenerate(index) then return end

    local kind = self.rotation:getTypeForMonth(index)
    local candidates = {}
    -- У пунктов покупки нет SellingStation. Скупщика выбираем только
    -- по фактической поддержке товара у разрешённых точек сдачи.
    for _, product in ipairs(ContractSupplySeasonality.getCandidates(
        kind, environment.currentPeriod)) do
        if product.index ~= nil then
            local target, placeable = ContractSupplyStations.resolve(kind, nil, product.index)
            if target ~= nil and placeable ~= nil
                and target:getIsFillTypeAllowed(product.index) then
                local fillType = g_fillTypeManager:getFillTypeByIndex(product.index)
                if fillType ~= nil and type(fillType.pricePerLiter) == "number"
                    and fillType.pricePerLiter > 0 then
                    candidates[#candidates + 1] = {
                        fillType = fillType,
                        placeable = placeable
                    }
                end
            end
        end
    end
    if #candidates == 0 then
        Logging.warning("[ContractRating] No accepted priced fillTypes for %s in period %d; proposal not generated",
            tostring(kind), environment.currentPeriod)
        return
    end

    local categories = {"short", "medium", "long"}
    local category = categories[math.random(#categories)]
    local difficulty = self.mission.missionInfo.economicDifficulty
    local liters = ContractSupplyVolumes.getRequiredLiters(kind, category, difficulty)
    if liters == nil then
        Logging.warning("[ContractRating] Missing volume for %s / %s", kind, category)
        return
    end
    local candidate = candidates[math.random(#candidates)]
    local fillType = candidate.fillType
    local placeable = candidate.placeable
    local baseAmount, deliveryPremium, reward = ContractSupplyEconomy.calculateBreakdown(fillType, liters, category)
    if reward == nil then return end

    local missionType = g_missionManager:getMissionType(TaigaSupplyMission.TYPE_NAME)
    if missionType == nil or missionType.data.numInstances >= missionType.data.maxNumInstances then
        return
    end

    local contract = TaigaSupplyMission.new(true, g_client ~= nil)
    contract.stationKind = kind
    contract.stationId = placeable.uniqueId
    contract.fillTypeName = fillType.name
    contract.fillTypeIndex = fillType.index
    contract.requiredLiters = liters
    contract.reward = reward
    contract.baseAmount = baseAmount
    contract.deliveryPremium = deliveryPremium
    contract.monthIndex = index
    contract.supplyCategory = category
    contract.customerName = ContractSupplyCustomers.choose(kind, fillType.name)
    contract.completion = 0
    -- Предложение действительно только до конца текущего игрового дня.
    contract:setEndDate(environment.currentMonotonicDay, 86399999)

    if not contract:validate() then
        contract:delete()
        return
    end

    g_missionManager:registerMission(contract, missionType)
    local id = contract:getUniqueId()
    if id == nil or g_missionManager:getMissionByUniqueId(id) ~= contract then
        Logging.warning("[ContractRating] Mission registration failed for month %d", index)
        return
    end
    if not self.rotation:markGenerated(index, tostring(id)) then
        Logging.warning("[ContractRating] Cannot record generated month %d", index)
    end
    Logging.info("[ContractRating] Supply generated: month %d, %s, %s, %d l, reward %d",
        index, kind, fillType.name, liters, reward)
end

-- Возобновляет месячную поставку, когда текущее предложение удалено.
-- Не трогает чужие контракты и успешные завершения.
function ContractSupplyCalendar:onMissionDeleted(contract)
    if contract == nil or contract.type == nil
        or contract.type.name ~= TaigaSupplyMission.TYPE_NAME
        or not self.mission:getIsServer() then
        return
    end
    local current = ContractSupplyCalendar.getMonthIndex(self.mission.environment)
    if current == nil or contract.monthIndex ~= current then
        return
    end
    if contract.finishState == MissionFinishState.SUCCESS then
        self.rotation:markCompleted(current, contract:getUniqueId())
        return
    end
    if self.rotation:clearGenerated(current, contract:getUniqueId()) then
        self:scheduleReplacement(current)
    end
end

-- Генерирует замену после провала, отмены или истечения срока.
function ContractSupplyCalendar:onMissionFinished(contract, finishState)
    if contract == nil or contract.type == nil
        or contract.type.name ~= TaigaSupplyMission.TYPE_NAME
        or finishState == MissionFinishState.SUCCESS
        or not self.mission:getIsServer() then
        return
    end
    local current = ContractSupplyCalendar.getMonthIndex(self.mission.environment)
    if contract.monthIndex == current and finishState == MissionFinishState.SUCCESS then
        self.rotation:markCompleted(current, contract:getUniqueId())
        return
    end
    if contract.monthIndex == current
        and self.rotation:clearGenerated(current, contract:getUniqueId()) then
        self:scheduleReplacement(current)
    end
end

-- Помещает создание замены в очередь, не выполняя его из события удаления.
-- Таймер основан на реальном dt: изменение скорости игры не влияет на задержку.
function ContractSupplyCalendar:scheduleReplacement(monthIndex)
    local current = ContractSupplyCalendar.getMonthIndex(self.mission.environment)
    if monthIndex ~= current then return end
    self.regenerationDelayMs = 45000
    Logging.info("[ContractRating] Supply replacement queued for month %d (45 sec)", monthIndex)
end

-- Обрабатывает очередь после выхода из обработчиков удаления и завершения.
function ContractSupplyCalendar:update(dt)
    if self.regenerationDelayMs == nil or self.mission == nil
        or not self.mission:getIsServer() then return end
    self.regenerationDelayMs = self.regenerationDelayMs - math.max(dt or 0, 0)
    if self.regenerationDelayMs > 0 then return end
    self.regenerationDelayMs = nil
    self.lastObservedMonth = nil
    self:checkCurrentPeriod()
end

-- Масштабирует оставшееся время активных поставок при смене длины месяца.
-- Предложения не масштабируются: они всегда действуют до конца дня.
function ContractSupplyCalendar:onPeriodLengthChanged(newDays)
    local oldDays = self.previousDaysPerPeriod
    self.previousDaysPerPeriod = newDays
    if not self.mission:getIsServer() or oldDays == nil or oldDays <= 0
        or type(newDays) ~= "number" or newDays <= 0 then return end
    if oldDays == newDays then return end
    for _, contract in ipairs(g_missionManager:getMissions()) do
        if contract.type ~= nil and contract.type.name == TaigaSupplyMission.TYPE_NAME
            and contract:getIsInProgress() and contract.endDate ~= nil then
            local remaining = contract:getMinutesLeft()
            if remaining ~= nil and remaining > 0 then
                contract:setDeadlineFromNow(remaining * 60000 * newDays / oldDays)
            end
        end
    end
    Logging.info("[ContractRating] Supply deadlines rescaled: %d -> %d days per month",
        oldDays, newDays)
end

-- Получает уведомление о смене игрового месяца.
function ContractSupplyCalendar:onPeriodChanged()
    self:checkCurrentPeriod()
end

-- Восстанавливает ротацию из sidecar и включает серверное наблюдение.
function ContractSupplyCalendar:start()
    if not self.mission:getIsServer() then
        return
    end
    local info = self.mission.missionInfo
    local directory = info ~= nil and info.savegameDirectory or nil
    if directory ~= nil then
        local ok, reason = self.rotation:load(directory)
        if not ok and reason ~= "fileMissing" then
            Logging.warning("[ContractRating] Supply rotation load: %s", tostring(reason))
        end
    end
    g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
    g_messageCenter:subscribe(MessageType.PERIOD_LENGTH_CHANGED, self.onPeriodLengthChanged, self)
    g_messageCenter:subscribe(MessageType.MISSION_DELETED, self.onMissionDeleted, self)
    g_messageCenter:subscribe(MissionFinishedEvent, self.onMissionFinished, self)
    -- Сверяем сохранённые миссии на случай отсутствия sidecar после сбоя.
    for _, contract in ipairs(g_missionManager:getMissions()) do
        if contract.type ~= nil and contract.type.name == TaigaSupplyMission.TYPE_NAME
            and contract.monthIndex ~= nil and self.rotation:canGenerate(contract.monthIndex) then
            self.rotation:markGenerated(contract.monthIndex, tostring(contract:getUniqueId()))
        end
    end
    -- При удалении контракта из сохранения sidecar мог оставить его старый ID.
    -- Проверяем именно текущий месяц; успешно закрытые контракты не восстанавливаем.
    local monthIndex = ContractSupplyCalendar.getMonthIndex(self.mission.environment)
    local entry = monthIndex ~= nil and self.rotation.generated[monthIndex] or nil
    if entry ~= nil and string.sub(entry.missionId, 1, 10) ~= "completed:" then
        local found = false
        for _, contract in ipairs(g_missionManager:getMissions()) do
            if contract.type ~= nil and contract.type.name == TaigaSupplyMission.TYPE_NAME
                and tostring(contract:getUniqueId()) == entry.missionId then
                found = true
                if contract.finishState == MissionFinishState.SUCCESS then
                    self.rotation:markCompleted(monthIndex, entry.missionId)
                elseif contract.finishState ~= MissionFinishState.NONE
                    and contract.status == MissionStatus.FINISHED then
                    self.rotation:clearGenerated(monthIndex, entry.missionId)
                end
                break
            end
        end
        if not found then
            Logging.warning("[ContractRating] Stale supply mission %s for month %d; allowing replacement",
                entry.missionId, monthIndex)
            self.rotation:clearGenerated(monthIndex, entry.missionId)
        end
    end
    self:checkCurrentPeriod()
end

-- Записывает отмеченные месяцы вместе с сохранением карьеры.
function ContractSupplyCalendar:save(directory)
    if self.mission ~= nil and self.mission:getIsServer() then
        if not self.rotation:save(directory) then
            Logging.warning("[ContractRating] Supply rotation save failed")
        end
    end
end

-- Удаляет подписки при выгрузке карты.
function ContractSupplyCalendar:delete()
    g_messageCenter:unsubscribeAll(self)
    self.mission = nil
end

-- Добавляет сохранение ротации к существующей цепочке FSCareerMissionInfo.
function ContractSupplyCalendar.installSaveHook()
    if FSCareerMissionInfo == nil or FSCareerMissionInfo.saveToXMLFile == nil
        or FSCareerMissionInfo.taigaSupplyCalendarSaveHookInstalled then
        return
    end
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
        FSCareerMissionInfo.saveToXMLFile,
        function(info, ...)
            local mission = g_currentMission
            local calendar = mission ~= nil and mission.contractSupplyCalendar or nil
            if calendar ~= nil and info ~= nil and info.savegameDirectory ~= nil then
                calendar:save(info.savegameDirectory)
            end
        end
    )
    FSCareerMissionInfo.taigaSupplyCalendarSaveHookInstalled = true
end

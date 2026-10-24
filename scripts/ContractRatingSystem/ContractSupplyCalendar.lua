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
        lastObservedMonth = nil
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
    local station, placeable = ContractSupplyStations.resolve(kind)
    if station == nil or placeable == nil then
        Logging.warning("[ContractRating] Supply station %s unavailable for month %d",
            tostring(kind), index)
        return
    end

    local candidates = {}
    for _, product in ipairs(ContractSupplySeasonality.getCandidates(
        kind, environment.currentPeriod)) do
        if station:getIsFillTypeAllowed(product.index) then
            local fillType = g_fillTypeManager:getFillTypeByIndex(product.index)
            if fillType ~= nil and type(fillType.pricePerLiter) == "number"
                and fillType.pricePerLiter > 0 then
                candidates[#candidates + 1] = fillType
            end
        end
    end
    if #candidates == 0 then
        Logging.warning("[ContractRating] No accepted seasonal goods for %s",
            tostring(kind))
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
    local fillType = candidates[math.random(#candidates)]
    local reward = ContractSupplyEconomy.calculateReward(fillType, liters, category)
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
    contract.monthIndex = index
    contract.supplyCategory = category
    contract.completion = 0

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
    -- Сверяем сохранённые миссии на случай отсутствия sidecar после сбоя.
    for _, contract in ipairs(g_missionManager:getMissions()) do
        if contract.type ~= nil and contract.type.name == TaigaSupplyMission.TYPE_NAME
            and contract.monthIndex ~= nil and self.rotation:canGenerate(contract.monthIndex) then
            self.rotation:markGenerated(contract.monthIndex, tostring(contract:getUniqueId()))
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

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
    if self.rotation:canGenerate(index) then
        Logging.info("[ContractRating] Supply month %d is pending, station: %s",
            index, tostring(self.rotation:getTypeForMonth(index)))
    end
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

--[[
    LoggingContractorRules

    Ограничения, действующие только пока существует активный договор:
    - с 08:00 до 21:00 обычное ускорение времени ограничено x15;
    - с 21:00 до 08:00 ограничение множителя времени снимается;
    - запрет сна временно отключён для сетевого тестирования;
    - штатное ускорение времени во время сна не ограничивается x15.
]]

LoggingContractor.MAX_ACTIVE_CONTRACT_TIME_SCALE = 15
LoggingContractor.TIME_SCALE_LIMIT_START_HOUR = 8
LoggingContractor.TIME_SCALE_LIMIT_END_HOUR = 21

-- Возвращает true только в дневном интервале, когда активный договор
-- действительно должен ограничивать обычный множитель времени.
function LoggingContractor:getIsTimeScaleLimitActive()
    if self.mission == nil or self.mission.environment == nil then
        return true
    end

    local hour = self.mission.environment.dayTime / (60 * 60 * 1000)
    return hour >= LoggingContractor.TIME_SCALE_LIMIT_START_HOUR
        and hour < LoggingContractor.TIME_SCALE_LIMIT_END_HOUR
end

-- Немедленно приводит текущий пользовательский множитель к допустимому
-- значению при активном договоре. Вызывается сервером как при старте договора,
-- так и в update(), поэтому невозможно заключить договор днём и сохранить x30/x60.
function LoggingContractor:enforceActiveContractTimeScaleLimit()
    if not self:hasAnyActiveJob()
        or not self:getIsTimeScaleLimitActive()
        or self.sleepTimeScaleOverride
        or g_sleepManager:getIsSleeping() then
        return
    end

    if self.mission.missionInfo.timeScale
        > LoggingContractor.MAX_ACTIVE_CONTRACT_TIME_SCALE then
        self.mission:setTimeScale(
            LoggingContractor.MAX_ACTIVE_CONTRACT_TIME_SCALE
        )
    end
end


local previousSleepManagerStartSleep = SleepManager.startSleep


-- Возвращает активный менеджер подрядчика текущей миссии.
local function getLoggingContractor()
    local mission = g_currentMission
    return mission ~= nil and mission.loggingContractor or nil
end


-- Разрешает штатному SleepManager использовать собственное ускорение времени.
-- Ограничение x15 относится только к обычному пользовательскому ускорению.
function SleepManager:startSleep(targetTime)
    local contractor = getLoggingContractor()
    if contractor ~= nil and contractor:hasAnyActiveJob() then
        contractor.sleepTimeScaleOverride = true
    end

    previousSleepManagerStartSleep(self, targetTime)

    if contractor ~= nil then
        contractor.sleepTimeScaleOverride = false
    end
end


-- Ограничивает обычное ускорение времени при активном договоре только
-- с 08:00 до 21:00. Ночью и во время штатного сна ограничение не применяется.
function MissionTayga:setTimeScale(timeScale, noEventSend)
    local contractor = self.loggingContractor

    if contractor ~= nil
        and contractor:hasAnyActiveJob()
        and contractor:getIsTimeScaleLimitActive()
        and not contractor.sleepTimeScaleOverride then
        timeScale = math.min(
            timeScale,
            LoggingContractor.MAX_ACTIVE_CONTRACT_TIME_SCALE
        )
    end

    return MissionTayga:superClass().setTimeScale(self, timeScale, noEventSend)
end

--[[
    LoggingContractorRules

    Ограничения, действующие только пока существует активный договор:
    - обычное ускорение времени ограничено x15;
    - запрет сна временно отключён для сетевого тестирования;
    - штатное ускорение времени во время сна не ограничивается x15.
]]

LoggingContractor.MAX_ACTIVE_CONTRACT_TIME_SCALE = 15

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


-- Ограничивает обычное ускорение времени при активном договоре.
-- Во время штатного сна ограничение временно снимается.
function MissionTayga:setTimeScale(timeScale, noEventSend)
    local contractor = self.loggingContractor

    if contractor ~= nil
        and contractor:hasAnyActiveJob()
        and not contractor.sleepTimeScaleOverride then
        timeScale = math.min(
            timeScale,
            LoggingContractor.MAX_ACTIVE_CONTRACT_TIME_SCALE
        )
    end

    return MissionTayga:superClass().setTimeScale(self, timeScale, noEventSend)
end

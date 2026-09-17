--[[
    LoggingContractorRules

    Ограничения, действующие только пока существует активный договор:
    - обычное ускорение времени ограничено x10;
    - с 08:00 до 21:00 сон запрещён;
    - ночной сон остаётся штатным и использует штатный SleepManager.
]]

LoggingContractor.MAX_ACTIVE_CONTRACT_TIME_SCALE = 10

local previousSleepManagerGetCanSleep = SleepManager.getCanSleep
local previousSleepManagerStartSleep = SleepManager.startSleep


-- Возвращает активный менеджер подрядчика текущей миссии.
local function getLoggingContractor()
    local mission = g_currentMission
    return mission ~= nil and mission.loggingContractor or nil
end


-- Запрещает сон в рабочее время подрядчика. Проверка выполняется и на сервере,
-- поэтому сетевой запрос сна не может обойти ограничение клиента.
function SleepManager:getCanSleep()
    local contractor = getLoggingContractor()
    if contractor ~= nil
        and contractor:hasAnyActiveJob()
        and contractor:getIsWorkingTime() then
        return false
    end

    return previousSleepManagerGetCanSleep(self)
end


-- На время штатного запуска сна разрешает SleepManager установить собственное
-- ускорение 5000. Обычное пользовательское ускорение при активном договоре
-- по-прежнему ограничивается x10.
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
-- Серверная проверка является окончательной; разрешение выше x10 используется
-- только внутри штатного SleepManager:startSleep().
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

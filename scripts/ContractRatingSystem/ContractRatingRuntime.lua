--[[
    ContractRatingRuntime
    Серверное подключение журнала рейтинга к штатным контрактам FS25.
    Сетевые события и контроль допуска реализуются отдельным этапом.
]]
ContractRatingRuntime = {}
ContractRatingRuntime.__index = ContractRatingRuntime

-- Создаёт обработчик, связанный с экземпляром миссии карты.
function ContractRatingRuntime.new(mission)
    return setmetatable({ mission = mission, ledger = ContractRatingLedger.new() }, ContractRatingRuntime)
end

-- Проверяет принадлежность типа миссии к штатным рейтингующим контрактам.
function ContractRatingRuntime.getStandardMissionDelta(mission, finishState)
    if mission == nil or mission.type == nil then
        return nil
    end

    local name = mission.type.name
    if name ~= "deadwoodMission"
        and name ~= "treeTransportMission"
        and name ~= "destructibleRockMission" then
        return nil
    end

    if finishState == MissionFinishState.SUCCESS then
        return 1
    end

    if finishState == MissionFinishState.CANCELED
        or finishState == MissionFinishState.FAILED
        or finishState == MissionFinishState.TIMED_OUT then
        return -2
    end

    return nil
end

-- Обрабатывает завершение только на сервере, с защитой по ID миссии.
function ContractRatingRuntime:onMissionFinished(contract, finishState)
    if self.mission == nil or not self.mission:getIsServer() then
        return
    end

    local delta = ContractRatingRuntime.getStandardMissionDelta(contract, finishState)
    if delta == nil or contract.farmId == nil then
        return
    end

    local uniqueId = contract:getUniqueId()
    if uniqueId == nil then
        Logging.warning("[ContractRating] Mission without uniqueId, rating skipped")
        return
    end

    local attemptId = "standard:" .. tostring(uniqueId)
    local applied, result = self.ledger:apply(
        "rating:" .. attemptId, contract.farmId, attemptId, delta,
        tostring(contract.type.name) .. ":" .. tostring(finishState)
    )
    if applied then
        Logging.info("[ContractRating] Farm %d: %+d (rating %s -> %s)",
            contract.farmId, delta, tostring(result.before), tostring(result.after))
    elseif result ~= "duplicateTransaction" then
        Logging.warning("[ContractRating] Could not record rating: %s", tostring(result))
    end
end

-- Восстанавливает журнал и подписывается на штатные события завершения.
function ContractRatingRuntime:start()
    if not self.mission:getIsServer() then
        return
    end

    local info = self.mission.missionInfo
    local directory = info ~= nil and info.savegameDirectory or nil
    if directory ~= nil then
        local ok, reason = self.ledger:load(directory)
        if not ok and reason ~= "fileMissing" then
            Logging.warning("[ContractRating] Ledger load failed: %s", tostring(reason))
        end
    end

    g_messageCenter:subscribe(MissionFinishedEvent, self.onMissionFinished, self)
end

-- Сохраняет текущий журнал при штатном сохранении карьеры.
function ContractRatingRuntime:save(directory)
    if not self.mission:getIsServer() then
        return
    end

    if not self.ledger:save(directory) then
        Logging.warning("[ContractRating] Ledger save failed")
    end
end

-- Снимает подписки перед выгрузкой карты.
function ContractRatingRuntime:delete()
    g_messageCenter:unsubscribeAll(self)
    self.mission = nil
end

-- Однократно подключает сохранение sidecar-файла к карьере.
function ContractRatingRuntime.installSaveHook()
    if FSCareerMissionInfo == nil
        or FSCareerMissionInfo.saveToXMLFile == nil
        or FSCareerMissionInfo.taigaContractRatingSaveHookInstalled then
        return
    end

    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
        FSCareerMissionInfo.saveToXMLFile,
        function(info, ...)
            local mission = g_currentMission
            local runtime = mission ~= nil and mission.contractRatingRuntime or nil
            if runtime ~= nil and info ~= nil and info.savegameDirectory ~= nil then
                runtime:save(info.savegameDirectory)
            end
        end
    )
    FSCareerMissionInfo.taigaContractRatingSaveHookInstalled = true
end

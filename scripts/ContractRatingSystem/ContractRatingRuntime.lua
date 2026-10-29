--[[
    ContractRatingRuntime
    Серверное подключение журнала рейтинга к штатным контрактам FS25.
    Передача рейтинга клиентам реализована через отдельные сетевые события.
    Контроль допуска и GUI реализуются отдельным этапом.
]]
ContractRatingRuntime = {}
ContractRatingRuntime.__index = ContractRatingRuntime

-- Значения используются только если XML-настройка не смогла загрузиться.
-- Они соответствуют утверждённым условиям поставок: +3 / -6.
ContractRatingRuntime.supplyRating = {success = 3, failure = -6}

-- Считывает рейтинг успешной/неудачной поставки из общего конфигурационного XML.
-- Параметры обновляются только после полной проверки, иначе сохраняется
-- гарантированная пара значений из требований.
function ContractRatingRuntime.loadRatingConfig(baseDirectory)
    local filename = Utils.getFilename(
        "scripts/ContractRatingSystem/contractRatingConfig.xml", baseDirectory)
    local xml = loadXMLFile("contractSupplyRatingConfig", filename)
    if xml == nil or xml == 0 then
        return false
    end

    local key = "contractRating.rating.mission(0)"
    local missionType = getXMLString(xml, key .. "#type")
    local success = getXMLInt(xml, key .. "#success")
    local failure = getXMLInt(xml, key .. "#failure")
    delete(xml)

    if missionType ~= "taigaSupplyMission"
        or success == nil or success <= 0
        or failure == nil or failure ~= -2 * success then
        return false
    end

    ContractRatingRuntime.supplyRating = {
        success = success,
        failure = failure
    }
    Logging.info(
        "[ContractRating] Рейтинг поставок настроен: успех %+d, отмена/провал %+d",
        success, failure)
    return true
end

-- Возвращает изменение рейтинга для поставок только после их принятия.
-- Непринятое предложение удаляется без MissionFinishedEvent и farmId.
function ContractRatingRuntime.getSupplyMissionDelta(mission, finishState)
    if mission == nil or mission.type == nil
        or mission.type.name ~= "taigaSupplyMission"
        or mission.farmId == nil then
        return nil
    end
    if finishState == MissionFinishState.SUCCESS then
        return ContractRatingRuntime.supplyRating.success
    end
    if finishState == MissionFinishState.CANCELED
        or finishState == MissionFinishState.FAILED
        or finishState == MissionFinishState.TIMED_OUT then
        return ContractRatingRuntime.supplyRating.failure
    end
    return nil
end

-- Маршрутизирует завершение в штатную или пользовательскую рейтинговую механику.
function ContractRatingRuntime.getMissionDelta(mission, finishState)
    local supplyDelta =
        ContractRatingRuntime.getSupplyMissionDelta(mission, finishState)
    if supplyDelta ~= nil then
        return supplyDelta
    end
    return ContractRatingRuntime.getStandardMissionDelta(mission, finishState)
end

-- Создаёт обработчик, связанный с экземпляром миссии карты.
function ContractRatingRuntime.new(mission)
    local self = setmetatable({
        mission = mission, ledger = ContractRatingLedger.new()
    }, ContractRatingRuntime)

    -- Любое новое понижение рейтинга, независимо от типа контракта,
    -- автоматически перепроверяет активные рецепты только этой фермы.
    self.ledger.onApplied = function(_, entry)
        if entry.delta < 0 and self.mission ~= nil
            and self.mission:getIsServer() then
            ContractRatingProduction.enforceFarm(entry.farmId)
        end
    end
    return self
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

    local delta = ContractRatingRuntime.getMissionDelta(contract, finishState)
    if delta == nil or contract.farmId == nil then
        return
    end

    local uniqueId = contract:getUniqueId()
    if uniqueId == nil then
        Logging.warning("[ContractRating] Mission without uniqueId, rating skipped")
        return
    end

    -- Префикс различает попытки поставки и штатные контракты.
    -- Постоянный uniqueId защищает от двойного начисления при повторном событии
    -- и при восстановлении уже завершённой миссии из старого сохранения.
    local prefix = contract.type.name == "taigaSupplyMission"
        and "supply:" or "standard:"
    local attemptId = prefix .. tostring(uniqueId)
    local applied, result = self.ledger:apply(
        "rating:" .. attemptId, contract.farmId, attemptId, delta,
        tostring(contract.type.name) .. ":" .. tostring(finishState)
    )
    if applied then
        self:broadcastEntry(result)
        Logging.info("[ContractRating] Farm %d: %+d (rating %s -> %s)",
            contract.farmId, delta, tostring(result.before), tostring(result.after))
    elseif result ~= "duplicateTransaction" then
        Logging.warning("[ContractRating] Could not record rating: %s", tostring(result))
    end
end

-- Восстанавливает пропущенное рейтинговое событие для поставок, которые
-- уже завершились, но ещё присутствуют в missions.xml. Удалённые миссии
-- восстановить по журналу невозможно, поэтому фиктивные записи не создаются.
function ContractRatingRuntime:reconcileFinishedSupplies()
    local missions = g_missionManager ~= nil and g_missionManager:getMissions() or {}
    for _, contract in ipairs(missions) do
        if contract.type ~= nil
            and contract.type.name == "taigaSupplyMission"
            and contract.status == MissionStatus.FINISHED
            and contract.finishState ~= nil then
            self:onMissionFinished(contract, contract.finishState)
        end
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
    self:reconcileFinishedSupplies()
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


-- Отправляет новую рейтинговую операцию всем подключённым клиентам.
function ContractRatingRuntime:broadcastEntry(entry)
    if self.mission ~= nil and self.mission:getIsServer() and g_server ~= nil then
        g_server:broadcastEvent(ContractRatingSyncEvent.new(1, entry), false)
    end
end

-- Отправляет полную историю только указанному соединению, начиная с очистки.
function ContractRatingRuntime:sendSnapshot(connection)
    if self.mission == nil or not self.mission:getIsServer() or connection == nil then
        return
    end
    connection:sendEvent(ContractRatingSyncEvent.new(0))
    for _, entry in ipairs(self.ledger:getTransactions()) do
        connection:sendEvent(ContractRatingSyncEvent.new(1, entry))
    end
end

-- Применяет на клиенте серверную операцию; повторные события не удваивают рейтинг.
function ContractRatingRuntime:receiveSync(kind, entry)
    if self.mission == nil or self.mission:getIsServer() then
        return
    end
    if kind == 0 then
        self.ledger = ContractRatingLedger.new()
    elseif kind == 1 and entry ~= nil then
        local ok, reason = self.ledger:apply(
            entry.id, entry.farmId, entry.attemptId, entry.delta, entry.reason
        )
        if not ok and reason ~= "duplicateTransaction" then
            Logging.warning("[ContractRating] Invalid sync entry: %s", tostring(reason))
        end
    end
end

-- Возвращает рейтинг конкретной фермы из серверного/синхронизированного журнала.
-- На клиенте используется только для отображения; изменения запрещены.
function ContractRatingRuntime.getRatingForFarm(farmId)
    local mission = g_currentMission
    local runtime = mission ~= nil and mission.contractRatingRuntime or nil
    if runtime == nil or type(farmId) ~= "number" or farmId <= 0
        or farmId % 1 ~= 0 then return nil end
    return runtime.ledger:getRating(farmId)
end

-- Единая серверная проверка для будущих производственных рецептов.
-- Источник farmId обязан быть серверно установленным владельцем/оператором.
-- Клиентское значение не предоставляет разрешения на использование рецепта.
function ContractRatingRuntime.isFarmRatingSufficient(farmId, minRating)
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer()
        or type(minRating) ~= "number" or minRating ~= minRating
        or minRating == math.huge or minRating == -math.huge then return false end
    local rating = ContractRatingRuntime.getRatingForFarm(farmId)
    return rating ~= nil and rating >= minRating
end

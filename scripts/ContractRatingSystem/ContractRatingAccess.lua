--[[
    ContractRatingAccess
    Серверный рейтинговый допуск на уровне события принятия контракта.
    Штатные миссии без зарегистрированного порога не затрагиваются.
]]
ContractRatingAccess = {}
ContractRatingAccess.CONFIG = "scripts/ContractRatingSystem/contractRatingConfig.xml"
ContractRatingAccess.thresholds = {}

-- Читает настройки рейтинговых порогов при загрузке карты.
function ContractRatingAccess.loadConfig(baseDirectory)
    local filename = Utils.getFilename(ContractRatingAccess.CONFIG, baseDirectory)
    local xml = loadXMLFile("taigaRatingAccessConfig", filename)
    if xml == nil or xml == 0 then
        Logging.warning("[ContractRating] Cannot load access configuration: %s", filename)
        return false
    end

    local thresholds = {}
    local i = 0
    while true do
        local key = string.format("contractRating.access.mission(%d)", i)
        local name = getXMLString(xml, key .. "#type")
        if name == nil then
            break
        end
        local minRating = getXMLInt(xml, key .. "#minRating")
        if minRating == nil or minRating < 0 or thresholds[name] ~= nil then
            Logging.warning("[ContractRating] Invalid access threshold: %s", tostring(name))
            delete(xml)
            return false
        end
        thresholds[name] = minRating
        i = i + 1
    end
    delete(xml)
    ContractRatingAccess.thresholds = thresholds
    return true
end

-- Определяет требуемый рейтинг, если тип входит в настройки.
function ContractRatingAccess.getRequiredRating(contract)
    local name = contract ~= nil and contract.type ~= nil and contract.type.name or nil
    return name ~= nil and ContractRatingAccess.thresholds[name] or nil
end

-- Выполняет ранний отказ на сервере до штатного MissionManager:startMission.
-- Ферма берётся из подтверждённого контекста соединения, а не из пакета клиента.
function ContractRatingAccess.missionStartEventRun(event, superFunc, connection)
    if connection == nil or connection:getIsServer() then
        return superFunc(event, connection)
    end

    local currentMission = g_currentMission
    local runtime = currentMission ~= nil and currentMission.contractRatingRuntime or nil
    local required = ContractRatingAccess.getRequiredRating(event.mission)
    if runtime == nil or required == nil then
        return superFunc(event, connection)
    end

    local userId = currentMission.userManager:getUserIdByConnection(connection)
    local senderFarm = g_farmManager:getFarmByUserId(userId)
    if senderFarm == nil or senderFarm.farmId ~= event.farmId then
        return superFunc(event, connection)
    end

    -- Разрешения manageContracts и другие стандартные ограничения проверяет игра.
    if not currentMission:getHasPlayerPermission("manageContracts", connection, senderFarm.farmId) then
        return superFunc(event, connection)
    end

    local current = runtime.ledger:getRating(senderFarm.farmId)
    if current >= required then
        return superFunc(event, connection)
    end

    -- Не вызываем validate, startMission и delete: предложение остаётся доступным.
    connection:sendEvent(MissionStartEvent.newServerToClient(
        MissionStartState.CANNOT_BE_STARTED_NOW, event.spawnVehicles
    ))
    connection:sendEvent(ContractRatingAccessDeniedEvent.new(required, current))
end

-- Устанавливает защиту однократно; повторная загрузка карты не дублирует hook.
function ContractRatingAccess.install()
    if MissionStartEvent == nil or MissionStartEvent.run == nil
        or ContractRatingAccess.installed then
        return false
    end

    MissionStartEvent.run = Utils.overwrittenFunction(
        MissionStartEvent.run, ContractRatingAccess.missionStartEventRun
    )
    ContractRatingAccess.installed = true
    return true
end

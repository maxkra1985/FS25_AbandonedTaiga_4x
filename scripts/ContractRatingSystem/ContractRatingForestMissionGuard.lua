--[[
    ContractRatingForestMissionGuard
    Защита штатных лесных контрактов от недействительных участков карты.
    ID может существовать в infoLayer_farmlands, но отсутствовать
    в config/farmlands.xml; в этом случае getNPC() штатной миссии
    обращается к nil и нарушает обновление списка контрактов.
]]
ContractRatingForestMissionGuard = {}
ContractRatingForestMissionGuard.installed = false
ContractRatingForestMissionGuard.reportedSpots = {}

-- Возвращает идентификатор участка только для двух штатных лесных миссий.
function ContractRatingForestMissionGuard.getForestFarmlandId(mission)
    if mission == nil then return nil, false end
    if mission:isa(DeadwoodMission) or mission:isa(TreeTransportMission) then
        return mission.farmlandId or
            (mission.spot ~= nil and mission.spot.farmlandId), true
    end
    return nil, false
end

-- Проверяет наличие объекта участка, а не только его числа в карте земель.
function ContractRatingForestMissionGuard.isInvalidMission(mission)
    local id, isForest = ContractRatingForestMissionGuard.getForestFarmlandId(mission)
    if not isForest or g_farmlandManager == nil then return false end
    return id == nil or g_farmlandManager:getFarmlandById(id) == nil
end

-- Освобождает ресурсы некорректной миссии до попадания в общий список.
-- delete() освобождает точку, убирает подписки и уменьшает numInstances.
function ContractRatingForestMissionGuard.rejectMission(mission, stage)
    local id = ContractRatingForestMissionGuard.getForestFarmlandId(mission)
    Logging.warning(
        "[ContractRating] Лесной контракт отклонён (%s): type=%s, farmlandId=%s. Участок отсутствует в FarmlandManager",
        stage, tostring(mission:getMissionTypeName()), tostring(id))
    mission:delete()
end

-- Отсекает некорректный контракт до MISSION_GENERATED и перерисовки GUI.
function ContractRatingForestMissionGuard.registerMission(manager, superFunc,
                                                         mission, missionType)
    if ContractRatingForestMissionGuard.isInvalidMission(mission) then
        ContractRatingForestMissionGuard.rejectMission(mission, "генерация")
        return
    end
    return superFunc(manager, mission, missionType)
end

-- При восстановлении старой сохранки MissionManager вызывает addMission
-- напрямую, поэтому проверяем и этот путь, прежде чем обновлять интерфейс.
function ContractRatingForestMissionGuard.addMission(manager, superFunc, mission)
    if ContractRatingForestMissionGuard.isInvalidMission(mission) then
        ContractRatingForestMissionGuard.rejectMission(mission, "сохранение")
        return
    end
    return superFunc(manager, mission)
end

-- Помечает только невозможные точки лесных заданий как занятые.
-- Массив spots и индексы точек не меняются: они используются в XML/MP.
function ContractRatingForestMissionGuard.blockInvalidSpots(typeName)
    if g_farmlandManager == nil then return end
    local data = g_missionManager:getMissionTypeDataByName(typeName)
    if data == nil or data.spots == nil then return end

    local newlyBlocked = 0
    for _, spot in ipairs(data.spots) do
        local id = spot.farmlandId
        if id == nil or g_farmlandManager:getFarmlandById(id) == nil then
            spot.isInUse = true
            local key = typeName .. ":" .. tostring(spot.index)
            if not ContractRatingForestMissionGuard.reportedSpots[key] then
                ContractRatingForestMissionGuard.reportedSpots[key] = true
                newlyBlocked = newlyBlocked + 1
                Logging.warning(
                    "[ContractRating] Лесная точка исключена из генерации: type=%s, spot=%s, farmlandId=%s",
                    typeName, tostring(spot.index), tostring(id))
            end
        end
    end
    if newlyBlocked > 0 then
        Logging.info("[ContractRating] Исключено новых неверных точек %s: %d",
            typeName, newlyBlocked)
    end
end

-- При генерации предварительно исключает неверные точки, не изменяя XML.
function ContractRatingForestMissionGuard.wrapGenerator(classObject, typeName)
    local original = classObject.tryGenerateMission
    if original == nil then return end
    classObject.tryGenerateMission = function(...)
        ContractRatingForestMissionGuard.blockInvalidSpots(typeName)
        return original(...)
    end
end

-- Подключает фильтры в жизненном цикле карты до генерации миссий.
function ContractRatingForestMissionGuard.install()
    if ContractRatingForestMissionGuard.installed then return end
    MissionManager.registerMission = Utils.overwrittenFunction(
        MissionManager.registerMission,
        ContractRatingForestMissionGuard.registerMission)
    MissionManager.addMission = Utils.overwrittenFunction(
        MissionManager.addMission,
        ContractRatingForestMissionGuard.addMission)
    ContractRatingForestMissionGuard.wrapGenerator(
        DeadwoodMission, DeadwoodMission.NAME)
    ContractRatingForestMissionGuard.wrapGenerator(
        TreeTransportMission, TreeTransportMission.NAME)
    ContractRatingForestMissionGuard.installed = true
    Logging.info("[ContractRating] Защита лесных контрактов от отсутствующих земельных участков подключена")
end

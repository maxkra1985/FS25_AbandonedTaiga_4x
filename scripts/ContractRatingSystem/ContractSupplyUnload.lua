--[[
    ContractSupplyUnload
    Перехват серверной разгрузки контрактной продукции.
    Контракт забирает ровно ещё необходимый объём, обычная продажа
    остатка выполняется штатной функцией. Без изменения DinamycalPrice.
]]
ContractSupplyUnload = {}

-- Находит выполняемый контракт, соответствующий ферме, товару и станции.
function ContractSupplyUnload.findMission(station, farmId, fillTypeIndex)
    if g_missionManager == nil or g_currentMission == nil then
        return nil
    end
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType == nil then
        return nil
    end
    for _, contract in ipairs(g_missionManager:getMissions()) do
        if contract.type ~= nil
            and contract.type.name == TaigaSupplyMission.TYPE_NAME
            and contract.status == MissionStatus.RUNNING
            and contract.farmId == farmId
            and contract.fillTypeName == fillType.name
            and contract.deliveredLiters < contract.requiredLiters then
            local target, placeable = ContractSupplyStations.resolve(contract.stationKind, contract.stationId, fillTypeIndex)
            if target == station and placeable ~= nil
                and placeable.uniqueId == contract.stationId then
                return contract
            end
        end
    end
    return nil
end

-- Отводит контрактную долю поставки до штатного начисления денег.
-- Для обычных продаж и неподходящих станций вызывает исходный метод.
function ContractSupplyUnload.addFillLevelFromTool(station, superFunc,
    farmId, deltaFillLevel, fillTypeIndex, fillInfo, toolType, extraAttributes)
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer()
        or type(deltaFillLevel) ~= "number" or deltaFillLevel <= 0 then
        return superFunc(station, farmId, deltaFillLevel, fillTypeIndex,
            fillInfo, toolType, extraAttributes)
    end

    local contract = ContractSupplyUnload.findMission(station, farmId, fillTypeIndex)
    if contract == nil
        or station:getStoreGoods(farmId, fillTypeIndex)
        or not station:getIsFillTypeAllowed(fillTypeIndex, extraAttributes)
        or (station.getIsFillAllowedFromFarm ~= nil
            and not station:getIsFillAllowedFromFarm(farmId)) then
        return superFunc(station, farmId, deltaFillLevel, fillTypeIndex,
            fillInfo, toolType, extraAttributes)
    end

    local needed = math.max(0, contract.requiredLiters - contract.deliveredLiters)
    local reserved = math.min(deltaFillLevel, needed)
    if reserved <= 0 then
        return superFunc(station, farmId, deltaFillLevel, fillTypeIndex,
            fillInfo, toolType, extraAttributes)
    end

    -- Контрактная доля возвращается триггеру как принятая и не продаётся повторно.
    local accepted = contract:addDeliveredLiters(
        farmId, contract.stationId, contract.fillTypeName, reserved)
    if accepted <= 0 then
        return superFunc(station, farmId, deltaFillLevel, fillTypeIndex,
            fillInfo, toolType, extraAttributes)
    end

    station:startFx(fillTypeIndex)

    -- Оставшуюся часть отдаём штатной торговле по действующей цене.
    local remainder = deltaFillLevel - accepted
    if remainder > 0 then
        return accepted + superFunc(station, farmId, remainder, fillTypeIndex,
            fillInfo, toolType, extraAttributes)
    end
    return accepted
end

-- Устанавливает ровно один hook для всех SellingStation карты.
function ContractSupplyUnload.install()
    if SellingStation == nil or SellingStation.addFillLevelFromTool == nil
        or SellingStation.taigaSupplyUnloadInstalled then
        return false
    end
    SellingStation.addFillLevelFromTool = Utils.overwrittenFunction(
        SellingStation.addFillLevelFromTool, ContractSupplyUnload.addFillLevelFromTool)
    SellingStation.taigaSupplyUnloadInstalled = true
    return true
end

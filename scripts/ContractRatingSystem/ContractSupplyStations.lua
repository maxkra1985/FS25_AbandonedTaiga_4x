--[[
    ContractSupplyStations
    Сопоставляет категорию поставки с реально загруженной SellingStation.
    У складских магазинов покупки поддонов нет статуса пункта приёма.
]]
ContractSupplyStations = {}
ContractSupplyStations.PREPLACED = {
    elevator = "preplaced_RailBulkSellPoint_22b676c5d05843409adca29b40ca3845",
    wood = "preplaced_sellingStationWood_6b9aa86c9073c3ef85c004cc8eb3b327"
}
ContractSupplyStations.palletStationIds = {}

-- Загружает явный приоритет пунктов скупки из XML-конфигурации.
function ContractSupplyStations.loadConfig(baseDirectory)
    local filename = Utils.getFilename(
        "scripts/ContractRatingSystem/contractRatingConfig.xml", baseDirectory)
    local xml = loadXMLFile("contractSupplyStations", filename)
    if xml == nil or xml == 0 then return false end
    local ids = {}
    local seen = {}
    for i = 0, 31 do
        local key = string.format("contractRating.supply.palletStations.station(%d)#uniqueId", i)
        local id = getXMLString(xml, key)
        if id == nil then break end
        if id == "" or seen[id] then
            delete(xml)
            return false
        end
        seen[id] = true
        ids[#ids + 1] = id
    end
    delete(xml)
    if #ids == 0 then return false end
    ContractSupplyStations.palletStationIds = ids
    return true
end

-- Находит загруженный объект приёма строго по идентификатору карты.
function ContractSupplyStations.resolveById(uniqueId)
    local mission = g_currentMission
    if mission == nil or mission.placeableSystem == nil or uniqueId == nil then
        return nil, nil
    end
    for _, placeable in ipairs(mission.placeableSystem.placeables or {}) do
        if placeable.uniqueId == uniqueId then
            local spec = placeable.spec_sellingStation
            if spec ~= nil and spec.sellingStation ~= nil then
                return spec.sellingStation, placeable
            end
        end
    end
    return nil, nil
end

-- Находит пункт поставки по типу, конкретному ID и типу продукции.
-- Для поддонов используется порядок из XML, но только среди принимающих товар.
function ContractSupplyStations.resolve(kind, stationId, fillTypeIndex)
    if kind ~= "pallets" then
        local expected = ContractSupplyStations.PREPLACED[kind]
        if expected == nil or (stationId ~= nil and stationId ~= expected) then
            return nil, nil
        end
        return ContractSupplyStations.resolveById(expected)
    end

    for _, uniqueId in ipairs(ContractSupplyStations.palletStationIds) do
        if stationId == nil or stationId == uniqueId then
            local target, placeable = ContractSupplyStations.resolveById(uniqueId)
            if target ~= nil and (fillTypeIndex == nil
                or target:getIsFillTypeAllowed(fillTypeIndex)) then
                return target, placeable
            end
        end
    end
    return nil, nil
end

-- Проверяет, что товар разрешён выбранной точкой.
function ContractSupplyStations.accepts(kind, fillTypeIndex, stationId)
    if fillTypeIndex == nil then return false end
    local target = ContractSupplyStations.resolve(kind, stationId, fillTypeIndex)
    return target ~= nil and target:getIsFillTypeAllowed(fillTypeIndex)
end

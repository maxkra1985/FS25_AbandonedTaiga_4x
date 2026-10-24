--[[
    ContractSupplyStations
    Поиск реально загруженных точек карты по ID из config/placeables.xml.
    Модуль не подменяет приемку продукции и не генерирует контракты.
]]
ContractSupplyStations = {}
ContractSupplyStations.PREPLACED = {
    elevator = "preplaced_RailBulkSellPoint_22b676c5d05843409adca29b40ca3845",
    wood = "preplaced_sellingStationWood_6b9aa86c9073c3ef85c004cc8eb3b327"
}

-- Возвращает фактическую точку приёма и её placeable по постоянному ID.
function ContractSupplyStations.resolve(kind)
    local uniqueId = ContractSupplyStations.PREPLACED[kind]
    if uniqueId == nil or g_currentMission == nil
        or g_currentMission.placeableSystem == nil then
        return nil
    end

    -- Берём загруженный объект, а не создаём фиктивный объект карты.
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables or {}) do
        if placeable.uniqueId == uniqueId then
            local spec = placeable.spec_sellingStation
            local station = spec ~= nil and spec.sellingStation or nil
            if station ~= nil then
                return station, placeable
            end
        end
    end
    return nil
end

-- Проверяет, что груз действительно принимается найденным объектом.
function ContractSupplyStations.accepts(kind, fillTypeIndex)
    local station = ContractSupplyStations.resolve(kind)
    return station ~= nil and fillTypeIndex ~= nil
        and station:getIsFillTypeAllowed(fillTypeIndex)
end

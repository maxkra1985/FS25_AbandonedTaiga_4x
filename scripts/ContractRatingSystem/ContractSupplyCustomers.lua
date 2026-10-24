--[[
    ContractSupplyCustomers
    Внешние организации, приобретающие продукцию через посредников на карте.
    Названия и ассортимент задаются в XML карты.
]]
ContractSupplyCustomers = {}
ContractSupplyCustomers.items = {}

-- Загружает список организаций; ошибка не изменяет существующий каталог.
function ContractSupplyCustomers.loadConfig(baseDirectory)
    local filename = Utils.getFilename("scripts/ContractRatingSystem/contractRatingConfig.xml", baseDirectory)
    local xml = loadXMLFile("contractSupplyCustomers", filename)
    if xml == nil or xml == 0 then return false end
    local entries = {}
    local i = 0
    while true do
        local key = string.format("contractRating.supply.customers.customer(%d)", i)
        local name = getXMLString(xml, key .. "#name")
        if name == nil then break end
        local station = getXMLString(xml, key .. "#station")
        local types = getXMLString(xml, key .. "#fillTypes")
        if name == "" or (station ~= "elevator" and station ~= "wood" and station ~= "pallets")
            or types == nil or types == "" then
            delete(xml)
            return false
        end
        local allowed = {}
        for fillType in string.gmatch(types, "%S+") do
            allowed[fillType] = true
        end
        entries[#entries + 1] = {name = name, station = station, types = allowed}
        i = i + 1
    end
    delete(xml)
    if #entries == 0 then return false end
    ContractSupplyCustomers.items = entries
    return true
end

-- Случайно выбирает подходящего заказчика для конкретной продукции.
function ContractSupplyCustomers.choose(station, fillTypeName)
    local candidates = {}
    for _, customer in ipairs(ContractSupplyCustomers.items) do
        if customer.station == station and customer.types[fillTypeName] then
            candidates[#candidates + 1] = customer.name
        end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(#candidates)]
end

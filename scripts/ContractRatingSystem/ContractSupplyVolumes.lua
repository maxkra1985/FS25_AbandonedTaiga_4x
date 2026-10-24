--[[
    ContractSupplyVolumes
    Вычисляет количество продукции по утверждённым базовым объёмам
    и коэффициенту сложности, считанным из XML-конфигурации карты.
]]
ContractSupplyVolumes = {}
ContractSupplyVolumes.levels = { [1] = 1, [2] = 1.25, [3] = 1.5 }
ContractSupplyVolumes.stations = {
    wood = { short = 20000, medium = 60000, long = 200000 },
    elevator = { short = 30000, medium = 60000, long = 150000 }
}

-- Загружает коэффициенты и объёмы из общей конфигурации.
function ContractSupplyVolumes.loadConfig(baseDirectory)
    local path = Utils.getFilename("scripts/ContractRatingSystem/contractRatingConfig.xml", baseDirectory)
    local xml = loadXMLFile("contractSupplyVolumes", path)
    if xml == nil or xml == 0 then
        return false
    end
    local key = "contractRating.supply"
    local d = key .. ".difficulty"
    local levels = {
        [1] = getXMLFloat(xml, d .. "#easy"),
        [2] = getXMLFloat(xml, d .. "#normal"),
        [3] = getXMLFloat(xml, d .. "#hard")
    }
    local stations = {}
    local i = 0
    while true do
        local prefix = string.format("%s.volume(%d)", key, i)
        local name = getXMLString(xml, prefix .. "#station")
        if name == nil then break end
        if stations[name] ~= nil then
            delete(xml)
            return false
        end
        stations[name] = {
            short = getXMLInt(xml, prefix .. "#short"),
            medium = getXMLInt(xml, prefix .. "#medium"),
            long = getXMLInt(xml, prefix .. "#long")
        }
        i = i + 1
    end
    delete(xml)
    for _, value in pairs(levels) do
        if type(value) ~= "number" or value <= 0 then return false end
    end
    for _, byCategory in pairs(stations) do
        for _, category in ipairs({"short", "medium", "long"}) do
            if type(byCategory[category]) ~= "number" or byCategory[category] <= 0 then
                return false
            end
        end
    end
    if stations.wood == nil or stations.elevator == nil then return false end
    ContractSupplyVolumes.levels = levels
    ContractSupplyVolumes.stations = stations
    return true
end

-- Возвращает требуемый объём, округляя результат до целого литра.
function ContractSupplyVolumes.getRequiredLiters(station, category, difficulty)
    local byCategory = ContractSupplyVolumes.stations[station]
    local coefficient = ContractSupplyVolumes.levels[difficulty]
    if byCategory == nil or coefficient == nil or byCategory[category] == nil then
        return nil
    end
    return math.floor(byCategory[category] * coefficient + 0.5)
end

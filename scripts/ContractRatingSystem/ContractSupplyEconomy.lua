--[[
    ContractSupplyEconomy
    Расчёт фиксированной суммы контракта по базовой цене fillType.
    Значения премий и сроков читаются из XML; динамическая цена не используется.
]]
ContractSupplyEconomy = {}
ContractSupplyEconomy.categories = {}

-- Проверяет и загружает категории поставок без частичного обновления состояния.
function ContractSupplyEconomy.loadConfig(baseDirectory)
    local filename = Utils.getFilename(
        "scripts/ContractRatingSystem/contractRatingConfig.xml", baseDirectory)
    local xml = loadXMLFile("contractSupplyEconomy", filename)
    if xml == nil or xml == 0 then return false end
    local data = {}
    local count = 0
    for i = 0, 2 do
        local key = string.format("contractRating.supply.category(%d)", i)
        local name = getXMLString(xml, key .. "#name")
        local premium = getXMLFloat(xml, key .. "#premium")
        local months = getXMLFloat(xml, key .. "#months")
        if name == nil or data[name] ~= nil
            or (name ~= "short" and name ~= "medium" and name ~= "long")
            or type(premium) ~= "number" or premium < 0
            or type(months) ~= "number" or months <= 0 then
            delete(xml)
            return false
        end
        data[name] = {premium = premium, months = months}
        count = count + 1
    end
    delete(xml)
    if count ~= 3 or data.short == nil or data.medium == nil
        or data.long == nil then return false end
    ContractSupplyEconomy.categories = data
    return true
end

-- Возвращает зафиксированные базовую стоимость, премию и итоговую сумму.
function ContractSupplyEconomy.calculateBreakdown(fillType, liters, category)
    local settings = ContractSupplyEconomy.categories[category]
    if fillType == nil or settings == nil or type(fillType.pricePerLiter) ~= "number"
        or fillType.pricePerLiter <= 0 or type(liters) ~= "number" or liters <= 0 then
        return nil
    end
    local base = math.floor(fillType.pricePerLiter * liters + 0.5)
    local total = math.floor(fillType.pricePerLiter * liters * (1 + settings.premium) + 0.5)
    return base, total - base, total
end

-- Возвращает денежную награду от базовой цены за литр и надбавки.
function ContractSupplyEconomy.calculateReward(fillType, liters, category)
    local settings = ContractSupplyEconomy.categories[category]
    if fillType == nil or settings == nil
        or type(fillType.pricePerLiter) ~= "number"
        or fillType.pricePerLiter <= 0 or type(liters) ~= "number"
        or liters <= 0 then
        return nil
    end
    return math.floor(fillType.pricePerLiter * liters * (1 + settings.premium) + 0.5)
end

-- Возвращает продолжительность миссии в миллисекундах игрового времени.
function ContractSupplyEconomy.getDuration(category, daysPerPeriod)
    local settings = ContractSupplyEconomy.categories[category]
    if settings == nil or type(daysPerPeriod) ~= "number"
        or daysPerPeriod <= 0 then return nil end
    return settings.months * daysPerPeriod * 86400000
end

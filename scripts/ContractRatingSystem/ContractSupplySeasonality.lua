--[[
    ContractSupplySeasonality
    Настраиваемый календарь продукции для трёх видов поставок.
    Календарь FS25 начинается с марта (currentPeriod=1); XML использует
    обычные номера месяцев, где январь=1 и декабрь=12.
]]
ContractSupplySeasonality = {}
ContractSupplySeasonality.products = {}

local allowedStations = { wood = true, elevator = true, pallets = true }

-- Преобразует игровой сезонный период в обычный календарный месяц.
function ContractSupplySeasonality.periodToMonth(period)
    if type(period) ~= "number" or period % 1 ~= 0
        or period < 1 or period > 12 then
        return nil
    end
    return (period + 1) % 12 + 1
end

-- Разбирает список месяцев, не позволяя неверным значениям пройти в настройки.
function ContractSupplySeasonality.parseMonths(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    local result = {}
    local count = 0
    for token in string.gmatch(value, "%S+") do
        if not string.match(token, "^%d+$") then
            return nil
        end
        local month = tonumber(token)
        if month == nil or month < 1 or month > 12 or result[month] then
            return nil
        end
        result[month] = true
        count = count + 1
    end
    return count > 0 and result or nil
end

-- Читает ассортимент из XML и заменяет его только после полной проверки.
function ContractSupplySeasonality.loadConfig(baseDirectory)
    local filename = Utils.getFilename(
        "scripts/ContractRatingSystem/contractRatingConfig.xml", baseDirectory)
    local xml = loadXMLFile("contractSupplySeasonality", filename)
    if xml == nil or xml == 0 then
        return false
    end

    local products = {wood = {}, elevator = {}, pallets = {}}
    local index = 0
    while true do
        local key = string.format(
            "contractRating.supply.seasonalProducts.product(%d)", index)
        local station = getXMLString(xml, key .. "#station")
        if station == nil then
            break
        end

        local fillTypeName = getXMLString(xml, key .. "#fillType")
        local months = ContractSupplySeasonality.parseMonths(
            getXMLString(xml, key .. "#months"))
        -- WOOD учитывается игрой как древесина через woodUnloadTrigger,
        -- а не как обычный fillType. В ассортименте это условный маркер.
        local isWood = station == "wood" and fillTypeName == "WOOD"
        local fillType = not isWood and fillTypeName ~= nil
            and g_fillTypeManager:getFillTypeByName(fillTypeName) or nil
        if not allowedStations[station] or (not isWood and fillType == nil) or months == nil
            or products[station][isWood and "WOOD" or (fillType ~= nil and fillType.name or "")] ~= nil then
            Logging.warning(
                "[ContractRating] Invalid seasonal product: %s / %s",
                tostring(station), tostring(fillTypeName))
            delete(xml)
            return false
        end

        -- Не используем выражение isWood and nil or fillType.index:
        -- в Lua при nil результатом становится правая ветка оператора or.
        local productName
        local fillTypeIndex
        if isWood then
            productName = "WOOD"
            fillTypeIndex = nil
        else
            productName = fillType.name
            fillTypeIndex = fillType.index
        end
        products[station][productName] = {
            name = productName,
            index = fillTypeIndex,
            months = months
        }
        index = index + 1
    end
    delete(xml)
    if index == 0 then
        return false
    end
    ContractSupplySeasonality.products = products
    return true
end

-- Возвращает отсортированные допустимые товары для категории и периода.
-- Для реальной генерации дополнительно требуется проверка SellingStation.
function ContractSupplySeasonality.getCandidates(station, period)
    local month = ContractSupplySeasonality.periodToMonth(period)
    if month == nil or not allowedStations[station] then
        return {}
    end
    local result = {}
    for _, product in pairs(ContractSupplySeasonality.products[station] or {}) do
        if product.months[month] then
            result[#result + 1] = product
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

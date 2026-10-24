--[[
    ContractSupplyRotation
    Календарный учёт предложений поставок.
    Не создаёт миссий: планировщик должен отметить месяц только после
    успешной регистрации предложения в штатном MissionManager.
]]
ContractSupplyRotation = {}
ContractSupplyRotation.__index = ContractSupplyRotation
ContractSupplyRotation.VERSION = 1
ContractSupplyRotation.FILENAME = "contractSupplyRotation.xml"
ContractSupplyRotation.DEFAULT_ORDER = {"elevator", "wood", "pallets"}

-- Создаёт состояние квартальной ротации в заданном порядке типов.
function ContractSupplyRotation.new(order)
    order = order or ContractSupplyRotation.DEFAULT_ORDER
    local seen = {}
    for _, name in ipairs(order) do
        if name ~= "elevator" and name ~= "wood" and name ~= "pallets"
            or seen[name] then
            return nil, "invalidOrder"
        end
        seen[name] = true
    end
    if #order ~= 3 then
        return nil, "invalidOrder"
    end
    return setmetatable({
        order = {order[1], order[2], order[3]},
        generated = {}
    }, ContractSupplyRotation)
end

-- Возвращает категорию точки для абсолютного индекса игрового месяца.
-- Индекс должен быть целым и отсчитываться от начала игровой эпохи.
function ContractSupplyRotation:getTypeForMonth(monthIndex)
    if type(monthIndex) ~= "number" or monthIndex < 0
        or monthIndex % 1 ~= 0 then
        return nil
    end
    return self.order[monthIndex % 3 + 1]
end

-- Проверяет, разрешена ли единственная регистрация предложения за месяц.
function ContractSupplyRotation:canGenerate(monthIndex)
    return self:getTypeForMonth(monthIndex) ~= nil
        and self.generated[monthIndex] == nil
end

-- Отмечает успешную регистрацию нового контракта.
-- Повторное подтверждение месяца не допускается даже после перезагрузки.
function ContractSupplyRotation:markGenerated(monthIndex, missionId)
    local typeName = self:getTypeForMonth(monthIndex)
    if typeName == nil or not self:canGenerate(monthIndex)
        or type(missionId) ~= "string" or missionId == "" then
        return false
    end
    self.generated[monthIndex] = {typeName = typeName, missionId = missionId}
    return true
end

-- Сохраняет месяцы генерации в самостоятельный файл savegame.
function ContractSupplyRotation:save(directory)
    if type(directory) ~= "string" or directory == "" then
        return false
    end
    local xml = createXMLFile(
        "taigaSupplyRotationSave",
        directory .. "/" .. self.FILENAME,
        "contractSupplyRotation"
    )
    if xml == nil or xml == 0 then
        return false
    end
    setXMLInt(xml, "contractSupplyRotation#version", self.VERSION)
    for i, name in ipairs(self.order) do
        setXMLString(xml,
            string.format("contractSupplyRotation.order(%d)#type", i - 1), name)
    end

    -- pairs не задаёт порядок, поэтому сериализуем месяцы по возрастанию.
    local months = {}
    for monthIndex in pairs(self.generated) do
        months[#months + 1] = monthIndex
    end
    table.sort(months)
    setXMLInt(xml, "contractSupplyRotation#count", #months)
    for i, monthIndex in ipairs(months) do
        local key = string.format("contractSupplyRotation.month(%d)", i - 1)
        setXMLInt(xml, key .. "#index", monthIndex)
        setXMLString(xml, key .. "#type", self.generated[monthIndex].typeName)
        setXMLString(xml, key .. "#missionId", self.generated[monthIndex].missionId)
    end
    saveXMLFile(xml)
    delete(xml)
    return true
end

-- Восстанавливает состояние атомарно; некорректный XML не портит текущий учёт.
function ContractSupplyRotation:load(directory)
    if type(directory) ~= "string" or directory == "" then
        return false, "invalidDirectory"
    end
    local filename = directory .. "/" .. self.FILENAME
    if not fileExists(filename) then
        return false, "fileMissing"
    end
    local xml = loadXMLFile("taigaSupplyRotationLoad", filename)
    if xml == nil or xml == 0 then
        return false, "cannotOpen"
    end
    local order = {}
    for i = 0, 2 do
        order[i + 1] = getXMLString(xml,
            string.format("contractSupplyRotation.order(%d)#type", i))
    end
    local state = ContractSupplyRotation.new(order)
    local count = getXMLInt(xml, "contractSupplyRotation#count")
    if getXMLInt(xml, "contractSupplyRotation#version") ~= self.VERSION
        or state == nil or count == nil or count < 0 then
        delete(xml)
        return false, "invalidHeader"
    end
    for i = 0, count - 1 do
        local key = string.format("contractSupplyRotation.month(%d)", i)
        local monthIndex = getXMLInt(xml, key .. "#index")
        local missionId = getXMLString(xml, key .. "#missionId")
        local typeName = getXMLString(xml, key .. "#type")
        if state:getTypeForMonth(monthIndex) ~= typeName
            or not state:markGenerated(monthIndex, missionId) then
            delete(xml)
            return false, "invalidMonth"
        end
    end
    delete(xml)
    self.order = state.order
    self.generated = state.generated
    return true
end

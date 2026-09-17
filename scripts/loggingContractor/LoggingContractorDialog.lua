--[[
    LoggingContractorDialog

    Единое окно подготовки договора подрядчика на лесоповал.

    Текущий этап:
    - выбор принадлежащего текущей ферме участка;
    - немедленный подсчёт стоящих деревьев выбранного участка по породам;
    - ручная настройка количества техники;
    - немедленный пересчёт времени и стоимости без открытия второго окна.
]]

LoggingContractorDialog = {}
local LoggingContractorDialog_mt = Class(LoggingContractorDialog, DialogElement)

LoggingContractorDialog.GUI_NAME = "LoggingContractorDialog"
LoggingContractorDialog.GUI_XML = "gui/LoggingContractorDialog.xml"
LoggingContractorDialog.INSTANCE = nil
LoggingContractorDialog.baseDirectory = nil


-- Создаёт контроллер единого окна подрядчика.
function LoggingContractorDialog.new(target, customMt)
    local self = DialogElement.new(target, customMt or LoggingContractorDialog_mt)
    self.contractor = nil
    self.farmlands = {}
    self.currentFarmland = nil
    self.currentScan = nil
    self.currentEquipmentCount = 0
    self.maxEquipmentCount = 0

    return self
end


-- Сохраняет каталог карты, необходимый для загрузки собственного GUI XML.
function LoggingContractorDialog.setBaseDirectory(baseDirectory)
    LoggingContractorDialog.baseDirectory = baseDirectory
end


-- Регистрирует собственный GUI-диалог один раз на клиенте.
function LoggingContractorDialog.register()
    if LoggingContractorDialog.INSTANCE ~= nil then
        return true
    end

    if g_gui == nil or LoggingContractorDialog.baseDirectory == nil then
        Logging.warning("[LoggingContractorDialog] GUI cannot be registered: base directory or g_gui is unavailable")
        return false
    end

    local dialog = LoggingContractorDialog.new()
    local filename = Utils.getFilename(LoggingContractorDialog.GUI_XML, LoggingContractorDialog.baseDirectory)
    g_gui:loadGui(filename, LoggingContractorDialog.GUI_NAME, dialog)
    LoggingContractorDialog.INSTANCE = dialog

    return true
end


-- Возвращает понятное сообщение для ошибки подготовки данных участка.
function LoggingContractorDialog.getScanErrorText(errorCode)
    if errorCode == "farmlandNotOwned" then
        return "Выбранный участок больше не принадлежит текущей ферме."
    elseif errorCode == "farmlandNotFound" then
        return "Выбранный участок больше не существует."
    elseif errorCode == "farmlandBoundsUnavailable" then
        return "Не удалось получить границы выбранного участка."
    elseif errorCode == "managerUnavailable" then
        return "Системы участков или деревьев ещё не готовы."
    end

    return "Не удалось получить данные выбранного участка."
end


-- Заполняет селектор участками текущей фермы и подготавливает первый участок.
function LoggingContractorDialog:setData(contractor, farmlands)
    self.contractor = contractor
    self.farmlands = farmlands or {}
    self.currentFarmland = nil
    self.currentScan = nil
    self.currentEquipmentCount = 0
    self.maxEquipmentCount = 0

    if #self.farmlands == 0 then
        self.farmlandOption:setTexts({"Нет принадлежащих участков"})
        self.farmlandOption:setState(1)
        self.farmlandOption:setDisabled(true)
        self.statisticsText:setText("У текущей фермы нет принадлежащих ей участков.")
        self.equipmentHintText:setText("Расчётное количество техники: 0")
        self:setEquipmentCount(0)
        return
    end

    local options = {}
    for _, farmland in ipairs(self.farmlands) do
        table.insert(options, string.format("Участок %d", farmland.id))
    end

    self.farmlandOption:setDisabled(false)
    self.farmlandOption:setTexts(options)
    self.farmlandOption:setState(1)
    self:selectFarmland(1)
end


-- Формирует многострочную статистику пород для выбранного участка.
function LoggingContractorDialog:updateStatisticsText(scan)
    local lines = {
        string.format("Стоящих деревьев: %d", scan.totalCount)
    }

    if #scan.species == 0 then
        table.insert(lines, "Породы: деревьев нет")
    else
        for _, species in ipairs(scan.species) do
            table.insert(lines, string.format("%s: %d", species.title, species.count))
        end
    end

    self.statisticsText:setText(table.concat(lines, "\n"))
end


-- Выбирает участок, выполняет его сканирование и задаёт начальное количество
-- техники по правилу ceil(treeCount / 100).
function LoggingContractorDialog:selectFarmland(index)
    local farmland = self.farmlands[index]
    if farmland == nil or self.contractor == nil then
        return
    end

    self.currentFarmland = farmland

    local farmId = self.contractor.mission:getFarmId()
    local scan, errorCode = self.contractor:scanFarmlandTrees(farmland.id, farmId)
    if scan == nil then
        self.currentScan = nil
        self.maxEquipmentCount = 0
        self.statisticsText:setText(LoggingContractorDialog.getScanErrorText(errorCode))
        self.equipmentHintText:setText("Расчётное количество техники: 0")
        self:setEquipmentCount(0)
        return
    end

    self.currentScan = scan
    self.maxEquipmentCount = scan.totalCount
    self:updateStatisticsText(scan)

    local recommendedCount = self.contractor:getRecommendedEquipmentCount(scan.totalCount)
    self.equipmentHintText:setText(string.format("Расчётное количество техники: %d", recommendedCount))
    self:setEquipmentCount(recommendedCount)
end


-- Устанавливает выбранное количество техники и сразу обновляет расчёт.
-- Верхняя граница равна числу деревьев: техника сверх числа текущих целей
-- не может обработать дополнительные деревья за один рабочий такт.
function LoggingContractorDialog:setEquipmentCount(equipmentCount)
    if self.currentScan == nil or self.currentScan.totalCount <= 0 then
        self.currentEquipmentCount = 0
    else
        self.currentEquipmentCount = math.clamp(
            math.floor(equipmentCount),
            1,
            math.max(self.maxEquipmentCount, 1)
        )
    end

    self.equipmentValueText:setText(tostring(self.currentEquipmentCount))
    self:updateEquipmentButtons()
    self:updateEstimate()
end


-- Обновляет доступность кнопок уменьшения и увеличения количества техники.
function LoggingContractorDialog:updateEquipmentButtons()
    local hasTrees = self.currentScan ~= nil and self.currentScan.totalCount > 0

    self.equipmentMinusButton:setDisabled(not hasTrees or self.currentEquipmentCount <= 1)
    self.equipmentPlusButton:setDisabled(
        not hasTrees or self.currentEquipmentCount >= self.maxEquipmentCount
    )
end


-- Пересчитывает время и стоимость для выбранного пользователем количества техники.
function LoggingContractorDialog:updateEstimate()
    if self.currentScan == nil or self.currentScan.totalCount <= 0 then
        self.estimateText:setText("Расчётное время: 0 ч\nСтоимость подрядчика: 0")
        return
    end

    local estimate = self.contractor:calculateEstimate(
        self.currentScan.totalCount,
        self.currentEquipmentCount
    )

    self.estimateText:setText(string.format(
        "Расчётное время: %d ч\nСтоимость подрядчика: %d",
        estimate.workHours,
        estimate.totalCost
    ))
end


-- Обрабатывает смену участка в верхнем селекторе окна.
function LoggingContractorDialog:onClickFarmland(state)
    self:selectFarmland(state)
end


-- Уменьшает количество техники на одну единицу и пересчитывает договор.
function LoggingContractorDialog:onClickEquipmentMinus()
    if self.currentEquipmentCount > 1 then
        self:setEquipmentCount(self.currentEquipmentCount - 1)
    end
end


-- Увеличивает количество техники на одну единицу и пересчитывает договор.
function LoggingContractorDialog:onClickEquipmentPlus()
    if self.currentScan ~= nil and self.currentEquipmentCount < self.maxEquipmentCount then
        self:setEquipmentCount(self.currentEquipmentCount + 1)
    end
end


-- Показывает единое окно выбора участка, статистики и расчёта подрядчика.
function LoggingContractorDialog.show(contractor)
    if contractor == nil or contractor.mission == nil then
        return
    end

    if not LoggingContractorDialog.register() then
        return
    end

    local farmId = contractor.mission:getFarmId()
    local farmlands = contractor:getOwnedFarmlands(farmId)
    local dialog = LoggingContractorDialog.INSTANCE

    dialog:setData(contractor, farmlands)
    g_gui:showDialog(LoggingContractorDialog.GUI_NAME)
end


-- Очищает ссылки на данные миссии после закрытия окна.
function LoggingContractorDialog:onClose()
    self.contractor = nil
    self.farmlands = {}
    self.currentFarmland = nil
    self.currentScan = nil
    self.currentEquipmentCount = 0
    self.maxEquipmentCount = 0

    LoggingContractorDialog:superClass().onClose(self)
end

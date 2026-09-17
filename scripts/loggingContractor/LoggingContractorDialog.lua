--[[
    LoggingContractorDialog

    Контроллер пользовательского окна подрядчиков на лесоповал.

    Текущий этап:
    - показывает только участки текущей фермы;
    - после выбора участка запускает подсчёт стоящих деревьев по породам;
    - показывает рассчитанные количество техники, время и стоимость подрядчика.
]]

LoggingContractorDialog = {}


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


-- Показывает результаты сканирования выбранного участка и расчёт подрядчика.
function LoggingContractorDialog.showFarmlandDetails(contractor, farmland)
    local farmId = contractor.mission:getFarmId()
    local scan, errorCode = contractor:scanFarmlandTrees(farmland.id, farmId)

    if scan == nil then
        InfoDialog.show(
            LoggingContractorDialog.getScanErrorText(errorCode),
            nil,
            nil,
            DialogElement.TYPE_INFO
        )
        return
    end

    local estimate = contractor:calculateEstimate(scan.totalCount)
    local lines = {
        string.format("Участок %d", farmland.id),
        "",
        string.format("Стоящих деревьев: %d", scan.totalCount)
    }

    if #scan.species == 0 then
        table.insert(lines, "Породы: деревьев нет")
    else
        for _, species in ipairs(scan.species) do
            table.insert(lines, string.format("%s: %d", species.title, species.count))
        end
    end

    table.insert(lines, "")
    table.insert(lines, string.format("Техника: %d", estimate.equipmentCount))
    table.insert(lines, string.format("Расчётное время: %d ч", estimate.workHours))
    table.insert(lines, string.format("Стоимость подрядчика: %d", estimate.totalCost))

    InfoDialog.show(
        table.concat(lines, "\n"),
        nil,
        nil,
        DialogElement.TYPE_INFO
    )
end


-- Показывает выбор участка из списка земель, принадлежащих текущей ферме.
function LoggingContractorDialog.show(contractor)
    if contractor == nil or contractor.mission == nil then
        return
    end

    local farmId = contractor.mission:getFarmId()
    local farmlands = contractor:getOwnedFarmlands(farmId)

    if #farmlands == 0 then
        InfoDialog.show(
            "У текущей фермы нет принадлежащих ей участков.",
            nil,
            nil,
            DialogElement.TYPE_INFO
        )
        return
    end

    local options = {}
    for _, farmland in ipairs(farmlands) do
        table.insert(options, string.format("Участок %d", farmland.id))
    end

    OptionDialog.show(
        function(selectedIndex)
            if selectedIndex ~= nil and selectedIndex > 0 then
                local farmland = farmlands[selectedIndex]
                if farmland ~= nil then
                    LoggingContractorDialog.showFarmlandDetails(contractor, farmland)
                end
            end
        end,
        "Выберите участок для расчёта лесозаготовки.",
        "Подрядчики на лесоповал",
        options,
        1
    )
end

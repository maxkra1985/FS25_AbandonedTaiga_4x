--[[
    LoggingContractorDialog

    Единое окно подготовки договора подрядчика на лесоповал.

    Текущий этап:
    - выбор принадлежащего текущей ферме участка;
    - немедленный подсчёт стоящих деревьев выбранного участка по породам;
    - ручная настройка количества техники;
    - выбор длины брёвен 3 / 6 / 9 / 12 м;
    - отображение фактического времени с точностью до 0.1 часа;
    - расчёт почасовой стоимости по оплачиваемым часам, округлённым вверх;
    - отправка серверного запроса на заключение договора и показ результата.
]]

LoggingContractorDialog = {}
local LoggingContractorDialog_mt = Class(LoggingContractorDialog, DialogElement)

LoggingContractorDialog.GUI_NAME = "LoggingContractorDialog"
LoggingContractorDialog.GUI_XML = "gui/LoggingContractorDialog.xml"
LoggingContractorDialog.INSTANCE = nil
LoggingContractorDialog.baseDirectory = nil
LoggingContractorDialog.LOG_LENGTHS = {3, 6, 9, 12}
LoggingContractorDialog.SPECIES_ROWS_PER_PAGE = 9


-- Создаёт контроллер единого окна подрядчика.
function LoggingContractorDialog.new(target, customMt)
    local self = DialogElement.new(target, customMt or LoggingContractorDialog_mt)
    self.contractor = nil
    self.farmlands = {}
    self.currentFarmland = nil
    self.currentScan = nil
    self.currentEstimate = nil
    self.currentContractDraft = nil
    self.currentEquipmentCount = 0
    self.maxEquipmentCount = 0
    self.currentLogLength = LoggingContractorDialog.LOG_LENGTHS[1]
    self.onlyMarkedTrees = false
    self.pruneLargeBranches = true
    self.selectedSpecies = {}
    self.speciesPage = 1
    self.startRequestPending = false

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


-- Возвращает сообщение для ошибки подготовки локального draft договора.
function LoggingContractorDialog.getContractDraftErrorText(errorCode)
    if errorCode == "noTrees" then
        return "На выбранном участке больше нет стоящих деревьев."
    elseif errorCode == "noMarkedTrees" then
        return "На выбранном участке нет стоящих деревьев, помеченных маркером."
    elseif errorCode == "invalidEquipment" then
        return "Выбрано недопустимое количество техники."
    elseif errorCode == "invalidLogLength" then
        return "Выбрана недопустимая длина брёвен."
    elseif errorCode == "noSelectedSpecies" then
        return "Выберите хотя бы одну породу деревьев."
    end

    return LoggingContractorDialog.getScanErrorText(errorCode)
end


-- Возвращает понятное сообщение для отклонённого сервером запроса.
function LoggingContractorDialog.getStartContractResultErrorText(state)
    if state == LoggingContractorResultEvent.STATE_NO_PERMISSION then
        return "Недостаточно прав для заключения договоров от имени фермы."
    elseif state == LoggingContractorResultEvent.STATE_FARM_NOT_FOUND then
        return "Не удалось определить ферму игрока."
    elseif state == LoggingContractorResultEvent.STATE_FARMLAND_NOT_FOUND then
        return "Выбранный участок больше не существует."
    elseif state == LoggingContractorResultEvent.STATE_FARMLAND_NOT_OWNED then
        return "Выбранный участок больше не принадлежит вашей ферме."
    elseif state == LoggingContractorResultEvent.STATE_NO_TREES then
        return "На выбранном участке больше нет стоящих деревьев."
    elseif state == LoggingContractorResultEvent.STATE_NO_MARKED_TREES then
        return "На выбранном участке нет стоящих деревьев, помеченных маркером."
    elseif state == LoggingContractorResultEvent.STATE_INVALID_EQUIPMENT then
        return "Сервер отклонил выбранное количество техники."
    elseif state == LoggingContractorResultEvent.STATE_INVALID_LOG_LENGTH then
        return "Сервер отклонил выбранную длину брёвен."
    elseif state == LoggingContractorResultEvent.STATE_NO_SELECTED_SPECIES then
        return "Сервер отклонил выбранные породы деревьев."
    elseif state == LoggingContractorResultEvent.STATE_NOT_ENOUGH_MONEY then
        return "На счету фермы недостаточно средств для заключения договора."
    elseif state == LoggingContractorResultEvent.STATE_ALREADY_ACTIVE then
        return "На этом участке уже выполняется договор подрядчика вашей фермы."
    end

    return "Не удалось заключить договор подряда из-за внутренней ошибки."
end


-- Заполняет селекторы окна и подготавливает первый принадлежащий ферме участок.
function LoggingContractorDialog:setData(contractor, farmlands)
    self.contractor = contractor
    self.farmlands = farmlands or {}
    self.currentFarmland = nil
    self.currentScan = nil
    self.currentEstimate = nil
    self.currentContractDraft = nil
    self.currentEquipmentCount = 0
    self.maxEquipmentCount = 0
    self.startRequestPending = false
    self.onlyMarkedTrees = false
    self.pruneLargeBranches = true
    self.selectedSpecies = {}
    self.speciesPage = 1

    self.onlyMarkedOption:setTexts({"Нет", "Да"})
    self.onlyMarkedOption:setState(1)
    self.pruneLargeBranchesOption:setTexts({"Нет", "Да"})
    self.pruneLargeBranchesOption:setState(2)

    local logLengthTexts = {}
    for _, length in ipairs(LoggingContractorDialog.LOG_LENGTHS) do
        table.insert(logLengthTexts, string.format("%d м", length))
    end
    self.logLengthOption:setTexts(logLengthTexts)
    self.logLengthOption:setState(1)
    self.currentLogLength = LoggingContractorDialog.LOG_LENGTHS[1]

    if #self.farmlands == 0 then
        self.farmlandOption:setTexts({"Нет принадлежащих участков"})
        self.farmlandOption:setState(1)
        self.farmlandOption:setDisabled(true)
        self.treeCountText:setText("У текущей фермы нет принадлежащих ей участков.")
        self:updateStatisticsText({species = {}, totalCount = 0})
        self.equipmentHintText:setText("Расчётное количество техники: 0")
        self:setEquipmentOptions(0, 0)
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


-- Считает выбранные деревья из полного сканирования участка.
function LoggingContractorDialog:getSelectedTreeCount(scan)
    local count = 0
    for _, species in ipairs(scan ~= nil and scan.species or {}) do
        if self.selectedSpecies[species.name] ~= false then
            count = count + species.count
        end
    end
    return count
end


-- Возвращает имена отмеченных пород для проверяемого сервером запроса.
function LoggingContractorDialog:getSelectedSpeciesNames(scan)
    local names = {}
    for _, species in ipairs(scan ~= nil and scan.species or {}) do
        if self.selectedSpecies[species.name] ~= false then
            table.insert(names, species.name)
        end
    end
    return names
end


-- Отображает текущую страницу списка пород с независимыми переключателями.
function LoggingContractorDialog:updateStatisticsText(scan)
    local title = scan.onlyMarkedTrees and "Помеченных стоящих деревьев" or "Стоящих деревьев"
    self.treeCountText:setText(string.format(
        "%s: %d из %d", title, self:getSelectedTreeCount(scan), scan.totalCount
    ))

    local totalPages = math.max(
        math.ceil(#scan.species / LoggingContractorDialog.SPECIES_ROWS_PER_PAGE), 1
    )
    self.speciesPage = math.clamp(self.speciesPage, 1, totalPages)
    for index = 1, LoggingContractorDialog.SPECIES_ROWS_PER_PAGE do
        local speciesIndex =
            (self.speciesPage - 1) * LoggingContractorDialog.SPECIES_ROWS_PER_PAGE + index
        local species = scan.species[speciesIndex]
        local label = self["speciesLabel" .. index]
        local option = self["speciesOption" .. index]
        if species ~= nil then
            label:setText(string.format("%s: %d", species.title, species.count))
            label:setVisible(true)
            option:setTexts({"Нет", "Да"})
            option:setState(self.selectedSpecies[species.name] == false and 1 or 2)
            option:setVisible(true)
        else
            label:setVisible(false)
            option:setVisible(false)
        end
    end
    local pages = {}
    for page = 1, totalPages do
        table.insert(pages, string.format("%d/%d", page, totalPages))
    end
    self.speciesPageOption:setTexts(pages)
    self.speciesPageOption:setState(self.speciesPage)
    self.speciesPageOption:setDisabled(totalPages == 1)
end


-- Заполняет MultiTextOption доступными количествами техники и выбирает
-- указанное значение. При отсутствии деревьев селектор блокируется на нуле.
function LoggingContractorDialog:setEquipmentOptions(maxEquipmentCount, selectedEquipmentCount)
    self.maxEquipmentCount = math.max(math.floor(maxEquipmentCount or 0), 0)

    if self.maxEquipmentCount <= 0 then
        self.currentEquipmentCount = 0
        self.equipmentOption:setTexts({"0"})
        self.equipmentOption:setState(1)
        self.equipmentOption:setDisabled(true)
        self:updateEstimate()
        return
    end

    local texts = {}
    for equipmentCount = 1, self.maxEquipmentCount do
        table.insert(texts, tostring(equipmentCount))
    end

    self.currentEquipmentCount = math.clamp(
        math.floor(selectedEquipmentCount or 1),
        1,
        self.maxEquipmentCount
    )

    self.equipmentOption:setDisabled(false)
    self.equipmentOption:setTexts(texts)
    self.equipmentOption:setState(self.currentEquipmentCount)
    self:updateEstimate()
end


-- Выбирает участок, выполняет его сканирование и задаёт начальное количество
-- техники по правилу ceil(treeCount / 100).
function LoggingContractorDialog:refreshCurrentFarmlandScan()
    if self.currentFarmland == nil or self.contractor == nil then
        return
    end

    self.currentContractDraft = nil

    local farmId = self.contractor.mission:getFarmId()
    local scan, errorCode = self.contractor:scanFarmlandTrees(
        self.currentFarmland.id,
        farmId,
        self.onlyMarkedTrees
    )
    if scan == nil then
        self.currentScan = nil
        self.currentEstimate = nil
        self.treeCountText:setText(LoggingContractorDialog.getScanErrorText(errorCode))
        self:updateStatisticsText({species = {}, totalCount = 0})
        self.equipmentHintText:setText("Расчётное количество техники: 0")
        self:setEquipmentOptions(0, 0)
        return
    end

    self.currentScan = scan
    self:updateStatisticsText(scan)

    local selectedCount = self:getSelectedTreeCount(scan)
    local recommendedCount = self.contractor:getRecommendedEquipmentCount(selectedCount)
    self.equipmentHintText:setText(string.format("Расчётное количество техники: %d", recommendedCount))
    self:setEquipmentOptions(selectedCount, recommendedCount)
end


function LoggingContractorDialog:selectFarmland(index)
    local farmland = self.farmlands[index]
    if farmland == nil or self.contractor == nil then
        return
    end

    self.currentFarmland = farmland
    self:refreshCurrentFarmlandScan()
end


-- Обновляет доступность кнопки заключения договора.
function LoggingContractorDialog:updateStartContractButton()
    if self.startContractButton == nil then
        return
    end

    local canStart = not self.startRequestPending
        and self.contractor ~= nil
        and self.currentFarmland ~= nil
        and self.currentScan ~= nil
        and self:getSelectedTreeCount(self.currentScan) > 0
        and self.currentEquipmentCount > 0
        and self.currentEstimate ~= nil

    self.startContractButton:setDisabled(not canStart)
end


-- Пересчитывает время и детализированную стоимость для выбранного количества
-- техники. Время показывается с точностью до 0.1 часа, а почасовые статьи
-- используют billableHours, уже округлённые вверх в расчёте подрядчика.
-- Денежные суммы форматируются штатным I18N, чтобы использовать локальный
-- разделитель разрядов и активный символ валюты игры или валютного мода.
function LoggingContractorDialog:updateEstimate()
    self.currentContractDraft = nil

    local zeroMoney = g_i18n:formatMoney(0, 0, true, false)
    local selectedCount = self:getSelectedTreeCount(self.currentScan)
    if selectedCount <= 0 or self.currentEquipmentCount <= 0 then
        self.currentEstimate = nil
        self.estimateTimeText:setText("Расчётное время: 0,0 ч")
        self.rentCostText:setText(string.format("Аренда техники: %s", zeroMoney))
        self.equipmentWorkCostText:setText(string.format("Работа техники: %s", zeroMoney))
        self.workerCostText:setText(string.format("Рабочие: %s", zeroMoney))
        self.totalCostText:setText(string.format("Итого: %s", zeroMoney))
        self:updateStartContractButton()
        return
    end

    local estimate = self.contractor:calculateEstimate(
        selectedCount,
        self.currentEquipmentCount
    )
    self.currentEstimate = estimate

    local workHoursText = string.format("%.1f", estimate.workHours):gsub("%.", ",")
    local rentCostText = g_i18n:formatMoney(estimate.rentCost, 0, true, false)
    local equipmentWorkCostText = g_i18n:formatMoney(estimate.equipmentWorkCost, 0, true, false)
    local workerCostText = g_i18n:formatMoney(estimate.workerCost, 0, true, false)
    local totalCostText = g_i18n:formatMoney(estimate.totalCost, 0, true, false)

    self.estimateTimeText:setText(string.format("Расчётное время: %s ч", workHoursText))
    self.rentCostText:setText(string.format("Аренда техники: %s", rentCostText))
    self.equipmentWorkCostText:setText(string.format(
        "Работа техники (%d оплач. ч): %s",
        estimate.billableHours,
        equipmentWorkCostText
    ))
    self.workerCostText:setText(string.format(
        "Рабочие (%d оплач. ч): %s",
        estimate.billableHours,
        workerCostText
    ))
    self.totalCostText:setText(string.format("Итого: %s", totalCostText))
    self:updateStartContractButton()
end


-- Повторно проверяет выбранный участок непосредственно перед отправкой запроса
-- и формирует локальный draft. Сервер всё равно независимо повторит проверки.
function LoggingContractorDialog:createContractDraft()
    if self.contractor == nil or self.currentFarmland == nil then
        return nil, "farmlandNotFound"
    end

    local farmId = self.contractor.mission:getFarmId()
    local scan, errorCode = self.contractor:scanFarmlandTrees(
        self.currentFarmland.id,
        farmId,
        self.onlyMarkedTrees
    )
    if scan == nil then
        return nil, errorCode
    end

    if scan.totalCount <= 0 then
        self.currentScan = scan
        self:updateStatisticsText(scan)
        self.equipmentHintText:setText("Расчётное количество техники: 0")
        self:setEquipmentOptions(0, 0)
        return nil, self.onlyMarkedTrees and "noMarkedTrees" or "noTrees"
    end

    local selectedCount = self:getSelectedTreeCount(scan)
    if selectedCount <= 0 then
        self.currentScan = scan
        self:updateStatisticsText(scan)
        self:setEquipmentOptions(0, 0)
        return nil, "noSelectedSpecies"
    end

    local equipmentCount = math.floor(self.currentEquipmentCount or 0)
    if equipmentCount <= 0 then
        return nil, "invalidEquipment"
    end

    equipmentCount = math.min(
        equipmentCount,
        selectedCount
    )

    local logLengthIsValid = false
    for _, length in ipairs(LoggingContractorDialog.LOG_LENGTHS) do
        if length == self.currentLogLength then
            logLengthIsValid = true
            break
        end
    end
    if not logLengthIsValid then
        return nil, "invalidLogLength"
    end

    self.currentScan = scan
    self:updateStatisticsText(scan)

    local recommendedCount = self.contractor:getRecommendedEquipmentCount(selectedCount)
    self.equipmentHintText:setText(string.format("Расчётное количество техники: %d", recommendedCount))

    if self.maxEquipmentCount ~= selectedCount
        or self.currentEquipmentCount ~= equipmentCount then
        self:setEquipmentOptions(selectedCount, equipmentCount)
    else
        self:updateEstimate()
    end

    local estimate = self.currentEstimate
    if estimate == nil then
        return nil, "invalidEquipment"
    end

    local draft = {
        farmId = farmId,
        farmlandId = self.currentFarmland.id,
        plannedTrees = selectedCount,
        selectedSpecies = self:getSelectedSpeciesNames(scan),
        onlyMarkedTrees = self.onlyMarkedTrees,
        pruneLargeBranches = self.pruneLargeBranches,
        equipmentCount = self.currentEquipmentCount,
        logLength = self.currentLogLength,
        workHours = estimate.workHours,
        billableHours = estimate.billableHours,
        rentCost = estimate.rentCost,
        equipmentWorkCost = estimate.equipmentWorkCost,
        workerCost = estimate.workerCost,
        totalCost = estimate.totalCost
    }

    self.currentContractDraft = draft
    return draft
end


-- Обрабатывает смену участка в верхнем селекторе окна.
-- Переключает породу на текущей странице и обновляет расчёт.
function LoggingContractorDialog:onClickSpeciesRow(row, state)
    if self.currentScan == nil then
        return
    end
    local index = (self.speciesPage - 1)
        * LoggingContractorDialog.SPECIES_ROWS_PER_PAGE + row
    local species = self.currentScan.species[index]
    if species == nil then
        return
    end
    self.selectedSpecies[species.name] = state == 2
    self.currentContractDraft = nil
    self:updateStatisticsText(self.currentScan)
    local selectedCount = self:getSelectedTreeCount(self.currentScan)
    local equipmentCount = math.min(self.currentEquipmentCount, selectedCount)
    self.equipmentHintText:setText(string.format(
        "Расчётное количество техники: %d",
        self.contractor:getRecommendedEquipmentCount(selectedCount)
    ))
    self:setEquipmentOptions(selectedCount, equipmentCount)
end


-- Меняет страницу переключателей при большом количестве пород.
function LoggingContractorDialog:onClickSpeciesPage(state)
    self.speciesPage = state
    if self.currentScan ~= nil then
        self:updateStatisticsText(self.currentScan)
    end
end


function LoggingContractorDialog:onClickSpecies1(state)
    self:onClickSpeciesRow(1, state)
end


function LoggingContractorDialog:onClickSpecies2(state)
    self:onClickSpeciesRow(2, state)
end


function LoggingContractorDialog:onClickSpecies3(state)
    self:onClickSpeciesRow(3, state)
end


function LoggingContractorDialog:onClickSpecies4(state)
    self:onClickSpeciesRow(4, state)
end


function LoggingContractorDialog:onClickSpecies5(state)
    self:onClickSpeciesRow(5, state)
end


function LoggingContractorDialog:onClickSpecies6(state)
    self:onClickSpeciesRow(6, state)
end


function LoggingContractorDialog:onClickSpecies7(state)
    self:onClickSpeciesRow(7, state)
end


function LoggingContractorDialog:onClickSpecies8(state)
    self:onClickSpeciesRow(8, state)
end


function LoggingContractorDialog:onClickSpecies9(state)
    self:onClickSpeciesRow(9, state)
end


function LoggingContractorDialog:onClickFarmland(state)
    self:selectFarmland(state)
end


-- Обрабатывает выбор количества техники и сразу обновляет расчёт договора.
function LoggingContractorDialog:onClickOnlyMarkedTrees(state)
    self.onlyMarkedTrees = state == 2
    self.currentContractDraft = nil
    self:refreshCurrentFarmlandScan()
end


-- Сохраняет настройку обработки крупных ветвей для нового договора.
-- На расчёт стоимости и количество выбранных деревьев этот переключатель не влияет.
function LoggingContractorDialog:onClickPruneLargeBranches(state)
    self.pruneLargeBranches = state == 2
    self.currentContractDraft = nil
end


function LoggingContractorDialog:onClickEquipment(state)
    if self.currentScan == nil or self:getSelectedTreeCount(self.currentScan) <= 0 then
        return
    end

    self.currentEquipmentCount = math.clamp(state, 1, self.maxEquipmentCount)
    self:updateEstimate()
end


-- Сохраняет выбранную длину брёвен для будущего договора.
-- На текущем этапе длина распила не изменяет расчёт времени и стоимости.
function LoggingContractorDialog:onClickLogLength(state)
    local length = LoggingContractorDialog.LOG_LENGTHS[state]
    if length ~= nil then
        self.currentLogLength = length
        self.currentContractDraft = nil
    end
end


-- Отправляет серверу запрос на заключение договора. Клиентские рассчитанные
-- стоимость и количество деревьев в сетевое событие не передаются.
function LoggingContractorDialog:onClickStartContract()
    if self.startRequestPending then
        return
    end

    local draft, errorCode = self:createContractDraft()
    if draft == nil then
        InfoDialog.show(
            LoggingContractorDialog.getContractDraftErrorText(errorCode),
            nil,
            nil,
            DialogElement.TYPE_INFO
        )
        return
    end

    self.startRequestPending = true
    self:updateStartContractButton()

    Logging.info(
        "[LoggingContractor] Start request: farm=%d farmland=%d previewTrees=%d onlyMarked=%s pruneLargeBranches=%s equipment=%d logLength=%d previewCost=%d species=%s",
        draft.farmId,
        draft.farmlandId,
        draft.plannedTrees,
        tostring(draft.onlyMarkedTrees),
        tostring(draft.pruneLargeBranches),
        draft.equipmentCount,
        draft.logLength,
        draft.totalCost,
        table.concat(draft.selectedSpecies, ",")
    )

    if not LoggingContractorStartEvent.sendEvent(
        draft.farmlandId,
        draft.equipmentCount,
        draft.logLength,
        draft.onlyMarkedTrees,
        draft.pruneLargeBranches,
        draft.selectedSpecies
    ) then
        self.startRequestPending = false
        self:updateStartContractButton()

        InfoDialog.show(
            "Не удалось отправить запрос на заключение договора серверу.",
            nil,
            nil,
            DialogElement.TYPE_INFO
        )
    end
end


-- Обрабатывает ответ сервера на заключение договора. При успехе отображаются
-- именно серверные параметры и фактически списанная стоимость.
function LoggingContractorDialog.onStartContractResult(event)
    local dialog = LoggingContractorDialog.INSTANCE
    if dialog ~= nil then
        dialog.startRequestPending = false
        dialog:updateStartContractButton()
    end

    if event.state ~= LoggingContractorResultEvent.STATE_SUCCESS then
        InfoDialog.show(
            LoggingContractorDialog.getStartContractResultErrorText(event.state),
            nil,
            nil,
            DialogElement.TYPE_INFO
        )
        return
    end

    if g_gui ~= nil then
        g_gui:closeDialogByName(LoggingContractorDialog.GUI_NAME)
    end

    local workHoursText = string.format("%.1f", event.workHours):gsub("%.", ",")
    local totalCostText = g_i18n:formatMoney(event.totalCost, 0, true, false)
    InfoDialog.show(
        string.format(
            "Договор подряда заключён.\n\n"
                .. "Участок: %d\n"
                .. "Запланировано к спилу: %d\n"
                .. "Только помеченные деревья: %s\n"
                .. "Обрезать крупные ветви: %s\n"
                .. "Техника: %d\n"
                .. "Длина брёвен: %d м\n"
                .. "Расчётное время: %s ч\n"
                .. "Списано со счёта фермы: %s",
            event.farmlandId,
            event.plannedTrees,
            event.onlyMarkedTrees and "Да" or "Нет",
            event.pruneLargeBranches and "Да" or "Нет",
            event.equipmentCount,
            event.logLength,
            workHoursText,
            totalCostText
        ),
        nil,
        nil,
        DialogElement.TYPE_INFO
    )
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
    self.currentEstimate = nil
    self.currentContractDraft = nil
    self.currentEquipmentCount = 0
    self.maxEquipmentCount = 0
    self.currentLogLength = LoggingContractorDialog.LOG_LENGTHS[1]
    self.onlyMarkedTrees = false
    self.pruneLargeBranches = true
    self.startRequestPending = false
    self.selectedSpecies = {}
    self.speciesPage = 1

    LoggingContractorDialog:superClass().onClose(self)
end

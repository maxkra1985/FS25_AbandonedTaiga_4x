--[[
    ContractRatingDialog
    Рейтинг текущей фермы, пороги доступа и постраничный журнал рейтинговых
    операций. Отображает только сведения, которые уже есть в серверном журнале;
    не подменяет отсутствующую историю попыток вымышленными данными.
]]
ContractRatingDialog = {}
local ContractRatingDialog_mt = Class(ContractRatingDialog, DialogElement)
ContractRatingDialog.GUI_NAME = "ContractRatingDialog"
ContractRatingDialog.GUI_XML = "gui/ContractRatingDialog.xml"
ContractRatingDialog.ROWS_PER_PAGE = 8
ContractRatingDialog.INSTANCE = nil
ContractRatingDialog.baseDirectory = nil
ContractRatingDialog.TYPE_TITLES = {
    deadwoodMission = "Очистка сухостоя",
    treeTransportMission = "Перевозка древесины",
    destructibleRockMission = "Разбивание камней",
    taigaSupplyMission = "Поставка продукции",
    taigaLoggingMission = "Лесозаготовка",
    taigaPlantingMission = "Посадка леса",
    taigaQuestClearingMission = "Расчистка участка",
    taigaQuestConstructionMission = "Строительство",
    taigaQuestLandscapingMission = "Благоустройство"
}

-- Создаёт контроллер независимого диалога.
function ContractRatingDialog.new(target, customMt)
    local self = DialogElement.new(target, customMt or ContractRatingDialog_mt)
    self.section = 1
    self.filter = 1
    self.page = 1
    self.farmId = nil
    self.refreshTimer = 0
    return self
end

-- Регистрирует диалог после готовности GUI, без нагрузки на выделенный сервер.
function ContractRatingDialog.register()
    if ContractRatingDialog.INSTANCE ~= nil then return true end
    if g_gui == nil or ContractRatingDialog.baseDirectory == nil then return false end

    local dialog = ContractRatingDialog.new()
    local filename = Utils.getFilename(ContractRatingDialog.GUI_XML,
        ContractRatingDialog.baseDirectory)
    g_gui:loadGui(filename, ContractRatingDialog.GUI_NAME, dialog)
    ContractRatingDialog.INSTANCE = dialog
    return true
end

-- Возвращает локальную копию серверного журнала и выбранную ферму.
function ContractRatingDialog:getCurrentLedger()
    local mission = g_currentMission
    local runtime = mission ~= nil and mission.contractRatingRuntime or nil
    local farmId = mission ~= nil and mission:getFarmId() or nil
    if runtime == nil or farmId == nil or farmId <= 0
        or g_farmManager == nil or g_farmManager:getFarmById(farmId) == nil then
        return nil, nil
    end
    return runtime.ledger, farmId
end

-- Создаёт отфильтрованный список результатов в обратном порядке.
-- Содержимое истории не ограничено, страницы ограничивают только отрисовку.
function ContractRatingDialog:getRows(ledger, farmId)
    local rows = {}
    if self.section == 1 then
        for i = #ledger.transactions, 1, -1 do
            local entry = ledger.transactions[i]
            if entry.farmId == farmId
                and (self.filter == 1
                    or (self.filter == 2 and entry.delta > 0)
                    or (self.filter == 3 and entry.delta < 0)) then
                local typeName = entry.reason:match("^([^:]+):")
                local title = ContractRatingDialog.TYPE_TITLES[typeName]
                    or typeName or entry.reason
                rows[#rows + 1] = {
                    text = string.format("%d. %s   %+g   (%g → %g)",
                        i, title, entry.delta, entry.before, entry.after),
                    detail = string.format("Операция: %s   Попытка: %s",
                        entry.id, entry.attemptId)
                }
            end
        end
    else
        for typeName, required in pairs(ContractRatingAccess.thresholds or {}) do
            local title = ContractRatingDialog.TYPE_TITLES[typeName] or typeName
            local allowed = ledger:getRating(farmId) >= required
            rows[#rows + 1] = {
                text = string.format("%s: %d   [%s]",
                    title, required, allowed and "ДОСТУПНО" or "ЗАКРЫТО"),
                sortKey = required * 1000 .. typeName
            }
        end
        table.sort(rows, function(a, b)
            local aValue = tonumber(a.text:match(": (%-?%d+)")) or 0
            local bValue = tonumber(b.text:match(": (%-?%d+)")) or 0
            if aValue ~= bValue then return aValue < bValue end
            return a.text < b.text
        end)
    end
    return rows
end

-- Перерисовывает рейтинг, пороги или страницу истории для одной фермы.
function ContractRatingDialog:refresh()
    local ledger, farmId = self:getCurrentLedger()
    if ledger == nil then
        self.ratingText:setText("Рейтинг: недоступен")
        self.farmText:setText("Выберите ферму, чтобы увидеть её рейтинг.")
        self.headerText:setText("Нет доступных данных")
        self.summaryText:setText("")
        for index = 1, ContractRatingDialog.ROWS_PER_PAGE do
            self["entryText" .. index]:setText("")
        end
        self.pageOption:setTexts({"1/1"})
        self.pageOption:setState(1)
        self.pageOption:setDisabled(true)
        return
    end

    self.farmId = farmId
    local rating = ledger:getRating(farmId)
    local farm = g_farmManager:getFarmById(farmId)
    self.ratingText:setText(string.format("РЕЙТИНГ: %g", rating))
    self.farmText:setText(string.format("Ферма: %s (ID %d)",
        farm.name or tostring(farmId), farmId))
    self.filterOption:setVisible(self.section == 1)
    self.headerText:setText(self.section == 1
        and "ЗАВЕРШЁННЫЕ КОНТРАКТЫ, ИЗМЕНИВШИЕ РЕЙТИНГ"
        or "ПОРОГИ ДОСТУПА К КОНТРАКТАМ")

    local rows = self:getRows(ledger, farmId)
    local pages = math.max(1,
        math.ceil(#rows / ContractRatingDialog.ROWS_PER_PAGE))
    self.page = math.min(math.max(self.page, 1), pages)
    local pageLabels = {}
    for index = 1, pages do
        pageLabels[index] = string.format("%d/%d", index, pages)
    end
    self.pageOption:setTexts(pageLabels)
    self.pageOption:setState(self.page)
    self.pageOption:setDisabled(pages <= 1)

    for index = 1, ContractRatingDialog.ROWS_PER_PAGE do
        local entry = rows[(self.page - 1) * ContractRatingDialog.ROWS_PER_PAGE + index]
        self["entryText" .. index]:setText(entry ~= nil and entry.text or "")
    end

    if self.section == 1 then
        self.summaryText:setText(string.format(
            "Записей: %d. Показаны только рейтинговые результаты. Полная история попыток пока не ведётся.",
            #rows))
    else
        self.summaryText:setText("Проверка допуска к будущим рецептам будет выполняться сервером по рейтингу фермы.")
    end
end

-- Запрашивает свежий снимок при открытии и показывает данные текущей фермы.
function ContractRatingDialog:onOpen()
    ContractRatingDialog:superClass().onOpen(self)
    self.section = 1
    self.filter = 1
    self.page = 1
    self.sectionOption:setTexts({"История рейтинга", "Пороги контрактов"})
    self.sectionOption:setState(1)
    self.filterOption:setTexts({"Все результаты", "Начисления", "Штрафы"})
    self.filterOption:setState(1)
    if g_currentMission ~= nil and not g_currentMission:getIsServer() then
        ContractRatingSyncRequestEvent.sendEvent()
    end
    self:refresh()
end

-- Периодически обновляет открытое окно после серверной синхронизации.
function ContractRatingDialog:update(dt)
    ContractRatingDialog:superClass().update(self, dt)
    if self.isOpen then
        self.refreshTimer = self.refreshTimer + dt
        if self.refreshTimer >= 800 then
            self.refreshTimer = 0
            self:refresh()
        end
    end
end

-- Переключает историю и список порогов без потери рейтинга фермы.
function ContractRatingDialog:onClickSection(state)
    self.section = state
    self.page = 1
    self:refresh()
end

-- Отбирает рейтинговые результаты по знаку изменения.
function ContractRatingDialog:onClickFilter(state)
    self.filter = state
    self.page = 1
    self:refresh()
end

-- Выводит выбранную страницу журнала.
function ContractRatingDialog:onClickPage(state)
    self.page = state
    self:refresh()
end

-- Освобождает состояние окна при закрытии, не затрагивая журнал.
function ContractRatingDialog:onClose()
    self.farmId = nil
    self.refreshTimer = 0
    ContractRatingDialog:superClass().onClose(self)
end

-- Показывает диалог из меню контрактов.
function ContractRatingDialog.show()
    if not ContractRatingDialog.register() then
        Logging.warning("[ContractRating] Не удалось открыть окно рейтинга")
        return
    end
    g_gui:showDialog(ContractRatingDialog.GUI_NAME)
end

-- Добавляет отдельную кнопку без изменения штатной обработки контрактов.
function ContractRatingDialog.appendContractsButton(frame)
    if frame.menuButtonInfo == nil then return end
    if frame.taigaRatingButton == nil then
        frame.taigaRatingButton = {
            inputAction = InputAction.MENU_EXTRA_1,
            text = "Рейтинг и история",
            callback = ContractRatingDialog.show
        }
    end
    table.insert(frame.menuButtonInfo, frame.taigaRatingButton)
    frame:setMenuButtonInfoDirty()
end

-- Подключает кнопку к обновлению состояния меню, включая пустой список миссий.
function ContractRatingDialog.install(baseDirectory)
    ContractRatingDialog.baseDirectory = baseDirectory
    if ContractRatingDialog.installed
        or InGameMenuContractsFrame == nil
        or InGameMenuContractsFrame.setButtonsForState == nil then return false end

    InGameMenuContractsFrame.setButtonsForState = Utils.appendedFunction(
        InGameMenuContractsFrame.setButtonsForState,
        ContractRatingDialog.appendContractsButton)
    ContractRatingDialog.installed = true
    Logging.info("[ContractRating] Кнопка рейтинга установлена в меню контрактов")
    return true
end

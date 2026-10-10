-- Диалог ручного переноса: шесть видимых строк с постраничным просмотром.
-- Каждая строка имеет собственную кнопку или статус «Не помещается».
TransferFromStorageDialog = {}
local TransferFromStorageDialog_mt = Class(TransferFromStorageDialog, DialogElement)
TransferFromStorageDialog.NAME = "TransferFromStorageDialog"
TransferFromStorageDialog.XML = "gui/TransferFromStorageDialog.xml"
TransferFromStorageDialog.INSTANCE = nil
TransferFromStorageDialog.baseDirectory = g_currentModDirectory
TransferFromStorageDialog.PAGE_SIZE = 6

-- Создаёт контроллер интерфейса.
function TransferFromStorageDialog.new(target, customMt)
    local self = DialogElement.new(target, customMt or TransferFromStorageDialog_mt)
    self.placeable = nil
    self.rows = {}
    self.page = 1
    self.pending = false
    self.refreshTimer = 0
    return self
end

-- Однократно подключает XML интерфейса на клиенте.
function TransferFromStorageDialog.register()
    if TransferFromStorageDialog.INSTANCE ~= nil then return true end
    if g_gui == nil or TransferFromStorageDialog.baseDirectory == nil then
        Logging.warning("[TransferFromStorage] GUI directory unavailable")
        return false
    end
    local dialog = TransferFromStorageDialog.new()
    g_gui:loadGui(
        Utils.getFilename(TransferFromStorageDialog.XML, TransferFromStorageDialog.baseDirectory),
        TransferFromStorageDialog.NAME, dialog
    )
    TransferFromStorageDialog.INSTANCE = dialog
    return true
end

-- Открывает меню именно для постройки, в триггере которой стоит игрок.
function TransferFromStorageDialog.show(placeable)
    if placeable == nil or not TransferFromStorageDialog.register() then return end
    local dialog = TransferFromStorageDialog.INSTANCE
    dialog.placeable = placeable
    dialog.rows = {}
    dialog.page = 1
    dialog.pending = false
    dialog.refreshTimer = 0
    g_gui:showDialog(TransferFromStorageDialog.NAME)
    dialog:refresh()
end

-- Перечитывает синхронизированные группы и отображает строки текущей страницы.
function TransferFromStorageDialog:refresh()
    if self.placeable == nil then return end
    self.placeable:updateDirtyObjectStorageObjectInfos()
    self.rows = self.placeable:transferFromStorageGetEntries()
    local maxPage = math.max(1, math.ceil(#self.rows / TransferFromStorageDialog.PAGE_SIZE))
    self.page = math.min(self.page, maxPage)
    self.pageText:setText(string.format("Страница %d / %d", self.page, maxPage))
    for i = 1, TransferFromStorageDialog.PAGE_SIZE do
        local row = self.rows[(self.page - 1) * TransferFromStorageDialog.PAGE_SIZE + i]
        local label = self["rowLabel" .. i]
        local button = self["rowButton" .. i]
        local status = self["rowStatus" .. i]
        if row == nil then
            label:setVisible(false)
            button:setVisible(false)
            status:setVisible(false)
        else
            label:setVisible(true)
            label:setText(row.title)
            button:setVisible(row.fits)
            status:setVisible(not row.fits)
            if row.fits then
                button:setText(row.actionText)
                button:setDisabled(self.pending)
            else
                status:setText("Не помещается")
            end
        end
    end
    self.prevButton:setDisabled(self.page <= 1 or self.pending)
    self.nextButton:setDisabled(self.page >= maxPage or self.pending)
    if #self.rows == 0 then
        self.messageText:setText("На складе нет подходящих тюков или поддонов.")
    end
end

-- Отправляет одну выбранную строку на сервер без доверия клиентским запасам.
function TransferFromStorageDialog:requestTransfer(index)
    if self.pending or self.placeable == nil then return end
    local row = self.rows[(self.page - 1) * TransferFromStorageDialog.PAGE_SIZE + index]
    if row == nil or not row.fits then return end
    self.pending = true
    self.messageText:setText("Передача...")
    self:refresh()
    if not TransferFromStorageEvent.sendRequest(
        self.placeable, row.isBale, row.fillType, row.amount
    ) then
        self.pending = false
        self.messageText:setText("Нет соединения с сервером.")
        self:refresh()
    end
end

-- Передаёт материал из строки 1 текущей страницы.
function TransferFromStorageDialog:onClickTransfer1()
    self:requestTransfer(1)
end

-- Передаёт материал из строки 2 текущей страницы.
function TransferFromStorageDialog:onClickTransfer2()
    self:requestTransfer(2)
end

-- Передаёт материал из строки 3 текущей страницы.
function TransferFromStorageDialog:onClickTransfer3()
    self:requestTransfer(3)
end

-- Передаёт материал из строки 4 текущей страницы.
function TransferFromStorageDialog:onClickTransfer4()
    self:requestTransfer(4)
end

-- Передаёт материал из строки 5 текущей страницы.
function TransferFromStorageDialog:onClickTransfer5()
    self:requestTransfer(5)
end

-- Передаёт материал из строки 6 текущей страницы.
function TransferFromStorageDialog:onClickTransfer6()
    self:requestTransfer(6)
end

-- Показывает предыдущую страницу.
function TransferFromStorageDialog:onClickPrev()
    self.page = math.max(1, self.page - 1)
    self:refresh()
end

-- Показывает следующую страницу.
function TransferFromStorageDialog:onClickNext()
    self.page = self.page + 1
    self:refresh()
end

-- Закрывает диалог штатным способом.
function TransferFromStorageDialog:onClickBack()
    g_gui:closeDialogByName(TransferFromStorageDialog.NAME)
end

-- Получает адресный ответ на сетевой запрос.
function TransferFromStorageDialog.onTransferResult(placeable, success, message)
    local dialog = TransferFromStorageDialog.INSTANCE
    if dialog == nil or dialog.placeable ~= placeable then return end
    dialog.pending = false
    dialog.messageText:setText(message or "")
    -- На клиенте ObjectStorage обновляется через штатный dirtyFlag с
    -- задержкой. Не показываем старые количества как окончательные.
    dialog.refreshTimer = success and 1400 or 100
    dialog:refresh()
end

-- Обновляет список после того, как пришёл штатный сетевой снимок склада.
function TransferFromStorageDialog:onUpdate(dt)
    if self.refreshTimer > 0 then
        self.refreshTimer = self.refreshTimer - dt
        if self.refreshTimer <= 0 then
            self:refresh()
        end
    end
end

-- Сбрасывает ссылки на постройку, когда игрок закрыл окно.
function TransferFromStorageDialog:onClose()
    self.placeable = nil
    self.rows = {}
    self.pending = false
    self.refreshTimer = 0
    TransferFromStorageDialog:superClass().onClose(self)
end

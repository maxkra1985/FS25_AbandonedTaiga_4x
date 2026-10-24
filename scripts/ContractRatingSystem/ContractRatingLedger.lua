--[[
    ContractRatingLedger
    Серверный журнал рейтинга ферм: начисления, штрафы и полная история операций.
    Модуль пока не подключается к карте: сначала необходимо проверить его
    сохранение и загрузку, затем добавить сетевую синхронизацию и lifecycle.
]]

ContractRatingLedger = {}
ContractRatingLedger.__index = ContractRatingLedger
ContractRatingLedger.VERSION = 1
ContractRatingLedger.FILENAME = "contractRatingLedger.xml"

-- Создаёт пустое состояние рейтинга без привязки к конкретной игровой миссии.
function ContractRatingLedger.new()
    return setmetatable({
        ratings = {},
        transactions = {},
        transactionIds = {}
    }, ContractRatingLedger)
end

-- Возвращает рейтинг фермы; отсутствие записи означает начальное значение 0.
function ContractRatingLedger:getRating(farmId)
    return self.ratings[farmId] or 0
end

-- Регистрирует изменение рейтинга строго один раз по постоянному ID операции.
-- Отрицательные рейтинги разрешены. Повтор операции ничего не изменяет.
function ContractRatingLedger:apply(transactionId, farmId, attemptId, delta, reason)
    if type(transactionId) ~= "string" or transactionId == ""
        or type(farmId) ~= "number" or farmId < 0 or farmId % 1 ~= 0
        or type(delta) ~= "number" or delta ~= delta
        or delta == math.huge or delta == -math.huge
        or type(attemptId) ~= "string" or attemptId == ""
        or type(reason) ~= "string" or reason == "" then
        return false, "invalidArguments"
    end

    if self.transactionIds[transactionId] then
        return false, "duplicateTransaction"
    end

    local before = self:getRating(farmId)
    local entry = {
        id = transactionId,
        farmId = farmId,
        attemptId = attemptId,
        delta = delta,
        reason = reason,
        before = before,
        after = before + delta
    }

    table.insert(self.transactions, entry)
    self.transactionIds[transactionId] = true
    self.ratings[farmId] = entry.after

    return true, entry
end

-- Возвращает всю историю в порядке применения; записи не удаляются автоматически.
function ContractRatingLedger:getTransactions()
    return self.transactions
end

-- Записывает журнал в отдельный XML файл сохранения.
-- Вызывающий код отвечает за вызов только на сервере и корректный путь savegame.
function ContractRatingLedger:save(directory)
    if type(directory) ~= "string" or directory == "" then
        return false
    end

    local filename = directory .. "/" .. self.FILENAME
    local xml = createXMLFile("contractRatingLedgerSave", filename, "contractRatingLedger")
    if xml == nil or xml == 0 then
        Logging.warning("[ContractRatingLedger] Cannot create '%s'", filename)
        return false
    end

    setXMLInt(xml, "contractRatingLedger#version", self.VERSION)
    setXMLInt(xml, "contractRatingLedger#count", #self.transactions)
    for i, entry in ipairs(self.transactions) do
        local key = string.format("contractRatingLedger.transaction(%d)", i - 1)
        setXMLString(xml, key .. "#id", entry.id)
        setXMLInt(xml, key .. "#farmId", entry.farmId)
        setXMLString(xml, key .. "#attemptId", entry.attemptId)
        setXMLFloat(xml, key .. "#delta", entry.delta)
        setXMLString(xml, key .. "#reason", entry.reason)
        setXMLFloat(xml, key .. "#before", entry.before)
        setXMLFloat(xml, key .. "#after", entry.after)
    end
    saveXMLFile(xml)
    delete(xml)
    return true
end

-- Загружает журнал в промежуточное состояние и пересчитывает рейтинг операциями.
-- Некорректная последовательность или версия не заменяет работающее состояние.
function ContractRatingLedger:load(directory)
    if type(directory) ~= "string" or directory == "" then
        return false, "invalidDirectory"
    end

    local filename = directory .. "/" .. self.FILENAME
    if not fileExists(filename) then
        return false, "fileMissing"
    end

    local xml = loadXMLFile("contractRatingLedgerLoad", filename)
    if xml == nil or xml == 0 then
        return false, "cannotOpen"
    end

    if getXMLInt(xml, "contractRatingLedger#version") ~= self.VERSION then
        delete(xml)
        return false, "unsupportedVersion"
    end

    local loaded = ContractRatingLedger.new()
    local count = getXMLInt(xml, "contractRatingLedger#count")
    if count == nil or count < 0 then
        delete(xml)
        return false, "invalidCount"
    end

    for i = 0, count - 1 do
        local key = string.format("contractRatingLedger.transaction(%d)", i)
        local id = getXMLString(xml, key .. "#id")
        local farmId = getXMLInt(xml, key .. "#farmId")
        local attemptId = getXMLString(xml, key .. "#attemptId")
        local delta = getXMLFloat(xml, key .. "#delta")
        local reason = getXMLString(xml, key .. "#reason")
        local before = getXMLFloat(xml, key .. "#before")
        local after = getXMLFloat(xml, key .. "#after")
        if farmId == nil or before == nil or after == nil
            or loaded:getRating(farmId) ~= before
            or delta == nil or before + delta ~= after then
            delete(xml)
            return false, "invalidTransactionSequence"
        end

        local ok = loaded:apply(id, farmId, attemptId, delta, reason)
        if not ok then
            delete(xml)
            return false, "invalidTransaction"
        end
    end

    delete(xml)
    self.ratings = loaded.ratings
    self.transactions = loaded.transactions
    self.transactionIds = loaded.transactionIds
    return true
end

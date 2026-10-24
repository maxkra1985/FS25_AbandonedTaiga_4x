--[[
    ContractDetailsLayout
    Адаптивная компоновка деталей контракта для стандартного интерфейса
    и профилей BetterContracts. Координаты измеряются после штатной отрисовки.
]]
ContractDetailsLayout = {}
ContractDetailsLayout.installed = false

-- Запоминает исходные размеры активного GUI. Профиль BetterContracts
-- применяется позднее загрузки скриптов, поэтому захват выполняется при показе.
function ContractDetailsLayout.capture(frame)
    local desc = frame.contractDescriptionText
    local list = frame.detailsList
    if desc == nil or list == nil then return nil end
    local state = frame.taigaDetailsLayout
    if state == nil then
        state = {
            descriptionY = desc.position[2],
            descriptionHeight = desc.size[2],
            descriptionMaxLines = desc.textMaxNumLines,
            listY = list.position[2],
            listHeight = list.size[2],
            listProfile = list.profileName
        }
        frame.taigaDetailsLayout = state
    end
    return state
end

-- Возвращает стандартную геометрию перед расчётом следующего контракта.
function ContractDetailsLayout.reset(frame, state)
    local desc = frame.contractDescriptionText
    local list = frame.detailsList
    desc:setPosition(nil, state.descriptionY)
    desc:setSize(nil, state.descriptionHeight)
    list:setPosition(nil, state.listY)
    list:setSize(nil, state.listHeight)
end

-- Измеряет фактический текст и освобождает для него место над таблицей.
-- Сокращение высоты списка сохраняет его нижнюю границу и область награды.
function ContractDetailsLayout.update(frame)
    local state = ContractDetailsLayout.capture(frame)
    if state == nil then return end
    local desc = frame.contractDescriptionText
    local list = frame.detailsList
    ContractDetailsLayout.reset(frame, state)

    local textHeight, lines = desc:getTextHeight(true)
    if textHeight == nil or lines == nil or lines <= 0 then return end

    local descTop = desc.absPosition[2] + desc.absSize[2]
    local listTop = list.absPosition[2] + list.absSize[2]
    -- Рассчитываем требуемый отступ непосредственно в нормализованных
    -- координатах GUI, а не из предполагаемых размеров XML в пикселях.
    local gap = 12 * g_pixelSizeY
    local wantedTop = descTop - textHeight - gap
    local overlap = math.max(0, listTop - wantedTop)
    local minHeight = math.min(state.listHeight, 64 * g_pixelSizeY)
    local shift = math.min(overlap, math.max(0, state.listHeight - minHeight))

    -- Текстовый элемент увеличиваем вниз от исходного верхнего края.
    local newDescHeight = math.max(state.descriptionHeight, textHeight)
    local extra = newDescHeight - state.descriptionHeight
    if extra > 0 then
        desc:setSize(nil, newDescHeight)
        desc:setPosition(nil, state.descriptionY - extra)
    end

    -- Таблица имеет нижнюю привязку; уменьшение высоты опускает верхнюю
    -- границу, не двигая нижний блок с суммой вознаграждения.
    list:setSize(nil, state.listHeight - shift)

    if frame.taigaDetailsLayoutReported ~= true then
        Logging.info("[ContractRating] Contracts layout: lines=%d, textHeight=%.4f, overlap=%.4f, shift=%.4f, listHeight=%.4f",
            lines, textHeight, overlap, shift, list.size[2])
        frame.taigaDetailsLayoutReported = true
    end
end

-- Перехватывает карточку до setText для отключения короткого лимита строк.
function ContractDetailsLayout.updateDetailContents(frame, superFunc, section, index)
    local state = ContractDetailsLayout.capture(frame)
    if state ~= nil then
        ContractDetailsLayout.reset(frame, state)
        frame.contractDescriptionText.textMaxNumLines = 20
    end
    superFunc(frame, section, index)
    if not frame.taigaLayoutHookCalled then
        frame.taigaLayoutHookCalled = true
        Logging.info("[ContractRating] Contracts layout callback reached (post-updateDetailContents)")
    end
    ContractDetailsLayout.update(frame)
end

-- Устанавливает обработчик однократно, без модификации файлов BetterContracts.
function ContractDetailsLayout.install()
    if ContractDetailsLayout.installed or InGameMenuContractsFrame == nil
        or InGameMenuContractsFrame.updateDetailContents == nil then
        return false
    end
    InGameMenuContractsFrame.updateDetailContents = Utils.overwrittenFunction(
        InGameMenuContractsFrame.updateDetailContents,
        ContractDetailsLayout.updateDetailContents)
    ContractDetailsLayout.installed = true
    Logging.info("[ContractRating] Adaptive contract details layout installed (absolute geometry)")
    return true
end

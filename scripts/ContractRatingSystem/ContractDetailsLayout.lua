--[[
    ContractDetailsLayout
    Адаптирует штатную карточку контрактов к длине описания.
    Описание расширяется по фактической высоте текста, таблица смещается,
    а при недостатке места остаётся прокручиваемой.
]]
ContractDetailsLayout = {}
ContractDetailsLayout.installed = false

-- Сохраняет исходную геометрию штатных элементов отдельно для каждой карточки.
function ContractDetailsLayout.capture(frame)
    if frame.taigaDetailsLayout ~= nil then
        return frame.taigaDetailsLayout
    end
    local description = frame.contractDescriptionText
    local list = frame.detailsList
    if description == nil or list == nil then return nil end
    local state = {
        descriptionHeight = description.size[2],
        descriptionMaxLines = description.textMaxNumLines,
        listY = list.position[2],
        listHeight = list.size[2]
    }
    frame.taigaDetailsLayout = state
    return state
end

-- Пересчитывает положение таблицы после обновления штатной карточки.
function ContractDetailsLayout.update(frame)
    local state = ContractDetailsLayout.capture(frame)
    if state == nil then return end
    local description = frame.contractDescriptionText
    local list = frame.detailsList

    -- Сначала возвращаем штатную геометрию, иначе возникает накопление сдвига.
    description:setSize(nil, state.descriptionHeight)
    description.textMaxNumLines = math.max(12, state.descriptionMaxLines or 4)
    list:setPosition(nil, state.listY)
    list:setSize(nil, state.listHeight)

    local height, lines = description:getTextHeight(true)
    if height == nil or lines == nil or lines <= 0 then return end

    -- Оставляем для таблицы не менее двух строк высотой по 32 пикселя.
    -- Пропорции взяты из штатного InGameMenuContractsFrame.xml:
    -- detailsList = 216px, строка = 32px.
    local minListHeight = state.listHeight * (64 / 216)
    local shift = math.min(math.max(0, height - state.descriptionHeight),
        state.listHeight - minListHeight)
    description:setSize(nil, state.descriptionHeight + shift)
    list:setPosition(nil, state.listY - shift)
    list:setSize(nil, state.listHeight - shift)

    -- Если описание длиннее доступной области, ограничиваем число строк;
    -- прокручиваемая таблица и нижняя сумма не должны перекрываться.
    local lineHeight = height / lines
    if lineHeight > 0 then
        local maxLines = math.max(1,
            math.floor((state.descriptionHeight + shift) / lineHeight))
        description.textMaxNumLines = math.min(description.textMaxNumLines, maxLines)
    end
end

-- Устанавливает обработчик ровно один раз, не меняя штатные XML и Lua.
function ContractDetailsLayout.install()
    if ContractDetailsLayout.installed or InGameMenuContractsFrame == nil
        or InGameMenuContractsFrame.updateDetailContents == nil then return false end
    InGameMenuContractsFrame.updateDetailContents = Utils.appendedFunction(
        InGameMenuContractsFrame.updateDetailContents, ContractDetailsLayout.update)
    ContractDetailsLayout.installed = true
    return true
end

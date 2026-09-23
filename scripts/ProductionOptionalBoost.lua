--[[
    ProductionOptionalBoost.lua

    Universal optional production catalysts for FS25 ProductionPoint.

    XML syntax (inside an ordinary production inputs block):

        <inputs>
            <input fillType="WATER" amount="10"/>
            <inputBoost fillType="CUTTING_TOOL" amountPerCycle="1" bonus="0.10"/>
            <inputBoost fillType="WATER" amountPerCycle="5" bonus="0.05"
                        outputFillTypes="BEEF PORK"/>
        </inputs>

    Rules:
      * inputBoost is NEVER a mandatory ProductionPoint input.
      * Missing inputBoost never causes MISSING_INPUTS.
      * Boosts stack additively.
      * Partial availability gives a proportional bonus.
      * outputFillTypes is optional. If omitted, the boost affects every output.
      * If a booster uses the same fillType as a mandatory input, only the surplus
        above the mandatory reserve of all active recipes may be consumed.
]]

ProductionOptionalBoost = ProductionOptionalBoost or {}

ProductionOptionalBoost.VERSION = "0.1.4.0"
ProductionOptionalBoost.DEBUG = false
ProductionOptionalBoost.EPSILON = 0.000001
ProductionOptionalBoost.DATA_KEY = "optionalInputBoosts"

local LOG_PREFIX = "[ProductionOptionalBoost]"

local function debugLog(formatString, ...)
    if ProductionOptionalBoost.DEBUG then
        Logging.info(LOG_PREFIX .. " " .. formatString, ...)
    end
end

local function splitFillTypeNames(value)
    local result = {}
    if value == nil then
        return result
    end

    for name in string.gmatch(value, "%S+") do
        table.insert(result, name)
    end

    return result
end

local function getFillTypeName(fillTypeIndex)
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    return fillType ~= nil and fillType.name or tostring(fillTypeIndex)
end

local function boostAffectsOutput(boost, outputType)
    return boost.outputFillTypes == nil or boost.outputFillTypes[outputType] == true
end

local function getProductionBoosts(production)
    return production ~= nil and production[ProductionOptionalBoost.DATA_KEY] or nil
end

local function productionHasBoosts(production)
    local boosts = getProductionBoosts(production)
    return boosts ~= nil and #boosts > 0
end

local function productionPointHasActiveBoosts(productionPoint)
    for _, production in ipairs(productionPoint.activeProductions or {}) do
        if productionHasBoosts(production) then
            return true
        end
    end

    return false
end

local function registerXMLPaths(schema, basePath)
    local boostPath = basePath .. ".productions.production(?).inputs.inputBoost(?)"
    schema:register(XMLValueType.STRING, boostPath .. "#fillType", "Optional boost fillType", nil, true)
    schema:register(XMLValueType.FLOAT, boostPath .. "#amountPerCycle", "Optional boost amount consumed per boosted production cycle", 1)
    schema:register(XMLValueType.FLOAT, boostPath .. "#bonus", "Additive output bonus (0.10 = +10 percent)", 0)
    schema:register(XMLValueType.STRING, boostPath .. "#outputFillTypes", "Optional whitespace separated output fillTypes affected by this boost")
end

local function loadBoosts(productionPoint, xmlFile, key)
    local totalBoostCount = 0

    for _, production in ipairs(productionPoint.productions or {}) do
        production[ProductionOptionalBoost.DATA_KEY] = nil
    end

    xmlFile:iterate(key .. ".productions.production", function(_, productionKey)
        local productionId = xmlFile:getValue(productionKey .. "#id")
        local production = productionId ~= nil and productionPoint.productionsIdToObj[productionId] or nil
        if production == nil then
            return
        end

        local boosts = {}

        xmlFile:iterate(productionKey .. ".inputs.inputBoost", function(_, boostKey)
            local fillTypeName = xmlFile:getValue(boostKey .. "#fillType")
            local amountPerCycle = math.max(xmlFile:getValue(boostKey .. "#amountPerCycle", 1), 0)
            local bonus = math.max(xmlFile:getValue(boostKey .. "#bonus", 0), 0)
            local fillTypeIndex = fillTypeName ~= nil and g_fillTypeManager:getFillTypeIndexByName(fillTypeName) or nil

            if fillTypeIndex == nil or fillTypeIndex == FillType.UNKNOWN then
                Logging.xmlWarning(
                    xmlFile,
                    "%s Production '%s' uses unknown inputBoost fillType '%s'; boost ignored.",
                    LOG_PREFIX,
                    tostring(productionId),
                    tostring(fillTypeName)
                )
                return
            end

            if amountPerCycle <= ProductionOptionalBoost.EPSILON or bonus <= ProductionOptionalBoost.EPSILON then
                Logging.xmlWarning(
                    xmlFile,
                    "%s Production '%s' has invalid inputBoost for '%s' (amountPerCycle=%.6f bonus=%.6f); boost ignored.",
                    LOG_PREFIX,
                    tostring(productionId),
                    tostring(fillTypeName),
                    amountPerCycle,
                    bonus
                )
                return
            end

            if productionPoint.storage == nil or not productionPoint.storage:getIsFillTypeSupported(fillTypeIndex) then
                Logging.xmlWarning(
                    xmlFile,
                    "%s Production '%s': storage does not support inputBoost '%s'; boost ignored.",
                    LOG_PREFIX,
                    tostring(productionId),
                    tostring(fillTypeName)
                )
                return
            end

            local outputFillTypes = nil
            local outputFillTypeNames = xmlFile:getValue(boostKey .. "#outputFillTypes")
            if outputFillTypeNames ~= nil and not string.isNilOrWhitespace(outputFillTypeNames) then
                outputFillTypes = {}
                local validOutputCount = 0

                for _, outputName in ipairs(splitFillTypeNames(outputFillTypeNames)) do
                    local outputIndex = g_fillTypeManager:getFillTypeIndexByName(outputName)
                    if outputIndex == nil or outputIndex == FillType.UNKNOWN then
                        Logging.xmlWarning(
                            xmlFile,
                            "%s Production '%s': unknown outputFillType '%s' in inputBoost '%s'.",
                            LOG_PREFIX,
                            tostring(productionId),
                            tostring(outputName),
                            tostring(fillTypeName)
                        )
                    else
                        outputFillTypes[outputIndex] = true
                        validOutputCount = validOutputCount + 1
                    end
                end

                if validOutputCount == 0 then
                    Logging.xmlWarning(
                        xmlFile,
                        "%s Production '%s': inputBoost '%s' has no valid outputFillTypes; boost ignored.",
                        LOG_PREFIX,
                        tostring(productionId),
                        tostring(fillTypeName)
                    )
                    return
                end
            end

            local boost = {
                type = fillTypeIndex,
                fillTypeName = fillTypeName,
                amountPerCycle = amountPerCycle,
                bonus = bonus,
                outputFillTypes = outputFillTypes
            }

            table.insert(boosts, boost)
            totalBoostCount = totalBoostCount + 1

            -- Make the optional resource visible to ProductionPoint input/storage
            -- consumers without ever inserting it into production.inputs.
            productionPoint.inputFillTypeIds[fillTypeIndex] = true
            table.addElement(productionPoint.inputFillTypeIdsArray, fillTypeIndex)

            debugLog(
                "loaded production=%s boost=%s amount/cycle=%.3f bonus=+%.1f%% outputs=%s",
                tostring(productionId),
                tostring(fillTypeName),
                amountPerCycle,
                bonus * 100,
                outputFillTypeNames or "ALL"
            )
        end)

        if #boosts > 0 then
            production[ProductionOptionalBoost.DATA_KEY] = boosts
        end
    end)

    if totalBoostCount > 0 then
        debugLog("ProductionPoint '%s': loaded %d optional boost(s)", tostring(productionPoint:getName()), totalBoostCount)
    end
end

-- Reserve the mandatory internal-storage consumption of every active recipe for
-- this update. Optional boosts may consume only the amount above this reserve.
local function buildMandatoryReserve(productionPoint, activeCount, cyclesTimescaledFactor)
    local reserve = {}

    local throughputDivisor = productionPoint.sharedThroughputCapacity and math.max(activeCount, 1) or 1

    for _, production in ipairs(productionPoint.activeProductions or {}) do
        local cyclesTimescaled = production.cyclesPerMinute * cyclesTimescaledFactor
        local actualCycles = cyclesTimescaled / throughputDivisor

        for _, input in ipairs(production.inputs or {}) do
            reserve[input.type] = (reserve[input.type] or 0) + input.amount * actualCycles
        end
    end

    return reserve
end

local function releaseMandatoryReserve(reserve, production, actualCycles)
    if reserve == nil then
        return
    end

    for _, input in ipairs(production.inputs or {}) do
        local oldValue = reserve[input.type] or 0
        reserve[input.type] = math.max(oldValue - input.amount * actualCycles, 0)
    end
end

local function calculateBoostUsage(productionPoint, production, actualCycles, mandatoryReserve)
    local result = {}
    local allocatedByFillType = {}
    local boosts = getProductionBoosts(production)

    if boosts == nil or actualCycles <= ProductionOptionalBoost.EPSILON then
        return result
    end

    for _, boost in ipairs(boosts) do
        local availableLevel = productionPoint:getFillLevel(boost.type) or 0
        local reservedMandatory = mandatoryReserve[boost.type] or 0
        local alreadyAllocated = allocatedByFillType[boost.type] or 0
        local availableForBoost = math.max(availableLevel - reservedMandatory - alreadyAllocated, 0)
        local boostedCycles = math.min(actualCycles, availableForBoost / boost.amountPerCycle)
        local amountToConsume = boostedCycles * boost.amountPerCycle

        allocatedByFillType[boost.type] = alreadyAllocated + amountToConsume

        table.insert(result, {
            boost = boost,
            boostedCycles = boostedCycles,
            amountToConsume = amountToConsume
        })
    end

    return result
end

local function calculateProducedAmount(output, actualCycles, boostUsage)
    local effectiveCycles = actualCycles

    for _, usage in ipairs(boostUsage or {}) do
        if usage.boostedCycles > ProductionOptionalBoost.EPSILON
            and boostAffectsOutput(usage.boost, output.type) then
            effectiveCycles = effectiveCycles + usage.boostedCycles * usage.boost.bonus
        end
    end

    return output.amount * effectiveCycles
end

local function consumeBoosts(productionPoint, production, boostUsage)
    for _, usage in ipairs(boostUsage or {}) do
        if usage.amountToConsume > ProductionOptionalBoost.EPSILON then
            local fillTypeIndex = usage.boost.type
            local currentLevel = productionPoint:getFillLevel(fillTypeIndex) or 0

            if productionPoint.loadingStation == nil then
                local newLevel = math.max(currentLevel - usage.amountToConsume, 0)
                productionPoint.storage:setFillLevel(newLevel, fillTypeIndex)

                debugLog(
                    "consume production=%s boost=%s amount=%.3f boostedCycles=%.4f storage=%.3f->%.3f",
                    tostring(production.id),
                    getFillTypeName(fillTypeIndex),
                    usage.amountToConsume,
                    usage.boostedCycles,
                    currentLevel,
                    newLevel
                )
            else
                productionPoint.loadingStation:removeFillLevel(
                    fillTypeIndex,
                    usage.amountToConsume,
                    productionPoint.ownerFarmId
                )

                debugLog(
                    "consume production=%s boost=%s amount=%.3f boostedCycles=%.4f loadingStationLevel=%.3f",
                    tostring(production.id),
                    getFillTypeName(fillTypeIndex),
                    usage.amountToConsume,
                    usage.boostedCycles,
                    currentLevel
                )
            end
        end
    end
end

local function spawnStockPalletIfPossible(productionPoint)
    if productionPoint.isServer
        and productionPoint.isOwned
        and g_time > productionPoint.palletSpawnCooldown
        and not productionPoint.waitingForPalletToSpawn then

        local nextFillTypeId = nil

        while true do
            local fillTypeId = productionPoint.lastPalletFillTypeId

            if fillTypeId ~= nil
                and productionPoint.outputFillTypeIdsDirectSell[fillTypeId] == nil
                and productionPoint.outputFillTypeIdsAutoDeliver[fillTypeId] == nil then

                local fillLevel = productionPoint.storage:getFillLevel(fillTypeId)
                if fillLevel > 0 then
                    local pallet = productionPoint.outputFillTypeIdsToPallets[fillTypeId]
                    if pallet and pallet.capacity <= fillLevel then
                        nextFillTypeId = fillTypeId
                        break
                    end
                end
            end

            productionPoint.lastPalletFillTypeId = next(
                productionPoint.outputFillTypeIdsToPallets,
                productionPoint.lastPalletFillTypeId
            )

            if productionPoint.lastPalletFillTypeId == nil then
                break
            end
        end

        if nextFillTypeId ~= nil then
            productionPoint.waitingForPalletToSpawn = true
            productionPoint.palletSpawner:spawnPallet(
                productionPoint:getOwnerFarmId(),
                nextFillTypeId,
                productionPoint.palletSpawnRequestCallback,
                productionPoint
            )
        end
    end
end

function ProductionOptionalBoost.productionPointLoad(productionPoint, superFunc, components, xmlFile, key, customEnv, i3dMappings)
    local result = superFunc(productionPoint, components, xmlFile, key, customEnv, i3dMappings)

    if result then
        loadBoosts(productionPoint, xmlFile, key)
    end

    return result
end

function ProductionOptionalBoost.productionPointUpdateProduction(productionPoint, superFunc)
    if not productionPointHasActiveBoosts(productionPoint) then
        return superFunc(productionPoint)
    end

    if productionPoint.lastUpdatedTime == nil then
        productionPoint.lastUpdatedTime = g_time
        return
    end

    local dt = g_time - productionPoint.lastUpdatedTime
    local clampedDt = math.clamp(dt, 0, 30000)
    local timeAdjustment = g_currentMission.environment.timeAdjustment
    local activeCount = #productionPoint.activeProductions

    if activeCount > 0 then
        local minuteFactorTimescaledDt = clampedDt * productionPoint.minuteFactorTimescaled * timeAdjustment
        local minuteFactorDt = clampedDt / 60000 * timeAdjustment
        local throughputDivisor = productionPoint.sharedThroughputCapacity and activeCount or 1
        local mandatoryReserve = buildMandatoryReserve(productionPoint, activeCount, minuteFactorTimescaledDt)

        for i = 1, activeCount do
            local production = productionPoint.activeProductions[i]
            local cyclesTimescaled = production.cyclesPerMinute * minuteFactorTimescaledDt
            local cyclesNoTimescale = production.cyclesPerMinute * minuteFactorDt
            local actualCycles = cyclesTimescaled / throughputDivisor
            local enoughInputResources = true
            local enoughOutputSpace = true

            for x = 1, #production.inputs do
                local input = production.inputs[x]
                local fillLevel = productionPoint:getFillLevel(input.type)
                productionPoint.inputFillLevels[input] = fillLevel

                if productionPoint.isOwned and fillLevel < input.amount * cyclesNoTimescale then
                    enoughInputResources = false

                    if production.status ~= ProductionPoint.PROD_STATUS.MISSING_INPUTS then
                        production.status = ProductionPoint.PROD_STATUS.MISSING_INPUTS
                        productionPoint.owningPlaceable:productionStatusChanged(
                            production,
                            ProductionPoint.PROD_STATUS.MISSING_INPUTS
                        )
                        productionPoint:setProductionStatus(production.id, production.status)
                    end
                    break
                end
            end

            local boostUsage = {}
            if enoughInputResources and productionPoint.isOwned then
                boostUsage = calculateBoostUsage(productionPoint, production, actualCycles, mandatoryReserve)

                for x = 1, #production.outputs do
                    local output = production.outputs[x]
                    local producedAmount = calculateProducedAmount(output, actualCycles, boostUsage)

                    -- Preserve the stock game's conservative base-capacity check:
                    -- vanilla reserves output.amount * cyclesTimescaled BEFORE the
                    -- shared-throughput division. Add only our optional bonus on top
                    -- of that vanilla reservation. With sharedThroughputCapacity=false
                    -- this is exactly equal to producedAmount.
                    local baseActualAmount = output.amount * actualCycles
                    local bonusAmount = math.max(producedAmount - baseActualAmount, 0)
                    local requiredCapacity = output.amount * cyclesTimescaled + bonusAmount

                    if not output.sellDirectly
                        and productionPoint.storage:getFreeCapacity(output.type) + ProductionOptionalBoost.EPSILON < requiredCapacity then

                        enoughOutputSpace = false
                        if production.status ~= ProductionPoint.PROD_STATUS.NO_OUTPUT_SPACE then
                            production.status = ProductionPoint.PROD_STATUS.NO_OUTPUT_SPACE
                            productionPoint:setProductionStatus(production.id, production.status)
                        end
                        break
                    end
                end
            end

            if productionPoint.isOwned then
                productionPoint.productionCostsToClaim =
                    productionPoint.productionCostsToClaim
                    + production.costsPerActiveMinute * minuteFactorTimescaledDt
            end

            if not productionPoint.isOwned or enoughInputResources and enoughOutputSpace then
                for x = 1, #production.inputs do
                    local input = production.inputs[x]

                    if productionPoint.loadingStation == nil then
                        local fillLevel = productionPoint.inputFillLevels[input]
                        if fillLevel and fillLevel > 0 then
                            productionPoint.storage:setFillLevel(
                                fillLevel - input.amount * actualCycles,
                                input.type
                            )
                        end
                    else
                        productionPoint.loadingStation:removeFillLevel(
                            input.type,
                            input.amount * actualCycles,
                            productionPoint.ownerFarmId
                        )
                    end
                end

                if productionPoint.isOwned then
                    consumeBoosts(productionPoint, production, boostUsage)

                    for x = 1, #production.outputs do
                        local output = production.outputs[x]
                        local producedAmount = calculateProducedAmount(output, actualCycles, boostUsage)

                        if output.sellDirectly then
                            if productionPoint.isServer then
                                productionPoint.soldFillTypesToPayOut[output.type] =
                                    productionPoint.soldFillTypesToPayOut[output.type] + producedAmount
                            end
                        else
                            local fillLevel = productionPoint.storage:getFillLevel(output.type)
                            productionPoint.storage:setFillLevel(fillLevel + producedAmount, output.type)
                        end
                    end
                end

                if production.status ~= ProductionPoint.PROD_STATUS.RUNNING then
                    production.status = ProductionPoint.PROD_STATUS.RUNNING
                    productionPoint.owningPlaceable:productionStatusChanged(production, production.status)
                    ProductionPointProductionStatusEvent.sendEvent(
                        productionPoint,
                        production.index,
                        production.status
                    )
                end

                table.clear(productionPoint.inputFillLevels)
            end

            -- This recipe has now had its turn. It can no longer need its share of
            -- the mandatory reserve during this update, irrespective of whether it
            -- actually ran. Later recipes may therefore use the released surplus.
            if productionPoint.loadingStation == nil then
                releaseMandatoryReserve(mandatoryReserve, production, actualCycles)
            end
        end
    end

    spawnStockPalletIfPossible(productionPoint)
    productionPoint.lastUpdatedTime = g_time
end

-- Отображение optional boost в штатной карточке рецепта. На время
-- построения recipeCell бустеры добавляются как синтетические inputs, после
-- чего немедленно удаляются и никогда не становятся обязательными ресурсами.
local function formatCompactNumber(value, maxDecimals)
    value = value or 0
    maxDecimals = maxDecimals or 2

    local integerValue = math.floor(value + 0.5)
    if math.abs(value - integerValue) < 0.0001 then
        return g_i18n:formatNumber(integerValue, 0)
    end

    if maxDecimals >= 1 then
        local oneDecimalValue = math.floor(value * 10 + 0.5) / 10
        if math.abs(value - oneDecimalValue) < 0.0001 then
            return g_i18n:formatNumber(oneDecimalValue, 1)
        end
    end

    return g_i18n:formatNumber(value, maxDecimals)
end

local function formatBoostPercent(bonus)
    return formatCompactNumber(math.max(bonus or 0, 0) * 100, 2)
end

local function setBoostTextColor(element, state)
    if element == nil or element.setTextColor == nil then
        return
    end

    if state == 2 then
        -- Зелёный: ресурса хватает как минимум на один полностью усиленный цикл.
        element:setTextColor(0.305, 0.85, 0.10, 1.0)
    elseif state == 1 then
        -- Оранжевый: ресурс есть частично, поэтому бонус будет пропорциональным.
        element:setTextColor(1.0, 0.65, 0.0, 1.0)
    else
        -- Красный: ресурс для буста отсутствует.
        element:setTextColor(1.0, 0.0, 0.0, 1.0)
    end
end

local function shrinkRecipeText(element, factor)
    if element ~= nil
        and element.setTextSize ~= nil
        and element.textSize ~= nil then
        element:setTextSize(element.textSize * factor)
    end
end

-- Добавляет в карточку рецепта inputBoost и компактно показывает максимальный
-- выход при полном наличии всех бустеров, влияющих на конкретный output.
function ProductionOptionalBoost.productionMenuPopulateCell(
    frame,
    superFunc,
    list,
    section,
    index,
    cell)

    local production = frame.selectedProduction
    local productionPoint = frame.selectedProductionPoint
    local boosts = getProductionBoosts(production)

    local isRecipeCell =
        list == frame.detailsList
        and cell ~= nil
        and cell.name == "recipeCell"
        and production ~= nil
        and productionPoint ~= nil
        and boosts ~= nil
        and #boosts > 0

    if not isRecipeCell then
        return superFunc(frame, list, section, index, cell)
    end

    local baseInputCount = #production.inputs
    local syntheticInputs = {}

    for boostIndex, boost in ipairs(boosts) do
        local syntheticInput = {
            type = boost.type,
            amount = boost.amountPerCycle,
            productionOptionalBoostVisual = true,
            productionOptionalBoostIndex = boostIndex
        }

        syntheticInputs[#syntheticInputs + 1] = syntheticInput
        table.insert(production.inputs, syntheticInput)
    end

    local result = superFunc(frame, list, section, index, cell)

    -- Возвращаем настоящий рецепт сразу после штатного построения интерфейса.
    for i = #syntheticInputs, 1, -1 do
        local syntheticInput = syntheticInputs[i]
        for inputIndex = #production.inputs, 1, -1 do
            if production.inputs[inputIndex] == syntheticInput then
                table.remove(production.inputs, inputIndex)
                break
            end
        end
    end

    -------------------------------------------------------------------------
    -- Входы: подпись вида "150 x Солома +17,65%" без лишних скобок и нулей.
    -------------------------------------------------------------------------
    local inputLayout = cell:getAttribute("inputLayout")
    local inputElements = inputLayout ~= nil and inputLayout.elements or nil

    if inputElements ~= nil then
        for boostIndex, boost in ipairs(boosts) do
            local boostItem = inputElements[baseInputCount + boostIndex]

            if boostItem ~= nil then
                local amountElement = boostItem:getDescendantByName("amount")
                local nameElement = boostItem:getDescendantByName("name")
                local fillType = g_fillTypeManager:getFillTypeByIndex(boost.type)

                if nameElement ~= nil and fillType ~= nil then
                    nameElement:setText(
                        string.format(
                            "x %s +%s%%",
                            tostring(fillType.title),
                            formatBoostPercent(boost.bonus)
                        )
                    )
                    shrinkRecipeText(nameElement, 0.93)
                end

                local fillLevel = productionPoint:getFillLevel(boost.type) or 0
                local requiredAmount = math.max(boost.amountPerCycle or 0, 0)
                local availabilityState = 0

                if requiredAmount <= ProductionOptionalBoost.EPSILON
                    or fillLevel + ProductionOptionalBoost.EPSILON >= requiredAmount then
                    availabilityState = 2
                elseif fillLevel > ProductionOptionalBoost.EPSILON then
                    availabilityState = 1
                end

                setBoostTextColor(amountElement, availabilityState)
                setBoostTextColor(nameElement, availabilityState)
            end
        end
    end

    -------------------------------------------------------------------------
    -- Выходы: вместо длинного "850 (+192,53)" показываем компактное
    -- "850>1042,5". Левая часть — базовый выход, правая — максимум с бустами.
    -------------------------------------------------------------------------
    local outputLayout = cell:getAttribute("outputLayout")
    local outputElements = outputLayout ~= nil and outputLayout.elements or nil

    if outputElements ~= nil then
        for outputIndex, output in ipairs(production.outputs or {}) do
            local bonusFactor = 0

            for _, boost in ipairs(boosts) do
                if boostAffectsOutput(boost, output.type) then
                    bonusFactor = bonusFactor + boost.bonus
                end
            end

            if bonusFactor > ProductionOptionalBoost.EPSILON then
                local outputItem = outputElements[outputIndex]
                local amountElement =
                    outputItem ~= nil
                    and outputItem:getDescendantByName("amount")
                    or nil

                if amountElement ~= nil then
                    local boostedAmount = output.amount * (1 + bonusFactor)

                    amountElement:setText(
                        string.format(
                            "%s>%s",
                            formatCompactNumber(output.amount, 2),
                            formatCompactNumber(boostedAmount, 1)
                        )
                    )
                    shrinkRecipeText(amountElement, 0.85)
                end
            end
        end
    end

    if inputLayout ~= nil then
        inputLayout:invalidateLayout()
    end
    if outputLayout ~= nil then
        outputLayout:invalidateLayout()
    end

    return result
end

function ProductionOptionalBoost.install()
    if ProductionOptionalBoost.installed then
        return
    end

    ProductionOptionalBoost.installed = true

    ProductionPoint.registerXMLPaths = Utils.appendedFunction(
        ProductionPoint.registerXMLPaths,
        registerXMLPaths
    )

    ProductionPoint.load = Utils.overwrittenFunction(
        ProductionPoint.load,
        ProductionOptionalBoost.productionPointLoad
    )

    ProductionPoint.updateProduction = Utils.overwrittenFunction(
        ProductionPoint.updateProduction,
        ProductionOptionalBoost.productionPointUpdateProduction
    )

    if InGameMenuProductionFrame ~= nil
        and not InGameMenuProductionFrame.productionOptionalBoostRecipeInstalled then

        InGameMenuProductionFrame.productionOptionalBoostRecipeInstalled = true
        InGameMenuProductionFrame.populateCellForItemInSection =
            Utils.overwrittenFunction(
                InGameMenuProductionFrame.populateCellForItemInSection,
                ProductionOptionalBoost.productionMenuPopulateCell
            )

        Logging.info("%s Production menu recipe boost hook installed", LOG_PREFIX)
    end

    Logging.info("%s installed v%s", LOG_PREFIX, ProductionOptionalBoost.VERSION)
end

ProductionOptionalBoost.install()

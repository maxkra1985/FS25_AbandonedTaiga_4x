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

ProductionOptionalBoost.VERSION = "0.1.2.0"
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

    Logging.info("%s installed v%s", LOG_PREFIX, ProductionOptionalBoost.VERSION)
end

ProductionOptionalBoost.install()

--[[
    FS25 - PlaceableGreenhouseSeasonal
    Version 0.7.4.0

    Temperature + fertilizer productivity test for standard greenhouse placeables.

    Custom XML attributes on each production:
        #minTemperature
        #optimalTemperatureMin
        #optimalTemperatureMax
        #maxTemperature
        #temperatureImpact
        #fertilizerFillType
        #fertilizerPerCycle
        #fertilizerFactor

    Temperature is read primarily from the same source as the in-game calendar:
        g_currentMission.environment.weather.forecast:getCurrentWeather().temperature
    weather:getCurrentTemperature() is used only as a fallback/diagnostic source.

    Productivity:
        finalFactor = temperatureFactor^2 * growthReadiness^2

    Temperature curve:
        <= minTemperature                         -> raw factor 0
        minTemperature .. optimalTemperatureMin   -> linear 0..1
        optimalTemperatureMin..optimalTemperatureMax -> 1
        optimalTemperatureMax .. maxTemperature   -> linear 1..0
        >= maxTemperature                         -> raw factor 0

    temperatureImpact blends this raw factor with 1.0:
        0.0 -> temperature has no effect
        1.0 -> full temperature effect

    Example:
        rawTemperatureFactor = 0.40
        temperatureImpact    = 0.60
        temperatureFactor    = 1 - 0.60 * (1 - 0.40) = 0.64
]]

PlaceableGreenhouseSeasonal = {}

PlaceableGreenhouseSeasonal.VERSION = "0.7.4.0"
PlaceableGreenhouseSeasonal.MODE = "TEMPERATURE_GROWTH_PALLET_HUD_RECIPEBOOST_RENDER_TEST"

PlaceableGreenhouseSeasonal.SPEC_NAME = string.format("%s.greenhouseSeasonal", g_currentModName)
PlaceableGreenhouseSeasonal.SPEC_TABLE = string.format("spec_%s", PlaceableGreenhouseSeasonal.SPEC_NAME)

local SPEC_TABLE = PlaceableGreenhouseSeasonal.SPEC_TABLE
local LOG_PREFIX = "[GreenhouseSeasonal]"

Logging.info(
    "%s SCRIPT LOADED: version=%s mode=%s mod=%s",
    LOG_PREFIX,
    PlaceableGreenhouseSeasonal.VERSION,
    PlaceableGreenhouseSeasonal.MODE,
    tostring(g_currentModName)
)

function PlaceableGreenhouseSeasonal.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(PlaceableGreenhouse, specializations)
        and SpecializationUtil.hasSpecialization(PlaceableProductionPoint, specializations)
end

function PlaceableGreenhouseSeasonal.initSpecialization()
    Logging.info(
        "%s initSpecialization: version=%s mode=%s",
        LOG_PREFIX,
        PlaceableGreenhouseSeasonal.VERSION,
        PlaceableGreenhouseSeasonal.MODE
    )

    -- Install one global wrapper, but use the custom production calculation
    -- only for placeables that actually have this specialization and a
    -- fertilizer catalyst configured.
    if not ProductionPoint.greenhouseSeasonalUpdateProductionInstalled then
        ProductionPoint.greenhouseSeasonalUpdateProductionInstalled = true
        ProductionPoint.updateProduction = Utils.overwrittenFunction(
            ProductionPoint.updateProduction,
            PlaceableGreenhouseSeasonal.productionPointUpdateProduction
        )
        Logging.info("%s ProductionPoint catalyst hook installed", LOG_PREFIX)
    end

    -- Extend only greenhouseSeasonal ProductionPoint info rows. The wrapper
    -- calls the stock updateInfo first and then decorates production titles.
    if not ProductionPoint.greenhouseSeasonalUpdateInfoInstalled then
        ProductionPoint.greenhouseSeasonalUpdateInfoInstalled = true
        ProductionPoint.updateInfo = Utils.overwrittenFunction(
            ProductionPoint.updateInfo,
            PlaceableGreenhouseSeasonal.productionPointUpdateInfo
        )
        Logging.info("%s ProductionPoint info HUD hook installed", LOG_PREFIX)
    end

    -- Production menu recipe visualization: append the optional fertilizer
    -- catalyst to the stock recipe cell without making it a real production input.
    if InGameMenuProductionFrame ~= nil
        and not InGameMenuProductionFrame.greenhouseSeasonalRecipeBoostInstalled then

        InGameMenuProductionFrame.greenhouseSeasonalRecipeBoostInstalled = true
        InGameMenuProductionFrame.populateCellForItemInSection =
            Utils.overwrittenFunction(
                InGameMenuProductionFrame.populateCellForItemInSection,
                PlaceableGreenhouseSeasonal.productionMenuPopulateCell
            )

        Logging.info("%s Production menu recipe boost hook installed", LOG_PREFIX)
    end
end

function PlaceableGreenhouseSeasonal.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("GreenhouseSeasonal")

    local productionPath = basePath .. ".productionPoint.productions.production(?)"

    schema:register(XMLValueType.FLOAT, productionPath .. "#minTemperature",
        "Temperature at/below which raw temperature productivity reaches 0")
    schema:register(XMLValueType.FLOAT, productionPath .. "#optimalTemperatureMin",
        "Lower bound of optimal temperature range")
    schema:register(XMLValueType.FLOAT, productionPath .. "#optimalTemperatureMax",
        "Upper bound of optimal temperature range")
    schema:register(XMLValueType.FLOAT, productionPath .. "#maxTemperature",
        "Temperature at/above which raw temperature productivity reaches 0")
    schema:register(XMLValueType.FLOAT, productionPath .. "#temperatureImpact",
        "Strength of temperature effect: 0=no effect, 1=full effect", 1.0)

    schema:register(XMLValueType.FLOAT, productionPath .. "#growthHeatRequirement",
        "Growing degree-days required for growthReadiness to reach 1.0", 300.0)
    schema:register(XMLValueType.FLOAT, productionPath .. "#growthBaseTemperature",
        "Base temperature used for growing degree-day accumulation; defaults to minTemperature")

    schema:register(XMLValueType.STRING, productionPath .. "#fertilizerFillType",
        "Optional catalyst fillType", "FERTILIZER")
    schema:register(XMLValueType.FLOAT, productionPath .. "#fertilizerPerCycle",
        "Catalyst amount consumed per actually performed production cycle", 0.0)
    schema:register(XMLValueType.FLOAT, productionPath .. "#fertilizerFactor",
        "Output multiplier for the fertilized part of production", 1.8)

    schema:setXMLSpecializationType()
end


function PlaceableGreenhouseSeasonal.registerSavegameXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("GreenhouseSeasonal")

    local statePath = basePath .. ".greenhouseSeasonal"
    schema:register(XMLValueType.INT, statePath .. "#trackedPeriod", "Period whose temperature statistics are currently being accumulated")
    schema:register(XMLValueType.FLOAT, statePath .. "#monthTempSum", "Accumulated hourly temperatures for tracked period")
    schema:register(XMLValueType.INT, statePath .. "#monthTempSamples", "Number of hourly temperature samples for tracked period")
    schema:register(XMLValueType.FLOAT, statePath .. "#previousMonthAverageTemperature", "Average temperature of the last completed tracked period")

    local productionPath = statePath .. ".production(?)"
    schema:register(XMLValueType.STRING, productionPath .. "#id", "Production id")
    schema:register(XMLValueType.FLOAT, productionPath .. "#growthReadiness", "Accumulated crop growth readiness 0..1")

    schema:setXMLSpecializationType()
end

function PlaceableGreenhouseSeasonal.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType,
        "updateGreenhouseTemperatureProductivity",
        PlaceableGreenhouseSeasonal.updateGreenhouseTemperatureProductivity)

    SpecializationUtil.registerFunction(placeableType,
        "applyGreenhouseProductivity",
        PlaceableGreenhouseSeasonal.applyGreenhouseProductivity)

    SpecializationUtil.registerFunction(placeableType,
        "registerGreenhouseCatalystAsUiInput",
        PlaceableGreenhouseSeasonal.registerGreenhouseCatalystAsUiInput)

    SpecializationUtil.registerFunction(placeableType,
        "applyPreviousMonthReset",
        PlaceableGreenhouseSeasonal.applyPreviousMonthReset)
    SpecializationUtil.registerFunction(placeableType,
        "finalizeTrackedMonth",
        PlaceableGreenhouseSeasonal.finalizeTrackedMonth)
    SpecializationUtil.registerFunction(placeableType,
        "updateGrowthReadiness",
        PlaceableGreenhouseSeasonal.updateGrowthReadiness)

    SpecializationUtil.registerFunction(placeableType,
        "scheduleEmergencyPalletsForNextHour",
        PlaceableGreenhouseSeasonal.scheduleEmergencyPalletsForNextHour)
end

function PlaceableGreenhouseSeasonal.registerOverwrittenFunctions(placeableType)
    SpecializationUtil.registerOverwrittenFunction(placeableType,
        "getNeedHourChanged",
        PlaceableGreenhouseSeasonal.getNeedHourChanged)
end

function PlaceableGreenhouseSeasonal.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableGreenhouseSeasonal)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", PlaceableGreenhouseSeasonal)
    SpecializationUtil.registerEventListener(placeableType, "onHourChanged", PlaceableGreenhouseSeasonal)
end


local function getCurrentPeriod()
    if g_currentMission ~= nil
        and g_currentMission.environment ~= nil then
        return g_currentMission.environment.currentPeriod
    end
    return nil
end

local function getTemperatureSources()
    local forecastTemperature = nil
    local weatherApiTemperature = nil

    if g_currentMission ~= nil
        and g_currentMission.environment ~= nil
        and g_currentMission.environment.weather ~= nil then

        local weather = g_currentMission.environment.weather
        local forecast = weather.forecast

        -- Same source used by InGameMenuCalendarFrame:updateTodayView().
        if forecast ~= nil and forecast.getCurrentWeather ~= nil then
            local currentWeather = forecast:getCurrentWeather()
            if currentWeather ~= nil then
                forecastTemperature = currentWeather.temperature
            end
        end

        -- Old source kept only for diagnostics and fallback.
        if weather.getCurrentTemperature ~= nil then
            weatherApiTemperature = weather:getCurrentTemperature()
        end
    end

    if forecastTemperature ~= nil then
        return forecastTemperature, forecastTemperature, weatherApiTemperature, "forecast"
    end

    if weatherApiTemperature ~= nil then
        return weatherApiTemperature, forecastTemperature, weatherApiTemperature, "weatherApiFallback"
    end

    return nil, forecastTemperature, weatherApiTemperature, "unavailable"
end

local function getCurrentTemperature()
    local temperature = getTemperatureSources()
    return temperature
end

local SEASON_NAMES = {"SPRING", "SUMMER", "AUTUMN", "WINTER"}

local function calculateClimateStatistics()
    local result = {
        seasons = {},
        annualAverage = nil
    }

    if g_currentMission == nil
        or g_currentMission.environment == nil
        or g_currentMission.environment.weather == nil then
        return result
    end

    local weather = g_currentMission.environment.weather
    if weather.weatherObjects == nil then
        return result
    end

    local orderedSeasons = Season.getAllOrdered()
    local annualSum = 0
    local annualCount = 0

    for orderIndex, season in ipairs(orderedSeasons) do
        local objects = weather.weatherObjects[season]
        local seasonData = {
            season = season,
            name = SEASON_NAMES[orderIndex] or tostring(season),
            average = nil,
            minTemperature = nil,
            maxTemperature = nil,
            objectCount = 0,
            variationCount = 0,
            totalObjectWeight = 0
        }

        if objects ~= nil then
            local weightedObjectTemperatureSum = 0
            local objectWeightSum = 0

            for _, weatherObject in ipairs(objects) do
                local variations = weatherObject.variations
                if variations ~= nil and #variations > 0 then
                    local variationWeightedSum = 0
                    local variationWeightSum = 0

                    for _, variation in ipairs(variations) do
                        local minT = variation.minTemperature
                        local maxT = variation.maxTemperature
                        local weight = variation.weight or 1

                        if minT ~= nil and maxT ~= nil then
                            local midpoint = (minT + maxT) * 0.5
                            variationWeightedSum = variationWeightedSum + midpoint * weight
                            variationWeightSum = variationWeightSum + weight
                            seasonData.variationCount = seasonData.variationCount + 1

                            seasonData.minTemperature =
                                seasonData.minTemperature == nil
                                and minT
                                or math.min(seasonData.minTemperature, minT)

                            seasonData.maxTemperature =
                                seasonData.maxTemperature == nil
                                and maxT
                                or math.max(seasonData.maxTemperature, maxT)
                        end
                    end

                    if variationWeightSum > 0 then
                        local objectAverage = variationWeightedSum / variationWeightSum
                        local objectWeight = weatherObject.weight or 1

                        weightedObjectTemperatureSum =
                            weightedObjectTemperatureSum + objectAverage * objectWeight
                        objectWeightSum = objectWeightSum + objectWeight
                        seasonData.objectCount = seasonData.objectCount + 1
                        seasonData.totalObjectWeight =
                            seasonData.totalObjectWeight + objectWeight
                    end
                end
            end

            if objectWeightSum > 0 then
                seasonData.average =
                    weightedObjectTemperatureSum / objectWeightSum
                annualSum = annualSum + seasonData.average
                annualCount = annualCount + 1
            end
        end

        table.insert(result.seasons, seasonData)
    end

    if annualCount > 0 then
        result.annualAverage = annualSum / annualCount
    end

    return result
end

local function logClimateStatistics()
    local climate = calculateClimateStatistics()

    Logging.info("%s ===== MAP CLIMATE PROFILE =====", LOG_PREFIX)

    for _, seasonData in ipairs(climate.seasons) do
        if seasonData.average ~= nil then
            Logging.info(
                "%s Climate %s: avg=%.2f C range=%.1f..%.1f C objects=%d variations=%d objectWeight=%d",
                LOG_PREFIX,
                seasonData.name,
                seasonData.average,
                seasonData.minTemperature or 0,
                seasonData.maxTemperature or 0,
                seasonData.objectCount,
                seasonData.variationCount,
                seasonData.totalObjectWeight
            )
        else
            Logging.info(
                "%s Climate %s: no usable temperature data",
                LOG_PREFIX,
                seasonData.name
            )
        end
    end

    if climate.annualAverage ~= nil then
        Logging.info(
            "%s Climate ANNUAL: avg=%.2f C (mean of seasonal weighted averages)",
            LOG_PREFIX,
            climate.annualAverage
        )
    else
        Logging.warning("%s Climate ANNUAL: unable to calculate", LOG_PREFIX)
    end

    Logging.info("%s ===============================", LOG_PREFIX)

    return climate
end

local function calculateRawTemperatureFactor(entry, temperature)
    if entry.minTemperature == nil
        or entry.optimalTemperatureMin == nil
        or entry.optimalTemperatureMax == nil
        or entry.maxTemperature == nil then
        return 1.0
    end

    if temperature <= entry.minTemperature then
        return 0.0
    elseif temperature < entry.optimalTemperatureMin then
        local range = entry.optimalTemperatureMin - entry.minTemperature
        return range > 0 and (temperature - entry.minTemperature) / range or 1.0
    elseif temperature <= entry.optimalTemperatureMax then
        return 1.0
    elseif temperature < entry.maxTemperature then
        local range = entry.maxTemperature - entry.optimalTemperatureMax
        return range > 0 and (entry.maxTemperature - temperature) / range or 1.0
    end

    return 0.0
end

local function getPlaceableLogId(placeable)
    if placeable == nil then
        return "unknown"
    end

    local configFileName = tostring(placeable.configFileName or "?")
    local shortFile = string.match(configFileName, "([^/\\]+)$") or configFileName

    local displayName = nil
    if placeable.getName ~= nil then
        displayName = placeable:getName()
    end

    local rootNode = placeable.rootNode

    return string.format(
        "%s|%s|node=%s",
        tostring(displayName or "unnamed"),
        tostring(shortFile),
        tostring(rootNode or "?")
    )
end

function PlaceableGreenhouseSeasonal:registerGreenhouseCatalystAsUiInput(fillType)
    local spec = self[SPEC_TABLE]
    if spec == nil or spec.productionPoint == nil or fillType == nil then
        return
    end

    local productionPoint = spec.productionPoint

    -- Register the catalyst only in the ProductionPoint UI/input fillType lists.
    -- Do NOT add it to production.inputs: fertilizer must stay optional and
    -- must never trigger MISSING_INPUTS.
    if productionPoint.inputFillTypeIds[fillType] == nil then
        productionPoint.inputFillTypeIds[fillType] = true
        table.insert(productionPoint.inputFillTypeIdsArray, fillType)

        Logging.info(
            "%s UI INPUT REGISTERED: version=%s fillType=%s (%s) file=%s",
            LOG_PREFIX,
            PlaceableGreenhouseSeasonal.VERSION,
            tostring(fillType),
            tostring(g_fillTypeManager:getFillTypeNameByIndex(fillType)),
            tostring(self.configFileName)
        )
    end
end

function PlaceableGreenhouseSeasonal:onLoad(savegame)
    local spec = self[SPEC_TABLE]

    Logging.info(
        "%s [%s] onLoad: version=%s mode=%s file=%s",
        LOG_PREFIX,
        getPlaceableLogId(self),
        PlaceableGreenhouseSeasonal.VERSION,
        PlaceableGreenhouseSeasonal.MODE,
        tostring(self.configFileName)
    )

    spec.logId = getPlaceableLogId(self)
    spec.productionPoint = nil
    spec.productions = {}
    spec.hourlyProducedOutput = {}

    -- Emergency palletization state for AUTO_DELIVER outputs.
    spec.emergencyPalletJobs = {}
    spec.emergencyPalletNotificationKey = nil

    spec.hasTemperatureProductions = false
    spec.hasFertilizerCatalyst = false
    spec.climateStatsLogged = false
    spec.temperatureStats = {
        count = 0,
        sum = 0,
        min = nil,
        max = nil
    }

    -- Persistent monthly temperature/growth state.
    spec.trackedPeriod = getCurrentPeriod()
    spec.monthTempSum = 0
    spec.monthTempSamples = 0
    spec.previousMonthAverageTemperature = nil
    spec.stateLoadedFromSavegame = false

    local productionPointSpec = self.spec_productionPoint
    if productionPointSpec == nil or productionPointSpec.productionPoint == nil then
        Logging.error("%s Placeable '%s' has greenhouseSeasonal but no productionPoint.",
            LOG_PREFIX, tostring(self.configFileName))
        return
    end

    local productionPoint = productionPointSpec.productionPoint
    spec.productionPoint = productionPoint

    local scannedProductions = 0
    local registeredTemperatureProductions = 0
    local registeredCatalystProductions = 0

    self.xmlFile:iterate("placeable.productionPoint.productions.production", function(_, productionKey)
        scannedProductions = scannedProductions + 1
        local productionId = self.xmlFile:getValue(productionKey .. "#id")
        local production = productionId ~= nil and productionPoint.productionsIdToObj[productionId] or nil

        if production == nil then
            return
        end

        local minTemperature = self.xmlFile:getValue(productionKey .. "#minTemperature")
        local optimalTemperatureMin = self.xmlFile:getValue(productionKey .. "#optimalTemperatureMin")
        local optimalTemperatureMax = self.xmlFile:getValue(productionKey .. "#optimalTemperatureMax")
        local maxTemperature = self.xmlFile:getValue(productionKey .. "#maxTemperature")
        local temperatureImpact = math.clamp(
            self.xmlFile:getValue(productionKey .. "#temperatureImpact", 1.0), 0.0, 1.0)
        local growthHeatRequirement = math.max(
            self.xmlFile:getValue(productionKey .. "#growthHeatRequirement", 300.0), 1.0)
        local growthBaseTemperature = self.xmlFile:getValue(
            productionKey .. "#growthBaseTemperature", minTemperature)

        local hasAnyTemperatureValue =
            minTemperature ~= nil
            or optimalTemperatureMin ~= nil
            or optimalTemperatureMax ~= nil
            or maxTemperature ~= nil

        local hasTemperatureProfile =
            minTemperature ~= nil
            and optimalTemperatureMin ~= nil
            and optimalTemperatureMax ~= nil
            and maxTemperature ~= nil

        if hasAnyTemperatureValue and not hasTemperatureProfile then
            Logging.xmlWarning(self.xmlFile,
                "%s Production '%s' has an incomplete temperature profile; temperature effect disabled.",
                LOG_PREFIX, tostring(productionId))
        end

        if hasTemperatureProfile then
            if not (minTemperature < optimalTemperatureMin
                and optimalTemperatureMin <= optimalTemperatureMax
                and optimalTemperatureMax < maxTemperature) then
                Logging.xmlWarning(self.xmlFile,
                    "%s Production '%s' has invalid temperature ranges; temperature effect disabled.",
                    LOG_PREFIX, tostring(productionId))
                hasTemperatureProfile = false
            end
        end

        local fertilizerFillTypeName = self.xmlFile:getValue(
            productionKey .. "#fertilizerFillType", "FERTILIZER")
        local fertilizerPerCycle = math.max(
            self.xmlFile:getValue(productionKey .. "#fertilizerPerCycle", 0.0), 0.0)
        local fertilizerFactor = math.max(
            self.xmlFile:getValue(productionKey .. "#fertilizerFactor", 1.8), 1.0)

        local fertilizerFillType = nil
        local hasFertilizerCatalyst = fertilizerPerCycle > 0.0

        if hasFertilizerCatalyst then
            fertilizerFillType = g_fillTypeManager:getFillTypeIndexByName(fertilizerFillTypeName)

            if fertilizerFillType == nil then
                Logging.xmlWarning(self.xmlFile,
                    "%s Production '%s' uses unknown catalyst fillType '%s'; catalyst disabled.",
                    LOG_PREFIX, tostring(productionId), tostring(fertilizerFillTypeName))
                hasFertilizerCatalyst = false
            elseif not productionPoint.storage:getIsFillTypeSupported(fertilizerFillType) then
                Logging.xmlWarning(self.xmlFile,
                    "%s Production '%s': storage does not support catalyst '%s'; catalyst disabled.",
                    LOG_PREFIX, tostring(productionId), tostring(fertilizerFillTypeName))
                hasFertilizerCatalyst = false
            end
        end

        if hasTemperatureProfile or hasFertilizerCatalyst then
            spec.productions[productionId] = {
                production = production,
                minTemperature = minTemperature,
                optimalTemperatureMin = optimalTemperatureMin,
                optimalTemperatureMax = optimalTemperatureMax,
                maxTemperature = maxTemperature,
                temperatureImpact = temperatureImpact,
                hasTemperatureProfile = hasTemperatureProfile,

                growthHeatRequirement = growthHeatRequirement,
                growthBaseTemperature = growthBaseTemperature,
                growthReadiness = 0.0,
                lastGrowthIncrement = 0.0,

                hasFertilizerCatalyst = hasFertilizerCatalyst,
                fertilizerFillType = fertilizerFillType,
                fertilizerFillTypeName = fertilizerFillTypeName,
                fertilizerPerCycle = fertilizerPerCycle,
                fertilizerFactor = fertilizerFactor,
                fertilizerActive = false,

                baseCyclesPerMonth = production.cyclesPerMonth,
                rawTemperatureFactor = 1.0,
                temperatureFactor = 1.0,
                finalFactor = 1.0
            }

            if hasTemperatureProfile then
                spec.hasTemperatureProductions = true
                registeredTemperatureProductions = registeredTemperatureProductions + 1
            end
            if hasFertilizerCatalyst then
                spec.hasFertilizerCatalyst = true
                registeredCatalystProductions = registeredCatalystProductions + 1

                self:registerGreenhouseCatalystAsUiInput(fertilizerFillType)
            end

            Logging.info(
                "%s Loaded '%s' (%s): baseCyclesPerMonth=%.6f, temp=%s, fertilizer=%s",
                LOG_PREFIX,
                tostring(production.name or productionId),
                tostring(productionId),
                production.cyclesPerMonth,
                hasTemperatureProfile and string.format(
                    "%.1f/%.1f..%.1f/%.1f impact=%.2f growthBase=%.1f heatReq=%.1fGDD",
                    minTemperature, optimalTemperatureMin,
                    optimalTemperatureMax, maxTemperature,
                    temperatureImpact, growthBaseTemperature, growthHeatRequirement) or "disabled",
                hasFertilizerCatalyst and string.format(
                    "%s %.3f/cycle x%.2f",
                    fertilizerFillTypeName, fertilizerPerCycle, fertilizerFactor) or "disabled"
            )
        end
    end)

    Logging.info(
        "%s [%s] onLoad summary: version=%s scanned=%d temperatureProfiles=%d catalystProfiles=%d needHourChanged=%s uiCatalystVisible=%s",
        LOG_PREFIX,
        tostring(spec.logId),
        PlaceableGreenhouseSeasonal.VERSION,
        scannedProductions,
        registeredTemperatureProductions,
        registeredCatalystProductions,
        tostring(spec.hasTemperatureProductions or spec.hasFertilizerCatalyst),
        tostring(spec.hasFertilizerCatalyst)
    )

    if not spec.hasTemperatureProductions then
        Logging.warning(
            "%s NO TEMPERATURE PROFILES FOUND in '%s'. Expected attributes: minTemperature, optimalTemperatureMin, optimalTemperatureMax, maxTemperature.",
            LOG_PREFIX,
            tostring(self.configFileName)
        )
    end
end


local function getClimateAverageForPeriod(climate, period)
    if climate == nil or climate.seasons == nil or period == nil then
        return nil
    end

    -- FS period numbering: 1=March ... 10=December, 11=January, 12=February.
    -- Therefore periods 1..3 spring, 4..6 summer, 7..9 autumn, 10..12 winter.
    local seasonIndex = math.floor((period - 1) / 3) + 1
    local seasonData = climate.seasons[seasonIndex]
    return seasonData ~= nil and seasonData.average or nil
end

local function getPreviousPeriod(period)
    if period == nil then
        return nil
    end
    return period == 1 and 12 or period - 1
end

function PlaceableGreenhouseSeasonal:applyPreviousMonthReset(previousAverage, source)
    local spec = self[SPEC_TABLE]
    if spec == nil or previousAverage == nil then
        return
    end

    for productionId, entry in pairs(spec.productions) do
        if entry.hasTemperatureProfile then
            local oldReadiness = entry.growthReadiness or 0.0
            local reset = previousAverage < entry.minTemperature

            if reset then
                entry.growthReadiness = 0.0
            end

            Logging.info(
                "%s [%s] MONTH RESET CHECK: production=%s previousAvg=%.2f C minTemperature=%.2f C source=%s reset=%s readiness=%.4f->%.4f",
                LOG_PREFIX,
                tostring(spec.logId),
                tostring(productionId),
                previousAverage,
                entry.minTemperature,
                tostring(source),
                tostring(reset),
                oldReadiness,
                entry.growthReadiness
            )
        end
    end
end

function PlaceableGreenhouseSeasonal:finalizeTrackedMonth(newPeriod)
    local spec = self[SPEC_TABLE]
    if spec == nil then
        return
    end

    local previousAverage = nil
    local source = nil

    if spec.monthTempSamples ~= nil and spec.monthTempSamples > 0 then
        previousAverage = spec.monthTempSum / spec.monthTempSamples
        source = "hourlySamples"
    elseif spec.climate ~= nil then
        previousAverage = getClimateAverageForPeriod(spec.climate, spec.trackedPeriod)
        source = "climateFallback"
    end

    if previousAverage ~= nil then
        spec.previousMonthAverageTemperature = previousAverage
        self:applyPreviousMonthReset(previousAverage, source)
    end

    Logging.info(
        "%s [%s] MONTH FINALIZED: oldPeriod=%s newPeriod=%s avg=%s samples=%d source=%s",
        LOG_PREFIX,
        tostring(spec.logId),
        tostring(spec.trackedPeriod),
        tostring(newPeriod),
        previousAverage ~= nil and string.format("%.2f", previousAverage) or "-",
        spec.monthTempSamples or 0,
        tostring(source or "none")
    )

    spec.trackedPeriod = newPeriod
    spec.monthTempSum = 0
    spec.monthTempSamples = 0
end

function PlaceableGreenhouseSeasonal:updateGrowthReadiness(temperature)
    local spec = self[SPEC_TABLE]
    if spec == nil or temperature == nil then
        return
    end

    for productionId, entry in pairs(spec.productions) do
        if entry.hasTemperatureProfile then
            local oldReadiness = entry.growthReadiness or 0.0

            -- Growing Degree Days accumulated from one hourly sample.
            -- One FS period represents roughly one calendar month. If the player
            -- uses fewer in-game days per period, scale the hourly heat so crop
            -- development remains independent of the "days per month" setting.
            local heatAboveBase = math.max(temperature - entry.growthBaseTemperature, 0.0)

            local daysPerPeriod = 1
            if g_currentMission ~= nil
                and g_currentMission.environment ~= nil
                and g_currentMission.environment.daysPerPeriod ~= nil then
                daysPerPeriod = math.max(g_currentMission.environment.daysPerPeriod, 1)
            end

            local calendarScale = 30.0 / daysPerPeriod
            local gddThisHourUnscaled = heatAboveBase / 24.0
            local gddThisHour = gddThisHourUnscaled * calendarScale
            local readinessIncrement = gddThisHour / entry.growthHeatRequirement

            entry.lastGrowthIncrement = readinessIncrement
            entry.growthReadiness = math.clamp(oldReadiness + readinessIncrement, 0.0, 1.0)

            Logging.info(
                "%s [%s] GROWTH: production=%s temp=%.2f base=%.2f daysPerPeriod=%d calendarScale=%.2f gddHourRaw=%.5f gddHourScaled=%.5f heatReq=%.2f readiness=%.5f->%.5f",
                LOG_PREFIX,
                tostring(spec.logId),
                tostring(productionId),
                temperature,
                entry.growthBaseTemperature,
                daysPerPeriod,
                calendarScale,
                gddThisHourUnscaled,
                gddThisHour,
                entry.growthHeatRequirement,
                oldReadiness,
                entry.growthReadiness
            )
        end
    end
end

function PlaceableGreenhouseSeasonal:onFinalizePlacement()
    local spec = self[SPEC_TABLE]

    Logging.info(
        "%s onFinalizePlacement: version=%s tempProfiles=%s catalyst=%s",
        LOG_PREFIX,
        PlaceableGreenhouseSeasonal.VERSION,
        tostring(spec ~= nil and spec.hasTemperatureProductions),
        tostring(spec ~= nil and spec.hasFertilizerCatalyst)
    )

    if spec == nil then
        return
    end

    if not spec.climateStatsLogged then
        spec.climate = logClimateStatistics()
        spec.climateStatsLogged = true
    end

    if not spec.stateLoadedFromSavegame then
        local currentPeriod = getCurrentPeriod()
        spec.trackedPeriod = currentPeriod

        local previousPeriod = getPreviousPeriod(currentPeriod)
        local fallbackAverage = getClimateAverageForPeriod(spec.climate, previousPeriod)
        spec.previousMonthAverageTemperature = fallbackAverage

        if fallbackAverage ~= nil then
            self:applyPreviousMonthReset(fallbackAverage, "climateFallbackOnLoad")
        end

        Logging.info(
            "%s [%s] STATE INIT: no saved greenhouse climate state; trackedPeriod=%s previousPeriod=%s previousAvg=%s readiness starts from saved/default values",
            LOG_PREFIX,
            tostring(spec.logId),
            tostring(currentPeriod),
            tostring(previousPeriod),
            fallbackAverage ~= nil and string.format("%.2f", fallbackAverage) or "-"
        )
    end

    local temperature, forecastTemperature, weatherApiTemperature, temperatureSource =
        getTemperatureSources()

    Logging.info(
        "%s [%s] TEMP SOURCE INIT: version=%s forecast=%s weatherApi=%s used=%s source=%s",
        LOG_PREFIX,
        tostring(spec.logId),
        PlaceableGreenhouseSeasonal.VERSION,
        forecastTemperature ~= nil and string.format("%.2f", forecastTemperature) or "-",
        weatherApiTemperature ~= nil and string.format("%.2f", weatherApiTemperature) or "-",
        temperature ~= nil and string.format("%.2f", temperature) or "-",
        tostring(temperatureSource)
    )

    if spec.hasTemperatureProductions then
        self:updateGreenhouseTemperatureProductivity(temperature, true)
    end
end

function PlaceableGreenhouseSeasonal:onHourChanged(currentHour)
    local spec = self[SPEC_TABLE]
    local currentPeriod = getCurrentPeriod()

    -- TEST HOOK: amounts accumulated by ProductionPoint:updateProduction()
    -- since the previous HOUR_CHANGED event.
    local produced = spec.hourlyProducedOutput or {}
    local knownProductionIds = {
        "whitecabbage",
        "tomato",
        "cucumber",
        "strawberry"
    }

    local totalProduced = 0.0
    for _, amount in pairs(produced) do
        totalProduced = totalProduced + (amount or 0.0)
    end

    Logging.info(
        "%s [%s] HOURLY OUTPUT BEGIN: version=%s hour=%s period=%s totalProduced=%.3f l",
        LOG_PREFIX,
        tostring(spec.logId),
        PlaceableGreenhouseSeasonal.VERSION,
        tostring(currentHour),
        tostring(currentPeriod),
        totalProduced
    )

    for _, productionId in ipairs(knownProductionIds) do
        Logging.info(
            "%s [%s] HOURLY OUTPUT: production=%s produced=%.3f l",
            LOG_PREFIX,
            tostring(spec.logId),
            productionId,
            produced[productionId] or 0.0
        )
    end

    -- Preserve visibility if an unexpected production id appears.
    for productionId, amount in pairs(produced) do
        local known =
            productionId == "whitecabbage"
            or productionId == "tomato"
            or productionId == "cucumber"
            or productionId == "strawberry"

        if not known then
            Logging.info(
                "%s [%s] HOURLY OUTPUT EXTRA: production=%s produced=%.3f l",
                LOG_PREFIX,
                tostring(spec.logId),
                tostring(productionId),
                amount or 0.0
            )
        end
    end

    Logging.info(
        "%s [%s] HOURLY OUTPUT END: version=%s hour=%s",
        LOG_PREFIX,
        tostring(spec.logId),
        PlaceableGreenhouseSeasonal.VERSION,
        tostring(currentHour)
    )

    spec.hourlyProducedOutput = {}
    local temperature, forecastTemperature, weatherApiTemperature, temperatureSource =
        getTemperatureSources()

    Logging.info(
        "%s [%s] TEMP SOURCE: version=%s hour=%s period=%s forecast=%s weatherApi=%s used=%s source=%s",
        LOG_PREFIX,
        tostring(spec.logId),
        PlaceableGreenhouseSeasonal.VERSION,
        tostring(currentHour),
        tostring(currentPeriod),
        forecastTemperature ~= nil and string.format("%.2f", forecastTemperature) or "-",
        weatherApiTemperature ~= nil and string.format("%.2f", weatherApiTemperature) or "-",
        temperature ~= nil and string.format("%.2f", temperature) or "-",
        tostring(temperatureSource)
    )

    if spec.trackedPeriod == nil then
        spec.trackedPeriod = currentPeriod
    elseif currentPeriod ~= nil and currentPeriod ~= spec.trackedPeriod then
        self:finalizeTrackedMonth(currentPeriod)
    end

    if temperature ~= nil then
        spec.monthTempSum = (spec.monthTempSum or 0) + temperature
        spec.monthTempSamples = (spec.monthTempSamples or 0) + 1
        local stats = spec.temperatureStats
        stats.count = stats.count + 1
        stats.sum = stats.sum + temperature
        stats.min = stats.min == nil and temperature or math.min(stats.min, temperature)
        stats.max = stats.max == nil and temperature or math.max(stats.max, temperature)

        Logging.info(
            "%s [%s] HOURLY: version=%s mode=%s hour=%s period=%s temperature=%.2f C sessionAvg=%.2f C sessionMin=%.2f C sessionMax=%.2f C samples=%d",
            LOG_PREFIX,
            tostring(spec.logId),
            PlaceableGreenhouseSeasonal.VERSION,
            PlaceableGreenhouseSeasonal.MODE,
            tostring(currentHour),
            tostring(currentPeriod),
            temperature,
            stats.sum / stats.count,
            stats.min,
            stats.max,
            stats.count
        )
    else
        Logging.warning(
            "%s [%s] HOURLY: version=%s mode=%s hour=%s period=%s temperature unavailable",
            LOG_PREFIX,
            tostring(spec.logId),
            PlaceableGreenhouseSeasonal.VERSION,
            PlaceableGreenhouseSeasonal.MODE,
            tostring(currentHour),
            tostring(currentPeriod)
        )
    end

    if spec.hasTemperatureProductions and temperature ~= nil then
        -- First accumulate thermal development for this hour, then use the
        -- updated readiness in the production factor for the same hour.
        self:updateGrowthReadiness(temperature)
        self:updateGreenhouseTemperatureProductivity(temperature, true)

        Logging.info(
            "%s [%s] GROWTH UPDATE COMPLETE: version=%s hour=%s period=%s",
            LOG_PREFIX,
            tostring(spec.logId),
            PlaceableGreenhouseSeasonal.VERSION,
            tostring(currentHour),
            tostring(currentPeriod)
        )
    end

    -- After the new hourly productivity has been calculated, make sure an
    -- AUTO_DELIVER output has enough storage room for the coming hour.
    self:scheduleEmergencyPalletsForNextHour(currentHour, currentPeriod)

    if spec.hasFertilizerCatalyst and spec.productionPoint ~= nil then
        for productionId, entry in pairs(spec.productions) do
            if entry.hasFertilizerCatalyst then
                local fillLevel =
                    spec.productionPoint.storage:getFillLevel(entry.fertilizerFillType)

                Logging.info(
                    "%s [%s] CATALYST: production=%s fertilizer=%s level=%.3f perCycle=%.3f outputFactor=%.2f active=%s",
                    LOG_PREFIX,
                    tostring(spec.logId),
                    tostring(productionId),
                    tostring(entry.fertilizerFillTypeName),
                    fillLevel or 0,
                    entry.fertilizerPerCycle,
                    entry.fertilizerFactor,
                    tostring(entry.fertilizerActive)
                )
            end
        end
    end
end

function PlaceableGreenhouseSeasonal:updateGreenhouseTemperatureProductivity(temperature, forceLog)
    local spec = self[SPEC_TABLE]
    if spec == nil or not spec.hasTemperatureProductions or temperature == nil then
        return
    end

    for productionId, entry in pairs(spec.productions) do
        if entry.hasTemperatureProfile then
            local rawFactor = math.clamp(calculateRawTemperatureFactor(entry, temperature), 0.0, 1.0)

            local temperatureFactor
            if rawFactor <= 0.0 then
                -- Outside the biologically allowed range the crop is fully stopped.
                temperatureFactor = 0.0
            else
                temperatureFactor = 1.0 - entry.temperatureImpact * (1.0 - rawFactor)
                temperatureFactor = math.clamp(temperatureFactor, 0.0, 1.0)
            end

            -- Both instantaneous temperature suitability and accumulated
            -- developmental readiness use a quadratic response.
            local readiness = math.clamp(entry.growthReadiness or 0.0, 0.0, 1.0)
            local newFactor =
                (temperatureFactor * temperatureFactor)
                * (readiness * readiness)

            local changed = math.abs(entry.finalFactor - newFactor) > 0.0001
            entry.rawTemperatureFactor = rawFactor
            entry.temperatureFactor = temperatureFactor
            entry.finalFactor = newFactor

            if changed or forceLog then
                self:applyGreenhouseProductivity(entry, productionId, "temperature", temperature)
            end
        end
    end
end

function PlaceableGreenhouseSeasonal:applyGreenhouseProductivity(entry, productionId, reason, temperature)
    local spec = self[SPEC_TABLE]
    local production = entry.production
    local finalFactor = entry.finalFactor

    production.cyclesPerMonth = entry.baseCyclesPerMonth * finalFactor
    production.cyclesPerHour = production.cyclesPerMonth / 24
    production.cyclesPerMinute = production.cyclesPerHour / 60
    entry.finalFactor = finalFactor

    Logging.info(
        "%s [%s] TEMP: '%s' (%s) period=%s temp=%s rawFactor=%.3f impact=%.2f temperatureFactor=%.3f temperatureSquared=%.3f growthReadiness=%.4f readinessSquared=%.4f finalFactor=%.4f stoppedByTemperature=%s cyclesPerHour=%.6f baseCyclesPerHour=%.6f",
        LOG_PREFIX,
        tostring(spec ~= nil and spec.logId or getPlaceableLogId(self)),
        tostring(production.name or productionId),
        tostring(productionId),
        tostring(getCurrentPeriod()),
        temperature ~= nil and string.format("%.2f", temperature) or "-",
        entry.rawTemperatureFactor,
        entry.temperatureImpact,
        entry.temperatureFactor,
        entry.temperatureFactor * entry.temperatureFactor,
        entry.growthReadiness or 0.0,
        (entry.growthReadiness or 0.0) * (entry.growthReadiness or 0.0),
        entry.finalFactor or 0.0,
        tostring(entry.rawTemperatureFactor <= 0.0),
        production.cyclesPerHour,
        entry.baseCyclesPerMonth / 24
    )
end



function PlaceableGreenhouseSeasonal:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self[SPEC_TABLE]
    if spec == nil then
        return
    end

    local stateKey = key .. ".greenhouseSeasonal"
    xmlFile:setValue(stateKey .. "#trackedPeriod", spec.trackedPeriod or getCurrentPeriod() or 1)
    xmlFile:setValue(stateKey .. "#monthTempSum", spec.monthTempSum or 0.0)
    xmlFile:setValue(stateKey .. "#monthTempSamples", spec.monthTempSamples or 0)

    if spec.previousMonthAverageTemperature ~= nil then
        xmlFile:setValue(
            stateKey .. "#previousMonthAverageTemperature",
            spec.previousMonthAverageTemperature
        )
    end

    local index = 0
    for productionId, entry in pairs(spec.productions) do
        local productionKey = string.format("%s.production(%d)", stateKey, index)
        xmlFile:setValue(productionKey .. "#id", productionId)
        xmlFile:setValue(
            productionKey .. "#growthReadiness",
            math.clamp(entry.growthReadiness or 0.0, 0.0, 1.0)
        )
        index = index + 1
    end

    Logging.info(
        "%s [%s] SAVE STATE: period=%s monthSum=%.3f samples=%d previousAvg=%s productions=%d",
        LOG_PREFIX,
        tostring(spec.logId),
        tostring(spec.trackedPeriod),
        spec.monthTempSum or 0.0,
        spec.monthTempSamples or 0,
        spec.previousMonthAverageTemperature ~= nil
            and string.format("%.2f", spec.previousMonthAverageTemperature)
            or "-",
        index
    )
end

function PlaceableGreenhouseSeasonal:loadFromXMLFile(xmlFile, key)
    local spec = self[SPEC_TABLE]
    if spec == nil then
        return
    end

    local stateKey = key .. ".greenhouseSeasonal"
    if not xmlFile:hasProperty(stateKey) then
        return
    end

    spec.trackedPeriod = xmlFile:getValue(
        stateKey .. "#trackedPeriod",
        getCurrentPeriod()
    )
    spec.monthTempSum = xmlFile:getValue(stateKey .. "#monthTempSum", 0.0)
    spec.monthTempSamples = xmlFile:getValue(stateKey .. "#monthTempSamples", 0)
    spec.previousMonthAverageTemperature = xmlFile:getValue(
        stateKey .. "#previousMonthAverageTemperature"
    )

    xmlFile:iterate(stateKey .. ".production", function(_, productionKey)
        local productionId = xmlFile:getValue(productionKey .. "#id")
        local readiness = xmlFile:getValue(productionKey .. "#growthReadiness")

        local entry = productionId ~= nil and spec.productions[productionId] or nil
        if entry ~= nil and readiness ~= nil then
            entry.growthReadiness = math.clamp(readiness, 0.0, 1.0)
        end
    end)

    spec.stateLoadedFromSavegame = true

    Logging.info(
        "%s [%s] LOAD STATE: period=%s monthSum=%.3f samples=%d previousAvg=%s",
        LOG_PREFIX,
        tostring(spec.logId),
        tostring(spec.trackedPeriod),
        spec.monthTempSum or 0.0,
        spec.monthTempSamples or 0,
        spec.previousMonthAverageTemperature ~= nil
            and string.format("%.2f", spec.previousMonthAverageTemperature)
            or "-"
    )
end



-- Returns the display name used in emergency notifications.
local function getGreenhouseDisplayName(placeable)
    if placeable == nil then
        return "Грядка"
    end

    if placeable.getName ~= nil then
        local name = placeable:getName()
        if name ~= nil and name ~= "" then
            return name
        end
    end

    if placeable.name ~= nil and placeable.name ~= "" then
        return placeable.name
    end

    return "Грядка"
end

-- Start one pallet from an already prepared emergency job.
local function spawnNextEmergencyPallet(placeable, fillTypeId)
    local spec = placeable ~= nil and placeable[SPEC_TABLE] or nil
    local productionPoint = spec ~= nil and spec.productionPoint or nil
    local job = spec ~= nil and spec.emergencyPalletJobs[fillTypeId] or nil

    if productionPoint == nil or job == nil or job.remaining <= 0 then
        if productionPoint ~= nil then
            productionPoint.waitingForPalletToSpawn = false
        end
        return
    end

    if productionPoint.palletSpawner == nil then
        Logging.warning(
            "%s [%s] EMERGENCY PALLET: no palletSpawner for fillType=%s",
            LOG_PREFIX,
            tostring(spec.logId),
            tostring(fillTypeId)
        )
        spec.emergencyPalletJobs[fillTypeId] = nil
        productionPoint.waitingForPalletToSpawn = false
        return
    end

    productionPoint.waitingForPalletToSpawn = true

    Logging.info(
        "%s [%s] EMERGENCY PALLET SPAWN REQUEST: fillType=%s remaining=%d planned=%d",
        LOG_PREFIX,
        tostring(spec.logId),
        tostring(fillTypeId),
        job.remaining,
        job.planned
    )

    productionPoint.palletSpawner:spawnPallet(
        productionPoint:getOwnerFarmId(),
        fillTypeId,
        PlaceableGreenhouseSeasonal.emergencyPalletSpawnCallback,
        placeable
    )
end

function PlaceableGreenhouseSeasonal.emergencyPalletSpawnCallback(
    placeable,
    pallet,
    status,
    fillTypeId)

    local spec = placeable ~= nil and placeable[SPEC_TABLE] or nil
    local productionPoint = spec ~= nil and spec.productionPoint or nil
    local job = spec ~= nil and spec.emergencyPalletJobs[fillTypeId] or nil

    if productionPoint == nil or job == nil then
        return
    end

    if pallet == nil
        or pallet.addFillUnitFillLevel == nil
        or fillTypeId == nil then

        productionPoint.waitingForPalletToSpawn = false
        productionPoint.palletSpawnCooldown =
            g_time + ProductionPoint.NO_PALLET_SPACE_COOLDOWN

        if status == PalletSpawner.PALLET_LIMITED_REACHED then
            if not productionPoint.palletLimitReached then
                productionPoint.palletLimitReached = true
                productionPoint:raiseDirtyFlags(productionPoint.dirtyFlag)
            end
        end

        Logging.warning(
            "%s [%s] EMERGENCY PALLET FAILED: fillType=%s status=%s remaining=%d",
            LOG_PREFIX,
            tostring(spec.logId),
            tostring(fillTypeId),
            tostring(status),
            job.remaining
        )

        -- Do not loop endlessly if the spawn area is blocked or the pallet
        -- limit is reached. Production will stay protected by stock
        -- NO_OUTPUT_SPACE behavior and we can retry at the next hour.
        spec.emergencyPalletJobs[fillTypeId] = nil
        return
    end

    if productionPoint.palletLimitReached then
        productionPoint.palletLimitReached = false
        productionPoint:raiseDirtyFlags(productionPoint.dirtyFlag)
    end

    local fillUnitIndex = pallet:getFirstValidFillUnitToFill(fillTypeId)
    if fillUnitIndex == nil then
        productionPoint.waitingForPalletToSpawn = false
        Logging.warning(
            "%s [%s] EMERGENCY PALLET FAILED: no fillUnit for fillType=%s",
            LOG_PREFIX,
            tostring(spec.logId),
            tostring(fillTypeId)
        )
        spec.emergencyPalletJobs[fillTypeId] = nil
        return
    end

    local palletData =
        productionPoint.outputFillTypeIdsToPallets[fillTypeId]
    local palletCapacity =
        palletData ~= nil and palletData.capacity or math.huge

    local storageBefore =
        productionPoint.storage:getFillLevel(fillTypeId)

    -- The job is scheduled only when at least one complete pallet is already
    -- available in storage. Limit the transfer explicitly to one pallet
    -- capacity so every emergency pallet is full.
    local requestedAmount = math.min(storageBefore, palletCapacity)

    local moved = pallet:addFillUnitFillLevel(
        productionPoint:getOwnerFarmId(),
        fillUnitIndex,
        requestedAmount,
        fillTypeId,
        ToolType.UNDEFINED
    )

    if moved ~= nil and moved > 0 then
        productionPoint.storage:setFillLevel(
            math.max(storageBefore - moved, 0),
            fillTypeId
        )

        job.remaining = job.remaining - 1
        job.spawned = job.spawned + 1

        Logging.info(
            "%s [%s] EMERGENCY PALLET FILLED: fillType=%s moved=%.3f storage=%.3f->%.3f remaining=%d",
            LOG_PREFIX,
            tostring(spec.logId),
            tostring(fillTypeId),
            moved,
            storageBefore,
            productionPoint.storage:getFillLevel(fillTypeId),
            job.remaining
        )

        -- AUTO_DELIVER emergency warning: once per placeable/hour, after the
        -- first pallet was actually filled successfully.
        local notificationKey =
            string.format("%s:%s", tostring(job.period), tostring(job.hour))

        if job.autoDeliver
            and spec.emergencyPalletNotificationKey ~= notificationKey then

            spec.emergencyPalletNotificationKey = notificationKey

            if g_currentMission ~= nil
                and g_currentMission.addIngameNotification ~= nil then

                local message = string.format(
                    "%s заполнена, распределение невозможно! Продукция выгружена в поддонах!",
                    getGreenhouseDisplayName(placeable)
                )

                g_currentMission:addIngameNotification(
                    FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                    message
                )
            end
        end
    else
        Logging.warning(
            "%s [%s] EMERGENCY PALLET FAILED TO FILL: fillType=%s storage=%.3f",
            LOG_PREFIX,
            tostring(spec.logId),
            tostring(fillTypeId),
            storageBefore
        )
        job.remaining = 0
    end

    if job.remaining > 0 then
        -- Keep stock pallet spawning paused while this emergency queue is active.
        spawnNextEmergencyPallet(placeable, fillTypeId)
    else
        productionPoint.waitingForPalletToSpawn = false
        spec.emergencyPalletJobs[fillTypeId] = nil
    end
end

function PlaceableGreenhouseSeasonal:scheduleEmergencyPalletsForNextHour(
    currentHour,
    currentPeriod)

    local spec = self[SPEC_TABLE]
    local productionPoint = spec ~= nil and spec.productionPoint or nil

    if productionPoint == nil
        or not productionPoint.isServer
        or not productionPoint.isOwned
        or productionPoint.palletSpawner == nil then
        return
    end

    local activeCount = #productionPoint.activeProductions
    if activeCount == 0 then
        return
    end

    -- Sum the predicted output for the coming in-game hour by fill type.
    local predictedByFillType = {}

    for _, production in ipairs(productionPoint.activeProductions) do
        local entry = spec.productions[production.id]
        local throughputDivisor =
            productionPoint.sharedThroughputCapacity and activeCount or 1
        local cycles = (production.cyclesPerHour or 0) / throughputDivisor

        if cycles > 0 then
            local fertilizedCycles = 0

            if entry ~= nil
                and entry.hasFertilizerCatalyst
                and entry.fertilizerPerCycle > 0 then

                local fertilizerLevel =
                    productionPoint.storage:getFillLevel(entry.fertilizerFillType)

                fertilizedCycles = math.min(
                    cycles,
                    fertilizerLevel / entry.fertilizerPerCycle
                )
            end

            for _, output in ipairs(production.outputs) do
                if not output.sellDirectly then
                    local predicted =
                        output.amount
                        * (
                            cycles
                            + fertilizedCycles
                                * (entry ~= nil
                                    and entry.hasFertilizerCatalyst
                                    and (entry.fertilizerFactor - 1.0)
                                    or 0.0)
                        )

                    predictedByFillType[output.type] =
                        (predictedByFillType[output.type] or 0.0) + predicted
                end
            end
        end
    end

    for fillTypeId, predictedAmount in pairs(predictedByFillType) do
        local mode =
            productionPoint:getOutputDistributionMode(fillTypeId)

        -- Emergency palletization is deliberately limited to DISTRIBUTING
        -- (AUTO_DELIVER). KEEP continues to use the stock pallet behavior.
        if mode == ProductionPoint.OUTPUT_MODE.AUTO_DELIVER then
            local palletData =
                productionPoint.outputFillTypeIdsToPallets[fillTypeId]

            if palletData ~= nil and palletData.capacity ~= nil then
                local freeCapacity =
                    productionPoint.storage:getFreeCapacity(fillTypeId)

                if predictedAmount > freeCapacity then
                    local shortage = predictedAmount - freeCapacity
                    local requiredPallets =
                        math.ceil(shortage / palletData.capacity)

                    local storageLevel =
                        productionPoint.storage:getFillLevel(fillTypeId)

                    local availableFullPallets =
                        math.floor(storageLevel / palletData.capacity)

                    local palletsToSpawn =
                        math.min(requiredPallets, availableFullPallets)

                    Logging.info(
                        "%s [%s] EMERGENCY PALLET CHECK: hour=%s period=%s fillType=%s predicted=%.3f free=%.3f shortage=%.3f palletCapacity=%.3f required=%d availableFull=%d spawn=%d",
                        LOG_PREFIX,
                        tostring(spec.logId),
                        tostring(currentHour),
                        tostring(currentPeriod),
                        tostring(fillTypeId),
                        predictedAmount,
                        freeCapacity,
                        shortage,
                        palletData.capacity,
                        requiredPallets,
                        availableFullPallets,
                        palletsToSpawn
                    )

                    if palletsToSpawn > 0
                        and spec.emergencyPalletJobs[fillTypeId] == nil
                        and not productionPoint.waitingForPalletToSpawn
                        and g_time > productionPoint.palletSpawnCooldown then

                        spec.emergencyPalletJobs[fillTypeId] = {
                            remaining = palletsToSpawn,
                            planned = palletsToSpawn,
                            spawned = 0,
                            hour = currentHour,
                            period = currentPeriod,
                            autoDeliver = true
                        }

                        spawnNextEmergencyPallet(self, fillTypeId)
                    end
                end
            end
        end
    end
end


-- Adds the fertilizer catalyst to the stock recipe renderer without making it
-- a persistent production input. The synthetic input exists only while
-- InGameMenuProductionFrame populates the recipeCell.
function PlaceableGreenhouseSeasonal.productionMenuPopulateCell(
    frame,
    superFunc,
    list,
    section,
    index,
    cell)

    local production = frame.selectedProduction
    local productionPoint = frame.selectedProductionPoint

    local isRecipeCell =
        list == frame.detailsList
        and cell ~= nil
        and cell.name == "recipeCell"
        and production ~= nil
        and productionPoint ~= nil

    local spec = nil
    local entry = nil
    local syntheticInput = nil

    if isRecipeCell then
        local placeable = productionPoint.owningPlaceable
        spec = placeable ~= nil and placeable[SPEC_TABLE] or nil
        entry = spec ~= nil and spec.productions[production.id] or nil

        if entry ~= nil
            and entry.hasFertilizerCatalyst
            and entry.fertilizerFillType ~= nil then

            syntheticInput = {
                type = entry.fertilizerFillType,
                amount = entry.fertilizerPerCycle or 1.0,
                greenhouseSeasonalVisualCatalyst = true
            }

            -- Temporarily let the stock recipe renderer see the catalyst.
            table.insert(production.inputs, syntheticInput)
        end
    end

    -- Stock FS25 renders the whole recipe here.
    superFunc(frame, list, section, index, cell)

    -- Remove the temporary input immediately. Production logic never sees it.
    if syntheticInput ~= nil then
        for i = #production.inputs, 1, -1 do
            if production.inputs[i] == syntheticInput then
                table.remove(production.inputs, i)
                break
            end
        end
    end

    if not isRecipeCell or entry == nil or syntheticInput == nil then
        return
    end

    local fillType =
        g_fillTypeManager:getFillTypeByIndex(entry.fertilizerFillType)

    if fillType == nil then
        return
    end

    local fertilizerLevel =
        productionPoint.storage:getFillLevel(entry.fertilizerFillType)

    local requiredAmount = math.max(entry.fertilizerPerCycle or 0.0, 0.0)
    local boostAvailable =
        requiredAmount <= 0.0 or fertilizerLevel >= requiredAmount

    -- Round the displayed percentage explicitly to avoid float artifacts
    -- such as fertilizerFactor=1.8 being rendered as +79%.
    local boostPercentRaw =
        math.max(((entry.fertilizerFactor or 1.0) - 1.0) * 100.0, 0.0)
    local boostPercent = math.floor(boostPercentRaw + 0.5)

    -------------------------------------------------------------------------
    -- Input side: the stock renderer created the catalyst as the last item.
    -------------------------------------------------------------------------
    local inputLayout = cell:getAttribute("inputLayout")
    local catalystItem =
        inputLayout ~= nil
        and inputLayout.elements ~= nil
        and inputLayout.elements[#inputLayout.elements]
        or nil

    if catalystItem ~= nil then
        local amountElement = catalystItem:getDescendantByName("amount")
        local nameElement = catalystItem:getDescendantByName("name")

        -- Keep the requested compact form: "1 x Удобрение (+80%)"
        if nameElement ~= nil then
            nameElement:setText(
                string.format(
                    "x %s (+%s%%)",
                    tostring(fillType.title),
                    g_i18n:formatNumber(boostPercent, 0)
                )
            )
        end

        -- Green when the booster can work, red when it cannot.
        local r, g, b, a
        if boostAvailable then
            r, g, b, a = 0.305, 0.85, 0.10, 1.0
        else
            r, g, b, a = 1.0, 0.0, 0.0, 1.0
        end

        if amountElement ~= nil and amountElement.setTextColor ~= nil then
            amountElement:setTextColor(r, g, b, a)
        end
        if nameElement ~= nil and nameElement.setTextColor ~= nil then
            nameElement:setTextColor(r, g, b, a)
        end
    end

    -------------------------------------------------------------------------
    -- Output side: append the *additional* amount produced by fertilizer.
    -- Example: base 10, factor 1.8 -> "10 (+8) x Помидоры".
    -------------------------------------------------------------------------
    local outputLayout = cell:getAttribute("outputLayout")
    local outputElements =
        outputLayout ~= nil and outputLayout.elements or nil

    if outputElements ~= nil then
        for outputIndex, output in ipairs(production.outputs) do
            local outputItem = outputElements[outputIndex]

            if outputItem ~= nil then
                local amountElement =
                    outputItem:getDescendantByName("amount")

                if amountElement ~= nil then
                    local bonusAmount =
                        output.amount
                        * math.max((entry.fertilizerFactor or 1.0) - 1.0, 0.0)

                    amountElement:setText(
                        string.format(
                            "%s (+%s)",
                            g_i18n:formatNumber(output.amount, 2),
                            g_i18n:formatNumber(bonusAmount, 2)
                        )
                    )
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


end

-- ProductionPoint info HUD wrapper. The stock method creates rows with
-- production.name/status. We decorate only rows belonging to this greenhouse.
function PlaceableGreenhouseSeasonal.productionPointUpdateInfo(
    productionPoint,
    superFunc,
    infoTable)

    local firstNewRow = #infoTable + 1
    superFunc(productionPoint, infoTable)

    local placeable = productionPoint.owningPlaceable
    local spec = placeable ~= nil and placeable[SPEC_TABLE] or nil

    if spec == nil then
        return
    end

    -- ProductionPoint:updateInfo rows do not expose an image/overlay field;
    -- therefore the fertilizer state is represented by a compact text marker.
    for _, production in ipairs(productionPoint.activeProductions) do
        local entry = spec.productions[production.id]

        if entry ~= nil then
            local originalTitle =
                production.name
                or g_fillTypeManager:getFillTypeTitleByIndex(
                    production.primaryProductFillType
                )

            local efficiency =
                math.floor(
                    math.clamp(entry.finalFactor or 0.0, 0.0, 1.0)
                    * 100
                    + 0.5
                )

            local fertilizerMarker =
                entry.hasFertilizerCatalyst
                and entry.fertilizerActive
                and " [Удобр.]"
                or ""

            local decoratedTitle =
                string.format(
                    "%s (%d%%)%s",
                    tostring(originalTitle),
                    efficiency,
                    fertilizerMarker
                )

            for rowIndex = firstNewRow, #infoTable do
                local row = infoTable[rowIndex]
                if row ~= nil and row.title == originalTitle then
                    row.title = decoratedTitle
                    break
                end
            end
        end
    end
end


-- Custom ProductionPoint calculation for greenhouseSeasonal catalyst-enabled placeables.
-- It follows the stock FS25 ProductionPoint:updateProduction flow, but treats fertilizer
-- as an optional catalyst:
--   * base inputs are consumed exactly as normal;
--   * fertilizer never blocks production;
--   * fertilizer is consumed only for actually performed cycles;
--   * only output amount is multiplied for the fertilized fraction of those cycles.
function PlaceableGreenhouseSeasonal.productionPointUpdateProduction(productionPoint, superFunc)
    local placeable = productionPoint.owningPlaceable
    local spec = placeable ~= nil and placeable[SPEC_TABLE] or nil

    if spec == nil or not spec.hasFertilizerCatalyst then
        return superFunc(productionPoint)
    end

    if productionPoint.lastUpdatedTime == nil then
        productionPoint.lastUpdatedTime = g_time
        return
    end

    local dt = g_time - productionPoint.lastUpdatedTime
    local clampedDt = math.clamp(dt, 0, 30000)
    local timeAdjustment = g_currentMission.environment.timeAdjustment
    local numActiveProductions = #productionPoint.activeProductions

    if numActiveProductions > 0 then
        local minuteFactorTimescaledDt =
            clampedDt * productionPoint.minuteFactorTimescaled * timeAdjustment
        local minuteFactorDt =
            clampedDt / 60000 * timeAdjustment

        for i = 1, numActiveProductions do
            local production = productionPoint.activeProductions[i]
            local entry = spec.productions[production.id]

            local cyclesTimescaled =
                production.cyclesPerMinute * minuteFactorTimescaledDt
            local cyclesNoTimescale =
                production.cyclesPerMinute * minuteFactorDt

            local enoughInputResources = true
            local enoughOutputSpace = true

            for x = 1, #production.inputs do
                local input = production.inputs[x]
                local fillLevel = productionPoint:getFillLevel(input.type)
                productionPoint.inputFillLevels[input] = fillLevel

                if productionPoint.isOwned
                    and fillLevel < input.amount * cyclesNoTimescale then

                    enoughInputResources = false

                    if production.status ~= ProductionPoint.PROD_STATUS.MISSING_INPUTS then
                        production.status = ProductionPoint.PROD_STATUS.MISSING_INPUTS
                        productionPoint.owningPlaceable:productionStatusChanged(
                            production,
                            ProductionPoint.PROD_STATUS.MISSING_INPUTS
                        )
                        productionPoint:setProductionStatus(
                            production.id,
                            production.status
                        )
                    end
                    break
                end
            end

            local throughputDivisor =
                productionPoint.sharedThroughputCapacity
                and numActiveProductions
                or 1

            local actualCycles = cyclesTimescaled / throughputDivisor

            local fertilizerAvailable = 0
            local fertilizedCycles = 0
            local fertilizerFactor = 1.0

            if entry ~= nil
                and entry.hasFertilizerCatalyst
                and actualCycles > 0 then

                fertilizerAvailable =
                    productionPoint.storage:getFillLevel(entry.fertilizerFillType)

                fertilizedCycles = math.min(
                    actualCycles,
                    fertilizerAvailable / entry.fertilizerPerCycle
                )

                if fertilizedCycles > 0 then
                    local fertilizedShare = fertilizedCycles / actualCycles
                    fertilizerFactor =
                        1.0 + (entry.fertilizerFactor - 1.0) * fertilizedShare
                end
            end

            if enoughInputResources and productionPoint.isOwned then
                for x = 1, #production.outputs do
                    local output = production.outputs[x]
                    local outputAmount = output.amount * fertilizerFactor

                    -- Preserve the stock game's conservative capacity check:
                    -- it checks against cyclesTimescaled before shared throughput division.
                    if not output.sellDirectly
                        and productionPoint.storage:getFreeCapacity(output.type)
                            < outputAmount * cyclesTimescaled then

                        enoughOutputSpace = false

                        if production.status ~= ProductionPoint.PROD_STATUS.NO_OUTPUT_SPACE then
                            production.status = ProductionPoint.PROD_STATUS.NO_OUTPUT_SPACE
                            productionPoint:setProductionStatus(
                                production.id,
                                production.status
                            )
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

            if not productionPoint.isOwned
                or enoughInputResources and enoughOutputSpace then

                for x = 1, #production.inputs do
                    local input = production.inputs[x]

                    if productionPoint.loadingStation == nil then
                        local fillLevel =
                            productionPoint.inputFillLevels[input]

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
                    if entry ~= nil
                        and entry.hasFertilizerCatalyst
                        and fertilizedCycles > 0 then

                        local fertilizerUsed =
                            fertilizedCycles * entry.fertilizerPerCycle

                        local currentFertilizer =
                            productionPoint.storage:getFillLevel(
                                entry.fertilizerFillType
                            )

                        productionPoint.storage:setFillLevel(
                            math.max(currentFertilizer - fertilizerUsed, 0),
                            entry.fertilizerFillType
                        )

                        if not entry.fertilizerActive then
                            entry.fertilizerActive = true
                            Logging.info(
                                "%s '%s' (%s): fertilizer catalyst ACTIVE, factor=%.2f",
                                LOG_PREFIX,
                                tostring(production.name or production.id),
                                tostring(production.id),
                                entry.fertilizerFactor
                            )
                        end
                    elseif entry ~= nil
                        and entry.hasFertilizerCatalyst
                        and entry.fertilizerActive then

                        entry.fertilizerActive = false
                        Logging.info(
                            "%s '%s' (%s): fertilizer catalyst INACTIVE",
                            LOG_PREFIX,
                            tostring(production.name or production.id),
                            tostring(production.id)
                        )
                    end

                    for x = 1, #production.outputs do
                        local output = production.outputs[x]

                        -- Mathematically equivalent to:
                        -- base output for all cycles +
                        -- bonus only for fertilized cycles.
                        local producedAmount =
                            output.amount
                            * (
                                actualCycles
                                + fertilizedCycles
                                    * (entry ~= nil
                                        and entry.hasFertilizerCatalyst
                                        and (entry.fertilizerFactor - 1.0)
                                        or 0.0)
                            )

                        -- TEST HOOK: accumulate the exact output calculated by this
                        -- ProductionPoint:updateProduction() call. This does not
                        -- change storage, cycles, fertilizer use, or production logic.
                        local owningPlaceable = productionPoint.owningPlaceable
                        if owningPlaceable ~= nil then
                            local greenhouseSpec =
                                owningPlaceable[PlaceableGreenhouseSeasonal.SPEC_TABLE]

                            if greenhouseSpec ~= nil then
                                greenhouseSpec.hourlyProducedOutput =
                                    greenhouseSpec.hourlyProducedOutput or {}

                                local productionIdForLog =
                                    tostring(production.id or production.name or "unknown")

                                greenhouseSpec.hourlyProducedOutput[productionIdForLog] =
                                    (greenhouseSpec.hourlyProducedOutput[productionIdForLog] or 0.0)
                                    + producedAmount
                            end
                        end

                        if output.sellDirectly then
                            if productionPoint.isServer then
                                productionPoint.soldFillTypesToPayOut[output.type] =
                                    productionPoint.soldFillTypesToPayOut[output.type]
                                    + producedAmount
                            end
                        else
                            local fillLevel =
                                productionPoint.storage:getFillLevel(output.type)

                            productionPoint.storage:setFillLevel(
                                fillLevel + producedAmount,
                                output.type
                            )
                        end
                    end
                end

                if production.status ~= ProductionPoint.PROD_STATUS.RUNNING then
                    production.status = ProductionPoint.PROD_STATUS.RUNNING
                    productionPoint.owningPlaceable:productionStatusChanged(
                        production,
                        production.status
                    )
                    ProductionPointProductionStatusEvent.sendEvent(
                        productionPoint,
                        production.index,
                        production.status
                    )
                end

                table.clear(productionPoint.inputFillLevels)
            end
        end
    end

    -- Stock pallet spawning logic.
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

                local fillLevel =
                    productionPoint.storage:getFillLevel(fillTypeId)

                if fillLevel > 0 then
                    local pallet =
                        productionPoint.outputFillTypeIdsToPallets[fillTypeId]

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

    productionPoint.lastUpdatedTime = g_time
end


function PlaceableGreenhouseSeasonal:getNeedHourChanged(superFunc)
    local spec = self[SPEC_TABLE]
    local needHourChanged =
        spec ~= nil
        and (spec.hasTemperatureProductions or spec.hasFertilizerCatalyst)

    if spec ~= nil and not spec.needHourChangedLogged then
        spec.needHourChangedLogged = true
        Logging.info(
            "%s getNeedHourChanged: version=%s result=%s tempProfiles=%s catalyst=%s file=%s",
            LOG_PREFIX,
            PlaceableGreenhouseSeasonal.VERSION,
            tostring(needHourChanged),
            tostring(spec.hasTemperatureProductions),
            tostring(spec.hasFertilizerCatalyst),
            tostring(self.configFileName)
        )
    end

    if needHourChanged then
        return true
    end

    return superFunc(self)
end

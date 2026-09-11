--[[
    ProductionActiveVisuals.lua

    Universal visual-node binding for ordinary FS25 ProductionPoint recipes.

    XML:
        <production id="cow" ...>
            ...
            <activeVisuals>
                <visual node="beefVisNodes_output"/>
            </activeVisuals>
        </production>

    Visuals are visible only while the matching production is enabled and the
    ProductionPoint is finalized. Vanilla ProductionPoint already synchronizes
    production state in multiplayer; this script only mirrors that state locally.
]]

ProductionActiveVisuals = ProductionActiveVisuals or {}
ProductionActiveVisuals.VERSION = "0.1.0.0"
ProductionActiveVisuals.DEBUG = false

local LOG_PREFIX = "[ProductionActiveVisuals]"
local DATA_KEY = "activeVisualNodes"

local function debugLog(formatString, ...)
    if ProductionActiveVisuals.DEBUG then
        Logging.info(LOG_PREFIX .. " " .. formatString, ...)
    end
end

local function registerXMLPaths(schema, basePath)
    schema:register(
        XMLValueType.NODE_INDEX,
        basePath .. ".productions.production(?).activeVisuals.visual(?)#node",
        "Node visible while this production is enabled"
    )
end

local function setProductionVisualState(productionPoint, production, enabled)
    if productionPoint == nil or production == nil or not productionPoint.isClient then
        return
    end

    local nodes = production[DATA_KEY]
    if nodes == nil then
        return
    end

    local visible = enabled == true and productionPoint.isFinalized ~= false
    for _, node in ipairs(nodes) do
        if node ~= nil and node ~= 0 and entityExists(node) then
            setVisibility(node, visible)
        end
    end
end

local function refreshAll(productionPoint)
    if productionPoint == nil or not productionPoint.isClient then
        return
    end

    for _, production in ipairs(productionPoint.productions or {}) do
        setProductionVisualState(
            productionPoint,
            production,
            productionPoint:getIsProductionEnabled(production.id)
        )
    end
end

local function loadVisuals(productionPoint, xmlFile, key, components, i3dMappings)
    if not productionPoint.isClient then
        return
    end

    local count = 0

    xmlFile:iterate(key .. ".productions.production", function(_, productionKey)
        local productionId = xmlFile:getValue(productionKey .. "#id")
        local production = productionId ~= nil and productionPoint.productionsIdToObj[productionId] or nil
        if production == nil then
            return
        end

        local nodes = {}
        xmlFile:iterate(productionKey .. ".activeVisuals.visual", function(_, visualKey)
            local node = xmlFile:getValue(visualKey .. "#node", nil, components, i3dMappings)
            if node == nil then
                Logging.xmlWarning(
                    xmlFile,
                    "%s Unable to resolve active visual node in '%s' for production '%s'.",
                    LOG_PREFIX,
                    tostring(visualKey),
                    tostring(productionId)
                )
            else
                table.insert(nodes, node)
                setVisibility(node, false)
                count = count + 1
            end
        end)

        if #nodes > 0 then
            production[DATA_KEY] = nodes
        end
    end)

    if count > 0 then
        debugLog("ProductionPoint '%s': loaded %d active visual node(s)", tostring(productionPoint:getName()), count)
    end
end

function ProductionActiveVisuals.productionPointLoad(productionPoint, superFunc, components, xmlFile, key, customEnv, i3dMappings)
    local result = superFunc(productionPoint, components, xmlFile, key, customEnv, i3dMappings)
    if result then
        loadVisuals(productionPoint, xmlFile, key, components, i3dMappings)
    end
    return result
end

function ProductionActiveVisuals.productionPointSetProductionState(productionPoint, superFunc, productionId, state, noEventSend)
    superFunc(productionPoint, productionId, state, noEventSend)

    local production = productionPoint.productionsIdToObj ~= nil
        and productionPoint.productionsIdToObj[productionId]
        or nil

    if production ~= nil then
        setProductionVisualState(productionPoint, production, state)
    end
end

function ProductionActiveVisuals.productionPointUpdateFxState(productionPoint, superFunc)
    superFunc(productionPoint)
    refreshAll(productionPoint)
end

function ProductionActiveVisuals.install()
    if ProductionActiveVisuals.installed then
        return
    end

    ProductionActiveVisuals.installed = true

    ProductionPoint.registerXMLPaths = Utils.appendedFunction(
        ProductionPoint.registerXMLPaths,
        registerXMLPaths
    )

    ProductionPoint.load = Utils.overwrittenFunction(
        ProductionPoint.load,
        ProductionActiveVisuals.productionPointLoad
    )

    ProductionPoint.setProductionState = Utils.overwrittenFunction(
        ProductionPoint.setProductionState,
        ProductionActiveVisuals.productionPointSetProductionState
    )

    ProductionPoint.updateFxState = Utils.overwrittenFunction(
        ProductionPoint.updateFxState,
        ProductionActiveVisuals.productionPointUpdateFxState
    )

    Logging.info("%s installed v%s", LOG_PREFIX, ProductionActiveVisuals.VERSION)
end

ProductionActiveVisuals.install()

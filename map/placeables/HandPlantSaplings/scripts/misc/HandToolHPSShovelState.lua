--
-- Author: GtX | Andy
-- Date: 01.04.2025
-- Revision: FS25-01
--

HandToolHPSShovelState = {}

HandToolHPSShovelState.INVALID = 1
HandToolHPSShovelState.UNOWNED_LAND = 2
HandToolHPSShovelState.RESTICTED_ZONE = 3
HandToolHPSShovelState.READY = 4
HandToolHPSShovelState.PLANTING = 5
HandToolHPSShovelState.NONE = 6 -- Position matters as states greater than this (6) allow placeholder visibility.
HandToolHPSShovelState.FLIGHT_ACTIVE = 7
HandToolHPSShovelState.STORAGE_IN_RANGE = 8
HandToolHPSShovelState.CONSTRUCTION_SCREEN_OPEN = 9

Enum(HandToolHPSShovelState)

function HandToolHPSShovelState.getColour(state)
    if state == HandToolHPSShovelState.NONE then
        return Color.PRESETS.WHITE
    end

    if state == HandToolHPSShovelState.READY then
        return Color.PRESETS.GREEN
    end

    if state == HandToolHPSShovelState.PLANTING then
        return Color.PRESETS.DEEPSKYBLUE
    end

    -- Not sure Red is any good her but I think the other colours are okay, hopefully someone lets me know if they are not.
    if HandPlantSaplingsManager.USE_COLORBLIND_MODE then
        return Color.PRESETS.YELLOW
    end

    return Color.PRESETS.RED
end

UazUniversalAutoloadCompat = {}

local UAZ_CONFIG_SUFFIXES = {
    "map/vehicles/UAZ_Forester/UAZ_3303_forester.xml",
    "map/vehicles/UAZ_Forester/UAZ_3303_forester2.xml"
}

local FALLBACK_LOAD_AREA = {
    offset = {0, 0.83, -1.10},
    width = 2.05,
    length = 3.20,
    height = 1.65
}

function UazUniversalAutoloadCompat.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(TensionBelts, specializations)
end

function UazUniversalAutoloadCompat.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", UazUniversalAutoloadCompat)
end

local function isTargetUaz(configFileName)
    local normalized = tostring(configFileName or ""):gsub("\\", "/")

    for _, suffix in ipairs(UAZ_CONFIG_SUFFIXES) do
        if normalized:sub(-#suffix) == suffix then
            return true
        end
    end

    return false
end

function UazUniversalAutoloadCompat:onLoad(savegame)
    if UniversalAutoload == nil
        or UniversalAutoloadManager == nil
        or UniversalAutoload.VEHICLE_CONFIGURATIONS == nil
        or UniversalAutoloadManager.cleanConfigFileName == nil then
        return
    end

    local configFileName = UniversalAutoloadManager.cleanConfigFileName(self.configFileName)
    if not isTargetUaz(configFileName) then
        return
    end

    local allKey = UniversalAutoload.ALL or "ALL"
    local configurations = UniversalAutoload.VEHICLE_CONFIGURATIONS
    local configGroup = configurations[configFileName]
    local existingConfig = configGroup ~= nil and configGroup[allKey] or nil

    if existingConfig ~= nil
        and existingConfig.loadArea ~= nil
        and #existingConfig.loadArea > 0 then
        return
    end

    configGroup = configGroup or {}
    configurations[configFileName] = configGroup

    configGroup[allKey] = {
        configFileName = configFileName,
        selectedConfigs = allKey,
        isLogTrailer = true,
        loadArea = {
            {
                offset = {
                    FALLBACK_LOAD_AREA.offset[1],
                    FALLBACK_LOAD_AREA.offset[2],
                    FALLBACK_LOAD_AREA.offset[3]
                },
                width = FALLBACK_LOAD_AREA.width,
                length = FALLBACK_LOAD_AREA.length,
                height = FALLBACK_LOAD_AREA.height
            }
        }
    }

    Logging.info("[UazUniversalAutoloadCompat] Added fallback UAL log loading area for '%s'", configFileName)
end

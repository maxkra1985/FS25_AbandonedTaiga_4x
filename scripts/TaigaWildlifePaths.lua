-- Wildlife companion assets are read directly by the engine. $mapdir$ is not
-- expanded there. Resolve model paths before the wildlife list is loaded,
-- including when the map itself is mounted from a ZIP archive.
TaigaWildlifePaths = {}
TaigaWildlifePaths.SPECIES = {"boar", "fox", "wolf", "bear", "deer2"}

local function normalized(path)
    return path:gsub("\\", "/"):gsub("/+$", "")
end

local function getString(xml, key)
    if type(xml) == "table" then
        return xml:getString(key)
    end
    return getXMLString(xml, key)
end

local function setString(xml, key, value)
    if type(xml) == "table" then
        xml:setString(key, value)
    else
        setXMLString(xml, key, value)
    end
end

local function pack(...)
    return {n=select("#", ...), ...}
end

local function copyConfig(source, destination)
    if not fileExists(source) then
        Logging.error("[TaigaWildlifePaths] Config missing: %s", source)
        return nil
    end
    if copyFile(source, destination, true) == false or not fileExists(destination) then
        Logging.error("[TaigaWildlifePaths] Cannot copy config to: %s", destination)
        return nil
    end
    local xml = loadXMLFile("taigaWildlifeResolved", destination)
    if xml == nil or xml == 0 then
        Logging.error("[TaigaWildlifePaths] Cannot open copied config: %s", destination)
        return nil
    end
    return xml
end

function TaigaWildlifePaths.prepare(baseDirectory)
    local directory = getUserProfileAppPath() .. "modSettings/"
    createFolder(directory)
    directory = directory .. "FS25_AbandonedTaiga_4x_wildlife/"
    createFolder(directory)
    local speciesFiles = {}

    for _, name in ipairs(TaigaWildlifePaths.SPECIES) do
        local model = Utils.getFilename("character/animals/wild/" .. name .. "/" .. name .. ".i3d", baseDirectory)
        if not fileExists(model) then
            Logging.error("[TaigaWildlifePaths] Model missing in map: %s", model)
            return nil
        end
        local source = Utils.getFilename("character/species/" .. name .. ".xml", baseDirectory)
        local destination = directory .. name .. ".xml"
        local xml = copyConfig(source, destination)
        if xml == nil then
            return nil
        end
        setXMLString(xml, "species.companion.asset#filename", model)
        saveXMLFile(xml)
        delete(xml)
        speciesFiles["character/species/" .. name .. ".xml"] = destination
        Logging.info("[TaigaWildlifePaths] %s model: %s", name, model)
    end

    local destination = directory .. "wildlife.xml"
    local xml = copyConfig(Utils.getFilename("config/wildlife.xml", baseDirectory), destination)
    if xml == nil then
        return nil
    end
    local index = 0
    local count = 0
    while hasXMLProperty(xml, string.format("wildlife.species.species(%d)", index)) do
        local key = string.format("wildlife.species.species(%d)#filename", index)
        local filename = getXMLString(xml, key)
        local replacement = speciesFiles[filename]
        if replacement ~= nil then
            setXMLString(xml, key, replacement)
            count = count + 1
        end
        index = index + 1
    end
    if count ~= #TaigaWildlifePaths.SPECIES then
        delete(xml)
        Logging.error("[TaigaWildlifePaths] Expected %d custom species, found %d", #TaigaWildlifePaths.SPECIES, count)
        return nil
    end
    saveXMLFile(xml)
    delete(xml)
    local resolvedFiles = {[destination] = true}
    for _, speciesFilename in pairs(speciesFiles) do
        resolvedFiles[speciesFilename] = true
    end
    return destination, resolvedFiles
end

function TaigaWildlifePaths.loadMapData(manager, superFunc, mapXML, ...)
    local mission = g_currentMission
    local baseDirectory = TaigaWildlifePaths.baseDirectory
    if mission == nil or mission.baseDirectory == nil
        or normalized(mission.baseDirectory) ~= normalized(baseDirectory) then
        return superFunc(manager, mapXML, ...)
    end
    local key = "map.wildlife#filename"
    local original = getString(mapXML, key)
    if original == nil
        or normalized(Utils.getFilename(original, baseDirectory))
            ~= normalized(Utils.getFilename("config/wildlife.xml", baseDirectory)) then
        return superFunc(manager, mapXML, ...)
    end
    local filename, resolvedFiles = TaigaWildlifePaths.prepare(baseDirectory)
    if filename == nil then
        Logging.error("[TaigaWildlifePaths] Could not prepare wildlife configuration")
        return superFunc(manager, mapXML, ...)
    end
    setString(mapXML, key, filename)
    -- Utils.getFilename prefixes even Windows absolute filenames with the map
    -- directory. Bypass that only for the XML files prepared above and
    -- only during this synchronous load; stock/mod paths keep normal handling.
    local getFilename = Utils.getFilename
    Utils.getFilename = function(path, directory, ...)
        if resolvedFiles[path] then
            return path, false
        end
        return getFilename(path, directory, ...)
    end
    local args = pack(...)
    local result = pack(pcall(superFunc, manager, mapXML, unpack(args, 1, args.n)))
    Utils.getFilename = getFilename
    -- Restore the map XML in memory even if the native loader reports an error.
    -- The map on disk and all spawning settings stay unchanged.
    setString(mapXML, key, original)
    if not result[1] then
        error(result[2], 0)
    end
    if result[2] == false then
        Logging.error("[TaigaWildlifePaths] Wildlife loader returned false for: %s", filename)
    else
        Logging.info("[TaigaWildlifePaths] Wildlife configuration load returned %s: %s", tostring(result[2]), filename)
    end
    return unpack(result, 2, result.n)
end

function TaigaWildlifePaths.install(baseDirectory)
    TaigaWildlifePaths.baseDirectory = baseDirectory
    if WildlifeManager == nil or type(WildlifeManager.loadMapData) ~= "function" then
        Logging.error("[TaigaWildlifePaths] WildlifeManager.loadMapData is unavailable")
        return false
    end
    if WildlifeManager.taigaResolvedPathsInstalled then
        return true
    end
    WildlifeManager.loadMapData = Utils.overwrittenFunction(WildlifeManager.loadMapData, TaigaWildlifePaths.loadMapData)
    WildlifeManager.taigaResolvedPathsInstalled = true
    Logging.info("[TaigaWildlifePaths] Installed wildlife model path fix v1.1.0")
    return true
end

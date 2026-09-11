-- Lampovo Project ^ω^ Average Enjoyer

addTreeTypes = {}

local modDir = g_currentModDirectory
local modName = g_currentModName

function addTreeTypes.loadDefaultTypes(self, superFunc, missionInfo, baseDirectory)
    superFunc(self, missionInfo, baseDirectory)

    local xmlFile = loadXMLFile("treeTypes", modDir .. "map/trees/maps_treeTypes.xml")
    g_treePlantManager:loadTreeTypes(xmlFile, missionInfo, modDir, false)

    delete(xmlFile)
end

TreePlantManager.loadDefaultTypes = Utils.overwrittenFunction(TreePlantManager.loadDefaultTypes, addTreeTypes.loadDefaultTypes)
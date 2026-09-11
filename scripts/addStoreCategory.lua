-- Lampovo Project ^ω^ Average Enjoyer

loadStoreCategories = {}

local modDir = g_currentModDirectory
local modName = g_currentModName

function loadStoreCategories.loadMapData(self, superFunc, xmlFile, missionInfo, baseDirectory)
    superFunc(self, xmlFile, missionInfo, baseDirectory)

    local xmlFile = XMLFile.load("ModFile", modDir .. "modDesc.xml")

    for _, key in xmlFile:iterator("modDesc.storeCategories.storeType") do
        g_storeManager:loadCategoryType(xmlFile, key, nil)
    end

    for _, key in xmlFile:iterator("modDesc.storeCategories.storeCategory") do
        g_storeManager:loadCategoryFromXML(xmlFile, key, modDir, modName)
    end

    local defaultRefSize = {256, 256}

    for _, key in xmlFile:iterator("modDesc.constructionCategories.constructionType") do
        local categoryName = xmlFile:getString(key .. "#name")
        local title = xmlFile:getString(key .. "#title")
        if title ~= nil then
            title = g_i18n:convertText(title, modName)
        end
        local iconFilename = xmlFile:getString(key .. "#iconFilename")
        local refSize = xmlFile:getVector(key .. "#refSize", defaultRefSize, 2)
        local iconUVs = GuiUtils.getUVs(xmlFile:getString(key .. "#iconUVs", "0 0 1 1"), refSize)
        local iconSliceId = xmlFile:getString(key .. "#iconSliceId")

        local category = self:getConstructionCategoryByName(categoryName)
        if category == nil then
            g_storeManager:addConstructionCategory(categoryName, title, iconFilename, iconUVs, modDir, iconSliceId)
        else
            Logging.warning("Construction category '%s' already exists.", categoryName)
        end
    end

    for _, key in xmlFile:iterator("modDesc.constructionCategories.constructionCategory") do
        local categoryTypeName = xmlFile:getString(key .. "#type")
        local tabName = xmlFile:getString(key .. "#name")
        local tabTitle = xmlFile:getString(key .. "#title")
        if tabTitle ~= nil then
            tabTitle = g_i18n:convertText(tabTitle, modName)
        end
        local tabIconFilename = xmlFile:getString(key .. "#iconFilename")
        local tabRefSize = xmlFile:getVector(key .. "#refSize", defaultRefSize, 2)
        local tabIconUVs = GuiUtils.getUVs(xmlFile:getString(key .. "#iconUVs", "0 0 1 1"), tabRefSize)
        local tabIconSliceId = xmlFile:getString(key .. "#iconSliceId")

        local tab = self:getConstructionTabByName(tabName, categoryTypeName)
        if tab == nil then
            g_storeManager:addConstructionTab(categoryTypeName, tabName, tabTitle, tabIconFilename, tabIconUVs, modDir, tabIconSliceId)
        else
            Logging.warning("Construction tab '%s' already exists.", tabName)
        end
    end

    xmlFile:delete()

    return true
end

StoreManager.loadMapData = Utils.overwrittenFunction(StoreManager.loadMapData, loadStoreCategories.loadMapData)
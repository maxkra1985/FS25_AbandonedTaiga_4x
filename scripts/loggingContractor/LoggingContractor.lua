--[[
    LoggingContractor

    Главный модуль системы подрядчиков на лесоповал.

    Текущий этап:
    - поиск и регистрация специального триггера карты;
    - получение списка участков, принадлежащих текущей ферме;
    - подсчёт стоящих деревьев выбранного участка по породам;
    - расчёт количества техники, длительности и стоимости подрядчика.

    В дальнейшем модуль также будет отвечать за создание, восстановление и
    завершение активного LoggingContractorJob, а также за сетевую синхронизацию.
]]

LoggingContractor = {}
local LoggingContractor_mt = Class(LoggingContractor)

LoggingContractor.TREES_PER_EQUIPMENT = 100
LoggingContractor.MINUTES_PER_TREE = 1.5
LoggingContractor.EQUIPMENT_RENT_COST = 10000
LoggingContractor.EQUIPMENT_WORK_COST_PER_HOUR = 1000
LoggingContractor.WORKER_COST_PER_HOUR = 2000


-- Создаёт менеджер подрядчиков для текущей миссии.
function LoggingContractor.new(mission)
    local self = setmetatable({}, LoggingContractor_mt)
    self.mission = mission
    self.trigger = nil
    self.activeTreeScan = nil

    return self
end


-- Ищет единственный trigger-node карты, помеченный атрибутом loggingContractor=true.
function LoggingContractor:findTriggerNode()
    local rootNode = getRootNode()
    if rootNode == nil or rootNode == 0 then
        return nil
    end

    local nodes = {rootNode}
    while #nodes > 0 do
        local node = table.remove(nodes)

        if getUserAttribute(node, "loggingContractor") == true then
            return node
        end

        for i = 0, getNumOfChildren(node) - 1 do
            table.insert(nodes, getChildAt(node, i))
        end
    end

    return nil
end


-- Возвращает принадлежащие указанной ферме участки, отсортированные по ID.
function LoggingContractor:getOwnedFarmlands(farmId)
    local result = {}

    if g_farmlandManager == nil or farmId == nil or farmId == FarmlandManager.NO_OWNER_FARM_ID then
        return result
    end

    for _, farmland in pairs(g_farmlandManager:getFarmlands()) do
        if g_farmlandManager:getFarmlandOwner(farmland.id) == farmId then
            table.insert(result, farmland)
        end
    end

    table.sort(result, function(a, b)
        return a.id < b.id
    end)

    return result
end


-- Приводит тип дерева GIANTS к породе, отображаемой в статистике подрядчика.
-- spruce1, spruce2 и базовый SPRUCE объединяются в одну породу «Ель».
function LoggingContractor:getTreeSpecies(treeTypeDesc, splitTypeIndex)
    if treeTypeDesc == nil then
        return string.format("SPLIT_TYPE_%d", splitTypeIndex), string.format("SplitType %d", splitTypeIndex)
    end

    local treeTypeName = string.upper(treeTypeDesc.name or "")
    if treeTypeName == "SPRUCE1" or treeTypeName == "SPRUCE2" or treeTypeName == "SPRUCE" then
        return "SPRUCE", "Ель"
    end

    if treeTypeName == "" then
        treeTypeName = string.format("SPLIT_TYPE_%d", splitTypeIndex)
    end

    return treeTypeName, treeTypeDesc.title or treeTypeName
end


-- Обрабатывает найденный overlapBox объект и учитывает только стоящее дерево
-- выбранного участка. Спиленные части, динамические брёвна и пни исключаются.
function LoggingContractor:treeScanOverlapCallback(transformId)
    local scan = self.activeTreeScan
    if scan == nil or transformId == nil or transformId == 0 then
        return
    end

    if scan.seenNodes[transformId] then
        return
    end

    if not getHasClassId(transformId, ClassIds.MESH_SPLIT_SHAPE) then
        return
    end

    local splitTypeIndex = getSplitType(transformId)
    if splitTypeIndex == 0
        or getRigidBodyType(transformId) ~= RigidBodyType.STATIC
        or getIsSplitShapeSplit(transformId)
        or getUserAttribute(transformId, "isTreeStump") == true then
        return
    end

    scan.seenNodes[transformId] = true

    local x, _, z = getWorldTranslation(transformId)
    if g_farmlandManager:getFarmlandIdAtWorldPosition(x, z) ~= scan.farmlandId then
        return
    end

    local treeTypeDesc = g_treePlantManager:getTreeTypeDescFromSplitType(splitTypeIndex)
    local speciesName, speciesTitle = self:getTreeSpecies(treeTypeDesc, splitTypeIndex)
    local species = scan.bySpecies[speciesName]

    if species == nil then
        species = {
            name = speciesName,
            title = speciesTitle,
            count = 0
        }
        scan.bySpecies[speciesName] = species
    end

    species.count = species.count + 1
    scan.totalCount = scan.totalCount + 1
end


-- Сканирует выбранный принадлежащий ферме участок и возвращает количество
-- стоящих деревьев с разбивкой по породам.
function LoggingContractor:scanFarmlandTrees(farmlandId, farmId)
    if g_farmlandManager == nil or g_treePlantManager == nil then
        return nil, "managerUnavailable"
    end

    local farmland = g_farmlandManager:getFarmlandById(farmlandId)
    if farmland == nil then
        return nil, "farmlandNotFound"
    end

    if farmId == nil then
        farmId = self.mission:getFarmId()
    end

    if g_farmlandManager:getFarmlandOwner(farmlandId) ~= farmId then
        return nil, "farmlandNotOwned"
    end

    local minX, minZ, maxX, maxZ = farmland:getBoundingBox()
    if minX == nil then
        return nil, "farmlandBoundsUnavailable"
    end

    local centerX = (minX + maxX) * 0.5
    local centerZ = (minZ + maxZ) * 0.5
    local halfWidth = math.max((maxX - minX) * 0.5, 0.5)
    local halfDepth = math.max((maxZ - minZ) * 0.5, 0.5)

    self.activeTreeScan = {
        farmlandId = farmlandId,
        totalCount = 0,
        bySpecies = {},
        seenNodes = {}
    }

    -- GIANTS использует тот же набор фильтров для поиска стоящих деревьев:
    -- TREE collision mask, только STATIC и неразделённые MESH_SPLIT_SHAPE.
    -- После overlap принадлежность участку проверяется по мировой позиции дерева.
    overlapBox(
        centerX,
        0,
        centerZ,
        0,
        0,
        0,
        halfWidth,
        self.mission.terrainSize,
        halfDepth,
        "treeScanOverlapCallback",
        self,
        CollisionFlag.TREE,
        false,
        false,
        true,
        false
    )

    local scan = self.activeTreeScan
    self.activeTreeScan = nil

    local species = {}
    for _, data in pairs(scan.bySpecies) do
        table.insert(species, data)
    end

    table.sort(species, function(a, b)
        return a.title < b.title
    end)

    Logging.info("[LoggingContractor] Farmland %d: %d standing trees", farmlandId, scan.totalCount)

    return {
        farmlandId = farmlandId,
        totalCount = scan.totalCount,
        species = species
    }
end


-- Рассчитывает количество техники, округлённое время работы и полную стоимость
-- подрядчика по зафиксированным правилам проекта.
function LoggingContractor:calculateEstimate(treeCount)
    if treeCount == nil or treeCount <= 0 then
        return {
            equipmentCount = 0,
            workHours = 0,
            totalCost = 0
        }
    end

    local equipmentCount = math.ceil(treeCount / LoggingContractor.TREES_PER_EQUIPMENT)
    local workMinutes = (treeCount * LoggingContractor.MINUTES_PER_TREE) / equipmentCount
    local workHours = math.ceil(workMinutes / 60)
    local totalCost = equipmentCount * LoggingContractor.EQUIPMENT_RENT_COST
        + equipmentCount * workHours * LoggingContractor.EQUIPMENT_WORK_COST_PER_HOUR
        + equipmentCount * workHours * LoggingContractor.WORKER_COST_PER_HOUR

    return {
        equipmentCount = equipmentCount,
        workHours = workHours,
        totalCost = totalCost
    }
end


-- Регистрирует клиентский activatable на специальном триггере карты.
function LoggingContractor:initialize()
    if not self.mission:getIsClient() then
        return
    end

    local triggerNode = self:findTriggerNode()
    if triggerNode == nil then
        Logging.warning("[LoggingContractor] Trigger with loggingContractor=true was not found")
        return
    end

    self.trigger = LoggingContractorTrigger.new(triggerNode, self)
    Logging.info("[LoggingContractor] Trigger registered: %s", getName(triggerNode))
end


-- Удаляет зарегистрированный триггер при завершении миссии.
function LoggingContractor:delete()
    self.activeTreeScan = nil

    if self.trigger ~= nil then
        self.trigger:delete()
        self.trigger = nil
    end
end

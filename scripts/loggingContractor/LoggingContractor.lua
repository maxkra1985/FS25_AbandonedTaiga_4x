--[[
    LoggingContractor

    Главный модуль системы подрядчиков на лесоповал.

    Текущий этап:
    - поиск и регистрация специального триггера карты;
    - получение списка участков, принадлежащих текущей ферме;
    - подсчёт стоящих деревьев выбранного участка по породам;
    - расчёт количества техники, длительности и стоимости подрядчика;
    - серверная проверка запроса, списание средств и создание LoggingContractorJob.

    Периодическая обработка деревьев активным договором будет добавлена
    следующим этапом.
]]

LoggingContractor = {}
local LoggingContractor_mt = Class(LoggingContractor)

LoggingContractor.TREES_PER_EQUIPMENT = 100
LoggingContractor.MINUTES_PER_TREE = 2
LoggingContractor.EQUIPMENT_RENT_COST = 24000
LoggingContractor.EQUIPMENT_WORK_COST_PER_HOUR = 1000
LoggingContractor.WORKER_COST_PER_HOUR = 2000
LoggingContractor.VALID_LOG_LENGTHS = {
    [3] = true,
    [6] = true,
    [9] = true,
    [12] = true
}


-- Создаёт менеджер подрядчиков для текущей миссии.
function LoggingContractor.new(mission)
    local self = setmetatable({}, LoggingContractor_mt)
    self.mission = mission
    self.trigger = nil
    self.activeTreeScan = nil
    self.activeJobs = {}
    self.clientJobs = {}
    self.nextJobId = 1

    -- В multiplayer изменения split-shape подрядчика распределяются между
    -- последовательными сетевыми update tick.
    self.networkSyncGeneration = 0
    self.networkMutationGeneration = -1

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

    return {
        farmlandId = farmlandId,
        totalCount = scan.totalCount,
        species = species
    }
end


-- Возвращает расчётное количество техники по правилу одна единица на каждые
-- сто деревьев. Это значение используется как начальное при открытии окна.
function LoggingContractor:getRecommendedEquipmentCount(treeCount)
    if treeCount == nil or treeCount <= 0 then
        return 0
    end

    return math.ceil(treeCount / LoggingContractor.TREES_PER_EQUIPMENT)
end


-- Рассчитывает фактическую длительность работы и стоимость подрядчика.
-- Фактические часы не округляются; для почасовых статей стоимости отдельно
-- используются оплачиваемые часы, округлённые вверх до целого.
function LoggingContractor:calculateEstimate(treeCount, equipmentCount)
    if treeCount == nil or treeCount <= 0 then
        return {
            equipmentCount = 0,
            workHours = 0,
            billableHours = 0,
            rentCost = 0,
            equipmentWorkCost = 0,
            workerCost = 0,
            totalCost = 0
        }
    end

    if equipmentCount == nil then
        equipmentCount = self:getRecommendedEquipmentCount(treeCount)
    end

    equipmentCount = math.max(math.floor(equipmentCount), 1)

    local workMinutes = (treeCount * LoggingContractor.MINUTES_PER_TREE) / equipmentCount
    local workHours = workMinutes / 60
    local billableHours = math.ceil(workHours)

    local rentCost = equipmentCount * LoggingContractor.EQUIPMENT_RENT_COST
    local equipmentWorkCost = equipmentCount * billableHours * LoggingContractor.EQUIPMENT_WORK_COST_PER_HOUR
    local workerCost = equipmentCount * billableHours * LoggingContractor.WORKER_COST_PER_HOUR
    local totalCost = rentCost + equipmentWorkCost + workerCost

    return {
        equipmentCount = equipmentCount,
        workHours = workHours,
        billableHours = billableHours,
        rentCost = rentCost,
        equipmentWorkCost = equipmentWorkCost,
        workerCost = workerCost,
        totalCost = totalCost
    }
end


-- Проверяет допустимость выбранной длины брёвен на сервере независимо от GUI.
function LoggingContractor:isValidLogLength(logLength)
    return LoggingContractor.VALID_LOG_LENGTHS[logLength] == true
end


-- Определяет ферму по сетевому соединению отправителя. Клиентский farmId для
-- заключения договора не используется и поэтому не может быть подменён.
function LoggingContractor:getFarmForConnection(connection)
    if connection == nil or self.mission.userManager == nil or g_farmManager == nil then
        return nil
    end

    local userId = self.mission.userManager:getUserIdByConnection(connection)
    if userId == nil then
        return nil
    end

    return g_farmManager:getFarmByUserId(userId)
end


-- Возвращает true, если на сервере выполняется хотя бы один договор.
-- На клиенте проверяются синхронизированные договоры его фермы.
function LoggingContractor:hasAnyActiveJob()
    local jobs = self.mission:getIsServer() and self.activeJobs or self.clientJobs

    for _, job in pairs(jobs) do
        if job.isActive then
            return true
        end
    end

    return false
end


-- Проверяет рабочее время лесозаготовителей: с 08:00 включительно
-- до 21:00 исключительно. Ночью договор остаётся активным, но таймер
-- выполнения не продвигается.
function LoggingContractor:getIsWorkingTime()
    if self.mission.environment == nil then
        return false
    end

    local hour = self.mission.environment.dayTime / (60 * 60 * 1000)
    return hour >= 8 and hour < 21
end


-- Проверяет, не выполняется ли уже договор этой фермы на том же участке.
-- Это не ограничивает ферму одним договором, но исключает двойную оплату и
-- одновременную обработку одного набора деревьев.
function LoggingContractor:hasActiveJobForFarmland(farmId, farmlandId)
    for _, job in pairs(self.activeJobs) do
        if job.isActive and job.farmId == farmId and job.farmlandId == farmlandId then
            return true
        end
    end

    return false
end


-- Преобразует внутреннюю ошибку сканирования в код сетевого ответа.
function LoggingContractor:getStartResultStateForScanError(errorCode)
    if errorCode == "farmlandNotFound" then
        return LoggingContractorResultEvent.STATE_FARMLAND_NOT_FOUND
    elseif errorCode == "farmlandNotOwned" then
        return LoggingContractorResultEvent.STATE_FARMLAND_NOT_OWNED
    end

    return LoggingContractorResultEvent.STATE_INTERNAL_ERROR
end


-- Выполняет серверную часть заключения договора: определяет ферму отправителя,
-- проверяет право manageContracts, участок и деревья, заново рассчитывает цену,
-- проверяет баланс, списывает средства и создаёт LoggingContractorJob.
function LoggingContractor:startContract(connection, farmlandId, equipmentCount, logLength)
    if not self.mission:getIsServer() then
        return LoggingContractorResultEvent.STATE_INTERNAL_ERROR
    end

    local farm = self:getFarmForConnection(connection)
    if farm == nil or farm.farmId == FarmlandManager.NO_OWNER_FARM_ID then
        return LoggingContractorResultEvent.STATE_FARM_NOT_FOUND
    end

    local farmId = farm.farmId
    if not self.mission:getHasPlayerPermission("manageContracts", connection, farmId) then
        return LoggingContractorResultEvent.STATE_NO_PERMISSION
    end

    equipmentCount = math.floor(equipmentCount or 0)
    if equipmentCount <= 0 then
        return LoggingContractorResultEvent.STATE_INVALID_EQUIPMENT
    end

    if not self:isValidLogLength(logLength) then
        return LoggingContractorResultEvent.STATE_INVALID_LOG_LENGTH
    end

    local scan, errorCode = self:scanFarmlandTrees(farmlandId, farmId)
    if scan == nil then
        return self:getStartResultStateForScanError(errorCode)
    end

    if scan.totalCount <= 0 then
        return LoggingContractorResultEvent.STATE_NO_TREES
    end

    if equipmentCount > scan.totalCount then
        return LoggingContractorResultEvent.STATE_INVALID_EQUIPMENT
    end

    if self:hasActiveJobForFarmland(farmId, farmlandId) then
        return LoggingContractorResultEvent.STATE_ALREADY_ACTIVE
    end

    local estimate = self:calculateEstimate(scan.totalCount, equipmentCount)
    if self.mission:getMoney(farmId) < estimate.totalCost then
        return LoggingContractorResultEvent.STATE_NOT_ENOUGH_MONEY
    end

    local job = LoggingContractorJob.new({
        jobId = self.nextJobId,
        farmId = farmId,
        farmlandId = farmlandId,
        plannedTrees = scan.totalCount,
        equipmentCount = equipmentCount,
        logLength = logLength,
        workHours = estimate.workHours,
        billableHours = estimate.billableHours,
        rentCost = estimate.rentCost,
        equipmentWorkCost = estimate.equipmentWorkCost,
        workerCost = estimate.workerCost,
        totalCost = estimate.totalCost
    })

    if job == nil then
        return LoggingContractorResultEvent.STATE_INTERNAL_ERROR
    end

    -- Списание выполняется только сервером после всех проверок. Для текущего
    -- этапа используется штатная нейтральная финансовая категория OTHER.
    self.mission:addMoney(-estimate.totalCost, farmId, MoneyType.OTHER, true, true)

    self.activeJobs[job.jobId] = job
    self.nextJobId = self.nextJobId + 1

    Logging.info(
        "[LoggingContractor] Contract started: job=%d farm=%d farmland=%d trees=%d equipment=%d logLength=%d cost=%d",
        job.jobId,
        job.farmId,
        job.farmlandId,
        job.plannedTrees,
        job.equipmentCount,
        job.logLength,
        job.totalCost
    )

    return LoggingContractorResultEvent.STATE_SUCCESS, job:getNetworkData()
end


-- Применяет на клиенте подтверждённый сервером результат заключения договора.
-- Успешная задача сохраняется отдельно от server-side activeJobs для будущего HUD.
function LoggingContractor:onStartContractResult(event)
    if event.state == LoggingContractorResultEvent.STATE_SUCCESS then
        self.clientJobs[event.jobId] = LoggingContractorJob.new({
            jobId = event.jobId,
            farmId = event.farmId,
            farmlandId = event.farmlandId,
            plannedTrees = event.plannedTrees,
            equipmentCount = event.equipmentCount,
            logLength = event.logLength,
            workHours = event.workHours,
            billableHours = event.billableHours,
            rentCost = event.rentCost,
            equipmentWorkCost = event.equipmentWorkCost,
            workerCost = event.workerCost,
            totalCost = event.totalCost
        })
    end

    if LoggingContractorDialog ~= nil then
        LoggingContractorDialog.onStartContractResult(event)
    end
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
end


-- Удаляет зарегистрированный триггер и созданные объекты договоров при
-- завершении миссии.
function LoggingContractor:delete()
    self.activeTreeScan = nil

    if self.trigger ~= nil then
        self.trigger:delete()
        self.trigger = nil
    end

    for _, job in pairs(self.activeJobs) do
        job:delete()
    end
    self.activeJobs = {}

    for _, job in pairs(self.clientJobs) do
        job:delete()
    end
    self.clientJobs = {}
end

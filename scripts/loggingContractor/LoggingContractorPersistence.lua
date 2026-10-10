--[[
    LoggingContractorPersistence

    Сохранение и восстановление уже оплаченных договоров на лесоповал.

    Договор хранится отдельным loggingContractor.xml внутри savegame.
    Runtime node-id деревьев не сохраняются: ожидающие цели описываются
    координатами и split type, а после загрузки сопоставляются с текущими
    стоящими деревьями участка.

    Дерево, обработка которого ещё не изменила split-shape, восстанавливается
    как активная processing-задача. Если split-shape уже был изменён, состояние
    PRUNE/BUCK не сериализуется: физический результат сохраняет сама игра, а
    такое дерево при восстановлении считается выполненным подрядчиком.
]]

LoggingContractor.PERSISTENCE_VERSION = 1
LoggingContractor.PERSISTENCE_FILENAME = "loggingContractor.xml"
LoggingContractor.PERSISTENCE_TARGET_TOLERANCE = 0.5


-- Возвращает каталог текущего savegame, если миссия действительно загружена
-- из/в сохранение и путь уже известен движку.
function LoggingContractor:getPersistenceSavegameDirectory()
    local missionInfo = self.mission ~= nil and self.mission.missionInfo or nil
    return missionInfo ~= nil and missionInfo.savegameDirectory or nil
end


-- Возвращает полный путь sidecar-файла подрядчика.
function LoggingContractor:getPersistenceFilename(directory)
    directory = directory or self:getPersistenceSavegameDirectory()
    return directory ~= nil
        and (directory .. "/" .. LoggingContractor.PERSISTENCE_FILENAME)
        or nil
end


-- Формирует устойчивое описание стоящего дерева без сохранения runtime node-id.
function LoggingContractor:getPersistentTargetDescriptor(node, farmlandId)
    if node == nil
        or node == 0
        or not entityExists(node)
        or not self:isStandingContractTarget(node, farmlandId) then
        return nil
    end

    local x, y, z = getWorldTranslation(node)
    return {
        x = x,
        y = y,
        z = z,
        splitTypeName = self:getContractorSplitTypeName(node)
    }
end


-- Сохраняет один список описаний деревьев.
function LoggingContractor:writePersistentTargetList(xmlFile, baseKey, descriptors)
    setXMLInt(xmlFile, baseKey .. "#count", #descriptors)

    for index, descriptor in ipairs(descriptors) do
        local key = string.format("%s.target(%d)", baseKey, index - 1)
        setXMLFloat(xmlFile, key .. "#x", descriptor.x)
        setXMLFloat(xmlFile, key .. "#y", descriptor.y)
        setXMLFloat(xmlFile, key .. "#z", descriptor.z)

        if descriptor.splitTypeName ~= nil then
            setXMLString(xmlFile, key .. "#splitType", descriptor.splitTypeName)
        end
    end
end


-- Читает список описаний деревьев из sidecar-файла.
function LoggingContractor:readPersistentTargetList(xmlFile, baseKey)
    local result = {}
    local count = math.max(getXMLInt(xmlFile, baseKey .. "#count") or 0, 0)

    for index = 0, count - 1 do
        local key = string.format("%s.target(%d)", baseKey, index)
        local x = getXMLFloat(xmlFile, key .. "#x")
        local y = getXMLFloat(xmlFile, key .. "#y")
        local z = getXMLFloat(xmlFile, key .. "#z")

        if x ~= nil and z ~= nil then
            table.insert(result, {
                x = x,
                y = y or 0,
                z = z,
                splitTypeName = getXMLString(xmlFile, key .. "#splitType")
            })
        end
    end

    return result
end


-- Собирает ожидающие и ещё не изменённые деревья. Текущие динамические
-- части уже записывает штатный savegame split-shapes. Такие незавершённые
-- обработки сохраняются счётчиком, но не считаются успешной рубкой.
function LoggingContractor:collectPersistentJobState(job)
    local pending = {}
    local processing = {}
    local seenNodes = {}
    local mutatedProcessingCount = 0

    for _, node in ipairs(job.targetNodes or {}) do
        if not seenNodes[node] then
            local descriptor = self:getPersistentTargetDescriptor(node, job.farmlandId)
            if descriptor ~= nil then
                table.insert(pending, descriptor)
                seenNodes[node] = true
            end
        end
    end

    for _, state in ipairs(job.processingTrees or {}) do
        if state.hadMutation == true then
            mutatedProcessingCount = mutatedProcessingCount + 1
        else
            local node = state.sourceShape
            if node ~= nil and not seenNodes[node] then
                local descriptor = self:getPersistentTargetDescriptor(node, job.farmlandId)
                if descriptor ~= nil then
                    table.insert(processing, descriptor)
                    seenNodes[node] = true
                end
            end
        end
    end

    return pending, processing, mutatedProcessingCount
end


-- Записывает все активные договоры в отдельный XML внутри savegame.
-- Деньги здесь не изменяются: sidecar хранит состояние уже оплаченной работы.
function LoggingContractor:saveToSavegame(directory)
    if self.mission == nil or not self.mission:getIsServer() then
        return false
    end

    local filename = self:getPersistenceFilename(directory)
    if filename == nil then
        return false
    end

    local xmlFile = createXMLFile(
        "loggingContractorPersistence",
        filename,
        "loggingContractor"
    )
    if xmlFile == nil or xmlFile == 0 then
        Logging.warning(
            "[LoggingContractor] Unable to create persistence file '%s'",
            tostring(filename)
        )
        return false
    end

    setXMLInt(
        xmlFile,
        "loggingContractor#version",
        LoggingContractor.PERSISTENCE_VERSION
    )
    setXMLInt(
        xmlFile,
        "loggingContractor#nextJobId",
        self.nextJobId or 1
    )

    local jobs = {}
    for _, job in pairs(self.activeJobs or {}) do
        if job.isActive then
            table.insert(jobs, job)
        end
    end

    table.sort(jobs, function(a, b)
        return a.jobId < b.jobId
    end)

    setXMLInt(xmlFile, "loggingContractor.jobs#count", #jobs)

    local totalTargets = 0
    local totalProcessing = 0
    local totalMutatedProcessing = 0

    for index, job in ipairs(jobs) do
        local key = string.format(
            "loggingContractor.jobs.job(%d)",
            index - 1
        )
        local pending, processing, mutatedProcessingCount =
            self:collectPersistentJobState(job)

        setXMLInt(xmlFile, key .. "#id", job.jobId)
        setXMLInt(xmlFile, key .. "#farmId", job.farmId)
        setXMLInt(xmlFile, key .. "#farmlandId", job.farmlandId)
        setXMLInt(xmlFile, key .. "#plannedTrees", job.plannedTrees)
        setXMLBool(xmlFile, key .. "#onlyMarkedTrees", job.onlyMarkedTrees == true)
        setXMLInt(
            xmlFile,
            key .. "#contractorCutTrees",
            job.contractorCutTrees or 0
        )
        setXMLInt(xmlFile, key .. "#failedTreeCount", job.failedTreeCount or 0)
        setXMLInt(
            xmlFile,
            key .. "#savedRemainingTrees",
            job.remainingTrees or 0
        )
        setXMLInt(xmlFile, key .. "#equipmentCount", job.equipmentCount)
        setXMLInt(xmlFile, key .. "#logLength", job.logLength)
        setXMLFloat(xmlFile, key .. "#workHours", job.workHours or 0)
        setXMLInt(xmlFile, key .. "#billableHours", job.billableHours or 0)
        setXMLInt(xmlFile, key .. "#rentCost", job.rentCost or 0)
        setXMLInt(
            xmlFile,
            key .. "#equipmentWorkCost",
            job.equipmentWorkCost or 0
        )
        setXMLInt(xmlFile, key .. "#workerCost", job.workerCost or 0)
        setXMLInt(xmlFile, key .. "#totalCost", job.totalCost or 0)
        setXMLFloat(
            xmlFile,
            key .. "#processTimerMs",
            job.processTimerMs or 0
        )
        setXMLInt(
            xmlFile,
            key .. "#mutatedProcessingCount",
            mutatedProcessingCount
        )

        if job.routeAnchorX ~= nil and job.routeAnchorZ ~= nil then
            setXMLFloat(xmlFile, key .. "#routeAnchorX", job.routeAnchorX)
            setXMLFloat(xmlFile, key .. "#routeAnchorZ", job.routeAnchorZ)
        end

        self:writePersistentTargetList(
            xmlFile,
            key .. ".targets",
            pending
        )
        self:writePersistentTargetList(
            xmlFile,
            key .. ".processing",
            processing
        )

        totalTargets = totalTargets + #pending
        totalProcessing = totalProcessing + #processing
        totalMutatedProcessing =
            totalMutatedProcessing + mutatedProcessingCount
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)

    Logging.info(
        "[LoggingContractor] Saved %d active contract(s): pending=%d processing=%d completedInProgress=%d",
        #jobs,
        totalTargets,
        totalProcessing,
        totalMutatedProcessing
    )

    return true
end


-- Находит для сохранённого описания ближайшее ещё не использованное стоящее
-- дерево той же породы. Сопоставление выполняется только внутри малого радиуса,
-- поэтому новые деревья участка не становятся целями старого договора.
function LoggingContractor:findPersistentTargetNode(descriptor, candidates, usedNodes)
    local toleranceSq =
        LoggingContractor.PERSISTENCE_TARGET_TOLERANCE
        * LoggingContractor.PERSISTENCE_TARGET_TOLERANCE
    local bestNode = nil
    local bestDistanceSq = toleranceSq

    for _, node in ipairs(candidates) do
        if not usedNodes[node] and entityExists(node) then
            local splitTypeName = self:getContractorSplitTypeName(node)
            if descriptor.splitTypeName == nil
                or descriptor.splitTypeName == ""
                or splitTypeName == descriptor.splitTypeName then
                local x, _, z = getWorldTranslation(node)
                local dx = x - descriptor.x
                local dz = z - descriptor.z
                local distanceSq = dx * dx + dz * dz

                if distanceSq <= bestDistanceSq then
                    bestDistanceSq = distanceSq
                    bestNode = node
                end
            end
        end
    end

    if bestNode ~= nil then
        usedNodes[bestNode] = true
    end

    return bestNode
end


-- Сопоставляет список сохранённых целей с текущими standing split-shapes.
function LoggingContractor:resolvePersistentTargets(descriptors, candidates, usedNodes)
    local nodes = {}
    local missing = 0

    for _, descriptor in ipairs(descriptors) do
        local node = self:findPersistentTargetNode(
            descriptor,
            candidates,
            usedNodes
        )

        if node ~= nil then
            table.insert(nodes, node)
        else
            missing = missing + 1
        end
    end

    return nodes, missing
end


-- Восстанавливает один активный договор без повторного вызова startContract().
-- Поэтому стоимость договора не списывается второй раз.
function LoggingContractor:restorePersistentJob(xmlFile, key)
    local jobId = getXMLInt(xmlFile, key .. "#id")
    local farmId = getXMLInt(xmlFile, key .. "#farmId")
    local farmlandId = getXMLInt(xmlFile, key .. "#farmlandId")
    local plannedTrees = getXMLInt(xmlFile, key .. "#plannedTrees")
    local equipmentCount = getXMLInt(xmlFile, key .. "#equipmentCount")
    local logLength = getXMLInt(xmlFile, key .. "#logLength")

    if jobId == nil
        or farmId == nil
        or farmlandId == nil
        or plannedTrees == nil
        or equipmentCount == nil
        or equipmentCount <= 0
        or not self:isValidLogLength(logLength) then
        Logging.warning(
            "[LoggingContractor] Skipping invalid persisted contract at '%s'",
            tostring(key)
        )
        return nil
    end

    if g_farmManager == nil or g_farmManager:getFarmById(farmId) == nil then
        Logging.warning(
            "[LoggingContractor] Skipping persisted contract %d: farm %s no longer exists",
            jobId,
            tostring(farmId)
        )
        return nil
    end

    if g_farmlandManager == nil
        or g_farmlandManager:getFarmlandById(farmlandId) == nil then
        Logging.warning(
            "[LoggingContractor] Skipping persisted contract %d: farmland %s no longer exists",
            jobId,
            tostring(farmlandId)
        )
        return nil
    end

    local pendingDescriptors =
        self:readPersistentTargetList(xmlFile, key .. ".targets")
    local processingDescriptors =
        self:readPersistentTargetList(xmlFile, key .. ".processing")
    local candidates = self:collectContractTargets(farmlandId, false)
    local usedNodes = {}

    local pendingNodes, missingPending =
        self:resolvePersistentTargets(
            pendingDescriptors,
            candidates,
            usedNodes
        )
    local processingNodes, missingProcessing =
        self:resolvePersistentTargets(
            processingDescriptors,
            candidates,
            usedNodes
        )

    local mutatedProcessingCount =
        math.max(
            getXMLInt(xmlFile, key .. "#mutatedProcessingCount") or 0,
            0
        )
    -- Не превращаем частично обработанный до сохранения ствол в успех.
    local contractorCutTrees = math.min(
        math.max(getXMLInt(xmlFile, key .. "#contractorCutTrees") or 0, 0),
        plannedTrees
    )
    local failedTreeCount =
        math.max(getXMLInt(xmlFile, key .. "#failedTreeCount") or 0, 0)
        + mutatedProcessingCount

    local job = LoggingContractorJob.new({
        jobId = jobId,
        farmId = farmId,
        farmlandId = farmlandId,
        plannedTrees = plannedTrees,
        onlyMarkedTrees =
            getXMLBool(xmlFile, key .. "#onlyMarkedTrees") == true,
        contractorCutTrees = contractorCutTrees,
        failedTreeCount = failedTreeCount,
        remainingTrees = #pendingNodes + #processingNodes,
        equipmentCount = equipmentCount,
        logLength = logLength,
        workHours = getXMLFloat(xmlFile, key .. "#workHours") or 0,
        billableHours = getXMLInt(xmlFile, key .. "#billableHours") or 0,
        rentCost = getXMLInt(xmlFile, key .. "#rentCost") or 0,
        equipmentWorkCost =
            getXMLInt(xmlFile, key .. "#equipmentWorkCost") or 0,
        workerCost = getXMLInt(xmlFile, key .. "#workerCost") or 0,
        totalCost = getXMLInt(xmlFile, key .. "#totalCost") or 0,
        state = LoggingContractorJob.STATE_ACTIVE
    })

    job.targetNodes = pendingNodes
    job.processingTrees = {}
    job.markerStates = {}
    job.processTimerMs =
        math.max(getXMLFloat(xmlFile, key .. "#processTimerMs") or 0, 0)
    job.routeAnchorX = getXMLFloat(xmlFile, key .. "#routeAnchorX")
    job.routeAnchorZ = getXMLFloat(xmlFile, key .. "#routeAnchorZ")

    for _, node in ipairs(job.targetNodes) do
        job.markerStates[node] = self:isContractTargetMarked(node)
    end

    -- Processing-деревья без физических изменений безопасно начинают свой
    -- внутренний state-machine заново с INITIAL_CUT, не ожидая нового 2-минутного такта.
    for _, node in ipairs(processingNodes) do
        local state = self:createContractorTreeProcess(job, node)
        if state ~= nil then
            table.insert(job.processingTrees, state)
        else
            job.remainingTrees = math.max(job.remainingTrees - 1, 0)
            missingProcessing = missingProcessing + 1
        end
    end

    job.remainingTrees = #job.targetNodes + #job.processingTrees
    job.progressBroadcastPending = true
    if mutatedProcessingCount > 0 then
        Logging.warning(
            "[LoggingContractor] Restored job=%d with %d unfinished tree(s): wood preserved; not counted as cut",
            job.jobId, mutatedProcessingCount
        )
    end

    Logging.info(
        "[LoggingContractor] Restored contract: job=%d farm=%d farmland=%d pending=%d processing=%d completedInProgress=%d missing=%d timer=%.0fms",
        job.jobId,
        job.farmId,
        job.farmlandId,
        #job.targetNodes,
        #job.processingTrees,
        mutatedProcessingCount,
        missingPending + missingProcessing,
        job.processTimerMs
    )

    return job
end


-- Загружает sidecar после штатной загрузки карты и split-shapes.
function LoggingContractor:loadFromSavegame()
    if self.mission == nil or not self.mission:getIsServer() then
        return false
    end

    LoggingContractor.installPersistenceSaveHook()

    if self.persistenceLoaded then
        return true
    end
    self.persistenceLoaded = true

    local filename = self:getPersistenceFilename()
    if filename == nil or not fileExists(filename) then
        return true
    end

    local xmlFile = loadXMLFile(
        "loggingContractorPersistence",
        filename
    )
    if xmlFile == nil or xmlFile == 0 then
        Logging.warning(
            "[LoggingContractor] Unable to load persistence file '%s'",
            tostring(filename)
        )
        return false
    end

    local version = getXMLInt(xmlFile, "loggingContractor#version")
    if version ~= LoggingContractor.PERSISTENCE_VERSION then
        Logging.warning(
            "[LoggingContractor] Unsupported persistence version %s in '%s'",
            tostring(version),
            tostring(filename)
        )
        delete(xmlFile)
        return false
    end

    local count =
        math.max(
            getXMLInt(xmlFile, "loggingContractor.jobs#count") or 0,
            0
        )
    local loadedJobs = 0
    local maxJobId = 0

    self.activeJobs = {}

    for index = 0, count - 1 do
        local key = string.format(
            "loggingContractor.jobs.job(%d)",
            index
        )
        local job = self:restorePersistentJob(xmlFile, key)

        if job ~= nil then
            maxJobId = math.max(maxJobId, job.jobId)

            if job.remainingTrees > 0 then
                self.activeJobs[job.jobId] = job
                loadedJobs = loadedJobs + 1
            else
                Logging.info(
                    "[LoggingContractor] Persisted contract %d has no remaining targets and is already complete",
                    job.jobId
                )
                job:delete()
            end
        end
    end

    local savedNextJobId =
        math.max(getXMLInt(xmlFile, "loggingContractor#nextJobId") or 1, 1)
    self.nextJobId = math.max(savedNextJobId, maxJobId + 1)

    delete(xmlFile)

    Logging.info(
        "[LoggingContractor] Loaded %d active contract(s) from savegame",
        loadedJobs
    )

    return true
end


-- Отправляет активные договоры фермы конкретному подключившемуся клиенту.
-- farmId берётся только из серверного User/FarmManager, а не из запроса клиента.
function LoggingContractor:syncActiveJobsToConnection(connection)
    if self.mission == nil
        or not self.mission:getIsServer()
        or connection == nil then
        return
    end

    local farm = self:getFarmForConnection(connection)
    if farm == nil or farm.farmId == FarmManager.SPECTATOR_FARM_ID then
        return
    end

    local jobs = {}
    for _, job in pairs(self.activeJobs or {}) do
        if job.isActive and job.farmId == farm.farmId then
            table.insert(jobs, job)
        end
    end

    table.sort(jobs, function(a, b)
        return a.jobId < b.jobId
    end)

    for _, job in ipairs(jobs) do
        connection:sendEvent(LoggingContractorProgressEvent.new(job))
    end

    Logging.info(
        "[LoggingContractor] Synced %d active contract(s) to farm %d",
        #jobs,
        farm.farmId
    )
end


-- Очищает старое клиентское представление и один раз синхронизирует договоры
-- после входа в другую ферму. Listen-server использует authoritative activeJobs
-- напрямую, обычный клиент отправляет серверу пустой sync-request.
function LoggingContractor:updateClientJobSync()
    if self.mission == nil or not self.mission:getIsClient() then
        return
    end

    local farmId = self.mission:getFarmId()
    if farmId == nil or self.clientSyncFarmId == farmId then
        return
    end

    for _, job in pairs(self.clientJobs or {}) do
        job:delete()
    end
    self.clientJobs = {}
    self.clientSyncFarmId = farmId

    if farmId == FarmManager.SPECTATOR_FARM_ID then
        return
    end

    if self.mission:getIsServer() then
        for _, job in pairs(self.activeJobs or {}) do
            if job.isActive and job.farmId == farmId then
                self:applyClientJobProgress(job)
            end
        end
        return
    end

    LoggingContractorSyncRequestEvent.sendEvent()
end


-- Устанавливает единый savegame-hook. Флаг хранится на FSCareerMissionInfo,
-- чтобы soft restart не оборачивал штатную функцию повторно.
function LoggingContractor.installPersistenceSaveHook()
    if FSCareerMissionInfo == nil
        or FSCareerMissionInfo.saveToXMLFile == nil
        or FSCareerMissionInfo.taigaLoggingContractorSaveHookInstalled then
        return
    end

    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
        FSCareerMissionInfo.saveToXMLFile,
        function(missionInfo, ...)
            local mission = g_currentMission
            local contractor =
                mission ~= nil and mission.loggingContractor or nil

            if contractor ~= nil
                and mission:getIsServer()
                and missionInfo ~= nil then
                contractor:saveToSavegame(missionInfo.savegameDirectory)
            end
        end
    )

    FSCareerMissionInfo.taigaLoggingContractorSaveHookInstalled = true
    Logging.info("[LoggingContractor] Savegame persistence hook installed")
end

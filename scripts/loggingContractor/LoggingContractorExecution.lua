--[[
    LoggingContractorExecution

    Серверное выполнение заключённых договоров на лесоповал.

    Основные правила:
    - один рабочий такт равен 1.5 игровым минутам;
    - за такт обрабатывается не больше деревьев, чем выбрано единиц техники;
    - договор хранит исходный набор целей, поэтому новые деревья на участке в
      уже оплаченный договор не попадают;
    - если игрок сам спилил исходную цель, она исчезает из remainingTrees, но
      contractorCutTrees не увеличивается;
    - при отсутствии исходных целей договор завершается;
    - подрядчик валит дерево, удаляет ветви и режет ствол на выбранную длину,
      сохраняя короткий остаток отдельным бревном.
]]

LoggingContractor.PROCESS_INTERVAL_MS = LoggingContractor.MINUTES_PER_TREE * 60 * 1000
LoggingContractor.MAX_BATCHES_PER_UPDATE = 5
LoggingContractor.SPLIT_PLANE_SIZE = 4
LoggingContractor.STUMP_HEIGHT = 0.5
LoggingContractor.MIN_LOG_REMAINDER = 0.001
LoggingContractor.TREE_DIRTY_RADIUS = 10


-- Возвращает имя split type дерева через штатный SplitShapeManager.
function LoggingContractor:getContractorSplitTypeName(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return nil
    end

    local splitTypeIndex = getSplitType(shape)
    local splitType = g_splitShapeManager:getSplitTypeByIndex(splitTypeIndex)
    return splitType ~= nil and splitType.name or nil
end


-- Помечает область дерева изменённой для collision map и AI.
function LoggingContractor:markContractorTreeAreaDirty(x, z)
    local radius = LoggingContractor.TREE_DIRTY_RADIUS

    if g_densityMapHeightManager ~= nil then
        g_densityMapHeightManager:setCollisionMapAreaDirty(
            x - radius,
            z - radius,
            x + radius,
            z + radius,
            true
        )
    end

    if self.mission ~= nil and self.mission.aiSystem ~= nil then
        self.mission.aiSystem:setAreaDirty(
            x - radius,
            x + radius,
            z - radius,
            z + radius
        )
    end
end


-- Полностью удаляет дерево, которое подрядчик не должен превращать в древесину.
-- Для DOWNYSERVICEBERRY используется прямое delete(), как в штатной команде
-- TreePlantManager удаления дерева, после чего обновляются collision map и AI.
function LoggingContractor:removeContractorNonTimberTree(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return false
    end

    local x, _, z = getWorldTranslation(shape)
    local splitTypeName = self:getContractorSplitTypeName(shape) or "<unknown>"

    delete(shape)
    self:markContractorTreeAreaDirty(x, z)

    Logging.info(
        "[LoggingContractor] Removed non-timber tree: splitType=%s",
        tostring(splitTypeName)
    )
    return true
end


-- Проверяет, остаётся ли node исходной стоящей целью договора.
function LoggingContractor:isStandingContractTarget(node, farmlandId)
    if node == nil or node == 0 or not entityExists(node) then
        return false
    end

    if not getHasClassId(node, ClassIds.MESH_SPLIT_SHAPE) then
        return false
    end

    if getSplitType(node) == 0
        or getRigidBodyType(node) ~= RigidBodyType.STATIC
        or getIsSplitShapeSplit(node)
        or getUserAttribute(node, "isTreeStump") == true then
        return false
    end

    local x, _, z = getWorldTranslation(node)
    return g_farmlandManager:getFarmlandIdAtWorldPosition(x, z) == farmlandId
end


-- Callback overlapBox: собирает только стоящие деревья указанного участка.
function LoggingContractor:contractTargetOverlapCallback(transformId)
    local scan = self.activeContractTargetScan
    if scan == nil or transformId == nil or transformId == 0 then
        return
    end

    if scan.seenNodes[transformId] then
        return
    end
    scan.seenNodes[transformId] = true

    if self:isStandingContractTarget(transformId, scan.farmlandId) then
        table.insert(scan.nodes, transformId)
    end
end


-- Собирает фактический список стоящих целей участка. Метод используется только
-- сервером для фиксации исходного набора деревьев сразу после заключения договора.
function LoggingContractor:collectContractTargets(farmlandId)
    local farmland = g_farmlandManager ~= nil and g_farmlandManager:getFarmlandById(farmlandId) or nil
    if farmland == nil then
        return {}
    end

    local minX, minZ, maxX, maxZ = farmland:getBoundingBox()
    if minX == nil then
        return {}
    end

    self.activeContractTargetScan = {
        farmlandId = farmlandId,
        nodes = {},
        seenNodes = {}
    }

    overlapBox(
        (minX + maxX) * 0.5,
        0,
        (minZ + maxZ) * 0.5,
        0,
        0,
        0,
        math.max((maxX - minX) * 0.5, 0.5),
        self.mission.terrainSize,
        math.max((maxZ - minZ) * 0.5, 0.5),
        "contractTargetOverlapCallback",
        self,
        CollisionFlag.TREE,
        false,
        false,
        true,
        false
    )

    local nodes = self.activeContractTargetScan.nodes
    self.activeContractTargetScan = nil

    table.sort(nodes)
    return nodes
end


-- Фиксирует исходные цели только что созданной задачи. plannedTrees остаётся
-- серверным числом на момент оплаты, а targetNodes определяет именно те деревья,
-- которые подрядчик имеет право обрабатывать в рамках этого договора.
function LoggingContractor:initializeJobTargets(job)
    job.targetNodes = self:collectContractTargets(job.farmlandId)
    job.remainingTrees = #job.targetNodes
    job.processTimerMs = 0

    if job.remainingTrees > job.plannedTrees then
        while #job.targetNodes > job.plannedTrees do
            table.remove(job.targetNodes)
        end
        job.remainingTrees = #job.targetNodes
    end
end


-- Удаляет из задачи исходные цели, которые игрок уже спилил или которые больше
-- не существуют как стоящие деревья на выбранном участке.
function LoggingContractor:refreshJobTargets(job)
    local validTargets = {}

    for _, node in ipairs(job.targetNodes or {}) do
        if self:isStandingContractTarget(node, job.farmlandId) then
            table.insert(validTargets, node)
        end
    end

    job.targetNodes = validTargets
    job.remainingTrees = #validTargets
    return validTargets
end


-- Callback splitShape: регистрирует созданные части тем же штатным путём,
-- которым GIANTS регистрирует части дерева после работы пилы и харвестера.
function LoggingContractor:contractorSplitShapeCallback(shape, isBelow, isAbove, minY, maxY, minZ, maxZ)
    local operation = self.activeContractSplitOperation
    if operation == nil then
        return
    end

    g_currentMission:addKnownSplitShape(shape)
    g_treePlantManager:addingSplitShape(shape, operation.oldShape, operation.fromTree)

    table.insert(operation.parts, {
        shape = shape,
        isBelow = isBelow,
        isAbove = isAbove,
        minY = minY,
        maxY = maxY,
        minZ = minZ,
        maxZ = maxZ
    })

    -- При первичном спиле статическая часть является пнём. Удаление повторяет
    -- принцип StumpCutter:crushSplitShape и не меняет rigid body у ствола.
    if operation.fromTree and getRigidBodyType(shape) == RigidBodyType.STATIC then
        local x, _, z = getWorldTranslation(shape)
        delete(shape)
        self:markContractorTreeAreaDirty(x, z)
    end
end

-- Выполняет один центрированный разрез split-shape плоскостью 4x4 м и
-- возвращает части из штатного callback. Старый shape снимается с учёта
-- TreePlantManager только после реально состоявшегося разреза.
function LoggingContractor:splitContractorShape(shape, centerX, centerY, centerZ, normalX, normalY, normalZ, upX, upY, upZ, fromTree)
    if not entityExists(shape) then
        return {}
    end

    normalX, normalY, normalZ = MathUtil.vector3Normalize(normalX, normalY, normalZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)

    local sideX, sideY, sideZ = MathUtil.crossProduct(normalX, normalY, normalZ, upX, upY, upZ)
    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    local halfSize = LoggingContractor.SPLIT_PLANE_SIZE * 0.5
    local planeX = centerX - sideX * halfSize - upX * halfSize
    local planeY = centerY - sideY * halfSize - upY * halfSize
    local planeZ = centerZ - sideZ * halfSize - upZ * halfSize

    self.activeContractSplitOperation = {
        oldShape = shape,
        fromTree = fromTree == true,
        parts = {}
    }

    g_currentMission:removeKnownSplitShape(shape)
    splitShape(
        shape,
        planeX,
        planeY,
        planeZ,
        normalX,
        normalY,
        normalZ,
        upX,
        upY,
        upZ,
        LoggingContractor.SPLIT_PLANE_SIZE,
        LoggingContractor.SPLIT_PLANE_SIZE,
        "contractorSplitShapeCallback",
        self
    )

    local operation = self.activeContractSplitOperation
    self.activeContractSplitOperation = nil

    if #operation.parts > 0 then
        g_treePlantManager:removingSplitShape(shape)
    elseif entityExists(shape) then
        g_currentMission:addKnownSplitShape(shape)
    end

    return operation.parts
end


-- Находит в результате разреза часть со стороны положительной нормали и часть
-- со стороны отрицательной нормали. Для распила положительная сторона всегда
-- считается оставшимся стволом, отрицательная — готовым бревном или пнём.
function LoggingContractor:getSplitPartsBySide(parts)
    local belowPart = nil
    local abovePart = nil

    for _, part in ipairs(parts) do
        if part.isBelow and not part.isAbove then
            belowPart = part
        elseif part.isAbove and not part.isBelow then
            abovePart = part
        end
    end

    return belowPart, abovePart
end


-- Обрабатывает одно стоящее дерево подрядчиком. DOWNYSERVICEBERRY удаляется
-- целиком без получения древесины; остальные деревья отделяются от пня и
-- передаются модулю обработки ствола для очистки, снятия ветвей и раскряжёвки.
function LoggingContractor:processContractTree(job, shape)
    if not self:isStandingContractTarget(shape, job.farmlandId) then
        return false
    end

    if self:getContractorSplitTypeName(shape) == "DOWNYSERVICEBERRY" then
        return self:removeContractorNonTimberTree(shape)
    end

    local treeX, treeY, treeZ = getWorldTranslation(shape)
    local localX, localY, localZ = worldToLocal(
        shape,
        treeX,
        treeY + LoggingContractor.STUMP_HEIGHT,
        treeZ
    )
    local cutX, cutY, cutZ = localToWorld(shape, localX, localY, localZ)

    local axisX, axisY, axisZ = localDirectionToWorld(shape, 0, 1, 0)
    local upX, upY, upZ = localDirectionToWorld(shape, 0, 0, 1)
    axisX, axisY, axisZ = MathUtil.vector3Normalize(axisX, axisY, axisZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)

    local lengthBelow, lengthAbove = getSplitShapePlaneExtents(
        shape,
        cutX,
        cutY,
        cutZ,
        axisX,
        axisY,
        axisZ
    )
    if lengthBelow == nil or lengthAbove == nil then
        Logging.warning("[LoggingContractor] Unable to determine tree extents for shape %d", shape)
        return false
    end

    local trunkLength
    if lengthBelow > lengthAbove then
        axisX = -axisX
        axisY = -axisY
        axisZ = -axisZ
        trunkLength = lengthBelow
    else
        trunkLength = lengthAbove
    end

    if trunkLength <= LoggingContractor.MIN_LOG_REMAINDER then
        return false
    end

    local parts = self:splitContractorShape(
        shape,
        cutX,
        cutY,
        cutZ,
        axisX,
        axisY,
        axisZ,
        upX,
        upY,
        upZ,
        true
    )

    local _, trunkPart = self:getSplitPartsBySide(parts)
    if trunkPart == nil or trunkPart.shape == nil then
        Logging.warning("[LoggingContractor] Unable to obtain trunk after cutting shape %d", shape)
        return false
    end

    local trunkShape = trunkPart.shape
    if getRigidBodyType(trunkShape) == RigidBodyType.STATIC then
        for _, part in ipairs(parts) do
            if part.shape ~= nil and entityExists(part.shape) and getRigidBodyType(part.shape) == RigidBodyType.DYNAMIC then
                trunkShape = part.shape
                break
            end
        end
    end

    -- Повторяем обновление областей коллизий и AI из штатного ChainsawUtil.
    if g_densityMapHeightManager ~= nil then
        g_densityMapHeightManager:setCollisionMapAreaDirty(treeX - 5, treeZ - 5, treeX + 5, treeZ + 5, true)
    end
    if self.mission.aiSystem ~= nil then
        self.mission.aiSystem:setAreaDirty(treeX - 5, treeX + 5, treeZ - 5, treeZ + 5)
    end

    self:cutContractorTrunk(
        trunkShape,
        cutX,
        cutY,
        cutZ,
        axisX,
        axisY,
        axisZ,
        upX,
        upY,
        upZ,
        trunkLength,
        job.logLength
    )

    return true
end


-- Синхронизирует состояние задачи всем клиентам. Локальный клиент хоста
-- обновляется напрямую, потому что server broadcast не обязан возвращать event
-- обратно в локальное соединение.
function LoggingContractor:broadcastJobProgress(job)
    if self.mission:getIsClient() then
        self:applyClientJobProgress(job)
    end

    if g_server ~= nil then
        g_server:broadcastEvent(LoggingContractorProgressEvent.new(job), false)
    end
end


-- Применяет состояние серверной задачи к локальному клиентскому представлению.
function LoggingContractor:applyClientJobProgress(data)
    local farmId = self.mission:getFarmId()
    if farmId == nil or data.farmId ~= farmId then
        return
    end

    local job = self.clientJobs[data.jobId]
    if job == nil then
        job = LoggingContractorJob.new({
            jobId = data.jobId,
            farmId = data.farmId,
            farmlandId = data.farmlandId,
            plannedTrees = data.plannedTrees,
            contractorCutTrees = data.contractorCutTrees,
            remainingTrees = data.remainingTrees,
            equipmentCount = data.equipmentCount,
            logLength = data.logLength,
            workHours = 0,
            billableHours = 0,
            rentCost = 0,
            equipmentWorkCost = 0,
            workerCost = 0,
            totalCost = 0,
            state = data.state
        })
        self.clientJobs[data.jobId] = job
    else
        job.farmlandId = data.farmlandId
        job.plannedTrees = data.plannedTrees
        job.contractorCutTrees = data.contractorCutTrees
        job.remainingTrees = data.remainingTrees
        job.equipmentCount = data.equipmentCount
        job.logLength = data.logLength
        job.state = data.state
        job.isActive = data.state == LoggingContractorJob.STATE_ACTIVE
    end
end


-- Получает сетевое состояние договора на клиенте.
function LoggingContractor:onJobProgress(event)
    self:applyClientJobProgress(event)
end


-- Завершает задачу, фиксирует итоговый лог и синхронизирует состояние клиентам.
function LoggingContractor:finishJob(job)
    if not job.isActive then
        return
    end

    job.state = LoggingContractorJob.STATE_FINISHED
    job.isActive = false
    job.remainingTrees = 0

    Logging.info(
        "[LoggingContractor] Contract finished: job=%d farm=%d farmland=%d",
        job.jobId,
        job.farmId,
        job.farmlandId
    )
    Logging.info("[LoggingContractor] Запланировано к спилу: %d", job.plannedTrees)
    Logging.info("[LoggingContractor] Спилено подрядчиком: %d", job.contractorCutTrees)

    self:broadcastJobProgress(job)
end


-- Выполняет один рабочий такт договора: сначала исключает уже спиленные игроком
-- цели, затем подрядчик обрабатывает до equipmentCount оставшихся деревьев.
function LoggingContractor:processJobBatch(job)
    local targets = self:refreshJobTargets(job)
    if #targets == 0 then
        self:finishJob(job)
        return
    end

    local count = math.min(job.equipmentCount, #targets)
    for i = 1, count do
        local shape = targets[i]
        if self:processContractTree(job, shape) then
            job.contractorCutTrees = (job.contractorCutTrees or 0) + 1
        end
    end

    self:refreshJobTargets(job)

    Logging.info(
        "[LoggingContractor] Job %d batch: contractorCut=%d remaining=%d",
        job.jobId,
        job.contractorCutTrees,
        job.remainingTrees
    )

    if job.remainingTrees == 0 then
        self:finishJob(job)
    else
        self:broadcastJobProgress(job)
    end
end


-- Обновляет серверные договоры в игровом времени. При высоком ускорении времени
-- за кадр допускается несколько рабочих тактов, но их число ограничено, чтобы
-- массовая рубка не создавала длинный кадр.
function LoggingContractor:update(dt)
    if not self.mission:getIsServer() then
        return
    end

    local effectiveTimeScale = self.mission:getEffectiveTimeScale()
    local dtGame = dt * effectiveTimeScale
    if dtGame <= 0 then
        return
    end

    for _, job in pairs(self.activeJobs) do
        if job.isActive then
            if job.targetNodes == nil then
                self:initializeJobTargets(job)
                job.progressBroadcastPending = true
            end

            if job.progressBroadcastPending then
                job.progressBroadcastPending = false
                self:broadcastJobProgress(job)
            end

            job.processTimerMs = (job.processTimerMs or 0) + dtGame
            local batchCount = math.min(
                math.floor(job.processTimerMs / LoggingContractor.PROCESS_INTERVAL_MS),
                LoggingContractor.MAX_BATCHES_PER_UPDATE
            )

            if batchCount > 0 then
                job.processTimerMs = job.processTimerMs - batchCount * LoggingContractor.PROCESS_INTERVAL_MS

                for _ = 1, batchCount do
                    if not job.isActive then
                        break
                    end
                    self:processJobBatch(job)
                end
            end
        end
    end
end


-- Рисует компактную строку прогресса для активных договоров текущей фермы.
-- Прогресс считается по исчезнувшим исходным целям, поэтому собственная рубка
-- игрока уменьшает remainingTrees и не может повесить договор.
function LoggingContractor:draw()
    if not self.mission:getIsClient() then
        return
    end

    local farmId = self.mission:getFarmId()
    if farmId == nil then
        return
    end

    local y = 0.91
    local textSize = getCorrectTextSize(0.014)

    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextBold(true)
    setTextColor(1, 1, 1, 1)

    for _, job in pairs(self.clientJobs) do
        if job.isActive and job.farmId == farmId then
            local completedTrees = math.max(job.plannedTrees - (job.remainingTrees or job.plannedTrees), 0)
            completedTrees = math.min(completedTrees, job.plannedTrees)

            local progress = 100
            if job.plannedTrees > 0 then
                progress = math.floor(completedTrees * 100 / job.plannedTrees + 0.5)
            end

            renderText(
                0.5,
                y,
                textSize,
                string.format(
                    "Участок %d — Подрядчик по заготовке леса: прогресс %d%% (%d / %d)",
                    job.farmlandId,
                    progress,
                    completedTrees,
                    job.plannedTrees
                )
            )
            y = y - textSize * 1.5
        end
    end

    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_LEFT)
end


-- Расширяет заключение договора и сразу фиксирует исходный набор целей. Само
-- списание средств и все проверки остаются в существующем startContract.
function LoggingContractor:startContractWithExecution(superFunc, connection, farmlandId, equipmentCount, logLength)
    local state, data = superFunc(self, connection, farmlandId, equipmentCount, logLength)

    if state == LoggingContractorResultEvent.STATE_SUCCESS and data ~= nil then
        local job = self.activeJobs[data.jobId]
        if job ~= nil then
            self:initializeJobTargets(job)
            job.progressBroadcastPending = true
        end
    end

    return state, data
end

LoggingContractor.startContract = Utils.overwrittenFunction(
    LoggingContractor.startContract,
    LoggingContractor.startContractWithExecution
)

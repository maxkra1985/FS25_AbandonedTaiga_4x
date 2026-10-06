--[[
    LoggingContractorExecution

    Серверное выполнение заключённых договоров на лесоповал.

    Основные правила:
    - один рабочий такт равен 2 игровым минутам;
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
LoggingContractor.START_EDGE_BAND = 20
LoggingContractor.START_ACCESS_RADIUS = 12
LoggingContractor.START_DENSITY_TOLERANCE = 2

-- Временный профилировщик подрядчика. Он собирает только агрегированные
-- длительности и счётчики, а в лог пишет сводку раз в 10 реальных секунд.
LoggingContractor.PERF_DEBUG_ENABLED = true
LoggingContractor.PERF_DEBUG_INTERVAL_MS = 10000

local function getContractorPerfTimeMs()
    return getTimeSec() * 1000
end

-- Возвращает окно накопления временной статистики, создавая его при первом вызове.
function LoggingContractor:getContractorPerfStats()
    if not LoggingContractor.PERF_DEBUG_ENABLED then
        return nil
    end

    if self.contractorPerfStats == nil then
        self.contractorPerfStats = {
            startedAtMs = getContractorPerfTimeMs(),
            metrics = {},
            counters = {}
        }
    end

    return self.contractorPerfStats
end

-- Добавляет длительность операции в агрегированную статистику профилировщика.
function LoggingContractor:recordContractorPerfMetric(name, elapsedMs, items)
    local stats = self:getContractorPerfStats()
    if stats == nil then
        return
    end

    local metric = stats.metrics[name]
    if metric == nil then
        metric = {
            calls = 0,
            totalMs = 0,
            maxMs = 0,
            items = 0
        }
        stats.metrics[name] = metric
    end

    metric.calls = metric.calls + 1
    metric.totalMs = metric.totalMs + elapsedMs
    metric.maxMs = math.max(metric.maxMs, elapsedMs)
    metric.items = metric.items + (items or 0)
end

-- Увеличивает простой диагностический счётчик без записи отдельной строки в лог.
function LoggingContractor:addContractorPerfCounter(name, value)
    local stats = self:getContractorPerfStats()
    if stats == nil then
        return
    end

    stats.counters[name] = (stats.counters[name] or 0) + (value or 1)
end

local function formatContractorPerfMetric(name, metric)
    if metric == nil or metric.calls <= 0 then
        return string.format("%s=n/a", name)
    end

    return string.format(
        "%s calls=%d total=%.2fms avg=%.3fms max=%.2fms items=%d",
        name,
        metric.calls,
        metric.totalMs,
        metric.totalMs / metric.calls,
        metric.maxMs,
        metric.items or 0
    )
end

-- Печатает накопленную статистику ограниченной частотой и начинает новое окно.
function LoggingContractor:logContractorPerfStatsIfDue()
    local stats = self:getContractorPerfStats()
    if stats == nil then
        return
    end

    local nowMs = getContractorPerfTimeMs()
    local windowMs = nowMs - stats.startedAtMs
    if windowMs < LoggingContractor.PERF_DEBUG_INTERVAL_MS then
        return
    end

    local activeJobs = 0
    for _, job in pairs(self.activeJobs or {}) do
        if job.isActive then
            activeJobs = activeJobs + 1
        end
    end

    Logging.info(
        "[LoggingContractorPerf] window=%.1fs jobs=%d | %s | %s | %s",
        windowMs / 1000,
        activeJobs,
        formatContractorPerfMetric("frameDt", stats.metrics.frameDt),
        formatContractorPerfMetric("update", stats.metrics.update),
        formatContractorPerfMetric("processing", stats.metrics.processing)
    )

    Logging.info(
        "[LoggingContractorPerf] %s | %s | %s | %s | %s | mutations=%d completed=%d requeued=%d started=%d",
        formatContractorPerfMetric("refreshTargets", stats.metrics.refreshTargets),
        formatContractorPerfMetric("batch", stats.metrics.batch),
        formatContractorPerfMetric("selectTarget", stats.metrics.selectTarget),
        formatContractorPerfMetric("splitShape", stats.metrics.splitShape),
        formatContractorPerfMetric("dirtyArea", stats.metrics.dirtyArea),
        stats.counters.shapeMutations or 0,
        stats.counters.treesCompleted or 0,
        stats.counters.treesRequeued or 0,
        stats.counters.treesStarted or 0
    )

    local phaseNames = {
        "INITIAL_CUT",
        "REMOVE_STUMP",
        "PRUNE_INIT",
        "PRUNE",
        "BUCK_INIT",
        "BUCK"
    }
    local phaseParts = {}
    for _, phaseName in ipairs(phaseNames) do
        local metric = stats.metrics["phase_" .. phaseName]
        if metric ~= nil and metric.calls > 0 then
            table.insert(
                phaseParts,
                formatContractorPerfMetric(phaseName, metric)
            )
        end
    end

    if #phaseParts > 0 then
        Logging.info(
            "[LoggingContractorPerf] phases | %s",
            table.concat(phaseParts, " | ")
        )
    end

    for _, job in pairs(self.activeJobs or {}) do
        if job.isActive then
            Logging.info(
                "[LoggingContractorPerf] job=%d pending=%d processing=%d remaining=%d timer=%.0fms/%dms",
                job.jobId,
                #(job.targetNodes or {}),
                #(job.processingTrees or {}),
                job.remainingTrees or 0,
                job.processTimerMs or 0,
                LoggingContractor.PROCESS_INTERVAL_MS
            )
        end
    end

    self.contractorPerfStats = {
        startedAtMs = nowMs,
        metrics = {},
        counters = {}
    }
end


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
    local perfStartMs = LoggingContractor.PERF_DEBUG_ENABLED
        and getContractorPerfTimeMs()
        or nil
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

    if perfStartMs ~= nil then
        self:recordContractorPerfMetric(
            "dirtyArea",
            getContractorPerfTimeMs() - perfStartMs
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
    delete(shape)
    self:markContractorTreeAreaDirty(x, z)
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

    if self:isStandingContractTarget(transformId, scan.farmlandId)
        and (not scan.onlyMarkedTrees or self:isContractTargetMarked(transformId)) then
        table.insert(scan.nodes, transformId)
    end
end


-- Собирает фактический список стоящих целей участка. Метод используется только
-- сервером для фиксации исходного набора деревьев сразу после заключения договора.
function LoggingContractor:collectContractTargets(farmlandId, onlyMarkedTrees)
    local farmland = g_farmlandManager ~= nil and g_farmlandManager:getFarmlandById(farmlandId) or nil
    if farmland == nil then
        return {}
    end

    if type(farmland.getBoundingBox) ~= "function" then
        return {}
    end

    local minX, minZ, maxX, maxZ = farmland:getBoundingBox()
    if minX == nil then
        return {}
    end

    self.activeContractTargetScan = {
        farmlandId = farmlandId,
        onlyMarkedTrees = onlyMarkedTrees == true,
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


-- Возвращает расстояние от точки до ближайшего дорожного spline AI.
-- AISystem:getRoadSplines() является штатным источником дорожной сети карты.
function LoggingContractor:getContractorRoadDistance(x, y, z)
    local aiSystem = self.mission.aiSystem
    if aiSystem == nil then
        return math.huge
    end

    local roadSplines = aiSystem:getRoadSplines()
    local bestDistanceSq = math.huge

    for spline in pairs(roadSplines) do
        if I3DUtil.getIsSpline(spline) then
            local length = getSplineLength(spline)
            if length ~= nil and length > 0 then
                local sx, sy, sz = getClosestSplinePosition(
                    spline,
                    x,
                    y,
                    z,
                    0.1 / length
                )
                local distanceSq = MathUtil.vector3LengthSq(
                    x - sx,
                    y - sy,
                    z - sz
                )
                bestDistanceSq = math.min(bestDistanceSq, distanceSq)
            end
        end
    end

    return bestDistanceSq < math.huge and math.sqrt(bestDistanceSq) or math.huge
end


-- Считает соседние деревья в радиусе от кандидата. Низкая плотность означает,
-- что к краю участка проще получить свободный доступ без прохода через лес.
function LoggingContractor:getContractorLocalTreeDensity(node, targets, radius)
    if node == nil or node == 0 or not entityExists(node) then
        return math.huge
    end

    local x, _, z = getWorldTranslation(node)
    local radiusSq = radius * radius
    local count = 0

    for _, otherNode in ipairs(targets) do
        if otherNode ~= node and entityExists(otherNode) then
            local otherX, _, otherZ = getWorldTranslation(otherNode)
            local dx = otherX - x
            local dz = otherZ - z
            if dx * dx + dz * dz <= radiusSq then
                count = count + 1
            end
        end
    end

    return count
end


-- Выбирает первую точку рубки у края участка. Сначала оставляются участки края
-- с минимальной локальной плотностью деревьев; среди примерно одинаково
-- свободных вариантов предпочтение отдаётся ближайшему к штатной AI-дороге.
function LoggingContractor:selectContractorInitialTarget(job, targets)
    local farmland = g_farmlandManager:getFarmlandById(job.farmlandId)
    if farmland == nil or #targets == 0 then
        return targets[1]
    end

    if type(farmland.getBoundingBox) ~= "function" then
        return targets[1]
    end

    local minX, minZ, maxX, maxZ = farmland:getBoundingBox()
    if minX == nil then
        return targets[1]
    end

    local width = math.max(maxX - minX, 1)
    local depth = math.max(maxZ - minZ, 1)
    local edgeBand = math.min(
        LoggingContractor.START_EDGE_BAND,
        math.min(width, depth) * 0.25
    )

    local edgeTargets = {}
    for _, node in ipairs(targets) do
        if entityExists(node) then
            local x, _, z = getWorldTranslation(node)
            local edgeDistance = math.min(
                x - minX,
                maxX - x,
                z - minZ,
                maxZ - z
            )

            if edgeDistance <= edgeBand then
                table.insert(edgeTargets, {
                    node = node,
                    edgeDistance = edgeDistance
                })
            end
        end
    end

    if #edgeTargets == 0 then
        for _, node in ipairs(targets) do
            table.insert(edgeTargets, {
                node = node,
                edgeDistance = math.huge
            })
        end
    end

    local minDensity = math.huge
    for _, candidate in ipairs(edgeTargets) do
        candidate.density = self:getContractorLocalTreeDensity(
            candidate.node,
            targets,
            LoggingContractor.START_ACCESS_RADIUS
        )
        minDensity = math.min(minDensity, candidate.density)
    end

    local best = nil
    for _, candidate in ipairs(edgeTargets) do
        if candidate.density <= minDensity + LoggingContractor.START_DENSITY_TOLERANCE then
            local x, y, z = getWorldTranslation(candidate.node)
            candidate.roadDistance = self:getContractorRoadDistance(x, y, z)

            local candidateHasRoad = candidate.roadDistance < math.huge
            local bestHasRoad = best ~= nil and best.roadDistance < math.huge

            if best == nil
                or (candidateHasRoad and not bestHasRoad)
                or (candidateHasRoad and bestHasRoad
                    and candidate.roadDistance < best.roadDistance - 0.001)
                or (candidateHasRoad == bestHasRoad
                    and (not candidateHasRoad
                        or math.abs(candidate.roadDistance - best.roadDistance) <= 0.001)
                    and candidate.edgeDistance < best.edgeDistance) then
                best = candidate
            end
        end
    end

    return best ~= nil and best.node or edgeTargets[1].node
end


-- Возвращает ближайшее дерево к опорной точке текущего маршрута.
-- Опорная точка не двигается после каждого спила, поэтому подрядчик расширяет
-- фронт работ вокруг одной исходной позиции вместо движения змейкой.
function LoggingContractor:selectNearestContractTarget(targets, x, z)
    local bestNode = nil
    local bestDistanceSq = math.huge

    for _, node in ipairs(targets) do
        if entityExists(node) then
            local nodeX, _, nodeZ = getWorldTranslation(node)
            local dx = nodeX - x
            local dz = nodeZ - z
            local distanceSq = dx * dx + dz * dz

            if distanceSq < bestDistanceSq then
                bestDistanceSq = distanceSq
                bestNode = node
            end
        end
    end

    return bestNode
end


-- Обновляет состояние маркировки и возвращает все текущие и вновь появившиеся
-- маркированные цели. Переход false -> true считается новой командой игрока.
function LoggingContractor:updateContractMarkerStates(job, targets)
    job.markerStates = job.markerStates or {}

    local activeNodes = {}
    local markedTargets = {}
    local newlyMarkedTargets = {}

    for _, node in ipairs(targets) do
        activeNodes[node] = true

        local isMarked = self:isContractTargetMarked(node)
        if isMarked then
            table.insert(markedTargets, node)

            if job.markerStates[node] ~= true then
                table.insert(newlyMarkedTargets, node)
            end
        end

        job.markerStates[node] = isMarked
    end

    for node in pairs(job.markerStates) do
        if not activeNodes[node] then
            job.markerStates[node] = nil
        end
    end

    return markedTargets, newlyMarkedTargets
end


-- Выбирает следующую цель договора.
-- До первого спила приоритет имеют маркированные деревья, иначе выбирается
-- доступный край участка. После первого спила все следующие цели ищутся как
-- ближайшие к неизменной опорной точке первого дерева. Если игрок во время
-- работ ставит новый маркер, опорная точка переносится на это дерево.
function LoggingContractor:selectNextContractTarget(job, targets)
    if #targets == 0 then
        return nil
    end

    local markedTargets, newlyMarkedTargets =
        self:updateContractMarkerStates(job, targets)

    if job.routeAnchorX ~= nil
        and job.routeAnchorZ ~= nil
        and #newlyMarkedTargets > 0 then
        local markedNode = self:selectNearestContractTarget(
            newlyMarkedTargets,
            job.routeAnchorX,
            job.routeAnchorZ
        )

        if markedNode ~= nil then
            local x, _, z = getWorldTranslation(markedNode)
            job.routeAnchorX = x
            job.routeAnchorZ = z
            return markedNode
        end
    end

    local candidates = #markedTargets > 0 and markedTargets or targets

    if job.routeAnchorX ~= nil and job.routeAnchorZ ~= nil then
        return self:selectNearestContractTarget(
            candidates,
            job.routeAnchorX,
            job.routeAnchorZ
        )
    end

    return self:selectContractorInitialTarget(job, candidates)
end


-- Возвращает true, если к серверу подключён хотя бы один удалённый клиент.
-- Условие совпадает со штатной проверкой FSBaseMission перед split-shape update.
function LoggingContractor:hasRemoteClients()
    return g_server ~= nil
        and g_server.clients ~= nil
        and #g_server.clients > 0
end


-- Вызывается после штатного onConnectionsUpdateTick: предыдущие изменения
-- split-shape уже получили возможность уйти клиентам.
function LoggingContractor:onNetworkUpdateTick()
    if self.mission:getIsServer() and self:hasRemoteClients() then
        self.networkSyncGeneration = (self.networkSyncGeneration or 0) + 1
    end
end


-- В multiplayer разрешает одну группу изменений split-shape между двумя
-- сетевыми update tick. В одиночной игре ограничение не применяется.
function LoggingContractor:canPerformContractorShapeMutation()
    if not self:hasRemoteClients() then
        return true
    end

    return (self.networkMutationGeneration or -1)
        < (self.networkSyncGeneration or 0)
end


-- После изменения shape расходует текущий сетевой шаг и блокирует продолжение
-- конкретного дерева до следующего update split-shape.
function LoggingContractor:markContractorShapeMutation(state)
    if not self:hasRemoteClients() then
        return
    end

    local generation = self.networkSyncGeneration or 0
    self.networkMutationGeneration = generation
    state.waitForSyncGeneration = generation + 1
end


-- Проверяет, прошёл ли сетевой update после последнего изменения дерева.
function LoggingContractor:getCanAdvanceContractorTreeState(state)
    if not self:hasRemoteClients() then
        return true
    end

    return (state.waitForSyncGeneration or 0)
        <= (self.networkSyncGeneration or 0)
end


-- Фиксирует исходные цели только что созданной задачи. plannedTrees остаётся
-- серверным числом на момент оплаты, а targetNodes определяет именно те деревья,
-- которые подрядчик имеет право обрабатывать в рамках этого договора.
function LoggingContractor:initializeJobTargets(job)
    local perfStartMs = LoggingContractor.PERF_DEBUG_ENABLED
        and getContractorPerfTimeMs()
        or nil

    job.targetNodes = self:collectContractTargets(job.farmlandId, job.onlyMarkedTrees)

    if perfStartMs ~= nil then
        self:recordContractorPerfMetric(
            "initialTargetScan",
            getContractorPerfTimeMs() - perfStartMs,
            #job.targetNodes
        )
    end

    job.processingTrees = {}
    job.remainingTrees = #job.targetNodes
    job.processTimerMs = 0
    job.routeAnchorX = nil
    job.routeAnchorZ = nil
    job.markerStates = {}

    if job.remainingTrees > job.plannedTrees then
        while #job.targetNodes > job.plannedTrees do
            table.remove(job.targetNodes)
        end
        job.remainingTrees = #job.targetNodes
    end

    for _, node in ipairs(job.targetNodes) do
        job.markerStates[node] = self:isContractTargetMarked(node)
    end
end

function LoggingContractor:refreshJobTargets(job)
    local perfStartMs = LoggingContractor.PERF_DEBUG_ENABLED
        and getContractorPerfTimeMs()
        or nil
    local sourceCount = #(job.targetNodes or {})
    local validTargets = {}

    for _, node in ipairs(job.targetNodes or {}) do
        if self:isStandingContractTarget(node, job.farmlandId) then
            table.insert(validTargets, node)
        end
    end

    job.targetNodes = validTargets
    job.processingTrees = job.processingTrees or {}
    job.remainingTrees = #validTargets + #job.processingTrees

    if perfStartMs ~= nil then
        self:recordContractorPerfMetric(
            "refreshTargets",
            getContractorPerfTimeMs() - perfStartMs,
            sourceCount
        )
    end

    return validTargets
end


-- Удаляет выбранную цель из очереди ожидания. До завершения обработки её
-- продолжает учитывать processingTrees.
function LoggingContractor:removePendingContractTarget(job, shape)
    for index = #job.targetNodes, 1, -1 do
        if job.targetNodes[index] == shape then
            table.remove(job.targetNodes, index)
            return
        end
    end
end

function LoggingContractor:contractorSplitShapeCallback(shape, isBelow, isAbove, minY, maxY, minZ, maxZ)
    local operation = self.activeContractSplitOperation
    if operation == nil then
        return
    end

    -- Как и ChainsawUtil, сначала регистрируем все полученные части разреза.
    -- Решение о том, какая часть является пнём, принимается после splitShape
    -- по стороне плоскости, а не по типу rigid body.
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
end

-- Удаляет подтверждённую часть пня после успешного первичного спила.
-- Shape заранее снимается с учёта известных split-shape и TreePlantManager,
-- чтобы после delete() не оставались устаревшие записи.
function LoggingContractor:removeContractorStump(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return
    end

    local x, _, z = getWorldTranslation(shape)

    g_currentMission:removeKnownSplitShape(shape)
    g_treePlantManager:removingSplitShape(shape)
    delete(shape)

    self:markContractorTreeAreaDirty(x, z)
end


-- Выполняет один центрированный разрез split-shape плоскостью 4x4 м и
-- возвращает части из штатного callback. Старый shape снимается с учёта
-- TreePlantManager только после реально состоявшегося разреза.
function LoggingContractor:splitContractorShape(shape, centerX, centerY, centerZ, normalX, normalY, normalZ, upX, upY, upZ, fromTree)
    if not entityExists(shape) then
        return {}
    end

    local perfStartMs = LoggingContractor.PERF_DEBUG_ENABLED
        and getContractorPerfTimeMs()
        or nil

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

    if perfStartMs ~= nil then
        self:recordContractorPerfMetric(
            "splitShape",
            getContractorPerfTimeMs() - perfStartMs,
            #operation.parts
        )
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
function LoggingContractor:createContractorTreeProcess(job, shape)
    if not self:isStandingContractTarget(shape, job.farmlandId) then
        return nil
    end

    local treeX, treeY, treeZ = getWorldTranslation(shape)

    return {
        sourceShape = shape,
        shape = shape,
        splitTypeName = self:getContractorSplitTypeName(shape),
        treeX = treeX,
        treeY = treeY,
        treeZ = treeZ,
        phase = "INITIAL_CUT",
        hadMutation = false,
        waitForSyncGeneration = 0
    }
end


-- Выполняет первичный спил и сохраняет данные для следующих фаз.
function LoggingContractor:performContractorInitialCut(job, state, allowMutation)
    local shape = state.shape

    if not self:isStandingContractTarget(shape, job.farmlandId) then
        return true, false, false
    end

    if state.splitTypeName == "DOWNYSERVICEBERRY" then
        if not allowMutation then
            return false, false, false
        end

        local removed = self:removeContractorNonTimberTree(shape)
        state.hadMutation = removed
        return true, removed, removed
    end

    local treeX, treeY, treeZ = state.treeX, state.treeY, state.treeZ
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
        Logging.warning(
            "[LoggingContractor] Unable to determine tree extents for shape %d",
            shape
        )
        return true, false, false
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
        return true, false, false
    end

    if not allowMutation then
        return false, false, false
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

    if #parts <= 0 then
        return true, false, false
    end

    state.hadMutation = true

    local _, trunkPart = self:getSplitPartsBySide(parts)
    local trunkShape = trunkPart ~= nil and trunkPart.shape or nil

    if trunkShape == nil
        or not entityExists(trunkShape)
        or getRigidBodyType(trunkShape) ~= RigidBodyType.DYNAMIC then
        local dynamicAbovePart = nil
        local dynamicAboveMeasure = -1

        for _, part in ipairs(parts) do
            if part.shape ~= nil
                and entityExists(part.shape)
                and part.isAbove
                and not part.isBelow
                and getRigidBodyType(part.shape) == RigidBodyType.DYNAMIC then
                local measure = self:getContractorShapeMeasure(part.shape)

                if measure > dynamicAboveMeasure then
                    dynamicAbovePart = part
                    dynamicAboveMeasure = measure
                end
            end
        end

        if dynamicAbovePart == nil then
            Logging.warning(
                "[LoggingContractor] Initial cut produced no dynamic trunk: type=%s parts=%d; split parts preserved",
                tostring(state.splitTypeName or "<unknown>"),
                #parts
            )
            state.phase = "FAILED_AFTER_SPLIT"
            return false, true, false
        end

        trunkShape = dynamicAbovePart.shape
    end

    state.shape = trunkShape
    state.cutX = cutX
    state.cutY = cutY
    state.cutZ = cutZ
    state.axisX = axisX
    state.axisY = axisY
    state.axisZ = axisZ
    state.upX = upX
    state.upY = upY
    state.upZ = upZ
    state.trunkLength = trunkLength
    state.stumpShapes = {}

    for _, part in ipairs(parts) do
        if part.shape ~= nil
            and part.shape ~= trunkShape
            and entityExists(part.shape)
            and part.isBelow
            and not part.isAbove then
            table.insert(state.stumpShapes, part.shape)
        end
    end

    self:markContractorTreeAreaDirty(treeX, treeZ)

    if job.routeAnchorX == nil or job.routeAnchorZ == nil then
        job.routeAnchorX = treeX
        job.routeAnchorZ = treeZ
    end

    state.phase =
        #state.stumpShapes > 0
        and "REMOVE_STUMP"
        or "PRUNE_INIT"

    return false, true, false
end


-- Продвигает одно дерево на одну безопасную фазу.
-- Возвращает: done, worldChanged, success.
function LoggingContractor:advanceContractorTreeProcess(job, state, allowMutation)
    if state.phase == "INITIAL_CUT" then
        return self:performContractorInitialCut(job, state, allowMutation)
    end

    if state.phase == "FAILED_AFTER_SPLIT" then
        return true, false, false
    end

    if state.phase == "REMOVE_STUMP" then
        while #state.stumpShapes > 0 do
            local stumpShape = table.remove(state.stumpShapes, 1)

            if stumpShape ~= nil and entityExists(stumpShape) then
                if not allowMutation then
                    table.insert(state.stumpShapes, 1, stumpShape)
                    return false, false, false
                end

                self:removeContractorStump(stumpShape)
                state.hadMutation = true

                if #state.stumpShapes == 0 then
                    state.phase = "PRUNE_INIT"
                end

                return false, true, false
            end
        end

        state.phase = "PRUNE_INIT"
        return false, false, false
    end

    if state.phase == "PRUNE_INIT" then
        state.pruning = self:createContractorPruningState(
            state.shape,
            state.cutX,
            state.cutY,
            state.cutZ,
            state.axisX,
            state.axisY,
            state.axisZ,
            state.upX,
            state.upY,
            state.upZ,
            state.trunkLength
        )
        state.phase = "PRUNE"
        return false, false, false
    end

    if state.phase == "PRUNE" then
        local done, changed =
            self:advanceContractorPruningState(
                state.pruning,
                allowMutation
            )

        if changed then
            state.hadMutation = true
            return false, true, false
        end

        if done then
            state.shape = state.pruning.shape
            state.trunkLength = state.pruning.length
            state.phase = "BUCK_INIT"
        end

        return false, false, false
    end

    if state.phase == "BUCK_INIT" then
        state.bucking = self:createContractorBuckingState(
            state.shape,
            state.cutX,
            state.cutY,
            state.cutZ,
            state.axisX,
            state.axisY,
            state.axisZ,
            state.upX,
            state.upY,
            state.upZ,
            state.trunkLength,
            job.logLength
        )
        state.phase = "BUCK"
        return false, false, false
    end

    if state.phase == "BUCK" then
        local done, changed =
            self:advanceContractorBuckingState(
                state.bucking,
                allowMutation
            )

        if changed then
            state.hadMutation = true
            return false, true, false
        end

        if done then
            return true, false, true
        end

        return false, false, false
    end

    return true, false, false
end

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
            onlyMarkedTrees = data.onlyMarkedTrees,
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
        job.onlyMarkedTrees = data.onlyMarkedTrees == true
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
        "[LoggingContractor] Contract finished: job=%d farm=%d farmland=%d planned=%d contractorCut=%d",
        job.jobId,
        job.farmId,
        job.farmlandId,
        job.plannedTrees,
        job.contractorCutTrees
    )

    self:broadcastJobProgress(job)
end


-- Выполняет один рабочий такт договора: один раз актуализирует очередь целей,
-- затем запускает до equipmentCount деревьев без повторного полного обхода участка.
function LoggingContractor:processJobBatch(job)
    local perfStartMs = LoggingContractor.PERF_DEBUG_ENABLED
        and getContractorPerfTimeMs()
        or nil
    job.processingTrees = job.processingTrees or {}

    -- Полная проверка targetNodes нужна при выборе новой партии: здесь исключаются
    -- деревья, которые игрок успел спилить самостоятельно между рабочими тактами.
    local targets = self:refreshJobTargets(job)
    local availableSlots =
        math.max(job.equipmentCount - #job.processingTrees, 0)

    if availableSlots <= 0 then
        if perfStartMs ~= nil then
            self:recordContractorPerfMetric(
                "batch",
                getContractorPerfTimeMs() - perfStartMs
            )
        end
        return
    end

    local started = 0

    while started < availableSlots and job.isActive do
        if #targets == 0 then
            break
        end

        local selectStartMs = LoggingContractor.PERF_DEBUG_ENABLED
            and getContractorPerfTimeMs()
            or nil
        local shape = self:selectNextContractTarget(job, targets)

        if selectStartMs ~= nil then
            self:recordContractorPerfMetric(
                "selectTarget",
                getContractorPerfTimeMs() - selectStartMs,
                #targets
            )
        end

        if shape == nil or not entityExists(shape) then
            break
        end

        local state = self:createContractorTreeProcess(job, shape)
        if state == nil then
            break
        end

        -- removePendingContractTarget изменяет ту же таблицу, которую вернул
        -- refreshJobTargets, поэтому повторное сканирование очереди здесь не требуется.
        self:removePendingContractTarget(job, shape)
        table.insert(job.processingTrees, state)
        started = started + 1
        self:addContractorPerfCounter("treesStarted", 1)
    end

    if perfStartMs ~= nil then
        self:recordContractorPerfMetric(
            "batch",
            getContractorPerfTimeMs() - perfStartMs,
            started
        )
    end

    if job.remainingTrees == 0 then
        self:finishJob(job)
    elseif started > 0 then
        self:broadcastJobProgress(job)
    end
end

-- Продвигает только уже начатые деревья. В multiplayer одна группа изменений
-- split-shape расходует текущий сетевой tick. Полная очередь targetNodes здесь
-- не пересканируется: завершение конкретного дерева обновляет счётчик локально.
function LoggingContractor:updateContractorProcessingTrees(job)
    job.processingTrees = job.processingTrees or {}

    if #job.processingTrees == 0 then
        return
    end

    local perfStartMs = LoggingContractor.PERF_DEBUG_ENABLED
        and getContractorPerfTimeMs()
        or nil
    local index = 1
    local progressChanged = false

    while index <= #job.processingTrees and job.isActive do
        local state = job.processingTrees[index]

        if self:getCanAdvanceContractorTreeState(state) then
            local canMutate = self:canPerformContractorShapeMutation()
            local phaseName = state.phase or "UNKNOWN"
            local phaseStartMs = LoggingContractor.PERF_DEBUG_ENABLED
                and getContractorPerfTimeMs()
                or nil
            local done, changed, success =
                self:advanceContractorTreeProcess(
                    job,
                    state,
                    canMutate
                )

            if phaseStartMs ~= nil then
                self:recordContractorPerfMetric(
                    "phase_" .. phaseName,
                    getContractorPerfTimeMs() - phaseStartMs
                )
            end

            if changed then
                self:addContractorPerfCounter("shapeMutations", 1)
                self:markContractorShapeMutation(state)
            end

            if done then
                table.remove(job.processingTrees, index)

                local resolved = true

                if success then
                    job.contractorCutTrees =
                        (job.contractorCutTrees or 0) + 1
                    self:addContractorPerfCounter("treesCompleted", 1)
                elseif not state.hadMutation
                    and self:isStandingContractTarget(
                        state.sourceShape,
                        job.farmlandId
                    ) then
                    -- Если обработка не изменила дерево и оно по-прежнему стоит,
                    -- возвращаем его в очередь без изменения remainingTrees.
                    table.insert(job.targetNodes, state.sourceShape)
                    self:addContractorPerfCounter("treesRequeued", 1)
                    resolved = false
                end

                if resolved then
                    job.remainingTrees = math.max(
                        (job.remainingTrees or 1) - 1,
                        0
                    )
                end

                progressChanged = true
            else
                index = index + 1
            end
        else
            index = index + 1
        end
    end

    if perfStartMs ~= nil then
        self:recordContractorPerfMetric(
            "processing",
            getContractorPerfTimeMs() - perfStartMs,
            #job.processingTrees
        )
    end

    if job.remainingTrees == 0 then
        self:finishJob(job)
    elseif progressChanged then
        self:broadcastJobProgress(job)
    end
end


function LoggingContractor:update(dt)
    -- Клиент запрашивает состояние активных договоров один раз после входа
    -- в ферму. Для listen-server локальное представление заполняется напрямую.
    if self.mission:getIsClient() and self.updateClientJobSync ~= nil then
        self:updateClientJobSync()
    end

    if not self.mission:getIsServer() then
        return
    end

    local perfStartMs = LoggingContractor.PERF_DEBUG_ENABLED
        and getContractorPerfTimeMs()
        or nil
    local hasActiveJob = self:hasAnyActiveJob()

    if hasActiveJob then
        self:enforceActiveContractTimeScaleLimit()
    end

    local isWorkingTime = self:getIsWorkingTime()
    local effectiveTimeScale = self.mission:getEffectiveTimeScale()
    local dtGame = isWorkingTime and dt * effectiveTimeScale or 0

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

            -- С 21:00 до 08:00 замораживаются и уже начатые деревья.
            -- Между партиями не вызываем обработчик вообще: до следующего
            -- двухминутного такта у договора нет split-shape работы.
            if isWorkingTime
                and job.processingTrees ~= nil
                and #job.processingTrees > 0 then
                self:updateContractorProcessingTrees(job)
            end

            if job.isActive and dtGame > 0 then
                job.processTimerMs = (job.processTimerMs or 0) + dtGame
                local batchCount = math.min(
                    math.floor(
                        job.processTimerMs
                        / LoggingContractor.PROCESS_INTERVAL_MS
                    ),
                    LoggingContractor.MAX_BATCHES_PER_UPDATE
                )

                if batchCount > 0 then
                    job.processTimerMs =
                        job.processTimerMs
                        - batchCount * LoggingContractor.PROCESS_INTERVAL_MS

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

    if perfStartMs ~= nil and hasActiveJob then
        self:recordContractorPerfMetric("frameDt", dt)
        self:recordContractorPerfMetric(
            "update",
            getContractorPerfTimeMs() - perfStartMs
        )
        self:logContractorPerfStatsIfDue()
    elseif not hasActiveJob then
        self.contractorPerfStats = nil
    end
end

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
function LoggingContractor:startContractWithExecution(superFunc, connection, farmlandId, equipmentCount, logLength, onlyMarkedTrees)
    local state, data = superFunc(self, connection, farmlandId, equipmentCount, logLength, onlyMarkedTrees)

    if state == LoggingContractorResultEvent.STATE_SUCCESS and data ~= nil then
        local job = self.activeJobs[data.jobId]
        if job ~= nil then
            self:initializeJobTargets(job)
            job.progressBroadcastPending = true

            -- В рабочее время новый договор сразу снижает текущий множитель
            -- до x15, даже если до заключения игрок использовал x30/x60.
            self:enforceActiveContractTimeScaleLimit()
        end
    end

    return state, data
end

LoggingContractor.startContract = Utils.overwrittenFunction(
    LoggingContractor.startContract,
    LoggingContractor.startContractWithExecution
)

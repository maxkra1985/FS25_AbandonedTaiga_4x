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

-- Возвращает накопленную за договор статистику очистки по породе.
-- Сводка хранится только в памяти и выводится при завершении договора.
function LoggingContractor:getContractorAttachmentTypeDiagnostics(jobId, treeTypeName)
    if not LoggingContractor.PERF_DEBUG_ENABLED or jobId == nil then
        return nil
    end

    self.contractorAttachmentDiagnostics = self.contractorAttachmentDiagnostics or {}
    local byJob = self.contractorAttachmentDiagnostics[jobId]
    if byJob == nil then
        byJob = {}
        self.contractorAttachmentDiagnostics[jobId] = byJob
    end

    treeTypeName = treeTypeName or "UNKNOWN"
    local profile = byJob[treeTypeName]
    if profile == nil then
        profile = {
            mainScans = 0,
            firstMain = 0,
            firstFromButt = {},
            firstFromTip = {},
            mainDirections = {},
            detachedDirections = {},
            fallbackStarts = 0,
            fallbackOrientations = {
                A = {calls = 0, reported = 0},
                B = {calls = 0, reported = 0}
            },
            fallbackOffsets = {},
            fallbackVerifiedPositions = 0,
            fallbackReportedWithoutReduction = 0
        }
        byJob[treeTypeName] = profile
    end

    return profile
end


-- Учитывает первый подтверждённый съём листвы с основного ствола.
-- При обратном обходе результат отделён от статистики движения от комля.
function LoggingContractor:recordContractorFirstAttachmentRemoval(profile, stepIndex, distance, fromButt)
    if profile == nil then
        return
    end

    profile.firstMain = profile.firstMain + 1
    local steps = fromButt and profile.firstFromButt or profile.firstFromTip
    steps[stepIndex] = (steps[stepIndex] or 0) + 1
end


-- Выводит накопленную статистику очистки по породам для договора.
-- Промежуточный снимок не сбрасывает данные, итоговый освобождает память.
-- Резервная сетка учитывается отдельно: её широкие плоскости не позволяют
-- определить точную высоту первой листвы по точке вызова.
function LoggingContractor:logContractorAttachmentDiagnostics(jobId, keepStats, processedInSession)
    local byJob = self.contractorAttachmentDiagnostics
        and self.contractorAttachmentDiagnostics[jobId] or nil
    if byJob == nil then
        return
    end

    Logging.info(
        "[LoggingContractorPerf] attachments snapshot job=%d kind=%s processedInSession=%d",
        jobId,
        keepStats and "INTERIM" or "FINAL",
        processedInSession or 0
    )

    local function pairsString(map, numericKeys)
        local keys = {}
        for key in pairs(map) do
            table.insert(keys, key)
        end
        table.sort(keys, function(x, y)
            if numericKeys then
                return x < y
            end
            return tostring(x) < tostring(y)
        end)

        local values = {}
        for _, key in ipairs(keys) do
            table.insert(values, string.format("%s:%d", tostring(key), map[key]))
        end
        return #values > 0 and table.concat(values, ",") or "none"
    end

    local types = {}
    for name in pairs(byJob) do
        table.insert(types, name)
    end
    table.sort(types)

    for _, treeType in ipairs(types) do
        local p = byJob[treeType]
        local forward = 0
        for _, count in pairs(p.firstFromButt) do
            forward = forward + count
        end

        Logging.info(
            "[LoggingContractorPerf] attachments job=%d type=%s scanned=%d firstMain=%d fromButt=%d fromTip=%d fallbackStarts=%d",
            jobId, treeType, p.mainScans, p.firstMain, forward,
            p.firstMain - forward, p.fallbackStarts
        )
        Logging.info(
            "[LoggingContractorPerf] attachments firstSteps job=%d type=%s step=0.10m fromButt={%s} fromTip={%s}",
            jobId, treeType,
            pairsString(p.firstFromButt, true),
            pairsString(p.firstFromTip, true)
        )

        local angles = {}
        for angle, value in pairs(p.mainDirections) do
            table.insert(angles, string.format(
                "%s=%d/%d",
                tostring(angle), value.removed, value.calls
            ))
        end
        table.sort(angles)
        Logging.info(
            "[LoggingContractorPerf] attachments angles job=%d type=%s trunkRemoved/calls {%s}",
            jobId, treeType, #angles > 0 and table.concat(angles, ",") or "none"
        )

        local detachedAngles = {}
        for angle, value in pairs(p.detachedDirections) do
            table.insert(detachedAngles, string.format(
                "%s=%d/%d", tostring(angle), value.removed, value.calls
            ))
        end
        table.sort(detachedAngles)
        if #detachedAngles > 0 then
            Logging.info(
                "[LoggingContractorPerf] attachments angles job=%d type=%s detachedRemoved/calls {%s}",
                jobId, treeType, table.concat(detachedAngles, ",")
            )
        end

        local o = p.fallbackOrientations
        Logging.info(
            "[LoggingContractorPerf] attachments fallback job=%d type=%s A=%d/%d B=%d/%d verifiedPositions=%d reportedNoReduction=%d verifiedOffsets={%s}",
            jobId, treeType, o.A.reported, o.A.calls,
            o.B.reported, o.B.calls, p.fallbackVerifiedPositions,
            p.fallbackReportedWithoutReduction,
            pairsString(p.fallbackOffsets, false)
        )
    end

    if not keepStats then
        self.contractorAttachmentDiagnostics[jobId] = nil
    end
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
function LoggingContractor:logContractorPerfStatsIfDue(force)
    local stats = self:getContractorPerfStats()
    if stats == nil then
        return
    end

    local nowMs = getContractorPerfTimeMs()
    local windowMs = nowMs - stats.startedAtMs
    if windowMs < LoggingContractor.PERF_DEBUG_INTERVAL_MS and not force then
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

    if (stats.counters.profileSpruceCandidates or 0) > 0
        or (stats.counters.profilePineCandidates or 0) > 0
        or (stats.counters.profileStarts or 0) > 0
        or (stats.counters.profileCalls or 0) > 0
        or (stats.counters.profileComplete or 0) > 0 then
        Logging.info(
            "[LoggingContractorPerf] tree address profiles | spruceCandidates=%d spruceMatched=%d pineCandidates=%d pineMatched=%d starts=%d calls=%d removed=%d complete=%d fullScan=%d missingFrame=%d skipFallback=%d remainingAfterFast=%d debugStarts=%d debugCalls=%d debugHits=%d debugRemoved=%d",
            stats.counters.profileSpruceCandidates or 0,
            stats.counters.profileSpruceMatched or 0,
            stats.counters.profilePineCandidates or 0,
            stats.counters.profilePineMatched or 0,
            stats.counters.profileStarts or 0,
            stats.counters.profileCalls or 0,
            stats.counters.profileAttachmentsRemoved or 0,
            stats.counters.profileComplete or 0,
            stats.counters.profileToFullScan or 0,
            stats.counters.profileMissingFrame or 0,
            stats.counters.profileSkippedFallback or 0,
            stats.counters.profileRemainingAfterFast or 0,
            stats.counters.profileDebugStarts or 0,
            stats.counters.profileDebugCalls or 0,
            stats.counters.profileDebugHits or 0,
            stats.counters.profileDebugRemoved or 0
        )
    end

    if stats.metrics.attachmentFallback ~= nil
        or (stats.counters.fallbackStarts or 0) > 0 then
        Logging.info(
            "[LoggingContractorPerf] fallback | %s | starts=%d extraPasses=%d completed=%d unresolved=%d",
            formatContractorPerfMetric(
                "attachmentFallback",
                stats.metrics.attachmentFallback
            ),
            stats.counters.fallbackStarts or 0,
            stats.counters.fallbackExtraPasses or 0,
            stats.counters.fallbackCompleted or 0,
            stats.counters.fallbackUnresolved or 0
        )

        -- Результат native-функции и реальное уменьшение числа attachments
        -- считаем раздельно. Это позволяет обнаружить дорогие проходы,
        -- которые возвращают успех, но не очищают дерево.
        Logging.info(
            "[LoggingContractorPerf] fallback detail | calls true=%d false=%d other=%d positions=%d changed=%d | passes=%d netRemoved=%d noReduction=%d reportedWithoutReduction=%d",
            stats.counters.fallbackCallsTrue or 0,
            stats.counters.fallbackCallsFalse or 0,
            stats.counters.fallbackCallsOther or 0,
            stats.counters.fallbackPositions or 0,
            stats.counters.fallbackPositionsChanged or 0,
            stats.counters.fallbackPassesChecked or 0,
            stats.counters.fallbackAttachmentsNetReduction or 0,
            stats.counters.fallbackPassesNoReduction or 0,
            stats.counters.fallbackPassesReportedButNoReduction or 0
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


-- Типы деревьев с прямым древесным стволом. У таких деревьев крупные
-- видимые ветви относятся к attachments и не требуют splitShape ветвей.
-- Таблица охватывает разновидности сосны из FS25 SplitShapeManager.
local CONTRACTOR_STRAIGHT_TRUNK_TYPES = {
    SPRUCE = true,
    BEECH = true,
    ASPEN = true,
    PINE = true,
    STONEPINE = true,
    LODGEPOLEPINE = true,
    PONDEROSAPINE = true,
    PINUSTABULIFORMIS = true,
    PINUSSYLVESTRIS = true,
    DEADWOOD = true,
    RAVAGED = true
}

-- Проверяет, нужно ли выполнять геометрический поиск крупных ветвей.
function LoggingContractor:getContractorNeedsBranchSearch(splitTypeName)
    return CONTRACTOR_STRAIGHT_TRUNK_TYPES[splitTypeName or ""] ~= true
end


-- Сопоставляет имена I3D-групп конкретным адресным профилям.
-- Один splitType может включать несколько геометрически разных моделей.
-- У пяти моделей дуба, сухостоя, бука и осины свои профили.
local CONTRACTOR_ADDRESS_TREE_MODELS = {
    spruceVar01_stage01 = "spruce1_stage01",
    spruceVar01_stage02 = "spruce1_stage02",
    spruceVar01_stage03 = "spruce1_stage03",
    spruceVar02_stage01 = "spruce2_stage01",
    spruceVar02_stage02 = "spruce2_stage02",
    spruceVar02_stage03 = "spruce2_stage03",
    lodgepolePine_stage01 = "lodgepolePine_stage01",
    lodgepolePine_stage02 = "lodgepolePine_stage02",
    lodgepolePine_stage02Var2 = "lodgepolePine_stage02Var2",
    lodgepolePine_stage03 = "lodgepolePine_stage03",
    lodgepolePine_stage03Var2 = "lodgepolePine_stage03Var2",
    pinusSylvestris_stage01 = "pinusSylvestris_stage01",
    pinusSylvestris_stage02 = "pinusSylvestris_stage02",
    pinusSylvestris_stage03 = "pinusSylvestris_stage03",
    pinusSylvestris_stage04 = "pinusSylvestris_stage04",
    pinusSylvestris_stage05 = "pinusSylvestris_stage05",
    pinusTabuliformis_stage01 = "pinusTabuliformis_stage01",
    pinusTabuliformis_stage02 = "pinusTabuliformis_stage02",
    pinusTabuliformis_stage03 = "pinusTabuliformis_stage03",
    pinusTabuliformis_stage04 = "pinusTabuliformis_stage04",
    pinusTabuliformis_stage05 = "pinusTabuliformis_stage05",
    oak_stage01 = "oak_stage01",
    oak_stage02 = "oak_stage02",
    oak_stage03 = "oak_stage03",
    oak_stage04 = "oak_stage04",
    oak_stage05 = "oak_stage05",
    deadwood = "deadwood",
    treePineRavaged_big = "treePineRavaged_big",
    betulaErmanii_stage01 = "betulaErmanii_stage01",
    betulaErmanii_stage02 = "betulaErmanii_stage02",
    betulaErmanii_stage03 = "betulaErmanii_stage03",
    betulaErmanii_stage04 = "betulaErmanii_stage04",
    beech_stage01 = "beech_stage01",
    beech_stage02 = "beech_stage02",
    beech_stage02_var02 = "beech_stage02_var02",
    beech_stage02_var03 = "beech_stage02_var03",
    beech_stage03 = "beech_stage03",
    beech_stage04 = "beech_stage04",
    beech_stage05 = "beech_stage05",
    beech_stage06_var01 = "beech_stage06_var01",
    beech_stage06_var02 = "beech_stage06_var02",
    aspen_stage01 = "aspen_stage01",
    aspen_stage02 = "aspen_stage02",
    aspen_stage03 = "aspen_stage03",
    aspen_stage04 = "aspen_stage04",
    aspen_stage05 = "aspen_stage05",
    aspen_stage06_var01 = "aspen_stage06_var01",
    aspen_stage06_var02 = "aspen_stage06_var02"
}

-- Возвращает название конкретной исходной I3D-модели по её родительской
-- transform-group. Различает варианты ели, сосны, сухостоя, бука и осины.
function LoggingContractor:getContractorTreeModelProfile(shape, splitTypeName)
    if (splitTypeName ~= "SPRUCE" and splitTypeName ~= "LODGEPOLEPINE" and splitTypeName ~= "PINUSSYLVESTRIS" and splitTypeName ~= "PINUSTABULIFORMIS" and splitTypeName ~= "OAK" and splitTypeName ~= "DEADWOOD" and splitTypeName ~= "RAVAGED" and splitTypeName ~= "BETULAERMANII" and splitTypeName ~= "BEECH" and splitTypeName ~= "ASPEN")
        or shape == nil or not entityExists(shape) then
        return nil
    end

    -- У экземпляра карты между shape и именованной группой модели могут
    -- присутствовать дополнительные transform-group: проверяем лишь родителей.
    local parent = getParent(shape)
    for _ = 1, 4 do
        if parent == nil or parent == 0 or not entityExists(parent) then
            break
        end
        local name = CONTRACTOR_ADDRESS_TREE_MODELS[getName(parent)]
        if name ~= nil then
            return name
        end
        parent = getParent(parent)
    end

    return nil
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
    job.pendingStartCount = 0
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

    -- Выбираем исходную опорную точку единожды при заключении договора,
    -- чтобы первая партия не повторяла тяжёлый поиск доступного края участка.
    -- Существующая маркировка уже учтена; новая по-прежнему перенесёт маршрут.
    local initialNode = self:selectNextContractTarget(job, job.targetNodes)
    if initialNode ~= nil and entityExists(initialNode) then
        local x, _, z = getWorldTranslation(initialNode)
        job.routeAnchorX = x
        job.routeAnchorZ = z
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
    local splitTypeName = self:getContractorSplitTypeName(shape)
    local profileName = self:getContractorTreeModelProfile(shape, splitTypeName)
    -- Профиль включается только при точном совпадении имени I3D-группы.
    local useAddressProfile = profileName ~= nil

    if splitTypeName == "SPRUCE" or splitTypeName == "LODGEPOLEPINE" then
        local prefix = splitTypeName == "SPRUCE" and "profileSpruce" or "profilePine"
        self:addContractorPerfCounter(prefix .. "Candidates", 1)
        if useAddressProfile then
            self:addContractorPerfCounter(prefix .. "Matched", 1)
        end
    end
    local profileSourceFrame = nil

    if useAddressProfile then
        -- Запоминаем исходный базис I3D до разделения: динамический shape
        -- после спила может получить другую локальную систему координат.
        local x0, y0, z0 = localToWorld(shape, 0, 0, 0)
        local xx, xy, xz = localDirectionToWorld(shape, 1, 0, 0)
        local yx, yy, yz = localDirectionToWorld(shape, 0, 1, 0)
        local zx, zy, zz = localDirectionToWorld(shape, 0, 0, 1)
        profileSourceFrame = {
            origin = {x0, y0, z0},
            axisX = {xx, xy, xz},
            axisY = {yx, yy, yz},
            axisZ = {zx, zy, zz}
        }
    end

    return {
        sourceShape = shape,
        shape = shape,
        splitTypeName = splitTypeName,
        profileName = profileName,
        profileSourceFrame = profileSourceFrame,
        profileSourceOrigin = profileSourceFrame ~= nil
            and {profileSourceFrame.origin[1], profileSourceFrame.origin[2], profileSourceFrame.origin[3]}
            or nil,
        treeX = treeX,
        treeY = treeY,
        treeZ = treeZ,
        phase = "INITIAL_CUT",
        hadMutation = false,
        waitForSyncGeneration = 0
    }
end


-- Временно фиксирует основной ствол на время очистки attachments и ветвей.
-- При изменении split-shape освобождает прежнюю часть и фиксирует новую.
-- Отделённые ветви и брёвна в этот режим не переводятся.
function LoggingContractor:freezeContractorPruningTrunk(state, shape)
    if state.frozenShape ~= nil
        and state.frozenShape ~= shape
        and entityExists(state.frozenShape)
        and getRigidBodyType(state.frozenShape) == RigidBodyType.KINEMATIC then
        setRigidBodyType(state.frozenShape, RigidBodyType.DYNAMIC)
    end

    state.frozenShape = nil
    if shape == nil or not entityExists(shape) then
        return false
    end

    local rigidType = getRigidBodyType(shape)
    if rigidType == RigidBodyType.DYNAMIC then
        setRigidBodyType(shape, RigidBodyType.KINEMATIC)
    elseif rigidType ~= RigidBodyType.KINEMATIC then
        Logging.warning(
            "[LoggingContractor] Cannot freeze trunk: shape=%s rigidType=%s",
            tostring(shape), tostring(rigidType)
        )
        return false
    end

    if getRigidBodyType(shape) ~= RigidBodyType.KINEMATIC then
        Logging.warning(
            "[LoggingContractor] Trunk freeze failed: shape=%s",
            tostring(shape)
        )
        return false
    end

    state.frozenShape = shape
    return true
end


-- Возвращает основному стволу динамическую физику перед раскряжёвкой
-- либо при завершении очистки, если раскряжёвка отключена.
function LoggingContractor:releaseContractorPruningTrunk(state)
    local shape = state.frozenShape
    state.frozenShape = nil

    if shape ~= nil and entityExists(shape)
        and getRigidBodyType(shape) == RigidBodyType.KINEMATIC then
        setRigidBodyType(shape, RigidBodyType.DYNAMIC)
    end
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

    -- Преобразуем исходный базис модели в локальную систему только что
    -- отделённого ствола. Далее профильные точки следуют за его поворотом
    -- и движением без использования уже удалённого исходного shape.
    if state.profileSourceFrame ~= nil then
        local sourceFrame = state.profileSourceFrame
        local o = sourceFrame.origin
        local a = sourceFrame.axisX
        local b = sourceFrame.axisY
        local d = sourceFrame.axisZ
        local ox, oy, oz = worldToLocal(trunkShape, o[1], o[2], o[3])
        local xx, xy, xz = worldDirectionToLocal(trunkShape, a[1], a[2], a[3])
        local yx, yy, yz = worldDirectionToLocal(trunkShape, b[1], b[2], b[3])
        local zx, zy, zz = worldDirectionToLocal(trunkShape, d[1], d[2], d[3])
        state.profileLocalFrame = {
            origin = {ox, oy, oz},
            axisX = {xx, xy, xz},
            axisY = {yx, yy, yz},
            axisZ = {zx, zy, zz}
        }
        state.profileSourceFrame = nil
    end

    -- Зафиксируем положение отделённого ствола сразу после splitShape.
    -- После удаления пня сравним его с текущим положением и проверим
    -- смещение исходного модельного базиса в мировых координатах.
    if state.profileLocalFrame ~= nil then
        local frame = state.profileLocalFrame
        local px, py, pz = localToWorld(
            trunkShape, frame.origin[1], frame.origin[2], frame.origin[3]
        )
        local sx, sy, sz = getWorldTranslation(trunkShape)
        state.profileSplitOrigin = {px, py, pz}
        state.profileSplitTranslation = {sx, sy, sz}
        Logging.info(
            "[LoggingContractorFrame] phase=AFTER_SPLIT model=%s shape=%s sourceOrigin=(%.3f,%.3f,%.3f) trunkTranslation=(%.3f,%.3f,%.3f) modelOrigin=(%.3f,%.3f,%.3f)",
            tostring(state.profileName), tostring(trunkShape),
            state.profileSourceOrigin[1], state.profileSourceOrigin[2],
            state.profileSourceOrigin[3],
            sx, sy, sz, px, py, pz
        )
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

    -- Пень оставляем до окончания раскряжёвки, а основной ствол
    -- удерживаем в KINEMATIC до завершения очистки.
    local frozen = self:freezeContractorPruningTrunk(state, trunkShape)
    Logging.info(
        "[LoggingContractorPhysics] phase=AFTER_SPLIT model=%s shape=%s frozen=%s stumpCount=%d",
        tostring(state.profileName or state.splitTypeName),
        tostring(trunkShape), tostring(frozen), #state.stumpShapes
    )
    state.phase = "PRUNE_INIT"

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
        -- Если раскряжёвка отключена, освобождаем очищенный ствол до
        -- удаления пня и даём физике синхронизироваться в отдельном tick.
        if state.frozenShape ~= nil then
            if not allowMutation then
                return false, false, false
            end

            self:releaseContractorPruningTrunk(state)
            return false, true, false
        end

        while #state.stumpShapes > 0 do
            local stumpShape = table.remove(state.stumpShapes, 1)

            if stumpShape ~= nil and entityExists(stumpShape) then
                if not allowMutation then
                    table.insert(state.stumpShapes, 1, stumpShape)
                    return false, false, false
                end

                self:removeContractorStump(stumpShape)
                state.hadMutation = true

                -- Контроль смещения динамического ствола после удаления пня.
                -- Профиль остаётся в локальной системе ствола и поэтому
                -- пересчитывается относительно его фактической трансформации.
                if state.profileLocalFrame ~= nil
                    and state.shape ~= nil
                    and entityExists(state.shape) then
                    local frame = state.profileLocalFrame
                    local px, py, pz = localToWorld(
                        state.shape,
                        frame.origin[1], frame.origin[2], frame.origin[3]
                    )
                    local tx, ty, tz = getWorldTranslation(state.shape)
                    local previous = state.profileSplitOrigin
                    local oldTranslation = state.profileSplitTranslation
                    if previous ~= nil and oldTranslation ~= nil then
                        Logging.info(
                            "[LoggingContractorFrame] phase=AFTER_STUMP model=%s shape=%s trunkTranslation=(%.3f,%.3f,%.3f) modelOrigin=(%.3f,%.3f,%.3f) originDelta=(%+.3f,%+.3f,%+.3f) translationDelta=(%+.3f,%+.3f,%+.3f)",
                            tostring(state.profileName), tostring(state.shape),
                            tx, ty, tz, px, py, pz,
                            px - previous[1], py - previous[2], pz - previous[3],
                            tx - oldTranslation[1],
                            ty - oldTranslation[2],
                            tz - oldTranslation[3]
                        )
                    end
                end

                if #state.stumpShapes == 0 then
                    state.phase = "DONE"
                end

                return false, true, false
            end
        end

        state.phase = "DONE"
        return false, false, false
    end

    if state.phase == "DONE" then
        return true, false, state.buckingSuccess == true
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

        -- Породу берём с исходного дерева, а не с динамических обломков.
        -- Один профиль используется основной очисткой и резервным поиском.
        state.pruning.attachmentTypeStats =
            self:getContractorAttachmentTypeDiagnostics(
                job.jobId, state.splitTypeName
            )

        state.pruning.attachmentProfileName = state.profileName
        state.pruning.attachmentProfileFrame = state.profileLocalFrame

        -- Воспроизводим проверенные ручные резы дубов и большой берёзы
        -- после очистки листвы. Геометрический поиск ветвей для них заменён
        -- адресными резами, сохранёнными в исходном базисе I3D.
        if (state.profileName == "oak_stage03"
            or state.profileName == "oak_stage05"
            or state.profileName == "betulaErmanii_stage04")
            and job.pruneLargeBranches ~= false then
            state.pruning.recordedCutIndex = 1
            state.pruning.phase = "ATTACHMENTS"
        end

        -- Для остальных стадий берёзы сначала выполняем адресную очистку
        -- листвы, затем запускаем обычный поиск и отделение древесных ветвей.
        -- У stage04 ветви уже обрабатываются записанными ручными резами.
        if state.splitTypeName == "BETULAERMANII"
            and job.pruneLargeBranches ~= false
            and state.pruning.recordedCutIndex == nil then
            state.pruning.branchesAfterAttachments = true
            state.pruning.phase = "ATTACHMENTS"
        end

        if job.pruneLargeBranches == false
            or not self:getContractorNeedsBranchSearch(state.splitTypeName) then
            -- Для прямоствольных пород не выполняем дорогой поиск и отделение
            -- древесных ветвей. Основная и резервная очистка листвы сохраняются.
            state.pruning.phase = "ATTACHMENTS"
        end

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
            -- После отделения крупной ветви основной split-shape может
            -- смениться. Новую часть также фиксируем до конца очистки.
            self:freezeContractorPruningTrunk(
                state, state.pruning.shape
            )
            return false, true, false
        end

        if done then
            state.shape = state.pruning.shape
            state.trunkLength = state.pruning.length
            if job.pruneLargeBranches == false then
                -- Без распила крупных ветвей оставляем целый очищенный
                -- ствол: пропускаем BUCK_INIT/BUCK и завершаем удалением пня.
                state.buckingSuccess = true
                state.phase = "REMOVE_STUMP"
            else
                state.phase = "BUCK_INIT"
            end
        end

        return false, false, false
    end

    if state.phase == "BUCK_INIT" then
        -- Пока создаём состояние раскряжёвки, основной ствол остаётся
        -- неподвижным. Отпустим его непосредственно перед разрезом.
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
        -- Разрешаем инерцию непосредственно перед первым рабочим шагом
        -- раскряжёвки. Отделённые брёвна получают динамическую физику.
        if state.frozenShape ~= nil and allowMutation then
            self:releaseContractorPruningTrunk(state)
        end
        local done, changed, success =
            self:advanceContractorBuckingState(state.bucking, allowMutation)

        if changed then
            state.hadMutation = true
            -- После любого изменения формы ждём сетевой tick, в том числе
            -- при неудачной раскряжёвке с неоднозначным результатом.
            return false, true, false
        end

        if done then
            state.shape = state.bucking.shape
            state.failureReason = state.bucking.failureReason
            state.buckingSuccess = success == true
            -- Даже при неудачной раскряжёвке нельзя оставлять пень.
            if #state.stumpShapes > 0 then
                state.phase = "REMOVE_STUMP"
                return false, false, false
            end
            state.phase = "DONE"
            return true, false, state.buckingSuccess
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
            pruneLargeBranches = data.pruneLargeBranches,
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
        job.pruneLargeBranches = data.pruneLargeBranches ~= false
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

    if (job.failedTreeCount or 0) > 0 then
        Logging.warning(
            "[LoggingContractor] Contract finished with %d unfinished tree(s): job=%d; wood left in world",
            job.failedTreeCount, job.jobId
        )
    end

    self:logContractorAttachmentDiagnostics(
        job.jobId, false, job.attachmentDiagnosticsProcessedTrees or 0
    )
    self:broadcastJobProgress(job)
end


-- Начисляет право начать деревья за рабочие двухминутные такты.
-- Количество оплаченной техники определяет число новых целей за такт,
-- а фактический запуск ограничивается числом свободных машин договора.
function LoggingContractor:processJobBatch(job, batchCount)
    batchCount = math.max(math.floor(batchCount or 1), 0)
    if batchCount == 0 then
        return
    end

    job.pendingStartCount = math.min(
        (job.pendingStartCount or 0) + batchCount * job.equipmentCount,
        #(job.targetNodes or {})
    )
end

-- Заполняет слоты по суммарному количеству оплаченной техники без общего
-- искусственного предела. В каждом договоре одновременно обрабатывается
-- не больше деревьев, чем единиц техники; договоры чередуются по jobId.
function LoggingContractor:fillContractorProcessingSlots()
    local jobs = {}
    local running = 0
    local totalEquipment = 0

    for _, job in pairs(self.activeJobs or {}) do
        if job.isActive then
            totalEquipment = totalEquipment + job.equipmentCount
            running = running + #(job.processingTrees or {})
            if (job.pendingStartCount or 0) > 0
                and #(job.targetNodes or {}) > 0 then
                table.insert(jobs, job)
            end
        end
    end

    local freeSlots = math.max(
        totalEquipment - running,
        0
    )
    if freeSlots == 0 or #jobs == 0 then
        return
    end

    table.sort(jobs, function(a, b)
        return a.jobId < b.jobId
    end)

    local index = 1
    local previousJobId = self.lastContractorScheduledJobId or 0
    for i, job in ipairs(jobs) do
        if job.jobId > previousJobId then
            index = i
            break
        end
    end

    local refreshed = {}
    local startedJobs = {}
    local stalled = 0
    local started = 0
    local perfStartMs = LoggingContractor.PERF_DEBUG_ENABLED
        and getContractorPerfTimeMs() or nil

    -- После неудачного полного обхода прекращаем попытки до следующего update.
    while freeSlots > 0 and stalled < #jobs do
        local job = jobs[index]
        local didStart = false
        local allowedForJob = job.equipmentCount

        if job.isActive
            and (job.pendingStartCount or 0) > 0
            and #(job.processingTrees or {}) < allowedForJob then
            if not refreshed[job] then
                -- Проверяем ожидающие деревья один раз на договор за update.
                self:refreshJobTargets(job)
                job.pendingStartCount = math.min(
                    job.pendingStartCount,
                    #job.targetNodes
                )
                refreshed[job] = true
            end

            if job.pendingStartCount > 0 and #job.targetNodes > 0 then
                local selectStartMs = LoggingContractor.PERF_DEBUG_ENABLED
                    and getContractorPerfTimeMs() or nil
                local shape = self:selectNextContractTarget(
                    job, job.targetNodes
                )
                if selectStartMs ~= nil then
                    self:recordContractorPerfMetric(
                        "selectTarget",
                        getContractorPerfTimeMs() - selectStartMs,
                        #job.targetNodes
                    )
                end

                if shape ~= nil and entityExists(shape) then
                    local state = self:createContractorTreeProcess(job, shape)
                    if state ~= nil then
                        self:removePendingContractTarget(job, shape)
                        table.insert(job.processingTrees, state)
                        job.pendingStartCount = job.pendingStartCount - 1
                        startedJobs[job] = true
                        self.lastContractorScheduledJobId = job.jobId
                        self:addContractorPerfCounter("treesStarted", 1)
                        freeSlots = freeSlots - 1
                        started = started + 1
                        didStart = true
                    end
                end
            end
        end

        stalled = didStart and 0 or stalled + 1
        index = index % #jobs + 1
    end

    if perfStartMs ~= nil then
        self:recordContractorPerfMetric(
            "batch", getContractorPerfTimeMs() - perfStartMs, started
        )
    end

    for job in pairs(refreshed) do
        if job.remainingTrees == 0 then
            self:finishJob(job)
        elseif startedJobs[job] then
            self:broadcastJobProgress(job)
        end
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
                        state.sourceShape, job.farmlandId
                    ) then
                    -- Неизменённую стоящую цель можно безопасно повторить.
                    table.insert(job.targetNodes, state.sourceShape)
                    self:addContractorPerfCounter("treesRequeued", 1)
                    resolved = false
                elseif state.hadMutation then
                    -- Незавершённое дерево не идёт в счётчик успешной работы;
                    -- ссылка на оставшийся ствол сохраняется до конца сессии.
                    job.failedTreeCount = (job.failedTreeCount or 0) + 1
                    if state.shape ~= nil and entityExists(state.shape) then
                        table.insert(job.failedTreeShapes, state.shape)
                    end
                    Logging.warning(
                        "[LoggingContractor] Tree unfinished: job=%d source=%s trunk=%s phase=%s reason=%s position=(%.2f, %.2f)",
                        job.jobId, tostring(state.sourceShape),
                        tostring(state.shape), tostring(state.phase),
                        tostring(state.failureReason or "processing did not complete"),
                        state.treeX or 0, state.treeZ or 0
                    )
                    self:addContractorPerfCounter("treesFailed", 1)
                end

                if resolved then
                    job.remainingTrees = math.max(
                        (job.remainingTrees or 1) - 1,
                        0
                    )
                end

                -- Периодически сохраняем в log.txt снимок статистики по
                -- породам, не дожидаясь завершения большого договора.
                -- Считаем только реально обработанные подрядчиком деревья:
                -- удачные и с изменённой геометрией, но не повторные попытки.
                if LoggingContractor.PERF_DEBUG_ENABLED
                    and (success or state.hadMutation) then
                    local processed =
                        (job.attachmentDiagnosticsProcessedTrees or 0) + 1
                    job.attachmentDiagnosticsProcessedTrees = processed

                    if processed % 25 == 0 then
                        self:logContractorAttachmentDiagnostics(
                            job.jobId, true, processed
                        )
                    end
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
            -- В рабочее время обрабатываем активные деревья, а освободившиеся
            -- слоты ниже заполняем из очередей уже начисленных рабочих тактов.
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

                    self:processJobBatch(job, batchCount)
                end
            end
        end
    end

    if isWorkingTime and hasActiveJob then
        -- Пополняем слоты после завершения деревьев и начисления рабочих тактов.
        -- Это также исключает обход новых целей в середине цикла обработки.
        self:fillContractorProcessingSlots()
    end

    if perfStartMs ~= nil and hasActiveJob then
        self:recordContractorPerfMetric("frameDt", dt)
        self:recordContractorPerfMetric(
            "update",
            getContractorPerfTimeMs() - perfStartMs
        )
        -- После последнего завершённого договора выводим неполное окно
        -- перед сбросом профилировщика: иначе его последние секунды теряются.
        self:logContractorPerfStatsIfDue(not self:hasAnyActiveJob())
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
function LoggingContractor:startContractWithExecution(superFunc, connection, farmlandId, equipmentCount, logLength, onlyMarkedTrees, pruneLargeBranches)
    local state, data = superFunc(self, connection, farmlandId, equipmentCount, logLength, onlyMarkedTrees, pruneLargeBranches)

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

--[[
    LoggingContractorTestPass1

    Тестовый проход №1 для обработки спиленного дерева подрядчиком.

    Цели прохода:
    1. Проверить removeSplitShapeAttachments() как единственный алгоритм
       удаления attachments. На каждом шаге 0.25 м выполняются пять вызовов.
       Центральный вызов ориентирован вдоль оси ствола. Четыре наружных вызова
       располагаются чуть за поверхностью древесины и направлены радиально
       снаружи к центру ствола. Количество attachments проверяется после всей
       группы, а возвращаемый bool сохраняется отдельно для каждой точки.
    2. Проверить новый локальный алгоритм снятия крупных ветвей. В пределах
       первых 5 м ствола после обнаружения одностороннего утолщения выполняется
       увеличенный продольный рез размером до 5x6 м чуть снаружи нормальной
       поверхности ствола. После успешного реза та же точка измеряется повторно;
       переход к следующему шагу выполняется только когда кандидатов больше нет.

    Чтобы результаты теста не смешивались, прежние delimb-алгоритмы этого
    прохода отключены. После окончания эксперимента модуль можно снять из
    загрузки без изменения основной реализации подрядчиков.
]]

LoggingContractor.TEST_PASS1_SCAN_STEP = 0.25
LoggingContractor.TEST_PASS1_BRANCH_SCAN_LENGTH = 5.0
LoggingContractor.TEST_PASS1_BRANCH_BASELINE_SAMPLES = 4
LoggingContractor.TEST_PASS1_BRANCH_MAX_TOTAL_CUTS = 8
LoggingContractor.TEST_PASS1_BRANCH_MAX_CUTS_PER_STEP = 4
LoggingContractor.TEST_PASS1_BRANCH_CUT_LENGTH = 5.0
LoggingContractor.TEST_PASS1_BRANCH_CUT_BACK = 0.25
LoggingContractor.TEST_PASS1_BRANCH_CUT_WIDTH = 6.0
LoggingContractor.TEST_PASS1_BRANCH_OUTSETS = {0.10, 0.05, 0.02, 0.00}

LoggingContractor.TEST_PASS1_ATTACHMENT_THICKNESS = 0.30
LoggingContractor.TEST_PASS1_ATTACHMENT_MIN_SIZE = 1.00
LoggingContractor.TEST_PASS1_ATTACHMENT_MAX_SIZE = 2.00
LoggingContractor.TEST_PASS1_ATTACHMENT_SIZE_FACTOR = 1.50
LoggingContractor.TEST_PASS1_ATTACHMENT_RADIAL_OUTSET = 0.10


-- Возвращает размер плоскости testSplitShape с запасом относительно текущего
-- split-shape. Большой размер нужен только для измерения сечения и не задаёт
-- область удаления attachments.
function LoggingContractor:getContractorTestPass1ScanSize(shape)
    local sizeX, sizeY, sizeZ = self:getContractorSplitShapeStats(shape)
    return math.max(sizeX, sizeY, sizeZ, 4) + 2
end


-- Снимает поперечное сечение в заданной точке основной оси ствола.
function LoggingContractor:sampleContractorTestPass1Section(
    shape,
    baseX,
    baseY,
    baseZ,
    axisX,
    axisY,
    axisZ,
    upX,
    upY,
    upZ,
    distance
)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return nil
    end

    local scanSize = self:getContractorTestPass1ScanSize(shape)
    local sample = self:sampleContractorCrossSection(
        shape,
        baseX + axisX * distance,
        baseY + axisY * distance,
        baseZ + axisZ * distance,
        axisX,
        axisY,
        axisZ,
        upX,
        upY,
        upZ,
        scanSize
    )

    if sample ~= nil then
        sample.distance = distance
    end

    return sample
end


-- Возвращает все стороны текущего сечения, которые соответствуют критериям
-- крупной ветви. В отличие от основной реализации функция не выбирает только
-- один вариант: это позволяет после неудачного реза проверить остальные стороны
-- в той же самой точке.
function LoggingContractor:getContractorTestPass1BranchCandidates(sample, baseline, nextSample, blockedDirections)
    local baselineDiameter = math.max(baseline.widthUp, baseline.widthSide)
    local growthThreshold = math.max(
        LoggingContractor.BRANCH_MIN_SIDE_GROWTH,
        baselineDiameter * LoggingContractor.BRANCH_SIDE_GROWTH_FACTOR
    )
    local widthThreshold = math.max(
        LoggingContractor.BRANCH_MIN_WIDTH_GROWTH,
        baselineDiameter * LoggingContractor.BRANCH_WIDTH_GROWTH_FACTOR
    )
    local candidates = {}

    for _, direction in ipairs({"SIDE_POS", "SIDE_NEG", "UP_POS", "UP_NEG"}) do
        if blockedDirections == nil or not blockedDirections[direction] then
            local growth, widthGrowth = self:getContractorBranchSideGrowth(sample, baseline, direction)
            local persistent = true

            if nextSample ~= nil then
                local nextGrowth, nextWidthGrowth = self:getContractorBranchSideGrowth(
                    nextSample,
                    baseline,
                    direction
                )
                persistent = nextGrowth >= growthThreshold * LoggingContractor.BRANCH_PERSISTENCE_FACTOR
                    and nextWidthGrowth >= widthThreshold * LoggingContractor.BRANCH_PERSISTENCE_FACTOR
            end

            if growth >= growthThreshold
                and widthGrowth >= widthThreshold
                and persistent then
                table.insert(candidates, {
                    direction = direction,
                    growth = growth,
                    widthGrowth = widthGrowth,
                    growthThreshold = growthThreshold,
                    widthThreshold = widthThreshold,
                    baselineDiameter = baselineDiameter
                })
            end
        end
    end

    table.sort(candidates, function(a, b)
        return a.growth > b.growth
    end)

    return candidates
end


-- Формирует параметры увеличенной продольной плоскости для ветви, найденной
-- в конкретном сечении. Плоскость начинается немного ниже точки обнаружения и
-- продолжается до 5 м вверх по стволу. Поперечная ширина 6 м выбрана намеренно
-- большой для эксперимента: она должна исключить нехватку охвата как причину
-- отсутствия splitShape на раскидистых деревьях.
function LoggingContractor:getContractorTestPass1BranchCutGeometry(
    shape,
    sample,
    baseline,
    candidate,
    baseX,
    baseY,
    baseZ,
    axisX,
    axisY,
    axisZ,
    upX,
    upY,
    upZ,
    trunkLength
)
    local normalX, normalY, normalZ = self:getContractorBranchDirection(
        candidate.direction,
        sample.sideX,
        sample.sideY,
        sample.sideZ,
        upX,
        upY,
        upZ
    )

    if normalX == nil then
        return nil
    end

    normalX, normalY, normalZ = MathUtil.vector3Normalize(normalX, normalY, normalZ)

    local cutStart = math.max(0, sample.distance - LoggingContractor.TEST_PASS1_BRANCH_CUT_BACK)
    local cutEnd = math.min(
        trunkLength,
        cutStart + LoggingContractor.TEST_PASS1_BRANCH_CUT_LENGTH
    )
    local cutLength = cutEnd - cutStart
    if cutLength <= 0.05 then
        return nil
    end

    local cutDistance = (cutStart + cutEnd) * 0.5
    local cutWidth = LoggingContractor.TEST_PASS1_BRANCH_CUT_WIDTH
    local surfaceOffset = math.max(
        self:getContractorBranchSurfaceOffset(baseline, candidate.direction),
        candidate.baselineDiameter * 0.25
    )
    local axisPointX = baseX + axisX * cutDistance
    local axisPointY = baseY + axisY * cutDistance
    local axisPointZ = baseZ + axisZ * cutDistance

    return {
        normalX = normalX,
        normalY = normalY,
        normalZ = normalZ,
        upX = axisX,
        upY = axisY,
        upZ = axisZ,
        axisPointX = axisPointX,
        axisPointY = axisPointY,
        axisPointZ = axisPointZ,
        surfaceOffset = surfaceOffset,
        cutStart = cutStart,
        cutEnd = cutEnd,
        sizeY = cutLength,
        sizeZ = cutWidth
    }
end

-- Выполняет один локальный продольный отпил. Если splitShape создал только одну
-- новую часть, она всё равно принимается как новый основной shape, чтобы после
-- замены исходного split-shape не потерять ссылку. Успешным снятием ветви
-- считается только появление хотя бы одной отдельной части помимо ствола.
function LoggingContractor:cutContractorTestPass1Branch(
    shape,
    sample,
    baseline,
    candidate,
    baseX,
    baseY,
    baseZ,
    axisX,
    axisY,
    axisZ,
    upX,
    upY,
    upZ,
    trunkLength
)
    local geometry = self:getContractorTestPass1BranchCutGeometry(
        shape,
        sample,
        baseline,
        candidate,
        baseX,
        baseY,
        baseZ,
        axisX,
        axisY,
        axisZ,
        upX,
        upY,
        upZ,
        trunkLength
    )

    if geometry == nil then
        return shape, trunkLength, false, 0
    end

    local currentShape = shape
    local currentLength = trunkLength
    local shapeChanged = false

    for _, outset in ipairs(LoggingContractor.TEST_PASS1_BRANCH_OUTSETS) do
        if currentShape == nil or currentShape == 0 or not entityExists(currentShape) then
            break
        end

        local cutOffset = geometry.surfaceOffset + outset
        local cutX = geometry.axisPointX + geometry.normalX * cutOffset
        local cutY = geometry.axisPointY + geometry.normalY * cutOffset
        local cutZ = geometry.axisPointZ + geometry.normalZ * cutOffset
        local probe = self:probeContractorLongitudinalCut(
            currentShape,
            cutX,
            cutY,
            cutZ,
            geometry.normalX,
            geometry.normalY,
            geometry.normalZ,
            geometry.upX,
            geometry.upY,
            geometry.upZ,
            geometry.sizeY,
            geometry.sizeZ
        )

        Logging.info(
            "[LoggingContractor][BranchCutTry] shape=%d d=%.2f direction=%s outset=%.2f surface=%.3f span=%.2f..%.2f plane=%.2fx%.2f probe=%s",
            currentShape,
            sample.distance,
            candidate.direction,
            outset,
            geometry.surfaceOffset,
            geometry.cutStart,
            geometry.cutEnd,
            geometry.sizeY,
            geometry.sizeZ,
            probe == nil and "none" or string.format("%.2fx%.2f", probe.widthY, probe.widthZ)
        )

        if probe ~= nil then
            local parts = self:splitContractorShapeSized(
                currentShape,
                cutX,
                cutY,
                cutZ,
                geometry.normalX,
                geometry.normalY,
                geometry.normalZ,
                geometry.upX,
                geometry.upY,
                geometry.upZ,
                geometry.sizeY,
                geometry.sizeZ
            )

            if #parts > 0 then
                local mainPart, mainAxisLength, mainMeasure = self:selectContractorMainStemPart(
                    parts,
                    baseX,
                    baseY,
                    baseZ,
                    axisX,
                    axisY,
                    axisZ
                )

                if mainPart ~= nil and mainPart.shape ~= nil and entityExists(mainPart.shape) then
                    local oldShape = currentShape
                    currentShape = mainPart.shape
                    currentLength = mainAxisLength > 0 and mainAxisLength or currentLength
                    shapeChanged = true
                    local detachedCount = 0

                    for _, part in ipairs(parts) do
                        if part.shape ~= nil
                            and part.shape ~= currentShape
                            and entityExists(part.shape) then
                            detachedCount = detachedCount + 1
                            local measure, sizeX, sizeY, sizeZ, convexes, attachments =
                                self:getContractorShapeMeasure(part.shape)

                            Logging.info(
                                "[LoggingContractor][BranchDetached] shape=%d d=%.2f direction=%s measure=%.3f size=%.2fx%.2fx%.2f convexes=%d attachments=%d",
                                part.shape,
                                sample.distance,
                                candidate.direction,
                                measure,
                                sizeX,
                                sizeY,
                                sizeZ,
                                convexes,
                                attachments
                            )

                            self:separateContractorBranch(
                                part.shape,
                                geometry.normalX,
                                geometry.normalY,
                                geometry.normalZ
                            )
                            local angularX, angularY, angularZ = self:getContractorFallAngularVelocity(upX, upY, upZ)
                            self:applyContractorFall(part.shape, angularX, angularY, angularZ)
                        end
                    end

                    Logging.info(
                        "[LoggingContractor][BranchCutResult] oldShape=%d mainShape=%d d=%.2f direction=%s outset=%.2f parts=%d detached=%d mainLength=%.2f mainMeasure=%.3f",
                        oldShape,
                        currentShape,
                        sample.distance,
                        candidate.direction,
                        outset,
                        #parts,
                        detachedCount,
                        currentLength,
                        mainMeasure
                    )

                    if detachedCount > 0 then
                        return currentShape, currentLength, true, detachedCount
                    end
                end
            end
        end
    end

    if shapeChanged then
        Logging.info(
            "[LoggingContractor][BranchCutNoDetach] shape=%d d=%.2f direction=%s geometry changed but no branch detached",
            currentShape,
            sample.distance,
            candidate.direction
        )
    end

    return currentShape, currentLength, false, 0
end


-- Выполняет первый тестовый алгоритм удаления attachments. Центральный вызов
-- остаётся контрольным и ориентирован вдоль оси ствола. Четыре наружных вызова
-- начинаются на 10 см за фактической поверхностью текущего сечения и направлены
-- радиально к центру. Это имитирует подвод сучкорезного механизма извне.
-- Счётчик attachments читается только до и после всей группы из пяти вызовов.
function LoggingContractor:removeContractorTestPass1AttachmentsAtStep(
    shape,
    sample,
    baseX,
    baseY,
    baseZ,
    axisX,
    axisY,
    axisZ,
    upX,
    upY,
    upZ,
    distance
)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return 0
    end

    local _, _, _, _, attachmentsBefore = self:getContractorSplitShapeStats(shape)
    if attachmentsBefore <= 0 then
        return 0
    end

    local axisPointX = baseX + axisX * distance
    local axisPointY = baseY + axisY * distance
    local axisPointZ = baseZ + axisZ * distance
    local sideX, sideY, sideZ = MathUtil.crossProduct(axisX, axisY, axisZ, upX, upY, upZ)

    if MathUtil.vector3Length(sideX, sideY, sideZ) < 0.001 then
        return 0
    end

    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    local centerUp = sample ~= nil and sample.centerUp or 0
    local centerSide = sample ~= nil and sample.centerSide or 0
    local radiusUpPos = sample ~= nil and math.max(sample.maxUp - sample.centerUp, 0) or 0.5
    local radiusUpNeg = sample ~= nil and math.max(sample.centerUp - sample.minUp, 0) or 0.5
    local radiusSidePos = sample ~= nil and math.max(sample.maxSide - sample.centerSide, 0) or 0.5
    local radiusSideNeg = sample ~= nil and math.max(sample.centerSide - sample.minSide, 0) or 0.5
    local localDiameter = math.max(
        radiusUpPos + radiusUpNeg,
        radiusSidePos + radiusSideNeg
    )
    local probeSize = math.clamp(
        localDiameter * LoggingContractor.TEST_PASS1_ATTACHMENT_SIZE_FACTOR,
        LoggingContractor.TEST_PASS1_ATTACHMENT_MIN_SIZE,
        LoggingContractor.TEST_PASS1_ATTACHMENT_MAX_SIZE
    )
    local outset = LoggingContractor.TEST_PASS1_ATTACHMENT_RADIAL_OUTSET

    local centerX = axisPointX + upX * centerUp + sideX * centerSide
    local centerY = axisPointY + upY * centerUp + sideY * centerSide
    local centerZ = axisPointZ + upZ * centerUp + sideZ * centerSide

    local hits = {
        center = removeSplitShapeAttachments(
            shape,
            centerX,
            centerY,
            centerZ,
            axisX,
            axisY,
            axisZ,
            upX,
            upY,
            upZ,
            LoggingContractor.TEST_PASS1_ATTACHMENT_THICKNESS,
            probeSize,
            probeSize
        )
    }

    hits.sidePos = removeSplitShapeAttachments(
        shape,
        centerX + sideX * (radiusSidePos + outset),
        centerY + sideY * (radiusSidePos + outset),
        centerZ + sideZ * (radiusSidePos + outset),
        -sideX,
        -sideY,
        -sideZ,
        axisX,
        axisY,
        axisZ,
        LoggingContractor.TEST_PASS1_ATTACHMENT_THICKNESS,
        probeSize,
        probeSize
    )
    hits.sideNeg = removeSplitShapeAttachments(
        shape,
        centerX - sideX * (radiusSideNeg + outset),
        centerY - sideY * (radiusSideNeg + outset),
        centerZ - sideZ * (radiusSideNeg + outset),
        sideX,
        sideY,
        sideZ,
        axisX,
        axisY,
        axisZ,
        LoggingContractor.TEST_PASS1_ATTACHMENT_THICKNESS,
        probeSize,
        probeSize
    )
    hits.upPos = removeSplitShapeAttachments(
        shape,
        centerX + upX * (radiusUpPos + outset),
        centerY + upY * (radiusUpPos + outset),
        centerZ + upZ * (radiusUpPos + outset),
        -upX,
        -upY,
        -upZ,
        axisX,
        axisY,
        axisZ,
        LoggingContractor.TEST_PASS1_ATTACHMENT_THICKNESS,
        probeSize,
        probeSize
    )
    hits.upNeg = removeSplitShapeAttachments(
        shape,
        centerX - upX * (radiusUpNeg + outset),
        centerY - upY * (radiusUpNeg + outset),
        centerZ - upZ * (radiusUpNeg + outset),
        upX,
        upY,
        upZ,
        axisX,
        axisY,
        axisZ,
        LoggingContractor.TEST_PASS1_ATTACHMENT_THICKNESS,
        probeSize,
        probeSize
    )

    if not entityExists(shape) then
        return 0
    end

    local _, _, _, _, attachmentsAfter = self:getContractorSplitShapeStats(shape)
    local removed = math.max(attachmentsBefore - attachmentsAfter, 0)

    Logging.info(
        "[LoggingContractor][AttachmentProbe1] shape=%d d=%.2f orientation=radialIn hits=C:%d +S:%d -S:%d +U:%d -U:%d radiusSide=%.3f/%.3f radiusUp=%.3f/%.3f outset=%.2f size=%.2f attachments=%d->%d removed=%d",
        shape,
        distance,
        hits.center and 1 or 0,
        hits.sidePos and 1 or 0,
        hits.sideNeg and 1 or 0,
        hits.upPos and 1 or 0,
        hits.upNeg and 1 or 0,
        radiusSidePos,
        radiusSideNeg,
        radiusUpPos,
        radiusUpNeg,
        outset,
        probeSize,
        attachmentsBefore,
        attachmentsAfter,
        removed
    )

    return removed
end

-- Новый тестовый проход крупных ветвей и attachments. Движение по стволу идёт
-- строго с шагом 0.25 м. На первых 5 м в каждой точке сначала исчерпываются все
-- доступные крупные ветви с повторным измерением того же сечения, затем там же
-- выполняется пятисторонняя очистка attachments. После 5 м остаётся только
-- очистка attachments, но сечение всё равно измеряется для расчёта радиусов.
function LoggingContractor:pruneContractorBranches(
    shape,
    baseX,
    baseY,
    baseZ,
    axisX,
    axisY,
    axisZ,
    upX,
    upY,
    upZ,
    trunkLength
)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return shape, trunkLength
    end

    axisX, axisY, axisZ = MathUtil.vector3Normalize(axisX, axisY, axisZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)

    local currentShape = shape
    local currentLength = trunkLength
    local step = LoggingContractor.TEST_PASS1_SCAN_STEP
    local distance = step
    local history = {}
    local cutCount = 0
    local attachmentRemovedTotal = 0
    local attachmentHitSteps = 0
    local attachmentSteps = 0

    local splitTypeIndex = getSplitType(currentShape)
    local splitTypeData = g_splitShapeManager:getSplitTypeByIndex(splitTypeIndex)
    local splitTypeName = splitTypeData ~= nil and splitTypeData.name or "<unknown>"

    Logging.info(
        "[LoggingContractor][TestPass1Start] shape=%d splitType=%s splitTypeName=%s length=%.2f step=%.2f branchLimit=%.2f branchPlane=%.2fx%.2f attachmentAlgorithm=removeSplitShapeAttachments orientation=radialIn",
        currentShape,
        tostring(splitTypeIndex),
        tostring(splitTypeName),
        currentLength,
        step,
        LoggingContractor.TEST_PASS1_BRANCH_SCAN_LENGTH,
        LoggingContractor.TEST_PASS1_BRANCH_CUT_LENGTH,
        LoggingContractor.TEST_PASS1_BRANCH_CUT_WIDTH
    )

    while currentShape ~= nil
        and currentShape ~= 0
        and entityExists(currentShape)
        and distance <= currentLength + 0.001 do
        local sample = self:sampleContractorTestPass1Section(
            currentShape,
            baseX,
            baseY,
            baseZ,
            axisX,
            axisY,
            axisZ,
            upX,
            upY,
            upZ,
            distance
        )

        local branchLimit = math.min(LoggingContractor.TEST_PASS1_BRANCH_SCAN_LENGTH, currentLength)

        if sample ~= nil and distance <= branchLimit + 0.001 then
            Logging.info(
                "[LoggingContractor][BranchProfile] shape=%d d=%.2f side=%.3f..%.3f up=%.3f..%.3f width=%.3f/%.3f center=%.3f/%.3f",
                currentShape,
                distance,
                sample.minSide,
                sample.maxSide,
                sample.minUp,
                sample.maxUp,
                sample.widthSide,
                sample.widthUp,
                sample.centerSide,
                sample.centerUp
            )

            if #history >= LoggingContractor.TEST_PASS1_BRANCH_BASELINE_SAMPLES
                and cutCount < LoggingContractor.TEST_PASS1_BRANCH_MAX_TOTAL_CUTS then
                local baseline = self:getContractorBranchBaseline(history, 1, #history)
                local blockedDirections = {}
                local cutsAtStep = 0
                local keepChecking = true

                while keepChecking
                    and currentShape ~= nil
                    and currentShape ~= 0
                    and entityExists(currentShape)
                    and cutsAtStep < LoggingContractor.TEST_PASS1_BRANCH_MAX_CUTS_PER_STEP
                    and cutCount < LoggingContractor.TEST_PASS1_BRANCH_MAX_TOTAL_CUTS do
                    sample = self:sampleContractorTestPass1Section(
                        currentShape,
                        baseX,
                        baseY,
                        baseZ,
                        axisX,
                        axisY,
                        axisZ,
                        upX,
                        upY,
                        upZ,
                        distance
                    )

                    if sample == nil then
                        break
                    end

                    local nextSample = nil
                    if distance + step <= branchLimit + 0.001 then
                        nextSample = self:sampleContractorTestPass1Section(
                            currentShape,
                            baseX,
                            baseY,
                            baseZ,
                            axisX,
                            axisY,
                            axisZ,
                            upX,
                            upY,
                            upZ,
                            distance + step
                        )
                    end

                    local candidates = self:getContractorTestPass1BranchCandidates(
                        sample,
                        baseline,
                        nextSample,
                        blockedDirections
                    )
                    local candidate = candidates[1]

                    if candidate == nil then
                        keepChecking = false
                    else
                        Logging.info(
                            "[LoggingContractor][BranchDetected] shape=%d d=%.2f direction=%s growth=%.3f threshold=%.3f widthGrowth=%.3f widthThreshold=%.3f baselineDiameter=%.3f",
                            currentShape,
                            distance,
                            candidate.direction,
                            candidate.growth,
                            candidate.growthThreshold,
                            candidate.widthGrowth,
                            candidate.widthThreshold,
                            candidate.baselineDiameter
                        )

                        local newShape, newLength, detached, detachedCount =
                            self:cutContractorTestPass1Branch(
                                currentShape,
                                sample,
                                baseline,
                                candidate,
                                baseX,
                                baseY,
                                baseZ,
                                axisX,
                                axisY,
                                axisZ,
                                upX,
                                upY,
                                upZ,
                                currentLength
                            )

                        currentShape = newShape
                        currentLength = newLength

                        if detached then
                            cutCount = cutCount + 1
                            cutsAtStep = cutsAtStep + 1
                            blockedDirections = {}

                            Logging.info(
                                "[LoggingContractor][BranchRecheck] shape=%d d=%.2f detached=%d cutsAtStep=%d totalCuts=%d -- repeat same position",
                                currentShape,
                                distance,
                                detachedCount,
                                cutsAtStep,
                                cutCount
                            )
                        else
                            blockedDirections[candidate.direction] = true
                            Logging.info(
                                "[LoggingContractor][BranchDirectionDone] shape=%d d=%.2f direction=%s -- no detachable branch, checking other sides",
                                currentShape,
                                distance,
                                candidate.direction
                            )
                        end
                    end
                end

                sample = self:sampleContractorTestPass1Section(
                    currentShape,
                    baseX,
                    baseY,
                    baseZ,
                    axisX,
                    axisY,
                    axisZ,
                    upX,
                    upY,
                    upZ,
                    distance
                )
            end
        end

        if currentShape == nil or currentShape == 0 or not entityExists(currentShape) then
            break
        end

        -- После обработки крупных ветвей текущая форма сечения становится
        -- базой для следующих шагов. За пределами 5 м история больше не нужна.
        if sample ~= nil and distance <= LoggingContractor.TEST_PASS1_BRANCH_SCAN_LENGTH + 0.001 then
            table.insert(history, sample)
            while #history > LoggingContractor.TEST_PASS1_BRANCH_BASELINE_SAMPLES do
                table.remove(history, 1)
            end
        end

        if sample == nil then
            sample = self:sampleContractorTestPass1Section(
                currentShape,
                baseX,
                baseY,
                baseZ,
                axisX,
                axisY,
                axisZ,
                upX,
                upY,
                upZ,
                distance
            )
        end

        attachmentSteps = attachmentSteps + 1
        local removed = self:removeContractorTestPass1AttachmentsAtStep(
            currentShape,
            sample,
            baseX,
            baseY,
            baseZ,
            axisX,
            axisY,
            axisZ,
            upX,
            upY,
            upZ,
            distance
        )
        attachmentRemovedTotal = attachmentRemovedTotal + removed
        if removed > 0 then
            attachmentHitSteps = attachmentHitSteps + 1
        end

        distance = distance + step
    end

    local _, _, _, _, attachmentsRemaining = self:getContractorSplitShapeStats(currentShape)
    Logging.info(
        "[LoggingContractor][TestPass1Done] shape=%s cuts=%d length=%.2f attachmentSteps=%d hitSteps=%d removed=%d remainingAttachments=%d",
        tostring(currentShape),
        cutCount,
        currentLength,
        attachmentSteps,
        attachmentHitSteps,
        attachmentRemovedTotal,
        attachmentsRemaining
    )

    return currentShape, currentLength
end


-- В тестовом проходе отключает все прежние методы delimb. Благодаря загрузке
-- этого файла последним ни глобальный removeSplitShapeAttachments, ни
-- findAndRemoveSplitShapeAttachments не могут изменить результат эксперимента.
function LoggingContractor:delimbContractorTrunk(shape, baseX, baseY, baseZ, dirX, dirY, dirZ, upX, upY, upZ, trunkLength)
    if not self.testPass1LegacyDelimbDisabledLogged then
        self.testPass1LegacyDelimbDisabledLogged = true
        Logging.info(
            "[LoggingContractor][TestPass1] legacy delimb disabled; only five-point removeSplitShapeAttachments probes are active"
        )
    end
end

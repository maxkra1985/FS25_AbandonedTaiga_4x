--[[
    LoggingContractorTestPass1

    Тестовый проход №1 для обработки спиленного дерева подрядчиком.

    Цели прохода:
    1. Проверить removeSplitShapeAttachments() как единственный алгоритм
       удаления attachments. На каждом шаге 0.25 м выполняются пять вызовов:
       в центре сечения и на поверхности ствола в четырёх направлениях.
       Количество attachments проверяется только после всех пяти вызовов.
    2. Проверить новый локальный алгоритм снятия крупных ветвей. В пределах
       первых 5 м ствола после обнаружения одностороннего утолщения выполняется
       короткий продольный рез чуть снаружи нормальной поверхности ствола.
       После успешного реза та же точка измеряется повторно; переход к следующему
       шагу выполняется только когда в текущем сечении больше нет кандидатов.

    Чтобы результаты теста не смешивались, прежние delimb-алгоритмы этого
    прохода отключены. После окончания эксперимента модуль можно снять из
    загрузки без изменения основной реализации подрядчиков.
]]

LoggingContractor.TEST_PASS1_SCAN_STEP = 0.25
LoggingContractor.TEST_PASS1_BRANCH_SCAN_LENGTH = 5.0
LoggingContractor.TEST_PASS1_BRANCH_BASELINE_SAMPLES = 4
LoggingContractor.TEST_PASS1_BRANCH_MAX_TOTAL_CUTS = 8
LoggingContractor.TEST_PASS1_BRANCH_MAX_CUTS_PER_STEP = 4
LoggingContractor.TEST_PASS1_BRANCH_CUT_FORWARD = 0.75
LoggingContractor.TEST_PASS1_BRANCH_CUT_BACK = 0.25
LoggingContractor.TEST_PASS1_BRANCH_CUT_MIN_LENGTH = 0.75
LoggingContractor.TEST_PASS1_BRANCH_CUT_MIN_WIDTH = 1.00
LoggingContractor.TEST_PASS1_BRANCH_CUT_WIDTH_FACTOR = 1.75
LoggingContractor.TEST_PASS1_BRANCH_OUTSETS = {0.10, 0.05, 0.02, 0.00}

LoggingContractor.TEST_PASS1_ATTACHMENT_THICKNESS = 0.30
LoggingContractor.TEST_PASS1_ATTACHMENT_MIN_SIZE = 1.00
LoggingContractor.TEST_PASS1_ATTACHMENT_MAX_SIZE = 2.00
LoggingContractor.TEST_PASS1_ATTACHMENT_SIZE_FACTOR = 1.50


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


-- Формирует параметры короткой продольной плоскости для ветви, найденной в
-- конкретном сечении. Плоскость не проходит через нормальный ствол: начальная
-- попытка располагается на 10 см снаружи его базовой поверхности, затем отступ
-- последовательно уменьшается до нуля.
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
        sample.distance + LoggingContractor.TEST_PASS1_BRANCH_CUT_FORWARD
    )
    local cutLength = math.max(
        cutEnd - cutStart,
        LoggingContractor.TEST_PASS1_BRANCH_CUT_MIN_LENGTH
    )
    local cutDistance = (cutStart + cutEnd) * 0.5

    local orthogonalWidth
    if candidate.direction == "SIDE_POS" or candidate.direction == "SIDE_NEG" then
        orthogonalWidth = math.max(sample.widthUp, baseline.widthUp)
    else
        orthogonalWidth = math.max(sample.widthSide, baseline.widthSide)
    end

    local cutWidth = math.max(
        LoggingContractor.TEST_PASS1_BRANCH_CUT_MIN_WIDTH,
        candidate.baselineDiameter * LoggingContractor.TEST_PASS1_BRANCH_CUT_WIDTH_FACTOR,
        orthogonalWidth + candidate.baselineDiameter * 0.25
    )
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
            "[LoggingContractor][BranchCutTry] shape=%d d=%.2f direction=%s outset=%.2f surface=%.3f plane=%.2fx%.2f probe=%s",
            currentShape,
            sample.distance,
            candidate.direction,
            outset,
            geometry.surfaceOffset,
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


-- Выполняет первый тестовый алгоритм удаления attachments. Для одного шага
-- сначала вычисляется фактический центр текущего сечения. Затем движок вызывается
-- пять раз: в центре и на поверхности в направлениях +/-side и +/-up.
-- Счётчик attachments читается только до и после всей группы вызовов.
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
    local radiusUp = sample ~= nil and sample.widthUp * 0.5 or 0.5
    local radiusSide = sample ~= nil and sample.widthSide * 0.5 or 0.5
    local localDiameter = math.max(radiusUp * 2, radiusSide * 2)
    local probeSize = math.clamp(
        localDiameter * LoggingContractor.TEST_PASS1_ATTACHMENT_SIZE_FACTOR,
        LoggingContractor.TEST_PASS1_ATTACHMENT_MIN_SIZE,
        LoggingContractor.TEST_PASS1_ATTACHMENT_MAX_SIZE
    )

    local centerX = axisPointX + upX * centerUp + sideX * centerSide
    local centerY = axisPointY + upY * centerUp + sideY * centerSide
    local centerZ = axisPointZ + upZ * centerUp + sideZ * centerSide
    local points = {
        {name = "CENTER", x = centerX, y = centerY, z = centerZ},
        {
            name = "SIDE_POS",
            x = centerX + sideX * radiusSide,
            y = centerY + sideY * radiusSide,
            z = centerZ + sideZ * radiusSide
        },
        {
            name = "SIDE_NEG",
            x = centerX - sideX * radiusSide,
            y = centerY - sideY * radiusSide,
            z = centerZ - sideZ * radiusSide
        },
        {
            name = "UP_POS",
            x = centerX + upX * radiusUp,
            y = centerY + upY * radiusUp,
            z = centerZ + upZ * radiusUp
        },
        {
            name = "UP_NEG",
            x = centerX - upX * radiusUp,
            y = centerY - upY * radiusUp,
            z = centerZ - upZ * radiusUp
        }
    }

    for _, point in ipairs(points) do
        removeSplitShapeAttachments(
            shape,
            point.x,
            point.y,
            point.z,
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
    end

    if not entityExists(shape) then
        return 0
    end

    local _, _, _, _, attachmentsAfter = self:getContractorSplitShapeStats(shape)
    local removed = math.max(attachmentsBefore - attachmentsAfter, 0)

    Logging.info(
        "[LoggingContractor][AttachmentProbe1] shape=%d d=%.2f points=5 radiusSide=%.3f radiusUp=%.3f size=%.2f attachments=%d->%d removed=%d",
        shape,
        distance,
        radiusSide,
        radiusUp,
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

    Logging.info(
        "[LoggingContractor][TestPass1Start] shape=%d length=%.2f step=%.2f branchLimit=%.2f attachmentAlgorithm=removeSplitShapeAttachments",
        currentShape,
        currentLength,
        step,
        LoggingContractor.TEST_PASS1_BRANCH_SCAN_LENGTH
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

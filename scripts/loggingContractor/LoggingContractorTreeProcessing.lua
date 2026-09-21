--[[
    LoggingContractorTreeProcessing

    Обработка спиленного дерева подрядчиком.

    Основной ствол сканируется через 0.10 м. Первые 5 м являются только
    классификационным окном: если там обнаружена крупная ветвь, её поиск
    продолжается до конца ствола. Крупные ветви отделяются продольными резами
    с повторными попытками 0/-30/+30 градусов и сдвигом вдоль оси на 0.10 м.

    Attachments удаляются штатным removeSplitShapeAttachments. Для обычных
    деревьев используется лёгкий четырёхсторонний радиальный проход. Для SPRUCE
    и для отделённых крупных ветвей на каждом сечении выполняется полный круг
    из 12 уникальных радиальных направлений через 30 градусов.
]]

local function getMedian(values)
    if #values == 0 then
        return 0
    end

    table.sort(values)
    local middle = math.floor((#values + 1) * 0.5)
    if #values % 2 == 0 then
        return (values[middle] + values[middle + 1]) * 0.5
    end

    return values[middle]
end

LoggingContractor.BRANCH_MIN_SIDE_GROWTH = 0.12
LoggingContractor.BRANCH_SIDE_GROWTH_FACTOR = 0.25
LoggingContractor.BRANCH_MIN_WIDTH_GROWTH = 0.08
LoggingContractor.BRANCH_WIDTH_GROWTH_FACTOR = 0.15
LoggingContractor.BRANCH_PERSISTENCE_FACTOR = 0.60
LoggingContractor.BRANCH_GROUP_END_FACTOR = 0.35
LoggingContractor.BRANCH_SEPARATION_SPEED = 0.55
LoggingContractor.BRANCH_SEPARATION_UP_SPEED = 0.15

-- Формирует базовое сечение по медиане предыдущих замеров.
function LoggingContractor:getContractorBranchBaseline(samples, firstIndex, lastIndex)
    local minUp, maxUp, minSide, maxSide = {}, {}, {}, {}
    local widthUp, widthSide, centerUp, centerSide = {}, {}, {}, {}

    for index = firstIndex, lastIndex do
        local sample = samples[index]
        table.insert(minUp, sample.minUp)
        table.insert(maxUp, sample.maxUp)
        table.insert(minSide, sample.minSide)
        table.insert(maxSide, sample.maxSide)
        table.insert(widthUp, sample.widthUp)
        table.insert(widthSide, sample.widthSide)
        table.insert(centerUp, sample.centerUp)
        table.insert(centerSide, sample.centerSide)
    end

    return {
        minUp = getMedian(minUp),
        maxUp = getMedian(maxUp),
        minSide = getMedian(minSide),
        maxSide = getMedian(maxSide),
        widthUp = getMedian(widthUp),
        widthSide = getMedian(widthSide),
        centerUp = getMedian(centerUp),
        centerSide = getMedian(centerSide)
    }
end

-- Возвращает одностороннее расширение сечения и прирост его полной ширины.
function LoggingContractor:getContractorBranchSideGrowth(sample, baseline, direction)
    if direction == "SIDE_POS" then
        return sample.maxSide - baseline.maxSide, sample.widthSide - baseline.widthSide
    elseif direction == "SIDE_NEG" then
        return baseline.minSide - sample.minSide, sample.widthSide - baseline.widthSide
    elseif direction == "UP_POS" then
        return sample.maxUp - baseline.maxUp, sample.widthUp - baseline.widthUp
    elseif direction == "UP_NEG" then
        return baseline.minUp - sample.minUp, sample.widthUp - baseline.widthUp
    end
    return 0, 0
end

-- Возвращает мировой радиальный вектор выбранной стороны сечения.
function LoggingContractor:getContractorBranchDirection(direction, sideX, sideY, sideZ, upX, upY, upZ)
    if direction == "SIDE_POS" then
        return sideX, sideY, sideZ
    elseif direction == "SIDE_NEG" then
        return -sideX, -sideY, -sideZ
    elseif direction == "UP_POS" then
        return upX, upY, upZ
    elseif direction == "UP_NEG" then
        return -upX, -upY, -upZ
    end
    return nil
end

-- Возвращает радиус нормального ствола в выбранном направлении.
function LoggingContractor:getContractorBranchSurfaceOffset(baseline, direction)
    if direction == "SIDE_POS" then
        return baseline.maxSide
    elseif direction == "SIDE_NEG" then
        return -baseline.minSide
    elseif direction == "UP_POS" then
        return baseline.maxUp
    elseif direction == "UP_NEG" then
        return -baseline.minUp
    end
    return 0
end

-- Проверяет, пересекает ли продольная плоскость древесную геометрию.
function LoggingContractor:probeContractorLongitudinalCut(
    shape, centerX, centerY, centerZ,
    normalX, normalY, normalZ,
    axisX, axisY, axisZ,
    sizeY, sizeZ
)
    local sideX, sideY, sideZ = MathUtil.crossProduct(
        normalX, normalY, normalZ,
        axisX, axisY, axisZ
    )
    if MathUtil.vector3Length(sideX, sideY, sideZ) < 0.001 then
        return nil
    end
    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    local planeX = centerX - axisX * sizeY * 0.5 - sideX * sizeZ * 0.5
    local planeY = centerY - axisY * sizeY * 0.5 - sideY * sizeZ * 0.5
    local planeZ = centerZ - axisZ * sizeY * 0.5 - sideZ * sizeZ * 0.5

    local minY, maxY, minZ, maxZ = testSplitShape(
        shape,
        planeX, planeY, planeZ,
        normalX, normalY, normalZ,
        axisX, axisY, axisZ,
        sizeY, sizeZ
    )
    if minY == nil then
        return nil
    end

    return {widthY = maxY - minY, widthZ = maxZ - minZ}
end


LoggingContractor.PROCESSING_SCAN_STEP = 0.10
LoggingContractor.PROCESSING_BRANCH_SCAN_LENGTH = 5.0
LoggingContractor.PROCESSING_BRANCH_BASELINE_SAMPLES = 10
LoggingContractor.PROCESSING_BRANCH_MAX_TOTAL_CUTS = 32
LoggingContractor.PROCESSING_BRANCH_MAX_CUTS_PER_STEP = 8
LoggingContractor.PROCESSING_BRANCH_CUT_LENGTH = 5.0
LoggingContractor.PROCESSING_BRANCH_CUT_BACK = 0.25
LoggingContractor.PROCESSING_BRANCH_CUT_WIDTH = 6.0
LoggingContractor.PROCESSING_BRANCH_OUTSETS = {0.10, 0.05, 0.02, 0.00}
LoggingContractor.PROCESSING_BRANCH_ANGLE_OFFSETS = {0, -30, 30}
LoggingContractor.PROCESSING_BRANCH_ADVANCE_STEP = 0.10

LoggingContractor.PROCESSING_ATTACHMENT_THICKNESS = 0.30
LoggingContractor.PROCESSING_ATTACHMENT_MIN_SIZE = 1.00
LoggingContractor.PROCESSING_ATTACHMENT_MAX_SIZE = 2.00
LoggingContractor.PROCESSING_ATTACHMENT_SIZE_FACTOR = 1.50
LoggingContractor.PROCESSING_ATTACHMENT_RADIAL_OUTSET = 0.10
LoggingContractor.PROCESSING_ATTACHMENT_ROTATION_STEP = 30
LoggingContractor.PROCESSING_DETACHED_SCAN_STEP = 0.05
LoggingContractor.PROCESSING_DETACHED_SECOND_PASS_PHASE = 15
LoggingContractor.PROCESSING_FULL_CIRCLE_DIRECTIONS = 12


-- Возвращает размер плоскости testSplitShape с запасом относительно текущего
-- split-shape. Большой размер нужен только для измерения сечения и не задаёт
-- область удаления attachments.
function LoggingContractor:getContractorProcessingScanSize(shape)
    local sizeX, sizeY, sizeZ = self:getContractorSplitShapeStats(shape)
    return math.max(sizeX, sizeY, sizeZ, 4) + 2
end


-- Снимает поперечное сечение в заданной точке основной оси ствола.
function LoggingContractor:sampleContractorProcessingSection(
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

    local scanSize = self:getContractorProcessingScanSize(shape)
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


-- Возвращает все стороны текущего сечения, соответствующие критериям крупной
-- ветви. Список нужен, чтобы после неудачного реза проверить остальные стороны
-- в той же самой точке.
function LoggingContractor:getContractorProcessingBranchCandidates(sample, baseline, nextSample, blockedDirections)
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
function LoggingContractor:getContractorProcessingBranchCutGeometry(
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

    local cutStart = math.max(0, sample.distance - LoggingContractor.PROCESSING_BRANCH_CUT_BACK)
    local cutEnd = math.min(
        trunkLength,
        cutStart + LoggingContractor.PROCESSING_BRANCH_CUT_LENGTH
    )
    local cutLength = cutEnd - cutStart
    if cutLength <= 0.05 then
        return nil
    end

    local cutDistance = (cutStart + cutEnd) * 0.5
    local cutWidth = LoggingContractor.PROCESSING_BRANCH_CUT_WIDTH
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

-- Поворачивает радиальное направление реза вокруг продольной оси ствола.
-- Так одна и та же найденная ветвь проверяется исходной плоскостью, а затем
-- плоскостями, повернутыми на 30 градусов влево и вправо.
function LoggingContractor:rotateContractorProcessingBranchNormal(
    normalX,
    normalY,
    normalZ,
    axisX,
    axisY,
    axisZ,
    angleDegrees
)
    local tangentX, tangentY, tangentZ = MathUtil.crossProduct(
        axisX,
        axisY,
        axisZ,
        normalX,
        normalY,
        normalZ
    )

    if MathUtil.vector3Length(tangentX, tangentY, tangentZ) < 0.001 then
        return normalX, normalY, normalZ
    end

    tangentX, tangentY, tangentZ = MathUtil.vector3Normalize(tangentX, tangentY, tangentZ)

    local angle = math.rad(angleDegrees)
    local cosAngle = math.cos(angle)
    local sinAngle = math.sin(angle)
    local rotatedX = normalX * cosAngle + tangentX * sinAngle
    local rotatedY = normalY * cosAngle + tangentY * sinAngle
    local rotatedZ = normalZ * cosAngle + tangentZ * sinAngle

    return MathUtil.vector3Normalize(rotatedX, rotatedY, rotatedZ)
end


-- Выполняет один локальный продольный отпил. Если splitShape создал только одну
-- новую часть, она всё равно принимается как новый основной shape, чтобы после
-- замены исходного split-shape не потерять ссылку. Успешным снятием ветви
-- считается только появление хотя бы одной отдельной части помимо ствола.
function LoggingContractor:cutContractorProcessingBranchOnce(
    state,
    sample,
    baseline,
    candidate,
    allowMutation
)
    local currentShape = state.shape
    local currentLength = state.length
    local initialDistance = sample.distance
    local attemptDistance = initialDistance

    while currentShape ~= nil
        and currentShape ~= 0
        and entityExists(currentShape)
        and attemptDistance <= currentLength + 0.001 do
        local attemptSample = self:sampleContractorProcessingSection(
            currentShape,
            state.baseX,
            state.baseY,
            state.baseZ,
            state.axisX,
            state.axisY,
            state.axisZ,
            state.upX,
            state.upY,
            state.upZ,
            attemptDistance
        )

        if attemptSample == nil then
            break
        end

        local growth, widthGrowth = self:getContractorBranchSideGrowth(
            attemptSample,
            baseline,
            candidate.direction
        )

        if attemptDistance > initialDistance then
            local minGrowth =
                candidate.growthThreshold * LoggingContractor.BRANCH_GROUP_END_FACTOR
            local minWidthGrowth =
                candidate.widthThreshold * LoggingContractor.BRANCH_GROUP_END_FACTOR

            if growth < minGrowth or widthGrowth < minWidthGrowth then
                break
            end
        end

        local geometry = self:getContractorProcessingBranchCutGeometry(
            currentShape,
            attemptSample,
            baseline,
            candidate,
            state.baseX,
            state.baseY,
            state.baseZ,
            state.axisX,
            state.axisY,
            state.axisZ,
            state.upX,
            state.upY,
            state.upZ,
            currentLength
        )

        if geometry == nil then
            break
        end

        for _, angleOffset in ipairs(LoggingContractor.PROCESSING_BRANCH_ANGLE_OFFSETS) do
            local normalX, normalY, normalZ =
                self:rotateContractorProcessingBranchNormal(
                    geometry.normalX,
                    geometry.normalY,
                    geometry.normalZ,
                    state.axisX,
                    state.axisY,
                    state.axisZ,
                    angleOffset
                )

            for _, outset in ipairs(LoggingContractor.PROCESSING_BRANCH_OUTSETS) do
                local cutOffset = geometry.surfaceOffset + outset
                local cutX = geometry.axisPointX + normalX * cutOffset
                local cutY = geometry.axisPointY + normalY * cutOffset
                local cutZ = geometry.axisPointZ + normalZ * cutOffset

                local probe = self:probeContractorLongitudinalCut(
                    currentShape,
                    cutX,
                    cutY,
                    cutZ,
                    normalX,
                    normalY,
                    normalZ,
                    geometry.upX,
                    geometry.upY,
                    geometry.upZ,
                    geometry.sizeY,
                    geometry.sizeZ
                )

                if probe ~= nil then
                    if not allowMutation then
                        return false, false
                    end

                    local parts = self:splitContractorShapeSized(
                        currentShape,
                        cutX,
                        cutY,
                        cutZ,
                        normalX,
                        normalY,
                        normalZ,
                        geometry.upX,
                        geometry.upY,
                        geometry.upZ,
                        geometry.sizeY,
                        geometry.sizeZ
                    )

                    if #parts > 0 then
                        local mainPart, mainAxisLength =
                            self:selectContractorMainStemPart(
                                parts,
                                state.baseX,
                                state.baseY,
                                state.baseZ,
                                state.axisX,
                                state.axisY,
                                state.axisZ
                            )

                        if mainPart == nil
                            or mainPart.shape == nil
                            or not entityExists(mainPart.shape) then
                            Logging.warning(
                                "[LoggingContractor] Branch cut produced no usable main stem"
                            )
                            return true, false
                        end

                        state.shape = mainPart.shape
                        state.length =
                            mainAxisLength > 0 and mainAxisLength or state.length

                        local detachedShapes = {}
                        for _, part in ipairs(parts) do
                            if part.shape ~= nil
                                and part.shape ~= state.shape
                                and entityExists(part.shape) then
                                table.insert(detachedShapes, part.shape)
                            end
                        end

                        state.pendingDetached = {
                            shapes = detachedShapes,
                            normalX = normalX,
                            normalY = normalY,
                            normalZ = normalZ
                        }

                        return true, #detachedShapes > 0
                    end
                end
            end
        end

        attemptDistance =
            attemptDistance + LoggingContractor.PROCESSING_BRANCH_ADVANCE_STEP
    end

    return false, false
end

function LoggingContractor:removeContractorProcessingAttachmentsAtStep(
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
    distance,
    rotationAngle,
    fullCircle
)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return 0
    end

    local _, _, _, _, attachmentsBefore = self:getContractorSplitShapeStats(shape)
    if attachmentsBefore <= 0 then
        return 0
    end

    rotationAngle = rotationAngle or 0

    local sideX, sideY, sideZ = MathUtil.crossProduct(
        axisX, axisY, axisZ,
        upX, upY, upZ
    )
    if MathUtil.vector3Length(sideX, sideY, sideZ) < 0.001 then
        return 0
    end
    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    local centerUp = sample ~= nil and sample.centerUp or 0
    local centerSide = sample ~= nil and sample.centerSide or 0
    local halfUp = sample ~= nil and math.max(sample.widthUp * 0.5, 0.01) or 0.5
    local halfSide = sample ~= nil and math.max(sample.widthSide * 0.5, 0.01) or 0.5
    local localDiameter = math.max(halfUp * 2, halfSide * 2)
    local probeSize = math.clamp(
        localDiameter * LoggingContractor.PROCESSING_ATTACHMENT_SIZE_FACTOR,
        LoggingContractor.PROCESSING_ATTACHMENT_MIN_SIZE,
        LoggingContractor.PROCESSING_ATTACHMENT_MAX_SIZE
    )

    local axisPointX = baseX + axisX * distance
    local axisPointY = baseY + axisY * distance
    local axisPointZ = baseZ + axisZ * distance
    local centerX = axisPointX + upX * centerUp + sideX * centerSide
    local centerY = axisPointY + upY * centerUp + sideY * centerSide
    local centerZ = axisPointZ + upZ * centerUp + sideZ * centerSide
    local outset = LoggingContractor.PROCESSING_ATTACHMENT_RADIAL_OUTSET

    removeSplitShapeAttachments(
        shape,
        centerX, centerY, centerZ,
        axisX, axisY, axisZ,
        upX, upY, upZ,
        LoggingContractor.PROCESSING_ATTACHMENT_THICKNESS,
        probeSize,
        probeSize
    )

    if not entityExists(shape) then
        return attachmentsBefore
    end

    local directionCount = fullCircle
        and LoggingContractor.PROCESSING_FULL_CIRCLE_DIRECTIONS
        or 4
    local angleStep = fullCircle
        and LoggingContractor.PROCESSING_ATTACHMENT_ROTATION_STEP
        or 90

    for index = 0, directionCount - 1 do
        local angle = math.rad(rotationAngle + index * angleStep)
        local cosAngle = math.cos(angle)
        local sinAngle = math.sin(angle)
        local radialX = upX * cosAngle + sideX * sinAngle
        local radialY = upY * cosAngle + sideY * sinAngle
        local radialZ = upZ * cosAngle + sideZ * sinAngle
        radialX, radialY, radialZ = MathUtil.vector3Normalize(radialX, radialY, radialZ)

        local radius = math.abs(cosAngle) * halfUp + math.abs(sinAngle) * halfSide

        removeSplitShapeAttachments(
            shape,
            centerX + radialX * (radius + outset),
            centerY + radialY * (radius + outset),
            centerZ + radialZ * (radius + outset),
            -radialX, -radialY, -radialZ,
            axisX, axisY, axisZ,
            LoggingContractor.PROCESSING_ATTACHMENT_THICKNESS,
            probeSize,
            probeSize
        )

        if not entityExists(shape) then
            return attachmentsBefore
        end

        if select(5, self:getContractorSplitShapeStats(shape)) <= 0 then
            break
        end
    end

    local attachmentsAfter = select(5, self:getContractorSplitShapeStats(shape))
    return math.max(attachmentsBefore - attachmentsAfter, 0)
end

-- Очищает уже отделённую крупную ветвь по её собственной продольной оси.
-- На каждом сечении выполняется полный круг из 12 радиальных направлений.
function LoggingContractor:scanContractorProcessingDetachedAttachments(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return false
    end

    local attachmentsBefore = select(5, self:getContractorSplitShapeStats(shape))
    if attachmentsBefore <= 0 then
        return false
    end

    local centerX, centerY, centerZ, dirX, dirY, dirZ, upX, upY, upZ, length =
        self:getContractorShapeMainAxis(shape)

    if centerX == nil or length == nil or length <= 0 then
        Logging.warning(
            "[LoggingContractor] Unable to determine detached branch axis for shape %d",
            shape
        )
        return false
    end

    local baseX = centerX - dirX * length * 0.5
    local baseY = centerY - dirY * length * 0.5
    local baseZ = centerZ - dirZ * length * 0.5
    local step = LoggingContractor.PROCESSING_DETACHED_SCAN_STEP
    local removedAny = false

    for passIndex = 1, 2 do
        if not entityExists(shape)
            or select(5, self:getContractorSplitShapeStats(shape)) <= 0 then
            break
        end

        local startDistance = passIndex == 1 and step or step * 0.5
        local phase = passIndex == 1 and 0
            or LoggingContractor.PROCESSING_DETACHED_SECOND_PASS_PHASE
        local distance = startDistance
        local stepIndex = 0

        while entityExists(shape) and distance <= length + 0.001 do
            stepIndex = stepIndex + 1

            local sample = self:sampleContractorProcessingSection(
                shape,
                baseX,
                baseY,
                baseZ,
                dirX,
                dirY,
                dirZ,
                upX,
                upY,
                upZ,
                distance
            )
            local rotationAngle = (
                phase
                + (stepIndex - 1)
                    * LoggingContractor.PROCESSING_ATTACHMENT_ROTATION_STEP
            ) % 360

            local removed = self:removeContractorProcessingAttachmentsAtStep(
                shape,
                sample,
                baseX,
                baseY,
                baseZ,
                dirX,
                dirY,
                dirZ,
                upX,
                upY,
                upZ,
                distance,
                rotationAngle,
                true
            )

            removedAny = removedAny or removed > 0

            if entityExists(shape)
                and select(5, self:getContractorSplitShapeStats(shape)) <= 0 then
                break
            end

            distance = distance + step
        end
    end

    return removedAny
end

function LoggingContractor:createContractorPruningState(
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
    axisX, axisY, axisZ = MathUtil.vector3Normalize(axisX, axisY, axisZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)

    return {
        shape = shape,
        length = trunkLength,
        baseX = baseX,
        baseY = baseY,
        baseZ = baseZ,
        axisX = axisX,
        axisY = axisY,
        axisZ = axisZ,
        upX = upX,
        upY = upY,
        upZ = upZ,
        distance = LoggingContractor.PROCESSING_SCAN_STEP,
        history = {},
        cutCount = 0,
        cutsAtStep = 0,
        topologyChangesAtStep = 0,
        blockedDirections = {},
        branchFoundInInitialWindow = false,
        phase = "BRANCHES",
        fullCircleAttachments =
            self:getContractorSplitTypeName(shape) == "SPRUCE"
    }
end


-- Очищает attachments окончательного основного ствола после всех branch split.
function LoggingContractor:cleanContractorMainTrunkAttachments(state)
    if state.shape == nil
        or state.shape == 0
        or not entityExists(state.shape) then
        return false
    end

    local attachmentsBefore = select(
        5,
        self:getContractorSplitShapeStats(state.shape)
    )
    if attachmentsBefore <= 0 then
        return false
    end

    local step = LoggingContractor.PROCESSING_SCAN_STEP
    local distance = step
    local attachmentStep = 0
    local removedAny = false

    while entityExists(state.shape)
        and distance <= state.length + 0.001 do
        attachmentStep = attachmentStep + 1

        local sample = self:sampleContractorProcessingSection(
            state.shape,
            state.baseX,
            state.baseY,
            state.baseZ,
            state.axisX,
            state.axisY,
            state.axisZ,
            state.upX,
            state.upY,
            state.upZ,
            distance
        )

        local attachmentAngle = 0
        if not state.fullCircleAttachments then
            attachmentAngle = (
                (attachmentStep - 1)
                * LoggingContractor.PROCESSING_ATTACHMENT_ROTATION_STEP
            ) % 360
        end

        local removed = self:removeContractorProcessingAttachmentsAtStep(
            state.shape,
            sample,
            state.baseX,
            state.baseY,
            state.baseZ,
            state.axisX,
            state.axisY,
            state.axisZ,
            state.upX,
            state.upY,
            state.upZ,
            distance,
            attachmentAngle,
            state.fullCircleAttachments
        )

        removedAny = removedAny or removed > 0

        if select(5, self:getContractorSplitShapeStats(state.shape)) <= 0 then
            break
        end

        distance = distance + step
    end

    return removedAny
end


-- Продвигает обработку ветвей до первого изменения split-shape либо до конца
-- текущей фазы. Возвращает: done, shapeChanged.
function LoggingContractor:advanceContractorPruningState(state, allowMutation)
    if state.shape == nil
        or state.shape == 0
        or not entityExists(state.shape) then
        return true, false
    end

    if state.pendingDetached ~= nil then
        local pending = state.pendingDetached

        if #pending.shapes > 0 and not allowMutation then
            return false, false
        end

        local changed = false
        for _, detachedShape in ipairs(pending.shapes) do
            if entityExists(detachedShape) then
                changed =
                    self:scanContractorProcessingDetachedAttachments(detachedShape)
                    or changed

                self:separateContractorBranch(
                    detachedShape,
                    pending.normalX,
                    pending.normalY,
                    pending.normalZ
                )

                local angularX, angularY, angularZ =
                    self:getContractorFallAngularVelocity(
                        state.upX,
                        state.upY,
                        state.upZ
                    )
                self:applyContractorFall(
                    detachedShape,
                    angularX,
                    angularY,
                    angularZ
                )
            end
        end

        state.pendingDetached = nil

        if changed then
            return false, true
        end
    end

    if state.phase == "ATTACHMENTS" then
        local attachments = select(
            5,
            self:getContractorSplitShapeStats(state.shape)
        )

        if attachments <= 0 then
            return true, false
        end

        if not allowMutation then
            return false, false
        end

        local changed = self:cleanContractorMainTrunkAttachments(state)
        return true, changed
    end

    local step = LoggingContractor.PROCESSING_SCAN_STEP

    while state.shape ~= nil
        and state.shape ~= 0
        and entityExists(state.shape) do
        local initialWindowEnd = math.min(
            LoggingContractor.PROCESSING_BRANCH_SCAN_LENGTH,
            state.length
        )

        if state.distance > state.length + 0.001
            or (not state.branchFoundInInitialWindow
                and state.distance > initialWindowEnd + 0.001)
            or state.cutCount >= LoggingContractor.PROCESSING_BRANCH_MAX_TOTAL_CUTS then
            state.phase = "ATTACHMENTS"
            return self:advanceContractorPruningState(state, allowMutation)
        end

        local sample = self:sampleContractorProcessingSection(
            state.shape,
            state.baseX,
            state.baseY,
            state.baseZ,
            state.axisX,
            state.axisY,
            state.axisZ,
            state.upX,
            state.upY,
            state.upZ,
            state.distance
        )

        local searchLargeBranches =
            state.distance <= initialWindowEnd + 0.001
            or state.branchFoundInInitialWindow

        if sample ~= nil
            and searchLargeBranches
            and #state.history >= LoggingContractor.PROCESSING_BRANCH_BASELINE_SAMPLES
            and state.cutsAtStep < LoggingContractor.PROCESSING_BRANCH_MAX_CUTS_PER_STEP
            and state.topologyChangesAtStep
                < LoggingContractor.PROCESSING_BRANCH_MAX_CUTS_PER_STEP then
            local baseline = self:getContractorBranchBaseline(
                state.history,
                1,
                #state.history
            )

            local nextSample = nil
            if state.distance + step <= state.length + 0.001 then
                nextSample = self:sampleContractorProcessingSection(
                    state.shape,
                    state.baseX,
                    state.baseY,
                    state.baseZ,
                    state.axisX,
                    state.axisY,
                    state.axisZ,
                    state.upX,
                    state.upY,
                    state.upZ,
                    state.distance + step
                )
            end

            local candidates = self:getContractorProcessingBranchCandidates(
                sample,
                baseline,
                nextSample,
                state.blockedDirections
            )
            local candidate = candidates[1]

            if candidate ~= nil then
                if state.distance
                    <= LoggingContractor.PROCESSING_BRANCH_SCAN_LENGTH + 0.001 then
                    state.branchFoundInInitialWindow = true
                end

                local changed, detached =
                    self:cutContractorProcessingBranchOnce(
                        state,
                        sample,
                        baseline,
                        candidate,
                        allowMutation
                    )

                if changed then
                    state.topologyChangesAtStep =
                        state.topologyChangesAtStep + 1

                    if detached then
                        state.cutCount = state.cutCount + 1
                        state.cutsAtStep = state.cutsAtStep + 1
                    end

                    state.blockedDirections = {}
                    return false, true
                end

                if not allowMutation then
                    return false, false
                end

                state.blockedDirections[candidate.direction] = true
            else
                state.blockedDirections = {}
                state.cutsAtStep = 0
                state.topologyChangesAtStep = 0

                table.insert(state.history, sample)
                while #state.history
                    > LoggingContractor.PROCESSING_BRANCH_BASELINE_SAMPLES do
                    table.remove(state.history, 1)
                end

                state.distance = state.distance + step
            end
        else
            state.blockedDirections = {}
            state.cutsAtStep = 0
            state.topologyChangesAtStep = 0

            if sample ~= nil then
                table.insert(state.history, sample)
                while #state.history
                    > LoggingContractor.PROCESSING_BRANCH_BASELINE_SAMPLES do
                    table.remove(state.history, 1)
                end
            end

            state.distance = state.distance + step
        end
    end

    return true, false
end


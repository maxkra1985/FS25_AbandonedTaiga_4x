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

-- Тяжёлая очистка attachments внутри PRUNE выполняется порциями, чтобы один
-- вызов не проходил целиком по стволу или отделённой ветви. Геометрический шаг
-- и число радиальных направлений не меняются.
LoggingContractor.PROCESSING_ATTACHMENT_SECTIONS_PER_UPDATE = 1
LoggingContractor.PROCESSING_DETACHED_SECTIONS_PER_UPDATE = 1

-- Fallback основан на рабочем принципе Tree Trimmer: после точной очистки
-- большая плоскость проходит по сетке вокруг всего split-shape. Полный проход
-- нарезан на небольшие порции, чтобы ручной алгоритм не выполнялся за один кадр.
LoggingContractor.PROCESSING_FALLBACK_STEP = 0.10
LoggingContractor.PROCESSING_FALLBACK_MAX_PASSES = 12
LoggingContractor.PROCESSING_FALLBACK_SEARCH_RADIUS = 14.0
LoggingContractor.PROCESSING_FALLBACK_PLANE_WIDTH = 64.0
LoggingContractor.PROCESSING_FALLBACK_PLANE_DEPTH = 64.0
LoggingContractor.PROCESSING_FALLBACK_TIP_OVERSHOOT = 3.0
LoggingContractor.PROCESSING_FALLBACK_POSITIONS_PER_UPDATE = 12
LoggingContractor.PROCESSING_FALLBACK_OFFSETS = {
    0,
    7, -7,
    14, -14,
    21, -21
}

-- Экспериментальный профиль взрослой spruce2: центры 72 групп
-- LOD0AttachmentsShape из map/trees/spruce/spruceVar2_stage03.i3d.shapes.
-- Все значения в локальных координатах исходной I3D, Y вдоль ствола.
-- Это приоритетные точки обработки, не гарантированные места удаления.
local CONTRACTOR_SPRUCE2_STAGE03_POINTS = {
    {0.27, 35.23, -0.3},
    {-0.36, 35.06, -0.53},
    {-0.89, 24.08, -0.42},
    {0.84, 32.84, -0.15},
    {0.31, 33.77, -0.83},
    {-0.01, 27.25, -0.8},
    {-0.56, 27.65, 1.05},
    {-0.93, 27.05, -0.14},
    {1.37, 25.04, -0.11},
    {0.42, 28.85, 1.13},
    {0.46, 29.48, -0.47},
    {-0.41, 30.6, -0.91},
    {-0.4, 30.97, 0.81},
    {0.89, 31.17, -0.18},
    {-0.79, 31.42, -0.37},
    {-0.03, 32.32, -0.99},
    {0.47, 31.8, 0.79},
    {-0.65, 32.41, 0.34},
    {-0.64, 33.23, -0.43},
    {0.19, 33.01, 0.81},
    {-0.56, 34.34, 0.05},
    {0.33, 34.54, 0.23},
    {-0.17, 35.08, 0.32},
    {0.29, 26.01, 1.33},
    {0.9, 23.3, 0.57},
    {0.22, 22.71, -0.87},
    {-0.02, 20.78, 1.39},
    {-0.56, 24.57, 1.17},
    {1.39, 19.22, 0.13},
    {-0.9, 18.97, -1.47},
    {-0.9, 18.19, 1.06},
    {0.29, 13.22, 1.7},
    {1.34, 17.17, -0.29},
    {-0.93, 19.29, 0.11},
    {-1.3, 15.95, -0.05},
    {0.29, 15.44, -1.07},
    {1.09, 14.93, 0.49},
    {-0.16, 15.88, 0.96},
    {0.85, 19.98, -1.18},
    {0.86, 11.96, -1.03},
    {-1.2, 12.91, -1.09},
    {1.51, 10.6, 0.07},
    {-1.27, 11.76, -0.51},
    {-0.82, 13.52, 0.59},
    {0.17, 8.83, 1.37},
    {-1.14, 7.89, -0.86},
    {-0.02, 9.32, -1.79},
    {0.94, 7.24, -1.02},
    {0.82, 10.97, 1.56},
    {-0.56, 6.77, 1.44},
    {0.84, 28.8, -0.24},
    {-1.62, 28.74, -0.53},
    {-1.25, 6.05, -0.27},
    {1.28, 6.16, 0.25},
    {1.06, 16.74, 0.21},
    {-0.48, 17.51, -0.65},
    {-0.2, 4.85, -0.89},
    {0.51, 4.56, 1.13},
    {-0.97, 3.71, 0.98},
    {1.47, 3.76, -0.17},
    {-0.55, 3.02, -1.13},
    {0.63, 3.4, -0.91},
    {0.3, 3.06, 0.68},
    {0.78, 5.36, 1.01},
    {0.2, 35.45, 0.07},
    {0, 33.5, 0.57},
    {-0.37, 34, 0.44},
    {-0.82, 21.77, 0.6},
    {-1.09, 28.66, 0.69},
    {-1.51, 13.61, 0.72},
    {0.8, 13.9, -0.74},
    {-0.24, 14.5, 1.77}
}

LoggingContractor.PROCESSING_PROFILE_RADIAL_DISTANCE = 0.35


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
    fullCircle,
    attachmentTypeStats,
    detachedShape
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

    -- Фиксируем реальное уменьшение числа attachments по ориентации.
    -- Дополнительное чтение геометрии требуется только в режиме диагностики
    -- для исходной осевой плоскости; после радиальных вызовов оно уже есть.
    local previousAttachments = attachmentsBefore
    if attachmentTypeStats ~= nil and entityExists(shape) then
        local remaining = select(5, self:getContractorSplitShapeStats(shape))
        local counts = detachedShape
            and attachmentTypeStats.detachedDirections
            or attachmentTypeStats.mainDirections
        local entry = counts.AXIS or {calls = 0, removed = 0}
        entry.calls = entry.calls + 1
        entry.removed = entry.removed + math.max(previousAttachments - remaining, 0)
        counts.AXIS = entry
        previousAttachments = remaining
    end

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

        local remaining = select(5, self:getContractorSplitShapeStats(shape))
        if attachmentTypeStats ~= nil then
            -- Угол относительно текущей поперечной оси, кратно 30 градусам.
            local angleKey = tostring(
                math.floor((rotationAngle + index * angleStep) % 360 + 0.5)
            )
            local counts = detachedShape
            and attachmentTypeStats.detachedDirections
            or attachmentTypeStats.mainDirections
            local entry = counts[angleKey] or {calls = 0, removed = 0}
            entry.calls = entry.calls + 1
            entry.removed = entry.removed
                + math.max(previousAttachments - remaining, 0)
            counts[angleKey] = entry
            previousAttachments = remaining
        end

        if remaining <= 0 then
            break
        end
    end

    local attachmentsAfter = select(5, self:getContractorSplitShapeStats(shape))
    return math.max(attachmentsBefore - attachmentsAfter, 0)
end

-- Возвращает систему осей, совпадающую с механикой Tree Trimmer:
-- стоящее дерево сканируется вдоль локальной Y, динамический split-shape —
-- вдоль локальной X; вторая поперечная ось всегда локальная -Z.
function LoggingContractor:getContractorFallbackTrimAxes(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return nil
    end

    local isStandingTree = getRigidBodyType(shape) == RigidBodyType.STATIC
    local axisX, axisY, axisZ
    local upX, upY, upZ
    local sideX, sideY, sideZ

    if isStandingTree then
        axisX, axisY, axisZ = localDirectionToWorld(shape, 0, 1, 0)
        upX, upY, upZ = localDirectionToWorld(shape, 1, 0, 0)
    else
        axisX, axisY, axisZ = localDirectionToWorld(shape, 1, 0, 0)
        upX, upY, upZ = localDirectionToWorld(shape, 0, 1, 0)
    end

    sideX, sideY, sideZ = localDirectionToWorld(shape, 0, 0, -1)
    axisX, axisY, axisZ = MathUtil.vector3Normalize(axisX, axisY, axisZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)
    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    return axisX, axisY, axisZ,
        upX, upY, upZ,
        sideX, sideY, sideZ
end


-- Создаёт состояние большого fallback-прохода. В отличие от основной очистки
-- он не пытается точно попасть в поверхность ствола, а последовательно
-- проверяет широкую поперечную сетку вокруг всего дерева.
function LoggingContractor:createContractorFallbackTrimState(shape, attachmentTypeStats)
    local state = {
        shape = shape,
        attachmentTypeStats = attachmentTypeStats,
        passIndex = 1,
        stepIndex = 0,
        upOffsetIndex = 1,
        sideOffsetIndex = 1,
        removedThisPass = false,
        passStartAttachments = nil,
        done = false
    }

    if shape == nil or shape == 0 or not entityExists(shape) then
        state.done = true
        return state
    end

    local attachments = select(5, self:getContractorSplitShapeStats(shape))
    if attachments <= 0 then
        state.done = true
        return state
    end

    -- Снимок перед полным проходом нужен для проверки фактического
    -- уменьшения количества attachments, а не только флага от движка.
    state.passStartAttachments = attachments
    if attachmentTypeStats ~= nil then
        attachmentTypeStats.fallbackStarts =
            attachmentTypeStats.fallbackStarts + 1
    end
    self:addContractorPerfCounter("fallbackStarts", 1)
    return state
end


-- Продвигает Tree-Trimmer-подобный fallback ограниченным числом позиций сетки.
-- Каждая позиция выполняет две ориентации большой плоскости. После первого
-- реального изменения управление сразу возвращается сетевой синхронизации.
function LoggingContractor:advanceContractorFallbackTrimState(state)
    if state == nil or state.done then
        return true, false
    end

    local perfStartMs = LoggingContractor.PERF_DEBUG_ENABLED
        and getTimeSec() * 1000
        or nil
    local removeCalls = 0
    local returnedTrue = 0
    local returnedFalse = 0
    local returnedOther = 0
    local positionsChecked = 0
    local positionsChanged = 0

    -- Фиксирует статистику одной порции работы без дополнительного опроса
    -- геометрии на каждом вызове движка. Показатель returnedTrue означает
    -- только ответ native-функции; фактический результат проверяется в конце прохода.
    local function finish(done, changed)
        if perfStartMs ~= nil then
            self:recordContractorPerfMetric(
                "attachmentFallback",
                getTimeSec() * 1000 - perfStartMs,
                removeCalls
            )

            local stats = self:getContractorPerfStats()
            if stats ~= nil then
                local counters = stats.counters
                counters.fallbackCallsTrue =
                    (counters.fallbackCallsTrue or 0) + returnedTrue
                counters.fallbackCallsFalse =
                    (counters.fallbackCallsFalse or 0) + returnedFalse
                counters.fallbackCallsOther =
                    (counters.fallbackCallsOther or 0) + returnedOther
                counters.fallbackPositions =
                    (counters.fallbackPositions or 0) + positionsChecked
                counters.fallbackPositionsChanged =
                    (counters.fallbackPositionsChanged or 0) + positionsChanged
            end
        end
        return done, changed
    end

    local shape = state.shape
    if shape == nil or shape == 0 or not entityExists(shape) then
        state.done = true
        return finish(true, false)
    end

    local _, _, _, _, attachments =
        self:getContractorSplitShapeStats(shape)
    if attachments <= 0 then
        state.done = true
        self:addContractorPerfCounter("fallbackCompleted", 1)
        return finish(true, false)
    end

    local sizeX, sizeY, sizeZ = self:getContractorSplitShapeStats(shape)
    local length = math.max(sizeX or 0, sizeY or 0, sizeZ or 0)
    if length <= 0.01 then
        state.done = true
        self:addContractorPerfCounter("fallbackUnresolved", 1)
        return finish(true, false)
    end

    local axisX, axisY, axisZ,
        upX, upY, upZ,
        sideX, sideY, sideZ =
        self:getContractorFallbackTrimAxes(shape)

    if axisX == nil then
        state.done = true
        self:addContractorPerfCounter("fallbackUnresolved", 1)
        return finish(true, false)
    end

    local centerX, centerY, centerZ = getWorldTranslation(shape)
    local overshoot = LoggingContractor.PROCESSING_FALLBACK_TIP_OVERSHOOT
    local halfSpan = length * 0.5 + overshoot
    local startX = centerX - axisX * halfSpan
    local startY = centerY - axisY * halfSpan
    local startZ = centerZ - axisZ * halfSpan
    local spanLength = halfSpan * 2
    local steps = math.max(
        1,
        math.ceil(
            spanLength / LoggingContractor.PROCESSING_FALLBACK_STEP
        )
    )
    local offsets = LoggingContractor.PROCESSING_FALLBACK_OFFSETS
    local processedPositions = 0

    while processedPositions
        < LoggingContractor.PROCESSING_FALLBACK_POSITIONS_PER_UPDATE do
        if state.stepIndex > steps then
            local remaining = select(
                5,
                self:getContractorSplitShapeStats(shape)
            )

            -- Сравниваем количество attachments до и после ПОЛНОГО
            -- прохода. Один положительный return native-функции сам по
            -- себе ещё не подтверждает уменьшение количества.
            if perfStartMs ~= nil then
                local before = state.passStartAttachments or remaining
                local reduction = math.max(before - remaining, 0)
                self:addContractorPerfCounter("fallbackPassesChecked", 1)
                self:addContractorPerfCounter(
                    "fallbackAttachmentsNetReduction", reduction
                )
                if reduction == 0 then
                    self:addContractorPerfCounter("fallbackPassesNoReduction", 1)
                    if state.removedThisPass then
                        self:addContractorPerfCounter(
                            "fallbackPassesReportedButNoReduction", 1
                        )
                    end
                end
            end

            if remaining <= 0 then
                state.done = true
                self:addContractorPerfCounter("fallbackCompleted", 1)
                return finish(true, false)
            end

            if state.removedThisPass
                and state.passIndex
                    < LoggingContractor.PROCESSING_FALLBACK_MAX_PASSES then
                state.passIndex = state.passIndex + 1
                state.stepIndex = 0
                state.upOffsetIndex = 1
                state.sideOffsetIndex = 1
                state.removedThisPass = false
                state.passStartAttachments = remaining
                self:addContractorPerfCounter("fallbackExtraPasses", 1)
            else
                state.done = true
                self:addContractorPerfCounter("fallbackUnresolved", 1)
                return finish(true, false)
            end
        else
            local t = state.stepIndex / steps
            local baseX = startX + axisX * spanLength * t
            local baseY = startY + axisY * spanLength * t
            local baseZ = startZ + axisZ * spanLength * t
            local upOffset = offsets[state.upOffsetIndex]
            local sideOffset = offsets[state.sideOffsetIndex]
            local posX =
                baseX + upX * upOffset + sideX * sideOffset
            local posY =
                baseY + upY * upOffset + sideY * sideOffset
            local posZ =
                baseZ + upZ * upOffset + sideZ * sideOffset

            positionsChecked = positionsChecked + 1
            local removedA = removeSplitShapeAttachments(
                shape,
                posX, posY, posZ,
                axisX, axisY, axisZ,
                upX, upY, upZ,
                LoggingContractor.PROCESSING_FALLBACK_SEARCH_RADIUS,
                LoggingContractor.PROCESSING_FALLBACK_PLANE_WIDTH,
                LoggingContractor.PROCESSING_FALLBACK_PLANE_DEPTH
            )
            removeCalls = removeCalls + 1
            if state.attachmentTypeStats ~= nil then
                local a = state.attachmentTypeStats.fallbackOrientations.A
                a.calls = a.calls + 1
                if removedA == true then
                    a.reported = a.reported + 1
                end
            end
            if perfStartMs ~= nil then
                if removedA == true then
                    returnedTrue = returnedTrue + 1
                elseif removedA == false then
                    returnedFalse = returnedFalse + 1
                else
                    returnedOther = returnedOther + 1
                end
            end

            if not entityExists(shape) then
                state.done = true
                if removedA == true then
                    positionsChanged = positionsChanged + 1
                end
                return finish(true, removedA == true)
            end

            local removedB = removeSplitShapeAttachments(
                shape,
                posX, posY, posZ,
                axisX, axisY, axisZ,
                sideX, sideY, sideZ,
                LoggingContractor.PROCESSING_FALLBACK_SEARCH_RADIUS,
                LoggingContractor.PROCESSING_FALLBACK_PLANE_WIDTH,
                LoggingContractor.PROCESSING_FALLBACK_PLANE_DEPTH
            )
            removeCalls = removeCalls + 1
            if state.attachmentTypeStats ~= nil then
                local b = state.attachmentTypeStats.fallbackOrientations.B
                b.calls = b.calls + 1
                if removedB == true then
                    b.reported = b.reported + 1
                end
            end
            if perfStartMs ~= nil then
                if removedB == true then
                    returnedTrue = returnedTrue + 1
                elseif removedB == false then
                    returnedFalse = returnedFalse + 1
                else
                    returnedOther = returnedOther + 1
                end
            end

            local changed = removedA == true or removedB == true
            if changed then
                positionsChanged = positionsChanged + 1

                if state.attachmentTypeStats ~= nil then
                    local p = state.attachmentTypeStats
                    local after = select(
                        5, self:getContractorSplitShapeStats(shape)
                    )
                    if after < attachments then
                        p.fallbackVerifiedPositions =
                            p.fallbackVerifiedPositions + 1

                        -- Смещения относятся к позиции пробной плоскости;
                        -- записываем только проверенное уменьшение attachments.
                        local offsetKey = string.format(
                            "%d/%d", upOffset, sideOffset
                        )
                        p.fallbackOffsets[offsetKey] =
                            (p.fallbackOffsets[offsetKey] or 0) + 1
                    else
                        p.fallbackReportedWithoutReduction =
                            p.fallbackReportedWithoutReduction + 1
                    end
                end
            end
            state.removedThisPass =
                state.removedThisPass or changed

            state.sideOffsetIndex = state.sideOffsetIndex + 1
            if state.sideOffsetIndex > #offsets then
                state.sideOffsetIndex = 1
                state.upOffsetIndex = state.upOffsetIndex + 1

                if state.upOffsetIndex > #offsets then
                    state.upOffsetIndex = 1
                    state.stepIndex = state.stepIndex + 1
                end
            end

            processedPositions = processedPositions + 1

            if changed then
                return finish(false, true)
            end
        end
    end

    return finish(false, false)
end

-- Создаёт состояние поэтапной очистки уже отделённой крупной ветви.
-- Два исходных прохода и шаг 0.05 м сохраняются без изменений.
function LoggingContractor:createContractorDetachedAttachmentState(shape, attachmentTypeStats)
    local state = {
        shape = shape,
        attachmentTypeStats = attachmentTypeStats,
        done = false
    }

    if shape == nil or shape == 0 or not entityExists(shape) then
        state.done = true
        return state
    end

    local attachments = select(5, self:getContractorSplitShapeStats(shape))
    if attachments <= 0 then
        state.done = true
        return state
    end

    local centerX, centerY, centerZ, dirX, dirY, dirZ, upX, upY, upZ, length =
        self:getContractorShapeMainAxis(shape)

    if centerX == nil or length == nil or length <= 0 then
        Logging.warning(
            "[LoggingContractor] Unable to determine detached branch axis for shape %d",
            shape
        )
        state.done = true
        return state
    end

    state.dirX = dirX
    state.dirY = dirY
    state.dirZ = dirZ
    state.upX = upX
    state.upY = upY
    state.upZ = upZ
    state.length = length
    state.baseX = centerX - dirX * length * 0.5
    state.baseY = centerY - dirY * length * 0.5
    state.baseZ = centerZ - dirZ * length * 0.5
    state.phase = "FAST"
    state.passIndex = 1
    state.distance = LoggingContractor.PROCESSING_DETACHED_SCAN_STEP
    state.stepIndex = 0
    state.fallbackState = nil

    return state
end


-- Продвигает очистку отделённой ветви только на ограниченное число сечений.
-- Возвращает done и признак реального изменения attachments в этом update.
function LoggingContractor:advanceContractorDetachedAttachmentState(state)
    if state == nil or state.done then
        return true, false
    end

    local shape = state.shape
    if shape == nil or shape == 0 or not entityExists(shape) then
        state.done = true
        return true, false
    end

    if state.phase == "FALLBACK" then
        local done, changed =
            self:advanceContractorFallbackTrimState(state.fallbackState)

        if done then
            state.done = true
            state.phase = "DONE"
        end

        return done, changed
    end

    local step = LoggingContractor.PROCESSING_DETACHED_SCAN_STEP
    local processedSections = 0
    local changed = false

    while processedSections
        < LoggingContractor.PROCESSING_DETACHED_SECTIONS_PER_UPDATE do
        if not entityExists(shape)
            or select(5, self:getContractorSplitShapeStats(shape)) <= 0 then
            state.done = true
            return true, changed
        end

        if state.passIndex > 2 then
            state.phase = "FALLBACK"
            state.fallbackState =
                self:createContractorFallbackTrimState(
                    shape, state.attachmentTypeStats
                )

            if state.fallbackState.done then
                state.done = true
                state.phase = "DONE"
                return true, changed
            end

            local done, fallbackChanged =
                self:advanceContractorFallbackTrimState(
                    state.fallbackState
                )

            if done then
                state.done = true
                state.phase = "DONE"
            end

            return done, changed or fallbackChanged
        end

        -- Отделённая ветвь динамическая и между кадрами может двигаться.
        -- Поэтому мировую ось и начало сканирования пересчитываем для текущего
        -- transform, а не продолжаем использовать координаты момента split.
        local centerX, centerY, centerZ,
            dirX, dirY, dirZ,
            upX, upY, upZ,
            currentLength =
            self:getContractorShapeMainAxis(shape)

        if centerX == nil or currentLength == nil or currentLength <= 0 then
            state.done = true
            return true, changed
        end

        if state.distance > currentLength + 0.001 then
            state.passIndex = state.passIndex + 1

            if state.passIndex > 2 then
                state.phase = "FALLBACK"
                state.fallbackState =
                    self:createContractorFallbackTrimState(
                    shape, state.attachmentTypeStats
                )

                if state.fallbackState.done then
                    state.done = true
                    state.phase = "DONE"
                    return true, changed
                end

                local done, fallbackChanged =
                    self:advanceContractorFallbackTrimState(
                        state.fallbackState
                    )

                if done then
                    state.done = true
                    state.phase = "DONE"
                end

                return done, changed or fallbackChanged
            end

            state.distance = state.passIndex == 1 and step or step * 0.5
            state.stepIndex = 0
        else
            state.stepIndex = state.stepIndex + 1

            local baseX = centerX - dirX * currentLength * 0.5
            local baseY = centerY - dirY * currentLength * 0.5
            local baseZ = centerZ - dirZ * currentLength * 0.5
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
                state.distance
            )
            local phase = state.passIndex == 1 and 0
                or LoggingContractor.PROCESSING_DETACHED_SECOND_PASS_PHASE
            local rotationAngle = (
                phase
                + (state.stepIndex - 1)
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
                state.distance,
                rotationAngle,
                true,
                state.attachmentTypeStats,
                true
            )

            changed = changed or removed > 0
            state.distance = state.distance + step
            processedSections = processedSections + 1
        end
    end

    return false, changed
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


-- Обрабатывает одну группу attachments из профильной I3D-модели.
-- Запомненный после спила локальный базис сохраняет корректную ориентацию
-- точек при падении и движении динамического ствола.
-- Возвращает done, changed: done означает окончание всей очистки ствола.
function LoggingContractor:advanceContractorProfileAttachments(state, cleanup)
    local shape = state.shape
    if shape == nil or not entityExists(shape) then
        cleanup.phase = "DONE"
        return true, false
    end

    local before = select(5, self:getContractorSplitShapeStats(shape))
    if before <= 0 then
        cleanup.phase = "DONE"
        self:addContractorPerfCounter("profileComplete", 1)
        return true, false
    end

    local point = CONTRACTOR_SPRUCE2_STAGE03_POINTS[cleanup.profileIndex]
    if point == nil then
        -- Эксперимент не должен ухудшать качество очистки: все оставшиеся
        -- attachments обрабатываются штатным полным проходом и fallback.
        cleanup.phase = "FAST"
        cleanup.distance = LoggingContractor.PROCESSING_SCAN_STEP
        cleanup.attachmentStep = 0
        self:addContractorPerfCounter("profileToFullScan", 1)
        return false, false
    end

    local f = state.attachmentProfileFrame
    if f == nil then
        cleanup.phase = "FAST"
        self:addContractorPerfCounter("profileMissingFrame", 1)
        return false, false
    end

    -- Центр плоскости располагается у поверхности ствола напротив ветви.
    -- Направления рассчитываются в исходных осях I3D, перенесённых в
    -- локальную систему split-shape, а не по текущему мировому углу падения.
    local px, py, pz = point[1], point[2], point[3]
    local radius = math.sqrt(px * px + pz * pz)
    if radius < 0.01 then
        cleanup.profileIndex = cleanup.profileIndex + 1
        return false, false
    end

    local rx, rz = px / radius, pz / radius
    local ox, oy, oz = f.origin[1], f.origin[2], f.origin[3]
    local bx, by, bz = f.axisX[1], f.axisX[2], f.axisX[3]
    local tx, ty, tz = f.axisY[1], f.axisY[2], f.axisY[3]
    local sx, sy, sz = f.axisZ[1], f.axisZ[2], f.axisZ[3]
    local distance = LoggingContractor.PROCESSING_PROFILE_RADIAL_DISTANCE
    local lx = ox + bx * rx * distance + tx * py + sx * rz * distance
    local ly = oy + by * rx * distance + ty * py + sy * rz * distance
    local lz = oz + bz * rx * distance + tz * py + sz * rz * distance

    local wx, wy, wz = localToWorld(shape, lx, ly, lz)
    local radialX, radialY, radialZ = localDirectionToWorld(
        shape, bx * rx + sx * rz, by * rx + sy * rz, bz * rx + sz * rz
    )
    local axisX, axisY, axisZ = localDirectionToWorld(shape, tx, ty, tz)
    radialX, radialY, radialZ = MathUtil.vector3Normalize(
        radialX, radialY, radialZ
    )
    axisX, axisY, axisZ = MathUtil.vector3Normalize(axisX, axisY, axisZ)

    -- Та же native-операция, что и в обычной очистке, но одна плоскость
    -- в известном направлении вместо полного перебора 12 направлений.
    removeSplitShapeAttachments(
        shape,
        wx, wy, wz,
        -radialX, -radialY, -radialZ,
        axisX, axisY, axisZ,
        LoggingContractor.PROCESSING_ATTACHMENT_THICKNESS,
        LoggingContractor.PROCESSING_ATTACHMENT_MAX_SIZE,
        LoggingContractor.PROCESSING_ATTACHMENT_MAX_SIZE
    )

    cleanup.profileIndex = cleanup.profileIndex + 1
    self:addContractorPerfCounter("profileCalls", 1)

    if not entityExists(shape) then
        cleanup.phase = "DONE"
        return true, true
    end

    local after = select(5, self:getContractorSplitShapeStats(shape))
    local removed = math.max(before - after, 0)
    if removed > 0 then
        self:addContractorPerfCounter("profileAttachmentsRemoved", removed)
    end

    if after <= 0 then
        cleanup.phase = "DONE"
        self:addContractorPerfCounter("profileComplete", 1)
        return true, removed > 0
    end

    return false, removed > 0
end


-- Продвигает очистку attachments основного ствола порциями.
-- Шаг 0.10 м и полный круг для ели не меняются; между update сохраняются
-- текущая позиция и номер сечения.
function LoggingContractor:advanceContractorMainTrunkAttachments(state)
    if state.shape == nil
        or state.shape == 0
        or not entityExists(state.shape) then
        state.attachmentCleanup = nil
        return true, false
    end

    if state.attachmentCleanup == nil then
        local attachments = select(
            5,
            self:getContractorSplitShapeStats(state.shape)
        )
        if attachments <= 0 then
            return true, false
        end

        local useProfile = state.attachmentProfileName == "spruce2_stage03"
            and state.attachmentProfileFrame ~= nil
        state.attachmentCleanup = {
            phase = useProfile and "PROFILE" or "FAST",
            profileIndex = 1,
            distance = LoggingContractor.PROCESSING_SCAN_STEP,
            attachmentStep = 0,
            fallbackState = nil
        }
        if useProfile then
            self:addContractorPerfCounter("profileStarts", 1)
        end
        if state.attachmentTypeStats ~= nil then
            state.attachmentTypeStats.mainScans =
                state.attachmentTypeStats.mainScans + 1
        end
    end

    local cleanup = state.attachmentCleanup

    if cleanup.phase == "DONE" then
        return true, false
    end

    if cleanup.phase == "PROFILE" then
        return self:advanceContractorProfileAttachments(state, cleanup)
    end

    if cleanup.phase == "FALLBACK" then
        local done, changed =
            self:advanceContractorFallbackTrimState(
                cleanup.fallbackState
            )

        if done then
            cleanup.phase = "DONE"
        end

        return done, changed
    end

    local step = LoggingContractor.PROCESSING_SCAN_STEP
    local processedSections = 0
    local changed = false

    while processedSections
        < LoggingContractor.PROCESSING_ATTACHMENT_SECTIONS_PER_UPDATE do
        if not entityExists(state.shape) then
            state.attachmentCleanup = nil
            return true, changed
        end

        -- Основной ствол после первичного спила динамический. При растянутой
        -- на несколько кадров очистке используем его текущую мировую ось,
        -- чтобы точки removeSplitShapeAttachments следовали за движением ствола.
        local centerX, centerY, centerZ,
            dirX, dirY, dirZ,
            upX, upY, upZ,
            currentLength =
            self:getContractorShapeMainAxis(state.shape)

        if centerX == nil
            or currentLength == nil
            or currentLength <= 0 then
            cleanup.phase = "DONE"
            return true, changed
        end

        if cleanup.distance > currentLength + 0.001 then
            local remaining = select(
                5,
                self:getContractorSplitShapeStats(state.shape)
            )

            if remaining <= 0 then
                cleanup.phase = "DONE"
                return true, changed
            end

            cleanup.phase = "FALLBACK"
            cleanup.fallbackState =
                self:createContractorFallbackTrimState(
                    state.shape, state.attachmentTypeStats
                )

            if cleanup.fallbackState.done then
                cleanup.phase = "DONE"
                return true, changed
            end

            local done, fallbackChanged =
                self:advanceContractorFallbackTrimState(
                    cleanup.fallbackState
                )

            if done then
                cleanup.phase = "DONE"
            end

            return done, changed or fallbackChanged
        end

        cleanup.attachmentStep = cleanup.attachmentStep + 1

        local baseX = centerX - dirX * currentLength * 0.5
        local baseY = centerY - dirY * currentLength * 0.5
        local baseZ = centerZ - dirZ * currentLength * 0.5
        local sample = self:sampleContractorProcessingSection(
            state.shape,
            baseX,
            baseY,
            baseZ,
            dirX,
            dirY,
            dirZ,
            upX,
            upY,
            upZ,
            cleanup.distance
        )

        local attachmentAngle = 0
        if not state.fullCircleAttachments then
            attachmentAngle = (
                (cleanup.attachmentStep - 1)
                * LoggingContractor.PROCESSING_ATTACHMENT_ROTATION_STEP
            ) % 360
        end

        local removed = self:removeContractorProcessingAttachmentsAtStep(
            state.shape,
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
            cleanup.distance,
            attachmentAngle,
            state.fullCircleAttachments,
            state.attachmentTypeStats,
            false
        )

        if removed > 0 and not state.firstAttachmentRemovalRecorded then
            state.firstAttachmentRemovalRecorded = true
            -- OBB может дать ось от верхушки к комлю. Отдельно отмечаем,
            -- начат ли обход от комля; шаг в обратном направлении не доказывает,
            -- что нижняя часть ствола уже проверена и чистая.
            local fromButt = dirX * state.axisX
                + dirY * state.axisY + dirZ * state.axisZ >= 0
            self:recordContractorFirstAttachmentRemoval(
                state.attachmentTypeStats,
                cleanup.attachmentStep,
                cleanup.distance,
                fromButt
            )
        end

        changed = changed or removed > 0
        cleanup.distance = cleanup.distance + step
        processedSections = processedSections + 1

        if not entityExists(state.shape)
            or select(5, self:getContractorSplitShapeStats(state.shape)) <= 0 then
            cleanup.phase = "DONE"
            return true, changed
        end
    end

    return false, changed
end


-- Продвигает PRUNE до первого изменения split-shape либо завершения текущей
-- веточной фазы. Длительные проходы удаления attachments ниже выполняются
-- отдельными порциями между update. Возвращает: done, shapeChanged.
function LoggingContractor:advanceContractorPruningState(state, allowMutation)
    if state.shape == nil
        or state.shape == 0
        or not entityExists(state.shape) then
        return true, false
    end

    if state.pendingDetached ~= nil then
        local pending = state.pendingDetached
        pending.shapeIndex = pending.shapeIndex or 1

        while pending.shapeIndex <= #pending.shapes do
            local detachedShape = pending.shapes[pending.shapeIndex]

            if detachedShape == nil or not entityExists(detachedShape) then
                pending.shapeIndex = pending.shapeIndex + 1
                pending.attachmentState = nil
            else
                if pending.attachmentState == nil then
                    pending.attachmentState =
                        self:createContractorDetachedAttachmentState(
                            detachedShape, state.attachmentTypeStats
                        )
                end

                if not pending.attachmentState.done and not allowMutation then
                    return false, false
                end

                local done, changed =
                    self:advanceContractorDetachedAttachmentState(
                        pending.attachmentState
                    )

                if changed then
                    -- После каждого реально изменившего attachments куска
                    -- отдаём управление сетевой синхронизации split-shape.
                    return false, true
                end

                if not done then
                    return false, false
                end

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

                pending.shapeIndex = pending.shapeIndex + 1
                pending.attachmentState = nil
            end
        end

        state.pendingDetached = nil
    end

    if state.phase == "ATTACHMENTS" then
        local attachments = select(
            5,
            self:getContractorSplitShapeStats(state.shape)
        )

        if attachments <= 0 then
            if state.attachmentCleanup ~= nil then
                state.attachmentCleanup.phase = "DONE"
            end
            return true, false
        end

        if not allowMutation then
            return false, false
        end

        local done, changed =
            self:advanceContractorMainTrunkAttachments(state)

        if changed then
            return false, true
        end

        return done, false
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

                -- Без доступного сетевого mutation-slot дорогое пробирование
                -- продольного реза всё равно не может завершиться splitShape.
                if not allowMutation then
                    return false, false
                end

                local changed, detached =
                    self:cutContractorProcessingBranchOnce(
                        state,
                        sample,
                        baseline,
                        candidate,
                        true
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


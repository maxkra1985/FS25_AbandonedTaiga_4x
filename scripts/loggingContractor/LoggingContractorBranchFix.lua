--[[
    LoggingContractorBranchFix

    Поиск и снятие крупных боковых ветвей после валки дерева.

    Алгоритм опирается на штатный testSplitShape. От комля по основной оси
    ствола строятся поперечные сечения с шагом 0.25 м только на первых 5 м.
    Для каждого сечения сохраняются четыре границы. Резкое устойчивое
    расширение одной из сторон относительно нескольких предыдущих сечений
    считается началом крупной ветви.

    Найденная ветвь отделяется продольной плоскостью: плоскость параллельна
    основной оси ствола и располагается со стороны обнаруженного расширения,
    около поверхности ствола до начала развилки. После успешного реза основной
    ствол сканируется заново, чтобы найти следующую крупную ветвь.
]]

LoggingContractor.BRANCH_SCAN_STEP = 0.25
LoggingContractor.BRANCH_SCAN_LENGTH = 5.0
LoggingContractor.BRANCH_BASELINE_SAMPLES = 4
LoggingContractor.BRANCH_MIN_SIDE_GROWTH = 0.12
LoggingContractor.BRANCH_SIDE_GROWTH_FACTOR = 0.25
LoggingContractor.BRANCH_MIN_WIDTH_GROWTH = 0.08
LoggingContractor.BRANCH_WIDTH_GROWTH_FACTOR = 0.15
LoggingContractor.BRANCH_PERSISTENCE_FACTOR = 0.60
LoggingContractor.BRANCH_GROUP_END_FACTOR = 0.35
LoggingContractor.BRANCH_CUT_MIN_LENGTH = 1.0
LoggingContractor.BRANCH_CUT_MIN_WIDTH = 1.25
LoggingContractor.BRANCH_CUT_WIDTH_FACTOR = 2.0
LoggingContractor.BRANCH_MAX_CUTS = 6
LoggingContractor.BRANCH_SEPARATION_SPEED = 0.55
LoggingContractor.BRANCH_SEPARATION_UP_SPEED = 0.15


-- Возвращает медиану набора чисел. Медиана используется для базовой формы
-- ствола, чтобы одиночное неточное сечение не смещало порог обнаружения ветви.
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


-- Формирует базовое поперечное сечение по нескольким предыдущим замерам.
-- Все координаты остаются в локальной системе плоскости testSplitShape.
function LoggingContractor:getContractorBranchBaseline(samples, firstIndex, lastIndex)
    local minUp = {}
    local maxUp = {}
    local minSide = {}
    local maxSide = {}
    local widthUp = {}
    local widthSide = {}
    local centerUp = {}
    local centerSide = {}

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


-- Возвращает расширение конкретной стороны относительно базового сечения.
-- Дополнительно возвращается увеличение полной ширины по соответствующей оси:
-- это позволяет отличить ветвь от простого плавного смещения кривого ствола.
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


-- Определяет наиболее выраженную сторону утолщения текущего сечения.
-- Кандидат принимается только когда одновременно выросла сама сторона и
-- общая ширина сечения по этой оси.
function LoggingContractor:getContractorBranchGrowthCandidate(sample, baseline)
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
        local growth, widthGrowth = self:getContractorBranchSideGrowth(sample, baseline, direction)
        if growth >= growthThreshold and widthGrowth >= widthThreshold then
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

    table.sort(candidates, function(a, b)
        return a.growth > b.growth
    end)

    return candidates[1]
end


-- Возвращает мировой вектор наружу для одной из четырёх сторон сечения.
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


-- Возвращает расстояние от исходной оси до поверхности нормального ствола
-- с выбранной стороны. Это положение используется для продольного реза.
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


-- Проверяет, пересекает ли рассчитанная продольная плоскость древесную
-- геометрию. Положение плоскости переводится из центра в угол тем же способом,
-- который используется в splitContractorShapeSized().
function LoggingContractor:probeContractorLongitudinalCut(shape, centerX, centerY, centerZ, normalX, normalY, normalZ, axisX, axisY, axisZ, sizeY, sizeZ)
    local sideX, sideY, sideZ = MathUtil.crossProduct(
        normalX,
        normalY,
        normalZ,
        axisX,
        axisY,
        axisZ
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
        planeX,
        planeY,
        planeZ,
        normalX,
        normalY,
        normalZ,
        axisX,
        axisY,
        axisZ,
        sizeY,
        sizeZ
    )

    if minY == nil then
        return nil
    end

    return {
        widthY = maxY - minY,
        widthZ = maxZ - minZ
    }
end


-- Находит первую крупную боковую ветвь в пределах первых пяти метров ствола.
-- Сечение снимается каждые 0.25 м. После обнаружения утолщения базовое сечение
-- фиксируется и по нему определяется вся непрерывная зона этой ветви.
function LoggingContractor:findContractorBranchCandidate(shape, baseX, baseY, baseZ, axisX, axisY, axisZ, upX, upY, upZ, trunkLength)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return nil
    end

    local sizeX, sizeY, sizeZ, numConvexes, numAttachments = self:getContractorSplitShapeStats(shape)
    local step = LoggingContractor.BRANCH_SCAN_STEP
    local scanLimit = math.min(LoggingContractor.BRANCH_SCAN_LENGTH, trunkLength - step)

    if scanLimit < step * (LoggingContractor.BRANCH_BASELINE_SAMPLES + 1) then
        Logging.info(
            "[LoggingContractor][BranchScan] shape=%d skipped length=%.2f scanLimit=%.2f",
            shape,
            trunkLength,
            math.max(scanLimit, 0)
        )
        return nil
    end

    local scanSize = math.max(sizeX, sizeY, sizeZ, 4) + 2
    local samples = {}
    local distance = step

    while distance <= scanLimit + 0.001 do
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
            table.insert(samples, sample)

            Logging.info(
                "[LoggingContractor][BranchProfile] shape=%d d=%.2f side=%.3f..%.3f up=%.3f..%.3f width=%.3f/%.3f center=%.3f/%.3f",
                shape,
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
        end

        distance = distance + step
    end

    Logging.info(
        "[LoggingContractor][BranchScan] shape=%d length=%.2f scan=%.2f step=%.2f samples=%d stats=%.2fx%.2fx%.2f convexes=%d attachments=%d",
        shape,
        trunkLength,
        scanLimit,
        step,
        #samples,
        sizeX,
        sizeY,
        sizeZ,
        numConvexes,
        numAttachments
    )

    if #samples <= LoggingContractor.BRANCH_BASELINE_SAMPLES then
        return nil
    end

    for index = LoggingContractor.BRANCH_BASELINE_SAMPLES + 1, #samples do
        local baseline = self:getContractorBranchBaseline(
            samples,
            index - LoggingContractor.BRANCH_BASELINE_SAMPLES,
            index - 1
        )
        local candidate = self:getContractorBranchGrowthCandidate(samples[index], baseline)

        if candidate ~= nil then
            local persistent = true
            if index < #samples then
                local nextGrowth, nextWidthGrowth = self:getContractorBranchSideGrowth(
                    samples[index + 1],
                    baseline,
                    candidate.direction
                )
                persistent = nextGrowth >= candidate.growthThreshold * LoggingContractor.BRANCH_PERSISTENCE_FACTOR
                    and nextWidthGrowth >= candidate.widthThreshold * LoggingContractor.BRANCH_PERSISTENCE_FACTOR
            end

            if persistent then
                local groupStart = samples[index].distance
                local groupEnd = groupStart
                local strongestSample = samples[index]
                local strongestGrowth = candidate.growth

                for groupIndex = index + 1, #samples do
                    local groupGrowth, groupWidthGrowth = self:getContractorBranchSideGrowth(
                        samples[groupIndex],
                        baseline,
                        candidate.direction
                    )

                    if groupGrowth >= candidate.growthThreshold * LoggingContractor.BRANCH_GROUP_END_FACTOR
                        and groupWidthGrowth >= candidate.widthThreshold * LoggingContractor.BRANCH_GROUP_END_FACTOR then
                        groupEnd = samples[groupIndex].distance
                        if groupGrowth > strongestGrowth then
                            strongestGrowth = groupGrowth
                            strongestSample = samples[groupIndex]
                        end
                    else
                        break
                    end
                end

                local normalX, normalY, normalZ = self:getContractorBranchDirection(
                    candidate.direction,
                    strongestSample.sideX,
                    strongestSample.sideY,
                    strongestSample.sideZ,
                    upX,
                    upY,
                    upZ
                )

                if normalX ~= nil then
                    normalX, normalY, normalZ = MathUtil.vector3Normalize(normalX, normalY, normalZ)

                    local cutStart = math.max(0, groupStart - step)
                    local cutEnd = math.min(trunkLength, groupEnd + step * 2)
                    local cutDistance = (cutStart + cutEnd) * 0.5
                    local cutLength = math.max(
                        cutEnd - cutStart,
                        LoggingContractor.BRANCH_CUT_MIN_LENGTH
                    )
                    local orthogonalWidth
                    if candidate.direction == "SIDE_POS" or candidate.direction == "SIDE_NEG" then
                        orthogonalWidth = math.max(strongestSample.widthUp, baseline.widthUp)
                    else
                        orthogonalWidth = math.max(strongestSample.widthSide, baseline.widthSide)
                    end

                    local cutWidth = math.max(
                        LoggingContractor.BRANCH_CUT_MIN_WIDTH,
                        candidate.baselineDiameter * LoggingContractor.BRANCH_CUT_WIDTH_FACTOR,
                        orthogonalWidth + candidate.baselineDiameter * 0.5
                    )
                    local surfaceOffset = math.max(
                        self:getContractorBranchSurfaceOffset(baseline, candidate.direction),
                        candidate.baselineDiameter * 0.25
                    )
                    local axisPointX = baseX + axisX * cutDistance
                    local axisPointY = baseY + axisY * cutDistance
                    local axisPointZ = baseZ + axisZ * cutDistance
                    local selected = nil

                    -- Начинаем почти по поверхности нормального ствола. Если
                    -- плоскость проходит снаружи геометрии, последовательно
                    -- смещаем её внутрь максимум на десять сантиметров.
                    for _, inset in ipairs({0.03, 0.06, 0.10}) do
                        local safeInset = math.min(inset, surfaceOffset * 0.30)
                        local cutOffset = math.max(surfaceOffset - safeInset, 0.02)
                        local cutX = axisPointX + normalX * cutOffset
                        local cutY = axisPointY + normalY * cutOffset
                        local cutZ = axisPointZ + normalZ * cutOffset
                        local probe = self:probeContractorLongitudinalCut(
                            shape,
                            cutX,
                            cutY,
                            cutZ,
                            normalX,
                            normalY,
                            normalZ,
                            axisX,
                            axisY,
                            axisZ,
                            cutLength,
                            cutWidth
                        )

                        if probe ~= nil then
                            selected = {
                                cutX = cutX,
                                cutY = cutY,
                                cutZ = cutZ,
                                cutOffset = cutOffset,
                                probe = probe
                            }
                            break
                        end
                    end

                    if selected ~= nil then
                        Logging.info(
                            "[LoggingContractor][BranchDetected] shape=%d direction=%s zone=%.2f..%.2f growth=%.3f threshold=%.3f widthGrowth=%.3f baselineDiameter=%.3f surface=%.3f cutOffset=%.3f plane=%.2fx%.2f probe=%.2fx%.2f",
                            shape,
                            candidate.direction,
                            groupStart,
                            groupEnd,
                            strongestGrowth,
                            candidate.growthThreshold,
                            candidate.widthGrowth,
                            candidate.baselineDiameter,
                            surfaceOffset,
                            selected.cutOffset,
                            cutLength,
                            cutWidth,
                            selected.probe.widthY,
                            selected.probe.widthZ
                        )

                        return {
                            cutX = selected.cutX,
                            cutY = selected.cutY,
                            cutZ = selected.cutZ,
                            normalX = normalX,
                            normalY = normalY,
                            normalZ = normalZ,
                            upX = axisX,
                            upY = axisY,
                            upZ = axisZ,
                            sizeY = cutLength,
                            sizeZ = cutWidth,
                            direction = candidate.direction,
                            rootDistance = groupStart,
                            baselineDiameter = candidate.baselineDiameter
                        }
                    end

                    Logging.warning(
                        "[LoggingContractor][BranchDetected] shape=%d direction=%s zone=%.2f..%.2f no longitudinal plane intersection",
                        shape,
                        candidate.direction,
                        groupStart,
                        groupEnd
                    )
                end
            end
        end
    end

    Logging.info(
        "[LoggingContractor][BranchScanDone] shape=%d no large branches in first %.2f m",
        shape,
        scanLimit
    )
    return nil
end


-- Возвращает геометрическую оценку размера split-shape без getVolume().
-- Она нужна только как дополнительный критерий при выборе основного ствола.
function LoggingContractor:getContractorShapeMeasure(shape)
    local sizeX, sizeY, sizeZ, numConvexes, numAttachments = self:getContractorSplitShapeStats(shape)
    return sizeX * sizeY * sizeZ, sizeX, sizeY, sizeZ, numConvexes, numAttachments
end


-- Выбирает после продольного реза часть, которая продолжает исходную ось
-- основного ствола. При равной длине сравниваются реальные габариты shape.
function LoggingContractor:selectContractorMainStemPart(parts, baseX, baseY, baseZ, axisX, axisY, axisZ)
    local mainPart = nil
    local bestAxisLength = -1
    local bestMeasure = -1

    for index, part in ipairs(parts) do
        if part.shape ~= nil and entityExists(part.shape) then
            local below, above = getSplitShapePlaneExtents(
                part.shape,
                baseX,
                baseY,
                baseZ,
                axisX,
                axisY,
                axisZ
            )
            local axisLength = (below or 0) + (above or 0)
            local measure, partSizeX, partSizeY, partSizeZ, convexes, attachments =
                self:getContractorShapeMeasure(part.shape)

            Logging.info(
                "[LoggingContractor][BranchPart] index=%d shape=%d axisLength=%.2f measure=%.3f size=%.2fx%.2fx%.2f convexes=%d attachments=%d",
                index,
                part.shape,
                axisLength,
                measure,
                partSizeX,
                partSizeY,
                partSizeZ,
                convexes,
                attachments
            )

            if axisLength > bestAxisLength + 0.001
                or (math.abs(axisLength - bestAxisLength) <= 0.001 and measure > bestMeasure) then
                mainPart = part
                bestAxisLength = axisLength
                bestMeasure = measure
            end
        end
    end

    return mainPart, bestAxisLength, bestMeasure
end


-- Раздвигает уже реально разделённые динамические части в сторону обнаруженной
-- ветви. Тип rigid body не меняется; скорость нужна только для наглядного
-- отделения частей, которые после splitShape начинают в совпадающем положении.
function LoggingContractor:separateContractorBranch(shape, normalX, normalY, normalZ)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return
    end

    if getRigidBodyType(shape) ~= RigidBodyType.DYNAMIC then
        return
    end

    local velocityX = normalX * LoggingContractor.BRANCH_SEPARATION_SPEED
    local velocityY = normalY * LoggingContractor.BRANCH_SEPARATION_SPEED
        + LoggingContractor.BRANCH_SEPARATION_UP_SPEED
    local velocityZ = normalZ * LoggingContractor.BRANCH_SEPARATION_SPEED
    setLinearVelocity(shape, velocityX, velocityY, velocityZ)

    Logging.info(
        "[LoggingContractor][BranchSeparate] shape=%d velocity=(%.2f,%.2f,%.2f)",
        shape,
        velocityX,
        velocityY,
        velocityZ
    )
end


-- Последовательно отделяет крупные ветви. После каждого успешного продольного
-- реза основной ствол снова сканируется от основания на первых пяти метрах.
-- Если новых утолщений нет, управление возвращается обычной очистке attachments.
function LoggingContractor:pruneContractorBranches(shape, baseX, baseY, baseZ, axisX, axisY, axisZ, upX, upY, upZ, trunkLength)
    local currentShape = shape
    local currentLength = trunkLength
    local cutCount = 0

    while currentShape ~= nil
        and currentShape ~= 0
        and entityExists(currentShape)
        and cutCount < LoggingContractor.BRANCH_MAX_CUTS do
        local candidate = self:findContractorBranchCandidate(
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
            currentLength
        )

        if candidate == nil then
            break
        end

        local parts = self:splitContractorShapeSized(
            currentShape,
            candidate.cutX,
            candidate.cutY,
            candidate.cutZ,
            candidate.normalX,
            candidate.normalY,
            candidate.normalZ,
            candidate.upX,
            candidate.upY,
            candidate.upZ,
            candidate.sizeY,
            candidate.sizeZ
        )

        if #parts < 2 then
            Logging.warning(
                "[LoggingContractor][BranchCut] shape=%d direction=%s candidate did not split geometry",
                currentShape,
                candidate.direction
            )
            break
        end

        local mainPart, mainAxisLength, mainMeasure = self:selectContractorMainStemPart(
            parts,
            baseX,
            baseY,
            baseZ,
            axisX,
            axisY,
            axisZ
        )

        if mainPart == nil or mainPart.shape == nil or not entityExists(mainPart.shape) then
            Logging.warning("[LoggingContractor][BranchCut] unable to identify main stem")
            break
        end

        local oldShape = currentShape
        currentShape = mainPart.shape
        if mainAxisLength > 0 then
            currentLength = mainAxisLength
        end
        cutCount = cutCount + 1

        Logging.info(
            "[LoggingContractor][BranchCut] oldShape=%d mainShape=%d direction=%s parts=%d mainLength=%.2f mainMeasure=%.3f",
            oldShape,
            currentShape,
            candidate.direction,
            #parts,
            currentLength,
            mainMeasure
        )

        local detachedCount = 0
        for _, part in ipairs(parts) do
            if part.shape ~= nil
                and part.shape ~= currentShape
                and entityExists(part.shape) then
                detachedCount = detachedCount + 1
                local measure, partSizeX, partSizeY, partSizeZ, convexes, attachments =
                    self:getContractorShapeMeasure(part.shape)

                Logging.info(
                    "[LoggingContractor][BranchDetached] shape=%d measure=%.3f size=%.2fx%.2fx%.2f convexes=%d attachments=%d",
                    part.shape,
                    measure,
                    partSizeX,
                    partSizeY,
                    partSizeZ,
                    convexes,
                    attachments
                )

                self:cleanContractorDetachedBranch(part.shape)

                if entityExists(part.shape) then
                    self:separateContractorBranch(
                        part.shape,
                        candidate.normalX,
                        candidate.normalY,
                        candidate.normalZ
                    )
                    local angularX, angularY, angularZ = self:getContractorFallAngularVelocity(upX, upY, upZ)
                    self:applyContractorFall(part.shape, angularX, angularY, angularZ)
                end
            end
        end

        Logging.info(
            "[LoggingContractor][BranchCutResult] oldShape=%d mainShape=%d detached=%d",
            oldShape,
            currentShape,
            detachedCount
        )
    end

    Logging.info(
        "[LoggingContractor][BranchPruneDone] shape=%s cuts=%d length=%.2f scanLimit=%.2f",
        tostring(currentShape),
        cutCount,
        currentLength,
        math.min(LoggingContractor.BRANCH_SCAN_LENGTH, currentLength)
    )

    return currentShape, currentLength
end

--[[
    LoggingContractorBranchFix

    Уточняет обработку крупных развилок после валки дерева.

    Диагностика показала две особенности движка:
    - getVolume() для древесных split-shape в наших тестах возвращает 0;
    - продольная плоскость вдоль основного ствола может срезать только узкую
      щепу с крупной ветви, не отделяя саму ветвь.

    Поэтому ветвь теперь режется поперёк её предполагаемой собственной оси.
    Ось оценивается по началу расширения ствола и наиболее удалённой стороне
    широкого поперечного сечения. Перед реальным splitShape несколько точек
    вдоль этой оси проверяются штатным testSplitShape, чтобы выбрать компактное
    сечение уже за пределами основного ствола.
]]

LoggingContractor.BRANCH_CUT_MIN_SIZE = 1.25
LoggingContractor.BRANCH_CUT_SIZE_FACTOR = 2.5
LoggingContractor.BRANCH_CUT_MIN_WIDTH_FACTOR = 0.20
LoggingContractor.BRANCH_CUT_MAX_WIDTH_FACTOR = 1.65


-- Возвращает геометрическую оценку размера split-shape без getVolume().
-- Произведение габаритов используется только для сравнения полученных частей.
function LoggingContractor:getContractorShapeMeasure(shape)
    local sizeX, sizeY, sizeZ, numConvexes, numAttachments = self:getContractorSplitShapeStats(shape)
    return sizeX * sizeY * sizeZ, sizeX, sizeY, sizeZ, numConvexes, numAttachments
end


-- Проверяет предполагаемую плоскость реза штатным testSplitShape.
-- Центр переводится в нижний левый угол прямоугольника тем же способом,
-- который используется в splitContractorShapeSized().
function LoggingContractor:probeContractorBranchCut(shape, centerX, centerY, centerZ, normalX, normalY, normalZ, planeUpX, planeUpY, planeUpZ, cutSize)
    local sideX, sideY, sideZ = MathUtil.crossProduct(
        normalX,
        normalY,
        normalZ,
        planeUpX,
        planeUpY,
        planeUpZ
    )

    local sideLength = MathUtil.vector3Length(sideX, sideY, sideZ)
    if sideLength < 0.001 then
        return nil
    end

    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    local halfSize = cutSize * 0.5
    local planeX = centerX - planeUpX * halfSize - sideX * halfSize
    local planeY = centerY - planeUpY * halfSize - sideY * halfSize
    local planeZ = centerZ - planeUpZ * halfSize - sideZ * halfSize

    local minY, maxY, minZ, maxZ = testSplitShape(
        shape,
        planeX,
        planeY,
        planeZ,
        normalX,
        normalY,
        normalZ,
        planeUpX,
        planeUpY,
        planeUpZ,
        cutSize,
        cutSize
    )

    if minY == nil then
        return nil
    end

    local below, above = getSplitShapePlaneExtents(
        shape,
        centerX,
        centerY,
        centerZ,
        normalX,
        normalY,
        normalZ
    )

    local widthY = maxY - minY
    local widthZ = maxZ - minZ

    return {
        widthY = widthY,
        widthZ = widthZ,
        maxWidth = math.max(widthY, widthZ),
        below = below or 0,
        above = above or 0
    }
end


-- Выбирает наиболее выраженное боковое направление широкого сечения.
-- Намеренно используются четыре стороны bounding rectangle, а не небольшое
-- смещение его центра: у симметричной кроны центр почти не смещается даже при
-- наличии нескольких очень крупных ветвей.
function LoggingContractor:getContractorBranchRadialDirection(sample, upX, upY, upZ)
    local candidates = {
        {side = 1, up = 0, extent = math.max(sample.maxSide, 0)},
        {side = -1, up = 0, extent = math.max(-sample.minSide, 0)},
        {side = 0, up = 1, extent = math.max(sample.maxUp, 0)},
        {side = 0, up = -1, extent = math.max(-sample.minUp, 0)}
    }

    table.sort(candidates, function(a, b)
        return a.extent > b.extent
    end)

    local best = candidates[1]
    if best == nil or best.extent <= 0 then
        return nil
    end

    local radialX = sample.sideX * best.side + upX * best.up
    local radialY = sample.sideY * best.side + upY * best.up
    local radialZ = sample.sideZ * best.side + upZ * best.up
    radialX, radialY, radialZ = MathUtil.vector3Normalize(radialX, radialY, radialZ)

    return radialX, radialY, radialZ, best.extent, best.side, best.up
end


-- Находит первую крупную развилку и строит плоскость, перпендикулярную
-- предполагаемой оси самой ветви. В отличие от прежнего варианта точка реза
-- берётся возле начала расширения, а не в середине всей широкой зоны.
function LoggingContractor:findContractorBranchCandidate(shape, baseX, baseY, baseZ, axisX, axisY, axisZ, upX, upY, upZ, trunkLength)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return nil
    end

    local sizeX, sizeY, sizeZ, numConvexes, numAttachments = self:getContractorSplitShapeStats(shape)
    local scanSize = math.max(sizeX, sizeY, sizeZ, 4) + 2
    local step = math.clamp(
        trunkLength / 40,
        LoggingContractor.BRANCH_SCAN_MIN_STEP,
        LoggingContractor.BRANCH_SCAN_MAX_STEP
    )

    local samples = {}
    local distance = math.min(step, trunkLength * 0.1)

    while distance < trunkLength - step * 0.5 do
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
        end

        distance = distance + step
    end

    if #samples < 3 then
        return nil
    end

    local baseLimit = trunkLength * LoggingContractor.BRANCH_BASE_SAMPLE_FRACTION
    local baselineDiameter = nil

    for _, sample in ipairs(samples) do
        if sample.distance <= baseLimit then
            if baselineDiameter == nil or sample.maxWidth < baselineDiameter then
                baselineDiameter = sample.maxWidth
            end
        end
    end

    if baselineDiameter == nil or baselineDiameter <= 0 then
        return nil
    end

    local threshold = math.max(
        baselineDiameter * LoggingContractor.BRANCH_WIDTH_FACTOR,
        baselineDiameter + LoggingContractor.BRANCH_MIN_WIDTH_GROWTH
    )

    Logging.info(
        "[LoggingContractor][BranchScan] shape=%d length=%.2f stats=%.2fx%.2fx%.2f convexes=%d attachments=%d baseline=%.2f threshold=%.2f step=%.2f samples=%d",
        shape,
        trunkLength,
        sizeX,
        sizeY,
        sizeZ,
        numConvexes,
        numAttachments,
        baselineDiameter,
        threshold,
        step,
        #samples
    )

    local groupStart = nil
    local groupEnd = nil
    local widestSample = nil

    for _, sample in ipairs(samples) do
        if sample.maxWidth >= threshold then
            if groupStart == nil then
                groupStart = sample.distance
            end

            groupEnd = sample.distance
            if widestSample == nil or sample.maxWidth > widestSample.maxWidth then
                widestSample = sample
            end
        elseif groupStart ~= nil then
            break
        end
    end

    if groupStart == nil or widestSample == nil then
        return nil
    end

    local radialX, radialY, radialZ, radialExtent, radialSide, radialUp =
        self:getContractorBranchRadialDirection(widestSample, upX, upY, upZ)

    if radialX == nil then
        return nil
    end

    local baseRadius = baselineDiameter * 0.5
    local axialTravel = math.max(widestSample.distance - groupStart, step)
    local radialTravel = math.max(radialExtent - baseRadius, baselineDiameter * 0.5)

    -- Вектор от корня к наиболее выступающей части ветви даёт оценку её
    -- собственной оси и, в отличие от чисто радиального направления, содержит
    -- продольную составляющую вдоль ствола.
    local branchDirX = axisX * axialTravel + radialX * radialTravel
    local branchDirY = axisY * axialTravel + radialY * radialTravel
    local branchDirZ = axisZ * axialTravel + radialZ * radialTravel
    branchDirX, branchDirY, branchDirZ = MathUtil.vector3Normalize(
        branchDirX,
        branchDirY,
        branchDirZ
    )

    -- Ось основного ствола проецируется на плоскость поперечного реза и служит
    -- её локальным направлением Y. Для почти параллельной ветви предусмотрен
    -- запасной вариант на основе исходного up-вектора.
    local axisDotBranch = axisX * branchDirX + axisY * branchDirY + axisZ * branchDirZ
    local planeUpX = axisX - branchDirX * axisDotBranch
    local planeUpY = axisY - branchDirY * axisDotBranch
    local planeUpZ = axisZ - branchDirZ * axisDotBranch

    if MathUtil.vector3Length(planeUpX, planeUpY, planeUpZ) < 0.001 then
        local upDotBranch = upX * branchDirX + upY * branchDirY + upZ * branchDirZ
        planeUpX = upX - branchDirX * upDotBranch
        planeUpY = upY - branchDirY * upDotBranch
        planeUpZ = upZ - branchDirZ * upDotBranch
    end

    if MathUtil.vector3Length(planeUpX, planeUpY, planeUpZ) < 0.001 then
        return nil
    end

    planeUpX, planeUpY, planeUpZ = MathUtil.vector3Normalize(
        planeUpX,
        planeUpY,
        planeUpZ
    )

    local rootX = baseX + axisX * groupStart
    local rootY = baseY + axisY * groupStart
    local rootZ = baseZ + axisZ * groupStart
    local cutSize = math.max(
        baselineDiameter * LoggingContractor.BRANCH_CUT_SIZE_FACTOR,
        LoggingContractor.BRANCH_CUT_MIN_SIZE
    )

    local selected = nil
    local fallback = nil
    local travelFactors = {0.55, 0.8, 1.05, 1.3}

    -- Идём от места срастания наружу по оси ветви. Предпочтительно первое
    -- сечение, которое уже стало компактнее основного ствола и при этом имеет
    -- достаточную толщину, чтобы не принять тонкую щепу за целую ветвь.
    for _, factor in ipairs(travelFactors) do
        local travel = math.max(baselineDiameter * factor, 0.25)
        local cutX = rootX + branchDirX * travel
        local cutY = rootY + branchDirY * travel
        local cutZ = rootZ + branchDirZ * travel

        local probe = self:probeContractorBranchCut(
            shape,
            cutX,
            cutY,
            cutZ,
            branchDirX,
            branchDirY,
            branchDirZ,
            planeUpX,
            planeUpY,
            planeUpZ,
            cutSize
        )

        if probe ~= nil then
            fallback = fallback or {
                cutX = cutX,
                cutY = cutY,
                cutZ = cutZ,
                travel = travel,
                probe = probe
            }

            local minWidth = baselineDiameter * LoggingContractor.BRANCH_CUT_MIN_WIDTH_FACTOR
            local maxWidth = baselineDiameter * LoggingContractor.BRANCH_CUT_MAX_WIDTH_FACTOR

            if probe.maxWidth >= minWidth
                and probe.maxWidth <= maxWidth
                and math.max(probe.below, probe.above) >= baselineDiameter then
                selected = {
                    cutX = cutX,
                    cutY = cutY,
                    cutZ = cutZ,
                    travel = travel,
                    probe = probe
                }
                break
            end
        end
    end

    selected = selected or fallback
    if selected == nil then
        Logging.warning(
            "[LoggingContractor][BranchCutProbe] shape=%d no intersection for candidate root=%.2f",
            shape,
            groupStart
        )
        return nil
    end

    Logging.info(
        "[LoggingContractor][BranchCandidate] shape=%d zone=%.2f..%.2f widest=%.2f width=%.2f radialExtent=%.2f radial=(%d,%d) axisTravel=%.2f radialTravel=%.2f dir=(%.3f,%.3f,%.3f)",
        shape,
        groupStart,
        groupEnd,
        widestSample.distance,
        widestSample.maxWidth,
        radialExtent,
        radialSide,
        radialUp,
        axialTravel,
        radialTravel,
        branchDirX,
        branchDirY,
        branchDirZ
    )

    Logging.info(
        "[LoggingContractor][BranchCutProbe] shape=%d root=%.2f travel=%.2f cut=(%.2f,%.2f,%.2f) plane=%.2fx%.2f cross=%.2fx%.2f extents=%.2f/%.2f",
        shape,
        groupStart,
        selected.travel,
        selected.cutX,
        selected.cutY,
        selected.cutZ,
        cutSize,
        cutSize,
        selected.probe.widthY,
        selected.probe.widthZ,
        selected.probe.below,
        selected.probe.above
    )

    return {
        cutX = selected.cutX,
        cutY = selected.cutY,
        cutZ = selected.cutZ,
        normalX = branchDirX,
        normalY = branchDirY,
        normalZ = branchDirZ,
        upX = planeUpX,
        upY = planeUpY,
        upZ = planeUpZ,
        sizeY = cutSize,
        sizeZ = cutSize,
        baselineDiameter = baselineDiameter,
        rootDistance = groupStart
    }
end


-- Выбирает часть, которая продолжает основной ствол после реза ветви.
-- Главный критерий -- длина пересечения исходной оси ствола; при равенстве
-- сравниваются реальные габариты, а не всегда нулевой getVolume().
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
            local measure, sizeX, sizeY, sizeZ, numConvexes, numAttachments =
                self:getContractorShapeMeasure(part.shape)

            Logging.info(
                "[LoggingContractor][BranchPart] index=%d shape=%d axisLength=%.2f measure=%.3f size=%.2fx%.2fx%.2f convexes=%d attachments=%d",
                index,
                part.shape,
                axisLength,
                measure,
                sizeX,
                sizeY,
                sizeZ,
                numConvexes,
                numAttachments
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


-- Последовательно отделяет крупные ветви. Каждая реальная часть, кроме
-- выбранного основного ствола, обрабатывается независимо от getVolume().
function LoggingContractor:pruneContractorBranches(shape, baseX, baseY, baseZ, axisX, axisY, axisZ, upX, upY, upZ, trunkLength)
    local currentShape = shape
    local currentLength = trunkLength
    local cutCount = 0

    while currentShape ~= nil
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
                "[LoggingContractor][BranchCut] shape=%d candidate did not split geometry",
                currentShape
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
        currentLength = mainAxisLength > 0 and mainAxisLength or currentLength
        cutCount = cutCount + 1

        Logging.info(
            "[LoggingContractor][BranchCut] oldShape=%d mainShape=%d parts=%d mainLength=%.2f mainMeasure=%.3f",
            oldShape,
            currentShape,
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
                    local angularX, angularY, angularZ =
                        self:getContractorFallAngularVelocity(upX, upY, upZ)
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
        "[LoggingContractor][BranchPruneDone] shape=%s cuts=%d length=%.2f",
        tostring(currentShape),
        cutCount,
        currentLength
    )

    return currentShape, currentLength
end

--[[
    LoggingContractorTreePhysics

    Низкоуровневая физическая обработка дерева подрядчиком.

    Порядок обработки:
    - дерево сначала отделяется от пня штатным splitShape;
    - на уже динамическом дереве ищутся крупные боковые развилки;
    - крупная ветвь отделяется плоскостью, ориентированной вдоль основного ствола;
    - отделённая ветвь дополнительно очищается от attachments;
    - основной ствол очищается и режется на выбранную длину;
    - готовые части получают небольшой угловой импульс для естественного падения.

    Поиск развилок пока намеренно сопровождается подробным диагностическим логом.
    После отладки сообщения можно будет удалить без изменения алгоритма.
]]

LoggingContractor.FALL_ANGULAR_SPEED = 0.8
LoggingContractor.STUMP_DIRTY_RADIUS = 10
LoggingContractor.DELIMB_PADDING = 2
LoggingContractor.DELIMB_MAX_PASSES = 4

LoggingContractor.BRANCH_SCAN_MIN_STEP = 0.5
LoggingContractor.BRANCH_SCAN_MAX_STEP = 0.9
LoggingContractor.BRANCH_BASE_SAMPLE_FRACTION = 0.35
LoggingContractor.BRANCH_WIDTH_FACTOR = 1.8
LoggingContractor.BRANCH_MIN_WIDTH_GROWTH = 0.35
LoggingContractor.BRANCH_CUT_INSET_FACTOR = 0.8
LoggingContractor.BRANCH_MAX_CUTS = 6
LoggingContractor.BRANCH_MIN_PART_VOLUME = 0.01


-- Помечает область вокруг удалённого пня изменённой для collision map и AI.
-- Размер области соответствует штатному StumpCutter:crushSplitShape().
function LoggingContractor:markContractorStumpAreaDirty(x, z)
    local radius = LoggingContractor.STUMP_DIRTY_RADIUS

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


-- Callback splitShape регистрирует новые части штатным способом GIANTS.
-- При первом срезе дерева статическая нижняя часть является пнём и сразу
-- удаляется аналогично StumpCutter:crushSplitShape().
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

    if operation.fromTree and getRigidBodyType(shape) == RigidBodyType.STATIC then
        local x, _, z = getWorldTranslation(shape)
        delete(shape)
        self:markContractorStumpAreaDirty(x, z)
    end
end


-- Возвращает размеры, количество convex-частей и attachments split-shape.
-- Эти значения напрямую возвращает штатная getSplitShapeStats().
function LoggingContractor:getContractorSplitShapeStats(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return 0, 0, 0, 0, 0
    end

    local sizeX, sizeY, sizeZ, numConvexes, numAttachments = getSplitShapeStats(shape)
    return sizeX or 0, sizeY or 0, sizeZ or 0, numConvexes or 0, numAttachments or 0
end


-- Возвращает главную ось произвольной отделённой части дерева по штатному OBB.
-- GIANTS использует getSplitShapeOrientedBoundingBox для отладки split-shape;
-- здесь выбирается ось с наибольшим extent как продольная ось ветви/бревна.
function LoggingContractor:getContractorShapeMainAxis(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return nil
    end

    local box = getSplitShapeOrientedBoundingBox(shape)
    if box == nil or #box < 15 then
        return nil
    end

    local axes = {
        {x = box[1], y = box[2], z = box[3], extent = box[13]},
        {x = box[4], y = box[5], z = box[6], extent = box[14]},
        {x = box[7], y = box[8], z = box[9], extent = box[15]}
    }

    table.sort(axes, function(a, b)
        return (a.extent or 0) > (b.extent or 0)
    end)

    local mainAxis = axes[1]
    local upAxis = axes[2]
    if mainAxis == nil or (mainAxis.extent or 0) <= 0 then
        return nil
    end

    local centerX, centerY, centerZ = localToWorld(shape, box[10], box[11], box[12])
    local dirX, dirY, dirZ = localDirectionToWorld(shape, mainAxis.x, mainAxis.y, mainAxis.z)
    local upX, upY, upZ = localDirectionToWorld(shape, upAxis.x, upAxis.y, upAxis.z)
    dirX, dirY, dirZ = MathUtil.vector3Normalize(dirX, dirY, dirZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)

    return centerX, centerY, centerZ, dirX, dirY, dirZ, upX, upY, upZ, mainAxis.extent * 2
end


-- Очищает уже отделённый динамический split-shape от attachments.
-- Область центрируется на середине части и рассчитывается по её реальным
-- габаритам. Несколько проходов позволяют удалить вложенные группы attachments.
function LoggingContractor:delimbContractorTrunk(shape, baseX, baseY, baseZ, dirX, dirY, dirZ, upX, upY, upZ, trunkLength)
    if shape == nil or shape == 0 or not entityExists(shape) or trunkLength <= 0 then
        return
    end

    local sizeX, sizeY, sizeZ, numConvexes, attachmentsBefore = self:getContractorSplitShapeStats(shape)
    if attachmentsBefore <= 0 then
        return
    end

    local midX = baseX + dirX * trunkLength * 0.5
    local midY = baseY + dirY * trunkLength * 0.5
    local midZ = baseZ + dirZ * trunkLength * 0.5
    local maxShapeSize = math.max(sizeX, sizeY, sizeZ, trunkLength)
    local delimbSize = maxShapeSize * 2 + LoggingContractor.DELIMB_PADDING * 2

    local attachmentsAfter = attachmentsBefore
    local previousAttachments = attachmentsBefore + 1
    local passes = 0

    while attachmentsAfter > 0
        and attachmentsAfter < previousAttachments
        and passes < LoggingContractor.DELIMB_MAX_PASSES do
        previousAttachments = attachmentsAfter
        passes = passes + 1

        removeSplitShapeAttachments(
            shape,
            midX,
            midY,
            midZ,
            dirX,
            dirY,
            dirZ,
            upX,
            upY,
            upZ,
            delimbSize,
            delimbSize,
            delimbSize
        )

        if not entityExists(shape) then
            return
        end

        local _, _, _, _, currentAttachments = self:getContractorSplitShapeStats(shape)
        attachmentsAfter = currentAttachments
    end

    Logging.info(
        "[LoggingContractor][Delimb] shape=%d attachments=%d->%d convexes=%d size=%.2fx%.2fx%.2f volume=%.3f passes=%d",
        shape,
        attachmentsBefore,
        attachmentsAfter,
        numConvexes,
        sizeX,
        sizeY,
        sizeZ,
        getVolume(shape),
        passes
    )
end


-- Измеряет поперечное сечение split-shape плоскостью, перпендикулярной основной
-- оси ствола. Возвращаемые testSplitShape границы переводятся в размеры и
-- смещение центра сечения относительно оси основного ствола.
function LoggingContractor:sampleContractorCrossSection(shape, centerX, centerY, centerZ, axisX, axisY, axisZ, upX, upY, upZ, scanSize)
    local sideX, sideY, sideZ = MathUtil.crossProduct(axisX, axisY, axisZ, upX, upY, upZ)
    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    local halfSize = scanSize * 0.5
    local planeX = centerX - upX * halfSize - sideX * halfSize
    local planeY = centerY - upY * halfSize - sideY * halfSize
    local planeZ = centerZ - upZ * halfSize - sideZ * halfSize

    local minY, maxY, minZ, maxZ = testSplitShape(
        shape,
        planeX,
        planeY,
        planeZ,
        axisX,
        axisY,
        axisZ,
        upX,
        upY,
        upZ,
        scanSize,
        scanSize
    )

    if minY == nil then
        return nil
    end

    local widthUp = maxY - minY
    local widthSide = maxZ - minZ
    local centerUp = (minY + maxY) * 0.5 - halfSize
    local centerSide = (minZ + maxZ) * 0.5 - halfSize

    return {
        widthUp = widthUp,
        widthSide = widthSide,
        maxWidth = math.max(widthUp, widthSide),
        centerUp = centerUp,
        centerSide = centerSide,
        minUp = minY - halfSize,
        maxUp = maxY - halfSize,
        minSide = minZ - halfSize,
        maxSide = maxZ - halfSize,
        sideX = sideX,
        sideY = sideY,
        sideZ = sideZ
    }
end


-- Находит первую крупную развилку основного ствола. Кривизна одного ствола
-- сама по себе не считается ветвью: требуется именно заметное увеличение
-- ширины поперечного сечения относительно фактического диаметра нижней части.
function LoggingContractor:findContractorBranchCandidate(shape, baseX, baseY, baseZ, axisX, axisY, axisZ, upX, upY, upZ, trunkLength)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return nil
    end

    local sizeX, sizeY, sizeZ, numConvexes, numAttachments = self:getContractorSplitShapeStats(shape)
    local scanSize = math.max(sizeX, sizeY, sizeZ, 4) + 2
    local step = math.clamp(trunkLength / 40, LoggingContractor.BRANCH_SCAN_MIN_STEP, LoggingContractor.BRANCH_SCAN_MAX_STEP)
    local samples = {}
    local distance = math.min(step, trunkLength * 0.1)

    while distance < trunkLength - step * 0.5 do
        local x = baseX + axisX * distance
        local y = baseY + axisY * distance
        local z = baseZ + axisZ * distance
        local sample = self:sampleContractorCrossSection(
            shape,
            x,
            y,
            z,
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
        local expanded = sample.maxWidth >= threshold

        if expanded then
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

    local centerMagnitude = math.sqrt(
        widestSample.centerSide * widestSample.centerSide
        + widestSample.centerUp * widestSample.centerUp
    )

    local radialSide
    local radialUp
    if centerMagnitude > baselineDiameter * 0.15 then
        radialSide = widestSample.centerSide / centerMagnitude
        radialUp = widestSample.centerUp / centerMagnitude
    else
        local positiveSide = widestSample.maxSide
        local negativeSide = -widestSample.minSide
        local positiveUp = widestSample.maxUp
        local negativeUp = -widestSample.minUp
        local maximum = math.max(positiveSide, negativeSide, positiveUp, negativeUp)

        if maximum == positiveSide then
            radialSide, radialUp = 1, 0
        elseif maximum == negativeSide then
            radialSide, radialUp = -1, 0
        elseif maximum == positiveUp then
            radialSide, radialUp = 0, 1
        else
            radialSide, radialUp = 0, -1
        end
    end

    local branchDirX = widestSample.sideX * radialSide + upX * radialUp
    local branchDirY = widestSample.sideY * radialSide + upY * radialUp
    local branchDirZ = widestSample.sideZ * radialSide + upZ * radialUp
    branchDirX, branchDirY, branchDirZ = MathUtil.vector3Normalize(branchDirX, branchDirY, branchDirZ)

    local baseRadius = baselineDiameter * 0.5
    local rootDistance = (groupStart + groupEnd) * 0.5
    local axisPointX = baseX + axisX * rootDistance
    local axisPointY = baseY + axisY * rootDistance
    local axisPointZ = baseZ + axisZ * rootDistance
    local cutOffset = baseRadius * LoggingContractor.BRANCH_CUT_INSET_FACTOR
    local cutX = axisPointX + branchDirX * cutOffset
    local cutY = axisPointY + branchDirY * cutOffset
    local cutZ = axisPointZ + branchDirZ * cutOffset

    local groupLength = math.max((groupEnd - groupStart) + step * 2, baselineDiameter * 4, 1.5)
    local cutWidth = math.max(widestSample.maxWidth + baselineDiameter, baselineDiameter * 4, 1.5)

    Logging.info(
        "[LoggingContractor][BranchCandidate] shape=%d zone=%.2f..%.2f widest=%.2f width=%.2f centerOffset=(%.2f,%.2f) dir=(%.3f,%.3f,%.3f) cut=(%.2f,%.2f,%.2f) plane=%.2fx%.2f",
        shape,
        groupStart,
        groupEnd,
        widestSample.distance,
        widestSample.maxWidth,
        widestSample.centerSide,
        widestSample.centerUp,
        branchDirX,
        branchDirY,
        branchDirZ,
        cutX,
        cutY,
        cutZ,
        groupLength,
        cutWidth
    )

    return {
        cutX = cutX,
        cutY = cutY,
        cutZ = cutZ,
        normalX = branchDirX,
        normalY = branchDirY,
        normalZ = branchDirZ,
        upX = axisX,
        upY = axisY,
        upZ = axisZ,
        sizeY = groupLength,
        sizeZ = cutWidth,
        baselineDiameter = baselineDiameter,
        rootDistance = rootDistance
    }
end


-- Выполняет splitShape произвольной прямоугольной плоскостью. Для боковой ветви
-- ось Y плоскости направлена вдоль основного ствола, поэтому ветвь снимается
-- продольным резом заподлицо со стволом, а не поперёк самой ветви.
function LoggingContractor:splitContractorShapeSized(shape, centerX, centerY, centerZ, normalX, normalY, normalZ, upX, upY, upZ, sizeY, sizeZ)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return {}
    end

    normalX, normalY, normalZ = MathUtil.vector3Normalize(normalX, normalY, normalZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)

    local sideX, sideY, sideZ = MathUtil.crossProduct(normalX, normalY, normalZ, upX, upY, upZ)
    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    local planeX = centerX - upX * sizeY * 0.5 - sideX * sizeZ * 0.5
    local planeY = centerY - upY * sizeY * 0.5 - sideY * sizeZ * 0.5
    local planeZ = centerZ - upZ * sizeY * 0.5 - sideZ * sizeZ * 0.5

    self.activeContractSplitOperation = {
        oldShape = shape,
        fromTree = false,
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
        sizeY,
        sizeZ,
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


-- Выбирает после продольного реза часть, которая продолжает основной ствол.
-- Приоритет имеет часть, которую всё ещё пересекает исходная ось ствола на
-- максимальной длине; при равенстве используется больший объём.
function LoggingContractor:selectContractorMainStemPart(parts, baseX, baseY, baseZ, axisX, axisY, axisZ)
    local mainPart = nil
    local bestAxisLength = -1
    local bestVolume = -1

    for _, part in ipairs(parts) do
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
            local axisLength = 0
            if below ~= nil then
                axisLength = axisLength + below
            end
            if above ~= nil then
                axisLength = axisLength + above
            end

            local volume = getVolume(part.shape) or 0
            if axisLength > bestAxisLength + 0.001
                or (math.abs(axisLength - bestAxisLength) <= 0.001 and volume > bestVolume) then
                mainPart = part
                bestAxisLength = axisLength
                bestVolume = volume
            end
        end
    end

    return mainPart, bestAxisLength, bestVolume
end


-- Очищает отделённую крупную ветвь от листвы/хвои и мелких attachments.
-- Продольная ось ветви определяется по её собственному oriented bounding box.
function LoggingContractor:cleanContractorDetachedBranch(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return
    end

    local centerX, centerY, centerZ, dirX, dirY, dirZ, upX, upY, upZ, length = self:getContractorShapeMainAxis(shape)
    local attachmentsBefore = select(5, self:getContractorSplitShapeStats(shape))

    if centerX ~= nil and length ~= nil and length > 0 then
        local baseX = centerX - dirX * length * 0.5
        local baseY = centerY - dirY * length * 0.5
        local baseZ = centerZ - dirZ * length * 0.5
        self:delimbContractorTrunk(
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
            length
        )
    end

    local _, _, _, numConvexes, attachmentsAfter = self:getContractorSplitShapeStats(shape)
    Logging.info(
        "[LoggingContractor][BranchClean] shape=%d volume=%.3f convexes=%d attachments=%d->%d length=%.2f",
        shape,
        getVolume(shape) or 0,
        numConvexes,
        attachmentsBefore,
        attachmentsAfter,
        length or 0
    )
end


-- Последовательно отделяет крупные боковые ветви от уже спиленного дерева.
-- После каждого реального разреза основной ствол определяется заново, а
-- отделённые части проходят самостоятельную очистку от attachments.
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

        local mainPart, mainAxisLength, mainVolume = self:selectContractorMainStemPart(
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
            "[LoggingContractor][BranchCut] oldShape=%d mainShape=%d parts=%d mainLength=%.2f mainVolume=%.3f",
            oldShape,
            currentShape,
            #parts,
            currentLength,
            mainVolume
        )

        for _, part in ipairs(parts) do
            if part.shape ~= nil
                and part.shape ~= currentShape
                and entityExists(part.shape)
                and (getVolume(part.shape) or 0) >= LoggingContractor.BRANCH_MIN_PART_VOLUME then
                self:cleanContractorDetachedBranch(part.shape)
                local branchAngularX, branchAngularY, branchAngularZ = self:getContractorFallAngularVelocity(upX, upY, upZ)
                self:applyContractorFall(part.shape, branchAngularX, branchAngularY, branchAngularZ)
            end
        end
    end

    Logging.info(
        "[LoggingContractor][BranchPruneDone] shape=%s cuts=%d length=%.2f",
        tostring(currentShape),
        cutCount,
        currentLength
    )

    return currentShape, currentLength
end


-- Рассчитывает угловую скорость заваливания по тому же принципу, который
-- ChainsawUtil использует после штатного спила дерева бензопилой.
function LoggingContractor:getContractorFallAngularVelocity(upX, upY, upZ)
    local angularX, angularY, angularZ = MathUtil.crossProduct(
        0,
        LoggingContractor.FALL_ANGULAR_SPEED,
        0,
        upX,
        upY,
        upZ
    )

    if MathUtil.vector3Length(angularX, angularY, angularZ) < 0.001 then
        angularX = LoggingContractor.FALL_ANGULAR_SPEED
        angularY = 0
        angularZ = 0
    end

    return angularX, angularY, angularZ
end


-- Выводит готовое динамическое бревно из идеально вертикального равновесия.
-- Тип rigid body не меняется: подрядчик лишь задаёт штатную угловую скорость.
function LoggingContractor:applyContractorFall(shape, angularX, angularY, angularZ)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return
    end

    if getRigidBodyType(shape) == RigidBodyType.DYNAMIC then
        setAngularVelocity(shape, angularX, angularY, angularZ)
    end
end


-- Режет спиленное дерево на выбранную длину. До продольной нарезки выполняется
-- отдельный этап снятия крупных боковых ветвей плоскостью вдоль основного ствола.
-- Короткий последний остаток сохраняется отдельным бревном.
function LoggingContractor:cutContractorTrunk(shape, baseX, baseY, baseZ, dirX, dirY, dirZ, upX, upY, upZ, trunkLength, logLength)
    local currentShape, prunedLength = self:pruneContractorBranches(
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
        trunkLength
    )

    if currentShape == nil or currentShape == 0 or not entityExists(currentShape) then
        return false
    end

    local currentX = baseX
    local currentY = baseY
    local currentZ = baseZ
    local remainingLength = prunedLength or trunkLength
    local angularX, angularY, angularZ = self:getContractorFallAngularVelocity(upX, upY, upZ)

    -- После снятия крупных ветвей повторно очищаем уже изменившийся основной ствол.
    self:delimbContractorTrunk(
        currentShape,
        currentX,
        currentY,
        currentZ,
        dirX,
        dirY,
        dirZ,
        upX,
        upY,
        upZ,
        remainingLength
    )

    while remainingLength > logLength + LoggingContractor.MIN_LOG_REMAINDER do
        if currentShape == nil or currentShape == 0 or not entityExists(currentShape) then
            return false
        end

        local cutX = currentX + dirX * logLength
        local cutY = currentY + dirY * logLength
        local cutZ = currentZ + dirZ * logLength
        local parts = self:splitContractorShape(
            currentShape,
            cutX,
            cutY,
            cutZ,
            dirX,
            dirY,
            dirZ,
            upX,
            upY,
            upZ,
            false
        )

        local logPart, remainderPart = self:getSplitPartsBySide(parts)
        if logPart == nil or logPart.shape == nil
            or remainderPart == nil or remainderPart.shape == nil then
            Logging.warning(
                "[LoggingContractor] Unable to split trunk at %.2f m, keeping remaining trunk unsplit",
                logLength
            )
            self:delimbContractorTrunk(
                currentShape,
                currentX,
                currentY,
                currentZ,
                dirX,
                dirY,
                dirZ,
                upX,
                upY,
                upZ,
                remainingLength
            )
            self:applyContractorFall(currentShape, angularX, angularY, angularZ)
            return false
        end

        self:delimbContractorTrunk(
            logPart.shape,
            currentX,
            currentY,
            currentZ,
            dirX,
            dirY,
            dirZ,
            upX,
            upY,
            upZ,
            logLength
        )
        self:applyContractorFall(logPart.shape, angularX, angularY, angularZ)

        currentShape = remainderPart.shape
        currentX = cutX
        currentY = cutY
        currentZ = cutZ
        remainingLength = remainingLength - logLength
    end

    if currentShape ~= nil and currentShape ~= 0 and entityExists(currentShape) then
        self:delimbContractorTrunk(
            currentShape,
            currentX,
            currentY,
            currentZ,
            dirX,
            dirY,
            dirZ,
            upX,
            upY,
            upZ,
            remainingLength
        )
        self:applyContractorFall(currentShape, angularX, angularY, angularZ)
    end

    return true
end

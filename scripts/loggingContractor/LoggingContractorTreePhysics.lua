--[[
    LoggingContractorTreePhysics

    Низкоуровневые операции с split-shape для подрядчика:
    - чтение геометрии дерева;
    - поперечные сечения testSplitShape;
    - произвольный splitShape;
    - выбор основной части ствола;
    - физическое разделение ветвей и падение готовых частей;
    - раскряжёвка очищенного ствола.

    Поиск крупных ветвей и удаление attachments находятся отдельно в
    LoggingContractorTreeProcessing.lua.
]]

LoggingContractor.FALL_ANGULAR_SPEED = 0.8
LoggingContractor.BRANCH_SEPARATION_SPEED = 0.55
LoggingContractor.BRANCH_SEPARATION_UP_SPEED = 0.15


-- Возвращает размеры, число convex-частей и attachments split-shape.
function LoggingContractor:getContractorSplitShapeStats(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return 0, 0, 0, 0, 0
    end

    local sizeX, sizeY, sizeZ, numConvexes, numAttachments = getSplitShapeStats(shape)
    return sizeX or 0, sizeY or 0, sizeZ or 0, numConvexes or 0, numAttachments or 0
end


-- Возвращает геометрическую оценку размера split-shape.
-- getVolume() у древесины может возвращать 0, поэтому для сравнения частей
-- используется произведение габаритов.
function LoggingContractor:getContractorShapeMeasure(shape)
    local sizeX, sizeY, sizeZ, numConvexes, numAttachments =
        self:getContractorSplitShapeStats(shape)

    return sizeX * sizeY * sizeZ, sizeX, sizeY, sizeZ, numConvexes, numAttachments
end


-- Возвращает главную продольную ось произвольной отделённой части дерева по OBB.
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
    if mainAxis == nil or upAxis == nil or (mainAxis.extent or 0) <= 0 then
        return nil
    end

    local centerX, centerY, centerZ = localToWorld(shape, box[10], box[11], box[12])
    local dirX, dirY, dirZ = localDirectionToWorld(
        shape,
        mainAxis.x,
        mainAxis.y,
        mainAxis.z
    )
    local upX, upY, upZ = localDirectionToWorld(
        shape,
        upAxis.x,
        upAxis.y,
        upAxis.z
    )

    dirX, dirY, dirZ = MathUtil.vector3Normalize(dirX, dirY, dirZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)

    return centerX, centerY, centerZ,
        dirX, dirY, dirZ,
        upX, upY, upZ,
        mainAxis.extent * 2
end


-- Измеряет поперечное сечение дерева плоскостью, перпендикулярной оси ствола.
function LoggingContractor:sampleContractorCrossSection(
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
    scanSize
)
    local sideX, sideY, sideZ = MathUtil.crossProduct(
        axisX, axisY, axisZ,
        upX, upY, upZ
    )
    if MathUtil.vector3Length(sideX, sideY, sideZ) < 0.001 then
        return nil
    end
    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    local halfSize = scanSize * 0.5
    local planeX = centerX - upX * halfSize - sideX * halfSize
    local planeY = centerY - upY * halfSize - sideY * halfSize
    local planeZ = centerZ - upZ * halfSize - sideZ * halfSize

    local minY, maxY, minZ, maxZ = testSplitShape(
        shape,
        planeX, planeY, planeZ,
        axisX, axisY, axisZ,
        upX, upY, upZ,
        scanSize, scanSize
    )

    if minY == nil then
        return nil
    end

    local widthUp = maxY - minY
    local widthSide = maxZ - minZ

    return {
        widthUp = widthUp,
        widthSide = widthSide,
        maxWidth = math.max(widthUp, widthSide),
        centerUp = (minY + maxY) * 0.5 - halfSize,
        centerSide = (minZ + maxZ) * 0.5 - halfSize,
        minUp = minY - halfSize,
        maxUp = maxY - halfSize,
        minSide = minZ - halfSize,
        maxSide = maxZ - halfSize,
        sideX = sideX,
        sideY = sideY,
        sideZ = sideZ
    }
end


-- Выполняет splitShape прямоугольной плоскостью заданного размера.
function LoggingContractor:splitContractorShapeSized(
    shape,
    centerX,
    centerY,
    centerZ,
    normalX,
    normalY,
    normalZ,
    upX,
    upY,
    upZ,
    sizeY,
    sizeZ
)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return {}
    end

    normalX, normalY, normalZ = MathUtil.vector3Normalize(normalX, normalY, normalZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)

    local sideX, sideY, sideZ = MathUtil.crossProduct(
        normalX, normalY, normalZ,
        upX, upY, upZ
    )
    if MathUtil.vector3Length(sideX, sideY, sideZ) < 0.001 then
        return {}
    end
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
        planeX, planeY, planeZ,
        normalX, normalY, normalZ,
        upX, upY, upZ,
        sizeY, sizeZ,
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


-- Выбирает после продольного реза часть, продолжающую исходную ось ствола.
function LoggingContractor:selectContractorMainStemPart(
    parts,
    baseX,
    baseY,
    baseZ,
    axisX,
    axisY,
    axisZ
)
    local mainPart = nil
    local bestAxisLength = -1
    local bestMeasure = -1

    for _, part in ipairs(parts) do
        if part.shape ~= nil and entityExists(part.shape) then
            local below, above = getSplitShapePlaneExtents(
                part.shape,
                baseX, baseY, baseZ,
                axisX, axisY, axisZ
            )
            local axisLength = (below or 0) + (above or 0)
            local measure = self:getContractorShapeMeasure(part.shape)

            if axisLength > bestAxisLength + 0.001
                or (math.abs(axisLength - bestAxisLength) <= 0.001
                    and measure > bestMeasure) then
                mainPart = part
                bestAxisLength = axisLength
                bestMeasure = measure
            end
        end
    end

    return mainPart, bestAxisLength, bestMeasure
end


-- Раздвигает уже реально отделённую динамическую ветвь.
-- Тип rigid body не меняется.
function LoggingContractor:separateContractorBranch(shape, normalX, normalY, normalZ)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return
    end

    if getRigidBodyType(shape) ~= RigidBodyType.DYNAMIC then
        return
    end

    setLinearVelocity(
        shape,
        normalX * LoggingContractor.BRANCH_SEPARATION_SPEED,
        normalY * LoggingContractor.BRANCH_SEPARATION_SPEED
            + LoggingContractor.BRANCH_SEPARATION_UP_SPEED,
        normalZ * LoggingContractor.BRANCH_SEPARATION_SPEED
    )
end


-- Рассчитывает угловую скорость падения по принципу ChainsawUtil.
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
        return LoggingContractor.FALL_ANGULAR_SPEED, 0, 0
    end

    return angularX, angularY, angularZ
end


-- Выводит динамическую часть из идеально вертикального равновесия.
function LoggingContractor:applyContractorFall(shape, angularX, angularY, angularZ)
    if shape ~= nil
        and shape ~= 0
        and entityExists(shape)
        and getRigidBodyType(shape) == RigidBodyType.DYNAMIC then
        setAngularVelocity(shape, angularX, angularY, angularZ)
    end
end


-- Снимает крупные ветви и раскряжёвывает подготовленный основной ствол.
function LoggingContractor:cutContractorTrunk(
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
    trunkLength,
    logLength
)
    local currentShape, processedLength = self:pruneContractorBranches(
        shape,
        baseX, baseY, baseZ,
        dirX, dirY, dirZ,
        upX, upY, upZ,
        trunkLength
    )

    if currentShape == nil or currentShape == 0 or not entityExists(currentShape) then
        return false
    end

    local currentX, currentY, currentZ = baseX, baseY, baseZ
    local remainingLength = processedLength or trunkLength
    local angularX, angularY, angularZ =
        self:getContractorFallAngularVelocity(upX, upY, upZ)

    while remainingLength > logLength + LoggingContractor.MIN_LOG_REMAINDER do
        if not entityExists(currentShape) then
            return false
        end

        local cutX = currentX + dirX * logLength
        local cutY = currentY + dirY * logLength
        local cutZ = currentZ + dirZ * logLength

        local parts = self:splitContractorShape(
            currentShape,
            cutX, cutY, cutZ,
            dirX, dirY, dirZ,
            upX, upY, upZ,
            false
        )
        local logPart, remainderPart = self:getSplitPartsBySide(parts)

        if logPart == nil or logPart.shape == nil
            or remainderPart == nil or remainderPart.shape == nil then
            Logging.warning(
                "[LoggingContractor] Unable to split trunk at %.2f m; remaining part kept whole",
                logLength
            )
            self:applyContractorFall(currentShape, angularX, angularY, angularZ)
            return false
        end

        self:applyContractorFall(logPart.shape, angularX, angularY, angularZ)

        currentShape = remainderPart.shape
        currentX, currentY, currentZ = cutX, cutY, cutZ
        remainingLength = remainingLength - logLength
    end

    self:applyContractorFall(currentShape, angularX, angularY, angularZ)
    return true
end

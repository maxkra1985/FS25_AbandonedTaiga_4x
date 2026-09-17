--[[
    LoggingContractorTreePhysics

    Низкоуровневая физическая обработка дерева подрядчиком.

    Порядок обработки соответствует механике GIANTS:
    - сначала дерево отделяется от пня;
    - затем уже динамический спиленный ствол очищается от attachments;
    - после очистки ствол режется на выбранную длину;
    - пень удаляется;
    - готовые брёвна получают небольшой угловой импульс для естественного падения.
]]

LoggingContractor.FALL_ANGULAR_SPEED = 0.8
LoggingContractor.STUMP_DIRTY_RADIUS = 10
LoggingContractor.DELIMB_PADDING = 2
LoggingContractor.DELIMB_MAX_PASSES = 4


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


-- Очищает уже отделённый динамический ствол от attachments до его распила.
-- Область центрируется на середине ствола и намеренно перекрывает габариты
-- всего конкретного split-shape. removeSplitShapeAttachments получает shape,
-- поэтому большая область не затрагивает соседние деревья.
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

    -- Для кривых и раскидистых деревьев ось основного ствола не описывает всю
    -- крону. Кубическая зона берётся по максимальному реальному габариту shape
    -- и с удвоенным запасом, чтобы охватить корни attachments боковых ветвей.
    local maxShapeSize = math.max(sizeX, sizeY, sizeZ, trunkLength)
    local delimbSize = maxShapeSize * 2 + LoggingContractor.DELIMB_PADDING * 2

    local attachmentsAfter = attachmentsBefore
    local previousAttachments = attachmentsBefore + 1
    local passes = 0

    -- Несколько проходов нужны для деревьев со сложной иерархией attachments:
    -- после удаления внешней группы движок может открыть следующую группу.
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
        "[LoggingContractor] Post-fell delimb shape %d: attachments %d -> %d, convexes=%d, size=%.2fx%.2fx%.2f, delimbSize=%.2f, passes=%d",
        shape,
        attachmentsBefore,
        attachmentsAfter,
        numConvexes,
        sizeX,
        sizeY,
        sizeZ,
        delimbSize,
        passes
    )
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


-- Режет очищенный ствол на выбранную длину. Каждый завершённый сортимент
-- дополнительно проверяется на остаточные attachments и получает одинаковое
-- направление заваливания. Короткий последний остаток сохраняется как бревно.
function LoggingContractor:cutContractorTrunk(shape, baseX, baseY, baseZ, dirX, dirY, dirZ, upX, upY, upZ, trunkLength, logLength)
    local currentShape = shape
    local currentX = baseX
    local currentY = baseY
    local currentZ = baseZ
    local remainingLength = trunkLength
    local angularX, angularY, angularZ = self:getContractorFallAngularVelocity(upX, upY, upZ)

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

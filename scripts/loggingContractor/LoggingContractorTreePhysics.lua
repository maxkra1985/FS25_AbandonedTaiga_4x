--[[
    LoggingContractorTreePhysics

    Низкоуровневая физическая обработка дерева подрядчиком.

    Модуль загружается после LoggingContractorExecution и уточняет операции,
    которые непосредственно работают со split-shape:
    - предварительно очищает стоящее дерево от attachments до первого среза;
    - удаляет пень после первого среза;
    - повторно очищает каждый полученный сортимент;
    - после распила задаёт каждому готовому бревну небольшой угловой импульс,
      чтобы динамические части не оставались в идеально вертикальном равновесии.
]]

LoggingContractor.FALL_ANGULAR_SPEED = 0.8
LoggingContractor.STUMP_DIRTY_RADIUS = 10
LoggingContractor.DELIMB_SWEEP_STEP = 0.6
LoggingContractor.DELIMB_SWEEP_LENGTH = 0.7
LoggingContractor.DELIMB_CROSS_SIZE = 4
LoggingContractor.DELIMB_FIND_CROSS_SIZE = 1.25


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


-- Возвращает количество attachments у split-shape. Значение используется только
-- для выбора дополнительного штатного прохода chainsaw-delimb и диагностики.
function LoggingContractor:getContractorAttachmentCount(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return 0
    end

    local _, _, _, _, numAttachments = getSplitShapeStats(shape)
    return numAttachments or 0
end


-- Удаляет attachments с конкретного split-shape серией коротких проходов вдоль
-- оси ствола. Такой проход повторяет работу delimbNode харвестера: вместо одной
-- большой области по всему дереву используется последовательность зон обработки.
function LoggingContractor:sweepContractorAttachments(shape, baseX, baseY, baseZ, dirX, dirY, dirZ, upX, upY, upZ, trunkLength)
    if shape == nil or shape == 0 or not entityExists(shape) or trunkLength <= 0 then
        return
    end

    local distance = 0
    while distance <= trunkLength + LoggingContractor.MIN_LOG_REMAINDER do
        local x = baseX + dirX * distance
        local y = baseY + dirY * distance
        local z = baseZ + dirZ * distance

        removeSplitShapeAttachments(
            shape,
            x,
            y,
            z,
            dirX,
            dirY,
            dirZ,
            upX,
            upY,
            upZ,
            LoggingContractor.DELIMB_SWEEP_LENGTH,
            LoggingContractor.DELIMB_CROSS_SIZE,
            LoggingContractor.DELIMB_CROSS_SIZE
        )

        distance = distance + LoggingContractor.DELIMB_SWEEP_STEP
    end
end


-- Выполняет дополнительный chainsaw-проход по attachments, которые не снялись
-- адресным removeSplitShapeAttachments. Область намеренно уже, чтобы не задеть
-- соседние деревья; вызывается только если у целевого shape attachments остались.
function LoggingContractor:findAndSweepContractorAttachments(baseX, baseY, baseZ, dirX, dirY, dirZ, upX, upY, upZ, trunkLength)
    local distance = 0
    while distance <= trunkLength + LoggingContractor.MIN_LOG_REMAINDER do
        local x = baseX + dirX * distance
        local y = baseY + dirY * distance
        local z = baseZ + dirZ * distance

        findAndRemoveSplitShapeAttachments(
            x,
            y,
            z,
            dirX,
            dirY,
            dirZ,
            upX,
            upY,
            upZ,
            LoggingContractor.DELIMB_SWEEP_LENGTH,
            LoggingContractor.DELIMB_FIND_CROSS_SIZE,
            LoggingContractor.DELIMB_FIND_CROSS_SIZE
        )

        distance = distance + LoggingContractor.DELIMB_SWEEP_STEP
    end
end


-- Предварительно опиливает attachments на ещё стоящем дереве. Это особенно
-- важно для развилочных и кривых деревьев: боковые сучья удаляются до того,
-- как основной ствол начнёт делиться на сортименты.
function LoggingContractor:preDelimbContractTree(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return
    end

    local treeX, treeY, treeZ = getWorldTranslation(shape)
    local localX, localY, localZ = worldToLocal(
        shape,
        treeX,
        treeY + LoggingContractor.STUMP_HEIGHT,
        treeZ
    )
    local baseX, baseY, baseZ = localToWorld(shape, localX, localY, localZ)

    local dirX, dirY, dirZ = localDirectionToWorld(shape, 0, 1, 0)
    local upX, upY, upZ = localDirectionToWorld(shape, 0, 0, 1)
    dirX, dirY, dirZ = MathUtil.vector3Normalize(dirX, dirY, dirZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)

    local lengthBelow, lengthAbove = getSplitShapePlaneExtents(
        shape,
        baseX,
        baseY,
        baseZ,
        dirX,
        dirY,
        dirZ
    )
    if lengthBelow == nil or lengthAbove == nil then
        return
    end

    local trunkLength
    if lengthBelow > lengthAbove then
        dirX = -dirX
        dirY = -dirY
        dirZ = -dirZ
        trunkLength = lengthBelow
    else
        trunkLength = lengthAbove
    end

    if trunkLength <= LoggingContractor.MIN_LOG_REMAINDER then
        return
    end

    local attachmentsBefore = self:getContractorAttachmentCount(shape)

    self:sweepContractorAttachments(
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

    local attachmentsAfter = self:getContractorAttachmentCount(shape)
    if attachmentsAfter > 0 then
        self:findAndSweepContractorAttachments(
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
        attachmentsAfter = self:getContractorAttachmentCount(shape)
    end

    if attachmentsBefore > 0 then
        Logging.info(
            "[LoggingContractor] Pre-delimb shape %d: attachments %d -> %d",
            shape,
            attachmentsBefore,
            attachmentsAfter
        )
    end
end


-- Оборачивает штатную для нашего подрядчика обработку дерева предварительным
-- опиливанием attachments. Основной срез, удаление пня и распил выполняет
-- LoggingContractorExecution без изменения логики прогресса договора.
function LoggingContractor:processContractTreeWithPreDelimb(superFunc, job, shape)
    if self:isStandingContractTarget(shape, job.farmlandId) then
        self:preDelimbContractTree(shape)
    end

    return superFunc(self, job, shape)
end


-- Удаляет ветви и листву/хвою вдоль уже отделённого ствола. Помимо общего
-- прохода выполняется серия коротких проходов, как при движении ствола через
-- delimbNode харвестера.
function LoggingContractor:delimbContractorTrunk(shape, baseX, baseY, baseZ, dirX, dirY, dirZ, upX, upY, upZ, trunkLength)
    if shape == nil or shape == 0 or not entityExists(shape) or trunkLength <= 0 then
        return
    end

    local midX = baseX + dirX * trunkLength * 0.5
    local midY = baseY + dirY * trunkLength * 0.5
    local midZ = baseZ + dirZ * trunkLength * 0.5

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
        trunkLength * 0.7 + 0.1,
        LoggingContractor.DELIMB_CROSS_SIZE,
        LoggingContractor.DELIMB_CROSS_SIZE
    )

    self:sweepContractorAttachments(
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
-- дополнительно очищается от оставшихся attachments и получает одинаковое
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


LoggingContractor.processContractTree = Utils.overwrittenFunction(
    LoggingContractor.processContractTree,
    LoggingContractor.processContractTreeWithPreDelimb
)

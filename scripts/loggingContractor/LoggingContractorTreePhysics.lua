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


-- Возвращает количество attachments у уже спиленного split-shape.
-- Используется для контроля фактической очистки ветвей.
function LoggingContractor:getContractorAttachmentCount(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return 0
    end

    local _, _, _, _, numAttachments = getSplitShapeStats(shape)
    return numAttachments or 0
end


-- Выполняет серию коротких проходов removeSplitShapeAttachments вдоль уже
-- спиленного ствола. Это имитирует протягивание дерева через delimbNode харвестера.
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


-- Выполняет дополнительный проход тем же механизмом, который бензопила GIANTS
-- использует для ручной обрезки сучьев. Вызывается только после валки дерева.
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


-- Очищает уже отделённый динамический ствол от ветвей и листвы/хвои.
-- Сначала используется адресная функция харвестера, затем при наличии остаточных
-- attachments выполняется проход функцией ручной обрезки бензопилой.
function LoggingContractor:delimbContractorTrunk(shape, baseX, baseY, baseZ, dirX, dirY, dirZ, upX, upY, upZ, trunkLength)
    if shape == nil or shape == 0 or not entityExists(shape) or trunkLength <= 0 then
        return
    end

    local attachmentsBefore = self:getContractorAttachmentCount(shape)

    -- Общий проход вдоль всей длины, как при подготовке готового ствола GIANTS.
    removeSplitShapeAttachments(
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
        LoggingContractor.DELIMB_CROSS_SIZE,
        LoggingContractor.DELIMB_CROSS_SIZE
    )

    -- Дополнительные короткие зоны повторяют движение ствола через головку.
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
            "[LoggingContractor] Post-fell delimb shape %d: attachments %d -> %d",
            shape,
            attachmentsBefore,
            attachmentsAfter
        )
    end
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

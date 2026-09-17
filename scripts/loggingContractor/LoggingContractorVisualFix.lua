--[[
    LoggingContractorVisualFix

    Визуальная доводка обработки древесины подрядчиком.

    Предыдущая диагностика показала, что splitShape действительно делит
    раскидистую берёзу на несколько крупных split-shape, однако полученные
    части остаются практически в исходном положении и визуально продолжают
    выглядеть как единое дерево. Одновременно shape-specific
    removeSplitShapeAttachments уменьшает внутренний счётчик attachments,
    но не даёт ожидаемой визуальной очистки ветвей и листвы.

    Для мелких ветвей дополнительно используется тот же engine-вызов,
    которым HandToolChainsaw выполняет ручную обрезку:
    findAndRemoveSplitShapeAttachments(). Плоскость центрируется вокруг
    проверяемой точки явно, потому что debug-wrapper GIANTS трактует переданные
    x/y/z как угол плоскости, а не как её центр.

    Для крупных отделённых ветвей задаётся небольшая различающаяся линейная
    скорость. Это только выводит уже реально разделённые split-shape из
    совпадающего положения; тип rigid body при этом не меняется.
]]

LoggingContractor.CHAINSAW_DELIMB_STEP = 0.45
LoggingContractor.CHAINSAW_DELIMB_THICKNESS = 0.7
LoggingContractor.CHAINSAW_DELIMB_MIN_SIZE = 0.8
LoggingContractor.CHAINSAW_DELIMB_MAX_SIZE = 1.6
LoggingContractor.CHAINSAW_DELIMB_PADDING = 0.15
LoggingContractor.CHAINSAW_DELIMB_MAX_PASSES = 2

LoggingContractor.BRANCH_SEPARATION_SPEED = 0.65
LoggingContractor.BRANCH_SEPARATION_UP_SPEED = 0.20

local previousDelimbContractorTrunk = LoggingContractor.delimbContractorTrunk
local previousCleanContractorDetachedBranch = LoggingContractor.cleanContractorDetachedBranch


-- Возвращает медианный габарит split-shape. Для длинного прямого ствола это
-- близко к его диаметру, а для сложной кроны значение используется только как
-- признак того, что отделённая часть сама содержит крупные развилки.
function LoggingContractor:getContractorMedianShapeSize(shape)
    local sizeX, sizeY, sizeZ = self:getContractorSplitShapeStats(shape)
    local sizes = {sizeX, sizeY, sizeZ}
    table.sort(sizes)
    return sizes[2] or 0
end


-- Подбирает рабочую ширину плоскости ручной обрезки. Размер намеренно ограничен
-- сверху: findAndRemoveSplitShapeAttachments не принимает конкретный shape,
-- поэтому слишком большая зона могла бы задеть соседнее дерево.
function LoggingContractor:getContractorChainsawDelimbSize(shape, baseX, baseY, baseZ, dirX, dirY, dirZ, upX, upY, upZ, trunkLength)
    local diameter = self:getContractorMedianShapeSize(shape)

    if self.sampleContractorCrossSection ~= nil and trunkLength > 0 then
        local sizeX, sizeY, sizeZ = self:getContractorSplitShapeStats(shape)
        local scanSize = math.max(sizeX, sizeY, sizeZ, 2) + 1
        local distance = trunkLength * 0.5
        local sample = self:sampleContractorCrossSection(
            shape,
            baseX + dirX * distance,
            baseY + dirY * distance,
            baseZ + dirZ * distance,
            dirX,
            dirY,
            dirZ,
            upX,
            upY,
            upZ,
            scanSize
        )

        if sample ~= nil and sample.maxWidth ~= nil and sample.maxWidth > 0 then
            diameter = sample.maxWidth
        end
    end

    return math.clamp(
        diameter * 1.8 + LoggingContractor.CHAINSAW_DELIMB_PADDING,
        LoggingContractor.CHAINSAW_DELIMB_MIN_SIZE,
        LoggingContractor.CHAINSAW_DELIMB_MAX_SIZE
    )
end


-- Переводит центр плоскости в угол, ожидаемый engine-функцией ручной обрезки.
-- WrapFunctions GIANTS визуализирует findAndRemoveSplitShapeAttachments через
-- DebugUtil.drawDebugPlane(), где плоскость строится от x/y/z только в
-- положительных направлениях up и cross(normal, up).
function LoggingContractor:getContractorDelimbPlaneOrigin(centerX, centerY, centerZ, normalX, normalY, normalZ, upX, upY, upZ, sizeY, sizeZ)
    local sideX, sideY, sideZ = MathUtil.crossProduct(
        normalX,
        normalY,
        normalZ,
        upX,
        upY,
        upZ
    )

    if MathUtil.vector3Length(sideX, sideY, sideZ) < 0.001 then
        return nil
    end

    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    return centerX - upX * sizeY * 0.5 - sideX * sizeZ * 0.5,
        centerY - upY * sizeY * 0.5 - sideY * sizeZ * 0.5,
        centerZ - upZ * sizeY * 0.5 - sideZ * sizeZ * 0.5
end


-- Имитирует проход бензопилой по уже спиленному стволу или крупной ветви.
-- В каждой точке используется небольшая поперечная плоскость, а не одна
-- гигантская зона. Функция возвращает число вызовов, в которых движок сообщил
-- о фактически удалённом attachment.
function LoggingContractor:chainsawDelimbContractorShape(shape, baseX, baseY, baseZ, dirX, dirY, dirZ, upX, upY, upZ, trunkLength)
    if shape == nil or shape == 0 or not entityExists(shape) or trunkLength <= 0 then
        return 0
    end

    local _, _, _, _, attachmentsBefore = self:getContractorSplitShapeStats(shape)
    if attachmentsBefore <= 0 then
        return 0
    end

    dirX, dirY, dirZ = MathUtil.vector3Normalize(dirX, dirY, dirZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)

    local planeSizeY = self:getContractorChainsawDelimbSize(
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
    local planeSizeZ = math.max(planeSizeY - 0.2, 0.3)
    local totalHits = 0
    local previousAttachments = attachmentsBefore + 1
    local currentAttachments = attachmentsBefore
    local pass = 0

    while currentAttachments > 0
        and currentAttachments < previousAttachments
        and pass < LoggingContractor.CHAINSAW_DELIMB_MAX_PASSES do
        pass = pass + 1
        previousAttachments = currentAttachments
        local passHits = 0
        local distance = 0

        while distance <= trunkLength + 0.001 do
            local centerX = baseX + dirX * distance
            local centerY = baseY + dirY * distance
            local centerZ = baseZ + dirZ * distance
            local planeX, planeY, planeZ = self:getContractorDelimbPlaneOrigin(
                centerX,
                centerY,
                centerZ,
                dirX,
                dirY,
                dirZ,
                upX,
                upY,
                upZ,
                planeSizeY,
                planeSizeZ
            )

            if planeX ~= nil then
                local removed = findAndRemoveSplitShapeAttachments(
                    planeX,
                    planeY,
                    planeZ,
                    dirX,
                    dirY,
                    dirZ,
                    upX,
                    upY,
                    upZ,
                    LoggingContractor.CHAINSAW_DELIMB_THICKNESS,
                    planeSizeY,
                    planeSizeZ
                )

                if removed then
                    passHits = passHits + 1
                    totalHits = totalHits + 1
                end
            end

            distance = distance + LoggingContractor.CHAINSAW_DELIMB_STEP
        end

        if shape == nil or shape == 0 or not entityExists(shape) then
            return totalHits
        end

        local _, _, _, _, attachmentsAfterPass = self:getContractorSplitShapeStats(shape)
        currentAttachments = attachmentsAfterPass

        Logging.info(
            "[LoggingContractor][ChainsawDelimbPass] shape=%d pass=%d hits=%d attachments=%d->%d plane=%.2fx%.2f length=%.2f",
            shape,
            pass,
            passHits,
            previousAttachments,
            currentAttachments,
            planeSizeY,
            planeSizeZ,
            trunkLength
        )

        if passHits == 0 then
            break
        end
    end

    return totalHits
end


-- Заменяет прежнюю очистку комбинированным вариантом. Сначала выполняется
-- штатноподобный локальный проход бензопилы, который отвечает именно за
-- визуальное удаление мелких ветвей, затем прежний shape-specific delimb
-- дочищает то, что движок ещё считает attachments данного split-shape.
function LoggingContractor:delimbContractorTrunk(shape, baseX, baseY, baseZ, dirX, dirY, dirZ, upX, upY, upZ, trunkLength)
    if shape == nil or shape == 0 or not entityExists(shape) or trunkLength <= 0 then
        return
    end

    local _, _, _, _, attachmentsBefore = self:getContractorSplitShapeStats(shape)
    local hits = self:chainsawDelimbContractorShape(
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

    if entityExists(shape) then
        previousDelimbContractorTrunk(
            self,
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

    if entityExists(shape) then
        local _, _, _, _, attachmentsAfter = self:getContractorSplitShapeStats(shape)
        Logging.info(
            "[LoggingContractor][VisualDelimb] shape=%d hits=%d attachments=%d->%d",
            shape,
            hits,
            attachmentsBefore,
            attachmentsAfter
        )
    end
end


-- Придаёт уже отделённой динамической ветви небольшую отличающуюся скорость.
-- Это не заменяет splitShape: функция вызывается только после состоявшегося
-- разреза и нужна, чтобы совпадающие по положению части не продолжали визуально
-- падать как единое дерево.
function LoggingContractor:separateContractorDetachedBranch(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return
    end

    local rigidBodyType = getRigidBodyType(shape)
    if rigidBodyType ~= RigidBodyType.DYNAMIC then
        Logging.info(
            "[LoggingContractor][BranchSeparate] shape=%d rigidBody=%s skipped",
            shape,
            tostring(rigidBodyType)
        )
        return
    end

    local centerX, centerY, centerZ, dirX, dirY, dirZ = self:getContractorShapeMainAxis(shape)
    if centerX == nil then
        Logging.info("[LoggingContractor][BranchSeparate] shape=%d no OBB axis", shape)
        return
    end

    local sideX, sideY, sideZ = MathUtil.crossProduct(dirX, dirY, dirZ, 0, 1, 0)
    if MathUtil.vector3Length(sideX, sideY, sideZ) < 0.001 then
        sideX, sideY, sideZ = MathUtil.crossProduct(dirX, dirY, dirZ, 1, 0, 0)
    end

    if MathUtil.vector3Length(sideX, sideY, sideZ) < 0.001 then
        return
    end

    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    -- Разные split-shape получают противоположное направление, поэтому части
    -- одной кроны гарантированно выходят из совпадающего положения.
    local sign = shape % 2 == 0 and 1 or -1
    local velocityX = sideX * LoggingContractor.BRANCH_SEPARATION_SPEED * sign
    local velocityY = LoggingContractor.BRANCH_SEPARATION_UP_SPEED
    local velocityZ = sideZ * LoggingContractor.BRANCH_SEPARATION_SPEED * sign

    setLinearVelocity(shape, velocityX, velocityY, velocityZ)

    Logging.info(
        "[LoggingContractor][BranchSeparate] shape=%d center=(%.2f,%.2f,%.2f) velocity=(%.2f,%.2f,%.2f)",
        shape,
        centerX,
        centerY,
        centerZ,
        velocityX,
        velocityY,
        velocityZ
    )
end


-- После отделения крупной ветви выполняется её собственная очистка, а затем
-- уже реально разделённому динамическому shape задаётся небольшой отличающийся
-- линейный импульс. Это позволяет визуально увидеть состоявшийся распил.
function LoggingContractor:cleanContractorDetachedBranch(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return
    end

    previousCleanContractorDetachedBranch(self, shape)

    if shape ~= nil and shape ~= 0 and entityExists(shape) then
        self:separateContractorDetachedBranch(shape)
    end
end

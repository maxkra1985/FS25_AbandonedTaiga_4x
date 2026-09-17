--[[
    LoggingContractorBranchFix

    Уточняет обработку уже отделённых крупных ветвей после продольного splitShape.

    Диагностика последнего теста показала, что getVolume() для древесных
    split-shape возвращает 0. Из-за этого отделённая ветвь отбрасывалась нашим
    фильтром как якобы пустая: она не очищалась и не получала импульс падения,
    поэтому визуально дерево оставалось целым.
]]


-- Возвращает геометрическую оценку размера split-shape без getVolume().
-- Для диагностических сравнений используется произведение габаритов shape.
function LoggingContractor:getContractorShapeMeasure(shape)
    local sizeX, sizeY, sizeZ, numConvexes, numAttachments = self:getContractorSplitShapeStats(shape)
    return sizeX * sizeY * sizeZ, sizeX, sizeY, sizeZ, numConvexes, numAttachments
end


-- Выбирает часть, которая продолжает основной ствол после продольного реза.
-- Основной критерий -- длина пересечения исходной оси ствола. При равенстве
-- вместо getVolume(), который для этих split-shape равен нулю, используются
-- реальные габариты полученной части.
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

            local axisLength = 0
            if below ~= nil then
                axisLength = axisLength + below
            end
            if above ~= nil then
                axisLength = axisLength + above
            end

            local measure, sizeX, sizeY, sizeZ, numConvexes, numAttachments = self:getContractorShapeMeasure(part.shape)
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


-- Очищает отделённую крупную ветвь от листвы/хвои и мелких attachments.
-- Продольная ось ветви определяется по её собственному oriented bounding box.
function LoggingContractor:cleanContractorDetachedBranch(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return
    end

    local measureBefore, sizeXBefore, sizeYBefore, sizeZBefore, convexesBefore, attachmentsBefore = self:getContractorShapeMeasure(shape)
    local centerX, centerY, centerZ, dirX, dirY, dirZ, upX, upY, upZ, length = self:getContractorShapeMainAxis(shape)

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

    if not entityExists(shape) then
        Logging.info("[LoggingContractor][BranchClean] shape=%d removed during delimb", shape)
        return
    end

    local measureAfter, sizeXAfter, sizeYAfter, sizeZAfter, convexesAfter, attachmentsAfter = self:getContractorShapeMeasure(shape)
    Logging.info(
        "[LoggingContractor][BranchClean] shape=%d measure=%.3f->%.3f size=%.2fx%.2fx%.2f->%.2fx%.2fx%.2f convexes=%d->%d attachments=%d->%d length=%.2f",
        shape,
        measureBefore,
        measureAfter,
        sizeXBefore,
        sizeYBefore,
        sizeZBefore,
        sizeXAfter,
        sizeYAfter,
        sizeZAfter,
        convexesBefore,
        convexesAfter,
        attachmentsBefore,
        attachmentsAfter,
        length or 0
    )
end


-- Последовательно отделяет крупные боковые ветви от уже спиленного дерева.
-- Все реальные части, кроме выбранного основного ствола, теперь обязательно
-- обрабатываются: getVolume() больше не используется как фильтр существования
-- ветви, потому что движок возвращает для этих shape нулевой объём.
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

                local measure, sizeX, sizeY, sizeZ, numConvexes, numAttachments = self:getContractorShapeMeasure(part.shape)
                Logging.info(
                    "[LoggingContractor][BranchDetached] shape=%d measure=%.3f size=%.2fx%.2fx%.2f convexes=%d attachments=%d",
                    part.shape,
                    measure,
                    sizeX,
                    sizeY,
                    sizeZ,
                    numConvexes,
                    numAttachments
                )

                self:cleanContractorDetachedBranch(part.shape)

                if entityExists(part.shape) then
                    local branchAngularX, branchAngularY, branchAngularZ = self:getContractorFallAngularVelocity(upX, upY, upZ)
                    self:applyContractorFall(part.shape, branchAngularX, branchAngularY, branchAngularZ)
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

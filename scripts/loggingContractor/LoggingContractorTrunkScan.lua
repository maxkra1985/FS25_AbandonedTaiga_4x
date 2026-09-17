--[[
    LoggingContractorTrunkScan

    Совмещает полезное сканирование ствола с очисткой attachments.

    Весь ствол проходится с шагом 0.25 м. На каждом шаге узкой поперечной
    областью вызывается штатный removeSplitShapeAttachments() для конкретного
    split-shape. Первые 5 м после этого дополнительно анализируются существующим
    алгоритмом LoggingContractorBranchFix для поиска крупных боковых ветвей.

    После отметки 5 м геометрический анализ крупных ветвей не выполняется:
    проход продолжается только ради удаления мелких веток и листвы.
]]

LoggingContractor.ATTACHMENT_SCAN_STEP = 0.25
LoggingContractor.ATTACHMENT_SCAN_THICKNESS = 0.30
LoggingContractor.ATTACHMENT_SCAN_MIN_TRANSVERSE_SIZE = 4.0
LoggingContractor.ATTACHMENT_SCAN_PADDING = 2.0

local previousFindContractorBranchCandidate = LoggingContractor.findContractorBranchCandidate


-- Проходит весь ствол тонкими поперечными слоями и удаляет attachments.
-- Поперечный размер области берётся с запасом по общим габаритам shape, чтобы
-- захватывать attachments на удалённых боковых ветвях. Поскольку в вызов
-- передаётся конкретный shape, соседние деревья этим проходом не затрагиваются.
function LoggingContractor:scanContractorAttachmentsAlongTrunk(
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
    if shape == nil or shape == 0 or not entityExists(shape) or trunkLength <= 0 then
        return 0
    end

    local sizeX, sizeY, sizeZ, _, attachmentsBefore = self:getContractorSplitShapeStats(shape)
    if attachmentsBefore <= 0 then
        Logging.info(
            "[LoggingContractor][AttachmentScan] shape=%d length=%.2f attachments=0, nothing to remove",
            shape,
            trunkLength
        )
        return 0
    end

    axisX, axisY, axisZ = MathUtil.vector3Normalize(axisX, axisY, axisZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)

    local step = LoggingContractor.ATTACHMENT_SCAN_STEP
    local thickness = math.max(LoggingContractor.ATTACHMENT_SCAN_THICKNESS, step)
    local transverseSize = math.max(
        LoggingContractor.ATTACHMENT_SCAN_MIN_TRANSVERSE_SIZE,
        sizeX,
        sizeY,
        sizeZ
    ) + LoggingContractor.ATTACHMENT_SCAN_PADDING

    local attachmentsCurrent = attachmentsBefore
    local removedTotal = 0
    local hitSteps = 0
    local scanSteps = 0
    local distance = step * 0.5

    while distance < trunkLength + 0.001 and attachmentsCurrent > 0 do
        local centerX = baseX + axisX * distance
        local centerY = baseY + axisY * distance
        local centerZ = baseZ + axisZ * distance
        scanSteps = scanSteps + 1

        local removed = removeSplitShapeAttachments(
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
            thickness,
            transverseSize,
            transverseSize
        )

        if removed and entityExists(shape) then
            local _, _, _, _, attachmentsAfter = self:getContractorSplitShapeStats(shape)
            local removedAtStep = math.max(attachmentsCurrent - attachmentsAfter, 0)

            if removedAtStep > 0 then
                removedTotal = removedTotal + removedAtStep
                hitSteps = hitSteps + 1

                Logging.info(
                    "[LoggingContractor][AttachmentScanStep] shape=%d d=%.2f attachments=%d->%d removed=%d",
                    shape,
                    distance,
                    attachmentsCurrent,
                    attachmentsAfter,
                    removedAtStep
                )
            end

            attachmentsCurrent = attachmentsAfter
        end

        distance = distance + step
    end

    Logging.info(
        "[LoggingContractor][AttachmentScan] shape=%d length=%.2f step=%.2f thickness=%.2f transverse=%.2f steps=%d hitSteps=%d attachments=%d->%d removed=%d branchProfileLimit=%.2f",
        shape,
        trunkLength,
        step,
        thickness,
        transverseSize,
        scanSteps,
        hitSteps,
        attachmentsBefore,
        attachmentsCurrent,
        removedTotal,
        math.min(LoggingContractor.BRANCH_SCAN_LENGTH or 5.0, trunkLength)
    )

    return removedTotal
end


-- Перед поиском крупной ветви сначала полезно проходит весь ствол и снимает
-- attachments. Затем прежний BranchFix анализирует только первые 5 м с шагом
-- 0.25 м, то есть после этой отметки остаётся только операция очистки.
function LoggingContractor:findContractorBranchCandidate(
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
    self:scanContractorAttachmentsAlongTrunk(
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

    return previousFindContractorBranchCandidate(
        self,
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
end

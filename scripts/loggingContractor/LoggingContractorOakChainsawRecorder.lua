--[[
    Диагностика ручных резов дуба и берёзы бензопилой.

    Записывает реальные резы ChainsawUtil.cutSplitShape и успешные
    удаления attachments бензопилой на сервере.
    Каждая плоскость сохраняется в исходных координатах I3D: при движении
    отделённых частей базис переносится на новые split-shape после реза.
    Этот модуль ничего не режет самостоятельно.
]]

LoggingContractorOakChainsawRecorder = {}
local Recorder = LoggingContractorOakChainsawRecorder

Recorder.frames = {}
Recorder.sequence = 0
Recorder.activeCut = nil
Recorder.delimbSequence = 0
Recorder.activeManualChainsaw = nil
Recorder.diagnosticEnabled = false
Recorder.lastDiagnosticsMs = nil
Recorder.diagnostics = {
    updates = 0, serverDelimbUpdates = 0,
    nativeInContext = 0, nativeInContextHits = 0,
    nativeOutsideHits = 0, matched = 0, unmatched = 0
}


-- Периодически выводит агрегированную статистику хуков, пока подрядчик
-- ожидает ручной очистки дуба. Не создаёт строки на каждый игровой кадр.
function Recorder.logDiagnosticsIfDue()
    if not Recorder.diagnosticEnabled then
        return
    end
    local now = getTimeSec() * 1000
    if Recorder.lastDiagnosticsMs == nil then
        Recorder.lastDiagnosticsMs = now
        return
    end
    if now - Recorder.lastDiagnosticsMs < 10000 then
        return
    end
    local d = Recorder.diagnostics
    Logging.info(
        "[LoggingContractorSawDiagnostics] updates=%d serverDelimbUpdates=%d nativeInContext=%d nativeInContextHits=%d nativeOutsideHits=%d matched=%d unmatched=%d",
        d.updates, d.serverDelimbUpdates,
        d.nativeInContext, d.nativeInContextHits,
        d.nativeOutsideHits, d.matched, d.unmatched
    )
    for key in pairs(d) do
        d[key] = 0
    end
    Recorder.lastDiagnosticsMs = now
end


-- Регистрирует ствол дуба, поваленный подрядчиком: для него штатный хук
-- ручного спила не вызывается, но исходный I3D-базис уже сохранён системой.
function Recorder.trackContractorOak(shape, model, frame)
    if shape == nil or not entityExists(shape) or frame == nil
        or model == nil or not model:match("^oak_stage0[1-5]$") then
        return false
    end
    Recorder.frames[shape] = {
        model = model,
        origin = {frame.origin[1], frame.origin[2], frame.origin[3]},
        axisX = {frame.axisX[1], frame.axisX[2], frame.axisX[3]},
        axisY = {frame.axisY[1], frame.axisY[2], frame.axisY[3]},
        axisZ = {frame.axisZ[1], frame.axisZ[2], frame.axisZ[3]}
    }
    Recorder.diagnosticEnabled = true
    return true
end


-- Находит исходную модель дуба или берёзы по родительским группам I3D.
function Recorder.findTargetModel(shape)
    local node = getParent(shape)
    for _ = 1, 5 do
        if node == nil or node == 0 or not entityExists(node) then
            break
        end
        local name = getName(node)
        if name ~= nil and (name:match("^oak_stage0[1-5]$")
            or name:match("^betulaErmanii_stage0[1-4]$")) then
            return name
        end
        node = getParent(node)
    end
    return nil
end


-- Снимает мировой базис исходной модели или перенесённой на часть модели.
function Recorder.captureWorldFrame(shape, frame)
    local o = frame.origin
    local x, y, z = frame.axisX, frame.axisY, frame.axisZ
    local ox, oy, oz = localToWorld(shape, o[1], o[2], o[3])
    local xx, xy, xz = localDirectionToWorld(shape, x[1], x[2], x[3])
    local yx, yy, yz = localDirectionToWorld(shape, y[1], y[2], y[3])
    local zx, zy, zz = localDirectionToWorld(shape, z[1], z[2], z[3])
    return {
        origin = {ox, oy, oz},
        axisX = {xx, xy, xz},
        axisY = {yx, yy, yz},
        axisZ = {zx, zy, zz}
    }
end


-- Привязывает исходный I3D-базис к локальным осям нового split-shape.
function Recorder.attachWorldFrame(shape, model, worldFrame)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return
    end
    local o = worldFrame.origin
    local x, y, z = worldFrame.axisX, worldFrame.axisY, worldFrame.axisZ
    local ox, oy, oz = worldToLocal(shape, o[1], o[2], o[3])
    local xx, xy, xz = worldDirectionToLocal(shape, x[1], x[2], x[3])
    local yx, yy, yz = worldDirectionToLocal(shape, y[1], y[2], y[3])
    local zx, zy, zz = worldDirectionToLocal(shape, z[1], z[2], z[3])
    Recorder.frames[shape] = {
        model = model,
        origin = {ox, oy, oz},
        axisX = {xx, xy, xz},
        axisY = {yx, yy, yz},
        axisZ = {zx, zy, zz}
    }
end


-- Преобразует мировую точку или направление в систему исходной I3D-модели.
function Recorder.toModel(shape, frame, x, y, z, direction)
    local lx, ly, lz
    if direction then
        lx, ly, lz = worldDirectionToLocal(shape, x, y, z)
    else
        lx, ly, lz = worldToLocal(shape, x, y, z)
        lx = lx - frame.origin[1]
        ly = ly - frame.origin[2]
        lz = lz - frame.origin[3]
    end
    local ax, ay, az = frame.axisX, frame.axisY, frame.axisZ
    return lx * ax[1] + ly * ax[2] + lz * ax[3],
        lx * ay[1] + ly * ay[2] + lz * ay[3],
        lx * az[1] + ly * az[2] + lz * az[3]
end


-- Сохраняет дочернюю часть сразу после native splitShape callback.
function Recorder.trackCutResult(shape)
    local context = Recorder.activeCut
    if context == nil or shape == nil or not entityExists(shape) then
        return
    end
    Recorder.attachWorldFrame(shape, context.model, context.worldFrame)
    context.children[#context.children + 1] = tostring(shape)
end


-- Оборачивает штатный серверный рез и фиксирует плоскость и результат.
function Recorder.cutSplitShape(original, shape, x, y, z,
    nx, ny, nz, ax, ay, az, width, depth, farmId)
    if g_server == nil or shape == nil or not entityExists(shape) then
        return original(shape, x, y, z, nx, ny, nz,
            ax, ay, az, width, depth, farmId)
    end

    local frame = Recorder.frames[shape]
    if frame == nil then
        local model = Recorder.findTargetModel(shape)
        if model ~= nil then
            local identity = {
                origin = {0, 0, 0},
                axisX = {1, 0, 0},
                axisY = {0, 1, 0},
                axisZ = {0, 0, 1}
            }
            Recorder.attachWorldFrame(shape, model,
                Recorder.captureWorldFrame(shape, identity))
            frame = Recorder.frames[shape]
        end
    end
    if frame == nil then
        return original(shape, x, y, z, nx, ny, nz,
            ax, ay, az, width, depth, farmId)
    end

    local px, py, pz = Recorder.toModel(shape, frame, x, y, z, false)
    local mx, my, mz = Recorder.toModel(shape, frame, nx, ny, nz, true)
    local ux, uy, uz = Recorder.toModel(shape, frame, ax, ay, az, true)
    local rigidType = getRigidBodyType(shape)
    local sizeX, sizeY, sizeZ, _, attachmentCount = getSplitShapeStats(shape)
    local context = {
        model = frame.model,
        worldFrame = Recorder.captureWorldFrame(shape, frame),
        children = {}
    }
    local previous = Recorder.activeCut
    Recorder.activeCut = context
    local result = original(shape, x, y, z, nx, ny, nz,
        ax, ay, az, width, depth, farmId)
    Recorder.activeCut = previous

    Recorder.sequence = Recorder.sequence + 1
    Logging.info(
        "[LoggingContractorSawCut] seq=%d model=%s shape=%s rigid=%s sourceSize=(%.3f,%.3f,%.3f) sourceAttachments=%d modelPlane=(%.5f,%.5f,%.5f) modelNormal=(%.6f,%.6f,%.6f) modelAxis=(%.6f,%.6f,%.6f) worldPlane=(%.3f,%.3f,%.3f) worldNormal=(%.5f,%.5f,%.5f) worldAxis=(%.5f,%.5f,%.5f) dimensions=(%.3f,%.3f) children=%d childShapes=%s",
        Recorder.sequence, frame.model, tostring(shape), tostring(rigidType),
        sizeX or 0, sizeY or 0, sizeZ or 0, attachmentCount or 0,
        px, py, pz, mx, my, mz, ux, uy, uz,
        x, y, z, nx, ny, nz, ax, ay, az,
        width, depth, #context.children, table.concat(context.children, ",")
    )
    return result
end


-- Запоминает количество attachments у отслеживаемых частей дуба перед
-- штатным вызовом очистки. Удалённые split-shape не учитываются.
function Recorder.captureOakAttachments()
    local snapshot = {}
    for shape, frame in pairs(Recorder.frames) do
        if frame.model:match("^oak_stage0[1-5]$")
            and entityExists(shape) then
            local count = select(5, getSplitShapeStats(shape))
            if count ~= nil and count > 0 then
                snapshot[#snapshot + 1] = {
                    shape = shape, frame = frame, before = count
                }
            end
        end
    end
    return snapshot
end


-- Логирует только успешную ручную очистку бензопилой. Модель определяется
-- по реальному уменьшению attachments отслеживаемого split-shape, без
-- угадывания ближайшего дерева по расстоянию.
function Recorder.logManualAttachmentChanges(snapshot, x, y, z,
    nx, ny, nz, ax, ay, az, thickness, width, depth, source)
    local matched = false
    for _, entry in ipairs(snapshot) do
        if entityExists(entry.shape) then
            local after = select(5, getSplitShapeStats(entry.shape))
            if after ~= nil and after < entry.before then
                matched = true
                Recorder.diagnostics.matched = Recorder.diagnostics.matched + 1
                local px, py, pz = Recorder.toModel(
                    entry.shape, entry.frame, x, y, z, false)
                local mx, my, mz = Recorder.toModel(
                    entry.shape, entry.frame, nx, ny, nz, true)
                local ux, uy, uz = Recorder.toModel(
                    entry.shape, entry.frame, ax, ay, az, true)
                Recorder.delimbSequence = Recorder.delimbSequence + 1
                Logging.info(
                    "[LoggingContractorSawDelimb] seq=%d source=%s model=%s shape=%s removed=%d before=%d after=%d modelPlane=(%.5f,%.5f,%.5f) modelNormal=(%.6f,%.6f,%.6f) modelAxis=(%.6f,%.6f,%.6f) worldPlane=(%.3f,%.3f,%.3f) dimensions=(%.3f,%.3f,%.3f)",
                    Recorder.delimbSequence, source, entry.frame.model,
                    tostring(entry.shape), entry.before - after,
                    entry.before, after, px, py, pz, mx, my, mz,
                    ux, uy, uz, x, y, z, thickness, width, depth
                )
            end
        end
    end
    if not matched and #snapshot > 0 and source == "NATIVE" then
        Recorder.diagnostics.unmatched = Recorder.diagnostics.unmatched + 1
        Logging.info(
            "[LoggingContractorSawDelimbUnmatched] worldPlane=(%.3f,%.3f,%.3f) trackedOakShapes=%d native=true",
            x, y, z, #snapshot
        )
    end
    return matched
end


-- Сохраняет совместимость прежнего native-хука, но для реальной бензопилы
-- приоритетным источником служит измерение до/после onUpdate.
function Recorder.removeAttachments(original, x, y, z,
    nx, ny, nz, ax, ay, az, thickness, width, depth)
    if g_server == nil or Recorder.activeManualChainsaw == nil then
        local result = original(x, y, z, nx, ny, nz, ax, ay, az,
            thickness, width, depth)
        if Recorder.diagnosticEnabled and result == true then
            Recorder.diagnostics.nativeOutsideHits =
                Recorder.diagnostics.nativeOutsideHits + 1
        end
        return result
    end

    Recorder.diagnostics.nativeInContext =
        Recorder.diagnostics.nativeInContext + 1
    local snapshot = Recorder.captureOakAttachments()
    local result = original(x, y, z, nx, ny, nz, ax, ay, az,
        thickness, width, depth)
    if result == true then
        Recorder.diagnostics.nativeInContextHits =
            Recorder.diagnostics.nativeInContextHits + 1
        Recorder.logManualAttachmentChanges(snapshot, x, y, z,
            nx, ny, nz, ax, ay, az, thickness, width, depth, "NATIVE")
    end
    return result
end


-- Обозначает только время штатного обновления ручной бензопилы.
-- В FS25 1.24 HandToolChainsaw.onUpdate вызывает native очистку напрямую;
-- SpecializationUtil.raiseEvent обращается к обработчику через таблицу класса.
function Recorder.updateManualChainsaw(original, tool, ...)
    local spec = tool ~= nil and tool.spec_chainsaw or nil
    local serverDelimbing = g_server ~= nil and tool ~= nil
        and tool.isServer and spec ~= nil
        and spec.currentCutState == ChainsawCutState.DELIMBING
    if Recorder.diagnosticEnabled then
        Recorder.diagnostics.updates = Recorder.diagnostics.updates + 1
        if serverDelimbing then
            Recorder.diagnostics.serverDelimbUpdates =
                Recorder.diagnostics.serverDelimbUpdates + 1
        end
    end
    -- Снимок до штатного обновления позволяет увидеть native-удаления,
    -- даже если оригинальная Lua-функция использует другой global environment.
    local snapshot = serverDelimbing and Recorder.diagnosticEnabled
        and Recorder.captureOakAttachments() or nil
    local matchedBefore = Recorder.diagnostics.matched
    local previous = Recorder.activeManualChainsaw
    Recorder.activeManualChainsaw = tool
    local result = original(tool, ...)
    Recorder.activeManualChainsaw = previous
    if snapshot ~= nil and Recorder.diagnostics.matched == matchedBefore then
        local width = spec.maximumDelimbDiameter
        Recorder.logManualAttachmentChanges(
            snapshot,
            spec.lastDelimbPosX, spec.lastDelimbPosY, spec.lastDelimbPosZ,
            spec.lastDelimbNormalX, spec.lastDelimbNormalY, spec.lastDelimbNormalZ,
            spec.lastDelimbUpX, spec.lastDelimbUpY, spec.lastDelimbUpZ,
            0.7, width, width + HandToolChainsaw.SPLIT_PLANE_OFFSET_Z,
            "ON_UPDATE"
        )
    end
    return result
end


-- Устанавливает перехватчики после загрузки штатного ChainsawUtil.
function Recorder.install()
    if Recorder.installed then
        return
    end
    if ChainsawUtil == nil or ChainsawUtil.cutSplitShape == nil
        or ChainsawUtil.cutSplitShapeCallback == nil
        or ChainsawUtil.cutSplitShapeCallbackCutJoint == nil then
        Logging.warning("[LoggingContractorSaw] ChainsawUtil не загружен")
        return
    end

    local nativeCut = ChainsawUtil.cutSplitShape
    local nativeRemoveAttachments = findAndRemoveSplitShapeAttachments
    local nativeChainsawUpdate = HandToolChainsaw ~= nil
        and HandToolChainsaw.onUpdate or nil
    local nativeCallback = ChainsawUtil.cutSplitShapeCallback
    local nativeJointCallback = ChainsawUtil.cutSplitShapeCallbackCutJoint

    ChainsawUtil.cutSplitShape = function(...)
        return Recorder.cutSplitShape(nativeCut, ...)
    end
    if nativeChainsawUpdate ~= nil then
        HandToolChainsaw.onUpdate = function(tool, ...)
            return Recorder.updateManualChainsaw(nativeChainsawUpdate, tool, ...)
        end
    else
        Logging.warning("[LoggingContractorSaw] HandToolChainsaw.onUpdate недоступен")
    end
    if nativeRemoveAttachments ~= nil then
        findAndRemoveSplitShapeAttachments = function(...)
            return Recorder.removeAttachments(nativeRemoveAttachments, ...)
        end
    else
        Logging.warning("[LoggingContractorSaw] native очистка attachments недоступна")
    end
    ChainsawUtil.cutSplitShapeCallback = function(...)
        nativeCallback(...)
        Recorder.trackCutResult(select(2, ...))
    end
    ChainsawUtil.cutSplitShapeCallbackCutJoint = function(...)
        nativeJointCallback(...)
        Recorder.trackCutResult(select(2, ...))
    end
    Recorder.installed = true
    Logging.info(
        "[LoggingContractorSaw] Перехват резов и ручной очистки включён updateHook=%s nativeHook=%s",
        tostring(nativeChainsawUpdate ~= nil), tostring(nativeRemoveAttachments ~= nil)
    )
end


Recorder.install()

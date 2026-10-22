-- Поиск встроенных в карту подвижных радиоприёмников.
-- Не создаёт Placeable/Vehicle и не меняет физику или геометрию I3D.
TaigaRadioMapReceivers = {}
local TaigaRadioMapReceivers_mt = Class(TaigaRadioMapReceivers)

-- Создаёт реестр объектов и физических триггеров радиоприёмников.
function TaigaRadioMapReceivers.new(mission)
    local self = setmetatable({}, TaigaRadioMapReceivers_mt)
    self.mission = mission
    self.receivers = {}
    self.byTriggerNode = {}
    return self
end

-- Опознаёт именно модель PortableRadio по дочерним узлам.
-- Поиск не зависит от названий и координат трёх экземпляров на карте.
function TaigaRadioMapReceivers.findModelNodes(node)
    local bodyNode = nil
    local displayNode = nil
    local triggerNode = nil
    local buttonNode = nil

    for i = 0, getNumOfChildren(node) - 1 do
        local child = getChildAt(node, i)
        local name = getName(child)
        if name == "Body" then
            bodyNode = child
        elseif name == "Display" then
            displayNode = child
        elseif name == "trigger" then
            triggerNode = child
        elseif name == "Button01" then
            buttonNode = child
        end
    end

    if bodyNode ~= nil and displayNode ~= nil and triggerNode ~= nil and buttonNode ~= nil then
        return bodyNode, displayNode, triggerNode
    end
    return nil, nil, nil
end

-- Регистрирует экземпляр модели и клиентский триггер без привязки к
-- неподвижной позиции. Все узлы остаются детьми подвижного корня I3D.
function TaigaRadioMapReceivers:addReceiver(rootNode, bodyNode, displayNode, triggerNode)
    if self.byTriggerNode[triggerNode] ~= nil then
        return
    end

    local receiver = {
        rootNode = rootNode,
        soundNode = bodyNode,
        displayNode = displayNode,
        triggerNode = triggerNode,
        playerInside = false,
        triggerRegistered = false,
        enabled = false,
        trackIndex = 1,
        elapsedMs = 0,
        soundSource = nil,
        soundSample = nil,
        activatable = nil
    }
    self.receivers[#self.receivers + 1] = receiver
    self.byTriggerNode[triggerNode] = receiver
    if self.mission:getIsClient() then
        receiver.activatable = TaigaRadioMapReceiverActivatable.new(self, receiver)
    end

    if self.mission:getIsClient() then
        addTrigger(triggerNode, "onTriggerCallback", self)
        receiver.triggerRegistered = true
    end

    local x, y, z = getWorldTranslation(rootNode)
    local physicsType = getRigidBodyType(rootNode)
    Logging.info(
        "[TaigaRadio] Приёмник #%d: node=%s, x=%.2f y=%.2f z=%.2f, rigidBodyType=%s, trigger=%s",
        #self.receivers, getName(rootNode), x, y, z,
        tostring(physicsType), tostring(triggerNode)
    )

    -- В сетевой игре BaseMission:findDynamicObjects может убирать физику
    -- неподготовленных динамических узлов. На данном этапе только диагностируем.
    if self.mission.missionDynamicInfo ~= nil and self.mission.missionDynamicInfo.isMultiplayer
        and physicsType ~= RigidBodyType.DYNAMIC then
        Logging.warning(
            "[TaigaRadio] Приёмник #%d: физика не DYNAMIC в мультиплеере. Проверьте mpCreatePhysicsObject в map.i3d",
            #self.receivers
        )
    end
end

-- Находит все встроенные радиоприёмники в загруженной карте.
-- Обход выполняется однократно при загрузке I3D, а не в каждом кадре.
function TaigaRadioMapReceivers:discover(mapRootNode)
    if mapRootNode == nil or mapRootNode == 0 then
        Logging.warning("[TaigaRadio] Нет корневого узла карты для поиска приёмников")
        return
    end

    local stack = {mapRootNode}
    local inspected = 0

    while #stack > 0 do
        local node = stack[#stack]
        stack[#stack] = nil
        inspected = inspected + 1

        -- Опознаём экземпляр по составу дочерних узлов: GE мог
        -- переименовать корневой Shape при размещении на карте.
        local childCount = getNumOfChildren(node)
        local triggerNode = nil
        if childCount >= 4 then
            local bodyNode, displayNode
            bodyNode, displayNode, triggerNode = TaigaRadioMapReceivers.findModelNodes(node)
            if triggerNode ~= nil then
                self:addReceiver(node, bodyNode, displayNode, triggerNode)
            end
        end

        -- Внутренние детали найденной модели не обходятся повторно.
        -- Остальную сцену просматриваем без рекурсивных вызовов Lua.
        if triggerNode == nil then
            for i = 0, childCount - 1 do
                stack[#stack + 1] = getChildAt(node, i)
            end
        end
    end

    Logging.info(
        "[TaigaRadio] Поиск в map.i3d завершён: найдено приёмников %d, просмотрено узлов %d",
        #self.receivers, inspected
    )
    if #self.receivers ~= 3 then
        Logging.warning(
            "[TaigaRadio] Ожидалось 3 приёмника на карте, найдено %d. Проверьте вложенность Body/Display/trigger/Button01",
            #self.receivers
        )
    end
end

-- Создаёт позиционный источник непосредственно на подвижном Body приёмника.
-- Старый источник всегда удаляется до перехода к следующей композиции.
function TaigaRadioMapReceivers:playTrack(receiver)
    self:stopTrack(receiver)
    local radio = self.mission.taigaRadio
    local track = radio ~= nil and radio:getTrack(receiver.trackIndex) or nil
    if track == nil then
        return
    end

    local filename = track.speakerFilename or track.filename
    local source = createAudioSource("TaigaRadioReceiver", filename, 35, 3, 0.65, 1)
    if source == nil or source == 0 then
        Logging.warning("[TaigaRadio] Не удалось создать 3D-источник MP3: %s", filename)
        receiver.enabled = false
        return
    end

    receiver.soundSource = source
    link(receiver.soundNode, source)
    setTranslation(source, 0, 0, 0)
    setAudioSourceAutoPlay(source, false)
    receiver.soundSample = getAudioSourceSample(source)
    setSampleGroup(receiver.soundSample, AudioGroup.ENVIRONMENT)
    playSample(receiver.soundSample, 1, 0.65, 0, 0, 0)
    receiver.elapsedMs = 0
    Logging.info("[TaigaRadio] Приёмник: воспроизводится '%s'", track.title)
end

-- Останавливает воспроизведение и освобождает ресурс аудиодвижка.
function TaigaRadioMapReceivers:stopTrack(receiver)
    if receiver.soundSample ~= nil then
        stopSample(receiver.soundSample, 0, 0)
        receiver.soundSample = nil
    end
    if receiver.soundSource ~= nil then
        delete(receiver.soundSource)
        receiver.soundSource = nil
    end
end

-- Включает либо выключает независимое радио указанного экземпляра.
function TaigaRadioMapReceivers:toggle(receiver)
    local radio = self.mission.taigaRadio
    if radio == nil or #radio.tracks == 0 then
        return
    end

    receiver.enabled = not receiver.enabled
    if receiver.enabled then
        self:playTrack(receiver)
    else
        self:stopTrack(receiver)
    end
    if receiver.activatable ~= nil then
        receiver.activatable:updateText()
    end
end

-- Выбирает следующую либо предыдущую песню, не затрагивая транспортное радио.
function TaigaRadioMapReceivers:nextTrack(receiver, step)
    local radio = self.mission.taigaRadio
    if radio == nil or #radio.tracks == 0 then
        return
    end
    receiver.trackIndex = ((receiver.trackIndex - 1 + step) % #radio.tracks) + 1
    receiver.elapsedMs = 0
    if receiver.enabled then
        self:playTrack(receiver)
    end
    Logging.info("[TaigaRadio] Приёмник: выбран трек %d", receiver.trackIndex)
end

-- Переводит проигрыватель к следующему MP3 по длительности из tracks.xml.
function TaigaRadioMapReceivers:update(dt)
    local radio = self.mission.taigaRadio
    if radio == nil then
        return
    end
    for _, receiver in ipairs(self.receivers) do
        if receiver.enabled then
            local track = radio:getTrack(receiver.trackIndex)
            if track ~= nil then
                receiver.elapsedMs = receiver.elapsedMs + dt
                if receiver.elapsedMs >= track.durationMs then
                    self:nextTrack(receiver, 1)
                end
            end
        end
    end
end

-- Регистрирует действия F1 при входе локального игрока в подвижный триггер.
function TaigaRadioMapReceivers:onTriggerCallback(triggerId, otherId, onEnter, onLeave, onStay)
    local receiver = self.byTriggerNode[triggerId]
    local player = g_localPlayer
    if receiver == nil or receiver.activatable == nil or player == nil or otherId ~= player.rootNode then
        return
    end

    if onEnter and not receiver.playerInside then
        receiver.playerInside = true
        self.mission.activatableObjectsSystem:addActivatable(receiver.activatable)
        Logging.info("[TaigaRadio] Игрок вошёл в триггер приёмника %s", tostring(triggerId))
    elseif onLeave and receiver.playerInside then
        receiver.playerInside = false
        self.mission.activatableObjectsSystem:removeActivatable(receiver.activatable)
        Logging.info("[TaigaRadio] Игрок вышел из триггера приёмника %s", tostring(triggerId))
    end
end

-- Очищает триггеры, игровые действия и 3D-источники до удаления карты.
function TaigaRadioMapReceivers:delete()
    for _, receiver in ipairs(self.receivers) do
        if receiver.activatable ~= nil then
            self.mission.activatableObjectsSystem:removeActivatable(receiver.activatable)
        end
        if receiver.triggerRegistered then
            removeTrigger(receiver.triggerNode)
            receiver.triggerRegistered = false
        end
        self:stopTrack(receiver)
    end
    self.receivers = {}
    self.byTriggerNode = {}
end

TaigaRadioMapReceiverActivatable = {}
local TaigaRadioMapReceiverActivatable_mt = Class(TaigaRadioMapReceiverActivatable)

-- Создаёт действие включения радиоприёмника для игрового меню F1.
function TaigaRadioMapReceiverActivatable.new(system, receiver)
    local self = setmetatable({}, TaigaRadioMapReceiverActivatable_mt)
    self.system = system
    self.receiver = receiver
    self:updateText()
    return self
end

-- Подписывает основное действие в зависимости от состояния проигрывателя.
function TaigaRadioMapReceiverActivatable:updateText()
    self.activateText = self.receiver.enabled and "Выключить радиоприёмник" or "Включить радиоприёмник"
end

-- Радиоприёмник доступен только при наличии композиций и вне транспорта.
function TaigaRadioMapReceiverActivatable:getIsActivatable()
    local radio = self.system.mission.taigaRadio
    return radio ~= nil and #radio.tracks > 0 and g_localPlayer ~= nil
end

-- Выполняет основное действие F1 через стандартную систему активации.
function TaigaRadioMapReceiverActivatable:run()
    self.system:toggle(self.receiver)
end

-- Дополнительные действия выбора композиции регистрируются только в зоне приёмника.
function TaigaRadioMapReceiverActivatable:registerCustomInput(inputContext)
    local _, nextId = g_inputBinding:registerActionEvent(
        InputAction.TAIGA_RADIO_NEXT, self, self.onNextTrack, false, true, false, true
    )
    local _, previousId = g_inputBinding:registerActionEvent(
        InputAction.TAIGA_RADIO_PREVIOUS, self, self.onPreviousTrack, false, true, false, true
    )
    self.nextEventId = nextId
    self.previousEventId = previousId
    if nextId ~= nil then
        g_inputBinding:setActionEventText(nextId, "Следующая песня")
    end
    if previousId ~= nil then
        g_inputBinding:setActionEventText(previousId, "Предыдущая песня")
    end
end

-- Удаляет дополнительные привязки при выходе из триггера.
function TaigaRadioMapReceiverActivatable:removeCustomInput(inputContext)
    g_inputBinding:removeActionEventsByTarget(self)
    self.nextEventId = nil
    self.previousEventId = nil
end

-- Переключает композицию вперёд.
function TaigaRadioMapReceiverActivatable:onNextTrack()
    self.system:nextTrack(self.receiver, 1)
end

-- Переключает композицию назад.
function TaigaRadioMapReceiverActivatable:onPreviousTrack()
    self.system:nextTrack(self.receiver, -1)
end

-- Определяет расстояние по текущему положению подвижного триггера.
function TaigaRadioMapReceiverActivatable:getDistance(x, y, z)
    local tx, ty, tz = getWorldTranslation(self.receiver.triggerNode)
    return MathUtil.vector3Length(x - tx, y - ty, z - tz)
end

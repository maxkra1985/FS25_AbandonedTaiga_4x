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
    self.byRootNode = {}
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

-- Ищет дочерний узел I3D по имени, сохраняя независимость от nodeId.
function TaigaRadioMapReceivers.findChildByName(parentNode, name)
    if parentNode == nil then
        return nil
    end
    for i = 0, getNumOfChildren(parentNode) - 1 do
        local node = getChildAt(parentNode, i)
        if getName(node) == name then
            return node
        end
    end
    return nil
end

-- Собирает два набора цифровых разрядов и индикаторов экрана.
-- Иерархия соответствует исходной модели PortableRadio/Radio.i3d.
function TaigaRadioMapReceivers.findDisplayNodes(displayNode)
    local trackGroup = TaigaRadioMapReceivers.findChildByName(displayNode, "track")
    local volumeGroup = TaigaRadioMapReceivers.findChildByName(displayNode, "volume")
    if trackGroup == nil or volumeGroup == nil then
        return nil
    end

    local display = {
        trackGroup = trackGroup,
        volumeGroup = volumeGroup,
        trackDigits = {},
        volumeDigits = {}
    }
    for i = 0, 1 do
        display.trackDigits[i + 1] =
            TaigaRadioMapReceivers.findChildByName(trackGroup, "track_id_" .. i)
        display.volumeDigits[i + 1] =
            TaigaRadioMapReceivers.findChildByName(volumeGroup, "volume_id_" .. i)
    end

    if display.trackDigits[1] == nil or display.trackDigits[2] == nil
        or display.volumeDigits[1] == nil or display.volumeDigits[2] == nil then
        return nil
    end

    return display
end

-- Выводит двузначное число на готовых цифровых мешах через параметр index.
-- Индикаторы TRACK и VOLUME уже находятся в соответствующих группах I3D.
function TaigaRadioMapReceivers.setDisplayNumber(digits, value)
    local number = math.min(99, math.max(0, math.floor(value)))
    local tens = math.floor(number / 10)
    local ones = number % 10
    setShaderParameter(digits[1], "index", tens, 0, 0, 0, false)
    setShaderParameter(digits[2], "index", ones, 0, 0, 0, false)
end

-- Показывает номер трека, громкость либо полностью выключает экран.
function TaigaRadioMapReceivers:setDisplayMode(receiver, mode)
    receiver.displayMode = mode
    local display = receiver.display
    if display == nil then
        return
    end
    setVisibility(display.trackGroup, mode == "track")
    setVisibility(display.volumeGroup, mode == "volume")

    if mode == "track" then
        TaigaRadioMapReceivers.setDisplayNumber(display.trackDigits, receiver.trackIndex)
    elseif mode == "volume" then
        local percent = math.floor(receiver.volume * 100 + 0.5)
        TaigaRadioMapReceivers.setDisplayNumber(display.volumeDigits, percent)
    end
end

-- Применяет громкость к текущему 3D-источнику без его перезагрузки.
-- На три секунды показывает громкость на штатном дисплее модели.
function TaigaRadioMapReceivers:adjustVolume(receiver, delta)
    local nextVolume = math.max(0, math.min(1, math.floor(receiver.volume * 10 + delta * 10 + 0.5) / 10))
    if nextVolume == receiver.volume then
        return
    end

    local action = delta > 0 and TaigaRadioMapReceiverEvent.ACTION_VOLUME_UP
        or TaigaRadioMapReceiverEvent.ACTION_VOLUME_DOWN
    self:requestAction(receiver, action)
end

-- Регистрирует экземпляр модели и клиентский триггер без привязки к
-- неподвижной позиции. Все узлы остаются детьми подвижного корня I3D.
function TaigaRadioMapReceivers:addReceiver(rootNode, bodyNode, displayNode, triggerNode)
    if self.byTriggerNode[triggerNode] ~= nil then
        return
    end

    local receiver = {
        id = #self.receivers + 1,
        rootNode = rootNode,
        soundNode = bodyNode,
        displayNode = displayNode,
        triggerNode = triggerNode,
        playerInside = false,
        triggerRegistered = false,
        enabled = false,
        trackIndex = 1,
        elapsedMs = 0,
        volume = 0.7,
        volumeDisplayTimer = 0,
        displayMode = "none",
        display = TaigaRadioMapReceivers.findDisplayNodes(displayNode),
        soundSource = nil,
        soundSample = nil,
        activatable = nil
    }
    self.receivers[#self.receivers + 1] = receiver
    self.byTriggerNode[triggerNode] = receiver
    self.byRootNode[rootNode] = receiver

    -- При загрузке скрываем одновременно отображаемые TRACK и VOLUME.
    if self.mission:getIsClient() then
        if receiver.display == nil then
            Logging.warning("[TaigaRadio] Приёмник #%d: отсутствуют узлы цифрового дисплея", #self.receivers)
        else
            self:setDisplayMode(receiver, "none")
        end
    end

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
-- playSample принимает начальное смещение; оно важно для позднего подключения.
function TaigaRadioMapReceivers:playTrack(receiver, elapsedMs)
    self:stopTrack(receiver)
    local radio = self.mission.taigaRadio
    local track = radio ~= nil and radio:getTrack(receiver.trackIndex) or nil
    if track == nil then
        return
    end

    local filename = track.speakerFilename or track.filename
    local source = createAudioSource("TaigaRadioReceiver", filename, 35, 3, receiver.volume, 1)
    if source == nil or source == 0 then
        Logging.warning("[TaigaRadio] Не удалось создать 3D-источник MP3: %s", filename)
        receiver.enabled = false
        self:setDisplayMode(receiver, "none")
        return
    end

    receiver.soundSource = source
    link(receiver.soundNode, source)
    setTranslation(source, 0, 0, 0)
    setAudioSourceAutoPlay(source, false)
    receiver.soundSample = getAudioSourceSample(source)
    setSampleGroup(receiver.soundSample, AudioGroup.ENVIRONMENT)
    local offset = math.max(0, elapsedMs or 0)
    -- playSample получает смещение в миллисекундах.
    playSample(receiver.soundSample, 1, receiver.volume, offset, 0, 0)
    receiver.elapsedMs = offset
    receiver.volumeDisplayTimer = 0
    self:setDisplayMode(receiver, "track")
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

-- Применяет проверенное состояние сервера на локальном клиенте.
-- При изменении только громкости не перезапускает воспроизводимую композицию.
function TaigaRadioMapReceivers:applyNetworkState(receiverId, enabled, trackIndex, volume, elapsedMs)
    local receiver = self.receivers[receiverId]
    local radio = self.mission.taigaRadio
    if receiver == nil or radio == nil or trackIndex < 1
        or trackIndex > #radio.tracks or volume < 0 or volume > 1 then
        Logging.warning("[TaigaRadio] Получено некорректное состояние приёмника %s", tostring(receiverId))
        return
    end

    local playbackChanged = receiver.enabled ~= enabled or receiver.trackIndex ~= trackIndex
    local volumeChanged = receiver.volume ~= volume
    receiver.enabled = enabled
    receiver.trackIndex = trackIndex
    receiver.volume = volume
    receiver.elapsedMs = math.max(0, math.min(elapsedMs or 0, radio.tracks[trackIndex].durationMs))

    if self.mission:getIsClient() then
        if playbackChanged then
            if enabled then
                self:playTrack(receiver, receiver.elapsedMs)
            else
                self:stopTrack(receiver)
                receiver.volumeDisplayTimer = 0
                self:setDisplayMode(receiver, "none")
            end
        elseif enabled and receiver.soundSample == nil then
            -- Отправленный после входа снимок состояния может прийти,
            -- когда локальный звук ещё не был создан.
            self:playTrack(receiver, receiver.elapsedMs)
        elseif volumeChanged and receiver.soundSample ~= nil then
            setSampleVolume(receiver.soundSample, volume)
        end

        if volumeChanged and enabled and not playbackChanged then
            receiver.volumeDisplayTimer = 3000
            self:setDisplayMode(receiver, "volume")
        end
        if receiver.activatable ~= nil then
            receiver.activatable:updateText()
        end
    end
end

-- Принимает действие только на сервере и распространяет его результат.
function TaigaRadioMapReceivers:applyServerAction(receiverId, action)
    if not self.mission:getIsServer() then
        return
    end

    local receiver = self.receivers[receiverId]
    local radio = self.mission.taigaRadio
    if receiver == nil or radio == nil or #radio.tracks == 0 then
        return
    end

    local event = TaigaRadioMapReceiverEvent
    local enabled, trackIndex, volume = receiver.enabled, receiver.trackIndex, receiver.volume
    if action == event.ACTION_TOGGLE then
        enabled = not enabled
    elseif action == event.ACTION_NEXT or action == event.ACTION_PREVIOUS then
        -- Только сервер выбирает случайный трек и рассылает его индекс клиентам.
        -- При нескольких композициях текущая не выбирается повторно.
        trackIndex = TaigaRadio.getRandomTrackIndex(#radio.tracks, trackIndex)
    elseif action == event.ACTION_VOLUME_UP then
        volume = math.min(1, math.floor(volume * 10 + 1.5) / 10)
    elseif action == event.ACTION_VOLUME_DOWN then
        volume = math.max(0, math.floor(volume * 10 - 0.5) / 10)
    else
        return
    end

    if receiver.enabled == enabled and receiver.trackIndex == trackIndex and receiver.volume == volume then
        return
    end

    local elapsed = trackIndex ~= receiver.trackIndex and 0 or receiver.elapsedMs
    if enabled and not receiver.enabled then
        elapsed = 0
    end
    self:applyNetworkState(receiverId, enabled, trackIndex, volume, elapsed)
    TaigaRadioMapReceiverEvent.broadcastState(receiver)
end

-- Проверяет, что сетевой запрос пришёл от игрока рядом с данным приёмником.
function TaigaRadioMapReceivers:handleRemoteAction(connection, receiverId, action)
    local receiver = self.receivers[receiverId]
    local player = self.mission:getPlayerByConnection(connection)
    if receiver == nil or player == nil or player.rootNode == nil then
        return
    end

    local px, py, pz = getWorldTranslation(player.rootNode)
    local tx, ty, tz = getWorldTranslation(receiver.triggerNode)
    local dx, dy, dz = px - tx, py - ty, pz - tz

    -- 6 м ограничивают дистанционные запросы; штатный I3D-триггер
    -- дополнительно контролирует появление действий на клиенте.
    if dx * dx + dy * dy + dz * dz > 36 then
        return
    end
    self:applyServerAction(receiverId, action)
end

-- Пересылает поздно подключившемуся игроку состояние всех трёх объектов.
function TaigaRadioMapReceivers:sendSnapshot(connection)
    if not self.mission:getIsServer() or connection == nil then
        return
    end
    for _, receiver in ipairs(self.receivers) do
        connection:sendEvent(TaigaRadioMapReceiverEvent.newState(receiver))
    end
end

-- Отправляет команду серверу; в одиночной игре хост исполняет её напрямую.
function TaigaRadioMapReceivers:requestAction(receiver, action)
    if self.mission:getIsServer() then
        self:applyServerAction(receiver.id, action)
    else
        TaigaRadioMapReceiverEvent.sendAction(receiver.id, action)
    end
end

-- Включает либо выключает независимое радио указанного экземпляра.
function TaigaRadioMapReceivers:toggle(receiver)
    local radio = self.mission.taigaRadio
    if radio == nil or #radio.tracks == 0 then
        return
    end

    self:requestAction(receiver, TaigaRadioMapReceiverEvent.ACTION_TOGGLE)
end

-- Выбирает случайную другую песню, не затрагивая транспортное радио.
function TaigaRadioMapReceivers:nextTrack(receiver, step)
    local radio = self.mission.taigaRadio
    if radio == nil or #radio.tracks == 0 then
        return
    end
    local action = step > 0 and TaigaRadioMapReceiverEvent.ACTION_NEXT
        or TaigaRadioMapReceiverEvent.ACTION_PREVIOUS
    self:requestAction(receiver, action)
end

-- Переводит проигрыватель к следующему MP3 по длительности из tracks.xml.
function TaigaRadioMapReceivers:update(dt)
    local radio = self.mission.taigaRadio
    if radio == nil then
        return
    end
    for _, receiver in ipairs(self.receivers) do
        if receiver.enabled then
            if receiver.volumeDisplayTimer > 0 then
                receiver.volumeDisplayTimer = receiver.volumeDisplayTimer - dt
                if receiver.volumeDisplayTimer <= 0 then
                    receiver.volumeDisplayTimer = 0
                    self:setDisplayMode(receiver, "track")
                end
            end

            local track = radio:getTrack(receiver.trackIndex)
            if track ~= nil then
                receiver.elapsedMs = receiver.elapsedMs + dt
                -- Смену песни принимает только сервер: иначе каждый
                -- клиент переключал бы её независимо и расходился по времени.
                if self.mission:getIsServer() and receiver.elapsedMs >= track.durationMs then
                    self:applyServerAction(receiver.id, TaigaRadioMapReceiverEvent.ACTION_NEXT)
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
    self.byRootNode = {}
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
    -- Основное действие Activatable может не выводиться отдельной строкой
    -- при зарегистрированных пользовательских действиях. Обновляем свою кнопку.
    if self.toggleEventId ~= nil then
        g_inputBinding:setActionEventText(self.toggleEventId, self.activateText)
    end
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
    -- Явная кнопка включения: не полагаемся на скрытое стандартное действие.
    local _, toggleId = g_inputBinding:registerActionEvent(
        InputAction.TAIGA_RADIO_TOGGLE, self, self.onToggle, false, true, false, true
    )
    self.toggleEventId = toggleId
    if toggleId ~= nil then
        g_inputBinding:setActionEventTextPriority(toggleId, GS_PRIO_VERY_HIGH)
        g_inputBinding:setActionEventTextVisibility(toggleId, true)
        g_inputBinding:setActionEventText(toggleId, self.activateText)
    end

    local _, nextId = g_inputBinding:registerActionEvent(
        InputAction.TAIGA_RADIO_NEXT, self, self.onNextTrack, false, true, false, true
    )
    local _, previousId = g_inputBinding:registerActionEvent(
        InputAction.TAIGA_RADIO_PREVIOUS, self, self.onPreviousTrack, false, true, false, true
    )
    self.nextEventId = nextId
    self.previousEventId = previousId

    local _, volumeUpId = g_inputBinding:registerActionEvent(
        InputAction.TAIGA_RADIO_VOLUME_UP, self, self.onVolumeUp, false, true, false, true
    )
    local _, volumeDownId = g_inputBinding:registerActionEvent(
        InputAction.TAIGA_RADIO_VOLUME_DOWN, self, self.onVolumeDown, false, true, false, true
    )
    self.volumeUpEventId = volumeUpId
    self.volumeDownEventId = volumeDownId

    if nextId ~= nil then
        g_inputBinding:setActionEventText(nextId, "Следующая песня")
    end
    if previousId ~= nil then
        g_inputBinding:setActionEventText(previousId, "Предыдущая песня")
    end
    if volumeUpId ~= nil then
        g_inputBinding:setActionEventText(volumeUpId, "Громче")
    end
    if volumeDownId ~= nil then
        g_inputBinding:setActionEventText(volumeDownId, "Тише")
    end
end

-- Удаляет дополнительные привязки при выходе из триггера.
function TaigaRadioMapReceiverActivatable:removeCustomInput(inputContext)
    g_inputBinding:removeActionEventsByTarget(self)
    self.toggleEventId = nil
    self.nextEventId = nil
    self.previousEventId = nil
    self.volumeUpEventId = nil
    self.volumeDownEventId = nil
end

-- Включает или выключает выбранный приёмник, используя серверную команду.
function TaigaRadioMapReceiverActivatable:onToggle()
    self.system:toggle(self.receiver)
end

-- Переключает композицию вперёд.
function TaigaRadioMapReceiverActivatable:onNextTrack()
    self.system:nextTrack(self.receiver, 1)
end

-- Переключает композицию назад.
function TaigaRadioMapReceiverActivatable:onPreviousTrack()
    self.system:nextTrack(self.receiver, -1)
end

-- Увеличивает громкость приёмника на один шаг.
function TaigaRadioMapReceiverActivatable:onVolumeUp()
    self.system:adjustVolume(self.receiver, 0.1)
end

-- Уменьшает громкость приёмника на один шаг.
function TaigaRadioMapReceiverActivatable:onVolumeDown()
    self.system:adjustVolume(self.receiver, -0.1)
end

-- Определяет расстояние по текущему положению подвижного триггера.
function TaigaRadioMapReceiverActivatable:getDistance(x, y, z)
    local tx, ty, tz = getWorldTranslation(self.receiver.triggerNode)
    return MathUtil.vector3Length(x - tx, y - ty, z - tz)
end

-- Стационарный радиоприёмник для I3D-placeable карты.
-- Звук локализован в точке динамика, состояние управляется сервером.
PlaceableTaigaRadioReceiver = {}
PlaceableTaigaRadioReceiver.SPEC_NAME = string.format("%s.taigaRadioReceiver", g_currentModName)
PlaceableTaigaRadioReceiver.SPEC_TABLE = "spec_" .. PlaceableTaigaRadioReceiver.SPEC_NAME

-- Не зависит от производственных и складских специализаций.
function PlaceableTaigaRadioReceiver.prerequisitesPresent(specializations)
    return true
end

-- Регистрирует точки привязки динамика, триггера и звуковой радиус.
function PlaceableTaigaRadioReceiver.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TaigaRadioReceiver")
    local key = basePath .. ".taigaRadioReceiver"
    schema:register(XMLValueType.NODE_INDEX, key .. "#triggerNode", "Триггер взаимодействия с радиоприёмником")
    schema:register(XMLValueType.NODE_INDEX, key .. "#soundNode", "Источник позиционного звука")
    schema:register(XMLValueType.FLOAT, key .. "#outerRadius", "Дальность слышимости, метры", 24)
    schema:register(XMLValueType.FLOAT, key .. "#innerRadius", "Радиус максимальной громкости, метры", 3)
    schema:register(XMLValueType.FLOAT, key .. "#volume", "Громкость 0..1", 0.65)
    schema:setXMLSpecializationType()
end

-- Регистрирует функции, доступные экземпляру placeable и сетевому событию.
function PlaceableTaigaRadioReceiver.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType, "taigaRadioReceiverTriggerCallback", PlaceableTaigaRadioReceiver.triggerCallback)
    SpecializationUtil.registerFunction(placeableType, "taigaRadioReceiverSetState", PlaceableTaigaRadioReceiver.setState)
    SpecializationUtil.registerFunction(placeableType, "taigaRadioReceiverPlayTrack", PlaceableTaigaRadioReceiver.playTrack)
end

-- Подключает жизненный цикл и первоначальную передачу состояния клиентам.
function PlaceableTaigaRadioReceiver.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableTaigaRadioReceiver)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", PlaceableTaigaRadioReceiver)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", PlaceableTaigaRadioReceiver)
    SpecializationUtil.registerEventListener(placeableType, "onWriteStream", PlaceableTaigaRadioReceiver)
    SpecializationUtil.registerEventListener(placeableType, "onReadStream", PlaceableTaigaRadioReceiver)
    SpecializationUtil.registerEventListener(placeableType, "onUpdate", PlaceableTaigaRadioReceiver)
end

-- Находит следующую композицию, у которой есть OGG для 3D-источника.
function PlaceableTaigaRadioReceiver.getNextTrack(radio, currentIndex)
    if radio == nil or #radio.tracks == 0 then
        return nil
    end
    for step = 1, #radio.tracks do
        local index = ((currentIndex + step - 1) % #radio.tracks) + 1
        if radio.tracks[index].speakerFilename ~= nil then
            return index
        end
    end
    return nil
end

-- Читает XML-настройки и готовит локальную точку взаимодействия.
function PlaceableTaigaRadioReceiver:onLoad(savegame)
    local key = "placeable.taigaRadioReceiver"
    local spec = self[PlaceableTaigaRadioReceiver.SPEC_TABLE]
    spec.triggerNode = self.xmlFile:getValue(key .. "#triggerNode", nil, self.components, self.i3dMappings)
    spec.soundNode = self.xmlFile:getValue(key .. "#soundNode", nil, self.components, self.i3dMappings)
    spec.outerRadius = math.max(1, self.xmlFile:getValue(key .. "#outerRadius", 24))
    spec.innerRadius = math.min(spec.outerRadius, math.max(0, self.xmlFile:getValue(key .. "#innerRadius", 3)))
    spec.volume = math.clamp(self.xmlFile:getValue(key .. "#volume", 0.65), 0, 1)
    spec.enabled = false
    spec.trackIndex = 0
    spec.elapsedMs = 0
    spec.source = nil
    spec.sample = nil
    spec.activatable = nil

    if self.isClient and spec.triggerNode ~= nil then
        spec.activatable = TaigaRadioReceiverActivatable.new(self)
    end
end

-- Подключает физический триггер только на клиенте.
function PlaceableTaigaRadioReceiver:onFinalizePlacement()
    local spec = self[PlaceableTaigaRadioReceiver.SPEC_TABLE]
    if self.isClient and spec.triggerNode ~= nil then
        addTrigger(spec.triggerNode, "taigaRadioReceiverTriggerCallback", self)
    end
end

-- Обрабатывает вход/выход локального игрока из зоны радиоприёмника.
function PlaceableTaigaRadioReceiver:triggerCallback(triggerId, otherId, onEnter, onLeave, onStay)
    local spec = self[PlaceableTaigaRadioReceiver.SPEC_TABLE]
    local player = g_localPlayer
    if spec == nil or spec.activatable == nil or player == nil or otherId ~= player.rootNode then
        return
    end
    if onEnter then
        g_currentMission.activatableObjectsSystem:addActivatable(spec.activatable)
    elseif onLeave then
        g_currentMission.activatableObjectsSystem:removeActivatable(spec.activatable)
    end
end

-- Запускает 3D-композицию из общего каталога, начиная с заданной позиции.
function PlaceableTaigaRadioReceiver:playTrack()
    local spec = self[PlaceableTaigaRadioReceiver.SPEC_TABLE]
    if spec.source ~= nil then
        stopSample(spec.sample, 0, 0)
        delete(spec.source)
        spec.source = nil
        spec.sample = nil
    end
    if not self.isClient or not spec.enabled or spec.soundNode == nil then
        return
    end
    local radio = g_currentMission ~= nil and g_currentMission.taigaRadio or nil
    local track = radio ~= nil and radio:getTrack(spec.trackIndex) or nil
    if track == nil or track.speakerFilename == nil then
        return
    end
    spec.source = createAudioSource(
        "TaigaRadioReceiver", track.speakerFilename,
        spec.outerRadius, spec.innerRadius, spec.volume, 1
    )
    if spec.source ~= nil and spec.source ~= 0 then
        link(spec.soundNode, spec.source)
        spec.sample = getAudioSourceSample(spec.source)
        setSampleGroup(spec.sample, AudioGroup.ENVIRONMENT)
        setAudioSourceAutoPlay(spec.source, false)
        playSample(spec.sample, 1, spec.volume, spec.elapsedMs, 0, 0)
    else
        spec.source = nil
        Logging.warning("[TaigaRadio] Не создан позиционный источник %s", track.speakerFilename)
    end
end

-- Применяет подтверждённое состояние; сервер рассылает изменение клиентам.
function PlaceableTaigaRadioReceiver:setState(enabled, trackIndex, elapsedMs, broadcast)
    local spec = self[PlaceableTaigaRadioReceiver.SPEC_TABLE]
    if spec == nil then
        return
    end
    local radio = g_currentMission ~= nil and g_currentMission.taigaRadio or nil
    local track = radio ~= nil and radio:getTrack(trackIndex) or nil
    if enabled and (track == nil or track.speakerFilename == nil) then
        return
    end

    local changed = spec.enabled ~= enabled or spec.trackIndex ~= trackIndex
    spec.enabled = enabled
    spec.trackIndex = trackIndex
    spec.elapsedMs = math.max(elapsedMs or 0, 0)

    if changed then
        self:taigaRadioReceiverPlayTrack()
    end
    if spec.activatable ~= nil then
        spec.activatable:updateText()
    end
    if broadcast and self.isServer then
        TaigaRadioReceiverEvent.broadcast(self, spec.enabled, spec.trackIndex, spec.elapsedMs)
    end
end

-- На сервере переключает композиции; у каждого приёмника независимый эфир.
function PlaceableTaigaRadioReceiver:onUpdate(dt)
    if not self.isServer then
        return
    end
    local spec = self[PlaceableTaigaRadioReceiver.SPEC_TABLE]
    if spec == nil or not spec.enabled then
        return
    end
    local radio = g_currentMission ~= nil and g_currentMission.taigaRadio or nil
    local track = radio ~= nil and radio:getTrack(spec.trackIndex) or nil
    if track == nil then
        return
    end
    spec.elapsedMs = spec.elapsedMs + dt
    if spec.elapsedMs >= track.durationMs then
        local nextIndex = PlaceableTaigaRadioReceiver.getNextTrack(radio, spec.trackIndex)
        if nextIndex ~= nil then
            self:taigaRadioReceiverSetState(true, nextIndex, 0, true)
        end
    end
end

-- Отправляет состояние новому сетевому клиенту.
function PlaceableTaigaRadioReceiver:onWriteStream(streamId, connection)
    local spec = self[PlaceableTaigaRadioReceiver.SPEC_TABLE]
    streamWriteBool(streamId, spec.enabled)
    streamWriteUInt16(streamId, spec.trackIndex)
    streamWriteFloat32(streamId, spec.elapsedMs)
end

-- Восстанавливает состояние у подключившегося клиента.
function PlaceableTaigaRadioReceiver:onReadStream(streamId, connection)
    local enabled = streamReadBool(streamId)
    local trackIndex = streamReadUInt16(streamId)
    local elapsedMs = streamReadFloat32(streamId)
    self:taigaRadioReceiverSetState(enabled, trackIndex, elapsedMs, false)
end

-- Удаляет триггер, Activatable и аудиоисточник.
function PlaceableTaigaRadioReceiver:onDelete()
    local spec = self[PlaceableTaigaRadioReceiver.SPEC_TABLE]
    if spec == nil then
        return
    end
    if self.isClient and spec.triggerNode ~= nil then
        removeTrigger(spec.triggerNode)
    end
    if spec.activatable ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(spec.activatable)
        spec.activatable = nil
    end
    if spec.sample ~= nil then
        stopSample(spec.sample, 0, 0)
    end
    if spec.source ~= nil then
        delete(spec.source)
        spec.source = nil
        spec.sample = nil
    end
end

TaigaRadioReceiverActivatable = {}
local TaigaRadioReceiverActivatable_mt = Class(TaigaRadioReceiverActivatable)

-- Создаёт кнопку взаимодействия F1 рядом с приёмником.
function TaigaRadioReceiverActivatable.new(placeable)
    local self = setmetatable({}, TaigaRadioReceiverActivatable_mt)
    self.placeable = placeable
    self:updateText()
    return self
end

-- Обновляет подпись действия на основании фактического состояния приёмника.
function TaigaRadioReceiverActivatable:updateText()
    local spec = self.placeable[PlaceableTaigaRadioReceiver.SPEC_TABLE]
    self.activateText = spec ~= nil and spec.enabled and "Выключить радио" or "Включить радио"
end

-- Предлагает взаимодействие только для приёмника с доступными композициями.
function TaigaRadioReceiverActivatable:getIsActivatable()
    local radio = g_currentMission ~= nil and g_currentMission.taigaRadio or nil
    return radio ~= nil and radio:getSpeakerTrackIndex() ~= nil
end

-- Передаёт нажатие серверу, который синхронизирует результат.
function TaigaRadioReceiverActivatable:run()
    TaigaRadioReceiverEvent.sendRequest(self.placeable)
end

-- Измеряет расстояние до физического триггера.
function TaigaRadioReceiverActivatable:getDistance(x, y, z)
    local spec = self.placeable[PlaceableTaigaRadioReceiver.SPEC_TABLE]
    if spec == nil or spec.triggerNode == nil then
        return math.huge
    end
    local tx, ty, tz = getWorldTranslation(spec.triggerNode)
    return MathUtil.vector3Length(tx - x, ty - y, tz - z)
end

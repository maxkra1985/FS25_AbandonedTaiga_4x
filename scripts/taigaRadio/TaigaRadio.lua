-- Радио карты: виртуальная станция в штатном управлении транспортным радио FS25.
-- Аудиофайлы не копируются в профиль игрока, штатные станции не изменяются.
TaigaRadio = {}
local TaigaRadio_mt = Class(TaigaRadio)
TaigaRadio.CONFIG_FILENAME = "sounds/taigaRadio/tracks.xml"
TaigaRadio.STATION_NAME = "Радио Заброшенная тайга"

-- Загружает каталог композиций. Длительность задаётся явно, потому что API
-- streamed sample не предоставляет надёжного признака окончания MP3-трека.
function TaigaRadio.new(baseDirectory)
    local self = setmetatable({}, TaigaRadio_mt)
    self.baseDirectory = baseDirectory
    self.tracks = {}
    self.trackIndex = 1
    self.elapsedMs = 0
    self.stream = nil
    self.streamPaused = false
    self.vehicleSelected = false
    self.vehiclePlaying = false
    self.player = nil
    self.original = {}

    local filename = Utils.getFilename(TaigaRadio.CONFIG_FILENAME, baseDirectory)
    if not fileExists(filename) then
        Logging.warning("[TaigaRadio] Не найден %s", filename)
        return self
    end

    local xmlFile = XMLFile.load("taigaRadio", filename)
    if xmlFile == nil then
        Logging.warning("[TaigaRadio] Не удалось прочитать список композиций: %s", filename)
        return self
    end

    xmlFile:iterate("taigaRadio.track", function(_, key)
        -- У XML нет зарегистрированной схемы, поэтому используем типовые
        -- getString/getInt вместо getValue, требующего XMLSchema.
        local path = xmlFile:getString(key .. "#file")
        local title = xmlFile:getString(key .. "#title")
        local durationMs = xmlFile:getInt(key .. "#durationMs")
        local speakerPath = xmlFile:getString(key .. "#speakerFile")

        if path == nil or title == nil or durationMs == nil or durationMs <= 0 then
            Logging.warning("[TaigaRadio] Пропущена запись %s: требуются file, title и durationMs", key)
            return
        end

        local fullPath = Utils.getFilename(path, baseDirectory)
        if not fileExists(fullPath) then
            Logging.warning("[TaigaRadio] Не найден аудиофайл %s", fullPath)
            return
        end

        local speakerFile = speakerPath ~= nil and Utils.getFilename(speakerPath, baseDirectory) or nil
        if speakerFile ~= nil and not fileExists(speakerFile) then
            Logging.warning("[TaigaRadio] Не найден файл для радиоприёмника: %s", speakerFile)
            speakerFile = nil
        end

        table.insert(self.tracks, {
            title = title,
            filename = fullPath,
            speakerFilename = speakerFile,
            durationMs = durationMs
        })
    end)
    xmlFile:delete()

    Logging.info("[TaigaRadio] Композиций: %d", #self.tracks)
    return self
end

-- Выбирает случайную композицию, исключая немедленный повтор текущей.
-- Возвращает прежний индекс при наличии только одного трека.
function TaigaRadio.getRandomTrackIndex(trackCount, currentIndex)
    if trackCount <= 1 then
        return trackCount == 1 and 1 or nil
    end

    local nextIndex = math.random(trackCount - 1)
    if nextIndex >= currentIndex then
        nextIndex = nextIndex + 1
    end
    return nextIndex
end

-- Возвращает дорожку для стационарного радиоприёмника.
function TaigaRadio:getTrack(index)
    return self.tracks[index]
end

-- Возвращает первый файл, который можно воспроизвести позиционным источником.
function TaigaRadio:getSpeakerTrackIndex()
    for i, track in ipairs(self.tracks) do
        if track.speakerFilename ~= nil then
            return i
        end
    end
    return nil
end

-- Отображает метаданные виртуального канала в штатном HUD радио.
function TaigaRadio:notify()
    local player = self.player
    if player == nil then
        return
    end
    local track = self.tracks[self.trackIndex]
    local title = track ~= nil and track.title or ""
    player.currentChannelName = TaigaRadio.STATION_NAME
    player.currentItemName = title
    player:onChange(TaigaRadio.STATION_NAME, title, false)
end

-- Освобождает предыдущий поток вместе с загруженным аудиофайлом.
-- stopStreamedSample только прекращает звучание: повторный loadStreamedSample
-- для того же объекта вызывает ошибку "Stream sample already loaded".
function TaigaRadio:releaseStream()
    if self.stream ~= nil then
        stopStreamedSample(self.stream)
        delete(self.stream)
        self.stream = nil
    end
    self.streamPaused = false
    self.vehiclePlaying = false
    self.lastVolume = nil
end

-- Читает штатную настройку громкости радио, применяемую к виртуальному потоку.
-- При отсутствии значения оставляет исходную громкость.
function TaigaRadio:getConfiguredVolume()
    local volume = g_gameSettings ~= nil and g_gameSettings:getValue("radioVolume") or nil
    if type(volume) ~= "number" then
        return 1
    end
    return math.max(0, math.min(1, volume))
end

-- Обновляет громкость без перезапуска композиции при изменении настроек.
function TaigaRadio:updateVolume()
    if self.stream == nil then
        return
    end
    local volume = self:getConfiguredVolume()
    if self.lastVolume ~= volume then
        setStreamedSampleVolume(self.stream, volume)
        self.lastVolume = volume
    end
end

-- Запускает текущий MP3 через потоковый плеер движка в AudioGroup.RADIO.
function TaigaRadio:startTrack()
    local track = self.tracks[self.trackIndex]
    if track == nil then
        return false
    end
    -- Для каждого нового трека создаём свежий источник. Повторная загрузка
    -- в ранее использованный streamed sample запрещена самим движком.
    self:releaseStream()
    self.stream = createStreamedSample("TaigaRadio", false)
    if self.stream == nil or self.stream == 0 then
        self.stream = nil
        Logging.warning("[TaigaRadio] createStreamedSample не создал источник")
        return false
    end
    setStreamedSampleGroup(self.stream, AudioGroup.RADIO)
    self.lastVolume = nil
    self:updateVolume()

    -- В штатном коде GIANTS результат loadStreamedSample не проверяется:
    -- реализация движка не гарантирует возвращаемое значение boolean.
    loadStreamedSample(self.stream, track.filename)
    playStreamedSample(self.stream, 1)
    self.elapsedMs = 0
    self.streamPaused = false
    self.vehiclePlaying = true
    if self.player ~= nil then
        self.player.isPlaying = true
    end
    self:notify()
    return true
end

-- Возобновляет либо запускает музыку текущей виртуальной станции.
function TaigaRadio:play()
    if self.stream ~= nil and self.streamPaused then
        resumeStreamedSample(self.stream)
        self.streamPaused = false
        self.vehiclePlaying = true
        self.player.isPlaying = true
        self:notify()
        return true
    end
    if self.vehiclePlaying then
        return true
    end
    return self:startTrack()
end

-- Приостанавливает поток, сохраняя позицию трека для повторного включения.
function TaigaRadio:pause()
    if self.stream ~= nil and self.vehiclePlaying then
        pauseStreamedSample(self.stream)
        self.streamPaused = true
    end
    self.vehiclePlaying = false
    if self.player ~= nil then
        self.player.isPlaying = false
    end
    return true
end

-- Случайно выбирает другую композицию при NEXT/PREVIOUS ITEM.
function TaigaRadio:selectTrack(step)
    if #self.tracks == 0 then
        return false
    end
    self.trackIndex = TaigaRadio.getRandomTrackIndex(#self.tracks, self.trackIndex)
    if self.vehiclePlaying then
        return self:startTrack()
    end
    -- При смене трека на паузе тоже освобождаем уже загруженный файл:
    -- повторное включение должно открыть выбранный MP3 с начала.
    self:releaseStream()
    self.elapsedMs = 0
    self:notify()
    return true
end

-- Переключает между реальными каналами SoundPlayer и одним виртуальным каналом.
function TaigaRadio:switchChannel(step)
    local player = self.player
    if player == nil or not isSoundPlayerLoaded(player.soundPlayerId) then
        return false
    end
    player:initializeSoundPlayer()
    local nativeCount = getNumSoundPlayerChannels(player.soundPlayerId)
    if nativeCount < 1 then
        return false
    end

    local oldChannel = self.vehicleSelected and nativeCount or player.currentChannel
    local nextChannel = (oldChannel + step + nativeCount + 1) % (nativeCount + 1)

    if nextChannel == nativeCount then
        if not self.vehicleSelected then
            self.original.pause(player)
            self.vehicleSelected = true
        end
        player.currentChannel = nativeCount
        return self:play()
    end

    if self.vehicleSelected then
        self:pause()
        self.vehicleSelected = false
        player.currentChannel = nextChannel
        player:startChannel()
        return true
    end
    return self.original[step > 0 and "nextChannel" or "previousChannel"](player)
end

-- Обновляет позицию потокового трека, не вызывая штатный update с
-- несуществующим в нативном списке номером канала.
function TaigaRadio:update(dt)
    if not self.vehicleSelected then
        return
    end
    self:updateVolume()
    if not self.vehiclePlaying then
        return
    end
    local track = self.tracks[self.trackIndex]
    if track ~= nil then
        self.elapsedMs = self.elapsedMs + dt
        if self.elapsedMs >= track.durationMs then
            self:selectTrack(1)
        end
    end
end

-- Подменяет методы только конкретного g_soundPlayer на время работы карты.
-- Кнопки стандартного радио вызывают именно методы этого объекта.
function TaigaRadio:install()
    if #self.tracks == 0 or self.player ~= nil or g_soundPlayer == nil then
        return
    end
    local player = g_soundPlayer
    self.player = player
    local original = self.original
    local methods = {
        "nextChannel", "previousChannel", "nextItem", "previousItem",
        "play", "pause", "update", "getChannelName", "getItemName"
    }
    for _, method in ipairs(methods) do
        original[method] = player[method]
    end

    local radio = self
    player.nextChannel = function(p)
        return radio:switchChannel(1)
    end
    player.previousChannel = function(p)
        return radio:switchChannel(-1)
    end
    player.nextItem = function(p)
        if radio.vehicleSelected then
            return radio:selectTrack(1)
        end
        return original.nextItem(p)
    end
    player.previousItem = function(p)
        if radio.vehicleSelected then
            return radio:selectTrack(-1)
        end
        return original.previousItem(p)
    end
    player.play = function(p)
        if radio.vehicleSelected then
            return radio:play()
        end
        return original.play(p)
    end
    player.pause = function(p)
        if radio.vehicleSelected then
            return radio:pause()
        end
        return original.pause(p)
    end
    player.update = function(p, dt)
        if radio.vehicleSelected then
            radio:update(dt)
        else
            original.update(p, dt)
        end
    end
    player.getChannelName = function(p)
        return radio.vehicleSelected and TaigaRadio.STATION_NAME or original.getChannelName(p)
    end
    player.getItemName = function(p)
        return radio.vehicleSelected and radio.tracks[radio.trackIndex].title or original.getItemName(p)
    end

    -- При каждой загрузке карты виртуальная станция выбрана первой.
    -- Воспроизведение запускает штатное управление радио; дальнейший выбор
    -- игрока сохраняется при выключении и повторном включении.
    self.vehicleSelected = true

    Logging.info("[TaigaRadio] Виртуальная станция подключена к транспортному радио")
end

-- Восстанавливает методы штатного радио и освобождает аудиопоток.
function TaigaRadio:delete()
    if self.player ~= nil then
        if self.vehicleSelected then
            self:pause()
            self.vehicleSelected = false
            self.player.currentChannel = 0
        end
        for method, func in pairs(self.original) do
            self.player[method] = func
        end
        self.player = nil
    end
    self:releaseStream()
end

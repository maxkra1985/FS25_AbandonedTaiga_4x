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
        triggerRegistered = false
    }
    self.receivers[#self.receivers + 1] = receiver
    self.byTriggerNode[triggerNode] = receiver

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

-- Регистрирует вход/выход локального игрока. На этом этапе события
-- только диагностируются; управление музыкой добавим отдельным этапом.
function TaigaRadioMapReceivers:onTriggerCallback(triggerId, otherId, onEnter, onLeave, onStay)
    local receiver = self.byTriggerNode[triggerId]
    local player = g_localPlayer
    if receiver == nil or player == nil or otherId ~= player.rootNode then
        return
    end

    if onEnter and not receiver.playerInside then
        receiver.playerInside = true
        Logging.info("[TaigaRadio] Игрок вошёл в триггер приёмника %s", tostring(triggerId))
    elseif onLeave and receiver.playerInside then
        receiver.playerInside = false
        Logging.info("[TaigaRadio] Игрок вышел из триггера приёмника %s", tostring(triggerId))
    end
end

-- Снимает триггеры до удаления геометрии карты. Геометрия нам не принадлежит.
function TaigaRadioMapReceivers:delete()
    for _, receiver in ipairs(self.receivers) do
        if receiver.triggerRegistered then
            removeTrigger(receiver.triggerNode)
            receiver.triggerRegistered = false
        end
    end
    self.receivers = {}
    self.byTriggerNode = {}
end

-- Универсальная передача тюков/паллет из ObjectStorage:
-- производство, кормушка и подстилка. Работает исключительно на сервере.
PlaceableTransferFromStorage = {}
PlaceableTransferFromStorage.EPSILON = 0.001

-- Полное имя таблицы пользовательской специализации; одинаково для карты и дополнения.
PlaceableTransferFromStorage.SPEC_NAME = string.format("%s.transferFromStorage", g_currentModName)
PlaceableTransferFromStorage.SPEC_TABLE = string.format("spec_%s", PlaceableTransferFromStorage.SPEC_NAME)
PlaceableTransferFromStorage.VERSION = "0.1.2.0"

Logging.info(
    "[TransferFromStorage] SCRIPT LOADED: version=%s mod=%s specTable=%s",
    PlaceableTransferFromStorage.VERSION,
    tostring(g_currentModName),
    PlaceableTransferFromStorage.SPEC_TABLE
)

-- Для специализации обязателен виртуальный склад.
function PlaceableTransferFromStorage.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(PlaceableObjectStorage, specializations)
end

-- Регистрирует собственные XML-настройки внутри objectStorage.
function PlaceableTransferFromStorage.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TransferFromStorage")
    local path = basePath .. ".objectStorage.transferFromStorage"
    schema:register(XMLValueType.NODE_INDEX, path .. "#playerTrigger",
        "Триггер ручной передачи со склада")
    schema:register(XMLValueType.BOOL, path .. "#debugTrigger",
        "Диагностика физического взаимодействия с триггером", false)
    schema:register(XMLValueType.STRING, path .. ".destination(?)#fillType",
        "Тип содержимого тюка или поддона")
    schema:register(XMLValueType.STRING, path .. ".destination(?)#target",
        "Приёмник: productionStorage, husbandryFood, husbandryStraw")
    schema:register(XMLValueType.STRING, path .. ".destination(?)#actionText",
        "Надпись на кнопке")
    schema:setXMLSpecializationType()
end

-- Регистрирует точки взаимодействия движка и методы сервера.
function PlaceableTransferFromStorage.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType,
        "onTransferFromStoragePlayerTrigger", PlaceableTransferFromStorage.onPlayerTrigger)
    SpecializationUtil.registerFunction(placeableType,
        "transferFromStorageExecute", PlaceableTransferFromStorage.execute)
    SpecializationUtil.registerFunction(placeableType,
        "transferFromStorageGetCapacity", PlaceableTransferFromStorage.getCapacity)
    SpecializationUtil.registerFunction(placeableType,
        "transferFromStorageGetEntries", PlaceableTransferFromStorage.getEntries)
    SpecializationUtil.registerFunction(placeableType,
        "transferFromStorageIsAvailable", PlaceableTransferFromStorage.isAvailable)
end

-- Присоединяет жизненный цикл специализации к Placeable.
function PlaceableTransferFromStorage.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableTransferFromStorage)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", PlaceableTransferFromStorage)
    SpecializationUtil.registerEventListener(placeableType, "onUpdate", PlaceableTransferFromStorage)
end

-- Возвращает содержимое виртуального тюка или поддона.
-- Ферментирующиеся физические тюки не расходуются до завершения ферментации.
function PlaceableTransferFromStorage.getStoredObjectData(object)
    if object == nil then return nil end
    if object.baleObject ~= nil then
        local bale = object.baleObject
        if bale.isFermenting then return nil end
        return true, bale:getFillType(), bale:getFillLevel()
    end
    if object.baleAttributes ~= nil then
        return true, object.baleAttributes.fillType, object.baleAttributes.fillLevel
    end
    if object.palletAttributes ~= nil then
        return false, object.palletAttributes.fillType, object.palletAttributes.fillLevel
    end
    return nil
end

-- Проверяет, что строительство завершено и приёмник действительно существует.
function PlaceableTransferFromStorage:isAvailable()
    local constructible = self.spec_constructible
    if constructible ~= nil and self.getNumFinishedConstructibleStates ~= nil then
        local finished, total = self:getNumFinishedConstructibleStates()
        if finished ~= nil and total ~= nil and finished < total then
            return false
        end
    end
    return self[PlaceableTransferFromStorage.SPEC_TABLE] ~= nil
        and self[PlaceableTransferFromStorage.SPEC_TABLE].triggerNode ~= nil
        and self.spec_objectStorage ~= nil
end

-- Возвращает свободную вместимость конкретного приёмника.
function PlaceableTransferFromStorage:getCapacity(fillType, target)
    if not self:transferFromStorageIsAvailable() then return 0 end
    if target == "productionStorage" then
        local p = self.spec_productionPoint ~= nil
            and self.spec_productionPoint.productionPoint or nil
        local storage = p ~= nil and p.storage or nil
        if storage == nil or not storage:getIsFillTypeSupported(fillType) then
            return 0
        end
        return storage:getFreeCapacity(fillType)
    elseif target == "husbandryFood" then
        if self.spec_husbandryFood == nil then return 0 end
        return self:getFreeFoodCapacity(fillType)
    elseif target == "husbandryStraw" then
        if self.spec_husbandryStraw == nil or fillType ~= FillType.STRAW then
            return 0
        end
        -- Солома физически хранится в Storage самого коровника.
        local storage = self.spec_husbandry ~= nil
            and self.spec_husbandry.storage or nil
        if storage == nil or not storage:getIsFillTypeSupported(fillType) then
            return 0
        end
        return storage:getFreeCapacity(fillType)
    end
    return 0
end

-- Формирует строки диалога из штатных групп ObjectStorage.
-- Группы с разными размерами и объёмами остаются отдельными строками.
function PlaceableTransferFromStorage:getEntries()
    local entries = {}
    local spec = self[PlaceableTransferFromStorage.SPEC_TABLE]
    local storageSpec = self.spec_objectStorage
    if spec == nil or storageSpec == nil then return entries end
    for _, group in ipairs(storageSpec.objectInfos or {}) do
        local object = group.objects ~= nil and group.objects[1] or nil
        local isBale, fillType, amount =
            PlaceableTransferFromStorage.getStoredObjectData(object)
        local route = fillType ~= nil and spec.routes[fillType] or nil
        if isBale ~= nil and route ~= nil and amount ~= nil
            and amount > PlaceableTransferFromStorage.EPSILON then
            local desc = g_fillTypeManager:getFillTypeByIndex(fillType)
            local label = desc ~= nil and desc.title or tostring(fillType)
            local kind = isBale and "Тюк" or "Поддон"
            table.insert(entries, {
                isBale = isBale, fillType = fillType, amount = amount,
                count = group.numObjects, target = route.target,
                actionText = route.actionText,
                title = string.format("%s: %s, %.0f л  (%d шт.)",
                    kind, label, amount, group.numObjects),
                fits = self:transferFromStorageGetCapacity(fillType, route.target)
                    + PlaceableTransferFromStorage.EPSILON >= amount
            })
        end
    end
    table.sort(entries, function(a, b)
        if a.fillType == b.fillType then
            if a.amount == b.amount then return a.isBale and not b.isBale end
            return a.amount < b.amount
        end
        return a.fillType < b.fillType
    end)
    return entries
end

-- Выполняет серверную проверку и зачисление материала в получатель.
-- Предварительная проверка вместимости запрещает частичную передачу.
function PlaceableTransferFromStorage:execute(connection, isBale, fillType, amount)
    if not self.isServer or not self:transferFromStorageIsAvailable() then
        return false, "Передача пока недоступна."
    end

    local userId = g_currentMission.userManager ~= nil
        and g_currentMission.userManager:getUserIdByConnection(connection) or nil
    local farm = userId ~= nil and g_farmManager:getFarmByUserId(userId) or nil
    if farm == nil or farm.farmId ~= self:getOwnerFarmId() then
        return false, "Недостаточно прав для передачи."
    end

    local spec = self.spec_objectStorage
    if spec.objectSpawn.isActive
        or (self.productionWarehouseSupply ~= nil and self.productionWarehouseSupply.busy) then
        return false, "Склад занят другой операцией."
    end

    local route = self[PlaceableTransferFromStorage.SPEC_TABLE].routes[fillType]
    if route == nil or amount == nil or amount <= 0 then
        return false, "Материал не разрешён для передачи."
    end

    -- Сервер самостоятельно находит объект; клиент не присылает индекс склада.
    local selected, selectedIndex, storedAmount
    for index, object in ipairs(spec.storedObjects) do
        local candidateBale, candidateFillType, candidateAmount =
            PlaceableTransferFromStorage.getStoredObjectData(object)
        if candidateBale == isBale and candidateFillType == fillType
            and candidateAmount ~= nil and math.abs(candidateAmount - amount) < 0.1 then
            selected = object
            selectedIndex = index
            storedAmount = candidateAmount
            break
        end
    end
    if selected == nil then
        return false, "Тюк или поддон уже отсутствует на складе."
    end

    if self:transferFromStorageGetCapacity(fillType, route.target)
        + PlaceableTransferFromStorage.EPSILON < storedAmount then
        return false, "Не помещается."
    end

    -- Успешной считается только полная передача содержимого.
    -- До удаления источника можно вернуть получателю прежнее значение.
    local inserted = 0
    local targetStorage = nil
    local previous = nil
    if route.target == "productionStorage" then
        targetStorage = self.spec_productionPoint.productionPoint.storage
        previous = targetStorage:getFillLevel(fillType)
        targetStorage:setFillLevel(previous + storedAmount, fillType)
        inserted = targetStorage:getFillLevel(fillType) - previous
    elseif route.target == "husbandryFood" then
        inserted = self:addFood(farm.farmId, storedAmount, fillType, nil, nil, nil)
    elseif route.target == "husbandryStraw" then
        targetStorage = self.spec_husbandry.storage
        previous = targetStorage:getFillLevel(fillType)
        targetStorage:setFillLevel(previous + storedAmount, fillType)
        inserted = targetStorage:getFillLevel(fillType) - previous
    end

    if math.abs(inserted - storedAmount) >= PlaceableTransferFromStorage.EPSILON then
        -- Если получатель принял не весь объект, откатываем зачисление.
        -- Исходный виртуальный объект остаётся в складском списке.
        if targetStorage ~= nil and previous ~= nil then
            targetStorage:setFillLevel(previous, fillType)
        elseif route.target == "husbandryFood" and inserted > 0 then
            self:removeFood(inserted, fillType)
        end
        Logging.warning(
            "[TransferFromStorage] Transfer mismatch: %s requested %.2f accepted %.2f; rolled back",
            tostring(fillType), storedAmount, inserted
        )
        return false, "Получатель не принял полный объём. Передача отменена."
    end

    if targetStorage ~= nil and targetStorage.isServer
        and targetStorage.storageDirtyFlag ~= nil then
        targetStorage:raiseDirtyFlags(targetStorage.storageDirtyFlag)
    end

    table.remove(spec.storedObjects, selectedIndex)
    spec.numStoredObjects = #spec.storedObjects
    selected:delete()
    g_farmManager:updateFarmStats(self:getOwnerFarmId(),
        isBale and "storedBales" or "storedPallets", -1)
    self:setObjectStorageObjectInfosDirty()

    Logging.info(
        "[TransferFromStorage] farm=%d kind=%s fillType=%s amount=%.2f target=%s",
        farm.farmId, isBale and "bale" or "pallet",
        tostring(fillType), storedAmount, route.target
    )
    return true, "Передан один объект: " .. string.format("%.0f л", storedAmount)
end

-- Создаёт триггер и загружает маршруты материалов из XML объекта.
function PlaceableTransferFromStorage:onLoad(savegame)
    local spec = self[PlaceableTransferFromStorage.SPEC_TABLE]
    if spec == nil then
        Logging.warning(
            "[TransferFromStorage] onLoad FAILED: specTable=%s file=%s",
            PlaceableTransferFromStorage.SPEC_TABLE,
            tostring(self.configFileName)
        )
        return
    end

    spec.routes = {}
    spec.triggerNode = nil
    spec.debugTrigger = false
    spec.debugElapsed = 0
    spec.debugNear = false
    spec.debugRawEvents = 0
    spec.debugStaySeen = false
    -- Один и тот же тип Placeable может использоваться без секции передачи.
    local xmlKey = "placeable.objectStorage.transferFromStorage"
    if not self.xmlFile:hasProperty(xmlKey) then
        return
    end

    spec.triggerNode = self.xmlFile:getValue(xmlKey .. "#playerTrigger",
        nil, self.components, self.i3dMappings)
    spec.debugTrigger = self.xmlFile:getValue(xmlKey .. "#debugTrigger", false)
    local routeCount = 0
    self.xmlFile:iterate(xmlKey .. ".destination", function(_, key)
        local name = self.xmlFile:getValue(key .. "#fillType")
        local target = self.xmlFile:getValue(key .. "#target")
        local actionText = self.xmlFile:getValue(key .. "#actionText", "Передать")
        local fillType = name ~= nil and g_fillTypeManager:getFillTypeIndexByName(name) or nil
        if fillType ~= nil and (target == "productionStorage"
            or target == "husbandryFood" or target == "husbandryStraw") then
            spec.routes[fillType] = {target = target, actionText = actionText}
            routeCount = routeCount + 1
        else
            Logging.xmlWarning(self.xmlFile,
                "TransferFromStorage: invalid destination fillType='%s' target='%s'",
                tostring(name), tostring(target))
        end
    end)
    spec.activatable = TransferFromStorageActivatable.new(self)
    if spec.triggerNode ~= nil then
        addTrigger(spec.triggerNode, "onTransferFromStoragePlayerTrigger", self)
        Logging.info(
            "[TransferFromStorage] onLoad OK: file=%s trigger=%s routes=%d isServer=%s debug=%s",
            tostring(self.configFileName), tostring(spec.triggerNode),
            routeCount, tostring(self.isServer), tostring(spec.debugTrigger)
        )
    else
        Logging.xmlWarning(self.xmlFile, "TransferFromStorage trigger not found")
        Logging.warning(
            "[TransferFromStorage] onLoad FAILED: trigger=nil routes=%d file=%s",
            routeCount, tostring(self.configFileName)
        )
    end
end

-- Отключает действие и освобождает триггер при удалении постройки.
function PlaceableTransferFromStorage:onDelete()
    local spec = self[PlaceableTransferFromStorage.SPEC_TABLE]
    if spec == nil then return end
    if spec.activatable ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(spec.activatable)
    end
    if spec.triggerNode ~= nil then removeTrigger(spec.triggerNode) end
end

-- Записывает близость игрока к узлу, даже когда физика не вызывает
-- onEnter. Только для объектов с debugTrigger=true, с редким интервалом.
function PlaceableTransferFromStorage:onUpdate(dt)
    local spec = self[PlaceableTransferFromStorage.SPEC_TABLE]
    if spec == nil or not spec.debugTrigger
        or spec.triggerNode == nil or not entityExists(spec.triggerNode)
        or g_localPlayer == nil or g_localPlayer.rootNode == nil then
        return
    end

    spec.debugElapsed = (spec.debugElapsed or 0) + dt
    if spec.debugElapsed < 2000 then return end
    spec.debugElapsed = 0

    local px, py, pz = getWorldTranslation(g_localPlayer.rootNode)
    local tx, ty, tz = getWorldTranslation(spec.triggerNode)
    local dx, dy, dz = px - tx, py - ty, pz - tz
    local horizontalDistance = math.sqrt(dx * dx + dz * dz)
    local near = horizontalDistance < 7 and math.abs(dy) < 5

    -- При приближении показываем относительную позицию, при удалении
    -- подтверждаем выход из области диагностики.
    if near then
        Logging.info(
            "[TransferFromStorageDebug] NEAR file=%s trigger=%s horizontal=%.2fm delta=(%.2f, %.2f, %.2f) playerRoot=%s rawEvents=%d",
            tostring(self.configFileName), tostring(spec.triggerNode),
            horizontalDistance, dx, dy, dz,
            tostring(g_localPlayer.rootNode), spec.debugRawEvents or 0
        )
    elseif spec.debugNear then
        Logging.info(
            "[TransferFromStorageDebug] FAR file=%s trigger=%s horizontal=%.2fm",
            tostring(self.configFileName), tostring(spec.triggerNode),
            horizontalDistance
        )
    end
    spec.debugNear = near
end


-- При срабатывании физики сначала регистрирует необработанное событие,
-- затем применяет штатный фильтр rootNode локального игрока.
function PlaceableTransferFromStorage:onPlayerTrigger(triggerId, otherId, onEnter, onLeave, onStay)
    local spec = self[PlaceableTransferFromStorage.SPEC_TABLE]
    if spec == nil or spec.activatable == nil then return end

    if spec.debugTrigger then
        if (onEnter or onLeave) and (spec.debugRawEvents or 0) < 30 then
            spec.debugRawEvents = (spec.debugRawEvents or 0) + 1
            Logging.info(
                "[TransferFromStorageDebug] RAW trigger=%s otherId=%s playerRoot=%s enter=%s leave=%s matchesPlayer=%s",
                tostring(triggerId), tostring(otherId),
                tostring(g_localPlayer ~= nil and g_localPlayer.rootNode or nil),
                tostring(onEnter), tostring(onLeave),
                tostring(g_localPlayer ~= nil and otherId == g_localPlayer.rootNode)
            )
        elseif onStay and not spec.debugStaySeen
            and g_localPlayer ~= nil and otherId == g_localPlayer.rootNode then
            spec.debugStaySeen = true
            Logging.info(
                "[TransferFromStorageDebug] RAW STAY player in trigger=%s without new enter",
                tostring(triggerId)
            )
        end
    end

    if g_localPlayer == nil or otherId ~= g_localPlayer.rootNode then return end
    if onEnter then
        -- Логируем условия активации один раз при входе: это позволяет
        -- отличить отсутствие события физического триггера от запрета доступа.
        local isAvailable = self:transferFromStorageIsAvailable()
        local canAccess = g_currentMission.accessHandler:canPlayerAccess(self)
        local isInVehicle = g_localPlayer:getIsInVehicle()
        Logging.info(
            "[TransferFromStorage] Player entered trigger=%s file=%s available=%s canAccess=%s inVehicle=%s ownerFarm=%s",
            tostring(triggerId), tostring(self.configFileName),
            tostring(isAvailable), tostring(canAccess),
            tostring(isInVehicle), tostring(self:getOwnerFarmId())
        )
        g_currentMission.activatableObjectsSystem:addActivatable(spec.activatable)
    elseif onLeave then
        Logging.info(
            "[TransferFromStorage] Player left trigger=%s file=%s",
            tostring(triggerId), tostring(self.configFileName)
        )
        g_currentMission.activatableObjectsSystem:removeActivatable(spec.activatable)
    end
end

-- Клавиша взаимодействия в зоне триггера.
TransferFromStorageActivatable = {}
local TransferFromStorageActivatable_mt = Class(TransferFromStorageActivatable)

function TransferFromStorageActivatable.new(placeable)
    local self = setmetatable({}, TransferFromStorageActivatable_mt)
    self.placeable = placeable
    self.activateText = "Передать материалы со склада"
    return self
end

-- Действие доступно только пешему игроку с правами на склад.
function TransferFromStorageActivatable:getIsActivatable()
    return self.placeable:transferFromStorageIsAvailable()
        and g_localPlayer ~= nil and not g_localPlayer:getIsInVehicle()
        and g_currentMission.accessHandler:canPlayerAccess(self.placeable)
end

-- Открывает собственный диалог с доступными материалами.
function TransferFromStorageActivatable:run()
    TransferFromStorageDialog.show(self.placeable)
end

-- Возвращает расстояние до триггера для выбора приоритетного действия.
-- Использует полное имя пользовательской специализации GIANTS; при удалении
-- постройки или отсутствии узла действие перестаёт участвовать в выборе.
function TransferFromStorageActivatable:getDistance(x, y, z)
    local placeable = self.placeable
    local spec = placeable ~= nil
        and placeable[PlaceableTransferFromStorage.SPEC_TABLE] or nil
    local node = spec ~= nil and spec.triggerNode or nil

    if node == nil or not entityExists(node) then
        return math.huge
    end

    local tx, ty, tz = getWorldTranslation(node)
    return MathUtil.vector3Length(x - tx, y - ty, z - tz)
end

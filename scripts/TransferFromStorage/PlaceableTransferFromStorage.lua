-- Универсальная передача тюков/паллет из ObjectStorage:
-- производство, кормушка и подстилка. Работает исключительно на сервере.
PlaceableTransferFromStorage = {}
PlaceableTransferFromStorage.EPSILON = 0.001

-- Для специализации обязателен виртуальный склад.
function PlaceableTransferFromStorage.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(PlaceableObjectStorage, specializations)
end

-- Регистрирует собственные XML-настройки внутри objectStorage.
function PlaceableTransferFromStorage.registerXMLPaths(schema, basePath)
    local path = basePath .. ".objectStorage.transferFromStorage"
    schema:register(XMLValueType.NODE_INDEX, path .. "#playerTrigger",
        "Триггер ручной передачи со склада")
    schema:register(XMLValueType.STRING, path .. ".destination(?)#fillType",
        "Тип содержимого тюка или поддона")
    schema:register(XMLValueType.STRING, path .. ".destination(?)#target",
        "Приёмник: productionStorage, husbandryFood, husbandryStraw")
    schema:register(XMLValueType.STRING, path .. ".destination(?)#actionText",
        "Надпись на кнопке")
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
    return self.spec_transferFromStorage ~= nil
        and self.spec_transferFromStorage.triggerNode ~= nil
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
    local spec = self.spec_transferFromStorage
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

    local route = self.spec_transferFromStorage.routes[fillType]
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
    local spec = self.spec_transferFromStorage
    local xmlKey = "placeable.objectStorage.transferFromStorage"
    spec.routes = {}
    spec.triggerNode = self.xmlFile:getValue(xmlKey .. "#playerTrigger",
        nil, self.components, self.i3dMappings)
    self.xmlFile:iterate(xmlKey .. ".destination", function(_, key)
        local name = self.xmlFile:getValue(key .. "#fillType")
        local target = self.xmlFile:getValue(key .. "#target")
        local actionText = self.xmlFile:getValue(key .. "#actionText", "Передать")
        local fillType = name ~= nil and g_fillTypeManager:getFillTypeIndexByName(name) or nil
        if fillType ~= nil and (target == "productionStorage"
            or target == "husbandryFood" or target == "husbandryStraw") then
            spec.routes[fillType] = {target = target, actionText = actionText}
        else
            Logging.xmlWarning(self.xmlFile,
                "TransferFromStorage: invalid destination fillType='%s' target='%s'",
                tostring(name), tostring(target))
        end
    end)
    spec.activatable = TransferFromStorageActivatable.new(self)
    if spec.triggerNode ~= nil then
        addTrigger(spec.triggerNode, "onTransferFromStoragePlayerTrigger", self)
    else
        Logging.xmlWarning(self.xmlFile, "TransferFromStorage trigger not found")
    end
end

-- Отключает действие и освобождает триггер при удалении постройки.
function PlaceableTransferFromStorage:onDelete()
    local spec = self.spec_transferFromStorage
    if spec.activatable ~= nil and g_currentMission.activatableObjectsSystem ~= nil then
        g_currentMission.activatableObjectsSystem:removeActivatable(spec.activatable)
    end
    if spec.triggerNode ~= nil then removeTrigger(spec.triggerNode) end
end

-- Реагирует только на вход локального игрока в trigger Shape.
function PlaceableTransferFromStorage:onPlayerTrigger(triggerId, otherId, onEnter, onLeave, onStay)
    if g_localPlayer == nil or otherId ~= g_localPlayer.rootNode then return end
    local act = self.spec_transferFromStorage.activatable
    if onEnter then
        g_currentMission.activatableObjectsSystem:addActivatable(act)
    elseif onLeave then
        g_currentMission.activatableObjectsSystem:removeActivatable(act)
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

-- Использует расстояние до исходного триггера для приоритета действий.
function TransferFromStorageActivatable:getDistance(x, y, z)
    local node = self.placeable.spec_transferFromStorage.triggerNode
    if node == nil then return math.huge end
    local tx, ty, tz = getWorldTranslation(node)
    return MathUtil.vector3Length(x - tx, y - ty, z - tz)
end

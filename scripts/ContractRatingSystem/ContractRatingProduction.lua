--[[
    ContractRatingProduction
    Расширение стандартной системы производств атрибутом minRating.
    Ограничения применяются к ферме-владельцу на сервере. Состояние рецепта
    передаётся штатными сетевыми событиями ProductionPoint.
]]
ContractRatingProduction = {}
ContractRatingProduction.installed = false
ContractRatingProduction.INVALID_RATING = 2147483647

-- Определяет требуемый рейтинг только для рецептов с атрибутом minRating.
function ContractRatingProduction.getRequiredRating(point, productionId)
    local production = point ~= nil and point.productionsIdToObj ~= nil
        and point.productionsIdToObj[productionId] or nil
    return production ~= nil and production.taigaMinRating or nil, production
end

-- Получает ферму-владельца из серверного объекта, не из сетевого пакета.
function ContractRatingProduction.getOwnerFarmId(point)
    if point == nil or point.owningPlaceable == nil then return nil end
    return point.owningPlaceable:getOwnerFarmId()
end

-- Проверяет действующий рейтинг фермы и возвращает данные для уведомления.
-- Пока журнал не загружен (восстановление сохранки), не блокируем запись:
-- после старта миссии все рецепты проверяются отдельно.
function ContractRatingProduction.check(point, productionId)
    local required = ContractRatingProduction.getRequiredRating(point, productionId)
    local farmId = ContractRatingProduction.getOwnerFarmId(point)
    if required == nil or farmId == AccessHandler.EVERYONE then
        return true, required, nil, farmId
    end
    local mission = g_currentMission
    local runtime = mission ~= nil and mission.contractRatingRuntime or nil
    if runtime == nil or farmId == nil then
        return runtime == nil, required, nil, farmId
    end

    local current = runtime.ledger:getRating(farmId)
    return current >= required, required, current, farmId
end

-- Выводит причину запрета локальному игроку без создания сетевого события.
function ContractRatingProduction.showLocalDenial(point, productionId, required, current)
    local _, production = ContractRatingProduction.getRequiredRating(point, productionId)
    local title = production ~= nil and production.name or productionId
    if InfoDialog ~= nil then
        InfoDialog.show(string.format(
            "Недостаточно рейтинга для рецепта «%s». Требуется: %d, текущий: %g.",
            tostring(title), required, current or 0),
            nil, nil, DialogElement.TYPE_WARNING)
    end
end

-- Отправляет ответ серверного отказа конкретному клиенту и восстанавливает
-- его оптимистическое состояние кнопки из авторитетного состояния сервера.
function ContractRatingProduction.rejectNetworkRequest(event, connection, kind, required, current)
    local point = event.productionPoint
    local originalState = point:getIsProductionEnabled(event.productionId)
    connection:sendEvent(ProductionPointProductionStateEvent.new(
        point, event.productionId, originalState))
    local production = point.productionsIdToObj[event.productionId]
    connection:sendEvent(ContractRatingProductionNoticeEvent.new(
        kind, production ~= nil and production.name or event.productionId,
        required, current))
end

-- Перехватывает сетевое переключение ДО штатной рассылки клиентам.
-- Штатный event.run иначе сначала делает broadcast, затем изменяет рецепт,
-- поэтому проверять только setProductionState на сервере недостаточно.
function ContractRatingProduction.productionStateEventRun(event, superFunc, connection)
    local point = event.productionPoint
    local required = ContractRatingProduction.getRequiredRating(point, event.productionId)
    if connection ~= nil and not connection:getIsServer()
        and required ~= nil and point ~= nil then
        local mission = g_currentMission
        local farmId = ContractRatingProduction.getOwnerFarmId(point)
        if farmId ~= AccessHandler.EVERYONE then
            local userId = mission.userManager:getUserIdByConnection(connection)
            local senderFarm = userId ~= nil and g_farmManager:getFarmByUserId(userId) or nil
            if senderFarm == nil or senderFarm.farmId ~= farmId
                or not mission:getHasPlayerPermission(
                    "manageProductions", connection, farmId) then
                ContractRatingProduction.rejectNetworkRequest(event, connection,
                    ContractRatingProductionNoticeEvent.PERMISSION, required, 0)
                return
            end
        end
        if event.isEnabled then
            local allowed, minRating, current =
                ContractRatingProduction.check(point, event.productionId)
            if not allowed then
                ContractRatingProduction.rejectNetworkRequest(event, connection,
                    ContractRatingProductionNoticeEvent.DENIED, minRating, current)
                return
            end
        end
    end
    return superFunc(event, connection)
end

-- Защищает серверные вызовы, консоль и локальный GUI от обхода minRating.
-- Выключение всегда разрешено; входящие сетевые обновления клиентов с
-- noEventSend=true не блокируются, так как их проверяет сервер.
function ContractRatingProduction.setProductionState(point, superFunc,
                                                     productionId, state, noEventSend)
    if state and (point.isServer or not noEventSend) then
        local allowed, required, current =
            ContractRatingProduction.check(point, productionId)
        if required ~= nil and not noEventSend then
            Logging.info("[ContractRating] Включение рецепта: recipe=%s, farmId=%s, rating=%s, minRating=%d, allowed=%s",
                tostring(productionId),
                tostring(ContractRatingProduction.getOwnerFarmId(point)),
                tostring(current), required, tostring(allowed))
        end
        if not allowed then
            if point.isClient and not noEventSend then
                ContractRatingProduction.showLocalDenial(
                    point, productionId, required, current)
            end
            return
        end
    end
    return superFunc(point, productionId, state, noEventSend)
end

-- Загружает minRating из того же XML, из которого штатный ProductionPoint
-- построил свои рецепты. Неизвестный/неверный атрибут не должен тихо открывать
-- доступ: некорректный minRating требует исправления XML.
function ContractRatingProduction.load(point, superFunc, components, xmlFile,
                                      key, customEnv, i3dMappings)
    local loaded = superFunc(point, components, xmlFile, key, customEnv, i3dMappings)
    if loaded then
        xmlFile:iterate(key .. ".productions.production", function(_, productionKey)
            local id = xmlFile:getValue(productionKey .. "#id")
            local production = point.productionsIdToObj[id]
            if production ~= nil
                and xmlFile:hasProperty(productionKey .. "#minRating") then
                local minRating = xmlFile:getValue(productionKey .. "#minRating")
                if minRating == nil or minRating % 1 ~= 0 then
                    Logging.xmlWarning(xmlFile,
                        "[ContractRating] Некорректный minRating рецепта '%s'", tostring(id))
                    minRating = ContractRatingProduction.INVALID_RATING
                end
                production.taigaMinRating = minRating
                Logging.info("[ContractRating] minRating прочитан: recipe=%s, minRating=%d, ownerFarmId=%s",
                    tostring(id), minRating,
                    tostring(ContractRatingProduction.getOwnerFarmId(point)))
            end
        end)
    end
    return loaded
end

-- Применяет рейтинг к активным рецептам только указанной фермы.
function ContractRatingProduction.enforceFarm(farmId)
    local mission = g_currentMission
    local manager = mission ~= nil and mission.productionChainManager or nil
    if mission == nil or not mission:getIsServer()
        or manager == nil or mission.contractRatingRuntime == nil
        or farmId == nil or farmId == AccessHandler.EVERYONE then return 0 end

    local disabled = 0
    for _, point in ipairs(manager:getProductionPointsForFarmId(farmId)) do
        -- setProductionState(false) удаляет элемент из activeProductions.
        -- Обратный обход не пропускает следующие активные рецепты.
        for index = #point.activeProductions, 1, -1 do
            local production = point.activeProductions[index]
            local required = production.taigaMinRating
            if required ~= nil then
                local current = mission.contractRatingRuntime.ledger:getRating(farmId)
                if current < required then
                    point:setProductionState(production.id, false)
                    disabled = disabled + 1
                    Logging.info(
                        "[ContractRating] Рецепт '%s' отключён: farmId=%d, rating=%g, minRating=%d",
                        production.id, farmId, current, required)
                    ContractRatingProduction.notifyFarm(
                        farmId, production.name or production.id, required, current)
                end
            end
        end
    end
    return disabled
end

-- Оповещает лишь участников затронутой фермы о принудительном отключении.
function ContractRatingProduction.notifyFarm(farmId, title, required, current)
    local mission = g_currentMission
    if mission == nil then return end
    if mission:getIsClient() and mission:getFarmId() == farmId then
        mission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            string.format("Рецепт «%s» отключён: рейтинг %g ниже требуемого %d.",
                tostring(title), current, required))
    end
    if not mission:getIsServer() or g_server == nil then return end
    for _, user in ipairs(mission.userManager:getUsers()) do
        local connection = user:getConnection()
        local farm = g_farmManager:getFarmByUserId(user:getId())
        if connection ~= nil and not connection:getIsLocal()
            and farm ~= nil and farm.farmId == farmId then
            connection:sendEvent(ContractRatingProductionNoticeEvent.new(
                ContractRatingProductionNoticeEvent.DISABLED,
                title, required, current))
        end
    end
end

-- При смене владельца проверяет ранее активированные рецепты новой фермы.
function ContractRatingProduction.setOwnerFarmId(point, superFunc, farmId, noEventSend)
    local result = superFunc(point, farmId, noEventSend)
    if point.isServer then ContractRatingProduction.enforceFarm(farmId) end
    return result
end

-- Проверяет все уже загруженные производства после восстановления журнала.
function ContractRatingProduction.enforceAll()
    local mission = g_currentMission
    if mission == nil or not mission:getIsServer()
        or mission.productionChainManager == nil then return end
    local seen = {}
    for _, point in ipairs(mission.productionChainManager.productionPoints) do
        local farmId = ContractRatingProduction.getOwnerFarmId(point)
        if farmId ~= nil and farmId ~= AccessHandler.EVERYONE and not seen[farmId] then
            seen[farmId] = true
            ContractRatingProduction.enforceFarm(farmId)
        end
    end
end

-- Регистрирует необязательный XML-атрибут до инициализации схем placeable.
function ContractRatingProduction.registerProductionXMLPaths(schema, basePath)
    schema:register(XMLValueType.INT,
        basePath .. ".productions.production(?)#minRating",
        "Minimum farm contract rating to enable this recipe")
end

-- Подключает расширение при загрузке extraSourceFiles. Все штатные рецепты
-- без minRating полностью сохраняют прежнюю логику и сетевой протокол.
function ContractRatingProduction.install()
    if ContractRatingProduction.installed then return true end
    if ProductionPoint == nil or ProductionPointProductionStateEvent == nil then
        Logging.warning("[ContractRating] Отложена установка minRating: классы ProductionPoint пока недоступны")
        return false
    end
    ProductionPoint.registerXMLPaths = Utils.appendedFunction(
        ProductionPoint.registerXMLPaths,
        ContractRatingProduction.registerProductionXMLPaths)
    ProductionPoint.load = Utils.overwrittenFunction(
        ProductionPoint.load, ContractRatingProduction.load)
    ProductionPoint.setProductionState = Utils.overwrittenFunction(
        ProductionPoint.setProductionState, ContractRatingProduction.setProductionState)
    ProductionPoint.setOwnerFarmId = Utils.overwrittenFunction(
        ProductionPoint.setOwnerFarmId, ContractRatingProduction.setOwnerFarmId)
    ProductionPointProductionStateEvent.run = Utils.overwrittenFunction(
        ProductionPointProductionStateEvent.run,
        ContractRatingProduction.productionStateEventRun)
    ContractRatingProduction.installed = true
    Logging.info("[ContractRating] Контроль производственных рецептов по minRating подключён")
    return true
end

-- Ранняя попытка не является окончательной: при компиляции extraSourceFiles
-- штатные классы могут ещё отсутствовать. Повторная установка в MissionTayga.new.
ContractRatingProduction.install()

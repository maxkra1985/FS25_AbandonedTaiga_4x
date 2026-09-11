--================================================================================================
-- ОБЪЯВЛЕНИЯ И КОНСТАНТЫ
-- Защита от двойной загрузки: скрипт может одновременно находиться в карте и отдельном моде.
-- В этом случае второй экземпляр не регистрирует повторные listeners/hooks.
if DinamycalPrice ~= nil and DinamycalPrice.__scriptLoaded then
	log("WARNING [DinamycalPrice] Duplicate script load ignored")
	return
end

DinamycalPrice = {}
DinamycalPrice.__scriptLoaded = true
DinamycalPrice.modName = "DinamycalPrice"
DinamycalPrice.version = "2026.08.29-audited-pricing-mp-pricescale-v13-auto-sell-growth-debug"

local config = {
	enableLogging = true,
	loggingPrefix = "[DinamycalPrice]"
}
local currentSellMultiplier = 1.0
local currentBuyMultiplier = 1.0


--================================================================================================
--================================================================================================
-- Вспомогательные функции для отладки и получения информации
local function logMessage(typeLog, msg)
	if config.enableLogging then
		log(typeLog, config.loggingPrefix .. " " .. tostring(msg))
	end
end


--================================================================================================
-- MULTIPLAYER-СИНХРОНИЗАЦИЯ
-- Сервер является единственным источником currentSellMultiplier/currentBuyMultiplier.
-- Клиент получает готовые значения и использует их для локального UI и цен.
--================================================================================================
DinamycalPriceSyncEvent = {}
local DinamycalPriceSyncEvent_mt = Class(DinamycalPriceSyncEvent, Event)
InitEventClass(DinamycalPriceSyncEvent, "DinamycalPriceSyncEvent")

function DinamycalPriceSyncEvent.emptyNew()
	return Event.new(DinamycalPriceSyncEvent_mt)
end

function DinamycalPriceSyncEvent.new(sellMultiplier, buyMultiplier)
	local self = DinamycalPriceSyncEvent.emptyNew()
	self.sellMultiplier = sellMultiplier or 1.0
	self.buyMultiplier = buyMultiplier or 1.0
	return self
end

function DinamycalPriceSyncEvent:writeStream(streamId, connection)
	streamWriteFloat32(streamId, self.sellMultiplier)
	streamWriteFloat32(streamId, self.buyMultiplier)
end

function DinamycalPriceSyncEvent:readStream(streamId, connection)
	self.sellMultiplier = streamReadFloat32(streamId)
	self.buyMultiplier = streamReadFloat32(streamId)
	self:run(connection)
end

function DinamycalPriceSyncEvent:run(connection)
	-- Сервер не принимает значения экономики от клиента.
	if g_currentMission ~= nil and g_currentMission:getIsServer() then
		logMessage("[SYNC]", "Ignored multiplier sync received on server")
		return
	end

	currentSellMultiplier = self.sellMultiplier or 1.0
	currentBuyMultiplier = self.buyMultiplier or 1.0

	DinamycalPrice.multiplierSyncReceived = true
	DinamycalPrice.clientPriceRefreshPending = true

	logMessage(
		"[SYNC]",
		string.format(
			"CLIENT received multipliers: sell=%.4f buy=%.4f",
			currentSellMultiplier,
			currentBuyMultiplier
		)
	)
end


DinamycalPriceSyncRequestEvent = {}
local DinamycalPriceSyncRequestEvent_mt = Class(DinamycalPriceSyncRequestEvent, Event)
InitEventClass(DinamycalPriceSyncRequestEvent, "DinamycalPriceSyncRequestEvent")

function DinamycalPriceSyncRequestEvent.emptyNew()
	return Event.new(DinamycalPriceSyncRequestEvent_mt)
end

function DinamycalPriceSyncRequestEvent.new()
	return DinamycalPriceSyncRequestEvent.emptyNew()
end

function DinamycalPriceSyncRequestEvent:writeStream(streamId, connection)
end

function DinamycalPriceSyncRequestEvent:readStream(streamId, connection)
	self:run(connection)
end

function DinamycalPriceSyncRequestEvent:run(connection)
	if g_currentMission == nil or not g_currentMission:getIsServer() then
		return
	end

	-- Запрос должен прийти от удалённого клиента.
	if connection == nil or connection:getIsServer() then
		return
	end

	logMessage(
		"[SYNC]",
		string.format(
			"SERVER received initial sync request; send sell=%.4f buy=%.4f",
			currentSellMultiplier,
			currentBuyMultiplier
		)
	)

	connection:sendEvent(
		DinamycalPriceSyncEvent.new(currentSellMultiplier, currentBuyMultiplier)
	)
end


function DinamycalPrice:broadcastMultipliers()
	if g_currentMission == nil
		or not g_currentMission:getIsServer()
		or g_server == nil then
		return
	end

	g_server:broadcastEvent(
		DinamycalPriceSyncEvent.new(currentSellMultiplier, currentBuyMultiplier),
		false
	)

	logMessage(
		"[SYNC]",
		string.format(
			"SERVER broadcast multipliers: sell=%.4f buy=%.4f",
			currentSellMultiplier,
			currentBuyMultiplier
		)
	)
end


function DinamycalPrice:requestInitialMultiplierSync()
	if self.multiplierSyncRequested then
		return true
	end

	if g_currentMission == nil or g_currentMission:getIsServer() then
		return false
	end

	if g_client == nil or g_client.getServerConnection == nil then
		return false
	end

	local connection = g_client:getServerConnection()
	if connection == nil then
		return false
	end

	connection:sendEvent(DinamycalPriceSyncRequestEvent.new())
	self.multiplierSyncRequested = true

	logMessage("[SYNC]", "CLIENT requested current multipliers from server")
	return true
end

local function getFullYears ()
	local environment = g_currentMission.environment
	local currentYear = 1
	local currentPeriod = 1
	local daysPerPeriod = 1

	local calculatedPeriod = 1

	if environment ~= nil then
		currentYear = environment.currentYear or 1
		logMessage( "INFO", string.format("Game calendar: currentYear=%d", currentYear))
		currentPeriod = environment.currentPeriod or 1
		logMessage( "INFO", string.format("Game calendar: currentPeriod=%d", currentPeriod))
		calculatedPeriod = currentPeriod + 2
		logMessage( "INFO", string.format("Game calendar: calculatedPeriod=%d", calculatedPeriod))
		if calculatedPeriod > 12 then
			calculatedPeriod = calculatedPeriod - 12
			logMessage( "INFO", string.format("Game calendar: calculatedPeriod=%d", calculatedPeriod))
		end
		daysPerPeriod = environment.daysPerPeriod or 1
		logMessage( "INFO", string.format("Game calendar: daysPerPeriod=%d", daysPerPeriod))
	end

	local fullYears = currentYear - 1
	logMessage( "INFO", string.format("Game calendar: fullYears=%d", fullYears))
	if fullYears > 0 and calculatedPeriod < 8 then
		fullYears = fullYears - 1
		logMessage( "INFO", string.format("Game calendar: fullYears=%d", fullYears))
	end

	logMessage(
		"INFO",
		string.format(
			"Game calendar: year=%d month=%d period=%d daysPerPeriod=%d =>> fullYears=%d",
			currentYear,
			calculatedPeriod,
			currentPeriod,
			daysPerPeriod,
			fullYears
		)
	)
	return fullYears
end

--================================================================================================
--================================================================================================
--================================================================================================
-- По факту постройки здания вызываем для него обновление цен
function DinamycalPrice:calculateChanged()
	logMessage("[EVENT]", "calculateChanged!")
	self:recalculateMultipliers()
	self:updatePlaceablesPrices()
	self:broadcastMultipliers()
end

--================================================================================================
-- Рассчёт и списание налога с продаж.
function DinamycalPrice:getCurrentTaxableSales(finances)
	if finances == nil then
		return 0
	end

	return math.max(0,
		(finances.soldProducts or 0)
		+ (finances.soldWood or 0)
		+ (finances.soldBales or 0)
		+ (finances.soldWool or 0)
		+ (finances.soldMilk or 0)
		+ (finances.harvestIncome or 0)
	)
end

function DinamycalPrice:initializeTaxSalesBaseline()
	self.taxSalesBaseline = self.taxSalesBaseline or {}

	if g_farmManager == nil or g_farmManager.farms == nil then
		return
	end

	for farmId, farm in pairs(g_farmManager.farms) do
		if farm ~= nil and farm.stats ~= nil then
			self.taxSalesBaseline[farmId] = self:getCurrentTaxableSales(farm.stats.finances)
		end
	end

	logMessage("[TAX]", "Initialized daily sales baselines")
end

--================================================================================================
-- FarmStats.finances накапливается в течение периода, поэтому суточный оборот
-- считаем как разницу двух накопительных снимков.
function DinamycalPrice:calculateTax()
	if g_currentMission == nil or g_farmManager == nil or not g_currentMission:getIsServer() then
		return
	end

	local farmId = g_currentMission:getFarmId()
	if farmId == nil then
		logMessage("[WARN]", "TAX: не удалось определить farmId")
		return
	end

	local farm = g_farmManager:getFarmById(farmId)
	if farm == nil or farm.stats == nil or farm.stats.finances == nil then
		logMessage("[WARN]", "TAX: не удалось получить статистику фермы")
		return
	end

	self.taxSalesBaseline = self.taxSalesBaseline or {}

	local cumulativeSales = self:getCurrentTaxableSales(farm.stats.finances)
	local previousSales = self.taxSalesBaseline[farmId]
	local dailySales

	if previousSales == nil then
		dailySales = 0
	elseif cumulativeSales >= previousSales then
		dailySales = cumulativeSales - previousSales
	else
		-- FarmStats был архивирован на PERIOD_CHANGED и накопитель начался заново.
		dailySales = cumulativeSales
	end

	self.taxSalesBaseline[farmId] = cumulativeSales
	dailySales = math.max(0, dailySales)

	logMessage("[TAX]", string.format(
		"Daily sales: cumulative=%.2f previous=%s daily=%.2f",
		cumulativeSales, tostring(previousSales), dailySales
	))

	-- Тестовое условие оставлено намеренно.
	local fullYears = getFullYears()
	if fullYears < 3 then
		g_currentMission:addIngameNotification(
			FSBaseMission.INGAME_NOTIFICATION_INFO,
			"Действует льготный период налогообложения (три года)"
		)
		logMessage("[TAX]", string.format(
			"Налог не начислен: оборот %.2f, льготный период не истёк", dailySales
		))
		return
	end

	local difficultyMultiplier = EconomyManager.getPriceMultiplier()

	local taxLimit1 = 50000 * difficultyMultiplier
	local taxLimit2 = 500000 * difficultyMultiplier
	local taxLimit3 = 1000000 * difficultyMultiplier
	local taxLimit4 = 2000000 * difficultyMultiplier
	local taxLimit5 = 3500000 * difficultyMultiplier

	local baseTaxRate = 0.00
	if dailySales <= taxLimit1 then
		baseTaxRate = 0.00
	elseif dailySales <= taxLimit2 then
		baseTaxRate = 0.02
	elseif dailySales <= taxLimit3 then
		baseTaxRate = 0.05
	elseif dailySales <= taxLimit4 then
		baseTaxRate = 0.10
	elseif dailySales <= taxLimit5 then
		baseTaxRate = 0.20
	else
		baseTaxRate = 0.30
	end

	local taxRate = 0.00
	if baseTaxRate > 0 then
		taxRate = MathUtil.round(
			(baseTaxRate + (3 - difficultyMultiplier) / 100) * currentBuyMultiplier,
			2
		)
	end

	local taxAmount = MathUtil.round(dailySales * taxRate, 0)

	logMessage("[TAX]", string.format(
		"difficultyMultiplier=%.2f limits=[%.0f, %.0f, %.0f, %.0f, %.0f] baseRate=%.0f%% buyMultiplier=%.4f finalRate=%.0f%% tax=%.2f",
		difficultyMultiplier, taxLimit1, taxLimit2, taxLimit3, taxLimit4, taxLimit5,
		baseTaxRate * 100, currentBuyMultiplier, taxRate * 100, taxAmount
	))

	if taxAmount > 0 then
		g_currentMission:addMoney(-taxAmount, farmId, MoneyType.OTHER, true, true)
		g_currentMission:addIngameNotification(
			FSBaseMission.INGAME_NOTIFICATION_INFO,
			string.format(
				"Налог с продаж за прошедший день: %s (ставка %.0f%%)",
				g_i18n:formatMoney(taxAmount, 0, true, true),
				taxRate * 100
			)
		)
		logMessage("[TAX]", string.format("Списан налог %.2f, категория OTHER", taxAmount))
	else
		g_currentMission:addIngameNotification(
			FSBaseMission.INGAME_NOTIFICATION_INFO,
			string.format(
				"Налог с продаж за прошедший день: %s (необлагаемый оборот)",
				g_i18n:formatMoney(0, 0, true, true)
			)
		)
		logMessage("[TAX]", string.format(
			"Налог не начислен: оборот %.2f, необлагаемый предел %.2f",
			dailySales, taxLimit1
		))
	end
end

--================================================================================================
-- Получение накопленной финансовой статистики.
-- Складывает текущий месяц + всю доступную financesHistory.
local function getFinanceTotal(stats, fieldName)
	local total = 0

	if stats == nil then
		return total
	end

	-- Текущий месяц
	if stats.finances ~= nil then
		total = total + (stats.finances[fieldName] or 0)
	end

	-- Завершённые месяцы
	if stats.financesHistory ~= nil then
		for _, finances in pairs(stats.financesHistory) do
			if finances ~= nil then
				total = total + (finances[fieldName] or 0)
			end
		end
	end

	return total
end

--================================================================================================
-- Рассчитываем множители цен на основе полученной игровой статистики
function DinamycalPrice:recalculateMultipliers()
	logMessage("[INFO]", "--- === recalculateMultipliers === ---")

	if g_currentMission == nil or g_farmManager == nil then
		logMessage("[WARN]", "g_currentMission или g_farmManager не определён")
		return
	end

	local farmId = g_currentMission:getFarmId()

	if farmId == nil then
		logMessage("[WARN]", "Не удалось определить farmId")
		return
	end

	local farm = g_farmManager:getFarmById(farmId)

	if farm == nil or farm.stats == nil then
		logMessage("[WARN]", "Не удалось получить статистику фермы farmId=" .. tostring(farmId))
		return
	end

	local stats = farm.stats
	local statistics = stats.statistics

	if statistics == nil then
		logMessage("[WARN]", "farm.stats.statistics не определён")
		return
	end


	--========================================================================
	-- Исходные данные
	--========================================================================
	local cutTreeCount = 0
	local plantedTreeCount = 0
	local plowedHectares = 0

	if statistics.cutTreeCount ~= nil then
		cutTreeCount = statistics.cutTreeCount.total or 0
	end

	if statistics.plantedTreeCount ~= nil then
		plantedTreeCount = statistics.plantedTreeCount.total or 0
	end

	if statistics.plowedHectares ~= nil then
		plowedHectares = statistics.plowedHectares.total or 0
	end

	--========================================================================
	-- Финансы за всё доступное игровое время
	--========================================================================
	local soldProducts = getFinanceTotal(stats, "soldProducts")
	local soldWood = getFinanceTotal(stats, "soldWood")
	local soldBales = getFinanceTotal(stats, "soldBales")
	local soldWool = getFinanceTotal(stats, "soldWool")
	local soldMilk = getFinanceTotal(stats, "soldMilk")
	local harvestIncome = getFinanceTotal(stats, "harvestIncome")

	local otherSoldProducts = soldWood + soldBales + soldWool + soldMilk + harvestIncome

	--========================================================================
	-- 1. Вырубка леса
	-- Учитываем только превышение количества срубленных деревьев
	-- над количеством посаженных.
	-- Каждая полная 1000 деревьев = 1% штрафа.
	--========================================================================
	local treeDifference = math.max(0, cutTreeCount - plantedTreeCount)
	local treeSteps = math.floor(treeDifference / 1000)

	--========================================================================
	-- 2. Возраст фермы. Берём только полностью прожитые годы. Первый полный год не штрафуется.
	--========================================================================
	local fullYears = getFullYears()
	local yearSteps = math.max(0, fullYears - 3)

	--========================================================================
	-- 3. Продажа продукции
	-- Каждые полные 1 000 000 = 1% штрафа.
	--========================================================================
	local soldProductsSteps = math.floor(soldProducts / 1000000)

	--========================================================================
	-- 4. Прочие продажи
	-- soldWood
	-- soldBales
	-- soldWool
	-- soldMilk
	-- harvestIncome
	-- Каждые полные 3 000 000 общей суммы = 1% штрафа.
	--========================================================================
	local otherProductsSteps = math.floor(otherSoldProducts / 3000000)

	--========================================================================
	-- 5. Вспашка
	-- Каждые полные 100 га = 1% льготы.
	--========================================================================
	local plowedSteps = math.floor(plowedHectares / 100)

	--========================================================================
	-- Итог
	-- Положительное число = штраф.
	-- Отрицательное число = льгота.
	--========================================================================
	local penaltySteps = treeSteps + yearSteps + soldProductsSteps + otherProductsSteps
	local benefitSteps = plowedSteps
	local netSteps = penaltySteps - benefitSteps
	local priceChange = netSteps * 0.01


	--========================================================================
	-- Штраф:
	--   игрок продаёт игре дешевле
	--   игрок покупает у игры дороже
	-- Льгота автоматически работает наоборот, потому что netSteps становится отрицательным.
	--========================================================================
	currentSellMultiplier = 1.0 - priceChange - 0.05
	currentBuyMultiplier = 1.0 + priceChange

	--========================================================================
	-- Логирование
	--========================================================================
	logMessage("[INFO]", string.format("Trees: cut=%s planted=%s difference=%s steps=%s", tostring(cutTreeCount), tostring(plantedTreeCount), tostring(treeDifference), tostring(treeSteps)) )
	logMessage("[INFO]", string.format("Time: fullYears=%s, steps=%s", tostring(fullYears), tostring(yearSteps)) )
	logMessage("[INFO]", string.format("soldProducts=%.2f, steps=%s", soldProducts, tostring(soldProductsSteps)) )
	logMessage("[INFO]", string.format("Other sales: wood=%.2f bales=%.2f wool=%.2f milk=%.2f harvest=%.2f total=%.2f steps=%s", soldWood, soldBales, soldWool, soldMilk, harvestIncome, otherSoldProducts, tostring(otherProductsSteps)) )
	logMessage("[INFO]", string.format("Plowed: %.2f ha, benefitSteps=%s", plowedHectares, tostring(plowedSteps)) )
	logMessage("[INFO]", string.format("Result: penalties=%s benefits=%s net=%s change=%.2f%% sellMultiplier=%.4f buyMultiplier=%.4f", tostring(penaltySteps), tostring(benefitSteps), tostring(netSteps), priceChange * 100, currentSellMultiplier, currentBuyMultiplier) )
	logMessage("[INFO]", "--- === recalculateMultipliers === ---")
end

--================================================================================================
-- Поиск BuyingStation, связанных с конкретным placeable.
-- Некоторые объекты (например silo/контейнеры) имеют BuyingStation в storageSystem,
-- но не имеют placeable.spec_buyingStation.
local function getBuyingStationsForPlaceable(placeable)
	local result = {}
	if placeable == nil or g_currentMission == nil or g_currentMission.storageSystem == nil or g_currentMission.storageSystem.loadingStations == nil then
		return result
	end

	for _, station in pairs(g_currentMission.storageSystem.loadingStations) do
		if station.owningPlaceable == placeable and station.fillTypePricesScale ~= nil then
			table.insert(result, station)
		end
	end

	return result
end


--================================================================================================
-- Корректировка итоговой цены аренды в LeaseYesNoDialog.
-- Три составляющие аренды (базовая, за день, за час) ShopConfigScreen уже рассчитывает
-- от скорректированного totalPrice. Штатный initialCosts при этом остаётся рассчитанным
-- от исходной цены, поэтому пересчитываем только его.
function DinamycalPrice.overwrittenLeaseDialogSetPrices(self, superFunc, costsBase, initialCosts, costsPerOperatingHour, costsPerDay, ...)
	local oldInitialCosts = initialCosts

	if g_shopConfigScreen ~= nil and g_shopConfigScreen.totalPrice ~= nil and g_shopConfigScreen.totalPrice > 0 and g_currentMission ~= nil and g_currentMission.economyManager ~= nil and g_currentMission.economyManager.getInitialLeasingPrice ~= nil then
		initialCosts = g_currentMission.economyManager:getInitialLeasingPrice(g_shopConfigScreen.totalPrice)

		logMessage(
			"INFO",
			string.format(
				"LEASE DIALOG: totalPrice=%s initialCosts=%s -> %s base=%s day=%s hour=%s buyMultiplier=%.4f",
				tostring(g_shopConfigScreen.totalPrice),
				tostring(oldInitialCosts),
				tostring(initialCosts),
				tostring(costsBase),
				tostring(costsPerDay),
				tostring(costsPerOperatingHour),
				currentBuyMultiplier
			)
		)
	end

	return superFunc(self, costsBase, initialCosts, costsPerOperatingHour, costsPerDay, ...)
end


--================================================================================================
-- В FS25 диалог аренды существует как отдельный GUI-экземпляр LeaseYesNoDialog.
-- Ставим hook непосредственно на target.setPrices, потому что callback GUI может хранить
-- ссылку на функцию экземпляра и поздняя подмена метода класса не всегда срабатывает.
function DinamycalPrice:installLeaseDialogHook()
	if self.leaseDialogHookInstalled then
		return true
	end

	if g_gui == nil or g_gui.guis == nil then
		logMessage("[WARN]", "Lease dialog hook: g_gui.guis недоступен")
		return false
	end

	for name, gui in pairs(g_gui.guis) do
		local nameLower = string.lower(tostring(name))
		local target = gui ~= nil and gui.target or nil

		if string.find(nameLower, "lease") and target ~= nil and target.setPrices ~= nil then
			target.setPrices = Utils.overwrittenFunction(target.setPrices, DinamycalPrice.overwrittenLeaseDialogSetPrices)
			self.leaseDialogHookInstalled = true
			logMessage("[EVENT]", "Lease dialog price hook installed: " .. tostring(name))
			return true
		end
	end

	logMessage("[WARN]", "Lease dialog with setPrices not found")
	return false
end

-- Forward declaration: этот helper реализован ниже, но нужен UI-хуку раньше
-- по тексту файла. Без объявления Lua воспринимал вызов как глобальную функцию nil.
local getPalletCapacityForFillType

--================================================================================================
-- PalletBuyingStation и меню цен используют разные единицы:
--   pallet.price / getEffectivePricePerPallet() = цена ВСЕЙ палеты;
--   InGameMenuStatisticsFrame визуально представляет цены в €/1000 л.
--
-- Штатный FS25 для PalletBuyingStation напрямую выводит getEffectivePricePerPallet()
-- в колонку buyPrice, не нормализуя нестандартную вместимость палеты. Поэтому
-- палеты 250/2000/3000 л в таблице цен выглядят соответственно в 4 раза ниже /
-- в 2-3 раза выше ожидаемой цены за 1000 л.
--
-- Покупную цену и списание денег НЕ трогаем. Исправляем только отображение
-- PalletBuyingStation в InGameMenuStatisticsFrame.
local function getPalletPricePer1000Liters(palletBuyingStation, fillTypeIndex)
	if palletBuyingStation == nil or fillTypeIndex == nil then
		return nil, nil, nil
	end

	local fullPalletPrice = palletBuyingStation:getEffectivePricePerPallet(fillTypeIndex)
	if fullPalletPrice == nil then
		return nil, nil, nil
	end

	local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
	local capacity = getPalletCapacityForFillType(fillType)

	if capacity == nil or capacity <= 0 then
		return fullPalletPrice, nil, fullPalletPrice
	end

	local pricePer1000 = fullPalletPrice / capacity * 1000
	return pricePer1000, capacity, fullPalletPrice
end

function DinamycalPrice.onStatisticsPriceCellPopulated(frame, list, section, index, cell)
	if frame == nil
		or cell == nil
		or frame.currentStationData == nil
		or frame.fillTypes == nil then
		return
	end

	local stationData = nil
	local fillTypeIndex = nil

	-- Режим "по станции": priceList содержит товары выбранной станции.
	if list == frame.priceList and frame.sellingStationMode then
		stationData = frame.currentStationData[frame.currentStationIndex]

		if frame.currentAcceptedFillTypes ~= nil then
			fillTypeIndex = frame.currentAcceptedFillTypes[index]
		end

	-- Режим "по товару": priceList/productList содержит станции для выбранного товара.
	elseif (list == frame.priceList and not frame.sellingStationMode)
		or (list == frame.productList and frame.sellingStationMode) then

		stationData = frame.currentStationData[index]

		if frame.productList ~= nil and frame.productList.getSelectedPath ~= nil then
			local fillTypeSection, fillTypeRow = frame.productList:getSelectedPath()
			local sectionData = fillTypeSection ~= nil and frame.fillTypes[fillTypeSection] or nil
			local fillType = sectionData ~= nil and sectionData[fillTypeRow] or nil

			if fillType ~= nil then
				fillTypeIndex = fillType.index
			end
		end
	end

	if stationData == nil
		or fillTypeIndex == nil
		or stationData.buyingStation ~= nil
		or stationData.palletBuyingStation == nil then
		return
	end

	local palletBuyingStation = stationData.palletBuyingStation

	if not palletBuyingStation:getHasPalletForFillType(fillTypeIndex) then
		return
	end

	local pricePer1000, capacity, fullPalletPrice =
		getPalletPricePer1000Liters(palletBuyingStation, fillTypeIndex)

	if pricePer1000 == nil then
		return
	end

	local buyPriceElement = cell:getAttribute("buyPrice")
	if buyPriceElement == nil then
		return
	end

	buyPriceElement:setVisible(true)
	buyPriceElement:setValue(tostring(pricePer1000))

	-- Диагностика только для нестандартных палет и только один раз на сочетание
	-- станция/fillType/цена, чтобы прокрутка списка не засоряла log.txt.
	if capacity ~= nil and math.abs(capacity - 1000) > 0.01 then
		frame.dinamycalPricePalletUiLogCache =
			frame.dinamycalPricePalletUiLogCache or {}

		local cacheKey = string.format(
			"%s:%s:%s",
			tostring(palletBuyingStation),
			tostring(fillTypeIndex),
			tostring(fullPalletPrice)
		)

		if not frame.dinamycalPricePalletUiLogCache[cacheKey] then
			frame.dinamycalPricePalletUiLogCache[cacheKey] = true

			local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)

			logMessage(
				"[PALLET PRICE UI]",
				string.format(
					"station='%s' product='%s' fillType=%s capacity=%.0f fullPalletPrice=%.2f displayPer1000=%.2f",
					tostring(stationData.name),
					fillType ~= nil and tostring(fillType.title) or "UNKNOWN",
					tostring(fillTypeIndex),
					capacity,
					fullPalletPrice,
					pricePer1000
				)
			)
		end
	end
end

--================================================================================================
-- Обработка одного placeable. Один объект может одновременно содержать несколько экономических специализаций, поэтому здесь намеренно нет return после каждого блока.
-- Получение реальной вместимости палеты для fillType.
getPalletCapacityForFillType = function(fillType)
	if fillType == nil or fillType.palletFilename == nil then
		return nil
	end

	local storeItem = g_storeManager:getItemByXMLFilename(fillType.palletFilename)
	if storeItem == nil then
		return nil
	end

	if storeItem.specs == nil then
		StoreItemUtil.loadSpecsFromXML(storeItem)
	end

	if storeItem.specs ~= nil and storeItem.specs.capacity ~= nil then
		local capacityConfig = storeItem.specs.capacity[1]

		if capacityConfig ~= nil and capacityConfig.fillUnits ~= nil then
			for _, fillUnit in ipairs(capacityConfig.fillUnits) do
				if fillUnit.capacity ~= nil and fillUnit.capacity > 0 then
					return fillUnit.capacity
				end
			end
		end
	end

	return nil
end

--================================================================================================
-- Сохраняем НАСТОЯЩИЙ priceScale из XML PalletBuyingStation.
--
-- Штатный PlaceablePalletBuyingStation:onLoad() читает #priceScale локально,
-- использует его при создании pallet.price, но не сохраняет в таблице pallet.
-- Поэтому восстанавливать scale из pallet.price НЕЛЬЗЯ: pallet.price построен
-- через storeItem.price, а наша динамическая цена строится через
-- EconomyManager:getPricePerLiter() * фактический объём палеты.
function DinamycalPrice:capturePalletBuyingStationPriceScales(placeable)
	if placeable == nil
		or placeable.spec_palletBuyingStation == nil
		or placeable.xmlFile == nil then
		return false
	end

	local spec = placeable.spec_palletBuyingStation
	if spec.fillTypeIndexToPallet == nil then
		return false
	end

	spec.dinamycalPricePriceScales = spec.dinamycalPricePriceScales or {}

	local foundAny = false
	local i = 0

	while true do
		local key = string.format("placeable.palletBuyingStation.fillType(%d)", i)
		if not placeable.xmlFile:hasProperty(key) then
			break
		end

		local fillTypeName = placeable.xmlFile:getValue(key .. "#name")
		local fillType = fillTypeName ~= nil
			and g_fillTypeManager:getFillTypeByName(fillTypeName)
			or nil

		if fillType ~= nil then
			local fillTypeIndex = fillType.index
			local priceScale = placeable.xmlFile:getValue(key .. "#priceScale", 1.0)
			local pallet = spec.fillTypeIndexToPallet[fillTypeIndex]

			spec.dinamycalPricePriceScales[fillTypeIndex] = priceScale

			if pallet ~= nil then
				pallet.dinamycalPricePriceScale = priceScale
			end

			foundAny = true

			logMessage(
				"[PALLET SCALE]",
				string.format(
					"'%s' fillType='%s' index=%s XML priceScale=%.4f",
					placeable.getName ~= nil and tostring(placeable:getName()) or "UNKNOWN",
					tostring(fillTypeName),
					tostring(fillTypeIndex),
					priceScale
				)
			)
		else
			logMessage(
				"[WARN]",
				string.format(
					"PALLET SCALE '%s': unknown fillType name='%s' at %s",
					placeable.getName ~= nil and tostring(placeable:getName()) or "UNKNOWN",
					tostring(fillTypeName),
					key
				)
			)
		end

		i = i + 1
	end

	return foundAny
end

-- appended to PlaceablePalletBuyingStation:onLoad(); base onLoad has already built
-- fillTypeIndexToPallet by the time this function runs.
function DinamycalPrice.onPalletBuyingStationLoaded(placeable, savegame)
	DinamycalPrice:capturePalletBuyingStationPriceScales(placeable)
end

function DinamycalPrice:updateSinglePlaceablePrice(placeable)
	if placeable == nil then
		return false
	end

	local handled = false

	-- SellingStation / BuyingStation рассчитываются динамически центральными hooks.
	if placeable.spec_sellingStation ~= nil or placeable.spec_buyingStation ~= nil then
		handled = true
	end

	-- PalletBuyingStation:
	--
	-- Штатный PlaceablePalletBuyingStation:onLoad() формирует pallet.price как:
	--   storeItem.price * priceScale * EconomyManager.getPriceMultiplier()
	--
	-- Для DinamycalPrice pallet.price не используется как база.
	-- Все палетные товары без исключений строят BUY от той же штатной
	-- рыночной цены, что и SELL: getPricePerLiter(fillTypeIndex), включая
	-- сезонность и economicDifficulty. Далее применяются XML priceScale
	-- станции, фактический объём палеты и currentBuyMultiplier.
	-- Подробные значения выводятся через [PALLET PRICE DEBUG].
	if placeable.spec_palletBuyingStation ~= nil then
		handled = true
		local spec = placeable.spec_palletBuyingStation

		if spec.fillTypeIndexToPallet ~= nil then
			for fillTypeIndex, pallet in pairs(spec.fillTypeIndexToPallet) do
				local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)

				if fillType ~= nil then
					local palletCapacity = getPalletCapacityForFillType(fillType)
					local basePricePerLiter = fillType.pricePerLiter

					if basePricePerLiter ~= nil
						and basePricePerLiter > 0
						and palletCapacity ~= nil
						and palletCapacity > 0 then

						local basePalletPrice = basePricePerLiter * palletCapacity

						local economyManager = g_currentMission ~= nil
							and g_currentMission.economyManager
							or nil

						-- SELL market price: сезонность + штатная сложность продажи.
						local marketSellPricePerLiter = nil
						-- Seasonal base: сезонность есть, difficulty multiplier отключён.
						local marketBasePricePerLiter = nil

						if economyManager ~= nil
							and economyManager.getPricePerLiter ~= nil then
							marketSellPricePerLiter =
								economyManager:getPricePerLiter(fillTypeIndex)
							marketBasePricePerLiter =
								economyManager:getPricePerLiter(fillTypeIndex, false)
						end

						local economicDifficulty = 1
						if g_currentMission ~= nil
							and g_currentMission.missionInfo ~= nil
							and g_currentMission.missionInfo.economicDifficulty ~= nil then
							economicDifficulty =
								g_currentMission.missionInfo.economicDifficulty
						end

						-- Все палетные товары без исключений покупаются от той же рыночной
						-- базы, что и продаются. getPricePerLiter(fillTypeIndex) уже содержит
						-- сезонность и штатный economicDifficulty.
						-- stationPriceScale и currentBuyMultiplier накладываются поверх неё.

						-- Берём ТОЛЬКО настоящий XML priceScale станции.
						-- Никакого обратного вычисления через pallet.price:
						-- штатный pallet.price основан на storeItem.price и потому
						-- не позволяет корректно восстановить scale при палетах
						-- объёмом 250/2000/3000 л и при сезонных ценах.
						if pallet.dinamycalPricePriceScale == nil then
							DinamycalPrice:capturePalletBuyingStationPriceScales(placeable)
						end

						local stationPriceScale = pallet.dinamycalPricePriceScale

						if stationPriceScale == nil
							and spec.dinamycalPricePriceScales ~= nil then
							stationPriceScale =
								spec.dinamycalPricePriceScales[fillTypeIndex]
						end

						if stationPriceScale == nil then
							-- XML schema default is 1.0. This fallback is safe only
							-- when the attribute is absent/unreadable; it is NOT inferred.
							stationPriceScale = 1.0

							logMessage(
								"[WARN]",
								string.format(
									"PALLET '%s' product='%s' fillType=%s: XML priceScale not captured, fallback=1.0",
									placeable.getName ~= nil and tostring(placeable:getName()) or "UNKNOWN",
									tostring(pallet.title),
									tostring(fillTypeIndex)
								)
							)
						end

						local effectiveSellPricePerLiter =
							marketSellPricePerLiter
							or (
								marketBasePricePerLiter ~= nil
								and marketBasePricePerLiter * EconomyManager.getPriceMultiplier()
								or basePricePerLiter
							)

						local effectiveBuyBasePricePerLiter =
							marketSellPricePerLiter
							or marketBasePricePerLiter
							or basePricePerLiter

						local calculatedSellPricePerLiter =
							effectiveSellPricePerLiter * currentSellMultiplier

						local calculatedBuyPricePerLiter =
							effectiveBuyBasePricePerLiter
							* stationPriceScale
							* currentBuyMultiplier

						local oldPrice = pallet.price or 0
						local newPrice = MathUtil.round(
							calculatedBuyPricePerLiter * palletCapacity,
							0
						)

						pallet.price = newPrice
						pallet.dinamycalPriceBasePrice = basePalletPrice
						pallet.dinamycalPricePriceScale = stationPriceScale

						logMessage(
							"[PALLET PRICE DEBUG]",
							string.format(
								"'%s' product='%s' fillType=%s capacity=%.0f rawPricePerLiter=%.4f getPricePerLiter=%s getPricePerLiterNoDifficulty=%s economicDifficulty=%s buyPriceBasis=%s stationPriceScale=%.4f currentSellMultiplier=%.4f currentBuyMultiplier=%.4f calculatedSellPerLiter=%.4f calculatedBuyPerLiter=%.4f oldPrice=%s newPrice=%s",
								placeable.getName ~= nil and tostring(placeable:getName()) or "UNKNOWN",
								tostring(pallet.title),
								tostring(fillTypeIndex),
								palletCapacity,
								basePricePerLiter,
								marketSellPricePerLiter ~= nil
									and string.format("%.4f", marketSellPricePerLiter)
									or "nil",
								marketBasePricePerLiter ~= nil
									and string.format("%.4f", marketBasePricePerLiter)
									or "nil",
								tostring(economicDifficulty),
								"MARKET_WITH_DIFFICULTY",
								stationPriceScale,
								currentSellMultiplier,
								currentBuyMultiplier,
								calculatedSellPricePerLiter,
								calculatedBuyPricePerLiter,
								tostring(oldPrice),
								tostring(newPrice)
							)
						)
					else
						logMessage(
							"[WARN]",
							string.format(
								"PALLET '%s': cannot calculate '%s' fillType=%s basePricePerLiter=%s capacity=%s",
								placeable.getName ~= nil and tostring(placeable:getName()) or "UNKNOWN",
								tostring(pallet.title),
								tostring(fillTypeIndex),
								tostring(basePricePerLiter),
								tostring(palletCapacity)
							)
						)
					end
				end
			end
		end
	end

	return handled
end

--================================================================================================
-- Обновление цен во всех существующих точках продаж и покупок
function DinamycalPrice:updatePlaceablesPrices()
	logMessage("[INFO]", "--- === updatePlaceablesPrices === ---")

	if g_currentMission == nil or g_currentMission.placeableSystem == nil or g_currentMission.placeableSystem.placeables == nil then
		return
	end

	for _, placeable in pairs(g_currentMission.placeableSystem.placeables) do
		self:updateSinglePlaceablePrice(placeable)
	end
end

--================================================================================================
-- Очередь новых placeable.
-- Hook устанавливается в loadMap(), но до первого игрового update новые placeable
-- в очередь не добавляем. Поэтому объекты карты/сохранения не будут обрабатываться
-- как вновь построенные.
DinamycalPrice.pendingPlaceables = {}
DinamycalPrice.pendingPlaceableDelayFrames = 2
DinamycalPrice.pendingPlaceableMaxRetries = 30
DinamycalPrice.initialUpdateDone = false
DinamycalPrice.farmlandEventHookInstalled = false
DinamycalPrice.buyVehicleDataHookInstalled = false
DinamycalPrice.shopConfigPriceHookInstalled = false
DinamycalPrice.leaseDialogHookInstalled = false
DinamycalPrice.placeableHookInstalled = false

function DinamycalPrice.onPlaceableAdded(placeableSystem, placeable)
	if placeable == nil then
		return
	end

	-- Во время первоначальной загрузки карты addPlaceable вызывается для множества
	-- объектов. Их отдельно не ставим в очередь: первый полный пересчёт выполнится
	-- в DinamycalPrice:update().
	if not DinamycalPrice.initialUpdateDone then
		return
	end

	DinamycalPrice.pendingPlaceables[placeable] = {
		framesLeft = DinamycalPrice.pendingPlaceableDelayFrames,
		retriesLeft = DinamycalPrice.pendingPlaceableMaxRetries
	}

	logMessage("[EVENT]", "Placeable added, queued: " .. tostring(placeable.getName ~= nil and placeable:getName() or placeable) )
end

-- Multiplayer sync state
DinamycalPrice.multiplierSyncRequested = false
DinamycalPrice.multiplierSyncReceived = false
DinamycalPrice.clientPriceRefreshPending = false

--================================================================================================
-- Первый update после загрузки выполняет полный пересчёт цен.
-- Далее update используется для очереди вновь построенных placeable и клиентской синхронизации.
function DinamycalPrice:update(dt)
	-- GUI существует только на клиенте; если диалог аренды не был готов в loadMap,
	-- повторяем установку hook в игровом update-цикле.
	-- Lease dialog uses the already corrected vehicle totalPrice from EconomyManager.
	-- The legacy lease hook is intentionally not installed to avoid double multiplication.

	if g_currentMission == nil then
		return
	end

	-- ========================================================================
	-- CLIENT
	-- Экономику не рассчитываем. Запрашиваем готовые множители у сервера,
	-- затем локально обновляем placeable/UI.
	-- ========================================================================
	if not g_currentMission:getIsServer() then
		if not self.multiplierSyncRequested
			and not self.multiplierSyncReceived
			and g_currentMission.placeableSystem ~= nil
			and g_currentMission.placeableSystem.placeables ~= nil
			and g_currentMission.storageSystem ~= nil then

			self:requestInitialMultiplierSync()
		end

		if self.clientPriceRefreshPending
			and g_currentMission.placeableSystem ~= nil
			and g_currentMission.placeableSystem.placeables ~= nil
			and g_currentMission.storageSystem ~= nil then

			logMessage(
				"[SYNC]",
				string.format(
					"CLIENT applying synced prices: sell=%.4f buy=%.4f",
					currentSellMultiplier,
					currentBuyMultiplier
				)
			)

			self:updatePlaceablesPrices()
			self.clientPriceRefreshPending = false
		end

		return
	end

	-- ========================================================================
	-- SERVER
	-- Первый полный пересчёт после загрузки. calculateChanged() также рассылает
	-- актуальные множители всем уже подключённым клиентам.
	-- ========================================================================
	if not self.initialUpdateDone then
		if g_currentMission.placeableSystem ~= nil
			and g_currentMission.placeableSystem.placeables ~= nil
			and g_currentMission.storageSystem ~= nil then

			logMessage("[EVENT]", "Initial price update")
			self:calculateChanged()
			self.initialUpdateDone = true
		end
	end

	for placeable, state in pairs(self.pendingPlaceables) do
		if placeable == nil or placeable.isDeleted then
			self.pendingPlaceables[placeable] = nil

		elseif state.framesLeft > 0 then
			state.framesLeft = state.framesLeft - 1

		else
			local name = placeable.getName ~= nil and placeable:getName() or tostring(placeable)
			local handled = self:updateSinglePlaceablePrice(placeable)

			if handled then
				logMessage("[EVENT]", "Queued placeable prices updated: " .. tostring(name))
				self.pendingPlaceables[placeable] = nil
			else
				state.retriesLeft = state.retriesLeft - 1

				if state.retriesLeft <= 0 then
					logMessage("[INFO]", "Queued placeable has no price station: " .. tostring(name))
					self.pendingPlaceables[placeable] = nil
				end
			end
		end
	end
end

--================================================================================================
-- Корректировка стоимости покупки материалов через PlaceableSilo.refillAmount.
-- Игра передаёт сюда уже рассчитанную стоимость для конкретного amount.
-- Количество материала не меняем: корректируем только price текущим buy-множителем.
function DinamycalPrice.overwrittenSiloRefillAmount(self, superFunc, fillTypeIndex, amount, price, ...)
	local originalPrice = price

	-- Нулевую/nil стоимость не трогаем: такие вызовы могут использоваться
	-- служебной логикой или обычным перемещением материала без покупки.
	if price ~= nil
		and price > 0
		and currentBuyMultiplier ~= nil
		and currentBuyMultiplier > 0 then

		price = price * currentBuyMultiplier

		local fillType = nil
		if g_fillTypeManager ~= nil then
			fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
		end

		local placeableName = "UNKNOWN"
		if self ~= nil and self.getName ~= nil then
			placeableName = tostring(self:getName())
		end

		logMessage(
			"INFO",
			string.format(
				"BUY SILO '%s': product='%s' fillType=%s amount=%.2f price=%.2f -> %.2f buyMultiplier=%.4f",
				placeableName,
				fillType ~= nil and tostring(fillType.title) or tostring(fillTypeIndex),
				tostring(fillTypeIndex),
				tonumber(amount) or 0,
				tonumber(originalPrice) or 0,
				tonumber(price) or 0,
				currentBuyMultiplier
			)
		)
	end

	return superFunc(self, fillTypeIndex, amount, price, ...)
end


--================================================================================================
-- Установка hook refillAmount непосредственно на экземпляр placeable.
-- Это необходимо, потому что placeableType регистрирует refillAmount до loadMap(),
-- и поздняя замена глобального PlaceableSilo.refillAmount не затрагивает уже
-- зарегистрированные функции конкретных типов.
function DinamycalPrice:installSiloRefillHook(placeable)
	-- Не требуется: RefillDialog корректируется до формирования цены.
	return placeable ~= nil and placeable.spec_silo ~= nil
end

--================================================================================================
-- Центральные штатные точки расчёта цены.
-- ВАЖНО: superFunc уже учитывает priceScale/priceMultipliers конкретной станции,
-- seasonal/economicDifficulty и прочие штатные коэффициенты.
function DinamycalPrice.overwrittenSellingStationEffectivePrice(self, superFunc, fillType, toolType)
	local price = superFunc(self, fillType, toolType)

	-- SellingStation синхронизирует клиенту уже готовую effective price:
	-- на сервере writeStream/writeUpdateStream вызывает getEffectiveFillTypePrice().
	-- Поэтому на клиенте повторно currentSellMultiplier НЕ применяем.
	if self.isServer then
		return price * currentSellMultiplier
	end

	return price
end

function DinamycalPrice.overwrittenBuyingStationEffectivePrice(self, superFunc, fillTypeIndex)
	-- superFunc уже содержит priceScale станции и штатный cost multiplier.
	return superFunc(self, fillTypeIndex) * currentBuyMultiplier
end


--================================================================================================
-- АВТОПРОДАЖА ПРОДУКЦИИ
--
-- В FS25 используются два отдельных пути:
--
-- 1) updateBalaceDirectlySoldOutputs()
--    Продукция, заданная в XML производства как sellDirectly="true".
--    Штатно выплачивается:
--        amount * marketPrice
--
-- 2) directlySellOutputs()
--    Режим выхода "Продажа", выбранный игроком в меню производства.
--    Штатно выплачивается:
--        DIRECT_SELL_PRICE_FACTOR(0.9) * amount * marketPrice
--
-- Мы сохраняем всю штатную логику и только дополнительно умножаем итоговую
-- цену на currentSellMultiplier. Никаких изменений pallet/buy pricing здесь нет.
local function getProductionPointDebugName(productionPoint)
	if productionPoint ~= nil and productionPoint.owningPlaceable ~= nil then
		local placeable = productionPoint.owningPlaceable
		if placeable.getName ~= nil then
			local name = placeable:getName()
			if name ~= nil and name ~= "" then
				return tostring(name)
			end
		end
	end

	return "UNKNOWN"
end


function DinamycalPrice.overwrittenProductionPointUpdateBalanceDirectlySoldOutputs(self, superFunc)
	-- Полностью повторяем штатную функцию ProductionPoint:updateBalaceDirectlySoldOutputs(),
	-- добавляя currentSellMultiplier непосредственно к выплате.
	if self.isOwned and self.isServer then
		for fillTypeId, amount in pairs(self.soldFillTypesToPayOut) do
			local moneyType = MoneyType.HARVEST_INCOME

			if g_fillTypeManager:getIsFillTypeInCategory(fillTypeId, "PRODUCT") then
				moneyType = MoneyType.SOLD_PRODUCTS
			elseif g_fillTypeManager:getIsFillTypeInCategory(fillTypeId, "PRODUCT_BGA") then
				moneyType = MoneyType.INCOME_BGA
			end

			if amount > 0 then
				local marketPricePerLiter =
					g_currentMission.economyManager:getPricePerLiter(fillTypeId)
				local finalPricePerLiter =
					marketPricePerLiter * currentSellMultiplier
				local revenue =
					amount * finalPricePerLiter

				self.mission:addMoney(
					revenue,
					self.ownerFarmId,
					moneyType,
					true
				)

				local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeId)

				logMessage(
					"[AUTO SELL]",
					string.format(
						"mode=XML_SELL_DIRECTLY production='%s' product='%s' fillType=%s amount=%.2f marketPricePerLiter=%.4f directSellFactor=1.0000 currentSellMultiplier=%.4f finalPricePerLiter=%.4f revenue=%.2f",
						getProductionPointDebugName(self),
						fillType ~= nil and tostring(fillType.title) or tostring(fillTypeId),
						tostring(fillTypeId),
						tonumber(amount) or 0,
						tonumber(marketPricePerLiter) or 0,
						currentSellMultiplier,
						tonumber(finalPricePerLiter) or 0,
						tonumber(revenue) or 0
					)
				)
			end

			self.soldFillTypesToPayOut[fillTypeId] = 0
		end
	end
end


function DinamycalPrice.overwrittenProductionPointDirectlySellOutputs(self, superFunc)
	-- Полностью повторяем штатную ProductionPoint:directlySellOutputs().
	-- Штатный DIRECT_SELL_PRICE_FACTOR (обычно 0.9) сохраняется и поверх него
	-- применяется currentSellMultiplier.
	for fillTypeId in pairs(self.outputFillTypeIdsDirectSell) do
		local amount = self.storage:getFillLevel(fillTypeId)

		if amount > 0 then
			local marketPricePerLiter =
				g_currentMission.economyManager:getPricePerLiter(fillTypeId)
			local directSellFactor =
				ProductionPoint.DIRECT_SELL_PRICE_FACTOR or 1
			local finalPricePerLiter =
				directSellFactor
				* marketPricePerLiter
				* currentSellMultiplier
			local revenue =
				amount * finalPricePerLiter

			self.mission:addMoney(
				revenue,
				self.ownerFarmId,
				MoneyType.SOLD_PRODUCTS,
				true
			)
			self.storage:setFillLevel(0, fillTypeId)

			local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeId)

			logMessage(
				"[AUTO SELL]",
				string.format(
					"mode=OUTPUT_MODE_SELL production='%s' product='%s' fillType=%s amount=%.2f marketPricePerLiter=%.4f directSellFactor=%.4f currentSellMultiplier=%.4f finalPricePerLiter=%.4f revenue=%.2f",
					getProductionPointDebugName(self),
					fillType ~= nil and tostring(fillType.title) or tostring(fillTypeId),
					tostring(fillTypeId),
					tonumber(amount) or 0,
					tonumber(marketPricePerLiter) or 0,
					tonumber(directSellFactor) or 0,
					currentSellMultiplier,
					tonumber(finalPricePerLiter) or 0,
					tonumber(revenue) or 0
				)
			)
		end
	end
end

-- Только техника. Placeable, hand tools и objects не затрагиваются.
function DinamycalPrice.overwrittenEconomyGetBuyPrice(self, superFunc, storeItem, configurations, saleItem)
	local price, upgradePrice = superFunc(self, storeItem, configurations, saleItem)

	if storeItem ~= nil
		and StoreSpecies ~= nil
		and storeItem.species == StoreSpecies.VEHICLE then
		price = MathUtil.round(price * currentBuyMultiplier, 0)
		upgradePrice = MathUtil.round((upgradePrice or 0) * currentBuyMultiplier, 0)
	end

	return price, upgradePrice
end

-- RefillDialog использует priceFactor и для UI, и для цены callback.
function DinamycalPrice.overwrittenRefillDialogSetFreeCapacities(self, superFunc, freeCapacities, priceFactor)
	return superFunc(self, freeCapacities, (priceFactor or 1) * currentBuyMultiplier)
end

-- Сервер перепроверяет цену палеты по своему экземпляру станции.
function DinamycalPrice.overwrittenPalletBuyEventRun(self, superFunc, connection)
	if connection ~= nil
		and not connection:getIsServer()
		and self.placeable ~= nil then

		-- Сервер является источником истины. Перед списанием ещё раз обновляем
		-- цену конкретной станции по нашей формуле и не доверяем palletPrice клиента.
		DinamycalPrice:updateSinglePlaceablePrice(self.placeable)

		if self.placeable.getEffectivePricePerPallet ~= nil then
			local serverPrice = self.placeable:getEffectivePricePerPallet(self.fillTypeIndex)

			if serverPrice ~= nil then
				logMessage(
					"[SYNC]",
					string.format(
						"PALLET BUY server validation: fillType=%s clientPrice=%s serverPrice=%s",
						tostring(self.fillTypeIndex),
						tostring(self.palletPrice),
						tostring(serverPrice)
					)
				)

				self.palletPrice = serverPrice
			end
		end
	end

	return superFunc(self, connection)
end

-- Мгновенная реакция на изменение экономической сложности.
-- FSBaseMission:setEconomicDifficulty вызывается и на сервере, и на клиентах
-- через SavegameSettingsEvent, поэтому cached pallet.price обновится сразу.
function DinamycalPrice.onEconomicDifficultyChanged(mission, economicDifficulty, noEventSend)
	if mission == nil or mission.missionInfo == nil then
		return
	end

	logMessage(
		"[DIFFICULTY]",
		string.format(
			"Economic difficulty changed: state=%s priceMultiplier=%.4f costMultiplier=%.4f",
			tostring(mission.missionInfo.economicDifficulty),
			EconomyManager.getPriceMultiplier(),
			EconomyManager.getCostMultiplier()
		)
	)

	-- Переоценка палет и прочих cached placeable prices без ожидания HOUR_CHANGED.
	if mission.placeableSystem ~= nil
		and mission.placeableSystem.placeables ~= nil then
		DinamycalPrice:updatePlaceablesPrices()
	end

	-- На сервере сразу пересчитываем и рассылаем наши глобальные множители.
	if mission:getIsServer() then
		DinamycalPrice:recalculateMultipliers()
		DinamycalPrice:broadcastMultipliers()
	end
end


-- Штатная точка initial sync нового клиента.
function DinamycalPrice.onSendInitialClientState(mission, connection, user, farm)
	if mission ~= nil and mission:getIsServer() and connection ~= nil then
		connection:sendEvent(
			DinamycalPriceSyncEvent.new(currentSellMultiplier, currentBuyMultiplier)
		)
		logMessage("[SYNC]", string.format(
			"SERVER initial client sync: sell=%.4f buy=%.4f",
			currentSellMultiplier, currentBuyMultiplier
		))
	end
end


--================================================================================================
-- Расчёт цены сделки с земельным участком.
-- Базовый farmland.price не изменяем: коэффициент применяется только к отображаемой
-- цене и к цене конкретного FarmlandStateEvent.
function DinamycalPrice:getFarmlandTransactionPrice(farmland, isSelling)
	if farmland == nil then
		return 0
	end

	local basePrice = farmland.price or 0
	local multiplier = isSelling and currentSellMultiplier or currentBuyMultiplier

	return MathUtil.round(basePrice * multiplier, 0)
end


--================================================================================================
-- Перехват создания события покупки/продажи участка.
-- В event.price записываем ту же цену, которую показываем игроку в интерфейсе.
function DinamycalPrice.overwrittenFarmlandStateEventNew(farmlandId, superFunc, farmId, ...)
	local event = superFunc(farmlandId, farmId, ...)

	if event == nil or g_farmlandManager == nil then
		return event
	end

	local farmland = g_farmlandManager:getFarmlandById(farmlandId)
	if farmland == nil then
		return event
	end

	local noOwnerFarmId = FarmlandManager.NO_OWNER_FARM_ID
	local oldOwnerFarmId = farmland.farmId or noOwnerFarmId

	local isBuying = oldOwnerFarmId == noOwnerFarmId and farmId ~= noOwnerFarmId
	local isSelling = oldOwnerFarmId ~= noOwnerFarmId and farmId == noOwnerFarmId

	if isBuying then
		local oldPrice = event.price
		event.price = DinamycalPrice:getFarmlandTransactionPrice(farmland, false)

		logMessage(
			"[FARMLAND]",
			string.format(
				"BUY id=%s base=%.2f eventPrice=%s -> %s buyMultiplier=%.4f",
				tostring(farmlandId),
				farmland.price or 0,
				tostring(oldPrice),
				tostring(event.price),
				currentBuyMultiplier
			)
		)

	elseif isSelling then
		local oldPrice = event.price
		event.price = DinamycalPrice:getFarmlandTransactionPrice(farmland, true)

		logMessage(
			"[FARMLAND]",
			string.format(
				"SELL id=%s base=%.2f eventPrice=%s -> %s sellMultiplier=%.4f",
				tostring(farmlandId),
				farmland.price or 0,
				tostring(oldPrice),
				tostring(event.price),
				currentSellMultiplier
			)
		)
	end

	return event
end

--================================================================================================
-- Корректировка фактической стоимости покупки и аренды транспорта/оборудования
function DinamycalPrice.overwrittenBuyVehicleUpdatePrice(self, superFunc)
	--====================================================================
	-- Покупка
	if not self.leaseVehicle then
		superFunc(self)
		if self.price ~= nil and self.price > 0 and currentBuyMultiplier > 0 then
			local oldPrice = self.price
			self.price = MathUtil.round(oldPrice * currentBuyMultiplier, 0)
			logMessage(
				"INFO",
				string.format(
					"SHOP BUY '%s': %s -> %s buyMultiplier=%.4f",
					self.storeItem ~= nil
						and tostring(self.storeItem.name)
						or "UNKNOWN",
					tostring(oldPrice),
					tostring(self.price),
					currentBuyMultiplier
				)
			)
		end
		return
	end

	--====================================================================
	-- Аренда. Сначала получаем полную стоимость техники. Затем применяем наш buyMultiplier. И только после этого считаем первоначальную стоимость аренды штатной функцией игры.
	local basePrice = g_currentMission.economyManager:getBuyPrice(self.storeItem, self.configurations, self.saleItem)
	local modifiedPrice = MathUtil.round(basePrice * currentBuyMultiplier, 0)
	self.price = g_currentMission.economyManager:getInitialLeasingPrice(modifiedPrice)
	logMessage(
		"INFO",
		string.format(
			"SHOP LEASE '%s': vehiclePrice=%s -> %s initialLease=%s buyMultiplier=%.4f",
			self.storeItem ~= nil
				and tostring(self.storeItem.name)
				or "UNKNOWN",
			tostring(basePrice),
			tostring(modifiedPrice),
			tostring(self.price),
			currentBuyMultiplier
		)
	)
	logMessage(
		"INFO",
		string.format(
			"SHOP VEHICLE: name='%s' calculatedPrice=%s lease=%s",
			self.storeItem ~= nil and tostring(self.storeItem.name) or "UNKNOWN",
			tostring(self.price),
			tostring(self.leaseVehicle)
		)
	)
end

--================================================================================================
-- Перехват интерфейса магазина при покупке техники
function DinamycalPrice.overwrittenShopUpdatePriceData(self, superFunc, ...)
	local result = superFunc(self, ...)

	if self.totalPrice ~= nil and self.totalPrice > 0 and currentBuyMultiplier ~= nil and currentBuyMultiplier > 0 then
		local oldPrice = self.totalPrice
		self.totalPrice = MathUtil.round(oldPrice * currentBuyMultiplier, 0)
		if self.totalPriceText ~= nil then
			self.totalPriceText:setText(g_i18n:formatMoney(self.totalPrice, 0, true, true))
		end
		logMessage(
			"INFO",
			string.format(
				"SHOP UI '%s': %s -> %s buyMultiplier=%.4f",
				self.storeItem ~= nil and tostring(self.storeItem.name) or "UNKNOWN",
				tostring(oldPrice),
				tostring(self.totalPrice),
				currentBuyMultiplier
			)
		)
	end
	return result
end

--================================================================================================
function DinamycalPrice:onDayChanged()
	logMessage("[EVENT]", "onDayChanged!")
	self:calculateTax()
end

--================================================================================================
function DinamycalPrice.init()
	logMessage("[EVENT]", "init...")
end


--================================================================================================
-- Корректировка отображаемой цены участка в окне карты.
-- Штатный setMapSelectionItem сначала полностью формирует contextBoxFarmland,
-- после чего меняем только текст цены. farmland.price остаётся неизменным.
function DinamycalPrice.withFarmlandTransactionPrice(frame, isSelling, callback, ...)
	if frame == nil or frame.selectedFarmland == nil then
		return callback(frame, ...)
	end

	local farmland = frame.selectedFarmland
	local basePrice = farmland.price
	farmland.price = DinamycalPrice:getFarmlandTransactionPrice(farmland, isSelling)

	local results = {callback(frame, ...)}
	farmland.price = basePrice
	return unpack(results)
end

function DinamycalPrice.overwrittenMapOnClickBuy(frame, superFunc, ...)
	return DinamycalPrice.withFarmlandTransactionPrice(frame, false, superFunc, ...)
end

function DinamycalPrice.overwrittenMapOnYesNoBuyFarmland(frame, superFunc, yes, ...)
	return DinamycalPrice.withFarmlandTransactionPrice(frame, false, superFunc, yes, ...)
end

function DinamycalPrice.overwrittenMapOnClickSell(frame, superFunc, ...)
	return DinamycalPrice.withFarmlandTransactionPrice(frame, true, superFunc, ...)
end

function DinamycalPrice.overwrittenMapOnYesNoSellFarmland(frame, superFunc, yes, ...)
	return DinamycalPrice.withFarmlandTransactionPrice(frame, true, superFunc, yes, ...)
end


function DinamycalPrice:installFarmlandUiHook()
	if self.farmlandUiHookInstalled then
		return
	end

	if InGameMenuMapFrame == nil or InGameMenuMapFrame.setMapSelectionItem == nil then
		return
	end

	local oldSetMapSelectionItem = InGameMenuMapFrame.setMapSelectionItem

	InGameMenuMapFrame.setMapSelectionItem = function(frame, item, ...)
		local result = oldSetMapSelectionItem(frame, item, ...)

		if item == nil or type(item) ~= "table" or item.farmland == nil or frame.contextBoxFarmland == nil then
			return result
		end

		local farmland = item.farmland
		local farmlandValue = frame.contextBoxFarmland:getDescendantByName("farmlandValue")

		if farmlandValue == nil then
			return result
		end

		local playerFarmId = nil
		if g_currentMission ~= nil then
			playerFarmId = g_currentMission:getFarmId()
		end

		-- Свой участок показываем по цене продажи, свободный — по цене покупки.
		-- Участок другой фермы не является доступной сделкой, поэтому его цену не меняем.
		local isSelling = playerFarmId ~= nil and farmland.farmId == playerFarmId
		local isFree = farmland.farmId == FarmlandManager.NO_OWNER_FARM_ID

		if isSelling or isFree then
			local transactionPrice = DinamycalPrice:getFarmlandTransactionPrice(farmland, isSelling)

			farmlandValue:setText(g_i18n:formatMoney(transactionPrice, 0, true, true))

			logMessage(
				"[FARMLAND]",
				string.format(
					"UI id=%s mode=%s base=%.2f shown=%s multiplier=%.4f",
					tostring(farmland.id),
					isSelling and "SELL" or "BUY",
					farmland.price or 0,
					tostring(transactionPrice),
					isSelling and currentSellMultiplier or currentBuyMultiplier
				)
			)
		end

		return result
	end

	self.farmlandUiHookInstalled = true
	logMessage("[EVENT]", "Farmland UI price hook installed")
end


--================================================================================================
-- По началу загрузки карты подписываемся на смену часа и ставим hook addPlaceable.
-- Utils.appendedFunction сохраняет стандартный PlaceableSystem.addPlaceable и
-- вызывает DinamycalPrice.onPlaceableAdded уже после штатной функции.

--================================================================================================
-- ДИАГНОСТИКА СИСТЕМЫ РОСТА
-- Только логирование: штатная логика GrowthSystem не изменяется.
--================================================================================================
function DinamycalPrice:onDiagnosticPeriodChanged(period, visualPeriod)
	if g_currentMission == nil or g_currentMission.environment == nil then
		return
	end

	local environment = g_currentMission.environment

	logMessage(
		"[GROWTH DEBUG]",
		string.format(
			"PERIOD_CHANGED RECEIVED BY MOD: period=%s visualPeriod=%s currentPeriod=%s currentDay=%s dayInPeriod=%s daysPerPeriod=%s",
			tostring(period),
			tostring(visualPeriod),
			tostring(environment.currentPeriod),
			tostring(environment.currentDay),
			tostring(environment.currentDayInPeriod),
			tostring(environment.daysPerPeriod)
		)
	)
end


function DinamycalPrice:installGrowthDiagnosticHooks()
	if self.growthDiagnosticHooksInstalled then
		return
	end

	if GrowthSystem == nil then
		logMessage("[GROWTH DEBUG]", "GrowthSystem is nil - hooks not installed")
		return
	end

	self.growthDiagnosticHooksInstalled = true

	if GrowthSystem.onPeriodChanged ~= nil then
		GrowthSystem.onPeriodChanged = Utils.overwrittenFunction(
			GrowthSystem.onPeriodChanged,
			function(growthSystem, superFunc, ...)
				local environment = growthSystem.environment
					or (g_currentMission ~= nil and g_currentMission.environment)
				local missionInfo = g_currentMission ~= nil and g_currentMission.missionInfo or nil

				logMessage(
					"[GROWTH DEBUG]",
					string.format(
						"onPeriodChanged ENTER: period=%s day=%s daysPerPeriod=%s growthMode=%s currentGrowthPeriod=%s queue=%s",
						tostring(environment ~= nil and environment.currentPeriod),
						tostring(environment ~= nil and environment.currentDay),
						tostring(environment ~= nil and environment.daysPerPeriod),
						tostring(missionInfo ~= nil and missionInfo.growthMode),
						tostring(growthSystem.currentGrowthPeriod),
						tostring(growthSystem.growthQueue ~= nil and #growthSystem.growthQueue or "nil")
					)
				)

				local result = {superFunc(growthSystem, ...)}

				logMessage(
					"[GROWTH DEBUG]",
					string.format(
						"onPeriodChanged EXIT: currentGrowthPeriod=%s queue=%s",
						tostring(growthSystem.currentGrowthPeriod),
						tostring(growthSystem.growthQueue ~= nil and #growthSystem.growthQueue or "nil")
					)
				)

				return unpack(result)
			end
		)
	else
		logMessage("[GROWTH DEBUG]", "GrowthSystem.onPeriodChanged not found")
	end

	if GrowthSystem.triggerGrowth ~= nil then
		GrowthSystem.triggerGrowth = Utils.overwrittenFunction(
			GrowthSystem.triggerGrowth,
			function(growthSystem, superFunc, period, ...)
				logMessage(
					"[GROWTH DEBUG]",
					string.format(
						"triggerGrowth ENTER: requestedPeriod=%s currentGrowthPeriod=%s queue=%s",
						tostring(period),
						tostring(growthSystem.currentGrowthPeriod),
						tostring(growthSystem.growthQueue ~= nil and #growthSystem.growthQueue or "nil")
					)
				)

				local result = {superFunc(growthSystem, period, ...)}

				logMessage(
					"[GROWTH DEBUG]",
					string.format(
						"triggerGrowth EXIT: requestedPeriod=%s currentGrowthPeriod=%s queue=%s",
						tostring(period),
						tostring(growthSystem.currentGrowthPeriod),
						tostring(growthSystem.growthQueue ~= nil and #growthSystem.growthQueue or "nil")
					)
				)

				return unpack(result)
			end
		)
	else
		logMessage("[GROWTH DEBUG]", "GrowthSystem.triggerGrowth not found")
	end

	if GrowthSystem.startEngineGrowth ~= nil then
		GrowthSystem.startEngineGrowth = Utils.overwrittenFunction(
			GrowthSystem.startEngineGrowth,
			function(growthSystem, superFunc, period, ...)
				local missionInfo = g_currentMission ~= nil and g_currentMission.missionInfo or nil

				logMessage(
					"[GROWTH DEBUG]",
					string.format(
						"startEngineGrowth ENTER: period=%s growthMode=%s currentGrowthPeriod=%s numEngineStepsActive=%s",
						tostring(period),
						tostring(missionInfo ~= nil and missionInfo.growthMode),
						tostring(growthSystem.currentGrowthPeriod),
						tostring(growthSystem.numEngineStepsActive)
					)
				)

				local result = {superFunc(growthSystem, period, ...)}

				logMessage(
					"[GROWTH DEBUG]",
					string.format(
						"startEngineGrowth EXIT: period=%s currentGrowthPeriod=%s numEngineStepsActive=%s",
						tostring(period),
						tostring(growthSystem.currentGrowthPeriod),
						tostring(growthSystem.numEngineStepsActive)
					)
				)

				return unpack(result)
			end
		)
	else
		logMessage("[GROWTH DEBUG]", "GrowthSystem.startEngineGrowth not found")
	end

	if GrowthSystem.onEngineGrowthFinished ~= nil then
		GrowthSystem.onEngineGrowthFinished = Utils.overwrittenFunction(
			GrowthSystem.onEngineGrowthFinished,
			function(growthSystem, superFunc, ...)
				logMessage(
					"[GROWTH DEBUG]",
					string.format(
						"onEngineGrowthFinished ENTER: currentGrowthPeriod=%s numEngineStepsActive=%s queue=%s",
						tostring(growthSystem.currentGrowthPeriod),
						tostring(growthSystem.numEngineStepsActive),
						tostring(growthSystem.growthQueue ~= nil and #growthSystem.growthQueue or "nil")
					)
				)

				local result = {superFunc(growthSystem, ...)}

				logMessage(
					"[GROWTH DEBUG]",
					string.format(
						"onEngineGrowthFinished EXIT: currentGrowthPeriod=%s numEngineStepsActive=%s queue=%s",
						tostring(growthSystem.currentGrowthPeriod),
						tostring(growthSystem.numEngineStepsActive),
						tostring(growthSystem.growthQueue ~= nil and #growthSystem.growthQueue or "nil")
					)
				)

				return unpack(result)
			end
		)
	else
		logMessage("[GROWTH DEBUG]", "GrowthSystem.onEngineGrowthFinished not found")
	end

	logMessage("[GROWTH DEBUG]", "GrowthSystem diagnostic hooks installed")
end


function DinamycalPrice:loadMap(name)
	logMessage("[EVENT]", "loadMap!")
	logMessage("[VERSION]", string.format("DinamycalPrice version=%s", tostring(self.version)))
	logMessage("[VERSION]", "Features: audited-pricing=ON auto-sell-multiplier=ON growth-debug=ON multiplayer-sync=ON daily-tax-delta=ON")

	if SellingStation ~= nil and SellingStation.getEffectiveFillTypePrice ~= nil and not self.sellingPriceHookInstalled then
		SellingStation.getEffectiveFillTypePrice = Utils.overwrittenFunction(
			SellingStation.getEffectiveFillTypePrice,
			DinamycalPrice.overwrittenSellingStationEffectivePrice
		)
		self.sellingPriceHookInstalled = true
		logMessage("[EVENT]", "SellingStation effective price hook installed")
	end

	if BuyingStation ~= nil and BuyingStation.getEffectiveFillTypePrice ~= nil and not self.buyingPriceHookInstalled then
		BuyingStation.getEffectiveFillTypePrice = Utils.overwrittenFunction(
			BuyingStation.getEffectiveFillTypePrice,
			DinamycalPrice.overwrittenBuyingStationEffectivePrice
		)
		self.buyingPriceHookInstalled = true
		logMessage("[EVENT]", "BuyingStation effective price hook installed")
	end

	if ProductionPoint ~= nil
		and ProductionPoint.updateBalaceDirectlySoldOutputs ~= nil
		and not self.productionPointXmlDirectSellHookInstalled then

		ProductionPoint.updateBalaceDirectlySoldOutputs = Utils.overwrittenFunction(
			ProductionPoint.updateBalaceDirectlySoldOutputs,
			DinamycalPrice.overwrittenProductionPointUpdateBalanceDirectlySoldOutputs
		)

		self.productionPointXmlDirectSellHookInstalled = true
		logMessage(
			"[EVENT]",
			"ProductionPoint sellDirectly XML auto-sell hook installed"
		)
	end

	if ProductionPoint ~= nil
		and ProductionPoint.directlySellOutputs ~= nil
		and not self.productionPointOutputSellHookInstalled then

		ProductionPoint.directlySellOutputs = Utils.overwrittenFunction(
			ProductionPoint.directlySellOutputs,
			DinamycalPrice.overwrittenProductionPointDirectlySellOutputs
		)

		self.productionPointOutputSellHookInstalled = true
		logMessage(
			"[EVENT]",
			"ProductionPoint output-mode auto-sell hook installed"
		)
	end

	if EconomyManager ~= nil and EconomyManager.getBuyPrice ~= nil and not self.economyBuyPriceHookInstalled then
		EconomyManager.getBuyPrice = Utils.overwrittenFunction(
			EconomyManager.getBuyPrice,
			DinamycalPrice.overwrittenEconomyGetBuyPrice
		)
		self.economyBuyPriceHookInstalled = true
		logMessage("[EVENT]", "EconomyManager vehicle buy price hook installed")
	end

	if RefillDialog ~= nil and RefillDialog.setFreeCapacities ~= nil and not self.refillDialogHookInstalled then
		RefillDialog.setFreeCapacities = Utils.overwrittenFunction(
			RefillDialog.setFreeCapacities,
			DinamycalPrice.overwrittenRefillDialogSetFreeCapacities
		)
		self.refillDialogHookInstalled = true
		logMessage("[EVENT]", "RefillDialog priceFactor hook installed")
	end

	if InGameMenuStatisticsFrame ~= nil
		and InGameMenuStatisticsFrame.populateCellForItemInSection ~= nil
		and not self.statisticsPalletPriceUiHookInstalled then

		InGameMenuStatisticsFrame.populateCellForItemInSection =
			Utils.appendedFunction(
				InGameMenuStatisticsFrame.populateCellForItemInSection,
				DinamycalPrice.onStatisticsPriceCellPopulated
			)

		self.statisticsPalletPriceUiHookInstalled = true
		logMessage("[EVENT]", "PalletBuyingStation price-table /1000L display hook installed")
	end

	if PlaceablePalletBuyingStation ~= nil
		and PlaceablePalletBuyingStation.onLoad ~= nil
		and not self.palletBuyingStationLoadHookInstalled then

		PlaceablePalletBuyingStation.onLoad = Utils.appendedFunction(
			PlaceablePalletBuyingStation.onLoad,
			DinamycalPrice.onPalletBuyingStationLoaded
		)
		self.palletBuyingStationLoadHookInstalled = true
		logMessage("[EVENT]", "PlaceablePalletBuyingStation XML priceScale capture hook installed")
	end

	if PlaceablePalletBuyEvent ~= nil and PlaceablePalletBuyEvent.run ~= nil and not self.palletBuyEventHookInstalled then
		PlaceablePalletBuyEvent.run = Utils.overwrittenFunction(
			PlaceablePalletBuyEvent.run,
			DinamycalPrice.overwrittenPalletBuyEventRun
		)
		self.palletBuyEventHookInstalled = true
		logMessage("[EVENT]", "PlaceablePalletBuyEvent server validation hook installed")
	end

	self:installFarmlandUiHook()

	if InGameMenuMapFrame ~= nil and not self.farmlandActionHooksInstalled then
		InGameMenuMapFrame.onClickBuy = Utils.overwrittenFunction(
			InGameMenuMapFrame.onClickBuy, DinamycalPrice.overwrittenMapOnClickBuy
		)
		InGameMenuMapFrame.onYesNoBuyFarmland = Utils.overwrittenFunction(
			InGameMenuMapFrame.onYesNoBuyFarmland, DinamycalPrice.overwrittenMapOnYesNoBuyFarmland
		)
		InGameMenuMapFrame.onClickSell = Utils.overwrittenFunction(
			InGameMenuMapFrame.onClickSell, DinamycalPrice.overwrittenMapOnClickSell
		)
		InGameMenuMapFrame.onYesNoSellFarmland = Utils.overwrittenFunction(
			InGameMenuMapFrame.onYesNoSellFarmland, DinamycalPrice.overwrittenMapOnYesNoSellFarmland
		)
		self.farmlandActionHooksInstalled = true
		logMessage("[EVENT]", "Farmland transaction action hooks installed")
	end

	-- Fallback для событий земли, созданных не через InGameMenuMapFrame.
	if FarmlandStateEvent ~= nil and FarmlandStateEvent.new ~= nil and not self.farmlandEventHookInstalled then
		FarmlandStateEvent.new = Utils.overwrittenFunction(
			FarmlandStateEvent.new, DinamycalPrice.overwrittenFarmlandStateEventNew
		)
		self.farmlandEventHookInstalled = true
		logMessage("[EVENT]", "FarmlandStateEvent fallback price hook installed")
	end

	if FSBaseMission ~= nil
		and FSBaseMission.setEconomicDifficulty ~= nil
		and not self.economicDifficultyHookInstalled then

		FSBaseMission.setEconomicDifficulty = Utils.appendedFunction(
			FSBaseMission.setEconomicDifficulty,
			DinamycalPrice.onEconomicDifficultyChanged
		)

		self.economicDifficultyHookInstalled = true
		logMessage("[EVENT]", "FSBaseMission economic difficulty hook installed")
	end

	if FSBaseMission ~= nil and FSBaseMission.sendInitialClientState ~= nil and not self.initialClientSyncHookInstalled then
		FSBaseMission.sendInitialClientState = Utils.appendedFunction(
			FSBaseMission.sendInitialClientState, DinamycalPrice.onSendInitialClientState
		)
		self.initialClientSyncHookInstalled = true
		logMessage("[EVENT]", "FSBaseMission initial client sync hook installed")
	end

	if g_currentMission ~= nil and g_currentMission:getIsServer() then
		self:installGrowthDiagnosticHooks()
		g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onDiagnosticPeriodChanged, self)
		logMessage("[GROWTH DEBUG]", "Subscribed diagnostic listener to PERIOD_CHANGED")

		g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.calculateChanged, self)
		logMessage("[EVENT]", "Subscribed to HOUR_CHANGED")

		g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
		logMessage("[EVENT]", "Subscribed to DAY_CHANGED")

		self:initializeTaxSalesBaseline()

		if not DinamycalPrice.placeableHookInstalled then
			PlaceableSystem.addPlaceable = Utils.appendedFunction(
				PlaceableSystem.addPlaceable, DinamycalPrice.onPlaceableAdded
			)
			DinamycalPrice.placeableHookInstalled = true
			logMessage("[EVENT]", "PlaceableSystem.addPlaceable hook installed")
		end
	else
		logMessage("[EVENT]", "CLIENT mode: waiting for synchronized multipliers")
	end
end

--================================================================================================
addModEventListener(DinamycalPrice)
DinamycalPrice.init()
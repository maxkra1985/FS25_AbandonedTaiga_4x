CustomMapHotspots = {}

CustomMapHotspots.customIcons = {}

-- Размер иконки строительной площадки относительно штатного PlaceableHotspot.
-- Значение 1.0 сохраняет стандартный размер около 50x50 px.
CustomMapHotspots.CONSTRUCTION_SITE_SCALE = 1.0


-- Возвращает следующий свободный числовой идентификатор типа hotspot.
-- Это позволяет не привязываться жёстко к конкретному ID из игры.
local function getNextHotspotTypeId()
	local maxId = 0

	for _, typeId in pairs(PlaceableHotspot.TYPE) do
		if type(typeId) == "number" then
			maxId = math.max(maxId, typeId)
		end
	end

	return maxId + 1
end


-- Регистрирует новый тип hotspot для строительной площадки.
-- По категории он остаётся производством, поэтому работает через штатный
-- фильтр производств на карте.
local function registerConstructionSiteHotspot()
	local typeId = getNextHotspotTypeId()

	PlaceableHotspot.TYPE.CONSTRUCTION_SITE = typeId

	-- Строительные площадки остаются в штатной категории производств.
	PlaceableHotspot.CATEGORY_MAPPING[typeId] = MapHotspot.CATEGORY_PRODUCTION

	-- Штатный production slice используется как резервный вариант.
	-- Он необходим, потому что PlaceableHotspot сначала создаёт обычную
	-- иконку через createIcon(), а уже затем вызывается setPlaceableType().
	PlaceableHotspot.SLICE[typeId] = PlaceableHotspot.SLICE[PlaceableHotspot.TYPE.PRODUCTION_POINT]

	-- Маленький hotspot на minimap пока оставляем таким же по цвету,
	-- как обычное производство.
	local color = PlaceableHotspot.COLOR[PlaceableHotspot.TYPE.PRODUCTION_POINT]

	PlaceableHotspot.COLOR[typeId] = {
		color[1],
		color[2],
		color[3],
		color[4]
	}

	-- Путь сохраняется сразу при загрузке скрипта, пока
	-- g_currentModDirectory указывает на каталог карты.
	CustomMapHotspots.customIcons[typeId] = g_currentModDirectory .. "markerIcons/constructionSite.dds"
end


-- Регистрирует отдельный тип hotspot для деревоперерабатывающих производств.
-- Тип остаётся в штатной категории производств, но получает собственную
-- древесно-коричневую цветовую гамму и пиктограмму дерева с брёвнами.
local function registerProductionWoodHotspot()
	local typeId = getNextHotspotTypeId()

	PlaceableHotspot.TYPE.PRODUCTION_WOOD = typeId
	PlaceableHotspot.CATEGORY_MAPPING[typeId] = MapHotspot.CATEGORY_PRODUCTION

	-- Штатный production slice используется как безопасный резервный вариант
	-- до момента подмены большой иконки нашей текстурой.
	PlaceableHotspot.SLICE[typeId] = PlaceableHotspot.SLICE[PlaceableHotspot.TYPE.PRODUCTION_POINT]

	-- Цвет применяется и к большой пользовательской иконке, и к маленькому
	-- hotspot на minimap. Значения подобраны в тёплой древесной гамме.
	PlaceableHotspot.COLOR[typeId] = {
		0.45,
		0.20,
		0.055,
		1
	}

	CustomMapHotspots.customIcons[typeId] = g_currentModDirectory .. "markerIcons/productionWood.dds"
end


-- Подменяет большую иконку карты только для зарегистрированных
-- пользовательских типов hotspot.
-- Штатная логика PlaceableHotspot вызывается первой и остаётся неизменной.
function CustomMapHotspots.setPlaceableType(
	self,
	superFunc,
	placeableType
)
	superFunc(self, placeableType)

	local filename = CustomMapHotspots.customIcons[placeableType]

	if filename == nil then
		return
	end

	if not fileExists(filename) then
		Logging.warning("CustomMapHotspots: hotspot icon not found '%s'", filename)
		return
	end

	local iconScale = 1

	if placeableType == PlaceableHotspot.TYPE.CONSTRUCTION_SITE then
		iconScale = CustomMapHotspots.CONSTRUCTION_SITE_SCALE
	end

	if self.icon ~= nil then
		self.icon:delete()
		self.icon = nil
	end

	-- Большая пользовательская иконка получает собственную текстуру.
	-- iconSmall для minimap остаётся штатным и использует только цвет типа.
	self.icon = Overlay.new(
		filename,
		0,
		0,
		self.width * iconScale,
		self.height * iconScale
	)

	if self.icon ~= nil then
		self.icon:setColor(unpack(self.color))
		self.icon:setScale(self.scale, self.scale)

		-- getDimension() у PlaceableHotspot ориентируется на lastRenderedIcon.
		-- Назначаем новую иконку сразу, чтобы карта учитывала её фактический
		-- размер при первичном позиционировании.
		self.lastRenderedIcon = self.icon
	end
end


registerConstructionSiteHotspot()
registerProductionWoodHotspot()

-- Расширяем штатный setPlaceableType, не заменяя его логику целиком.
PlaceableHotspot.setPlaceableType = Utils.overwrittenFunction(PlaceableHotspot.setPlaceableType, CustomMapHotspots.setPlaceableType)

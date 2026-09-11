-- Average Enjoyer ^ω^ Lampovo Project
-- vk.com/lampovofs

licensePlatesStandalone = {}
licensePlatesStandalone.modDir = g_currentModDirectory

LicensePlateManager.loadMapData = Utils.overwrittenFunction(LicensePlateManager.loadMapData, function (self, superFunc, xmlFile, missionInfo, baseDirectory)
	local xmlFilename = Utils.getFilename('map/russianLicensePlates/fonts.xml', licensePlatesStandalone.modDir)
	g_materialManager:loadFontMaterialsXML(xmlFilename, nil, licensePlatesStandalone.modDir)

	LicensePlateManager:superClass().loadMapData(self, xmlFile, missionInfo, baseDirectory)

	LicensePlateManager.createLicensePlateXMLSchema()

	local filename = getXMLString(xmlFile, "map.licensePlates#filename")
	if filename ~= nil then
		self.xmlFilename = Utils.getFilename('map/russianLicensePlates/licensePlates.xml', licensePlatesStandalone.modDir)
		self.licensePlateXML = XMLFile.load("mapLicensePlates", self.xmlFilename, LicensePlateManager.xmlSchema)
		if self.licensePlateXML ~= nil then
			self.xmlReferences = 0
			self:loadLicensePlatesFromXML(self.licensePlateXML, licensePlatesStandalone.modDir)

			if self.licensePlateXML ~= nil and self.xmlReferences == 0 then
				self.licensePlateXML:delete()
				self.licensePlateXML = nil
			end
		end
	end

	return true
end)

LicensePlateDialog.updateVariations = Utils.overwrittenFunction(LicensePlateDialog.updateVariations, function (self, superFunc)
	local texts = {}

	for i = 1, #self.licensePlate.variations do
		local typeText = g_i18n:getText("ui_licensePlateType" .. i)
		table.insert(texts, typeText)
	end

	self.typeOption:setTexts(texts)
	self.typeOption:setState(self.currentVariation)
end)

LicensePlates.onLoad = Utils.overwrittenFunction(LicensePlates.onLoad, function (self, superFunc, savegame)
	local spec = self.spec_licensePlates

	spec.licensePlates = {}
	local defaultPlacementName = self.xmlFile:getValue("vehicle.licensePlates#defaultPlacement")
	if defaultPlacementName ~= nil then
		spec.defaultPlacementIndex = LicensePlateManager.PLACEMENT_OPTION[defaultPlacementName:upper()]
	end

	if g_licensePlateManager:getAreLicensePlatesAvailable() then
		local i = 0
		while true do
			local plateKey = string.format("vehicle.licensePlates.licensePlate(%d)", i)
			if not self.xmlFile:hasProperty(plateKey) then
				break
			end

			local licensePlate = {}

			licensePlate.node = self.xmlFile:getValue(plateKey .. "#node", nil, self.components, self.i3dMappings)
			if licensePlate.node ~= nil then
				local positionStr = self.xmlFile:getValue(plateKey .. "#position", "ANY")
				licensePlate.position = LicensePlateManager.PLATE_POSITION[positionStr]
				if positionStr ~= nil then
					local preferedTypeStr = self.xmlFile:getValue(plateKey .. "#preferedType", "ELONGATED")
					licensePlate.preferedType = LicensePlateManager.PLATE_TYPE[preferedTypeStr]

					if licensePlate.preferedType ~= nil then
						licensePlate.placementArea = {1, 1, 1, 1}
						self.type = self.xmlFile:getValue ("vehicle.base.mapHotspot#type", "OTHER")
						if licensePlate.preferedType == LicensePlateManager.PLATE_TYPE.ELONGATED then
							placementAreaString = "0.06 0.265 0.07 0.265"
						elseif licensePlate.preferedType == LicensePlateManager.PLATE_TYPE.SQUARISH and self.type ~= "TRUCK" and self.type ~= "CAR" then
							placementAreaString = "0.11 0.15 0.1 0.15"
						else
							placementAreaString = "0.09 0.15 0.1 0.15"
						end
						if placementAreaString ~= nil then
							local placementArea = string.split(placementAreaString, " ")
							if #placementArea == 4 then
								for j=1, 4 do
									if placementArea[j] ~= "-" then
										local numberValue = tonumber(placementArea[j])
										if numberValue == nil then
											Logging.xmlWarning(self.xmlFile, "Invalid 4-vector '%s' for '%s'. '%s' is not a number!", placementAreaString, plateKey .. "#placementArea", placementArea[j])
											else
											licensePlate.placementArea[j] = numberValue
										end
									end
								end
								else
								Logging.xmlWarning(self.xmlFile, "Invalid 4-vector '%s' for '%s' ", placementAreaString, plateKey .. "#placementArea")
							end
						end

						local includeFrame = self.xmlFile:getValue(plateKey .. "#frame", true)

						licensePlate.data = g_licensePlateManager:getLicensePlate(licensePlate.preferedType, includeFrame)
						if licensePlate.data ~= nil then
							link(licensePlate.node, licensePlate.data.node)
							setTranslation(licensePlate.data.node, 0, 0, 0)
							setRotation(licensePlate.data.node, 0, 0, 0)
							setVisibility(licensePlate.data.node, false)

							local widthPos = licensePlate.data.rawWidth * 0.5 + licensePlate.data.widthOffsetLeft
							local widthNeg = licensePlate.data.rawWidth * 0.5 + licensePlate.data.widthOffsetRight
							local heightPos = licensePlate.data.rawHeight * 0.5 + licensePlate.data.heightOffsetTop
							local heightNeg = licensePlate.data.rawHeight * 0.5 + licensePlate.data.heightOffsetBot

							local scaleFactorWidth = (licensePlate.placementArea[2] + licensePlate.placementArea[4]) / (widthPos + widthNeg)
							local scaleFactorHeight = (licensePlate.placementArea[1] + licensePlate.placementArea[3]) / (heightPos + heightNeg)
							local minFactor = math.clamp(math.min(scaleFactorWidth, scaleFactorHeight), 0, 1)
							if minFactor < 1 then
								setScale(licensePlate.data.node, minFactor, minFactor, minFactor)

								widthPos = widthPos * minFactor
								widthNeg = widthNeg * minFactor
								heightPos = heightPos * minFactor
								heightNeg = heightNeg * minFactor
							end

							local moveX, moveY = 0, 0
							moveX = moveX - math.max(widthPos - licensePlate.placementArea[2], 0)
							moveX = moveX + math.max(widthNeg - licensePlate.placementArea[4], 0)
							moveY = moveY - math.max(heightPos - licensePlate.placementArea[1], 0)
							moveY = moveY + math.max(heightNeg - licensePlate.placementArea[3], 0)
							setTranslation(licensePlate.data.node, moveX, moveY, 0)

							licensePlate.changeObjects = {}
							ObjectChangeUtil.loadObjectChangeFromXML(self.xmlFile, plateKey, licensePlate.changeObjects, self.components, self)

							table.insert(spec.licensePlates, licensePlate)
						end
						else
						Logging.xmlError(self.xmlFile, "Unknown preferedType '%s' for license plate '%s'", preferedTypeStr, plateKey)
					end
				end
			end

			i = i + 1
		end

		if self:getHasLicensePlates() then
			spec.licensePlateData = {variation=1, characters=nil, colorIndex=nil}
		end
		else
		ObjectChangeUtil.updateObjectChanges(self.xmlFile, "vehicle.licensePlates.licensePlate", -1, self.components, self)
	end
end)
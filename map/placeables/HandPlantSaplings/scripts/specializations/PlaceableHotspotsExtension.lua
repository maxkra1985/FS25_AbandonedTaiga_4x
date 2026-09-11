--[[
Copyright (C) GtX (Andy), 2021

Author: GtX | Andy
Date: 11.01.2021
Revision: FS25-01

Contact:
https://forum.giants-software.com
https://github.com/GtX-Andy/FS25_PlaceableHotspotsExtension

Important:
Free for use in mods (FS25 Only) - no permission needed.
No modifications may be made to this script, including conversion to other game versions without written permission from GtX | Andy
Copying or removing any part of this code for external use without written permission from GtX | Andy is prohibited.

Frei verwendbar (Nur LS25) - keine erlaubnis nötig
Ohne schriftliche Genehmigung von GtX | Andy dürfen keine Änderungen an diesem Skript vorgenommen werden, einschließlich der Konvertierung in andere Spielversionen
Das Kopieren oder Entfernen irgendeines Teils dieses Codes zur externen Verwendung ohne schriftliche Genehmigung von GtX | Andy ist verboten.
]]


PlaceableHotspotsExtension = {}

PlaceableHotspotsExtension.MOD_NAME = g_currentModName
PlaceableHotspotsExtension.SPEC_NAME = string.format("spec_%s.hotspotsExtension", g_currentModName)

function PlaceableHotspotsExtension.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(PlaceableHotspots, specializations)
end

function PlaceableHotspotsExtension.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onPreLoad", PlaceableHotspotsExtension)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableHotspotsExtension)
end

function PlaceableHotspotsExtension.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("HotspotsExtension")

    schema:register(XMLValueType.STRING, basePath .. ".hotspots.hotspot(?).customType#name", "Custom type name")
    schema:register(XMLValueType.STRING, basePath .. ".hotspots.hotspot(?).customType#filename", "Image filename")
    schema:register(XMLValueType.STRING, basePath .. ".hotspots.hotspot(?).customType#customEnv", "Custom mod environment when a different base directory is required")
    schema:register(XMLValueType.STRING, basePath .. ".hotspots.hotspot(?).customType#imageUVs", "Image UVs when using filename", "- - - -")
    schema:register(XMLValueType.STRING, basePath .. ".hotspots.hotspot(?).customType#sliceId", "Slice identifier instead of a filename.")
    schema:register(XMLValueType.STRING, basePath .. ".hotspots.hotspot(?).customType#sliceIdCustomEnv", "Slice identifier custom environment if required")
    schema:register(XMLValueType.VECTOR_2, basePath .. ".hotspots.hotspot(?).customType#imageResolution", "Image Resolution", "1024 512")
    schema:register(XMLValueType.STRING, basePath .. ".hotspots.hotspot(?).customType#category", "Placeable hotspot category, this will be used for filtering visible icons etc on the in-game map", "OTHER")

    schema:setXMLSpecializationType()
end

function PlaceableHotspotsExtension:onPreLoad(savegame)
    self.spec_hotspotsExtension = self[PlaceableHotspotsExtension.SPEC_NAME]

    if self.spec_hotspotsExtension ~= nil then
        SpecializationUtil.removeEventListener(self, "onLoad", PlaceableHotspots)
    else
        Logging.error("[%s] Specialization with name 'hotspotsExtension' was not found in modDesc!", PlaceableHotspotsExtension.MOD_NAME)
    end
end

function PlaceableHotspotsExtension:onLoad(savegame)
    local spec = self.spec_hotspotsExtension

    if spec ~= nil then
        local hotspotsSpec = self.spec_hotspots
        local xmlFile = self.xmlFile

        -- Make sure old hotspots do not exist.
        if hotspotsSpec.mapHotspots ~= nil then
            for _, hotspot in ipairs(hotspotsSpec.mapHotspots) do
                g_currentMission:removeMapHotspot(hotspot)
                hotspot:delete()
            end
        end

        hotspotsSpec.mapHotspots = {}

        xmlFile:iterate("placeable.hotspots.hotspot", function(_, key)
            local hotspot = PlaceableHotspot.new()

            local customTypeName = xmlFile:getValue(key .. ".customType#name")
            local customFilename = xmlFile:getValue(key .. ".customType#filename")
            local customImageUVs = xmlFile:getValue(key .. ".customType#imageUVs")

            local sliceId = xmlFile:getValue(key .. ".customType#sliceId")
            local sliceIdCustomEnv = xmlFile:getValue(key .. ".customType#sliceIdCustomEnv")

            local loadFromFilename = customFilename ~= nil and customImageUVs ~= nil
            local loadFromSpliceId = sliceId ~= nil

            hotspot:setPlaceable(self)

            if customTypeName ~= nil and (loadFromFilename or loadFromSpliceId) then
                local customImageResolution = xmlFile:getValue(key .. ".customType#imageResolution", "1024 512", true)

                local categoryName = xmlFile:getValue(key .. ".customType#category", "OTHER")
                local category = MapHotspot["CATEGORY_" .. categoryName:upper()]

                if category == nil then
                    category = MapHotspot.CATEGORY_OTHER
                end

                if loadFromFilename then
                    local customImageCustomEnv = xmlFile:getValue(key .. ".customType#customEnv", "")
                    local baseDirectory = self.baseDirectory

                    if customImageCustomEnv ~= "" and customImageCustomEnv ~= self.customEnvironment then
                        local newBaseDirectory = g_modNameToDirectory[customImageCustomEnv]

                        if newBaseDirectory ~= nil then
                            baseDirectory = newBaseDirectory
                        end
                    end

                    customImageUVs = string.getVector(customImageUVs, 4)
                    customFilename = Utils.getFilename(customFilename, baseDirectory)

                    hotspot.customFilename = customFilename
                    hotspot.customImageResolution = customImageResolution
                end

                hotspot.sliceId = sliceId
                hotspot.sliceIdCustomEnv = sliceIdCustomEnv

                hotspot.customTypeName = customTypeName:upper()
                hotspot.placeableType = PlaceableHotspot.TYPE.EXCLAMATION_MARK

                hotspot.setPlaceableType = function(_, placeableType)
                    hotspot.placeableType = PlaceableHotspot.TYPE.EXCLAMATION_MARK

                    if loadFromFilename and hotspot.icon ~= nil then
                        hotspot.icon:setUVs(GuiUtils.getUVs(customImageUVs, customImageResolution))
                    end
                end

                hotspot.createIcon = function()
                    if hotspot.icon ~= nil then
                        hotspot.icon:delete()
                        hotspot.icon = nil
                    end

                    if loadFromFilename then
                        hotspot.icon = Overlay.new(customFilename, 0, 0, hotspot.width, hotspot.height)

                        if hotspot.icon ~= nil then
                            hotspot.icon:setUVs(GuiUtils.getUVs(customImageUVs, customImageResolution))
                        end
                    elseif loadFromSpliceId then
                        hotspot.icon = g_overlayManager:createOverlay(sliceId, 0, 0, hotspot.width, hotspot.height, sliceIdCustomEnv)
                    end

                    if hotspot.icon ~= nil then
                        hotspot.icon:setColor(unpack(hotspot.color))
                        hotspot.icon:setScale(hotspot.scale, hotspot.scale)
                    end
                end

                hotspot.getCategory = function()
                    return category
                end

                hotspot:createIcon()
            else
                local hotspotTypeName = self.xmlFile:getValue(key .. "#type", "EXCLAMATION_MARK")
                local hotspotType = PlaceableHotspot.getTypeByName(hotspotTypeName)

                if hotspotType == nil then
                    Logging.xmlWarning(self.xmlFile, "Unknown placeable hotspot type '%s'. Falling back to type 'EXCLAMATION_MARK'\nAvailable types: %s", hotspotTypeName, table.concatKeys(PlaceableHotspot.TYPE, " "))
                    hotspotType = PlaceableHotspot.TYPE.EXCLAMATION_MARK
                end

                hotspot:setPlaceableType(hotspotType)
            end

            local linkNode = self.xmlFile:getValue(key .. "#linkNode", nil, self.components, self.i3dMappings) or self.rootNode

            if linkNode ~= nil then
                local x, _, z = getWorldTranslation(linkNode)
                hotspot:setWorldPosition(x, z)
            end

            local teleportNode = self.xmlFile:getValue(key .. "#teleportNode", nil, self.components, self.i3dMappings)

            if teleportNode ~= nil then
                local x, y, z = getWorldTranslation(teleportNode)
                hotspot:setTeleportWorldPosition(x, y, z)
            end

            local worldPositionX, worldPositionZ = self.xmlFile:getValue(key .. "#worldPosition", nil)

            if worldPositionX ~= nil then
                hotspot:setWorldPosition(worldPositionX, worldPositionZ)
            end

            local teleportX, teleportY, teleportZ = self.xmlFile:getValue(key .. "#teleportWorldPosition", nil)

            if teleportX ~= nil then
                if g_currentMission ~= nil then
                    teleportY = math.max(teleportY, getTerrainHeightAtWorldPos(g_currentMission.terrainRootNode, teleportX, 0, teleportZ))
                end

                hotspot:setTeleportWorldPosition(teleportX, teleportY, teleportZ)
            end

            local text = self.xmlFile:getValue(key.."#text", nil)

            if text ~= nil then
                text = g_i18n:convertText(text, self.customEnvironment)
                hotspot:setName(text)
            end

            table.insert(hotspotsSpec.mapHotspots, hotspot)
        end)
    end
end

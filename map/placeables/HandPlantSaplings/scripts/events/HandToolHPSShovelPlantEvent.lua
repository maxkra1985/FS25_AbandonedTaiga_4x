--[[
Copyright (C) GtX (Andy), 2018

Author: GtX | Andy
Date: 15.03.2018
Revision: FS25-01

Contact:
https://forum.giants-software.com
https://github.com/GtX-Andy

Important:
Not to be added to any mods / maps or modified from its current release form.
No modifications may be made to this script, including conversion to other game versions without written permission from GtX | Andy
Copying or removing any part of this code for external use without written permission from GtX | Andy is prohibited.

Darf nicht zu Mods / Maps hinzugefügt oder von der aktuellen Release-Form geändert werden.
Ohne schriftliche Genehmigung von GtX | Andy dürfen keine Änderungen an diesem Skript vorgenommen werden, einschließlich der Konvertierung in andere Spielversionen
Das Kopieren oder Entfernen irgendeines Teils dieses Codes zur externen Verwendung ohne schriftliche Genehmigung von GtX | Andy ist verboten.
]]

HandToolHPSShovelPlantEvent = {}

local HandToolHPSShovelPlantEvent_mt = Class(HandToolHPSShovelPlantEvent, Event)
InitEventClass(HandToolHPSShovelPlantEvent, "HandToolHPSShovelPlantEvent")

function HandToolHPSShovelPlantEvent.emptyNew()
    return Event.new(HandToolHPSShovelPlantEvent_mt)
end

function HandToolHPSShovelPlantEvent.new(handTool, x, y, z)
    local self = HandToolHPSShovelPlantEvent.emptyNew()

    self.handTool = handTool

    self.x = x
    self.y = y
    self.z = z

    return self
end

function HandToolHPSShovelPlantEvent:readStream(streamId, connection)
    self.handTool = NetworkUtil.readNodeObject(streamId)

    self.x = streamReadFloat32(streamId)
    self.y = streamReadFloat32(streamId)
    self.z = streamReadFloat32(streamId)

    self:run(connection)
end

function HandToolHPSShovelPlantEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.handTool)

    streamWriteFloat32(streamId, self.x)
    streamWriteFloat32(streamId, self.y)
    streamWriteFloat32(streamId, self.z)
end

function HandToolHPSShovelPlantEvent:run(connection)
    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.handTool)
    end

    if self.handTool ~= nil and self.handTool:getIsSynchronized() then
        self.handTool:shovelCreateTree(self.x, self.y, self.z, true)
    end
end

function HandToolHPSShovelPlantEvent.sendEvent(handTool, x, y, z, noEventSend)
    if noEventSend == nil or noEventSend == false then
        if g_server ~= nil then
            g_server:broadcastEvent(HandToolHPSShovelPlantEvent.new(handTool, x, y, z), nil, nil, handTool)
        else
            g_client:getServerConnection():sendEvent(HandToolHPSShovelPlantEvent.new(handTool, x, y, z))
        end
    end
end

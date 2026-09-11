local function onMissionStart()
	if g_treePlantManager ~= nil then
		g_treePlantManager.maxNumTrees = 130000
		Logging.info("Лимит деревьев установлен в 130 000")
	else
		Logging.warn("g_treePlantManager не найден!")
	end
end

g_messageCenter:subscribeOneshot(MessageType.CURRENT_MISSION_START, onMissionStart)

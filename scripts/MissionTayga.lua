--[[
    Abandoned Taiga - MissionTayga

    Класс миссии карты. Наследует штатный Mission00 и служит центральной
    точкой для глобальных систем карты, которым нужен lifecycle миссии.
]]

MissionTayga = {}
local MissionTayga_mt = Class(MissionTayga, Mission00)

MissionTayga.MAX_NUM_TREES = 130000


-- Создаёт экземпляр миссии карты, сохраняя полный штатный lifecycle Mission00.
function MissionTayga.new(baseDirectory, customMt)
    return MissionTayga:superClass().new(baseDirectory, customMt or MissionTayga_mt)
end


-- Запускает миссию и до штатного события CURRENT_MISSION_START применяет
-- увеличенный лимит деревьев карты. Благодаря этому TreePlantManager и другие
-- подписчики события сразу получают окончательное значение лимита.
function MissionTayga:onStartMission()
    if g_treePlantManager ~= nil then
        g_treePlantManager.maxNumTrees = MissionTayga.MAX_NUM_TREES
        Logging.info("Лимит деревьев установлен в 130 000")
    else
        Logging.warning("MissionTayga: g_treePlantManager не найден")
    end

    MissionTayga:superClass().onStartMission(self)
end

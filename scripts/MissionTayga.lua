--[[
    Abandoned Taiga - MissionTayga

    Минимальный класс миссии карты. Наследует штатный Mission00 без изменения
    его поведения и служит точкой расширения для будущих глобальных систем карты.
]]

MissionTayga = {}
local MissionTayga_mt = Class(MissionTayga, Mission00)


-- Создаёт экземпляр миссии карты, сохраняя полный штатный lifecycle Mission00.
function MissionTayga.new(baseDirectory, customMt)
    return MissionTayga:superClass().new(baseDirectory, customMt or MissionTayga_mt)
end

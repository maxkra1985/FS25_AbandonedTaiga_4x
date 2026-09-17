--[[
    LoggingContractorJob

    Серверное состояние заключённого договора на лесоповал.

    На текущем этапе задача хранит зафиксированные при заключении параметры
    договора и счётчики будущего выполнения. Само периодическое спиливание
    деревьев будет добавлено следующим этапом.
]]

LoggingContractorJob = {}
local LoggingContractorJob_mt = Class(LoggingContractorJob)

LoggingContractorJob.STATE_ACTIVE = 1
LoggingContractorJob.STATE_FINISHED = 2


-- Создаёт состояние заключённого договора из уже проверенных сервером данных.
function LoggingContractorJob.new(data, customMt)
    local self = setmetatable({}, customMt or LoggingContractorJob_mt)

    self.jobId = data.jobId
    self.farmId = data.farmId
    self.farmlandId = data.farmlandId
    self.plannedTrees = data.plannedTrees
    self.contractorCutTrees = data.contractorCutTrees or 0
    self.remainingTrees = data.remainingTrees or data.plannedTrees
    self.equipmentCount = data.equipmentCount
    self.logLength = data.logLength
    self.workHours = data.workHours
    self.billableHours = data.billableHours
    self.rentCost = data.rentCost
    self.equipmentWorkCost = data.equipmentWorkCost
    self.workerCost = data.workerCost
    self.totalCost = data.totalCost
    self.state = data.state or LoggingContractorJob.STATE_ACTIVE
    self.isActive = self.state == LoggingContractorJob.STATE_ACTIVE

    return self
end


-- Возвращает набор данных договора, который можно передать клиенту после
-- успешного заключения без повторного доверия клиентскому расчёту.
function LoggingContractorJob:getNetworkData()
    return {
        jobId = self.jobId,
        farmId = self.farmId,
        farmlandId = self.farmlandId,
        plannedTrees = self.plannedTrees,
        contractorCutTrees = self.contractorCutTrees,
        remainingTrees = self.remainingTrees,
        equipmentCount = self.equipmentCount,
        logLength = self.logLength,
        workHours = self.workHours,
        billableHours = self.billableHours,
        rentCost = self.rentCost,
        equipmentWorkCost = self.equipmentWorkCost,
        workerCost = self.workerCost,
        totalCost = self.totalCost,
        state = self.state
    }
end


-- Завершает жизненный цикл объекта задачи. Отдельных engine-ресурсов на
-- текущем этапе задача не создаёт.
function LoggingContractorJob:delete()
    self.isActive = false
end

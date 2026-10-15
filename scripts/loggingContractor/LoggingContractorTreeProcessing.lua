--[[
    LoggingContractorTreeProcessing

    Обработка спиленного дерева подрядчиком.

    Основной ствол сканируется через 0.10 м. Первые 5 м являются только
    классификационным окном: если там обнаружена крупная ветвь, её поиск
    продолжается до конца ствола. Крупные ветви отделяются продольными резами
    с повторными попытками 0/-30/+30 градусов и сдвигом вдоль оси на 0.10 м.

    Attachments удаляются штатным removeSplitShapeAttachments. Для обычных
    деревьев используется лёгкий четырёхсторонний радиальный проход. Для SPRUCE
    и для отделённых крупных ветвей на каждом сечении выполняется полный круг
    из 12 уникальных радиальных направлений через 30 градусов.
]]

local function getMedian(values)
    if #values == 0 then
        return 0
    end

    table.sort(values)
    local middle = math.floor((#values + 1) * 0.5)
    if #values % 2 == 0 then
        return (values[middle] + values[middle + 1]) * 0.5
    end

    return values[middle]
end

LoggingContractor.BRANCH_MIN_SIDE_GROWTH = 0.12
LoggingContractor.BRANCH_SIDE_GROWTH_FACTOR = 0.25
LoggingContractor.BRANCH_MIN_WIDTH_GROWTH = 0.08
LoggingContractor.BRANCH_WIDTH_GROWTH_FACTOR = 0.15
LoggingContractor.BRANCH_PERSISTENCE_FACTOR = 0.60
LoggingContractor.BRANCH_GROUP_END_FACTOR = 0.35
LoggingContractor.BRANCH_SEPARATION_SPEED = 0.55
LoggingContractor.BRANCH_SEPARATION_UP_SPEED = 0.15

-- Формирует базовое сечение по медиане предыдущих замеров.
function LoggingContractor:getContractorBranchBaseline(samples, firstIndex, lastIndex)
    local minUp, maxUp, minSide, maxSide = {}, {}, {}, {}
    local widthUp, widthSide, centerUp, centerSide = {}, {}, {}, {}

    for index = firstIndex, lastIndex do
        local sample = samples[index]
        table.insert(minUp, sample.minUp)
        table.insert(maxUp, sample.maxUp)
        table.insert(minSide, sample.minSide)
        table.insert(maxSide, sample.maxSide)
        table.insert(widthUp, sample.widthUp)
        table.insert(widthSide, sample.widthSide)
        table.insert(centerUp, sample.centerUp)
        table.insert(centerSide, sample.centerSide)
    end

    return {
        minUp = getMedian(minUp),
        maxUp = getMedian(maxUp),
        minSide = getMedian(minSide),
        maxSide = getMedian(maxSide),
        widthUp = getMedian(widthUp),
        widthSide = getMedian(widthSide),
        centerUp = getMedian(centerUp),
        centerSide = getMedian(centerSide)
    }
end

-- Возвращает одностороннее расширение сечения и прирост его полной ширины.
function LoggingContractor:getContractorBranchSideGrowth(sample, baseline, direction)
    if direction == "SIDE_POS" then
        return sample.maxSide - baseline.maxSide, sample.widthSide - baseline.widthSide
    elseif direction == "SIDE_NEG" then
        return baseline.minSide - sample.minSide, sample.widthSide - baseline.widthSide
    elseif direction == "UP_POS" then
        return sample.maxUp - baseline.maxUp, sample.widthUp - baseline.widthUp
    elseif direction == "UP_NEG" then
        return baseline.minUp - sample.minUp, sample.widthUp - baseline.widthUp
    end
    return 0, 0
end

-- Возвращает мировой радиальный вектор выбранной стороны сечения.
function LoggingContractor:getContractorBranchDirection(direction, sideX, sideY, sideZ, upX, upY, upZ)
    if direction == "SIDE_POS" then
        return sideX, sideY, sideZ
    elseif direction == "SIDE_NEG" then
        return -sideX, -sideY, -sideZ
    elseif direction == "UP_POS" then
        return upX, upY, upZ
    elseif direction == "UP_NEG" then
        return -upX, -upY, -upZ
    end
    return nil
end

-- Возвращает радиус нормального ствола в выбранном направлении.
function LoggingContractor:getContractorBranchSurfaceOffset(baseline, direction)
    if direction == "SIDE_POS" then
        return baseline.maxSide
    elseif direction == "SIDE_NEG" then
        return -baseline.minSide
    elseif direction == "UP_POS" then
        return baseline.maxUp
    elseif direction == "UP_NEG" then
        return -baseline.minUp
    end
    return 0
end

-- Проверяет, пересекает ли продольная плоскость древесную геометрию.
function LoggingContractor:probeContractorLongitudinalCut(
    shape, centerX, centerY, centerZ,
    normalX, normalY, normalZ,
    axisX, axisY, axisZ,
    sizeY, sizeZ
)
    local sideX, sideY, sideZ = MathUtil.crossProduct(
        normalX, normalY, normalZ,
        axisX, axisY, axisZ
    )
    if MathUtil.vector3Length(sideX, sideY, sideZ) < 0.001 then
        return nil
    end
    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    local planeX = centerX - axisX * sizeY * 0.5 - sideX * sizeZ * 0.5
    local planeY = centerY - axisY * sizeY * 0.5 - sideY * sizeZ * 0.5
    local planeZ = centerZ - axisZ * sizeY * 0.5 - sideZ * sizeZ * 0.5

    local minY, maxY, minZ, maxZ = testSplitShape(
        shape,
        planeX, planeY, planeZ,
        normalX, normalY, normalZ,
        axisX, axisY, axisZ,
        sizeY, sizeZ
    )
    if minY == nil then
        return nil
    end

    return {widthY = maxY - minY, widthZ = maxZ - minZ}
end


LoggingContractor.PROCESSING_SCAN_STEP = 0.10
LoggingContractor.PROCESSING_BRANCH_SCAN_LENGTH = 5.0
LoggingContractor.PROCESSING_BRANCH_BASELINE_SAMPLES = 10
LoggingContractor.PROCESSING_BRANCH_MAX_TOTAL_CUTS = 32
LoggingContractor.PROCESSING_BRANCH_MAX_CUTS_PER_STEP = 8
LoggingContractor.PROCESSING_BRANCH_CUT_LENGTH = 5.0
LoggingContractor.PROCESSING_BRANCH_CUT_BACK = 0.25
LoggingContractor.PROCESSING_BRANCH_CUT_WIDTH = 6.0
LoggingContractor.PROCESSING_BRANCH_OUTSETS = {0.10, 0.05, 0.02, 0.00}
LoggingContractor.PROCESSING_BRANCH_ANGLE_OFFSETS = {0, -30, 30}
LoggingContractor.PROCESSING_BRANCH_ADVANCE_STEP = 0.10

LoggingContractor.PROCESSING_ATTACHMENT_THICKNESS = 0.30
LoggingContractor.PROCESSING_ATTACHMENT_MIN_SIZE = 1.00
LoggingContractor.PROCESSING_ATTACHMENT_MAX_SIZE = 2.00
LoggingContractor.PROCESSING_ATTACHMENT_SIZE_FACTOR = 1.50
LoggingContractor.PROCESSING_ATTACHMENT_RADIAL_OUTSET = 0.10
LoggingContractor.PROCESSING_ATTACHMENT_ROTATION_STEP = 30
LoggingContractor.PROCESSING_DETACHED_SCAN_STEP = 0.05
LoggingContractor.PROCESSING_DETACHED_SECOND_PASS_PHASE = 15
LoggingContractor.PROCESSING_FULL_CIRCLE_DIRECTIONS = 12

-- Тяжёлая очистка attachments внутри PRUNE выполняется порциями, чтобы один
-- вызов не проходил целиком по стволу или отделённой ветви. Геометрический шаг
-- и число радиальных направлений не меняются.
LoggingContractor.PROCESSING_ATTACHMENT_SECTIONS_PER_UPDATE = 1
LoggingContractor.PROCESSING_DETACHED_SECTIONS_PER_UPDATE = 1

-- Fallback основан на рабочем принципе Tree Trimmer: после точной очистки
-- большая плоскость проходит по сетке вокруг всего split-shape. Полный проход
-- нарезан на небольшие порции, чтобы ручной алгоритм не выполнялся за один кадр.
LoggingContractor.PROCESSING_FALLBACK_STEP = 0.10
LoggingContractor.PROCESSING_FALLBACK_MAX_PASSES = 12
LoggingContractor.PROCESSING_FALLBACK_SEARCH_RADIUS = 14.0
LoggingContractor.PROCESSING_FALLBACK_PLANE_WIDTH = 64.0
LoggingContractor.PROCESSING_FALLBACK_PLANE_DEPTH = 64.0
LoggingContractor.PROCESSING_FALLBACK_TIP_OVERSHOOT = 3.0
LoggingContractor.PROCESSING_FALLBACK_POSITIONS_PER_UPDATE = 12
LoggingContractor.PROCESSING_FALLBACK_OFFSETS = {
    0,
    7, -7,
    14, -14,
    21, -21
}

-- Экспериментальный профиль взрослой spruce2: крепления 72 групп
-- LOD0AttachmentsShape из map/trees/spruce/spruceVar2_stage03.i3d.shapes.
-- Y: усреднённая высота шести ближайших к оси вершин группы;
-- X/Z: единичный радиальный вектор околоствольной геометрии.
-- Значения локальные, привязанные к исходной I3D.
local CONTRACTOR_SPRUCE2_STAGE03_POINTS = {
    {0.711, 34.531, -0.703},
    {-0.509, 34.469, -0.861},
    {-0.774, 25.811, -0.634},
    {0.952, 33.512, -0.307},
    {0.326, 34.135, -0.945},
    {0.008, 29.088, -1},
    {-0.506, 29.385, 0.862},
    {-0.95, 28.885, -0.312},
    {0.995, 26.599, -0.099},
    {0.274, 30.348, 0.962},
    {0.983, 31.208, -0.184},
    {-0.137, 31.364, -0.991},
    {-0.388, 32.009, 0.921},
    {0.949, 31.829, -0.315},
    {-0.943, 32.068, -0.332},
    {-0.108, 32.446, -0.994},
    {0.592, 32.352, 0.806},
    {-0.843, 33.103, 0.537},
    {-0.834, 33.672, -0.552},
    {0.275, 33.185, 0.961},
    {-0.998, 33.771, 0.06},
    {0.773, 33.907, 0.634},
    {-0.418, 34.84, 0.908},
    {0.103, 27.82, 0.995},
    {0.599, 25.097, 0.8},
    {0.494, 24.084, -0.869},
    {0.221, 21.877, 0.975},
    {-0.187, 25.998, 0.982},
    {0.992, 20.17, -0.123},
    {-0.513, 20.467, -0.858},
    {-0.43, 19.444, 0.903},
    {0.312, 14.726, 0.95},
    {0.95, 18.727, -0.313},
    {-0.944, 20.772, 0.329},
    {-0.988, 17.555, 0.156},
    {-0.071, 16.464, -0.997},
    {0.927, 15.589, 0.376},
    {0.046, 16.753, 0.999},
    {0.473, 21.449, -0.881},
    {0.782, 14.032, -0.624},
    {-0.831, 14.561, -0.557},
    {0.993, 11.966, -0.118},
    {-0.996, 12.825, -0.089},
    {-0.693, 14.272, 0.721},
    {0.329, 10.015, 0.944},
    {-0.926, 9.038, -0.377},
    {-0.278, 11.028, -0.961},
    {0.527, 8.152, -0.85},
    {0.657, 11.291, 0.754},
    {-0.173, 8.09, 0.985},
    {0.907, 29.443, -0.421},
    {-0.985, 29.911, -0.17},
    {-0.986, 6.643, -0.167},
    {1, 7.167, -0.02},
    {0.989, 17.007, 0.149},
    {-0.676, 18.568, -0.737},
    {-0.248, 5.606, -0.969},
    {0.501, 5.126, 0.865},
    {-0.668, 5.299, 0.745},
    {0.948, 4.984, -0.318},
    {-0.512, 4.118, -0.859},
    {0.556, 4.163, -0.831},
    {0.384, 3.63, 0.923},
    {0.576, 6.308, 0.817},
    {0.85, 35.278, 0.527},
    {0.014, 33.992, 1},
    {-0.638, 34.434, 0.77},
    {-0.724, 22.442, 0.69},
    {-0.792, 30.176, 0.61},
    {-0.854, 15.378, 0.521},
    {0.67, 14.559, -0.742},
    {-0.051, 15.678, 0.999}
}

-- Второй профиль: 49 креплений LOD0AttachmentsShape из
-- spruceVar2_stage02.i3d.shapes. Y соответствует вершинам у ствола,
-- X/Z задают радиальное направление у основания ветви.
local CONTRACTOR_SPRUCE2_STAGE02_POINTS = {
    {0.711, 20.808, -0.703},
    {-0.332, 20.772, -0.943},
    {0.909, 20.178, -0.417},
    {0.515, 20.417, -0.857},
    {0.301, 15.374, -0.954},
    {-0.326, 15.66, 0.945},
    {-0.936, 15.169, -0.353},
    {0.439, 16.591, 0.899},
    {0.506, 17.483, -0.862},
    {0.29, 18.068, -0.957},
    {-0.831, 18.235, 0.556},
    {0.999, 18.106, -0.051},
    {-0.539, 18.658, -0.842},
    {0.188, 19.03, -0.982},
    {0.831, 18.984, 0.556},
    {-0.398, 19.407, 0.918},
    {-0.934, 19.951, -0.357},
    {-0.287, 19.72, 0.958},
    {-0.9, 20.046, -0.436},
    {0.885, 20.182, 0.466},
    {0.335, 21.09, 0.942},
    {0.546, 14.201, 0.838},
    {0.904, 12.23, -0.427},
    {-0.041, 11.496, -0.999},
    {-0.816, 12.026, 0.579},
    {0.808, 8.281, -0.589},
    {-0.764, 9.653, 0.645},
    {0.681, 12.028, 0.733},
    {0.773, 8.059, -0.634},
    {-0.897, 6.482, 0.442},
    {-0.722, 6.119, -0.692},
    {0.887, 9.38, -0.461},
    {0.777, 5.498, 0.63},
    {0.999, 16.121, 0.035},
    {-0.936, 3.952, 0.352},
    {0.839, 4.627, -0.544},
    {0.717, 3.592, 0.697},
    {0.273, 3.773, -0.962},
    {-0.992, 3.315, 0.127},
    {0.909, 3.841, 0.418},
    {0.79, 20.801, -0.614},
    {-0.1, 20.27, 0.995},
    {-0.193, 20.706, 0.981},
    {0.355, 12.868, 0.935},
    {-0.414, 12.351, -0.91},
    {-0.992, 8.713, -0.128},
    {-0.766, 16.187, -0.643},
    {-0.333, 7.236, 0.943},
    {-0.681, 7.228, -0.732}
}

-- Профиль взрослой ели spruce1: 103 группы LOD0AttachmentsShape из
-- spruceVar1_stage03.i3d.shapes. Высота: средняя Y шести ближайших
-- к оси ствола вершин; X/Z: направление группы около ствола.
-- Координаты локальные, в системе исходной I3D-модели.
local CONTRACTOR_SPRUCE1_STAGE03_POINTS = {
    {0.683, 11.229, 0.73},
    {0.993, 9.935, 0.114},
    {0.248, 9.502, -0.969},
    {-0.955, 8.905, -0.296},
    {-0.766, 9.518, 0.643},
    {-0.353, 8.215, -0.936},
    {0.878, 7.693, 0.479},
    {-0.92, 7.525, 0.392},
    {-0.785, 6.396, 0.619},
    {0.994, 6.653, -0.11},
    {-0.643, 11.901, 0.766},
    {-0.977, 11.021, -0.215},
    {0.785, 10.777, -0.62},
    {0.733, 34.597, -0.68},
    {-0.523, 34.553, -0.852},
    {-0.942, 27.607, -0.336},
    {0.986, 12.328, -0.165},
    {-0.306, 8.307, 0.952},
    {0.431, 9.009, 0.902},
    {-0.999, 13.212, -0.033},
    {-0.236, 13.932, -0.972},
    {-0.645, 10.265, -0.764},
    {-0.004, 11.898, -1},
    {0.346, 12.622, 0.938},
    {-0.892, 12.666, -0.452},
    {-0.497, 14.178, 0.868},
    {-0.979, 14.501, -0.203},
    {0.125, 15.21, -0.992},
    {0.572, 13.066, -0.82},
    {0.75, 14.416, -0.662},
    {0.966, 13.583, 0.257},
    {-0.917, 15.35, 0.399},
    {-0.991, 16.755, 0.131},
    {0.416, 15.021, 0.909},
    {0.993, 15.699, -0.114},
    {0.849, 16.994, 0.529},
    {0.148, 16.05, 0.989},
    {-0.645, 17.509, 0.765},
    {0.542, 16.762, -0.84},
    {0.358, 18.544, 0.934},
    {-0.818, 16.177, -0.576},
    {-0.335, 17.556, -0.942},
    {0.927, 18.132, -0.375},
    {0.36, 19.004, -0.933},
    {-0.929, 18.568, -0.37},
    {-0.695, 19.752, -0.719},
    {-0.909, 19.079, 0.416},
    {1, 19.507, 0.029},
    {-0.083, 19.872, 0.997},
    {0.737, 20.801, 0.676},
    {-0.115, 21.259, -0.993},
    {0.922, 21.783, -0.387},
    {-0.628, 21.673, 0.778},
    {-0.925, 21.927, -0.381},
    {-1, 21.214, -0.03},
    {0.998, 33.233, 0.06},
    {0.769, 33.726, -0.639},
    {0.965, 22.961, 0.261},
    {-0.404, 23.291, 0.915},
    {-0.502, 23.297, -0.865},
    {-0.401, 29.145, -0.916},
    {0.837, 29.134, -0.548},
    {-0.303, 29.361, 0.953},
    {0.671, 20.423, -0.741},
    {-0.94, 28.875, 0.342},
    {0.887, 28.948, 0.462},
    {0.544, 30.083, 0.839},
    {-0.81, 30.362, 0.587},
    {0.109, 30.236, -0.994},
    {0.997, 30.498, -0.082},
    {0.405, 24.253, 0.914},
    {-0.764, 30.843, -0.645},
    {0.697, 31.261, -0.717},
    {-0.079, 31.052, 0.997},
    {-0.999, 31.129, 0.036},
    {-0.061, 31.803, -0.998},
    {0.784, 31.604, 0.621},
    {-0.226, 32.083, 0.974},
    {0.908, 32.274, -0.419},
    {-0.995, 32.486, -0.095},
    {-0.012, 32.805, -1},
    {0.597, 32.731, 0.802},
    {-0.767, 32.985, 0.641},
    {-0.744, 33.307, -0.669},
    {0.149, 33.505, 0.989},
    {-0.998, 33.82, 0.062},
    {0.808, 33.991, 0.589},
    {-0.396, 34.892, 0.918},
    {0.334, 27.675, 0.943},
    {0.903, 24.13, -0.43},
    {-0.988, 23.726, 0.157},
    {0.999, 25.13, -0.039},
    {0.701, 25.867, -0.713},
    {0.117, 24.628, -0.993},
    {-0.681, 24.841, 0.732},
    {0.178, 25.599, 0.984},
    {-0.989, 26.253, 0.148},
    {-0.607, 26.03, -0.795},
    {-0.13, 27.109, -0.992},
    {-0.509, 27.432, 0.861},
    {0.551, 27.144, 0.835},
    {0.982, 27.627, -0.187},
    {0.318, 27.895, -0.948}
}

-- Сопоставляет три опытные модели с их адресными контрольными точками.
-- Для остальных елей сохраняются стандартные FAST и FALLBACK.
local CONTRACTOR_SPRUCE_PROFILE_POINTS = {
    spruce1_stage03 = CONTRACTOR_SPRUCE1_STAGE03_POINTS,
    spruce2_stage02 = CONTRACTOR_SPRUCE2_STAGE02_POINTS,
    spruce2_stage03 = CONTRACTOR_SPRUCE2_STAGE03_POINTS
}

LoggingContractor.PROCESSING_PROFILE_RADIAL_DISTANCE = 0.20


-- Возвращает размер плоскости testSplitShape с запасом относительно текущего
-- split-shape. Большой размер нужен только для измерения сечения и не задаёт
-- область удаления attachments.
function LoggingContractor:getContractorProcessingScanSize(shape)
    local sizeX, sizeY, sizeZ = self:getContractorSplitShapeStats(shape)
    return math.max(sizeX, sizeY, sizeZ, 4) + 2
end


-- Снимает поперечное сечение в заданной точке основной оси ствола.
function LoggingContractor:sampleContractorProcessingSection(
    shape,
    baseX,
    baseY,
    baseZ,
    axisX,
    axisY,
    axisZ,
    upX,
    upY,
    upZ,
    distance
)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return nil
    end

    local scanSize = self:getContractorProcessingScanSize(shape)
    local sample = self:sampleContractorCrossSection(
        shape,
        baseX + axisX * distance,
        baseY + axisY * distance,
        baseZ + axisZ * distance,
        axisX,
        axisY,
        axisZ,
        upX,
        upY,
        upZ,
        scanSize
    )

    if sample ~= nil then
        sample.distance = distance
    end

    return sample
end


-- Возвращает все стороны текущего сечения, соответствующие критериям крупной
-- ветви. Список нужен, чтобы после неудачного реза проверить остальные стороны
-- в той же самой точке.
function LoggingContractor:getContractorProcessingBranchCandidates(sample, baseline, nextSample, blockedDirections)
    local baselineDiameter = math.max(baseline.widthUp, baseline.widthSide)
    local growthThreshold = math.max(
        LoggingContractor.BRANCH_MIN_SIDE_GROWTH,
        baselineDiameter * LoggingContractor.BRANCH_SIDE_GROWTH_FACTOR
    )
    local widthThreshold = math.max(
        LoggingContractor.BRANCH_MIN_WIDTH_GROWTH,
        baselineDiameter * LoggingContractor.BRANCH_WIDTH_GROWTH_FACTOR
    )
    local candidates = {}

    for _, direction in ipairs({"SIDE_POS", "SIDE_NEG", "UP_POS", "UP_NEG"}) do
        if blockedDirections == nil or not blockedDirections[direction] then
            local growth, widthGrowth = self:getContractorBranchSideGrowth(sample, baseline, direction)
            local persistent = true

            if nextSample ~= nil then
                local nextGrowth, nextWidthGrowth = self:getContractorBranchSideGrowth(
                    nextSample,
                    baseline,
                    direction
                )
                persistent = nextGrowth >= growthThreshold * LoggingContractor.BRANCH_PERSISTENCE_FACTOR
                    and nextWidthGrowth >= widthThreshold * LoggingContractor.BRANCH_PERSISTENCE_FACTOR
            end

            if growth >= growthThreshold
                and widthGrowth >= widthThreshold
                and persistent then
                table.insert(candidates, {
                    direction = direction,
                    growth = growth,
                    widthGrowth = widthGrowth,
                    growthThreshold = growthThreshold,
                    widthThreshold = widthThreshold,
                    baselineDiameter = baselineDiameter
                })
            end
        end
    end

    table.sort(candidates, function(a, b)
        return a.growth > b.growth
    end)

    return candidates
end


-- Формирует параметры увеличенной продольной плоскости для ветви, найденной
-- в конкретном сечении. Плоскость начинается немного ниже точки обнаружения и
-- продолжается до 5 м вверх по стволу. Поперечная ширина 6 м выбрана намеренно
-- большой для эксперимента: она должна исключить нехватку охвата как причину
-- отсутствия splitShape на раскидистых деревьях.
function LoggingContractor:getContractorProcessingBranchCutGeometry(
    shape,
    sample,
    baseline,
    candidate,
    baseX,
    baseY,
    baseZ,
    axisX,
    axisY,
    axisZ,
    upX,
    upY,
    upZ,
    trunkLength
)
    local normalX, normalY, normalZ = self:getContractorBranchDirection(
        candidate.direction,
        sample.sideX,
        sample.sideY,
        sample.sideZ,
        upX,
        upY,
        upZ
    )

    if normalX == nil then
        return nil
    end

    normalX, normalY, normalZ = MathUtil.vector3Normalize(normalX, normalY, normalZ)

    local cutStart = math.max(0, sample.distance - LoggingContractor.PROCESSING_BRANCH_CUT_BACK)
    local cutEnd = math.min(
        trunkLength,
        cutStart + LoggingContractor.PROCESSING_BRANCH_CUT_LENGTH
    )
    local cutLength = cutEnd - cutStart
    if cutLength <= 0.05 then
        return nil
    end

    local cutDistance = (cutStart + cutEnd) * 0.5
    local cutWidth = LoggingContractor.PROCESSING_BRANCH_CUT_WIDTH
    local surfaceOffset = math.max(
        self:getContractorBranchSurfaceOffset(baseline, candidate.direction),
        candidate.baselineDiameter * 0.25
    )
    local axisPointX = baseX + axisX * cutDistance
    local axisPointY = baseY + axisY * cutDistance
    local axisPointZ = baseZ + axisZ * cutDistance

    return {
        normalX = normalX,
        normalY = normalY,
        normalZ = normalZ,
        upX = axisX,
        upY = axisY,
        upZ = axisZ,
        axisPointX = axisPointX,
        axisPointY = axisPointY,
        axisPointZ = axisPointZ,
        surfaceOffset = surfaceOffset,
        cutStart = cutStart,
        cutEnd = cutEnd,
        sizeY = cutLength,
        sizeZ = cutWidth
    }
end

-- Поворачивает радиальное направление реза вокруг продольной оси ствола.
-- Так одна и та же найденная ветвь проверяется исходной плоскостью, а затем
-- плоскостями, повернутыми на 30 градусов влево и вправо.
function LoggingContractor:rotateContractorProcessingBranchNormal(
    normalX,
    normalY,
    normalZ,
    axisX,
    axisY,
    axisZ,
    angleDegrees
)
    local tangentX, tangentY, tangentZ = MathUtil.crossProduct(
        axisX,
        axisY,
        axisZ,
        normalX,
        normalY,
        normalZ
    )

    if MathUtil.vector3Length(tangentX, tangentY, tangentZ) < 0.001 then
        return normalX, normalY, normalZ
    end

    tangentX, tangentY, tangentZ = MathUtil.vector3Normalize(tangentX, tangentY, tangentZ)

    local angle = math.rad(angleDegrees)
    local cosAngle = math.cos(angle)
    local sinAngle = math.sin(angle)
    local rotatedX = normalX * cosAngle + tangentX * sinAngle
    local rotatedY = normalY * cosAngle + tangentY * sinAngle
    local rotatedZ = normalZ * cosAngle + tangentZ * sinAngle

    return MathUtil.vector3Normalize(rotatedX, rotatedY, rotatedZ)
end


-- Выполняет один локальный продольный отпил. Если splitShape создал только одну
-- новую часть, она всё равно принимается как новый основной shape, чтобы после
-- замены исходного split-shape не потерять ссылку. Успешным снятием ветви
-- считается только появление хотя бы одной отдельной части помимо ствола.
function LoggingContractor:cutContractorProcessingBranchOnce(
    state,
    sample,
    baseline,
    candidate,
    allowMutation
)
    local currentShape = state.shape
    local currentLength = state.length
    local initialDistance = sample.distance
    local attemptDistance = initialDistance

    while currentShape ~= nil
        and currentShape ~= 0
        and entityExists(currentShape)
        and attemptDistance <= currentLength + 0.001 do
        local attemptSample = self:sampleContractorProcessingSection(
            currentShape,
            state.baseX,
            state.baseY,
            state.baseZ,
            state.axisX,
            state.axisY,
            state.axisZ,
            state.upX,
            state.upY,
            state.upZ,
            attemptDistance
        )

        if attemptSample == nil then
            break
        end

        local growth, widthGrowth = self:getContractorBranchSideGrowth(
            attemptSample,
            baseline,
            candidate.direction
        )

        if attemptDistance > initialDistance then
            local minGrowth =
                candidate.growthThreshold * LoggingContractor.BRANCH_GROUP_END_FACTOR
            local minWidthGrowth =
                candidate.widthThreshold * LoggingContractor.BRANCH_GROUP_END_FACTOR

            if growth < minGrowth or widthGrowth < minWidthGrowth then
                break
            end
        end

        local geometry = self:getContractorProcessingBranchCutGeometry(
            currentShape,
            attemptSample,
            baseline,
            candidate,
            state.baseX,
            state.baseY,
            state.baseZ,
            state.axisX,
            state.axisY,
            state.axisZ,
            state.upX,
            state.upY,
            state.upZ,
            currentLength
        )

        if geometry == nil then
            break
        end

        for _, angleOffset in ipairs(LoggingContractor.PROCESSING_BRANCH_ANGLE_OFFSETS) do
            local normalX, normalY, normalZ =
                self:rotateContractorProcessingBranchNormal(
                    geometry.normalX,
                    geometry.normalY,
                    geometry.normalZ,
                    state.axisX,
                    state.axisY,
                    state.axisZ,
                    angleOffset
                )

            for _, outset in ipairs(LoggingContractor.PROCESSING_BRANCH_OUTSETS) do
                local cutOffset = geometry.surfaceOffset + outset
                local cutX = geometry.axisPointX + normalX * cutOffset
                local cutY = geometry.axisPointY + normalY * cutOffset
                local cutZ = geometry.axisPointZ + normalZ * cutOffset

                local probe = self:probeContractorLongitudinalCut(
                    currentShape,
                    cutX,
                    cutY,
                    cutZ,
                    normalX,
                    normalY,
                    normalZ,
                    geometry.upX,
                    geometry.upY,
                    geometry.upZ,
                    geometry.sizeY,
                    geometry.sizeZ
                )

                if probe ~= nil then
                    if not allowMutation then
                        return false, false
                    end

                    local parts = self:splitContractorShapeSized(
                        currentShape,
                        cutX,
                        cutY,
                        cutZ,
                        normalX,
                        normalY,
                        normalZ,
                        geometry.upX,
                        geometry.upY,
                        geometry.upZ,
                        geometry.sizeY,
                        geometry.sizeZ
                    )

                    if #parts > 0 then
                        local mainPart, mainAxisLength =
                            self:selectContractorMainStemPart(
                                parts,
                                state.baseX,
                                state.baseY,
                                state.baseZ,
                                state.axisX,
                                state.axisY,
                                state.axisZ
                            )

                        if mainPart == nil
                            or mainPart.shape == nil
                            or not entityExists(mainPart.shape) then
                            Logging.warning(
                                "[LoggingContractor] Branch cut produced no usable main stem"
                            )
                            return true, false
                        end

                        state.shape = mainPart.shape
                        state.length =
                            mainAxisLength > 0 and mainAxisLength or state.length

                        local detachedShapes = {}
                        for _, part in ipairs(parts) do
                            if part.shape ~= nil
                                and part.shape ~= state.shape
                                and entityExists(part.shape) then
                                table.insert(detachedShapes, part.shape)
                            end
                        end

                        state.pendingDetached = {
                            shapes = detachedShapes,
                            normalX = normalX,
                            normalY = normalY,
                            normalZ = normalZ
                        }

                        return true, #detachedShapes > 0
                    end
                end
            end
        end

        attemptDistance =
            attemptDistance + LoggingContractor.PROCESSING_BRANCH_ADVANCE_STEP
    end

    return false, false
end

function LoggingContractor:removeContractorProcessingAttachmentsAtStep(
    shape,
    sample,
    baseX,
    baseY,
    baseZ,
    axisX,
    axisY,
    axisZ,
    upX,
    upY,
    upZ,
    distance,
    rotationAngle,
    fullCircle,
    attachmentTypeStats,
    detachedShape
)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return 0
    end

    local _, _, _, _, attachmentsBefore = self:getContractorSplitShapeStats(shape)
    if attachmentsBefore <= 0 then
        return 0
    end

    rotationAngle = rotationAngle or 0

    local sideX, sideY, sideZ = MathUtil.crossProduct(
        axisX, axisY, axisZ,
        upX, upY, upZ
    )
    if MathUtil.vector3Length(sideX, sideY, sideZ) < 0.001 then
        return 0
    end
    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    local centerUp = sample ~= nil and sample.centerUp or 0
    local centerSide = sample ~= nil and sample.centerSide or 0
    local halfUp = sample ~= nil and math.max(sample.widthUp * 0.5, 0.01) or 0.5
    local halfSide = sample ~= nil and math.max(sample.widthSide * 0.5, 0.01) or 0.5
    local localDiameter = math.max(halfUp * 2, halfSide * 2)
    local probeSize = math.clamp(
        localDiameter * LoggingContractor.PROCESSING_ATTACHMENT_SIZE_FACTOR,
        LoggingContractor.PROCESSING_ATTACHMENT_MIN_SIZE,
        LoggingContractor.PROCESSING_ATTACHMENT_MAX_SIZE
    )

    local axisPointX = baseX + axisX * distance
    local axisPointY = baseY + axisY * distance
    local axisPointZ = baseZ + axisZ * distance
    local centerX = axisPointX + upX * centerUp + sideX * centerSide
    local centerY = axisPointY + upY * centerUp + sideY * centerSide
    local centerZ = axisPointZ + upZ * centerUp + sideZ * centerSide
    local outset = LoggingContractor.PROCESSING_ATTACHMENT_RADIAL_OUTSET

    removeSplitShapeAttachments(
        shape,
        centerX, centerY, centerZ,
        axisX, axisY, axisZ,
        upX, upY, upZ,
        LoggingContractor.PROCESSING_ATTACHMENT_THICKNESS,
        probeSize,
        probeSize
    )

    -- Фиксируем реальное уменьшение числа attachments по ориентации.
    -- Дополнительное чтение геометрии требуется только в режиме диагностики
    -- для исходной осевой плоскости; после радиальных вызовов оно уже есть.
    local previousAttachments = attachmentsBefore
    if attachmentTypeStats ~= nil and entityExists(shape) then
        local remaining = select(5, self:getContractorSplitShapeStats(shape))
        local counts = detachedShape
            and attachmentTypeStats.detachedDirections
            or attachmentTypeStats.mainDirections
        local entry = counts.AXIS or {calls = 0, removed = 0}
        entry.calls = entry.calls + 1
        entry.removed = entry.removed + math.max(previousAttachments - remaining, 0)
        counts.AXIS = entry
        previousAttachments = remaining
    end

    if not entityExists(shape) then
        return attachmentsBefore
    end

    local directionCount = fullCircle
        and LoggingContractor.PROCESSING_FULL_CIRCLE_DIRECTIONS
        or 4
    local angleStep = fullCircle
        and LoggingContractor.PROCESSING_ATTACHMENT_ROTATION_STEP
        or 90

    for index = 0, directionCount - 1 do
        local angle = math.rad(rotationAngle + index * angleStep)
        local cosAngle = math.cos(angle)
        local sinAngle = math.sin(angle)
        local radialX = upX * cosAngle + sideX * sinAngle
        local radialY = upY * cosAngle + sideY * sinAngle
        local radialZ = upZ * cosAngle + sideZ * sinAngle
        radialX, radialY, radialZ = MathUtil.vector3Normalize(radialX, radialY, radialZ)

        local radius = math.abs(cosAngle) * halfUp + math.abs(sinAngle) * halfSide

        removeSplitShapeAttachments(
            shape,
            centerX + radialX * (radius + outset),
            centerY + radialY * (radius + outset),
            centerZ + radialZ * (radius + outset),
            -radialX, -radialY, -radialZ,
            axisX, axisY, axisZ,
            LoggingContractor.PROCESSING_ATTACHMENT_THICKNESS,
            probeSize,
            probeSize
        )

        if not entityExists(shape) then
            return attachmentsBefore
        end

        local remaining = select(5, self:getContractorSplitShapeStats(shape))
        if attachmentTypeStats ~= nil then
            -- Угол относительно текущей поперечной оси, кратно 30 градусам.
            local angleKey = tostring(
                math.floor((rotationAngle + index * angleStep) % 360 + 0.5)
            )
            local counts = detachedShape
            and attachmentTypeStats.detachedDirections
            or attachmentTypeStats.mainDirections
            local entry = counts[angleKey] or {calls = 0, removed = 0}
            entry.calls = entry.calls + 1
            entry.removed = entry.removed
                + math.max(previousAttachments - remaining, 0)
            counts[angleKey] = entry
            previousAttachments = remaining
        end

        if remaining <= 0 then
            break
        end
    end

    local attachmentsAfter = select(5, self:getContractorSplitShapeStats(shape))
    return math.max(attachmentsBefore - attachmentsAfter, 0)
end

-- Возвращает систему осей, совпадающую с механикой Tree Trimmer:
-- стоящее дерево сканируется вдоль локальной Y, динамический split-shape —
-- вдоль локальной X; вторая поперечная ось всегда локальная -Z.
function LoggingContractor:getContractorFallbackTrimAxes(shape)
    if shape == nil or shape == 0 or not entityExists(shape) then
        return nil
    end

    local isStandingTree = getRigidBodyType(shape) == RigidBodyType.STATIC
    local axisX, axisY, axisZ
    local upX, upY, upZ
    local sideX, sideY, sideZ

    if isStandingTree then
        axisX, axisY, axisZ = localDirectionToWorld(shape, 0, 1, 0)
        upX, upY, upZ = localDirectionToWorld(shape, 1, 0, 0)
    else
        axisX, axisY, axisZ = localDirectionToWorld(shape, 1, 0, 0)
        upX, upY, upZ = localDirectionToWorld(shape, 0, 1, 0)
    end

    sideX, sideY, sideZ = localDirectionToWorld(shape, 0, 0, -1)
    axisX, axisY, axisZ = MathUtil.vector3Normalize(axisX, axisY, axisZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)
    sideX, sideY, sideZ = MathUtil.vector3Normalize(sideX, sideY, sideZ)

    return axisX, axisY, axisZ,
        upX, upY, upZ,
        sideX, sideY, sideZ
end


-- Создаёт состояние большого fallback-прохода. В отличие от основной очистки
-- он не пытается точно попасть в поверхность ствола, а последовательно
-- проверяет широкую поперечную сетку вокруг всего дерева.
function LoggingContractor:createContractorFallbackTrimState(shape, attachmentTypeStats)
    local state = {
        shape = shape,
        attachmentTypeStats = attachmentTypeStats,
        passIndex = 1,
        stepIndex = 0,
        upOffsetIndex = 1,
        sideOffsetIndex = 1,
        removedThisPass = false,
        passStartAttachments = nil,
        done = false
    }

    if shape == nil or shape == 0 or not entityExists(shape) then
        state.done = true
        return state
    end

    local attachments = select(5, self:getContractorSplitShapeStats(shape))
    if attachments <= 0 then
        state.done = true
        return state
    end

    -- Снимок перед полным проходом нужен для проверки фактического
    -- уменьшения количества attachments, а не только флага от движка.
    state.passStartAttachments = attachments
    if attachmentTypeStats ~= nil then
        attachmentTypeStats.fallbackStarts =
            attachmentTypeStats.fallbackStarts + 1
    end
    self:addContractorPerfCounter("fallbackStarts", 1)
    return state
end


-- Продвигает Tree-Trimmer-подобный fallback ограниченным числом позиций сетки.
-- Каждая позиция выполняет две ориентации большой плоскости. После первого
-- реального изменения управление сразу возвращается сетевой синхронизации.
function LoggingContractor:advanceContractorFallbackTrimState(state)
    if state == nil or state.done then
        return true, false
    end

    local perfStartMs = LoggingContractor.PERF_DEBUG_ENABLED
        and getTimeSec() * 1000
        or nil
    local removeCalls = 0
    local returnedTrue = 0
    local returnedFalse = 0
    local returnedOther = 0
    local positionsChecked = 0
    local positionsChanged = 0

    -- Фиксирует статистику одной порции работы без дополнительного опроса
    -- геометрии на каждом вызове движка. Показатель returnedTrue означает
    -- только ответ native-функции; фактический результат проверяется в конце прохода.
    local function finish(done, changed)
        if perfStartMs ~= nil then
            self:recordContractorPerfMetric(
                "attachmentFallback",
                getTimeSec() * 1000 - perfStartMs,
                removeCalls
            )

            local stats = self:getContractorPerfStats()
            if stats ~= nil then
                local counters = stats.counters
                counters.fallbackCallsTrue =
                    (counters.fallbackCallsTrue or 0) + returnedTrue
                counters.fallbackCallsFalse =
                    (counters.fallbackCallsFalse or 0) + returnedFalse
                counters.fallbackCallsOther =
                    (counters.fallbackCallsOther or 0) + returnedOther
                counters.fallbackPositions =
                    (counters.fallbackPositions or 0) + positionsChecked
                counters.fallbackPositionsChanged =
                    (counters.fallbackPositionsChanged or 0) + positionsChanged
            end
        end
        return done, changed
    end

    local shape = state.shape
    if shape == nil or shape == 0 or not entityExists(shape) then
        state.done = true
        return finish(true, false)
    end

    local _, _, _, _, attachments =
        self:getContractorSplitShapeStats(shape)
    if attachments <= 0 then
        state.done = true
        self:addContractorPerfCounter("fallbackCompleted", 1)
        return finish(true, false)
    end

    local sizeX, sizeY, sizeZ = self:getContractorSplitShapeStats(shape)
    local length = math.max(sizeX or 0, sizeY or 0, sizeZ or 0)
    if length <= 0.01 then
        state.done = true
        self:addContractorPerfCounter("fallbackUnresolved", 1)
        return finish(true, false)
    end

    local axisX, axisY, axisZ,
        upX, upY, upZ,
        sideX, sideY, sideZ =
        self:getContractorFallbackTrimAxes(shape)

    if axisX == nil then
        state.done = true
        self:addContractorPerfCounter("fallbackUnresolved", 1)
        return finish(true, false)
    end

    local centerX, centerY, centerZ = getWorldTranslation(shape)
    local overshoot = LoggingContractor.PROCESSING_FALLBACK_TIP_OVERSHOOT
    local halfSpan = length * 0.5 + overshoot
    local startX = centerX - axisX * halfSpan
    local startY = centerY - axisY * halfSpan
    local startZ = centerZ - axisZ * halfSpan
    local spanLength = halfSpan * 2
    local steps = math.max(
        1,
        math.ceil(
            spanLength / LoggingContractor.PROCESSING_FALLBACK_STEP
        )
    )
    local offsets = LoggingContractor.PROCESSING_FALLBACK_OFFSETS
    local processedPositions = 0

    while processedPositions
        < LoggingContractor.PROCESSING_FALLBACK_POSITIONS_PER_UPDATE do
        if state.stepIndex > steps then
            local remaining = select(
                5,
                self:getContractorSplitShapeStats(shape)
            )

            -- Сравниваем количество attachments до и после ПОЛНОГО
            -- прохода. Один положительный return native-функции сам по
            -- себе ещё не подтверждает уменьшение количества.
            if perfStartMs ~= nil then
                local before = state.passStartAttachments or remaining
                local reduction = math.max(before - remaining, 0)
                self:addContractorPerfCounter("fallbackPassesChecked", 1)
                self:addContractorPerfCounter(
                    "fallbackAttachmentsNetReduction", reduction
                )
                if reduction == 0 then
                    self:addContractorPerfCounter("fallbackPassesNoReduction", 1)
                    if state.removedThisPass then
                        self:addContractorPerfCounter(
                            "fallbackPassesReportedButNoReduction", 1
                        )
                    end
                end
            end

            if remaining <= 0 then
                state.done = true
                self:addContractorPerfCounter("fallbackCompleted", 1)
                return finish(true, false)
            end

            if state.removedThisPass
                and state.passIndex
                    < LoggingContractor.PROCESSING_FALLBACK_MAX_PASSES then
                state.passIndex = state.passIndex + 1
                state.stepIndex = 0
                state.upOffsetIndex = 1
                state.sideOffsetIndex = 1
                state.removedThisPass = false
                state.passStartAttachments = remaining
                self:addContractorPerfCounter("fallbackExtraPasses", 1)
            else
                state.done = true
                self:addContractorPerfCounter("fallbackUnresolved", 1)
                return finish(true, false)
            end
        else
            local t = state.stepIndex / steps
            local baseX = startX + axisX * spanLength * t
            local baseY = startY + axisY * spanLength * t
            local baseZ = startZ + axisZ * spanLength * t
            local upOffset = offsets[state.upOffsetIndex]
            local sideOffset = offsets[state.sideOffsetIndex]
            local posX =
                baseX + upX * upOffset + sideX * sideOffset
            local posY =
                baseY + upY * upOffset + sideY * sideOffset
            local posZ =
                baseZ + upZ * upOffset + sideZ * sideOffset

            positionsChecked = positionsChecked + 1
            local removedA = removeSplitShapeAttachments(
                shape,
                posX, posY, posZ,
                axisX, axisY, axisZ,
                upX, upY, upZ,
                LoggingContractor.PROCESSING_FALLBACK_SEARCH_RADIUS,
                LoggingContractor.PROCESSING_FALLBACK_PLANE_WIDTH,
                LoggingContractor.PROCESSING_FALLBACK_PLANE_DEPTH
            )
            removeCalls = removeCalls + 1
            if state.attachmentTypeStats ~= nil then
                local a = state.attachmentTypeStats.fallbackOrientations.A
                a.calls = a.calls + 1
                if removedA == true then
                    a.reported = a.reported + 1
                end
            end
            if perfStartMs ~= nil then
                if removedA == true then
                    returnedTrue = returnedTrue + 1
                elseif removedA == false then
                    returnedFalse = returnedFalse + 1
                else
                    returnedOther = returnedOther + 1
                end
            end

            if not entityExists(shape) then
                state.done = true
                if removedA == true then
                    positionsChanged = positionsChanged + 1
                end
                return finish(true, removedA == true)
            end

            local removedB = removeSplitShapeAttachments(
                shape,
                posX, posY, posZ,
                axisX, axisY, axisZ,
                sideX, sideY, sideZ,
                LoggingContractor.PROCESSING_FALLBACK_SEARCH_RADIUS,
                LoggingContractor.PROCESSING_FALLBACK_PLANE_WIDTH,
                LoggingContractor.PROCESSING_FALLBACK_PLANE_DEPTH
            )
            removeCalls = removeCalls + 1
            if state.attachmentTypeStats ~= nil then
                local b = state.attachmentTypeStats.fallbackOrientations.B
                b.calls = b.calls + 1
                if removedB == true then
                    b.reported = b.reported + 1
                end
            end
            if perfStartMs ~= nil then
                if removedB == true then
                    returnedTrue = returnedTrue + 1
                elseif removedB == false then
                    returnedFalse = returnedFalse + 1
                else
                    returnedOther = returnedOther + 1
                end
            end

            local changed = removedA == true or removedB == true
            if changed then
                positionsChanged = positionsChanged + 1

                if state.attachmentTypeStats ~= nil then
                    local p = state.attachmentTypeStats
                    local after = select(
                        5, self:getContractorSplitShapeStats(shape)
                    )
                    if after < attachments then
                        p.fallbackVerifiedPositions =
                            p.fallbackVerifiedPositions + 1

                        -- Смещения относятся к позиции пробной плоскости;
                        -- записываем только проверенное уменьшение attachments.
                        local offsetKey = string.format(
                            "%d/%d", upOffset, sideOffset
                        )
                        p.fallbackOffsets[offsetKey] =
                            (p.fallbackOffsets[offsetKey] or 0) + 1
                    else
                        p.fallbackReportedWithoutReduction =
                            p.fallbackReportedWithoutReduction + 1
                    end
                end
            end
            state.removedThisPass =
                state.removedThisPass or changed

            state.sideOffsetIndex = state.sideOffsetIndex + 1
            if state.sideOffsetIndex > #offsets then
                state.sideOffsetIndex = 1
                state.upOffsetIndex = state.upOffsetIndex + 1

                if state.upOffsetIndex > #offsets then
                    state.upOffsetIndex = 1
                    state.stepIndex = state.stepIndex + 1
                end
            end

            processedPositions = processedPositions + 1

            if changed then
                return finish(false, true)
            end
        end
    end

    return finish(false, false)
end

-- Создаёт состояние поэтапной очистки уже отделённой крупной ветви.
-- Два исходных прохода и шаг 0.05 м сохраняются без изменений.
function LoggingContractor:createContractorDetachedAttachmentState(shape, attachmentTypeStats)
    local state = {
        shape = shape,
        attachmentTypeStats = attachmentTypeStats,
        done = false
    }

    if shape == nil or shape == 0 or not entityExists(shape) then
        state.done = true
        return state
    end

    local attachments = select(5, self:getContractorSplitShapeStats(shape))
    if attachments <= 0 then
        state.done = true
        return state
    end

    local centerX, centerY, centerZ, dirX, dirY, dirZ, upX, upY, upZ, length =
        self:getContractorShapeMainAxis(shape)

    if centerX == nil or length == nil or length <= 0 then
        Logging.warning(
            "[LoggingContractor] Unable to determine detached branch axis for shape %d",
            shape
        )
        state.done = true
        return state
    end

    state.dirX = dirX
    state.dirY = dirY
    state.dirZ = dirZ
    state.upX = upX
    state.upY = upY
    state.upZ = upZ
    state.length = length
    state.baseX = centerX - dirX * length * 0.5
    state.baseY = centerY - dirY * length * 0.5
    state.baseZ = centerZ - dirZ * length * 0.5
    state.phase = "FAST"
    state.passIndex = 1
    state.distance = LoggingContractor.PROCESSING_DETACHED_SCAN_STEP
    state.stepIndex = 0
    state.fallbackState = nil

    return state
end


-- Продвигает очистку отделённой ветви только на ограниченное число сечений.
-- Возвращает done и признак реального изменения attachments в этом update.
function LoggingContractor:advanceContractorDetachedAttachmentState(state)
    if state == nil or state.done then
        return true, false
    end

    local shape = state.shape
    if shape == nil or shape == 0 or not entityExists(shape) then
        state.done = true
        return true, false
    end

    if state.phase == "FALLBACK" then
        local done, changed =
            self:advanceContractorFallbackTrimState(state.fallbackState)

        if done then
            state.done = true
            state.phase = "DONE"
        end

        return done, changed
    end

    local step = LoggingContractor.PROCESSING_DETACHED_SCAN_STEP
    local processedSections = 0
    local changed = false

    while processedSections
        < LoggingContractor.PROCESSING_DETACHED_SECTIONS_PER_UPDATE do
        if not entityExists(shape)
            or select(5, self:getContractorSplitShapeStats(shape)) <= 0 then
            state.done = true
            return true, changed
        end

        if state.passIndex > 2 then
            state.phase = "FALLBACK"
            state.fallbackState =
                self:createContractorFallbackTrimState(
                    shape, state.attachmentTypeStats
                )

            if state.fallbackState.done then
                state.done = true
                state.phase = "DONE"
                return true, changed
            end

            local done, fallbackChanged =
                self:advanceContractorFallbackTrimState(
                    state.fallbackState
                )

            if done then
                state.done = true
                state.phase = "DONE"
            end

            return done, changed or fallbackChanged
        end

        -- Отделённая ветвь динамическая и между кадрами может двигаться.
        -- Поэтому мировую ось и начало сканирования пересчитываем для текущего
        -- transform, а не продолжаем использовать координаты момента split.
        local centerX, centerY, centerZ,
            dirX, dirY, dirZ,
            upX, upY, upZ,
            currentLength =
            self:getContractorShapeMainAxis(shape)

        if centerX == nil or currentLength == nil or currentLength <= 0 then
            state.done = true
            return true, changed
        end

        if state.distance > currentLength + 0.001 then
            state.passIndex = state.passIndex + 1

            if state.passIndex > 2 then
                state.phase = "FALLBACK"
                state.fallbackState =
                    self:createContractorFallbackTrimState(
                    shape, state.attachmentTypeStats
                )

                if state.fallbackState.done then
                    state.done = true
                    state.phase = "DONE"
                    return true, changed
                end

                local done, fallbackChanged =
                    self:advanceContractorFallbackTrimState(
                        state.fallbackState
                    )

                if done then
                    state.done = true
                    state.phase = "DONE"
                end

                return done, changed or fallbackChanged
            end

            state.distance = state.passIndex == 1 and step or step * 0.5
            state.stepIndex = 0
        else
            state.stepIndex = state.stepIndex + 1

            local baseX = centerX - dirX * currentLength * 0.5
            local baseY = centerY - dirY * currentLength * 0.5
            local baseZ = centerZ - dirZ * currentLength * 0.5
            local sample = self:sampleContractorProcessingSection(
                shape,
                baseX,
                baseY,
                baseZ,
                dirX,
                dirY,
                dirZ,
                upX,
                upY,
                upZ,
                state.distance
            )
            local phase = state.passIndex == 1 and 0
                or LoggingContractor.PROCESSING_DETACHED_SECOND_PASS_PHASE
            local rotationAngle = (
                phase
                + (state.stepIndex - 1)
                    * LoggingContractor.PROCESSING_ATTACHMENT_ROTATION_STEP
            ) % 360

            local removed = self:removeContractorProcessingAttachmentsAtStep(
                shape,
                sample,
                baseX,
                baseY,
                baseZ,
                dirX,
                dirY,
                dirZ,
                upX,
                upY,
                upZ,
                state.distance,
                rotationAngle,
                true,
                state.attachmentTypeStats,
                true
            )

            changed = changed or removed > 0
            state.distance = state.distance + step
            processedSections = processedSections + 1
        end
    end

    return false, changed
end

function LoggingContractor:createContractorPruningState(
    shape,
    baseX,
    baseY,
    baseZ,
    axisX,
    axisY,
    axisZ,
    upX,
    upY,
    upZ,
    trunkLength
)
    axisX, axisY, axisZ = MathUtil.vector3Normalize(axisX, axisY, axisZ)
    upX, upY, upZ = MathUtil.vector3Normalize(upX, upY, upZ)

    return {
        shape = shape,
        length = trunkLength,
        baseX = baseX,
        baseY = baseY,
        baseZ = baseZ,
        axisX = axisX,
        axisY = axisY,
        axisZ = axisZ,
        upX = upX,
        upY = upY,
        upZ = upZ,
        distance = LoggingContractor.PROCESSING_SCAN_STEP,
        history = {},
        cutCount = 0,
        cutsAtStep = 0,
        topologyChangesAtStep = 0,
        blockedDirections = {},
        branchFoundInInitialWindow = false,
        phase = "BRANCHES",
        fullCircleAttachments =
            self:getContractorSplitTypeName(shape) == "SPRUCE"
    }
end


-- Выводит остаток attachments по конкретной I3D-модели.
-- У трёх опытных елей замер выполняется после исключительно адресного
-- прохода; остальные модели проходят штатные FAST и FALLBACK.
function LoggingContractor:logContractorModelAttachmentScan(state, cleanup, remaining, reason)
    if state.attachmentProfileName == nil or cleanup.profileReported then
        return
    end

    cleanup.profileReported = true
    Logging.info(
        "[LoggingContractorProfile] model=%s shape=%s mode=%s initial=%d afterProfile=%s remaining=%d fallback=%s reason=%s",
        state.attachmentProfileName,
        tostring(state.shape),
        cleanup.profileEnabled and "ADDRESS_ONLY" or "FAST",
        cleanup.initialAttachments or 0,
        tostring(cleanup.profileRemaining or "n/a"),
        remaining,
        cleanup.profileEnabled and "DISABLED_TEST" or "ENABLED",
        reason or "scanEnd"
    )
end


-- Обрабатывает одну группу attachments из профильной I3D-модели.
-- Запомненный после спила локальный базис сохраняет корректную ориентацию
-- точек при падении и движении динамического ствола.
-- Возвращает done, changed: done означает окончание всей очистки ствола.
function LoggingContractor:advanceContractorProfileAttachments(state, cleanup)
    local shape = state.shape
    if shape == nil or not entityExists(shape) then
        cleanup.phase = "DONE"
        return true, false
    end

    local before = select(5, self:getContractorSplitShapeStats(shape))
    if before <= 0 then
        cleanup.phase = "DONE"
        cleanup.profileRemaining = 0
        self:logContractorModelAttachmentScan(
            state, cleanup, 0, "profileComplete"
        )
        self:addContractorPerfCounter("profileComplete", 1)
        return true, false
    end

    local points = CONTRACTOR_SPRUCE_PROFILE_POINTS[state.attachmentProfileName]
    local point = points ~= nil and points[cleanup.profileIndex] or nil
    if point == nil then
        -- Тестируем ТОЛЬКО адресные вызовы: не запускаем ни FAST, ни
        -- FALLBACK. Остатки сохраняются для визуальной проверки.
        cleanup.profileRemaining = before
        self:addContractorPerfCounter("profileSkippedFallback", 1)
        self:addContractorPerfCounter("profileRemainingAfterFast", before)
        self:logContractorModelAttachmentScan(
            state, cleanup, before, "addressPointsExhausted"
        )
        cleanup.phase = "DONE"
        return true, false
    end

    local f = state.attachmentProfileFrame
    if f == nil then
        -- При отсутствии преобразования I3D не маскируем ошибку
        -- штатной очисткой: для тестового профиля оставляем листву.
        cleanup.profileRemaining = before
        self:addContractorPerfCounter("profileMissingFrame", 1)
        self:addContractorPerfCounter("profileSkippedFallback", 1)
        self:addContractorPerfCounter("profileRemainingAfterFast", before)
        self:logContractorModelAttachmentScan(
            state, cleanup, before, "missingFrame"
        )
        cleanup.phase = "DONE"
        return true, false
    end

    -- Центр плоскости располагается у поверхности ствола напротив ветви.
    -- Направления рассчитываются в исходных осях I3D, перенесённых в
    -- локальную систему split-shape, а не по текущему мировому углу падения.
    local px, py, pz = point[1], point[2], point[3]
    local radius = math.sqrt(px * px + pz * pz)
    if radius < 0.01 then
        cleanup.profileIndex = cleanup.profileIndex + 1
        return false, false
    end

    local rx, rz = px / radius, pz / radius
    local ox, oy, oz = f.origin[1], f.origin[2], f.origin[3]
    local bx, by, bz = f.axisX[1], f.axisX[2], f.axisX[3]
    local tx, ty, tz = f.axisY[1], f.axisY[2], f.axisY[3]
    local sx, sy, sz = f.axisZ[1], f.axisZ[2], f.axisZ[3]
    local distance = LoggingContractor.PROCESSING_PROFILE_RADIAL_DISTANCE
    local lx = ox + bx * rx * distance + tx * py + sx * rz * distance
    local ly = oy + by * rx * distance + ty * py + sy * rz * distance
    local lz = oz + bz * rx * distance + tz * py + sz * rz * distance

    local wx, wy, wz = localToWorld(shape, lx, ly, lz)
    local radialX, radialY, radialZ = localDirectionToWorld(
        shape, bx * rx + sx * rz, by * rx + sy * rz, bz * rx + sz * rz
    )
    local axisX, axisY, axisZ = localDirectionToWorld(shape, tx, ty, tz)
    radialX, radialY, radialZ = MathUtil.vector3Normalize(
        radialX, radialY, radialZ
    )
    axisX, axisY, axisZ = MathUtil.vector3Normalize(axisX, axisY, axisZ)

    -- Та же native-операция, что и в обычной очистке, но одна плоскость
    -- в известном направлении вместо полного перебора 12 направлений.
    local didDelimb = removeSplitShapeAttachments(
        shape,
        wx, wy, wz,
        -radialX, -radialY, -radialZ,
        axisX, axisY, axisZ,
        LoggingContractor.PROCESSING_ATTACHMENT_THICKNESS,
        LoggingContractor.PROCESSING_ATTACHMENT_MAX_SIZE,
        LoggingContractor.PROCESSING_ATTACHMENT_MAX_SIZE
    )

    cleanup.profileIndex = cleanup.profileIndex + 1
    self:addContractorPerfCounter("profileCalls", 1)

    if not entityExists(shape) then
        cleanup.phase = "DONE"
        return true, true
    end

    local after = select(5, self:getContractorSplitShapeStats(shape))
    local removed = math.max(before - after, 0)
    if removed > 0 then
        self:addContractorPerfCounter("profileAttachmentsRemoved", removed)
    end

    -- При безрезультатной пробе фиксируем исходные координаты группы
    -- и мировую плоскость, фактически переданную native-функции.
    -- false сам по себе не доказывает ошибку координаты: соседние
    -- группы могли уже удалить тот же attachment.
    if didDelimb ~= true or removed == 0 then
        self:addContractorPerfCounter("profileUnsuccessfulProbes", 1)
        Logging.info(
            "[LoggingContractorProfileMiss] model=%s shape=%s group=%d native=%s removed=%d before=%d after=%d rootLocal=(%.3f,%.3f,%.3f) shapeLocalPlane=(%.3f,%.3f,%.3f) worldPlane=(%.3f,%.3f,%.3f) worldNormal=(%.4f,%.4f,%.4f) worldAxis=(%.4f,%.4f,%.4f) dimensions=(%.2f,%.2f,%.2f) modelAxisDistance=%.3f",
            state.attachmentProfileName,
            tostring(shape),
            cleanup.profileIndex - 1,
            tostring(didDelimb),
            removed, before, after,
            px, py, pz,
            lx, ly, lz,
            wx, wy, wz,
            -radialX, -radialY, -radialZ,
            axisX, axisY, axisZ,
            LoggingContractor.PROCESSING_ATTACHMENT_THICKNESS,
            LoggingContractor.PROCESSING_ATTACHMENT_MAX_SIZE,
            LoggingContractor.PROCESSING_ATTACHMENT_MAX_SIZE,
            distance
        )
    end

    -- Диагностика каждой проверенной группы позволяет установить,
    -- какие координаты крепления реально обрабатываются движком.
    Logging.info(
        "[LoggingContractorProfilePoint] model=%s shape=%s group=%d height=%.3f radialX=%.3f radialZ=%.3f native=%s before=%d after=%d removed=%d",
        state.attachmentProfileName,
        tostring(shape),
        cleanup.profileIndex - 1,
        py, rx, rz,
        tostring(didDelimb),
        before, after, removed
    )

    if after <= 0 then
        cleanup.phase = "DONE"
        cleanup.profileRemaining = 0
        self:logContractorModelAttachmentScan(
            state, cleanup, 0, "profileComplete"
        )
        self:addContractorPerfCounter("profileComplete", 1)
        return true, removed > 0
    end

    return false, removed > 0
end


-- Продвигает очистку attachments основного ствола порциями.
-- Для трёх профилированных елей используются только адресные точки I3D.
-- Для остальных деревьев сохраняются FAST (шаг 0,10 м) и FALLBACK.
function LoggingContractor:advanceContractorMainTrunkAttachments(state)
    if state.shape == nil
        or state.shape == 0
        or not entityExists(state.shape) then
        state.attachmentCleanup = nil
        return true, false
    end

    if state.attachmentCleanup == nil then
        local attachments = select(
            5,
            self:getContractorSplitShapeStats(state.shape)
        )
        if attachments <= 0 then
            return true, false
        end

        local useProfile =
            CONTRACTOR_SPRUCE_PROFILE_POINTS[state.attachmentProfileName] ~= nil
        state.attachmentCleanup = {
            phase = useProfile and "PROFILE" or "FAST",
            profileEnabled = useProfile,
            initialAttachments = attachments,
            profileIndex = 1,
            distance = LoggingContractor.PROCESSING_SCAN_STEP,
            attachmentStep = 0,
            fallbackState = nil
        }
        if useProfile then
            self:addContractorPerfCounter("profileStarts", 1)
        end
        if state.attachmentTypeStats ~= nil then
            state.attachmentTypeStats.mainScans =
                state.attachmentTypeStats.mainScans + 1
        end
    end

    local cleanup = state.attachmentCleanup

    if cleanup.phase == "DONE" then
        return true, false
    end

    if cleanup.phase == "PROFILE" then
        return self:advanceContractorProfileAttachments(state, cleanup)
    end

    if cleanup.phase == "FALLBACK" then
        local done, changed =
            self:advanceContractorFallbackTrimState(
                cleanup.fallbackState
            )

        if done then
            cleanup.phase = "DONE"
        end

        return done, changed
    end

    local step = LoggingContractor.PROCESSING_SCAN_STEP
    local processedSections = 0
    local changed = false

    while processedSections
        < LoggingContractor.PROCESSING_ATTACHMENT_SECTIONS_PER_UPDATE do
        if not entityExists(state.shape) then
            state.attachmentCleanup = nil
            return true, changed
        end

        -- Основной ствол после первичного спила динамический. При растянутой
        -- на несколько кадров очистке используем его текущую мировую ось,
        -- чтобы точки removeSplitShapeAttachments следовали за движением ствола.
        local centerX, centerY, centerZ,
            dirX, dirY, dirZ,
            upX, upY, upZ,
            currentLength =
            self:getContractorShapeMainAxis(state.shape)

        if centerX == nil
            or currentLength == nil
            or currentLength <= 0 then
            self:logContractorModelAttachmentScan(
                state, cleanup,
                select(5, self:getContractorSplitShapeStats(state.shape)),
                "axisUnavailable"
            )
            cleanup.phase = "DONE"
            return true, changed
        end

        if cleanup.distance > currentLength + 0.001 then
            local remaining = select(
                5,
                self:getContractorSplitShapeStats(state.shape)
            )

            self:logContractorModelAttachmentScan(
                state, cleanup, remaining, "fastEnd"
            )

            if remaining <= 0 then
                cleanup.phase = "DONE"
                return true, changed
            end

            cleanup.phase = "FALLBACK"
            cleanup.fallbackState =
                self:createContractorFallbackTrimState(
                    state.shape, state.attachmentTypeStats
                )

            if cleanup.fallbackState.done then
                cleanup.phase = "DONE"
                return true, changed
            end

            local done, fallbackChanged =
                self:advanceContractorFallbackTrimState(
                    cleanup.fallbackState
                )

            if done then
                cleanup.phase = "DONE"
            end

            return done, changed or fallbackChanged
        end

        cleanup.attachmentStep = cleanup.attachmentStep + 1

        local baseX = centerX - dirX * currentLength * 0.5
        local baseY = centerY - dirY * currentLength * 0.5
        local baseZ = centerZ - dirZ * currentLength * 0.5
        local sample = self:sampleContractorProcessingSection(
            state.shape,
            baseX,
            baseY,
            baseZ,
            dirX,
            dirY,
            dirZ,
            upX,
            upY,
            upZ,
            cleanup.distance
        )

        local attachmentAngle = 0
        if not state.fullCircleAttachments then
            attachmentAngle = (
                (cleanup.attachmentStep - 1)
                * LoggingContractor.PROCESSING_ATTACHMENT_ROTATION_STEP
            ) % 360
        end

        local removed = self:removeContractorProcessingAttachmentsAtStep(
            state.shape,
            sample,
            baseX,
            baseY,
            baseZ,
            dirX,
            dirY,
            dirZ,
            upX,
            upY,
            upZ,
            cleanup.distance,
            attachmentAngle,
            state.fullCircleAttachments,
            state.attachmentTypeStats,
            false
        )

        if removed > 0 and not state.firstAttachmentRemovalRecorded then
            state.firstAttachmentRemovalRecorded = true
            -- OBB может дать ось от верхушки к комлю. Отдельно отмечаем,
            -- начат ли обход от комля; шаг в обратном направлении не доказывает,
            -- что нижняя часть ствола уже проверена и чистая.
            local fromButt = dirX * state.axisX
                + dirY * state.axisY + dirZ * state.axisZ >= 0
            self:recordContractorFirstAttachmentRemoval(
                state.attachmentTypeStats,
                cleanup.attachmentStep,
                cleanup.distance,
                fromButt
            )
        end

        changed = changed or removed > 0
        cleanup.distance = cleanup.distance + step
        processedSections = processedSections + 1

        if not entityExists(state.shape)
            or select(5, self:getContractorSplitShapeStats(state.shape)) <= 0 then
            self:logContractorModelAttachmentScan(
                state, cleanup, 0, "fastComplete"
            )
            cleanup.phase = "DONE"
            return true, changed
        end
    end

    return false, changed
end


-- Продвигает PRUNE до первого изменения split-shape либо завершения текущей
-- веточной фазы. Длительные проходы удаления attachments ниже выполняются
-- отдельными порциями между update. Возвращает: done, shapeChanged.
function LoggingContractor:advanceContractorPruningState(state, allowMutation)
    if state.shape == nil
        or state.shape == 0
        or not entityExists(state.shape) then
        return true, false
    end

    if state.pendingDetached ~= nil then
        local pending = state.pendingDetached
        pending.shapeIndex = pending.shapeIndex or 1

        while pending.shapeIndex <= #pending.shapes do
            local detachedShape = pending.shapes[pending.shapeIndex]

            if detachedShape == nil or not entityExists(detachedShape) then
                pending.shapeIndex = pending.shapeIndex + 1
                pending.attachmentState = nil
            else
                if pending.attachmentState == nil then
                    pending.attachmentState =
                        self:createContractorDetachedAttachmentState(
                            detachedShape, state.attachmentTypeStats
                        )
                end

                if not pending.attachmentState.done and not allowMutation then
                    return false, false
                end

                local done, changed =
                    self:advanceContractorDetachedAttachmentState(
                        pending.attachmentState
                    )

                if changed then
                    -- После каждого реально изменившего attachments куска
                    -- отдаём управление сетевой синхронизации split-shape.
                    return false, true
                end

                if not done then
                    return false, false
                end

                self:separateContractorBranch(
                    detachedShape,
                    pending.normalX,
                    pending.normalY,
                    pending.normalZ
                )

                local angularX, angularY, angularZ =
                    self:getContractorFallAngularVelocity(
                        state.upX,
                        state.upY,
                        state.upZ
                    )
                self:applyContractorFall(
                    detachedShape,
                    angularX,
                    angularY,
                    angularZ
                )

                pending.shapeIndex = pending.shapeIndex + 1
                pending.attachmentState = nil
            end
        end

        state.pendingDetached = nil
    end

    if state.phase == "ATTACHMENTS" then
        local attachments = select(
            5,
            self:getContractorSplitShapeStats(state.shape)
        )

        if attachments <= 0 then
            if state.attachmentCleanup ~= nil then
                state.attachmentCleanup.phase = "DONE"
            end
            return true, false
        end

        if not allowMutation then
            return false, false
        end

        local done, changed =
            self:advanceContractorMainTrunkAttachments(state)

        if changed then
            return false, true
        end

        return done, false
    end

    local step = LoggingContractor.PROCESSING_SCAN_STEP

    while state.shape ~= nil
        and state.shape ~= 0
        and entityExists(state.shape) do
        local initialWindowEnd = math.min(
            LoggingContractor.PROCESSING_BRANCH_SCAN_LENGTH,
            state.length
        )

        if state.distance > state.length + 0.001
            or (not state.branchFoundInInitialWindow
                and state.distance > initialWindowEnd + 0.001)
            or state.cutCount >= LoggingContractor.PROCESSING_BRANCH_MAX_TOTAL_CUTS then
            state.phase = "ATTACHMENTS"
            return self:advanceContractorPruningState(state, allowMutation)
        end

        local sample = self:sampleContractorProcessingSection(
            state.shape,
            state.baseX,
            state.baseY,
            state.baseZ,
            state.axisX,
            state.axisY,
            state.axisZ,
            state.upX,
            state.upY,
            state.upZ,
            state.distance
        )

        local searchLargeBranches =
            state.distance <= initialWindowEnd + 0.001
            or state.branchFoundInInitialWindow

        if sample ~= nil
            and searchLargeBranches
            and #state.history >= LoggingContractor.PROCESSING_BRANCH_BASELINE_SAMPLES
            and state.cutsAtStep < LoggingContractor.PROCESSING_BRANCH_MAX_CUTS_PER_STEP
            and state.topologyChangesAtStep
                < LoggingContractor.PROCESSING_BRANCH_MAX_CUTS_PER_STEP then
            local baseline = self:getContractorBranchBaseline(
                state.history,
                1,
                #state.history
            )

            local nextSample = nil
            if state.distance + step <= state.length + 0.001 then
                nextSample = self:sampleContractorProcessingSection(
                    state.shape,
                    state.baseX,
                    state.baseY,
                    state.baseZ,
                    state.axisX,
                    state.axisY,
                    state.axisZ,
                    state.upX,
                    state.upY,
                    state.upZ,
                    state.distance + step
                )
            end

            local candidates = self:getContractorProcessingBranchCandidates(
                sample,
                baseline,
                nextSample,
                state.blockedDirections
            )
            local candidate = candidates[1]

            if candidate ~= nil then
                if state.distance
                    <= LoggingContractor.PROCESSING_BRANCH_SCAN_LENGTH + 0.001 then
                    state.branchFoundInInitialWindow = true
                end

                -- Без доступного сетевого mutation-slot дорогое пробирование
                -- продольного реза всё равно не может завершиться splitShape.
                if not allowMutation then
                    return false, false
                end

                local changed, detached =
                    self:cutContractorProcessingBranchOnce(
                        state,
                        sample,
                        baseline,
                        candidate,
                        true
                    )

                if changed then
                    state.topologyChangesAtStep =
                        state.topologyChangesAtStep + 1

                    if detached then
                        state.cutCount = state.cutCount + 1
                        state.cutsAtStep = state.cutsAtStep + 1
                    end

                    state.blockedDirections = {}
                    return false, true
                end

                if not allowMutation then
                    return false, false
                end

                state.blockedDirections[candidate.direction] = true
            else
                state.blockedDirections = {}
                state.cutsAtStep = 0
                state.topologyChangesAtStep = 0

                table.insert(state.history, sample)
                while #state.history
                    > LoggingContractor.PROCESSING_BRANCH_BASELINE_SAMPLES do
                    table.remove(state.history, 1)
                end

                state.distance = state.distance + step
            end
        else
            state.blockedDirections = {}
            state.cutsAtStep = 0
            state.topologyChangesAtStep = 0

            if sample ~= nil then
                table.insert(state.history, sample)
                while #state.history
                    > LoggingContractor.PROCESSING_BRANCH_BASELINE_SAMPLES do
                    table.remove(state.history, 1)
                end
            end

            state.distance = state.distance + step
        end
    end

    return true, false
end


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

-- Адресный профиль взрослой spruce1_stage03: 103 группы из I3D.shapes.
-- Основание группы выбирается в ОДНОМ локальном кластере вокруг вершины
-- с минимальным расстоянием до оси: по высоте +/-0,26 м, по радиусу
-- не дальше minRadius+0,26 м (но не меньше 0,30 м от оси).
-- Высота усреднена в этом кластере с весом 1/(radius+0,1);
-- направление рассчитано по вершинам того же околоствольного участка.
-- Это исключает смешивание вершин двух участков ветки, разделённых
-- по высоте на 2–3 м, при предыдущем усреднении ближайших шести.
-- Все 103 точки заданы в исходной локальной системе координат I3D.
local CONTRACTOR_SPRUCE1_STAGE03_POINTS = {
    {0.516, 12.251, 0.857},
    {0.981, 10.957, 0.193},
    {0.036, 10.523, -0.999},
    {-0.974, 9.935, -0.227},
    {-0.784, 10.54, 0.621},
    {-0.269, 9.164, -0.963},
    {0.935, 8.705, 0.354},
    {-0.964, 8.493, 0.266},
    {-0.675, 7.352, 0.738},
    {0.942, 7.54, -0.335},
    {-0.23, 12.862, 0.973},
    {-0.997, 12.051, -0.08},
    {0.712, 11.8, -0.702},
    {0.237, 34.596, -0.972},
    {-0.281, 34.571, -0.96},
    {-0.942, 27.632, -0.335},
    {0.988, 13.264, -0.155},
    {-0.222, 9.242, 0.975},
    {0.467, 9.928, 0.884},
    {-0.88, 14.104, 0.475},
    {-0.798, 14.94, -0.602},
    {-0.513, 11.285, -0.859},
    {-0.333, 12.605, -0.943},
    {0.354, 13.595, 0.935},
    {-0.935, 13.418, -0.354},
    {-0.372, 14.892, 0.928},
    {-0.94, 15.448, 0.34},
    {0.98, 16.243, -0.197},
    {0.304, 14.027, -0.953},
    {0.795, 15.351, -0.607},
    {0.906, 14.536, 0.424},
    {-0.834, 16.354, 0.552},
    {-0.966, 17.642, 0.258},
    {0.553, 15.703, 0.833},
    {0.914, 16.624, 0.406},
    {0.8, 17.97, 0.601},
    {-0.008, 17.03, 1},
    {-0.558, 18.48, 0.83},
    {-0.388, 17.618, -0.922},
    {0.826, 19.396, 0.564},
    {-0.975, 17.157, -0.221},
    {0.279, 18.501, -0.96},
    {0.904, 18.862, -0.427},
    {0.272, 19.673, -0.962},
    {-0.836, 19.319, -0.548},
    {-0.666, 20.475, -0.746},
    {-0.903, 19.814, 0.43},
    {0.993, 20.258, 0.118},
    {-0.244, 20.578, 0.97},
    {0.651, 21.522, 0.759},
    {-0.021, 21.832, -1},
    {0.996, 22.455, 0.091},
    {-0.305, 22.318, 0.952},
    {-0.873, 22.566, -0.487},
    {-0.859, 21.335, -0.512},
    {0.998, 33.258, 0.057},
    {0.75, 33.731, -0.661},
    {0.942, 23.6, 0.336},
    {-0.638, 24.09, 0.77},
    {-0.414, 23.945, -0.91},
    {-0.406, 29.153, -0.914},
    {0.85, 29.536, -0.526},
    {-0.327, 29.33, 0.945},
    {0.709, 21.05, -0.706},
    {-0.951, 28.89, 0.309},
    {0.887, 29.009, 0.462},
    {0.555, 30.086, 0.832},
    {-0.812, 30.353, 0.584},
    {0.099, 30.24, -0.995},
    {0.919, 30.472, -0.394},
    {0.591, 24.896, 0.807},
    {-0.731, 30.844, -0.682},
    {0.706, 31.26, -0.709},
    {-0.096, 31.052, 0.995},
    {-1, 31.129, -0.026},
    {-0.082, 31.803, -0.997},
    {0.827, 31.603, 0.563},
    {-0.21, 32.101, 0.978},
    {0.921, 32.278, -0.389},
    {-0.987, 32.502, -0.162},
    {-0.072, 32.846, -0.997},
    {0.628, 32.747, 0.779},
    {-0.813, 33.017, 0.582},
    {-0.695, 33.339, -0.719},
    {0.046, 33.539, 0.999},
    {-1, 33.836, 0.017},
    {0.941, 33.957, 0.338},
    {-0.71, 35.084, 0.704},
    {0.333, 28.071, 0.943},
    {0.923, 24.452, -0.386},
    {-0.995, 24.335, 0.098},
    {0.999, 25.784, 0.038},
    {0.747, 26.459, -0.664},
    {0.198, 25.226, -0.98},
    {-0.785, 25.418, 0.62},
    {0.055, 26.217, 0.999},
    {-0.994, 26.68, 0.114},
    {-0.608, 26.076, -0.794},
    {-0.139, 27.16, -0.99},
    {-0.544, 27.493, 0.839},
    {0.572, 27.169, 0.82},
    {0.975, 27.659, -0.222},
    {0.317, 27.951, -0.948}
}

-- Профили двух ранних стадий ели, извлечённые из собственных I3D.shapes карты.
-- Для каждой группы вычислен один корневой кластер ближайших к оси вершин.
-- Локальная высота и направление X/Z задают адресную плоскость очистки.
-- spruceVar1_stage01: 37 групп LOD0AttachmentsShape, 10260 вершин.
local CONTRACTOR_SPRUCE1_STAGE01_POINTS = {
    {1, 11.505, -0.031},
    {-0.064, 10.863, -0.998},
    {-0.742, 3.93, -0.67},
    {0.911, 9.576, 0.413},
    {0.971, 10.037, -0.239},
    {-0.072, 5.427, -0.997},
    {0.871, 5.768, -0.491},
    {-0.655, 5.64, 0.755},
    {-0.999, 5.146, -0.045},
    {0.866, 5.313, 0.501},
    {0.232, 6.373, 0.973},
    {-0.96, 6.64, 0.28},
    {0.431, 6.518, -0.903},
    {0.955, 6.769, 0.295},
    {-0.51, 7.127, -0.86},
    {0.91, 7.569, -0.415},
    {-0.473, 7.356, 0.881},
    {-0.936, 7.436, -0.351},
    {0.195, 8.114, -0.981},
    {0.519, 7.908, 0.855},
    {-0.571, 8.438, 0.821},
    {0.999, 8.601, -0.053},
    {-0.9, 8.815, -0.435},
    {0.386, 9.154, -0.922},
    {0.288, 9.063, 0.958},
    {-0.949, 9.33, 0.315},
    {-0.433, 9.653, -0.901},
    {-0.283, 9.857, 0.959},
    {-0.902, 10.129, -0.431},
    {0.127, 10.266, 0.992},
    {-0.999, 10.863, -0.04},
    {0.018, 4.381, 1},
    {0.239, 3.452, 0.971},
    {0.996, 3.97, 0.086},
    {0.42, 4.254, -0.907},
    {-0.91, 3.135, 0.414},
    {0.114, 11.504, -0.993}
}

-- spruceVar2_stage01: 22 группы LOD0AttachmentsShape, 3384 вершины.
-- У группы 20 радиальное направление по выбранному кластеру менее
-- определённо; её результат отдельно проверим в игровом логе.
local CONTRACTOR_SPRUCE2_STAGE01_POINTS = {
    {0.943, 5.313, -0.333},
    {-0.399, 5.235, -0.917},
    {0.984, 4.566, -0.179},
    {0.593, 4.869, -0.806},
    {-0.743, 2.692, 0.67},
    {0.962, 2.868, 0.271},
    {-0.978, 3.113, -0.21},
    {0.34, 3.406, -0.941},
    {0.659, 3.374, 0.752},
    {-0.171, 3.79, 0.985},
    {-0.989, 4.619, -0.15},
    {-0.584, 4.117, 0.811},
    {-0.995, 4.508, 0.104},
    {0.784, 4.602, 0.621},
    {0.435, 5.331, 0.9},
    {0.965, 5.266, -0.261},
    {-0.102, 4.73, 0.995},
    {-0.43, 5.056, 0.903},
    {-0.343, 5.189, -0.939},
    {-0.993, 5.161, 0.114},
    {0.155, 1.378, -0.988},
    {-0.984, 3.638, 0.18}
}

-- Последний профиль: 70 геометрических групп LOD0AttachmentsShape
-- из присланного spruceVar1_stage02.i3d.shapes (29111 вершин).
-- Корень выбирается внутри одного локального кластера вершин возле
-- оси ствола. Высота берётся по этому кластеру, направление X/Z
-- определяется по околоствольной части той же группы.
-- У групп 20 и 53 направление неустойчиво из-за разных ближних
-- участков геометрии: отдельно проверяем их в игровом логе.
local CONTRACTOR_SPRUCE1_STAGE02_POINTS = {
    {0.713, 25.118, 0.701},
    {-0.782, 18.139, -0.623},
    {-0.87, 8.148, 0.494},
    {0.688, 8.488, 0.725},
    {-0.568, 8.987, 0.823},
    {0.995, 8.134, 0.096},
    {-0.75, 7.667, 0.661},
    {0.961, 9.007, 0.275},
    {0.927, 9.369, -0.376},
    {0.728, 10.181, -0.686},
    {-0.447, 9.83, -0.895},
    {0.049, 10.99, -0.999},
    {-0.971, 10.329, -0.24},
    {0.874, 10.763, -0.486},
    {0.027, 11.084, 1},
    {-0.328, 12.033, 0.945},
    {0.743, 12.345, -0.67},
    {0.879, 12.966, 0.477},
    {-0.322, 12.822, 0.947},
    {-0.419, 13.069, -0.908},
    {0.604, 11.836, 0.797},
    {0.542, 23.752, 0.841},
    {0.72, 24.236, -0.694},
    {0.848, 14.106, 0.531},
    {-0.312, 14.619, 0.95},
    {0.875, 14.445, -0.484},
    {-0.465, 19.659, -0.885},
    {0.938, 20.032, -0.348},
    {-0.63, 19.883, 0.776},
    {0.881, 11.559, -0.473},
    {-0.864, 19.396, 0.503},
    {0.829, 19.521, 0.559},
    {0.786, 20.59, 0.619},
    {-0.943, 20.873, 0.334},
    {0.764, 20.748, -0.645},
    {0.821, 20.972, -0.571},
    {0.434, 15.404, 0.901},
    {-0.485, 21.355, -0.874},
    {0.491, 21.763, -0.871},
    {-0.441, 21.561, 0.897},
    {-0.848, 21.642, -0.53},
    {-0.112, 22.308, -0.994},
    {0.85, 22.107, 0.527},
    {-0.51, 22.615, 0.86},
    {0.942, 22.791, 0.336},
    {-0.716, 22.995, -0.698},
    {0.299, 23.355, -0.954},
    {0.479, 23.254, 0.878},
    {-1, 23.516, -0.013},
    {-0.308, 23.827, -0.952},
    {0.159, 24.06, 0.987},
    {-0.81, 24.347, 0.587},
    {0.821, 24.448, 0.571},
    {0.342, 25.091, 0.94},
    {-0.22, 18.594, 0.975},
    {1, 14.96, -0.018},
    {-0.611, 14.848, -0.792},
    {0.854, 16.293, 0.52},
    {0.733, 17.731, 0.681},
    {0.49, 15.739, -0.872},
    {-0.989, 15.927, 0.147},
    {0.224, 16.723, 0.975},
    {-0.748, 17.194, -0.664},
    {-0.769, 16.583, -0.639},
    {-0.238, 17.66, -0.971},
    {-0.976, 17.998, 0.218},
    {-0.628, 17.702, 0.778},
    {0.957, 18.175, 0.289},
    {0.704, 18.46, -0.711},
    {-0.996, 12.946, 0.094}
}

-- Все шесть моделей ели теперь используют свои I3D-координаты.
-- Плоскости обрабатываются однократно без FAST и FALLBACK.
local CONTRACTOR_SPRUCE_PROFILE_POINTS = {
    spruce1_stage01 = CONTRACTOR_SPRUCE1_STAGE01_POINTS,
    spruce1_stage02 = CONTRACTOR_SPRUCE1_STAGE02_POINTS,
    spruce1_stage03 = CONTRACTOR_SPRUCE1_STAGE03_POINTS,
    spruce2_stage01 = CONTRACTOR_SPRUCE2_STAGE01_POINTS,
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
-- У всех шести моделей ели замер выполняется после адресного
-- прохода; остальные модели проходят штатные FAST и FALLBACK.
function LoggingContractor:logContractorModelAttachmentScan(state, cleanup, remaining, reason)
    if state.attachmentProfileName == nil or cleanup.profileReported then
        return
    end

    cleanup.profileReported = true
    Logging.info(
        "[LoggingContractorProfile] model=%s shape=%s mode=%s calibration=%s initial=%d afterProfile=%s remaining=%d fallback=%s reason=%s",
        state.attachmentProfileName,
        tostring(state.shape),
        cleanup.profileEnabled and "ADDRESS_ONLY" or "FAST",
        (
            state.attachmentProfileName == "spruce1_stage01"
            or state.attachmentProfileName == "spruce1_stage02"
            or state.attachmentProfileName == "spruce1_stage03"
            or state.attachmentProfileName == "spruce2_stage01"
        ) and "ROOT_LOCAL_CLUSTER" or "ORIGINAL",
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
-- Для всех шести моделей ели используются только адресные точки.
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


#!/usr/bin/env tarantool
--- Гейт покрытия: порога у luacov нет, поэтому он считается здесь.
---
--- Падает, если хотя бы один файл покрыт ниже порога ИЛИ если файл
--- прикладного кода вовсе не попал в статистику. Второе важнее первого:
--- модуль, который не загрузил ни один тест, отсутствует в отчёте luacov
--- и без этой проверки молча засчитывался бы как стопроцентный.
---
--- Непокрытые строки считает сам luacov, а не этот гейт. Причина в том,
--- что «строка не исполнялась» и «строку исполнить нельзя» различаются
--- только разбором исходника: комментарий, `end`, пустая строка и объявление
--- функции никогда не получают попаданий, и считать их пропущенными
--- значило бы требовать невозможного. Разбор живёт в luacov.reporter
--- (а с cluacov — в разборе байткода), и повторять его здесь нельзя:
--- своя мерка разошлась бы с той, по которой отчёт показывает строки.
---
--- Прямое чтение файла статистики для этого не годится: luacov.stats.load
--- отбрасывает строки с нулём попаданий, и по нему пропущенных не видно
--- вовсе — любой файл выглядит покрытым полностью.
---
--- Запуск: tarantool tools/coverage_gate.lua [порог]

local fio = require('fio')
local luacov_reporter = require('luacov.reporter')
local luacov_stats = require('luacov.stats')
local luacov_runner = require('luacov.runner')

--- Планка покрытия. Ровно 100 % — осознанное решение: строка, которую
--- не исполнил ни один тест, либо не нужна, либо не проверена.
local DEFAULT_THRESHOLD = 100

--- Каталоги, весь Lua-код которых обязан быть покрыт.
local WATCHED_DIRECTORIES = { 'tnt' }

--- Сколько непокрытых строк показывать по каждому файлу.
local SHOWN_MISSED_LINES = 10

local threshold = tonumber(arg[1]) or DEFAULT_THRESHOLD
local project_root = fio.abspath('.')

--- Приводит путь к виду, удобному для чтения в отчёте.
---
--- Путь под корнем узнаётся по тому, что складывается из корня и хвоста.
--- Сверка начала строки через `sub(1, n)` не заметила бы ошибки
--- в границе: `sub(0, n)` отдаёт в Lua ту же строку.
---@param path string
---@return string
local function relative(path)
    local tail = path:sub(#project_root + 2)
    if project_root .. '/' .. tail == path then
        return tail
    end
    return path
end

--- Рекурсивно собирает Lua-файлы каталога.
---
--- Тесты самих пакетов в охват не входят — они проверяют, а не проверяются.
--- Исключения берутся из .luacov: список того, что покрывать незачем,
--- должен быть один, иначе он расходится и гейт начинает требовать
--- покрытия от сгенерированных данных.
---@param directory string
---@param accumulator string[] Абсолютные пути найденных файлов
local function collect_lua_files(directory, accumulator)
    for _, entry in ipairs(fio.listdir(directory) or {}) do
        local path = fio.pathjoin(directory, entry)
        if fio.path.is_dir(path) then
            if entry ~= 'test' then
                collect_lua_files(path, accumulator)
            end
        elseif entry:match('%.lua$') and luacov_runner.file_included(path) then
            table.insert(accumulator, fio.abspath(path))
        end
    end
end

-- Конфигурация нужна и сбору файлов, и разбору статистики: она читается
-- один раз и до всего остального.
local configuration = luacov_runner.load_config()
local stats = luacov_stats.load(configuration.statsfile)

if stats == nil or next(stats) == nil then
    io.stderr:write(('Статистика покрытия не найдена: %s\n'):format(configuration.statsfile))
    io.stderr:write('Сначала прогоните тесты с ключом --coverage.\n')
    os.exit(1)
end

-- Один и тот же файл попадает в статистику дважды, если его грузили
-- и относительным путём, и абсолютным: так бывает, когда часть тестов
-- работает на поднятом инстансе со своим рабочим каталогом. Строки
-- сливаются по абсолютному пути до разбора, потому что дальше файл
-- читается с диска, и два имени одного файла дали бы два отчёта.
--
-- Сливает их сам luacov (`update_stats`): тем же сложением попаданий он
-- копит в одном файле статистику нескольких процессов и сводит два имени
-- одного файла в своём отчёте, и своя мерка разошлась бы с его мерой.
---@cast stats table
local merged = {}

for filename, file_stats in pairs(stats) do
    if luacov_runner.file_included(filename) then
        local absolute = fio.abspath(filename)
        local known = merged[absolute]

        if known == nil then
            merged[absolute] = file_stats
        else
            luacov_runner.update_stats(known, file_stats)
        end
    end
end

-- Слитая статистика кладётся рядом с исходной: разбор берёт её оттуда,
-- а исходную трогать нельзя — по ней считают покрытие следующие прогоны.
local merged_statsfile = configuration.statsfile .. '.merged'
luacov_stats.save(merged_statsfile, merged)

--- Сводка по файлам, которую собирает разбор luacov.
local report = {}

--- Непокрытые строки по файлам: номер строки и её содержимое.
local missed_lines = {}

--- Разбор luacov, из которого берутся попадания и пропуски.
---
--- Наследуется от обычного отчёта, а не от заготовки: подробный
--- `luacov.report.out` с пометками против каждой строки остаётся на месте,
--- и непокрытую строку видно в нём глазами.
local Gate = setmetatable({}, luacov_reporter.DefaultReporter)
Gate.__index = Gate

function Gate:on_mis_line(filename, line_number, line)
    luacov_reporter.DefaultReporter.on_mis_line(self, filename, line_number, line)

    local lines = missed_lines[filename] or {}
    table.insert(lines, { number = line_number, text = line })
    missed_lines[filename] = lines
end

function Gate:on_end_file(filename, hits, missed)
    luacov_reporter.DefaultReporter.on_end_file(self, filename, hits, missed)

    table.insert(report, {
        absolute = filename,
        filename = relative(filename),
        hit = hits,
        missed = missed,
        percent = (hits + missed) > 0 and (hits / (hits + missed) * 100) or 100,
    })
end

configuration.statsfile = merged_statsfile

local gate, gate_error = Gate:new(configuration)

if gate == nil then
    io.stderr:write(('Разбор покрытия не удался: %s\n'):format(tostring(gate_error)))
    os.exit(1)
end

---@cast gate table
gate:run()
gate:close()
fio.unlink(merged_statsfile)

local measured = {}
local total_hit, total_missed = 0, 0

for _, entry in ipairs(report) do
    measured[entry.absolute] = true
    total_hit = total_hit + entry.hit
    total_missed = total_missed + entry.missed
end

-- Файлы, которых нет в статистике вовсе, — нулевое покрытие.
local untouched = {}
for _, directory in ipairs(WATCHED_DIRECTORIES) do
    if fio.path.is_dir(directory) then
        local files = {}
        collect_lua_files(directory, files)
        for _, path in ipairs(files) do
            if not measured[path] then
                table.insert(untouched, relative(path))
            end
        end
    end
end

table.sort(untouched)

-- Отчёт своей сортировки не требует: разбор luacov идёт по файлам
-- в порядке путей, и строки отчёта приходят уже по порядку.

print(('%-52s %8s %10s %8s'):format('ФАЙЛ', 'ПОКРЫТО', 'ПРОПУЩЕНО', 'ПРОЦЕНТ'))
print(string.rep('-', 82))

local failed = {}
for _, entry in ipairs(report) do
    print(('%-52s %8d %10d %7.1f%%'):format(entry.filename, entry.hit, entry.missed, entry.percent))
    if entry.percent < threshold then
        table.insert(failed, entry)
    end
end

for _, filename in ipairs(untouched) do
    print(('%-52s %8d %10s %7.1f%%'):format(filename, 0, '—', 0))
end

local total_relevant = total_hit + total_missed
local total_percent = total_relevant > 0 and (total_hit / total_relevant * 100) or 0

print(string.rep('-', 82))
print(('%-52s %8d %10d %7.1f%%'):format('ИТОГО', total_hit, total_missed, total_percent))

if #untouched > 0 then
    io.stderr:write(
        ('\nНе загружено ни одним тестом — файлов: %d\n'):format(#untouched)
    )
    for _, filename in ipairs(untouched) do
        io.stderr:write(('  %s\n'):format(filename))
    end
end

if #failed > 0 then
    io.stderr:write(
        ('\nПокрытие ниже порога %.1f%% — файлов: %d\n'):format(threshold, #failed)
    )
    for _, entry in ipairs(failed) do
        io.stderr:write(
            ('  %s — %.1f%%, не покрыто строк: %d\n'):format(
                entry.filename,
                entry.percent,
                entry.missed
            )
        )

        -- Номера строк нужны сразу: иначе за каждым падением гейта следует
        -- открывание отчёта и поиск в нём глазами.
        local lines = missed_lines[entry.absolute] or {}
        for index, line in ipairs(lines) do
            if index > SHOWN_MISSED_LINES then
                io.stderr:write(('      … и ещё строк: %d\n'):format(#lines - SHOWN_MISSED_LINES))
                break
            end

            -- Отступ срезается разбором, а не заменой: замена `^%s+` и `^%s*`
            -- дают одно и то же, и ошибку в шаблоне никто бы не заметил.
            io.stderr:write(('      %d: %s\n'):format(line.number, line.text:match('^%s*(.-)$')))
        end
    end
end

if #untouched > 0 or #failed > 0 then
    os.exit(1)
end

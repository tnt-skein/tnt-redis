--- Исходники пакетов для проверок — мимо загрузчика `.rocks`.
---
--- У Tarantool собственный загрузчик `.rocks`: он идёт раньше `package.path`
--- и на `require` подсунул бы установленную копию. Покрытие считалось бы
--- по ней, исходники в репозитории числились бы непокрытыми, а проверка
--- шла бы против вчерашнего кода — до следующего `make libs`. Поэтому
--- проверки грузят файлы сами, в порядке зависимостей, и кладут их
--- в `package.loaded` под именами модулей: `require` изнутри пакета
--- находит их первыми.
---
--- Исходник обязан вернуть модуль. Пустое значение в `package.loaded`
--- для `require` означает «не загружен» — и `nil`, и `false`, — и следующий
--- модуль списка молча взял бы зависимость из `.rocks`. По симптомам этого
--- не видно: проверки и покрытие зелёные, но считаются по чужому коду.
---
--- Исходник вытесняет из `package.loaded` прежний экземпляр, а соседи,
--- взятые раньше, — установленные копии других пакетов — держат ссылку
--- на прежний. Поэтому выгрузка возвращает его на место, а не оставляет
--- пустоту, и загрузчик помнит все экземпляры под именем: подмену, которая
--- должна дойти до всех, ставят на каждый (так ловушка журнала ловит
--- записи и соседей, и исходников, загруженных после неё).

local fio = require('fio')

local Module = {}

--- Что лежало под именем до исходников: имя → `{ value = прежнее }`.
---
--- Помнится первое вытесненное до выгрузки: повторная загрузка того же
--- списка вытесняет уже свой исходник, а вернуть надо то, что было до них.
---@type table<string, { value: any }>
local displaced = {}

--- Экземпляры, которые загрузчик видел под именем: имя → набор, где
--- экземпляр — и ключ, и значение.
---
--- Слабые обе стороны: экземпляр, которого никто не держит, подменять
--- незачем, а иначе каждая загрузка оставляла бы свой навсегда. Значение
--- слабое тоже: сильное держало бы свой же ключ, и набор не пустел бы.
---@type table<string, table<any, any>>
local known = {}

--- Кого звать на каждом новом экземпляре под именем.
---@type table<string, fun(instance: any)>
local followers = {}

--- Запоминает экземпляр под именем.
---@param name string
---@param value any Пустое не запоминается: держать под ним нечего
local function witness(name, value)
    local instances = known[name]

    if instances == nil then
        instances = setmetatable({}, { __mode = 'kv' })
        known[name] = instances
    end

    if value ~= nil then
        instances[value] = value
    end
end

---@class TntTestingSource
---@field name string Имя модуля, например tnt.pool
---@field path string Путь к файлу от корня дерева

--- Загружает исходники в `package.loaded` и отдаёт названный.
---@param modules TntTestingSource[] Модули в порядке зависимостей
---@param name string Какой из них вернуть
---@return any
function Module.load(modules, name)
    for _, module in ipairs(modules) do
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('исходник %s не читается: %s'):format(module.name, tostring(failure)))
        end

        local value = chunk()

        if not value then
            error(
                ('исходник %s (%s) не вернул модуль: require взял бы установленную копию из .rocks'):format(
                    module.name,
                    module.path
                )
            )
        end

        local previous = package.loaded[module.name]

        if displaced[module.name] == nil then
            displaced[module.name] = { value = previous }
        end

        witness(module.name, previous)
        witness(module.name, value)
        package.loaded[module.name] = value

        local follower = followers[module.name]

        if follower ~= nil then
            follower(value)
        end
    end

    return Module.module(name)
end

--- Уже загруженный модуль.
---
--- Нужен там, где проверке нужны два модуля одного пакета: второй вызов
--- `load` собрал бы их заново, и первый модуль остался бы со ссылками
--- на прежние — подмена средств в одном не доходила бы до другого.
---@param name string
---@return any
function Module.module(name)
    local loaded = package.loaded[name]

    if not loaded then
        error(('модуль %s не загружен'):format(name))
    end

    return loaded
end

--- Склеивает списки модулей в один, в порядке перечисления и без повторов.
---
--- Пакет, который берёт соседний пакет, грузит и его исходники — иначе
--- проверка пошла бы в установленную копию. Порядок здесь и есть
--- зависимость: первым идёт то, что берут, последним — то, что берёт.
---
--- Повтор остаётся на первом месте. Соседи берут одно и то же — внешние
--- зависимости, журнал, проверяльщик, — и загруженный второй раз модуль достался бы
--- только тем, кто грузился после него: у первых остались бы ссылки
--- на прежний, и подмена средств в одном не доходила бы до другого.
---@param ... TntTestingSource[]
---@return TntTestingSource[]
function Module.merge(...)
    local merged = {}
    local seen = {}

    for _, list in ipairs({ ... }) do
        for _, module in ipairs(list) do
            if not seen[module.name] then
                seen[module.name] = true
                table.insert(merged, module)
            end
        end
    end

    return merged
end

--- Список модулей пакета по именам: путь складывается из имени.
---
--- Именами, а не парами «имя — путь»: в паре имя повторяется в пути слово
--- в слово, и список чужого пакета выходит дословно тем же, что у него
--- самого, — вплоть до того, что гейт дублей считает его копией.
---@param package string Каталог пакета в `libs/`, например tnt-pool
---@param names string[] Имена модулей в порядке зависимостей
---@return TntTestingSource[]
function Module.of(package, names)
    local list = {}

    for _, name in ipairs(names) do
        local inside = name:gsub('%.', '/')

        table.insert(list, { name = name, path = ('libs/%s/%s.lua'):format(package, inside) })
    end

    return list
end

--- Тот же список с путями от корня.
---
--- Узел, поднятый проверкой, живёт в своём каталоге и относительных путей
--- не поймёт; то же с дочерним процессом.
---@param modules TntTestingSource[]
---@return TntTestingSource[]
function Module.absolute(modules)
    local list = {}

    for _, module in ipairs(modules) do
        table.insert(list, { name = module.name, path = fio.abspath(module.path) })
    end

    return list
end

--- Убирает исходники из `package.loaded` и возвращает то, что они
--- вытеснили.
---
--- Исходник убирается, иначе следующая проверка получила бы модуль
--- с подменёнными средствами от предыдущей. А вместо него встаёт прежний
--- экземпляр, а не пустота: на пустоту следующий `require` собрал бы ещё
--- один, и соседи, взятые до исходников, остались бы с прежним — подмена,
--- поставленная на новый, до них бы не дошла.
---
--- Имя, которого загрузчик не вытеснял, выгрузка не трогает: исходника
--- под ним нет, либо прежний экземпляр уже вернули — группы проверок
--- выгружают один список не по разу, и вторая выгрузка иначе выбросила бы
--- то, что вернула первая.
---@param modules TntTestingSource[]
function Module.unload(modules)
    for _, module in ipairs(modules) do
        local previous = displaced[module.name]

        if previous ~= nil then
            displaced[module.name] = nil
            package.loaded[module.name] = previous.value
        end
    end
end

--- Все известные экземпляры модуля: нынешний и те, что загрузчик видел
--- под его именем, — вытесненные и загруженные.
---
--- Порядок не задан: подмена ставится на все сразу.
---@param name string
---@return any[]
function Module.instances(name)
    witness(name, package.loaded[name])

    local list = {}

    for _, instance in pairs(known[name]) do
        table.insert(list, instance)
    end

    return list
end

--- Кого звать на каждом экземпляре модуля, который загрузчик соберёт
--- позже; `nil` — никого.
---
--- Следящий у имени один, последний поставленный. Двое боролись бы
--- за каждый новый экземпляр, и подмена на нём зависела бы от того,
--- кто встал раньше, — ровно та зависимость от порядка, которую слежение
--- убирает.
---@param name string
---@param visit (fun(instance: any))|nil
function Module.follow(name, visit)
    followers[name] = visit
end

return Module

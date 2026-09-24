--- Общие средства проверок драйвера Redis.
---
--- Двойников два, и оба разговаривают байтами RESP. Читатель из строки —
--- для разбора ответа: он отдаёт байты так же, как сокет (`chunk`,
--- `delimiter`), и на нём проверяется каждая ветка протокола без сети.
--- Двойник сервера — настоящий сокет `tcp_server` на петле, отвечающий
--- по сценарию: сроки, обрыв посреди ответа, закрытие простаивающего
--- соединения и отмена файбера держатся на ядре, и подделка сокета тут
--- доказала бы только, что мы правильно разговариваем сами с собой.
--- Поведение настоящего Redis проверяет `redis_live_test.lua`.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must`, `tnt.log`, `tnt.pool`, `tnt.retry`, `tnt.external`,
--- `tnt.storage`, `tnt.tls` — берутся из `.rocks` обычным `require`:
--- проверяется этот пакет, а не они.
---
--- Оснастка в `test/testing/` — загрузчик исходников, часы двойника
--- и ловушка журнала — грузится так же, файлами, и один раз на процесс:
--- второй экземпляр загрузчика не знал бы, что вытеснил первый, и не вернул
--- бы вытесненное на место.
---
--- Проверки берут всё через этот помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в наборе, где пакет живёт рядом со своими зависимостями.

local fiber = require('fiber')
local fio = require('fio')
local socket = require('socket')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей: ловушка журнала берёт
--- загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.clock', path = 'test/testing/clock.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    module = package.loaded['tnt.testing.sources'].module,
    clock = package.loaded['tnt.testing.clock'].new,
    capture_log = package.loaded['tnt.testing.journal'].capture,
}

local helper = {
    --- Модули пакета в порядке зависимостей.
    MODULES = {
        { name = 'tnt.redis.resp', path = 'tnt/redis/resp.lua' },
        { name = 'tnt.redis.link', path = 'tnt/redis/link.lua' },
        { name = 'tnt.redis.settings', path = 'tnt/redis/settings.lua' },
        { name = 'tnt.redis', path = 'tnt/redis.lua' },
    },
}

--- Фасад пакета из исходников.
helper.redis = testing.load_sources(helper.MODULES, 'tnt.redis')

-- Части пакета берутся из той же загрузки, что и фасад: взятые `require`,
-- они пришли бы установленной копией из `.rocks`. Срок, отказ и общее
-- для драйверов — зависимость, и они те же, что зовёт пакет.
helper.resp = testing.module('tnt.redis.resp')
helper.link = testing.module('tnt.redis.link')
helper.settings = testing.module('tnt.redis.settings')
helper.within = require('tnt.storage.within')
helper.failure = require('tnt.storage.failure')
helper.storage = require('tnt.storage')
helper.pool = require('tnt.pool')
helper.runner = require('tnt.retry.runner')

--- Шифрование — та же зависимость, что зовёт пакет: двойник рукопожатия
--- отказывает её же словом, и слово, разошедшееся с тем, что сверяет
--- драйвер, роняет проверку, а не прячется до живого сервера.
helper.tls = require('tnt.tls')

--- Значение мимо проверки типов: негодный аргумент нарочно.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Возвращает пакету настоящие часы и сеть.
function helper.restore()
    helper.within._set_source(nil)
    helper.link._set_source(nil)
    helper.pool._set_source(nil)
    helper.runner._set_source(nil)
end

--- Переводит срок вызова, ожидание пула и повторы на часы двойника.
---
--- Сколько попыток уместится в срок вызова, решают сроки ожидания пула,
--- а на настоящих часах — ещё и нагрузка машины: остановка цикла событий
--- в полном прогоне съедает срок последней попытки. На часах двойника
--- ожидание, которого никто не разбудил, сдвигает их ровно на свой срок
--- и не уступает управления, и попыток ровно столько, сколько уместили
--- сроки. Настоящие часы возвращает `restore`.
---@return TntTestingClock
function helper.virtual_time()
    local clock = testing.clock()

    helper.within._set_source({ monotonic = clock.monotonic, scheduler_now = clock.scheduler_now })
    helper.pool._set_source({ monotonic = clock.monotonic, cond = clock.cond })
    helper.runner._set_source({ now = clock.monotonic, scheduler_now = clock.scheduler_now, sleep = clock.sleep })

    return clock
end

--- Ловушка журнала на время проверки: выброс соединения виден только
--- записью.
helper.capture_log = testing.capture_log

--- Чтение окружения для настроек живых проверок: порт и каталог
--- сертификатов стенда.
---
--- `tnt-env` приходит из `.rocks`: сам пакет окружения не читает,
--- и его зависимостью он не объявлен — его ставит `make deps`.
---@return table
function helper.stand_env()
    return require('tnt.env')
end

--- Каталог стенда, общий на машину: туда `test/stand/redis.sh` кладёт
--- сертификаты контейнера с этим именем.
---
--- Контейнер стенда один на машину, а рабочих копий репозитория бывает
--- несколько, и копия, поднявшая его, уходит раньше контейнера.
--- Сертификаты в её `test/stand/run/` видела бы только она: остальные
--- копии пропускали бы проверки TLS, а копия со старыми сертификатами
--- после чужого подъёма падала бы на рукопожатии.
---@param container string Имя контейнера стенда
---@return string
function helper.stand_directory(container)
    return fio.pathjoin('/tmp/tnt-stand', container)
end

--- Простая строка ответа.
---@param text string
---@return string
function helper.status(text)
    return '+' .. text .. '\r\n'
end

--- Ошибка ответа.
---@param text string
---@return string
function helper.error(text)
    return '-' .. text .. '\r\n'
end

--- Целое ответа.
---@param number integer
---@return string
function helper.integer(number)
    return (':%s\r\n'):format(tostring(number))
end

--- Строка байтов ответа.
---@param text string
---@return string
function helper.bulk(text)
    return ('$%d\r\n%s\r\n'):format(#text, text)
end

--- Массив ответа из уже закодированных элементов.
---@param ... string
---@return string
function helper.array(...)
    return ('*%d\r\n'):format(select('#', ...)) .. table.concat({ ... })
end

--- Пустая строка байтов.
helper.NULL = '$-1\r\n'

--- Читатель из строки: байты, как их отдаёт сокет.
---
--- Чтение по разделителю отдаёт кусок до разделителя включительно либо
--- `chunk` байт, что наступит раньше; строка кончилась — остаток
--- и дальше пустая строка, как у сокета после конца потока. Если дана
--- беда, кончившаяся строка отдаёт её вместо пустой строки — как связь,
--- у которой вышел срок.
---
--- Читает по смещению, а не срезая остаток: разбор ответа в сотню тысяч
--- строк иначе копировал бы остаток на каждой.
---@param text string Что прислал сервер
---@param trouble table|nil Беда связи после конца строки
---@return fun(opts: table): string|nil, table|nil
---@return table[] asked Что просили прочесть, по порядку
function helper.receiver(text, trouble)
    local at = 1
    local asked = {}

    return function(opts)
        table.insert(asked, opts)

        if at > #text and trouble ~= nil then
            return nil, trouble
        end

        local size = math.min(opts.chunk, #text - at + 1)

        if opts.delimiter ~= nil then
            local _, last = text:find(opts.delimiter, at, true)

            if last ~= nil and last - at + 1 < size then
                size = last - at + 1
            end
        end

        local piece = text:sub(at, at + size - 1)

        at = at + size

        return piece
    end,
        asked
end

--- Разбирает команду, которую прислал драйвер: массив строк байтов.
---@param peer any Сокет двойника
---@return string[]|nil
local function command_of(peer)
    -- Не длиннее 64 байт: строка команды RESP всегда короче, а чужой
    -- протокол (приветствие TLS) без CRLF иначе ждал бы продолжения вечно.
    local head = peer:read({ delimiter = '\r\n', chunk = 64 })

    if head == nil or head == '' then
        return nil
    end

    local args = {}

    for _ = 1, tonumber(head:match('^%*(%d+)')) do
        local size = tonumber(peer:read({ delimiter = '\r\n' }):match('^%$(%d+)')) --[[@as integer]]

        table.insert(args, peer:read({ chunk = size + 2 }):sub(1, size))
    end

    return args
end

---@class TntRedisFakeAnswer
---@field reply string|nil Что отдать байтами
---@field delay number|nil Сколько помолчать перед ответом
---@field close boolean|nil Закрыть ли соединение после ответа

---@class TntRedisFake
---@field port integer Порт на петле
---@field commands string[][] Команды, которые дошли, по порядку
---@field connections integer Сколько соединений открыто всего
---@field finished integer Сколько соединений кончилось: клиент закрыл либо двойник
---@field peers table[] Сокеты двойника по соединениям
---@field stop fun() Погасить сервер и закрыть соединения

--- Двойник сервера Redis.
---
--- `respond(args, number)` получает команду и номер соединения и отвечает
--- байтами либо таблицей `{ reply, delay, close }`; пустой ответ —
--- молчание. Команды входа (`AUTH`, `SELECT`, `PING`) по умолчанию
--- отвечают сами, пока `respond` не ответит на них иначе.
---@param respond fun(args: string[], number: integer): string|TntRedisFakeAnswer|nil
---@return TntRedisFake
function helper.serve(respond)
    -- Порт и остановка появятся, когда сервер поднимется.
    ---@diagnostic disable-next-line: missing-fields
    local fake = { commands = {}, connections = 0, finished = 0, peers = {} } ---@type TntRedisFake

    local server = socket.tcp_server('127.0.0.1', 0, function(peer)
        fake.connections = fake.connections + 1
        table.insert(fake.peers, peer)

        local number = fake.connections

        while true do
            -- Под pcall: сокет двойника закрывают и снаружи (`stop`),
            -- и чтение из закрытого бросает — это конец разговора.
            local read, args = pcall(command_of, peer)

            if not read or args == nil then
                break
            end

            table.insert(fake.commands, args)

            local answer = respond(args, number)

            if answer == nil and (args[1] == 'AUTH' or args[1] == 'SELECT') then
                answer = helper.status('OK')
            elseif answer == nil and args[1] == 'PING' then
                answer = helper.status('PONG')
            end

            if type(answer) ~= 'table' then
                answer = { reply = answer }
            end

            if answer.delay ~= nil then
                fiber.sleep(answer.delay)
            end

            if answer.reply ~= nil then
                pcall(peer.write, peer, answer.reply)
            end

            if answer.close then
                break
            end
        end

        pcall(peer.close, peer)
        fake.finished = fake.finished + 1
    end)

    fake.port = server:name().port --[[@as integer]]

    fake.stop = function()
        server:close()

        for _, peer in ipairs(fake.peers) do
            pcall(peer.close, peer)
        end
    end

    return fake
end

--- Команды двойника без команд входа: то, что прислал вызывающий.
---@param fake TntRedisFake
---@return string[][]
function helper.sent(fake)
    local sent = {}

    for _, args in ipairs(fake.commands) do
        if args[1] ~= 'AUTH' and args[1] ~= 'SELECT' and args[1] ~= 'PING' then
            table.insert(sent, args)
        end
    end

    return sent
end

--- Драйвер к двойнику: без уборки пула и без пауз повторов.
---
--- Уборка заводила бы файбер на каждый пул, а пауза между попытками —
--- десятые доли секунды на каждую проверку повторов. Пауза после отказа
--- открытия — сотые: без неё пул открывал бы к закрытому порту без
--- передышки до конца срока.
---@param fake TntRedisFake
---@param opts table|nil Настройки поверх
---@return TntRedisClient
function helper.client(fake, opts)
    local given = table.deepcopy(opts or {})

    given.port = fake.port
    given.pool = given.pool or {}
    given.pool.sweep_interval = given.pool.sweep_interval or 0
    given.pool.open_cooldown = given.pool.open_cooldown or 0.02
    given.retry = given.retry or {}
    given.retry.base = given.retry.base or 0

    return helper.redis.new(given)
end

--- Сокет свободного соединения драйвера.
---
--- Соединение берётся из пула мимо команды и тут же возвращается:
--- пул выдаёт последнее возвращённое, и следующая команда пойдёт ровно
--- по нему. Брать надо до того, как сервер соединение закроет, — после
--- взятие само проверило бы годность и могло выдать уже другое.
---@param client TntRedisClient
---@return any socket
function helper.idle_socket(client)
    local conn = client.pool:take(5)

    t.assert_not_equals(conn, nil, 'соединение не открылось')
    ---@cast conn -nil
    t.assert_equals(client.pool:give(conn), true)

    return conn.socket
end

--- Ждёт, пока закрытие на той стороне дойдёт до сокета клиента.
---
--- Сервер закрыл соединение — это ещё не значит, что клиент может это
--- увидеть: конец потока идёт обработкой сети ядра, и под нагрузкой машины
--- пакет может ждать в очереди другого процессора, пока клиент шлёт следующую
--- команду. Проверка годности в пуле видит только дошедшее, и соединение,
--- выданное раньше, получало на команде сброс. Поэтому ждётся сокет
--- клиента, а не счёт закрытых у двойника и не пауза: готовность
--- к чтению — это дошедший конец потока, и из сокета не вынимается
--- ни байта.
---@param peer any Сокет клиента из `idle_socket`
function helper.until_closed(peer)
    t.assert(
        peer:readable(5),
        'закрытие на той стороне не дошло до клиента за 5 с'
    )
end

--- Свободный порт на петле, на котором никто не слушает.
---@return integer
function helper.closed_port()
    local server = socket.tcp_server('127.0.0.1', 0, function() end)
    local port = server:name().port --[[@as integer]]

    server:close()

    return port
end

return helper

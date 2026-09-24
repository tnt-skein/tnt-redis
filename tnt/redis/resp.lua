--- RESP: команда — в байты, ответ — из байтов.
---
--- Redis говорит на RESP (REdis Serialization Protocol): команда — массив
--- строк байтов, ответ — простая строка, ошибка, целое, строка байтов либо
--- массив из них. Драйвер говорит на второй версии, RESP2: её понимает
--- всякий Redis и всё, что выдаёт себя за него (Valkey, KeyDB, Dragonfly).
--- Третья (`HELLO 3`) дала бы словари и логику ценой версии сервера
--- не ниже шестой, поэтому `HELLO` драйвер не шлёт вовсе, и тип ответа
--- RESP3 — отказ протокола.
---
--- Сети и срока здесь нет: байты приходят через `receive`, который даёт
--- связь (`tnt.redis.link`), и разбор проверяется строками без сервера.
---
--- Три решения, которые стоит знать:
---
--- * **Ответ дочитывается целиком, даже с ошибкой внутри.** Ошибка бывает
---   и в середине массива (`EVAL`, вернувший `redis.error_reply` в таблице,
---   проверено на 7.4), и недочитанный хвост сдвинул бы следующему взявшему
---   соединение все ответы на один. Первая ошибка запоминается, а разбор
---   идёт до конца ответа.
--- * **Предел — байтами на весь ответ.** Длина строки байтов сверяется
---   с остатком до чтения: сервер, пообещавший 512 МБ, не получит ни байта
---   памяти сверх предела. Отдельного предела на число элементов массива
---   не нужно — каждый элемент стоит хотя бы трёх байтов того же предела.
--- * **Разбор — циклом со стеком, а не рекурсией.** Глубину вложенности
---   ответа ограничивает только предел байтов, а рекурсия на ответе
---   в сотню тысяч вложенных массивов упала бы «stack overflow».
---
--- Пустое (`$-1`, `*-1`) читается как `box.NULL`: внутри массива дыра
--- `nil` сдвинула бы длину, и `MGET` с промахом посередине потерял бы
--- хвост. Что из этого сделать на верхнем уровне, решает фасад.

local ffi = require('ffi')
local must = require('tnt.must')
local value = require('tnt.storage.value')

local Module = {}

--- Конец строки протокола.
Module.CRLF = '\r\n'

--- Больше этого целое в double уже неточно: 2⁵³ + 1 не представимо.
local EXACT = 2 ^ 53

--- Отказ, что за команду драйвер не отправит.
local TRANSACTION =
    'транзакции у драйвера нет (features.transaction = false): атомарность даёт сценарий EVAL'
local SUBSCRIPTION =
    'подписка занимает соединение целиком, а драйвер отдаёт его следующему после каждой команды'
local STATE =
    'состояние соединения задают настройки драйвера (username, password, db), а не команда'
local REPLICATION = 'поток репликации — не ответ на команду'
local REPLIES =
    'CLIENT REPLY и CLIENT TRACKING меняют, на что отвечает соединение, а его возьмёт следующий'

--- Команды, которых драйвер не отправляет, и почему.
---
--- Соединение живёт в пуле и после команды достаётся другому. Команда,
--- меняющая его состояние, отдала бы следующему взявшему чужую базу,
--- чужую учётную запись, начатую транзакцию либо подписку, где ответы
--- не отвечают на команды. Поэтому это исключение, а не пара: ошибся тот,
--- кто пишет код.
local FORBIDDEN = {
    MULTI = TRANSACTION,
    EXEC = TRANSACTION,
    DISCARD = TRANSACTION,
    WATCH = TRANSACTION,
    UNWATCH = TRANSACTION,
    SUBSCRIBE = SUBSCRIPTION,
    PSUBSCRIBE = SUBSCRIPTION,
    SSUBSCRIBE = SUBSCRIPTION,
    UNSUBSCRIBE = SUBSCRIPTION,
    PUNSUBSCRIBE = SUBSCRIPTION,
    SUNSUBSCRIBE = SUBSCRIPTION,
    MONITOR = SUBSCRIPTION,
    AUTH = STATE,
    HELLO = STATE,
    SELECT = STATE,
    RESET = STATE,
    QUIT = STATE,
    READONLY = STATE,
    READWRITE = STATE,
    SYNC = REPLICATION,
    PSYNC = REPLICATION,
    REPLCONF = REPLICATION,
}

--- Подкоманды `CLIENT`, после которых ответы перестают совпадать
--- с командами: `REPLY OFF` глушит ответы вовсе, `TRACKING` оставляет
--- соединению слежку за ключами.
local CLIENT_FORBIDDEN = { REPLY = true, TRACKING = true }

--- Команда байтами: массив строк байтов.
---
--- Аргументы здесь уже строки: их готовит `command`, а вход приветствия
--- собирает связь из настроек.
---@param args string[]
---@return string
function Module.encode(args)
    local parts = { ('*%d\r\n'):format(#args) }

    for _, arg in ipairs(args) do
        table.insert(parts, ('$%d\r\n'):format(#arg))
        table.insert(parts, arg)
        table.insert(parts, Module.CRLF)
    end

    return table.concat(parts)
end

--- Проверенная команда байтами.
---
--- Команда — непустой список: имя и аргументы. Аргумент уходит строкой байтов
--- по правилу `tnt-storage` для Redis (`value.wire`): число — точной
--- записью без степени, `int64` — цифрами, `decimal`, `uuid`, время —
--- текстом, `storage.json` и `storage.binary` — как обёрнуты. Пустое,
--- логика, таблица — исключение.
---@param args any Команда
---@param title string Как назвать её в отказе
---@param level integer|nil Уровень вины, как у `error`, в кадрах того, кто зовёт эту функцию:
--- 1 — его строка (по умолчанию), 2 — его вызывающий
---@return string payload
function Module.command(args, title, level)
    local depth = (level or 1) + 1
    local caller = must.at(depth)

    caller.array(args, title)
    caller.not_empty(args[1], title .. '[1]')

    local name = args[1]:upper()
    local refusal = FORBIDDEN[name]

    if name == 'CLIENT' and type(args[2]) == 'string' and CLIENT_FORBIDDEN[args[2]:upper()] then
        refusal = REPLIES
    end

    if refusal ~= nil then
        error(('команду %s драйвер не отправит: %s'):format(name, refusal), depth)
    end

    local wired = {}

    for index, arg in ipairs(args) do
        wired[index] = value.wire(value.REDIS, arg, depth)
    end

    return Module.encode(wired)
end

---@class TntRedisTrouble
---@field kind string Род отказа: broken, overflow, а от связи — ещё timeout
---@field message string Что случилось

--- Беда чтения: род отказа и текст.
---@param kind string broken либо overflow
---@param text string
---@return TntRedisTrouble
local function trouble(kind, text)
    return { kind = kind, message = text }
end

--- Беда протокола: сервер ответил не на RESP2.
---@param text string
---@return TntRedisTrouble
local function garbled(text)
    return trouble('broken', ('ответ не по протоколу RESP2: %s'):format(text))
end

--- Сервер закрыл соединение, не договорив.
local CUT = 'сервер закрыл соединение посреди ответа'

---@class TntRedisReading
---@field receive fun(opts: table): string|nil, TntRedisTrouble|nil Байты из связи
---@field left integer Сколько байтов ответа ещё можно прочесть
---@field fault TntRedisFault|nil Первая ошибка ответа

---@class TntRedisFault
---@field text string Текст ошибки сервера
---@field code string|nil Первое слово ошибки; общее ERR кодом не считается

---@class TntRedisReply
---@field value any Ответ; пустое — box.NULL
---@field fault TntRedisFault|nil Первая ошибка в ответе, если была

--- Строка ответа без CRLF.
---
--- Читается не длиннее остатка предела: сервер, у которого строка
--- не кончается, иначе съел бы память узла. Остаток бывает и нулём —
--- чтение нуля байтов отдаёт пустую строку сразу, и это тот же выход
--- за предел.
---@param reading TntRedisReading
---@return string|nil line
---@return TntRedisTrouble|nil trouble
local function line_of(reading)
    local limit = reading.left
    local piece, failed = reading.receive({ chunk = limit, delimiter = Module.CRLF })

    if piece == nil then
        return nil, failed
    end

    if piece:sub(-2) == Module.CRLF then
        reading.left = limit - #piece

        return piece:sub(-#piece, -3)
    end

    -- Прочитанное не бывает длиннее запрошенного: короче — поток кончился
    -- посреди строки, ровно столько — строка не уложилась в предел.
    if #piece < limit then
        return nil, trouble('broken', CUT)
    end

    return nil,
        trouble(
            'overflow',
            ('ответ длиннее предела max_bytes: строка не уложилась в %d байт'):format(
                limit
            )
        )
end

--- Длина строки байтов или массива: целое не меньше −1.
---@param text string
---@return integer|nil
local function length_of(text)
    if text:find('^%-?%d+$') == nil then
        return nil
    end

    local size = tonumber(text)

    if size < -1 then
        return nil
    end

    return size
end

--- Целое ответа: число Lua, пока оно точно, иначе `int64` либо `uint64`.
---
--- Так же отдаёт целые msgpack самого Tarantool: большое положительное —
--- `uint64`, большое отрицательное — `int64`. Запись сверяется образцом
--- до `tonumber64`: тот принимает и `0x10`, и ` 12`, и `12LL` — всё, чего
--- в RESP не бывает.
---@param text string
---@return number|ffi.cdata*|nil
---@return string|nil wrong Что не так с записью
local function integer_of(text)
    if text:find('^%-?%d+$') == nil then
        return nil, ('целое «%s»'):format(text)
    end

    local number = tonumber64(text)

    if number == nil then
        return nil, ('целое «%s» не умещается в 64 бита'):format(text)
    end

    -- Нижняя граница — только у знакового: LuaJIT переводит -2^53
    -- в uint64_t приведением отрицательного double, а это неопределённое
    -- поведение C. На x86 выходит мусор, и целые от 1e14 до 2^53
    -- оставались бы cdata; на arm64 — ноль, и ошибки не видно.
    if number <= EXACT and (ffi.istype('uint64_t', number) or number >= -EXACT) then
        return tonumber(number)
    end

    return number
end

--- Строка байтов по объявленной длине.
---@param reading TntRedisReading
---@param size integer Длина без CRLF
---@return string|nil bytes
---@return TntRedisTrouble|nil trouble
local function bulk_of(reading, size)
    local wanted = size + 2

    if wanted > reading.left then
        return nil,
            trouble(
                'overflow',
                ('ответ длиннее предела max_bytes: строка в %d байт, а осталось %d'):format(
                    size,
                    reading.left
                )
            )
    end

    local piece, failed = reading.receive({ chunk = wanted })

    if piece == nil then
        return nil, failed
    end

    if #piece < wanted then
        return nil, trouble('broken', CUT)
    end

    if piece:sub(-2) ~= Module.CRLF then
        return nil, garbled(('строка байтов длиной %d не кончается CRLF'):format(size))
    end

    reading.left = reading.left - wanted

    return piece:sub(-#piece, size)
end

--- Ошибка сервера: текст и первое слово.
---
--- `ERR` — общее слово, ничего не говорящее о роде; кодом оно
--- не считается, и род решают слова отказа (`tnt.storage.codes`).
---@param text string
---@return TntRedisFault
local function fault_of(text)
    local code = (text .. ' '):match('^(%u+) ')

    if code == 'ERR' then
        code = nil
    end

    return { text = text, code = code }
end

--- Следующий элемент ответа: значение либо начало массива.
---@param reading TntRedisReading
---@return any element Значение; пустое — box.NULL
---@return integer|nil opened Длина открытого массива: элементы пойдут следом
---@return TntRedisTrouble|nil trouble
local function element_of(reading)
    local line, failed = line_of(reading)

    if line == nil then
        return nil, nil, failed
    end

    local mark, body = line:sub(-#line, 1), line:sub(2)

    if mark == '+' then
        return body
    end

    if mark == '-' then
        reading.fault = reading.fault or fault_of(body)

        return box.NULL
    end

    if mark == ':' then
        local number, wrong = integer_of(body)

        if number == nil then
            ---@cast wrong string
            return nil, nil, garbled(wrong)
        end

        return number
    end

    if mark ~= '$' and mark ~= '*' then
        return nil, nil, garbled(('тип ответа «%s» незнаком'):format(mark))
    end

    local size = length_of(body)

    if size == nil then
        return nil, nil, garbled(('длина «%s»'):format(body))
    end

    if size == -1 then
        return box.NULL
    end

    if mark == '*' then
        return nil, size
    end

    local bytes, broken = bulk_of(reading, size)

    return bytes, nil, broken
end

--- Один ответ целиком.
---@param reading TntRedisReading
---@return TntRedisReply|nil reply
---@return TntRedisTrouble|nil trouble
local function reply_of(reading)
    -- Открытые массивы: элементы и сколько их ждать.
    ---@type { items: any[], size: integer }[]
    local stack = {}

    reading.fault = nil

    while true do
        local element, opened, failed = element_of(reading)

        if failed ~= nil then
            return nil, failed
        end

        if opened ~= nil and opened > 0 then
            table.insert(stack, { items = {}, size = opened })
        else
            if opened ~= nil then
                element = {}
            end

            -- Готовое значение ложится в свой массив; массив, дополненный
            -- до конца, — в объемлющий, и так до верха либо до массива,
            -- которому ещё ждать элементов.
            while true do
                local frame = stack[#stack]

                if frame == nil then
                    return { value = element, fault = reading.fault }
                end

                table.insert(frame.items, element)

                if #frame.items < frame.size then
                    break
                end

                table.remove(stack)
                element = frame.items
            end
        end
    end
end

--- Читает ответы подряд: по одному на отправленную команду.
---
--- Предел байтов общий на все ответы: он бережёт память узла, а ей всё
--- равно, пришло ли много одним ответом или многими.
---@param receive fun(opts: table): string|nil, TntRedisTrouble|nil Байты из связи: `{ chunk, delimiter }`
--- как у сокета; беда — nil и `{ kind, message }`
---@param count integer Сколько ответов ждать
---@param budget integer Предел байтов на все ответы
---@return TntRedisReply[]|nil replies
---@return TntRedisTrouble|nil trouble
function Module.read(receive, count, budget)
    ---@type TntRedisReading
    local reading = { receive = receive, left = budget }
    local replies = {}

    for index = 1, count do
        local reply, failed = reply_of(reading)

        if reply == nil then
            return nil, failed
        end

        replies[index] = reply
    end

    return replies
end

return Module

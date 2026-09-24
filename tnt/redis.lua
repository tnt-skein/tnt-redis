--- Клиент Redis: RESP2 по сокету, пул, срок, повторы и отказ парой.
---
---     local redis = require('tnt.redis')
---
---     local client = redis.new({ host = 'cache', password = secret, pool = { size = 4 } })
---
---     local ok, err = client:command({ 'SET', 'user:7', 'Анна', 'EX', 60 })
---     local name, err = client:command({ 'GET', 'user:7' })   -- промах — nil без err
---     local replies, err = client:pipeline({ { 'INCR', 'hits' }, { 'EXPIRE', 'hits', 60 } })
---
---     client:close()
---
--- Готового клиента Redis у Tarantool нет — ни в ядре, ни среди официальных
--- роков, — поэтому протокол свой (`tnt.redis.resp`), поверх встроенного
--- сокета: он неблокирующий и живёт с файберами. Всё прочее взято готовым:
--- пул — `tnt-pool`, который драйвер заводит сам; отказ, срок и кодирование
--- значений — `tnt-storage`; повторы — `tnt-retry` по полю `retriable`
--- отказа; TLS — `tnt-tls`.
---
--- Решения, которые стоит знать заранее:
---
--- * **Отказ — пара `nil, err`**, где `err` — `TntStorageFailure` с родом.
---   Ошибка сервера (`WRONGTYPE`, `NOSCRIPT`) — `rejected`, `LOADING`,
---   `BUSY`, `READONLY` — `busy` (команда не выполнялась, повтор можно),
---   `NOAUTH`, `NOPERM` — `denied`. Исключение — только ошибка программиста:
---   негодная команда, значение, которого Redis не выразит, незнакомый ключ.
--- * **Срок один на вызов**, умолчание 5 с: взятие соединения, вход,
---   запрос и паузы повторов — остатки одного мига.
--- * **Повтор после отправки — только с `idempotent = true`.** `INCR`,
---   оборванный после записи, сервер мог выполнить, и повтор посчитал бы
---   дважды. До отправки — сеть, пул, `LOADING` — повтор всегда.
--- * **Транзакций нет** (`features.transaction = false`): `MULTI`
---   и `WATCH` — исключение. Атомарность — сценарий `EVAL`.
--- * **Промах — `nil` без отказа**, как у `box.space:get`; внутри массива
---   пустое — `box.NULL`, иначе дыра сдвинула бы длину.
---
--- Подробно — `docs/redis.md`.

local fiber = require('fiber')

local link = require('tnt.redis.link')
local must = require('tnt.must')
local pool = require('tnt.pool')
local resp = require('tnt.redis.resp')
local retry = require('tnt.retry')
local settings_of = require('tnt.redis.settings')
local storage = require('tnt.storage')

local log = require('tnt.log').new('tnt.redis')

local failure, within = storage.failure, storage.within

local Module = {}

--- Настройки вызова: срок и согласие на повтор после отправки.
local CALL = { timeout = '?number', idempotent = '?boolean' }

---@class TntRedisClient
---@field name string Имя драйвера
---@field features { transaction: boolean } Что драйвер умеет
---@field where string Узел и порт
---@field limits TntStorageLimits Сроки вызова
---@field max_bytes integer Предел байтов ответа
---@field wait_timeout number Сколько ждать соединения из пула
---@field pool TntPool Соединения
---@field retry TntRetry Повторы
---@field closed boolean Закрыт ли драйвер
local Client = {}
Client.__index = Client

--- Отказ закрытого драйвера: закрытие гонится с запросами при остановке
--- узла, и это «так бывает», а не ошибка кода.
---@param text string
---@return TntStorageFailure
local function closed(text)
    return failure.new(failure.CLOSED, text)
end

--- Заводит драйвер. Соединений не открывает: первое откроет первый вызов.
---@param opts TntRedisOptions|nil
---@return TntRedisClient
function Module.new(opts)
    local settings = settings_of.check(opts)
    local limits = settings.pool
    local retries = settings.retry

    local connections = pool.new({
        open = function(left)
            return link.open(settings, left)
        end,
        close = link.close,
        alive = link.alive,
        name = settings.name,
        size = limits.size,
        wait_timeout = limits.wait_timeout,
        idle_timeout = limits.idle_timeout,
        max_lifetime = limits.max_lifetime,
        open_cooldown = limits.open_cooldown,
        leak_timeout = limits.leak_timeout,
        sweep_interval = limits.sweep_interval,
    })

    local retrier, wrong = retry.new({
        scope = settings.name,
        attempts = retries.attempts,
        base = retries.base,
        factor = retries.factor,
        jitter = retries.jitter,
        max = retries.max,
    })

    if retrier == nil then
        connections:close()
        -- Отказ повторов сам начинается словами «настройки повторов»,
        -- и своя приставка назвала бы те же настройки дважды.
        error(wrong, 2)
    end

    return setmetatable({
        name = settings.name,
        features = { transaction = false },
        where = settings.where,
        limits = settings.limits,
        max_bytes = settings.max_bytes,
        wait_timeout = connections.settings.wait_timeout,
        pool = connections,
        retry = retrier,
        closed = false,
    }, Client)
end

--- Срок вызова из его настроек, с виной на строке того, кто звал
--- `command` либо `pipeline`.
---@param client TntRedisClient
---@param opts table|nil
---@return number timeout
---@return boolean|nil idempotent
local function call_of(client, opts)
    must.at(3).optional.options(opts, 'настройки вызова', CALL)

    local given = opts or {}
    local timeout = within.timeout(given.timeout, client.limits, 3)

    return timeout, given.idempotent
end

--- Отказ, когда срок вышел до отправки.
---
--- Была попытка — отказ её, но без повтора: пауза `tnt-retry` меряет свой
--- срок от своего начала и могла в него уложиться, не уложившись в миг
--- вызова. Не было — `timeout` без отправки.
---@param last TntStorageFailure|nil
---@return TntStorageFailure
local function expired(last)
    if last == nil then
        return failure.new(
            failure.TIMEOUT,
            'срок вызова вышел до отправки команды',
            { sent = false }
        )
    end

    return failure.new(last.kind, last.message, {
        sent = last.sent,
        retriable = false,
        server_code = last.server_code,
        reason = last.reason,
    })
end

--- Чем объяснить, что соединения не дали.
---@param why any Что отдал пул
---@return TntStorageFailure
function Client:_refusal(why)
    -- Окончательный отказ входа пул отдаёт тем, что вернула `open`.
    if failure.is(why) then
        return why
    end

    if self.closed then
        return closed(('%s: драйвер закрыт'):format(self.name))
    end

    -- Место в пуле есть, а соединения нет — не открылось: род по тексту
    -- отказа открытия, как у пула. Иначе — все заняты.
    local stats = self.pool:stats()

    if stats.total < stats.size and stats.last_open_error ~= nil then
        return failure.login(why)
    end

    return failure.new(failure.BUSY, ('redis %s: %s'):format(self.where, tostring(why)))
end

--- Выбрасывает соединение и говорит об этом в журнал: выброс — это новый
--- вход на следующем вызове, и частые выбросы видны только так.
---@param conn TntRedisLink
---@param err TntStorageFailure Почему
---@return TntStorageFailure err Тот же отказ
function Client:_discard(conn, err)
    self.pool:drop(conn)
    log.warn('соединение выброшено', { driver = self.name, kind = err.kind, reason = err.reason })

    return err
end

--- Выбрасывает соединение, в котором остался недочитанный ответ.
---@param conn TntRedisLink
---@param trouble table Беда связи: род, текст, дошла ли команда
---@param idempotent boolean|nil
---@return TntStorageFailure
function Client:_drop(conn, trouble, idempotent)
    local err = failure.new(trouble.kind, ('redis %s: %s'):format(self.where, trouble.message), {
        sent = trouble.sent,
        retriable = trouble.retriable,
        idempotent = idempotent,
    })

    return self:_discard(conn, err)
end

--- Ответы — значениями, а ошибку сервера — отказом.
---
--- Соединение, дочитанное до конца, цело и возвращается в пул. Кроме
--- `READONLY`: так отвечает бывший ведущий после смены, и новое соединение
--- по тому же имени узла может прийти уже к новому ведущему.
---@param conn TntRedisLink
---@param replies TntRedisReply[]
---@param idempotent boolean|nil
---@return any[]|nil values
---@return TntStorageFailure|nil err
function Client:_settle(conn, replies, idempotent)
    local values = {}

    for index, reply in ipairs(replies) do
        local fault = reply.fault

        if fault ~= nil then
            local text = fault.text

            if #replies > 1 then
                text = ('команда %d из %d: %s'):format(index, #replies, text)
            end

            local err = failure.statement(text, fault.code, { idempotent = idempotent })

            if fault.code == 'READONLY' then
                return nil, self:_discard(conn, err)
            end

            self.pool:give(conn)

            return nil, err
        end

        values[index] = reply.value
    end

    self.pool:give(conn)

    return values
end

--- Одна попытка: взять соединение, обменяться, вернуть либо выбросить.
---@param payload string
---@param count integer
---@param deadline number
---@param idempotent boolean|nil
---@param last TntStorageFailure|nil Отказ прошлой попытки
---@return any[]|nil values
---@return TntStorageFailure|nil err
function Client:_attempt(payload, count, deadline, idempotent, last)
    if self.closed then
        return nil, closed(('%s: драйвер закрыт'):format(self.name))
    end

    local left = within.left(deadline)

    if left <= 0 then
        return nil, expired(last)
    end

    local conn, why = self.pool:take(math.min(left, self.wait_timeout))

    if conn == nil then
        return nil, self:_refusal(why)
    end

    -- Срок мог выйти в ожидании пула. Команда не ушла, сокет чист,
    -- и соединение возвращается, а не выбрасывается.
    if within.left(deadline) <= 0 then
        self.pool:give(conn)

        return nil, expired(last)
    end

    local replies, trouble = link.exchange(conn, payload, count, deadline, self.max_bytes)

    if replies == nil then
        ---@cast trouble table
        return nil, self:_drop(conn, trouble, idempotent)
    end

    return self:_settle(conn, replies, idempotent)
end

--- Вызов целиком: один миг срока, попытки по приговору отказа.
---@param payload string
---@param count integer
---@param timeout number
---@param idempotent boolean|nil
---@return any[]|nil values
---@return TntStorageFailure|nil err
function Client:_call(payload, count, timeout, idempotent)
    local deadline = within.deadline(timeout)
    local last = nil

    local values, err = self.retry:run(function()
        local done, refusal = self:_attempt(payload, count, deadline, idempotent, last)

        last = refusal

        return done, refusal
    end, { deadline = timeout })

    -- Отменённого вызывающего пара не останавливает: отмена уходит
    -- дальше тем же исключением, соединение к этому мигу уже выброшено.
    fiber.testcancel()

    return values, err
end

--- Одна команда.
---
--- Промах (`GET` нет такого ключа) — `nil` без отказа, как у
--- `box.space:get`; отказ — `nil, err`.
---@param args any[] Команда и аргументы: `{ 'SET', key, value, 'EX', 60 }`
---@param opts { timeout: number|nil, idempotent: boolean|nil }|nil
---@return any value Ответ сервера
---@return TntStorageFailure|nil err
function Client:command(args, opts)
    local timeout, idempotent = call_of(self, opts)
    local payload = resp.command(args, 'команда', 2)
    local values, err = self:_call(payload, 1, timeout, idempotent)

    if values == nil then
        return nil, err
    end

    -- Пустой ответ `box.NULL` равен `nil` и в сравнении, но не в `if`:
    -- наружу уходит настоящий `nil`.
    if values[1] == nil then
        return nil
    end

    return values[1]
end

--- Команды подряд одним обменом: запись одна, ответы — по порядку.
---
--- Это не транзакция: команды выполняются по одной, и соседние между
--- ними успевают свои. Ошибка любой команды — отказ всего вызова
--- (`команда 2 из 3: …`), хотя прочие выполнены.
---@param commands any[][] Команды: `{ { 'INCR', 'hits' }, { 'EXPIRE', 'hits', 60 } }`
---@param opts { timeout: number|nil, idempotent: boolean|nil }|nil
---@return any[]|nil values Ответы по порядку; пустое — box.NULL
---@return TntStorageFailure|nil err
function Client:pipeline(commands, opts)
    local timeout, idempotent = call_of(self, opts)
    local caller = must.at(2)

    caller.array(commands, 'команды')

    if #commands == 0 then
        error('команды — непустой список, а не пустой', 2)
    end

    local parts = {}

    for index, args in ipairs(commands) do
        parts[index] = resp.command(args, ('команды[%d]'):format(index), 2)
    end

    return self:_call(table.concat(parts), #commands, timeout, idempotent)
end

--- Закрывает драйвер: свободные соединения — сразу, занятые — когда
--- их вернут.
---
--- Повторное закрытие — пара `closed`, а не исключение: закрытие при
--- остановке узла гонится с запросами, и «так бывает».
---@return boolean ok
---@return TntStorageFailure|nil err
function Client:close()
    if self.closed then
        return false, closed(('%s: драйвер уже закрыт'):format(self.name))
    end

    self.closed = true
    self.pool:close()

    return true
end

--- Что с соединениями: показатели пула, без учётных данных.
---@return table
function Client:stats()
    return self.pool:stats()
end

return Module

--- Настройки драйвера Redis: умолчания и проверка.
---
--- Проверяется всё и сразу, в `redis.new`, а не там, где до настройки
--- впервые дошло дело: драйвер заводят при подъёме узла, а первую команду
--- шлют через час под нагрузкой. Негодная настройка — исключение на строке
--- того, кто завёл драйвер: это ошибка кода, а не отказ службы. Незнакомый
--- ключ — тоже: опечатка в имени (`pasword`) иначе молча оставила бы
--- драйвер без пароля.
---
--- Сроки проверяет `tnt-storage` (`within.settings`): умолчание 5 с,
--- потолок `max_timeout` 60 с — одно правило на все драйверы. Границы
--- пула и повторов проверяют сами `tnt-pool` и `tnt-retry`: здесь — только
--- набор ключей и род значений, чтобы опечатка показывала на вызывающего.

local must = require('tnt.must')
local resp = require('tnt.redis.resp')
local within = require('tnt.storage.within')

local Module = {}

--- Узел по умолчанию: Redis на той же машине.
Module.DEFAULT_HOST = '127.0.0.1'

--- Порт Redis по умолчанию.
Module.DEFAULT_PORT = 6379

--- Предел байтов на ответ по умолчанию: 16 МБ.
---
--- Строка Redis бывает до 512 МБ, и ответ такой длины, принятый целиком,
--- занял бы память узла, в которой живут его данные. Шестнадцать мегабайт
--- больше любого разумного значения кэша и сессии; кому нужно больше,
--- поднимает предел настройкой и знает, что делает.
Module.DEFAULT_MAX_BYTES = 16 * 1024 * 1024

--- Имя драйвера по умолчанию: в журнале, в имени пула и ведре повторов.
Module.DEFAULT_NAME = 'redis'

--- Уровень вины: строка того, кто завёл драйвер.
---
--- `check` зовёт `redis.new` не хвостовым вызовом: уровень 2 — строка
--- в `redis.lua`, 3 — строка вызывающего.
local OWNER = 3

--- Проверки с виной на строке того, кто завёл драйвер.
local owner = must.at(OWNER)

--- Как настройки называются в отказе.
local TITLE = 'настройки redis'

--- Настройки пула, которые драйвер передаёт `tnt-pool` как есть.
local POOL = {
    size = '?integer',
    wait_timeout = '?number',
    idle_timeout = '?number',
    max_lifetime = '?number',
    open_cooldown = '?number',
    leak_timeout = '?number',
    sweep_interval = '?number',
}

--- Настройки повторов, которые драйвер передаёт `tnt-retry` как есть.
---
--- Срока (`deadline`) и суждения о повторе (`retriable`) здесь нет: срок —
--- у каждого вызова свой, а судит поле `retriable` отказа.
local RETRY = {
    attempts = '?integer',
    base = '?number',
    factor = '?number',
    jitter = '?number|string',
    max = '?number',
}

--- Шифрование: то, что уходит в `tnt-tls`.
local TLS = {
    verify = '?boolean',
    ca_file = '?not_empty',
    ca_path = '?not_empty',
    sni = '?not_empty',
    cert_file = '?not_empty',
    key_file = '?not_empty',
}

--- Все настройки драйвера. Незнакомый ключ — отказ.
local OPTIONS = {
    host = '?not_empty',
    port = '?integer',
    username = '?not_empty',
    password = '?string',
    db = '?integer',
    tls = '?boolean|table',
    timeout = '?number',
    max_timeout = '?number',
    max_bytes = '?integer',
    pool = { '?options', POOL },
    retry = { '?options', RETRY },
    name = '?not_empty',
}

---@class TntRedisOptions
---@field host string|nil Узел; по умолчанию 127.0.0.1
---@field port integer|nil Порт; по умолчанию 6379
---@field username string|nil Учётная запись ACL; только вместе с паролем
---@field password string|nil Пароль
---@field db integer|nil Номер базы; по умолчанию 0
---@field tls boolean|TntRedisTlsSettings|nil Шифрование: true либо настройки `tnt-tls`
---@field timeout number|nil Срок вызова по умолчанию, секунд; 5
---@field max_timeout number|nil Потолок срока вызова, секунд; 60
---@field max_bytes integer|nil Предел байтов на ответ; 16 МБ
---@field pool table|nil Настройки пула: size, wait_timeout, idle_timeout, max_lifetime и прочие `tnt-pool`
---@field retry table|nil Настройки повторов: attempts, base, factor, jitter, max
---@field name string|nil Имя драйвера в журнале; redis

---@class TntRedisSettings: TntRedisLinkSettings
---@field name string
---@field limits TntStorageLimits Сроки вызова
---@field pool table Настройки пула как даны
---@field retry table Настройки повторов как даны

--- Команды входа: пароль, база, а без них — `PING`.
---
--- Входу нужен хоть один ответ: сервер, у которого кончились места («max
--- number of clients reached») или включён защищённый режим, отказывает
--- на первую команду, и лучше услышать это при входе, чем на команде
--- вызывающего. `AUTH` и `SELECT` дают такой ответ сами, а `PING` рядом
--- с ними был бы лишним — и вредным: он в категории ACL `@connection`,
--- и учётку только для чтения (`+@read`) он не пустил бы вовсе
--- («NOPERM … 'ping'», проверено на 7.4).
---@param given TntRedisOptions
---@param db integer
---@return string payload
---@return integer count
local function greeting(given, db)
    local commands = {}

    if given.username ~= nil then
        table.insert(commands, { 'AUTH', given.username, given.password })
    elseif given.password ~= nil then
        table.insert(commands, { 'AUTH', given.password })
    end

    if db ~= 0 then
        table.insert(commands, { 'SELECT', tostring(db) })
    end

    if #commands == 0 then
        table.insert(commands, { 'PING' })
    end

    local parts = {}

    for index, command in ipairs(commands) do
        parts[index] = resp.encode(command)
    end

    return table.concat(parts), #commands
end

--- Проверяет настройки и дополняет их умолчаниями.
---@param opts TntRedisOptions|nil
---@return TntRedisSettings
function Module.check(opts)
    owner.optional.options(opts, TITLE, OPTIONS)

    local given = opts or {}
    local port = given.port or Module.DEFAULT_PORT
    local db = given.db or 0

    owner.between(port, TITLE .. '.port', 1, 65535)
    owner.non_negative(db, TITLE .. '.db')
    owner.optional.positive(given.max_bytes, TITLE .. '.max_bytes')

    if given.username ~= nil and given.password == nil then
        error(
            ('%s.username без password: вход по учётной записи ACL требует пароля'):format(
                TITLE
            ),
            OWNER
        )
    end

    local tls = given.tls

    if type(tls) == 'table' then
        owner.options(tls, TITLE .. '.tls', TLS)

        -- `tnt-tls` отказал бы и сам, но при входе, и отказ этот вызов
        -- повторял бы до конца срока: а это опечатка в коде, и видна она
        -- уже здесь.
        if tls.key_file ~= nil and tls.cert_file == nil then
            error(
                ('%s.tls.key_file без cert_file: ключ предъявляется только вместе с сертификатом'):format(
                    TITLE
                ),
                OWNER
            )
        end
    elseif tls == true then
        tls = {}
    else
        tls = nil
    end

    local host = given.host or Module.DEFAULT_HOST
    local payload, count = greeting(given, db)

    return {
        name = given.name or Module.DEFAULT_NAME,
        host = host,
        port = port,
        where = ('%s:%d'):format(host, port),
        tls = tls,
        greeting = payload,
        greeting_count = count,
        max_bytes = given.max_bytes or Module.DEFAULT_MAX_BYTES,
        limits = within.settings(given.timeout, given.max_timeout, OWNER),
        pool = given.pool or {},
        retry = given.retry or {},
    }
end

return Module

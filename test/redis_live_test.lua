--- Драйвер против настоящего Redis.
---
--- Двойник показывает, что мы правильно разговариваем сами с собой.
--- Настоящий сервер показывает, что нас понимает кто-то ещё: его тексты
--- отказов входа, ошибка внутри массива из EVAL, отказ NOPERM у учётки
--- только для чтения, BUSY от сценария-долгожителя, TLS с его
--- сертификатом и сервер, требующий сертификат клиента. Сервер
--- поднимается отдельно — `make redis-up`
--- (`test/stand/redis.sh`), — и если его нет, проверки честно
--- пропускаются: гейты не должны зависеть от докера.
---
--- Стенд один на машину, а проверки идут разом из нескольких рабочих
--- копий. Поэтому каждая проверка трогает только своё: ключи прогона,
--- своё соединение в списке клиентов. BUSY же занимает весь сервер,
--- и для него у стенда отдельный сервер, на котором проверки BUSY из
--- разных копий встают в очередь.

local clock = require('clock')
local fiber = require('fiber')
local fio = require('fio')
local t = require('luatest')
local uuid = require('uuid')

local helper = dofile('test/helper.lua')

local redis = helper.redis
local storage = helper.storage

local g = t.group('tnt.redis.live')

--- Окружение стенда — через `tnt-env`: мимо него окружение не читают
--- и проверки.
local env = helper.stand_env()

--- Где стоит сервер: те же адреса и переменные, что у скрипта стенда.
local PORT = env.int('STAND_REDIS_PORT', 16379)
local TLS_PORT = env.int('STAND_REDIS_TLS_PORT', 16380)
local MTLS_PORT = env.int('STAND_REDIS_MTLS_PORT', 16381)
local BUSY_PORT = env.int('STAND_REDIS_BUSY_PORT', 16382)
local CONTAINER = env.string('STAND_REDIS_CONTAINER', 'tnt-stand-redis')
local TLS_DIR = env.string('REDIS_TLS_DIR', helper.stand_directory(CONTAINER))
local PASSWORD = 'stand-secret'

--- Опознаватель прогона: ключи прошлого прогона, упавшего на середине,
--- не мешают этому.
local RUN = uuid.str()

--- Отвечает ли кто-нибудь на порту стенда.
---@param port integer|nil По умолчанию открытый порт
---@return boolean
local function listening(port)
    local socket = require('socket').tcp_connect('127.0.0.1', port or PORT, 0.3)

    if socket == nil then
        return false
    end

    socket:close()

    return true
end

g.before_all(function()
    t.skip_if(not listening(), 'Redis не отвечает: поднимите его — make redis-up')
end)

g.after_each(function()
    for _, client in ipairs(g.clients or {}) do
        client:close()
    end

    g.clients = nil
end)

--- Драйвер к стенду; закроется после проверки сам.
---@param opts table|nil Настройки поверх пароля и порта стенда
---@return any
local function connect(opts)
    local given = opts or {}

    given.port = given.port or PORT

    if given.password == nil and given.username == nil then
        given.password = PASSWORD
    end

    given.pool = given.pool or {}
    given.pool.sweep_interval = 0

    local client = redis.new(given)

    g.clients = g.clients or {}
    table.insert(g.clients, client)

    return client
end

--- Ключ этой проверки: проверки не мешают друг другу и повторному прогону.
---@param name string
---@return string
local function key(name)
    return ('tnt-redis-live:%s:%s'):format(RUN, name)
end

g.test_values_go_there_and_back_exactly = function()
    local client = connect()
    local name = key('values')
    local bytes = 'a\r\nb\0c'

    t.assert_equals({ client:command({ 'SET', name, bytes, 'EX', 60 }) }, { 'OK' })
    t.assert_equals({ client:command({ 'GET', name }) }, { bytes })
    t.assert_equals({ client:command({ 'SET', name, 'Анна' }) }, { 'OK' })
    t.assert_equals({ client:command({ 'GET', name }) }, { 'Анна' })
    -- Целое без степени: запись `1e+15` INCRBY отвергает.
    t.assert_equals({ client:command({ 'SET', name, 0 }) }, { 'OK' })
    t.assert_equals({ client:command({ 'INCRBY', name, 1e15 }) }, { 1e15 })

    local big = client:command({ 'INCRBY', name, 9007199254740993LL - 1000000000000000LL })

    t.assert_equals(tostring(big), '9007199254740993ULL')
    t.assert_equals({ client:command({ 'INCRBYFLOAT', key('float'), 0.1 }) }, { '0.1' })
    t.assert_equals({ client:command({ 'SET', name, storage.json({ a = 1 }) }) }, { 'OK' })
    t.assert_equals({ client:command({ 'GET', name }) }, { '{"a":1}' })
    t.assert_equals({ client:command({ 'DEL', name, key('float') }) }, { 2 })
end

g.test_a_miss_and_nulls_keep_their_places = function()
    local client = connect()
    local name = key('nulls')

    client:command({ 'SET', name, 'v', 'EX', 60 })

    t.assert_equals({ client:command({ 'GET', key('nobody') }) }, {})
    t.assert_equals({ client:command({ 'MGET', key('nobody'), name, key('nobody') }) }, { { box.NULL, 'v', box.NULL } })

    local replies = client:pipeline({ { 'INCR', key('hits') }, { 'PEXPIRE', key('hits'), 60000 }, { 'GET', key('x') } })

    t.assert_equals({ replies[1], replies[2], replies[3] }, { 1, 1, box.NULL })
    client:command({ 'DEL', name, key('hits') })
end

g.test_errors_of_the_server_come_as_kinds_and_the_connection_stays = function()
    local client = connect({ pool = { size = 1 } })
    local name = key('wrongtype')

    client:command({ 'SET', name, 'v', 'EX', 60 })

    local _, wrongtype = client:command({ 'LPUSH', name, 'x' }, { idempotent = true })

    t.assert_equals({ wrongtype.kind, wrongtype.server_code, wrongtype.retriable }, { 'rejected', 'WRONGTYPE', false })
    t.assert_equals(wrongtype.message, 'WRONGTYPE Operation against a key holding the wrong kind of value')

    -- Ошибка внутри массива: ответ дочитан, соединение цело.
    local _, nested = client:command({ 'EVAL', 'return {1, redis.error_reply("MY custom"), 3}', 0 })

    t.assert_equals({ nested.kind, nested.server_code, nested.message }, { 'rejected', 'MY', 'MY custom' })

    local _, noscript = client:command({ 'EVALSHA', ('f'):rep(40), 0 })

    t.assert_equals({ noscript.kind, noscript.server_code }, { 'rejected', 'NOSCRIPT' })
    t.assert_equals({ client:command({ 'GET', name }) }, { 'v' })

    local stats = client:stats()

    t.assert_equals({ stats.opened, stats.drops }, { 1, 0 })
    client:command({ 'DEL', name })
end

g.test_logins_and_rights = function()
    t.assert_equals({ connect({ username = 'app', password = 'app-secret' }):command({ 'PING' }) }, { 'PONG' })

    local started = clock.monotonic()
    local _, wrong = connect({ password = 'wrong' }):command({ 'PING' }, { idempotent = true })

    t.assert_equals({ wrong.kind, wrong.retriable, wrong.server_code }, { 'denied', false, 'WRONGPASS' })
    t.assert_equals(
        wrong.message,
        ('redis 127.0.0.1:%d: вход не удался: WRONGPASS invalid username-password pair or user is disabled.'):format(
            PORT
        )
    )
    t.assert(clock.monotonic() - started < 0.5)

    local reader = connect({ username = 'reader', password = 'reader-secret' })
    local _, noperm = reader:command({ 'SET', key('reader'), 'v' })

    t.assert_equals({ noperm.kind, noperm.server_code, noperm.sent }, { 'denied', 'NOPERM', false })
    t.assert_equals({ reader:command({ 'GET', key('reader') }) }, {})

    local _, far = connect({ db = 99 }):command({ 'PING' })

    t.assert_equals({ far.kind, far.message }, {
        'denied',
        ('redis 127.0.0.1:%d: вход не удался: ERR DB index is out of range'):format(PORT),
    })
end

g.test_the_database_is_the_one_in_the_settings = function()
    local first = connect({ db = 1 })
    local zero = connect()
    local name = key('db')

    first:command({ 'SET', name, 'one', 'EX', 60 })

    t.assert_equals({ first:command({ 'GET', name }) }, { 'one' })
    t.assert_equals({ zero:command({ 'GET', name }) }, {})
    first:command({ 'DEL', name })
end

g.test_an_unanswered_command_is_a_timeout_and_the_connection_is_closed = function()
    local client = connect({ pool = { size = 1 } })
    local watcher = connect()
    local id = client:command({ 'CLIENT', 'ID' })
    local started = clock.monotonic()
    local _, err = client:command({ 'BLPOP', key('queue'), 5 }, { timeout = 0.2 })
    local spent = clock.monotonic() - started

    t.assert_equals({ err.kind, err.sent, err.retriable }, { 'timeout', true, false })
    t.assert(spent >= 0.19 and spent < 0.5, spent)
    t.assert_equals(client:stats().drops, 1)
    -- Выброшенное соединение закрыто: сервер его больше не держит.
    -- Ищется своё соединение, а не всякое с BLPOP: на общем сервере BLPOP
    -- ждёт и у той же проверки из соседней копии.
    t.helpers.retrying({ timeout = 2 }, function()
        t.assert_equals({ watcher:command({ 'CLIENT', 'LIST', 'ID', id }) }, { '' })
    end)
end

g.test_a_killed_connection_is_broken_mid_call_and_replaced_when_idle = function()
    local client = connect({ pool = { size = 1 } })
    local killer = connect()
    local id = client:command({ 'CLIENT', 'ID' })
    local seen = {}
    local caller = fiber.new(function()
        seen.result, seen.err = client:command({ 'BLPOP', key('queue'), 5 }, { timeout = 3 })
    end)

    caller:set_joinable(true)
    fiber.sleep(0.1)
    t.assert_equals({ killer:command({ 'CLIENT', 'KILL', 'ID', id }) }, { 1 })
    caller:join()

    t.assert_equals({ seen.err.kind, seen.err.sent, seen.err.retriable }, { 'broken', true, false })

    -- Убитое в простое соединение отсеивается до выдачи: неидемпотентная
    -- команда проходит без повтора.
    local idle = client:command({ 'CLIENT', 'ID' })
    local peer = helper.idle_socket(client)

    t.assert_equals({ killer:command({ 'CLIENT', 'KILL', 'ID', idle }) }, { 1 })
    helper.until_closed(peer)
    t.assert_equals({ client:command({ 'INCR', key('after-kill') }) }, { 1 })
    t.assert_equals(client:stats().opened, 3)
    killer:command({ 'DEL', key('after-kill') })
end

--- Очередь на сервер BUSY. Сервер у проверки свой, но один на машину:
--- проверка BUSY из соседней копии заняла бы его своим сценарием посреди
--- этой, и её `SCRIPT KILL` снял бы наш. Очередь — ключом на том же
--- сервере: занять его — значит записать ключ, которого ещё нет, а пока
--- чужой сценарий идёт, сервер не примет и этой записи.
local BUSY_TURN = 'tnt-redis-live:busy-turn'

--- Сколько держится очередь, мс: дольше проверки вместе с её сценарием.
--- Прогон, убитый посреди проверки, держит соседей не дольше этого.
local BUSY_TURN_MS = 10000

--- Отпустить очередь можно только свою: чужую, взятую после истечения
--- нашей, снимать нельзя.
local RELEASE = "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) end return 0"

--- Сценарий-долгожитель. Кончается сам не позже чем через четыре
--- секунды, раньше срока вызова, который его ждёт: прогон, убитый
--- до `SCRIPT KILL` (в том числе пределом мутационного прогона),
--- не оставит сервер занятым навсегда, а с ним и все следующие проверки
--- BUSY на машине.
local LONG_SCRIPT = "local stop = tonumber(redis.call('TIME')[1]) + 4 "
    .. "while tonumber(redis.call('TIME')[1]) < stop do end"

--- Занимает сервер BUSY: ждёт, пока его отпустит проверка соседней копии.
---@param client any Драйвер к серверу BUSY
local function take_busy_turn(client)
    local deadline = clock.monotonic() + 2 * BUSY_TURN_MS / 1000

    -- Отказ тут не беда, а ожидание: пока чужой сценарий идёт, сервер
    -- отвечает BUSY и на вход, и на запись.
    while client:command({ 'SET', BUSY_TURN, RUN, 'NX', 'PX', BUSY_TURN_MS }, { timeout = 1 }) ~= 'OK' do
        t.assert(
            clock.monotonic() < deadline,
            'сервер для проверки BUSY занят дольше срока очереди'
        )
        fiber.sleep(0.05)
    end

    g.busy = client
end

g.test_a_busy_server_is_repeated_until_it_answers = function()
    t.skip_if(
        not listening(BUSY_PORT),
        'нет сервера для проверки BUSY: поднимите Redis заново — make redis-up'
    )

    local killer = connect({ port = BUSY_PORT })

    take_busy_turn(killer)

    local runner = connect({ port = BUSY_PORT })
    local impatient = connect({ port = BUSY_PORT, retry = { attempts = 1 } })
    local patient = connect({ port = BUSY_PORT, retry = { attempts = 20, base = 0.05, max = 0.1 } })

    -- Соединения открыты до сценария: пока он идёт, сервер отвечает BUSY
    -- и на команды входа, и новое соединение не откроется вовсе.
    for _, client in ipairs({ impatient, patient }) do
        t.assert_equals({ client:command({ 'PING' }) }, { 'PONG' })
    end

    local ran = {}
    local script = fiber.new(function()
        ran.result, ran.err = runner:command({ 'EVAL', LONG_SCRIPT, 0 }, { timeout = 5 })
    end)

    script:set_joinable(true)
    fiber.sleep(0.3)

    local _, busy = impatient:command({ 'GET', key('busy') })

    t.assert_equals({ busy.kind, busy.server_code, busy.retriable, busy.sent }, { 'busy', 'BUSY', true, false })

    local started = clock.monotonic()
    local seen = {}
    local waiter = fiber.new(function()
        seen.result, seen.err = patient:command({ 'GET', key('busy') }, { timeout = 3 })
    end)

    waiter:set_joinable(true)
    fiber.sleep(0.2)
    t.assert_equals({ killer:command({ 'SCRIPT', 'KILL' }) }, { 'OK' })
    waiter:join()

    t.assert_equals(seen.err, nil)
    t.assert(clock.monotonic() - started >= 0.2)

    script:join()

    t.assert_equals(ran.err.kind, 'rejected')
    t.assert_str_contains(ran.err.message, 'Script killed by user with SCRIPT KILL')
end

-- Сценарий снимается, а очередь отпускается и тогда, когда проверка упала
-- посреди сценария: иначе сервер был бы занят до конца сценария, а соседние
-- копии ждали бы до конца очереди. Хук проверки идёт раньше `after_each`,
-- который закрывает драйверы, — снимать нечем было бы.
g.after_test('test_a_busy_server_is_repeated_until_it_answers', function()
    if g.busy ~= nil then
        g.busy:command({ 'SCRIPT', 'KILL' })
        g.busy:command({ 'EVAL', RELEASE, 1, BUSY_TURN, RUN })
        g.busy = nil
    end
end)

g.test_a_reply_longer_than_max_bytes_is_an_overflow = function()
    local writer = connect()
    local name = key('big')

    writer:command({ 'SET', name, ('x'):rep(100000), 'EX', 60 })

    local reader = connect({ max_bytes = 65536 })
    local _, err = reader:command({ 'GET', name })

    t.assert_equals(err.kind, 'overflow')
    t.assert_str_contains(err.message, 'строка в 100000 байт')
    t.assert_equals(reader:stats().drops, 1)
    writer:command({ 'DEL', name })
end

g.test_tls_with_the_root_of_the_stand = function()
    local ca = fio.pathjoin(TLS_DIR, 'ca.pem')

    t.skip_if(
        not fio.path.exists(ca),
        'нет корня стенда: поднимите Redis заново — make redis-up'
    )

    local secured = connect({ port = TLS_PORT, tls = { ca_file = ca } })

    t.assert_equals({ secured:command({ 'PING' }) }, { 'PONG' })

    local unverified = connect({ port = TLS_PORT, tls = { verify = false } })

    t.assert_equals({ unverified:command({ 'PING' }) }, { 'PONG' })
    -- TLS к открытому порту: сервер не отвечает рукопожатием.
    local _, plain = connect({ tls = { verify = false } }):command({ 'PING' }, { timeout = 1 })

    t.assert_equals(plain.kind, 'unreachable')
end

g.test_a_certificate_of_an_unknown_root_is_denied_at_once = function()
    -- Корень стенда самоподписанный, и среди системных его нет. Время
    -- это не лечит: отказ приходит сразу, со словом о сертификате,
    -- а вход пробуется один раз — ни пул, ни повторы вызова его не повторяют.
    -- Корень стенда здесь не нужен, поэтому проверка идёт и на стенде,
    -- поднятом без каталога сертификатов.
    t.skip_if(not listening(TLS_PORT), 'нет порта TLS: поднимите Redis заново — make redis-up')

    local client = connect({ port = TLS_PORT, tls = true })
    local started = clock.monotonic()
    local _, unknown = client:command({ 'PING' }, { timeout = 1, idempotent = true })
    local spent = clock.monotonic() - started

    t.assert_equals({ unknown.kind, unknown.retriable, unknown.sent }, { 'denied', false, false })
    t.assert_str_contains(unknown.message, 'рукопожатие TLS не прошло')
    t.assert_str_contains(unknown.message, 'сертификат не принят')
    t.assert_lt(spent, 0.5)
    t.assert_equals(client:stats().open_failures, 1, 'вход пробовали один раз')
end

--- Настройки TLS с корнем стенда; без корня проверка пропускается.
---@param extra table|nil Что добавить к корню
---@return table
local function stand_tls(extra)
    local ca = fio.pathjoin(TLS_DIR, 'ca.pem')

    t.skip_if(
        not fio.path.exists(ca),
        'нет корня стенда: поднимите Redis заново — make redis-up'
    )

    local tls = { ca_file = ca }

    for name, value in pairs(extra or {}) do
        tls[name] = value
    end

    return tls
end

g.test_a_server_that_demands_a_client_certificate = function()
    local cert = fio.pathjoin(TLS_DIR, 'client.pem')

    t.skip_if(
        not fio.path.exists(cert) or not listening(MTLS_PORT),
        'нет сервера с tls-auth-clients yes: поднимите Redis заново — make redis-up'
    )

    local presented = connect({
        port = MTLS_PORT,
        tls = stand_tls({ cert_file = cert, key_file = fio.pathjoin(TLS_DIR, 'client.key') }),
    })

    t.assert_equals({ presented:command({ 'PING' }) }, { 'PONG' })

    -- Без сертификата рукопожатие у клиента проходит (в TLS 1.3 сервер
    -- судит о сертификате клиента позже), и отказ приходит на входе.
    local _, bare = connect({ port = MTLS_PORT, tls = stand_tls() }):command({ 'PING' }, { timeout = 1 })

    t.assert_equals({ bare.kind, bare.retriable }, { 'unreachable', true })
    t.assert_str_contains(bare.message, ('redis 127.0.0.1:%d: вход не завершился'):format(MTLS_PORT))
    t.assert_str_contains(bare.message, 'certificate required')
end

g.test_a_tls_connection_killed_while_idle_is_replaced_before_it_is_given = function()
    -- Под TLS в сокет только заглядывают: прощание сервера, убившего
    -- свободное соединение, видно до выдачи, и неидемпотентная команда
    -- проходит без повтора.
    local client = connect({ port = TLS_PORT, tls = stand_tls(), pool = { size = 1 } })
    local killer = connect()
    local idle = client:command({ 'CLIENT', 'ID' })

    t.assert_equals({ client:command({ 'PING' }) }, { 'PONG' })
    t.assert_equals(
        client:stats().opened,
        1,
        'живое свободное соединение не выбрасывается'
    )
    local peer = helper.idle_socket(client)

    t.assert_equals({ killer:command({ 'CLIENT', 'KILL', 'ID', idle }) }, { 1 })
    helper.until_closed(peer)
    t.assert_equals({ client:command({ 'INCR', key('after-tls-kill') }) }, { 1 })
    t.assert_equals(client:stats().opened, 2)
    killer:command({ 'DEL', key('after-tls-kill') })
end

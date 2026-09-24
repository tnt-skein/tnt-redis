--- Проверки фасада: команда и цепочка, отказ парой с родом, возврат
--- и выброс соединения, повторы по приговору, один срок на вызов,
--- закрытие и отмена — на двойнике сервера с настоящим сокетом.

local clock = require('clock')
local fiber = require('fiber')
local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local redis = helper.redis

local g = t.group('tnt.redis')

g.after_each(function()
    helper.restore()

    if g.client ~= nil then
        g.client:close()
        g.client = nil
    end

    if g.fake ~= nil then
        g.fake.stop()
        g.fake = nil
    end

    if g.journal ~= nil then
        g.journal.release()
        g.journal = nil
    end
end)

--- Поднимает двойник сервера и драйвер к нему на эту проверку.
---
--- Драйвер отдаётся без типа: проверки читают поля отказа, не сверяя
--- его с пустотой, — пустой отказ сам уронит проверку.
---@param respond fun(args: string[], number: integer): any
---@param opts table|nil Настройки драйвера
---@return any client
---@return TntRedisFake fake
local function connect(respond, opts)
    g.fake = helper.serve(respond)
    g.client = helper.client(g.fake, opts)

    return g.client, g.fake
end

--- Простой Redis в памяти: GET, SET, INCR, MGET, DEL.
---@return fun(args: string[]): string|nil
local function memory()
    local data = {}

    return function(args)
        local name = args[1]:upper()

        if name == 'SET' then
            data[args[2]] = args[3]

            return helper.status('OK')
        end

        if name == 'GET' then
            return data[args[2]] and helper.bulk(data[args[2]]) or helper.NULL
        end

        if name == 'INCR' then
            data[args[2]] = tostring((tonumber(data[args[2]]) or 0) + 1)

            return helper.integer(data[args[2]])
        end

        if name == 'MGET' then
            local items = {}

            for index = 2, #args do
                items[index - 1] = data[args[index]] and helper.bulk(data[args[index]]) or helper.NULL
            end

            return helper.array(unpack(items))
        end
    end
end

--- Род, приговор и отправка отказа.
---@param err any
---@return table
local function verdict(err)
    return { kind = err.kind, retriable = err.retriable, sent = err.sent }
end

--- Ждёт, пока соседний файбер не займёт соединение и не встанут в очередь
--- ждущие: пауза фиксированной длины под нагрузкой прогона с покрытием
--- кончается раньше, чем сосед успевает войти.
---@param client any
---@param waiting integer|nil Сколько ждущих в очереди пула; по умолчанию ни одного
local function until_taken(client, waiting)
    t.helpers.retrying({ timeout = 2 }, function()
        local stats = client:stats()

        t.assert_equals({ stats.busy, stats.waiting }, { 1, waiting or 0 })
    end)
end

--- Занимает соединение пула самой проверкой.
---
--- Пул отдаёт `open` только остаток срока взявшего, и держатель, входивший
--- командой, получал на вход срок ожидания пула — десятую долю секунды.
--- Под нагрузкой полного прогона вход в неё не укладывался, соединение
--- не открывалось, и держателю нечего было держать. Поэтому соединение
--- берётся мимо команды и с запасом срока. Держит его проверка, а не
--- чужой файбер с долгим ответом двойника: место занято, пока она его
--- не вернёт, сколько бы ни стоял цикл событий.
---@param client any
---@return any held Взятое соединение; возвращается `client.pool:give`
local function occupied(client)
    local held = client.pool:take(5)

    t.assert_not_equals(held, nil, 'соединение не открылось')

    return held
end

g.test_a_client_opens_nothing_until_the_first_call = function()
    local client, fake = connect(memory())

    t.assert_equals(client.name, 'redis')
    t.assert_equals(client.features, { transaction = false })
    t.assert_equals(fake.connections, 0)

    local stats = client:stats()

    t.assert_equals({ stats.name, stats.size, stats.total, stats.opened }, { 'redis', 8, 0, 0 })
end

g.test_a_command_answers_and_the_connection_serves_the_next = function()
    local client, fake = connect(memory(), { password = 'hunter2', name = 'cache' })

    t.assert_equals({ client:command({ 'SET', 'user:7', 'Анна' }) }, { 'OK' })
    t.assert_equals({ client:command({ 'GET', 'user:7' }) }, { 'Анна' })
    t.assert_equals({ client:command({ 'INCR', 'hits' }) }, { 1 })
    t.assert_equals({ client:command({ 'MGET', 'user:7', 'nobody' }) }, { { 'Анна', box.NULL } })
    t.assert_equals(fake.connections, 1)
    t.assert_equals(fake.commands, {
        { 'AUTH', 'hunter2' },
        { 'SET', 'user:7', 'Анна' },
        { 'GET', 'user:7' },
        { 'INCR', 'hits' },
        { 'MGET', 'user:7', 'nobody' },
    })

    local stats = client:stats()

    t.assert_equals({ stats.name, stats.busy, stats.idle, stats.takes, stats.gives }, { 'cache', 0, 1, 4, 4 })
    t.assert_not_str_contains(json.encode(stats), 'hunter2')
end

g.test_a_miss_is_nil_without_a_failure = function()
    local client = connect(memory())
    local result = { client:command({ 'GET', 'nobody' }) }

    t.assert_equals(select('#', unpack(result, 1, table.maxn(result))), 0)
    t.assert_equals(type((client:command({ 'GET', 'nobody' }))), 'nil')
    t.assert_equals(select('#', client:command({ 'GET', 'nobody' })), 1)
end

g.test_a_pipeline_sends_the_commands_at_once_and_answers_in_order = function()
    local client, fake = connect(memory())
    local replies = client:pipeline({ { 'SET', 'k', 'v' }, { 'GET', 'k' }, { 'GET', 'nobody' }, { 'INCR', 'n' } })

    t.assert_equals(replies, { 'OK', 'v', box.NULL, 1 })
    t.assert_equals(helper.sent(fake), { { 'SET', 'k', 'v' }, { 'GET', 'k' }, { 'GET', 'nobody' }, { 'INCR', 'n' } })
    t.assert_equals(client:stats().gives, 1)
end

g.test_a_refusal_of_the_server_is_rejected_and_the_connection_stays = function()
    local client, fake = connect(function(args)
        if args[1] == 'LPUSH' then
            return helper.error('WRONGTYPE Operation against a key holding the wrong kind of value')
        end

        return memory()(args)
    end)
    local result, err = client:command({ 'LPUSH', 'k', 'x' }, { idempotent = true })

    t.assert_equals(result, nil)
    t.assert(helper.failure.is(err))
    t.assert_equals(verdict(err), { kind = 'rejected', retriable = false, sent = true })
    t.assert_equals(err.server_code, 'WRONGTYPE')
    t.assert_equals(tostring(err), 'WRONGTYPE Operation against a key holding the wrong kind of value')

    local _, second = client:pipeline({ { 'SET', 'a', '1' }, { 'LPUSH', 'k', 'x' } })

    t.assert_equals(
        second.message,
        'команда 2 из 2: WRONGTYPE Operation against a key holding the wrong kind of value'
    )
    t.assert_equals(second.server_code, 'WRONGTYPE')
    -- Отказ сервера не рвёт соединение: оба вызова — на первом.
    t.assert_equals(fake.connections, 1)
    t.assert_equals(client:stats().drops, 0)
    t.assert_equals(#helper.sent(fake), 3)
end

g.test_a_command_refused_for_a_while_is_repeated = function()
    local answers = { helper.error('LOADING Redis is loading the dataset in memory'), helper.status('OK') }
    local client, fake = connect(function(args)
        if args[1] == 'SET' then
            return table.remove(answers, 1)
        end
    end)

    t.assert_equals({ client:command({ 'SET', 'k', 'v' }) }, { 'OK' })
    t.assert_equals(#helper.sent(fake), 2)
    t.assert_equals(fake.connections, 1)
end

g.test_a_former_leader_drops_the_connection_before_the_repeat = function()
    g.journal = helper.capture_log()

    local client, fake = connect(function(args, number)
        if args[1] == 'SET' and number == 1 then
            return helper.error("READONLY You can't write against a read only replica.")
        end

        return memory()(args)
    end)

    t.assert_equals({ client:command({ 'SET', 'k', 'v' }) }, { 'OK' })
    t.assert_equals(fake.connections, 2)
    t.assert_equals(client:stats().drops, 1)

    local record = g.journal.find('WARN [tnt.redis] соединение выброшено')

    t.assert_equals(record.record.fields, {
        driver = 'redis',
        kind = 'busy',
        reason = "READONLY You can't write against a read only replica.",
    })
end

g.test_a_command_without_rights_is_denied_once = function()
    local client, fake = connect(function(args)
        if args[1] == 'FLUSHALL' then
            return helper.error("NOPERM User reader has no permissions to run the 'flushall' command")
        end
    end)
    local _, err = client:command({ 'FLUSHALL' }, { idempotent = true })

    t.assert_equals(verdict(err), { kind = 'denied', retriable = false, sent = false })
    t.assert_equals(#helper.sent(fake), 1)
end

g.test_an_unanswered_command_is_a_timeout_and_the_connection_is_dropped = function()
    g.journal = helper.capture_log()

    local client, fake = connect(function(args)
        if args[1] == 'BLPOP' then
            return { delay = 5 }
        end
    end)

    -- Соединение открыто заранее и с запасом срока: срок вызова мерит одно
    -- ожидание — ответа. Вход, открытый самим вызовом, под нагрузкой
    -- прогона не укладывался в десятую долю секунды, и вместо отказа
    -- по сроку ответа приходил отказ входа.
    t.assert_equals(client.pool:give(occupied(client)), true)

    local started = clock.monotonic()
    local result, err = client:command({ 'BLPOP', 'secret-queue', '0' }, { timeout = 0.1 })
    local spent = clock.monotonic() - started

    t.assert_equals(result, nil)
    t.assert_equals(verdict(err), { kind = 'timeout', retriable = false, sent = true })
    t.assert_equals(
        err.message,
        ('redis 127.0.0.1:%d: ответа нет за срок вызова'):format(fake.port)
    )
    -- Не раньше срока вызова и задолго до ответа двойника через пять
    -- секунд. Граница посередине между ними: запас в три десятых секунды
    -- съедала одна остановка цикла под нагрузкой прогона.
    t.assert(spent >= 0.09 and spent < 2.5, spent)
    t.assert_equals(client:stats().drops, 1)

    local record = g.journal.find('WARN [tnt.redis] соединение выброшено')

    t.assert_not_equals(record, nil)
    t.assert_equals(record.record.fields, { driver = 'redis', kind = 'timeout', reason = err.message })
    -- Ни команды, ни ключа в журнале.
    t.assert_not(g.journal.logged('secret-queue'))
    t.assert_not(g.journal.logged('BLPOP'))
end

g.test_a_broken_connection_is_repeated_only_when_idempotent = function()
    local cut = true
    local client, fake = connect(function(args)
        if args[1] == 'INCR' and cut then
            cut = false

            return { reply = ':', close = true }
        end

        return memory()(args)
    end)
    local _, err = client:command({ 'INCR', 'hits' })

    t.assert_equals(verdict(err), { kind = 'broken', retriable = false, sent = true })
    t.assert_equals(
        err.message,
        ('redis 127.0.0.1:%d: сервер закрыл соединение посреди ответа'):format(
            fake.port
        )
    )

    cut = true

    t.assert_equals({ client:command({ 'INCR', 'hits' }, { idempotent = true }) }, { 1 })
    t.assert_equals(fake.connections, 3)
end

g.test_a_connection_closed_while_idle_is_replaced_without_a_repeat = function()
    local client, fake = connect(function(args)
        if args[1] == 'BYE' then
            return { reply = helper.status('OK'), close = true }
        end

        return memory()(args)
    end)

    local idle = helper.idle_socket(client)

    t.assert_equals({ client:command({ 'BYE' }) }, { 'OK' })
    t.assert_equals(fake.connections, 1)
    -- Ждётся сокет клиента, а не счёт закрытых у двойника: двойник знает
    -- о закрытии раньше, чем клиент может его увидеть.
    helper.until_closed(idle)
    -- Неидемпотентная команда проходит: соединение отсеяно до выдачи.
    t.assert_equals({ client:command({ 'INCR', 'hits' }) }, { 1 })
    t.assert_equals(fake.connections, 2)
    t.assert_equals(client:stats().drops, 0)
end

g.test_a_reply_longer_than_max_bytes_is_an_overflow = function()
    local client = connect(function(args)
        if args[1] == 'GET' then
            return helper.bulk(('x'):rep(100))
        end
    end, { max_bytes = 64 })
    local _, err = client:command({ 'GET', 'big' }, { idempotent = true })

    t.assert_equals(verdict(err), { kind = 'overflow', retriable = false, sent = true })
    t.assert_str_contains(
        err.message,
        'ответ длиннее предела max_bytes: строка в 100 байт, а осталось 58'
    )
    t.assert_equals(client:stats().drops, 1)
end

g.test_a_closed_port_is_unreachable_within_the_deadline = function()
    local port = helper.closed_port()

    -- Пауза пула после отказа открытия длиннее вызова: вход пробуется
    -- один раз, и текст отказа — его. Сроки с запасом: закрытый порт
    -- отказывает сразу, а вход по настоящему сокету получает весь срок
    -- ожидания пула. С десятой долей секунды остановка цикла под нагрузкой
    -- прогона превращала «Connection refused» в отказ по сроку соединения.
    g.client = helper.redis.new({
        port = port,
        timeout = 3,
        pool = { wait_timeout = 2, sweep_interval = 0, open_cooldown = 5 },
        retry = { base = 0 },
    })

    -- Ожидания пула и повторов — на часах двойника: проверка мгновенна,
    -- а длительность вызова сверяется точно, без допуска на остановки.
    local virtual = helper.virtual_time()
    local started = virtual.monotonic()
    local _, err = g.client:command({ 'GET', 'k' })
    local spent = virtual.monotonic() - started

    helper.restore()
    t.assert_equals(verdict(err), { kind = 'unreachable', retriable = true, sent = false })
    t.assert_str_contains(
        err.message,
        ('открыть соединение не удалось: redis 127.0.0.1:%d: соединение не открылось: Connection refused'):format(
            port
        )
    )
    t.assert_equals(g.client:stats().open_failures, 1)
    -- Вызов длится ровно свой срок: ожидание пула, затем его остаток.
    t.assert_equals(spent, 3)
end

g.test_a_refused_login_returns_at_once = function()
    local client, fake = connect(function(args)
        if args[1] == 'AUTH' then
            return helper.error('WRONGPASS invalid username-password pair or user is disabled.')
        end
    end, { username = 'app', password = 'wrong' })

    -- «Сразу» — без единого ожидания пула и повторов. На часах двойника
    -- каждое такое ожидание сдвинуло бы их на свой срок, а вход
    -- по настоящему сокету их не двигает. Настоящие часы мерили бы ещё
    -- и остановки цикла под нагрузкой прогона.
    local virtual = helper.virtual_time()
    local started = virtual.monotonic()
    local _, err = client:command({ 'GET', 'k' }, { idempotent = true })
    local spent = virtual.monotonic() - started

    helper.restore()
    t.assert_equals(verdict(err), { kind = 'denied', retriable = false, sent = false })
    t.assert_str_contains(err.message, 'вход не удался: WRONGPASS')
    t.assert_equals(spent, 0)
    -- Повторов нет: вход пробовали один раз.
    t.assert_equals(fake.connections, 1)
end

g.test_an_untrusted_certificate_returns_at_once = function()
    -- Неверный корень время не лечит: ни пул, ни повторы вызова вход
    -- не пробуют снова, и вызов отказывает сразу, а не в конце срока.
    local client = connect(function() end, { tls = true, timeout = 1 })

    helper.link._set_source({
        secure = function()
            return nil, 'сертификат не принят: self-signed certificate', helper.tls.UNTRUSTED
        end,
    })

    local started = clock.monotonic()
    local _, err = client:command({ 'PING' }, { idempotent = true })

    t.assert_equals(verdict(err), { kind = 'denied', retriable = false, sent = false })
    t.assert_str_contains(
        err.message,
        'рукопожатие TLS не прошло: сертификат не принят'
    )
    t.assert(clock.monotonic() - started < 0.5)

    local stats = client:stats()

    t.assert_equals({ stats.open_failures, stats.opened }, { 1, 0 }, 'вход пробовали один раз')
end

g.test_a_refused_login_while_others_hold_connections_is_denied_by_its_words = function()
    ---@type TntRedisClient|nil
    local client

    -- Пауза после отказа входа длиннее срока ожидания: попытка входа одна,
    -- и текст отказа по сроку — её. Иначе пул пробует снова, и попытка
    -- у самого края срока отказывает уже сроком соединения. Отвергается
    -- вход после первого открытого пулом соединения, а не второй
    -- пришедший: чужой клиент на освободившемся порту сдвинул бы счёт.
    --
    -- Сроки с запасом: вход идёт по настоящему сокету и получает весь срок
    -- ожидания пула. С десятой долей секунды остановка цикла под нагрузкой
    -- прогона обрывала вход сроком, и отказ выходил словами сети, а не
    -- сервера.
    client = connect(function(args)
        if args[1] == 'AUTH' and client ~= nil and client:stats().opened > 0 then
            return helper.error('WRONGPASS invalid username-password pair or user is disabled.')
        end
    end, { password = 'secret', pool = { size = 2, wait_timeout = 2, open_cooldown = 5 } })

    local held = occupied(client)

    -- Ожидание пула после отказа — на часах двойника: проверка мгновенна.
    helper.virtual_time()

    local _, err = client:command({ 'GET', 'k' }, { timeout = 3 })

    helper.restore()
    t.assert_equals(verdict(err), { kind = 'denied', retriable = false, sent = false })
    t.assert_str_contains(
        err.message,
        'соединение не получено за 2 с: открыть соединение не удалось:'
    )
    t.assert_str_contains(err.message, 'WRONGPASS')
    t.assert_equals(client.pool:give(held), true)
end

g.test_a_full_pool_is_busy = function()
    local client, fake = connect(memory(), { pool = { size = 1, wait_timeout = 0.1 } })
    local held = occupied(client)

    -- Сколько попыток уместится в четверть секунды, решают сроки ожидания
    -- пула, а не остановки цикла событий под нагрузкой прогона.
    helper.virtual_time()

    local _, err = client:command({ 'GET', 'k' }, { timeout = 0.25 })

    helper.restore()
    t.assert_equals(verdict(err), { kind = 'busy', retriable = true, sent = false })
    -- Срок последнего ожидания — остаток вызова, число в нём не круглое.
    t.assert_str_matches(
        err.message,
        ('redis 127%%.0%%.0%%.1:%d: соединение не получено за [%%d.]+ с: все 1 заняты'):format(
            fake.port
        )
    )
    -- Три попытки по умолчанию: 0.1, 0.1 и остаток.
    t.assert_equals(client:stats().wait_timeouts, 3)
    t.assert_equals(client.pool:give(held), true)
end

g.test_a_full_pool_is_busy_even_after_a_failed_open = function()
    ---@type TntRedisClient|nil
    local client

    -- Первый вход пула отвергнут на время: у пула остаётся текст отказа
    -- открытия, но мест в нём больше нет — это нехватка, а не вход.
    -- Отвергается вход, пока отказ не запишет сам пул, а не первый
    -- пришедший: порты петли общие на машину, и чужой клиент, стучащийся
    -- на освободившийся порт, забрал бы единственный отказ себе.
    client = connect(function(args)
        if args[1] == 'PING' and (client == nil or client:stats().open_failures == 0) then
            return helper.error('LOADING Redis is loading the dataset in memory')
        end
    end, { pool = { size = 1, wait_timeout = 0.1 } })

    local held = occupied(client)
    local stats = client:stats()

    t.assert_equals({ stats.total, stats.size, stats.open_failures }, { 1, 1, 1 })
    t.assert_str_contains(stats.last_open_error, 'LOADING')

    local _, err = client:command({ 'GET', 'k' }, { timeout = 0.1 })

    t.assert_equals(verdict(err), { kind = 'busy', retriable = true, sent = false })
    t.assert_str_contains(err.message, 'все 1 заняты')
    t.assert_equals(client.pool:give(held), true)
end

--- Часы срока, которые двигает проверка: настоящие стоят на тысячной
--- секунде, а планировщик отстаёт от них на `shift` — на столько срок
--- вызова в пять секунд уже съеден. `shift = 5` — остаток ровно ноль.
---@return table clock Поле `shift` двигает время планировщика
local function stopped_clock()
    local stopped = { shift = 0 }

    helper.within._set_source({
        monotonic = function()
            return 1000
        end,
        scheduler_now = function()
            return 1000 + stopped.shift
        end,
    })

    return stopped
end

g.test_a_deadline_gone_before_the_first_attempt_sends_nothing = function()
    local client, fake = connect(memory())
    local stopped = stopped_clock()

    -- Остаток ровно ноль — тоже «срок вышел», как и меньше нуля.
    for _, shift in ipairs({ 5, 100 }) do
        stopped.shift = shift

        local _, err = client:command({ 'GET', 'k' })

        t.assert_equals(verdict(err), { kind = 'timeout', retriable = false, sent = false }, shift)
        t.assert_equals(err.message, 'срок вызова вышел до отправки команды', shift)
    end

    t.assert_equals(fake.connections, 0)
end

--- Вход съедает срок: после взятия соединения время планировщика ушло
--- на `shift` секунд из пяти — ровно ноль остатка либо меньше.
---@param shift number
local function assert_returned_after_login(shift)
    local stopped = stopped_clock()
    local client, fake = connect(function(args)
        if args[1] == 'PING' then
            stopped.shift = shift
        end
    end)

    local _, err = client:command({ 'GET', 'k' })

    t.assert_equals(verdict(err), { kind = 'timeout', retriable = false, sent = false })
    t.assert_equals(helper.sent(fake), {})

    local stats = client:stats()

    t.assert_equals({ stats.idle, stats.drops }, { 1, 0 })
end

g.test_a_deadline_gone_while_waiting_for_the_pool_returns_the_connection = function()
    assert_returned_after_login(5)
end

g.test_a_deadline_long_gone_while_waiting_for_the_pool_returns_the_connection = function()
    assert_returned_after_login(100)
end

g.test_a_deadline_gone_before_a_repeat_returns_the_last_failure_without_a_repeat = function()
    local stopped = stopped_clock()
    local client, fake = connect(function(args)
        if args[1] == 'SET' then
            stopped.shift = 5

            return helper.error('LOADING Redis is loading the dataset in memory')
        end
    end)

    local _, err = client:command({ 'SET', 'k', 'v' })

    t.assert_equals(verdict(err), { kind = 'busy', retriable = false, sent = false })
    t.assert_equals(err.message, 'LOADING Redis is loading the dataset in memory')
    t.assert_equals(err.server_code, 'LOADING')
    t.assert_equals(err.reason, 'LOADING Redis is loading the dataset in memory')
    t.assert_equals(#helper.sent(fake), 1)
end

g.test_a_deadline_gone_while_a_repeat_waits_for_the_pool_returns_the_last_failure = function()
    local stopped = stopped_clock()
    local client, fake = connect(function(args, number)
        if args[1] == 'SET' and number == 1 then
            return helper.error("READONLY You can't write against a read only replica.")
        end

        -- Второе соединение открывается повтором, и вход съедает весь срок.
        if args[1] == 'PING' and number == 2 then
            stopped.shift = 5
        end
    end)

    local _, err = client:command({ 'SET', 'k', 'v' })

    t.assert_equals(verdict(err), { kind = 'busy', retriable = false, sent = false })
    t.assert_equals(err.server_code, 'READONLY')
    t.assert_equals(#helper.sent(fake), 1)
    t.assert_equals(fake.connections, 2)

    local stats = client:stats()

    t.assert_equals({ stats.idle, stats.drops }, { 1, 1 })
end

g.test_a_closed_client_refuses_with_a_pair = function()
    local client = connect(memory())

    t.assert_equals({ client:command({ 'SET', 'k', 'v' }) }, { 'OK' })
    t.assert_equals({ client:close() }, { true })

    local again, second = client:close()

    t.assert_equals(again, false)
    t.assert_equals({ second.kind, second.message }, { 'closed', 'redis: драйвер уже закрыт' })

    local result, err = client:command({ 'GET', 'k' })

    t.assert_equals(result, nil)
    t.assert_equals(verdict(err), { kind = 'closed', retriable = false, sent = false })
    t.assert_equals(err.message, 'redis: драйвер закрыт')
    t.assert_equals(client:stats().closed, true)
    g.client = nil
end

g.test_a_caller_waiting_for_the_pool_learns_that_it_is_closed = function()
    -- Одна попытка: закрытие узнаётся из отказа пула сразу, а не повтором.
    local client = connect(function(args)
        if args[1] == 'BLPOP' then
            return { delay = 0.3, reply = helper.NULL }
        end
    end, { pool = { size = 1, wait_timeout = 1 }, retry = { attempts = 1 } })
    local holder = fiber.new(function()
        client:command({ 'BLPOP', 'q', '1' }, { timeout = 1 })
    end)
    local seen = {}
    local waiter = fiber.new(function()
        seen.result, seen.err = client:command({ 'GET', 'k' }, { timeout = 1 })
    end)

    holder:set_joinable(true)
    waiter:set_joinable(true)
    until_taken(client, 1)
    client:close()
    waiter:join()

    t.assert_equals(seen.result, nil)
    t.assert_equals(verdict(seen.err), { kind = 'closed', retriable = false, sent = false })
    holder:join()
    g.client = nil
end

g.test_a_cancelled_caller_is_cancelled_and_the_connection_dropped = function()
    local client = connect(function(args)
        if args[1] == 'BLPOP' then
            return { delay = 5 }
        end
    end)
    local seen = {}
    local caller = fiber.new(function()
        seen.ok, seen.err = pcall(client.command, client, { 'BLPOP', 'q', '0' }, { timeout = 3, idempotent = true })
    end)

    caller:set_joinable(true)
    until_taken(client)
    caller:cancel()
    caller:join()

    t.assert_equals(seen.ok, false)
    t.assert_str_contains(tostring(seen.err), 'fiber is cancelled')

    local stats = client:stats()

    t.assert_equals({ stats.busy, stats.drops }, { 0, 1 })
end

g.test_wrong_calls_are_raised_at_the_callers_line = function()
    local client = connect(memory(), { max_timeout = 10 })

    helper.assert_blamed({
        {
            function()
                client:command({ 'GET', 'k' }, { timout = 1 })
            end,
            'настройки вызова: ключа «timout» нет, есть idempotent, timeout',
        },
        {
            function()
                client:command({ 'GET', 'k' }, { timeout = 30 })
            end,
            'timeout 30 с длиннее потолка max_timeout 10 с',
        },
        {
            function()
                client:command({ 'MULTI' })
            end,
            'команду MULTI драйвер не отправит: транзакции у драйвера нет (features.transaction = false): '
                .. 'атомарность даёт сценарий EVAL',
        },
        {
            function()
                client:command({ 'SET', 'k', true })
            end,
            'логику в Redis не передать: у него только строки — передайте строку явно',
        },
        {
            function()
                client:pipeline({ { 'GET', 'k' }, { 'WATCH', 'k' } })
            end,
            'команду WATCH драйвер не отправит: транзакции у драйвера нет (features.transaction = false): '
                .. 'атомарность даёт сценарий EVAL',
        },
        {
            function()
                client:pipeline({ { 'GET', 'k' }, 'GET k' })
            end,
            'команды[2] — массив, а не строка',
        },
        {
            function()
                client:pipeline({})
            end,
            'команды — непустой список, а не пустой',
        },
        {
            function()
                client:pipeline(helper.wrong('GET k'))
            end,
            'команды — массив, а не строка',
        },
        {
            function()
                client:pipeline({ { 'GET', 'k' } }, { timeout = 0 })
            end,
            'timeout — число секунд больше нуля и меньше бесконечности, а не 0',
        },
    })
end

g.test_wrong_settings_of_retries_are_raised_at_the_line_of_new = function()
    helper.assert_blamed({
        {
            function()
                redis.new({ retry = { factor = 0.5 }, pool = { sweep_interval = 0 } })
            end,
            'настройки повторов: настройка factor не может быть меньше 1',
        },
        {
            function()
                redis.new({ pasword = 'x' })
            end,
            'настройки redis: ключа «pasword» нет, есть db, host, max_bytes, max_timeout, name, password, '
                .. 'pool, port, retry, timeout, tls, username',
        },
    })
end

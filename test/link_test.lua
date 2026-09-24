--- Проверки связи: вход одним обменом, TLS, обмен в срок, обрывы
--- и живость без сети — на двойнике сервера с настоящим сокетом.

local clock = require('clock')
local fiber = require('fiber')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local link = helper.link
local resp = helper.resp
local within = helper.within

local g = t.group('tnt.redis.link')

--- Предел байтов с запасом для проверок.
local BUDGET = 1024

g.after_each(function()
    helper.restore()

    if g.fake ~= nil then
        g.fake.stop()
        g.fake = nil
    end
end)

--- Поднимает двойник сервера на эту проверку.
---@param respond fun(args: string[], number: integer): any
---@return TntRedisFake
local function serve(respond)
    g.fake = helper.serve(respond)

    return g.fake
end

--- Настройки связи к двойнику.
---@param fake TntRedisFake|nil
---@param opts table|nil
---@return TntRedisSettings
local function settings(fake, opts)
    local given = opts or {}

    given.port = given.port or (fake --[[@as TntRedisFake]]).port

    -- Не хвостовым вызовом: бросок проверки настроек называет строку
    -- того, кто позвал зовущего, и хвостовой вызов отдал бы это место
    -- кадру luatest — а бросок из кадра luatest мутационный гейт считает
    -- отказом запуска, а не упавшей проверкой.
    local checked = helper.settings.check(given)

    return checked
end

--- Обмен одной командой в срок.
---@param opened TntRedisLink
---@param args string[]
---@param timeout number|nil
---@return any replies
---@return any trouble
local function exchange(opened, args, timeout)
    return link.exchange(opened, resp.encode(args), 1, within.deadline(timeout or 1), BUDGET)
end

--- Отказ открытия: род, приговор, отправка, текст.
---@param err TntStorageFailure
---@return table
local function shape(err)
    return { kind = err.kind, retriable = err.retriable, sent = err.sent, message = err.message }
end

g.test_open_greets_with_ping_and_the_link_talks = function()
    local fake = serve(function(args)
        if args[1] == 'GET' then
            return helper.bulk('v')
        end
    end)
    local opened = link.open(settings(fake), 1)

    t.assert_equals(opened.secured, false)
    t.assert_equals(fake.commands, { { 'PING' } })
    t.assert_equals(exchange(opened, { 'GET', 'k' }), { { value = 'v' } })
    t.assert_equals(fake.commands, { { 'PING' }, { 'GET', 'k' } })

    link.close(opened)
end

g.test_open_logs_in_and_selects_the_database_in_one_exchange = function()
    local fake = serve(function() end)
    local opened = link.open(settings(fake, { username = 'app', password = 'secret', db = 2 }), 1)

    t.assert_not_equals(opened, nil)
    t.assert_equals(fake.commands, { { 'AUTH', 'app', 'secret' }, { 'SELECT', '2' } })

    link.close(opened)
end

g.test_a_refused_login_is_denied_and_the_link_is_closed = function()
    local fake = serve(function(args)
        if args[1] == 'AUTH' then
            return helper.error('WRONGPASS invalid username-password pair or user is disabled.')
        end

        return helper.error('NOAUTH Authentication required.')
    end)
    local opened, err = link.open(settings(fake, { password = 'wrong', db = 1 }), 1)

    t.assert_equals(opened, nil)
    t.assert(helper.failure.is(err))
    t.assert_equals(shape(err), {
        kind = 'denied',
        retriable = false,
        sent = false,
        message = (
            'redis 127.0.0.1:%d: вход не удался: '
            .. 'WRONGPASS invalid username-password pair or user is disabled.'
        ):format(fake.port),
    })
    t.assert_equals(err.server_code, 'WRONGPASS')
    -- Отказ дочитан до конца, и связь закрыта: сервер видит конец потока.
    t.assert_equals(#fake.commands, 2)
    t.helpers.retrying({ timeout = 1 }, function()
        t.assert_equals(fake.finished, 1)
    end)
end

g.test_a_login_refused_by_words_or_for_a_while_has_its_kind = function()
    local answers = {
        { 'ERR invalid password', 'denied', false },
        { 'ERR DB index is out of range', 'denied', false },
        { 'LOADING Redis is loading the dataset in memory', 'unreachable', true },
        { 'ERR max number of clients reached', 'unreachable', true },
    }

    for _, answer in ipairs(answers) do
        local fake = serve(function()
            return helper.error(answer[1])
        end)
        local opened, err = link.open(settings(fake), 1)

        t.assert_equals(opened, nil)
        t.assert_equals({ err.kind, err.retriable }, { answer[2], answer[3] }, answer[1])
        fake.stop()
        g.fake = nil
    end
end

g.test_a_closed_port_is_unreachable = function()
    local port = helper.closed_port()
    local opened, err = link.open(settings(nil, { port = port }), 1)

    t.assert_equals(opened, nil)
    t.assert_equals(shape(err), {
        kind = 'unreachable',
        retriable = true,
        sent = false,
        message = ('redis 127.0.0.1:%d: соединение не открылось: Connection refused'):format(port),
    })
end

g.test_a_connect_that_raises_is_unreachable = function()
    local asked = {}

    link._set_source({
        connect = function(host, port, timeout)
            table.insert(asked, { host, port, timeout })
            error('имя узла не разрешилось', 0)
        end,
    })

    local opened, err = link.open(settings(nil, { host = 'cache', port = 6390 }), 0.5)

    t.assert_equals(opened, nil)
    t.assert_equals(
        err.message,
        'redis cache:6390: соединение не открылось: имя узла не разрешилось'
    )
    t.assert_equals(asked, { { 'cache', 6390, 0.5 } })
end

g.test_a_greeting_cut_short_or_unanswered_is_unreachable = function()
    local fake = serve(function()
        return { reply = '+PO', close = true }
    end)
    local _, cut = link.open(settings(fake), 1)

    t.assert_equals(shape(cut), {
        kind = 'unreachable',
        retriable = true,
        sent = false,
        message = ('redis 127.0.0.1:%d: вход не завершился: сервер закрыл соединение посреди ответа'):format(
            fake.port
        ),
    })

    fake.stop()

    local silent = serve(function()
        return { delay = 10 }
    end)
    local started = clock.monotonic()
    local _, expired = link.open(settings(silent), 0.1)
    local spent = clock.monotonic() - started

    t.assert_equals(
        expired.message,
        ('redis 127.0.0.1:%d: вход не завершился: ответа нет за срок вызова'):format(
            silent.port
        )
    )
    t.assert_equals(expired.kind, 'unreachable')
    t.assert(spent >= 0.09 and spent < 0.5, spent)
end

--- Шифрование двойником: разговор идёт тем же сокетом, а настройки,
--- ушедшие в `tnt-tls`, запоминаются.
---
--- Свободно ли соединение, двойник отвечает по `asked.idle`: по умолчанию
--- да. Сокет двойник для этого не трогает — так видно, что под TLS
--- живость спрашивается у соединения `tnt-tls`, а не у сокета.
---@param asked table Куда складывать настройки; поле idle — ответ на вопрос о свободе
---@param refusal string|nil Чем отказать вместо рукопожатия
---@param kind string|nil Род отказа, как его называет `tnt-tls`
local function fake_tls(asked, refusal, kind)
    link._set_source({
        secure = function(socket, opts)
            table.insert(asked, opts)

            if refusal ~= nil then
                return nil, refusal, kind
            end

            return {
                read = function(_, opts_, timeout)
                    return socket:read(opts_, timeout)
                end,
                write = function(_, data, timeout)
                    return socket:write(data, timeout) ~= nil
                end,
                close = function()
                    socket:close()
                end,
                idle = function()
                    return asked.idle ~= false
                end,
            }
        end,
    })
end

g.test_tls_goes_through_tnt_tls_with_the_rest_of_the_deadline = function()
    local fake = serve(function() end)
    local asked = {}

    fake_tls(asked)

    local tls = {
        verify = false,
        ca_file = '/ca.pem',
        ca_path = '/ca',
        sni = 'cache',
        cert_file = '/client.pem',
        key_file = '/client.key',
    }
    local opened = link.open(settings(fake, { tls = tls }), 0.5)

    t.assert_equals(opened.secured, true)
    t.assert_equals(fake.commands, { { 'PING' } })
    t.assert_equals(#asked, 1)
    t.assert(asked[1].timeout > 0.4 and asked[1].timeout <= 0.5, asked[1].timeout)
    asked[1].timeout = nil
    t.assert_equals(asked[1], {
        host = '127.0.0.1',
        verify = false,
        ca_file = '/ca.pem',
        ca_path = '/ca',
        sni = 'cache',
        cert_file = '/client.pem',
        key_file = '/client.key',
    })

    -- Под TLS живость спрашивается у соединения `tnt-tls`, а не у сокета:
    -- в сокете бывают служебные записи, и читать их вправе только OpenSSL.
    t.assert_equals(link.alive(opened), true)
    asked.idle = false
    t.assert_equals(link.alive(opened), false)

    link.close(opened)
end

g.test_a_failed_handshake_is_unreachable_and_closes_the_socket = function()
    local fake = serve(function() end)
    local asked = {}

    fake_tls(asked, 'сертификат не прошёл проверку')

    local opened, err = link.open(settings(fake, { tls = true }), 1)

    t.assert_equals(opened, nil)
    t.assert_equals(shape(err), {
        kind = 'unreachable',
        retriable = true,
        sent = false,
        message = ('redis 127.0.0.1:%d: рукопожатие TLS не прошло: сертификат не прошёл проверку'):format(
            fake.port
        ),
    })
    t.helpers.retrying({ timeout = 1 }, function()
        t.assert_equals({ fake.connections, fake.finished }, { 1, 1 })
    end)
end

g.test_an_untrusted_certificate_is_denied_and_closes_the_socket = function()
    -- Время неверный корень не лечит: пул отдаёт `denied` сразу, а не
    -- повторяет вход до конца срока, выдавая настройку за моргнувшую сеть.
    local fake = serve(function() end)
    local refusal =
        'рукопожатие TLS не удалось: сертификат не принят: self-signed certificate'

    fake_tls({}, refusal, helper.tls.UNTRUSTED)

    local opened, err = link.open(settings(fake, { tls = true }), 1)

    t.assert_equals(opened, nil)
    t.assert_equals(shape(err), {
        kind = 'denied',
        retriable = false,
        sent = false,
        message = ('redis 127.0.0.1:%d: рукопожатие TLS не прошло: %s'):format(fake.port, refusal),
    })
    t.helpers.retrying({ timeout = 1 }, function()
        t.assert_equals({ fake.connections, fake.finished }, { 1, 1 })
    end)
end

g.test_a_server_without_tls_fails_the_real_handshake = function()
    -- Настоящий `tnt-tls` против двойника, который TLS не говорит: двойник
    -- не разбирает приветствия TLS и закрывает соединение, рукопожатие
    -- обрывается.
    local fake = serve(function() end)
    local opened, err = link.open(settings(fake, { tls = { verify = false } }), 2)

    t.assert_equals(opened, nil)
    t.assert_equals({ err.kind, err.retriable }, { 'unreachable', true })
    t.assert_str_contains(
        err.message,
        ('redis 127.0.0.1:%d: рукопожатие TLS не прошло: рукопожатие TLS не удалось'):format(
            fake.port
        )
    )
    t.assert_equals(fake.commands, {})
end

--- Часы, у которых миг срока — сто первая секунда, а планировщик — на `now`.
---@param now number
local function frozen_at(now)
    within._set_source({
        monotonic = function()
            return 100
        end,
        scheduler_now = function()
            return now
        end,
    })
end

g.test_no_time_left_for_the_handshake_is_unreachable = function()
    local fake = serve(function() end)
    local asked = {}

    fake_tls(asked)

    -- Миг входа — сто первая секунда, а планировщик уже на ней и за ней:
    -- остаток ровно ноль — тоже «времени нет».
    for _, now in ipairs({ 101, 200 }) do
        frozen_at(now)

        local _, err = link.open(settings(fake, { tls = true }), 1)

        t.assert_equals(
            err.message,
            ('redis 127.0.0.1:%d: рукопожатие TLS не прошло: срок входа вышел до рукопожатия TLS'):format(
                fake.port
            ),
            now
        )
    end

    t.assert_equals(asked, {})
end

g.test_an_unanswered_command_is_a_timeout = function()
    local fake = serve(function(args)
        if args[1] == 'BLPOP' then
            return { delay = 10 }
        end
    end)
    local opened = link.open(settings(fake), 1)
    local started = clock.monotonic()
    local replies, trouble = exchange(opened, { 'BLPOP', 'q', '0' }, 0.1)
    local spent = clock.monotonic() - started

    t.assert_equals(replies, nil)
    t.assert_equals(trouble, { kind = 'timeout', message = 'ответа нет за срок вызова' })
    t.assert(spent >= 0.09 and spent < 0.5, spent)

    link.close(opened)
end

g.test_a_connection_closed_by_the_server_is_seen_idle_and_mid_reply = function()
    local fake = serve(function(args)
        if args[1] == 'QUIT_SOON' then
            return { reply = helper.status('OK'), close = true }
        end

        if args[1] == 'HALF' then
            return { reply = '$10\r\nabc', close = true }
        end
    end)
    local idle = link.open(settings(fake), 1)

    t.assert_equals(link.alive(idle), true)
    t.assert_equals(exchange(idle, { 'QUIT_SOON' }), { { value = 'OK' } })
    -- Сервер закрыл свободное соединение: живость видит это без сети.
    t.helpers.retrying({ timeout = 1 }, function()
        t.assert_equals(link.alive(idle), false)
    end)
    link.close(idle)
    -- Закрытый сокет бросает на чтении — это тоже «не живо».
    t.assert_equals(link.alive(idle), false)
    link.close(idle)

    local busy = link.open(settings(fake), 1)

    t.assert_equals({ exchange(busy, { 'HALF' }) }, {
        nil,
        { kind = 'broken', message = 'сервер закрыл соединение посреди ответа' },
    })
    link.close(busy)
end

--- Связь поверх двойника ввода-вывода, без сети.
---@param io table
---@return TntRedisLink
local function over(io)
    return { io = io, socket = nil, secured = true }
end

g.test_a_failed_write_did_not_send_a_lone_command = function()
    local failed = over({
        write = function()
            return false, 'Broken pipe'
        end,
    })
    local deadline = within.deadline(1)

    t.assert_equals({ link.exchange(failed, 'x', 1, deadline, BUDGET) }, {
        nil,
        { kind = 'broken', message = 'команда не ушла: Broken pipe', sent = false, retriable = true },
    })
    -- Из нескольких команд первые могли уйти целиком.
    t.assert_equals({ link.exchange(failed, 'x', 2, deadline, BUDGET) }, {
        nil,
        { kind = 'broken', message = 'команда не ушла: Broken pipe', sent = true },
    })

    local raising = over({
        write = function()
            error('attempt to use closed socket', 0)
        end,
    })

    t.assert_equals({ link.exchange(raising, 'x', 1, deadline, BUDGET) }, {
        nil,
        {
            kind = 'broken',
            message = 'команда не ушла: attempt to use closed socket',
            sent = false,
            retriable = true,
        },
    })
end

g.test_a_write_that_ran_out_of_time_is_a_timeout = function()
    frozen_at(200)

    local slow = over({
        write = function(_, _, timeout)
            return false, ('не принял запись за %s с'):format(timeout)
        end,
    })

    t.assert_equals({ link.exchange(slow, 'x', 1, within.deadline(1), BUDGET) }, {
        nil,
        {
            kind = 'timeout',
            message = 'команда не ушла: не принял запись за -99 с',
            sent = false,
        },
    })
end

g.test_a_failed_read_is_broken_with_its_reason = function()
    local written = function()
        return true
    end
    local reset = over({
        write = written,
        read = function()
            return nil, 'Connection reset by peer'
        end,
    })
    -- Остаток меньше секунды: обрыв — это обрыв, пока срок не вышел.
    local deadline = within.deadline(0.5)

    t.assert_equals(
        { link.exchange(reset, 'x', 1, deadline, BUDGET) },
        { nil, { kind = 'broken', message = 'соединение оборвалось: Connection reset by peer' } }
    )

    local raising = over({
        write = written,
        read = function()
            error('attempt to use closed socket', 0)
        end,
    })

    t.assert_equals({ link.exchange(raising, 'x', 1, deadline, BUDGET) }, {
        nil,
        { kind = 'broken', message = 'соединение оборвалось: attempt to use closed socket' },
    })
end

g.test_a_failure_exactly_at_the_deadline_is_a_timeout = function()
    frozen_at(101)

    local silent = over({
        write = function()
            return true
        end,
        read = function()
            return nil, 'Operation timed out'
        end,
    })

    t.assert_equals(
        { link.exchange(silent, 'x', 1, within.deadline(1), BUDGET) },
        { nil, { kind = 'timeout', message = 'ответа нет за срок вызова' } }
    )
end

g.test_a_plain_socket_speaks_as_a_pair = function()
    local fake = serve(function() end)
    local opened = link.open(settings(fake), 1)

    opened.socket:close()

    -- Закрытый сокет бросает, а сокет с отказом отвечает парой.
    local closed_io = opened.io

    t.assert_error_msg_contains('attempt to use closed socket', closed_io.read, closed_io, { chunk = 1 }, 0.1)

    local reopened = link.open(settings(fake), 1)
    local io = reopened.io

    t.assert_equals({ io:read({ chunk = 1 }, 0.01) }, { nil, reopened.socket:error() })
    t.assert_not_equals(reopened.socket:error(), nil)
    fake.stop()
    g.fake = nil
    t.helpers.retrying({ timeout = 1 }, function()
        t.assert_equals(io:read({ chunk = 1 }, 0.01), '')
    end)
    t.helpers.retrying({ timeout = 1 }, function()
        local ok, why = io:write(('x'):rep(65536), 0.01)

        t.assert_equals(ok, false)
        t.assert_equals(why, reopened.socket:error())
    end)
    link.close(reopened)
end

g.test_a_cancelled_caller_gets_a_trouble_and_stays_cancelled = function()
    local fake = serve(function(args)
        if args[1] == 'SLOW' then
            return { delay = 10 }
        end
    end)
    local opened = link.open(settings(fake), 1)
    local seen = {}
    local reader = fiber.new(function()
        local replies, trouble = exchange(opened, { 'SLOW' }, 5)

        seen.replies = replies
        seen.trouble = trouble
        seen.cancelled = not pcall(fiber.testcancel)
    end)

    reader:set_joinable(true)
    fiber.sleep(0.05)
    reader:cancel()
    reader:join()

    t.assert_equals(seen.replies, nil)
    t.assert_equals(seen.trouble.kind, 'broken')
    t.assert_str_contains(seen.trouble.message, 'fiber is cancelled')
    t.assert_equals(seen.cancelled, true)
    link.close(opened)
end

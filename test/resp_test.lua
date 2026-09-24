--- Проверки RESP: команда байтами, запретные команды, разбор каждого
--- вида ответа, предел байтов и беды протокола — без сети.

local datetime = require('datetime')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local resp = helper.resp
local storage = helper.storage

local g = t.group('tnt.redis.resp')

--- Разбирает ответы из строки с пределом по умолчанию — с запасом.
---@param text string
---@param count integer|nil Сколько ответов; по умолчанию один
---@param budget integer|nil Предел байтов
---@return any replies
---@return any trouble
local function read(text, count, budget)
    return resp.read(helper.receiver(text), count or 1, budget or 1024)
end

--- Значение единственного ответа без ошибки.
---@param text string
---@return any
local function value_of(text)
    local replies = read(text)

    t.assert_equals(replies[1].fault, nil, text)

    return replies[1].value
end

g.test_a_command_is_an_array_of_bulk_strings = function()
    t.assert_equals(resp.CRLF, '\r\n')
    t.assert_equals(resp.encode({ 'SET', 'k', 'v' }), '*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n')
    t.assert_equals(resp.encode({ 'SET', '', 'a\r\nb\0' }), '*3\r\n$3\r\nSET\r\n$0\r\n\r\n$5\r\na\r\nb\0\r\n')
    t.assert_equals(resp.encode({}), '*0\r\n')
end

g.test_arguments_go_by_the_redis_rule_of_storage = function()
    local moment = datetime.new({ year = 2026, month = 9, day = 13, hour = 12, min = 34, sec = 56, tzoffset = 180 })

    t.assert_equals(
        resp.command({ 'set', 'счёт', 1e15 }, 'команда'),
        '*3\r\n$3\r\nset\r\n$8\r\nсчёт\r\n$16\r\n1000000000000000\r\n'
    )
    t.assert_equals(
        resp.command({ 'SET', 'k', 0.1 + 0.2, 9007199254740993LL, moment }, 'команда'),
        resp.encode({ 'SET', 'k', '0.30000000000000004', '9007199254740993', '2026-09-13T12:34:56.000000+0300' })
    )
    t.assert_equals(
        resp.command({ 'SET', 'k', storage.json({ a = 1 }), storage.binary('\0\255') }, 'команда'),
        resp.encode({ 'SET', 'k', '{"a":1}', '\0\255' })
    )
    -- Подкоманда CLIENT числом — не REPLY и не TRACKING.
    t.assert_equals(resp.command({ 'CLIENT', 5 }, 'команда'), resp.encode({ 'CLIENT', '5' }))
    t.assert_equals(resp.command({ 'client', 'list' }, 'команда'), resp.encode({ 'client', 'list' }))
    t.assert_equals(resp.command({ 'CLIENT' }, 'команда'), resp.encode({ 'CLIENT' }))
    t.assert_equals(resp.command({ 'CLIENT', 5, 'REPLY' }, 'команда'), resp.encode({ 'CLIENT', '5', 'REPLY' }))
end

g.test_commands_that_change_the_connection_are_refused = function()
    local reasons = {
        transaction = 'транзакции у драйвера нет (features.transaction = false): атомарность даёт сценарий EVAL',
        subscription = 'подписка занимает соединение целиком, а драйвер отдаёт его следующему после каждой команды',
        state = 'состояние соединения задают настройки драйвера (username, password, db), а не команда',
        replication = 'поток репликации — не ответ на команду',
    }
    local refused = {
        MULTI = 'transaction',
        EXEC = 'transaction',
        DISCARD = 'transaction',
        WATCH = 'transaction',
        UNWATCH = 'transaction',
        SUBSCRIBE = 'subscription',
        PSUBSCRIBE = 'subscription',
        SSUBSCRIBE = 'subscription',
        UNSUBSCRIBE = 'subscription',
        PUNSUBSCRIBE = 'subscription',
        SUNSUBSCRIBE = 'subscription',
        MONITOR = 'subscription',
        AUTH = 'state',
        HELLO = 'state',
        SELECT = 'state',
        RESET = 'state',
        QUIT = 'state',
        READONLY = 'state',
        READWRITE = 'state',
        SYNC = 'replication',
        PSYNC = 'replication',
        REPLCONF = 'replication',
    }

    for name, reason in pairs(refused) do
        for _, spelled in ipairs({ name, name:lower() }) do
            local ok, err = pcall(resp.command, { spelled, 'x' }, 'команда')

            t.assert_not(ok, spelled)
            t.assert_str_contains(
                err,
                ('команду %s драйвер не отправит: %s'):format(name, reasons[reason]),
                false,
                spelled
            )
        end
    end

    local replies =
        'CLIENT REPLY и CLIENT TRACKING меняют, на что отвечает соединение, а его возьмёт следующий'

    for _, subcommand in ipairs({ 'REPLY', 'reply', 'TRACKING', 'tracking' }) do
        local ok, err = pcall(resp.command, { 'client', subcommand, 'on' }, 'команда')

        t.assert_not(ok, subcommand)
        t.assert_str_contains(
            err,
            'команду CLIENT драйвер не отправит: ' .. replies,
            false,
            subcommand
        )
    end

    -- Подкоманда без аргументов — та же.
    local ok, err = pcall(resp.command, { 'CLIENT', 'TRACKING' }, 'команда')

    t.assert_not(ok)
    t.assert_str_contains(err, 'команду CLIENT драйвер не отправит: ' .. replies)
end

g.test_a_wrong_command_is_raised_at_the_callers_line = function()
    local function driver_command(args)
        local payload = resp.command(args, 'команды[2]', 2)

        return payload
    end

    helper.assert_blamed({
        {
            function()
                resp.command(helper.wrong('GET k'), 'команда')
            end,
            'команда — массив, а не строка',
        },
        {
            function()
                resp.command({}, 'команда')
            end,
            'команда[1] — непустая строка, а не nil',
        },
        {
            function()
                resp.command({ '' }, 'команда')
            end,
            'команда[1] — непустая строка, а не пустая',
        },
        {
            function()
                resp.command({ 'GET', nil, 'k' }, 'команда')
            end,
            'команда — массив, а не таблица с дырой на месте 2',
        },
        {
            function()
                resp.command({ 'SET', 'k', true }, 'команда')
            end,
            'логику в Redis не передать: у него только строки — передайте строку явно',
        },
        {
            function()
                resp.command({ 'MULTI' }, 'команда')
            end,
            'команду MULTI драйвер не отправит: транзакции у драйвера нет (features.transaction = false): '
                .. 'атомарность даёт сценарий EVAL',
        },
        {
            -- `box.NULL` в списке — та же дыра: `box.NULL == nil`.
            function()
                driver_command({ 'SET', 'k', box.NULL })
            end,
            'команды[2] — массив, а не таблица с дырой на месте 3',
        },
        {
            function()
                driver_command({ 7 })
            end,
            'команды[2][1] — непустая строка, а не число',
        },
        {
            function()
                driver_command({ 'SELECT', 1 })
            end,
            'команду SELECT драйвер не отправит: '
                .. 'состояние соединения задают настройки драйвера (username, password, db), а не команда',
        },
        {
            function()
                driver_command({ 'SET', 'k', { 1 } })
            end,
            'значение table нельзя передать параметром: таблицу оберните json, байты — binary',
        },
    })
end

g.test_scalar_replies_are_read_as_lua_values = function()
    t.assert_equals(value_of(helper.status('OK')), 'OK')
    t.assert_equals(value_of('+\r\n'), '')
    t.assert_equals(value_of(helper.bulk('Анна')), 'Анна')
    t.assert_equals(value_of(helper.bulk('')), '')
    -- Строка байтов берётся по длине: CRLF и нулевой байт внутри — её часть.
    t.assert_equals(value_of(helper.bulk('a\r\nb\0c')), 'a\r\nb\0c')
    t.assert_equals(value_of(helper.integer(0)), 0)
    t.assert_equals(value_of(helper.integer(42)), 42)
    t.assert_equals(value_of(':-7\r\n'), -7)
    t.assert(rawequal(value_of(helper.NULL), box.NULL))
    t.assert(rawequal(value_of('*-1\r\n'), box.NULL))
end

g.test_an_integer_stays_a_lua_number_while_it_is_exact = function()
    local exact = value_of(':9007199254740992\r\n')

    t.assert_equals({ type(exact), exact }, { 'number', 2 ^ 53 })

    local negative = value_of(':-9007199254740992\r\n')

    t.assert_equals({ type(negative), negative }, { 'number', -(2 ^ 53) })

    -- Метки времени в микросекундах и прочие целые от 1e14 — числом:
    -- сравнение uint64_t с -2^53 на x86 давало ложь, и они оставались cdata.
    local large = value_of(':100000000000000\r\n')

    t.assert_equals({ type(large), large }, { 'number', 1e14 })

    local large_negative = value_of(':-100000000000000\r\n')

    t.assert_equals({ type(large_negative), large_negative }, { 'number', -1e14 })

    local widest = value_of(':18446744073709551615\r\n')

    t.assert_equals({ type(widest), tostring(widest) }, { 'cdata', '18446744073709551615ULL' })

    local beyond = value_of(':9007199254740993\r\n')

    t.assert_equals({ type(beyond), tostring(beyond) }, { 'cdata', '9007199254740993ULL' })

    local below = value_of(':-9223372036854775808\r\n')

    t.assert_equals({ type(below), tostring(below) }, { 'cdata', '-9223372036854775808LL' })
end

g.test_arrays_keep_their_shape_and_positions = function()
    t.assert_equals(value_of('*0\r\n'), {})
    t.assert_equals(value_of(helper.array(helper.bulk('v'), helper.NULL, helper.integer(3))), { 'v', box.NULL, 3 })
    t.assert_equals(
        value_of(
            helper.array(
                helper.integer(1),
                helper.array(helper.integer(2), helper.array(helper.integer(3)), '*0\r\n'),
                helper.status('x'),
                '*-1\r\n'
            )
        ),
        { 1, { 2, { 3 }, {} }, 'x', box.NULL }
    )
    -- Ответ SCAN: курсор и массив ключей.
    t.assert_equals(
        value_of(helper.array(helper.bulk('0'), helper.array(helper.bulk('a'), helper.bulk('b')))),
        { '0', { 'a', 'b' } }
    )
end

g.test_a_deep_reply_is_read_without_recursion = function()
    local depth = 100000
    local replies = read(('*1\r\n'):rep(depth) .. helper.integer(7), 1, depth * 4 + 4)
    local node = replies[1].value

    for _ = 1, depth do
        t.assert_equals(type(node), 'table')
        node = node[1]
    end

    t.assert_equals(node, 7)
end

g.test_an_error_reply_is_a_fault_with_its_code = function()
    local replies = read(helper.error('WRONGTYPE Operation against a key holding the wrong kind of value'))

    t.assert(rawequal(replies[1].value, box.NULL))
    t.assert_equals(replies[1].fault, {
        text = 'WRONGTYPE Operation against a key holding the wrong kind of value',
        code = 'WRONGTYPE',
    })
    -- Общее ERR кодом не считается; одно слово без текста — код.
    t.assert_equals(read(helper.error('ERR unknown command'))[1].fault, { text = 'ERR unknown command' })
    t.assert_equals(read(helper.error('LOADING'))[1].fault, { text = 'LOADING', code = 'LOADING' })
    t.assert_equals(read(helper.error('ERR'))[1].fault, { text = 'ERR' })
    t.assert_equals(read(helper.error('noprefix here'))[1].fault, { text = 'noprefix here' })
    t.assert_equals(read(helper.error('Wrong case'))[1].fault, { text = 'Wrong case' })
    -- Без слова в начале кода нет, и пустой код не заводится.
    t.assert_equals(read(helper.error(' LOADING'))[1].fault, { text = ' LOADING' })
    t.assert_equals(read(helper.error(''))[1].fault, { text = '' })
end

g.test_an_error_inside_an_array_is_the_first_fault_and_the_rest_is_read = function()
    local text = helper.array(
        helper.integer(1),
        helper.error('MY custom'),
        helper.error('ERR second'),
        helper.bulk('x')
    ) .. helper.status('next')
    local replies = read(text, 2)

    t.assert_equals(replies[1].fault, { text = 'MY custom', code = 'MY' })
    t.assert_equals(replies[1].value, { 1, box.NULL, box.NULL, 'x' })
    -- Ответ дочитан до конца: следующий ответ — свой, и без чужой ошибки.
    t.assert_equals(replies[2], { value = 'next' })
end

g.test_replies_are_read_one_per_command = function()
    local replies = read(helper.integer(1) .. helper.error('ERR x') .. helper.NULL, 3)

    t.assert_equals(#replies, 3)
    t.assert_equals({ replies[1].value, replies[1].fault }, { 1, nil })
    t.assert_equals(replies[2].fault, { text = 'ERR x' })
    t.assert(rawequal(replies[3].value, box.NULL))
    t.assert_equals(replies[3].fault, nil)
end

g.test_reading_asks_the_link_for_a_line_and_then_for_the_bytes = function()
    local receive, asked = helper.receiver(helper.bulk('abc') .. helper.status('OK'))

    resp.read(receive, 2, 100)

    t.assert_equals(asked, {
        { chunk = 100, delimiter = '\r\n' },
        { chunk = 5 },
        { chunk = 91, delimiter = '\r\n' },
    })
end

g.test_a_reply_that_fits_the_budget_exactly_is_read = function()
    -- «$3\r\n» — четыре байта, «abc\r\n» — ещё пять.
    t.assert_equals(read(helper.bulk('abc'), 1, 9)[1].value, 'abc')
    t.assert_equals(read(helper.status('OK'), 1, 5)[1].value, 'OK')
    t.assert_equals(read(helper.status('OK') .. helper.status('A'), 2, 9)[2].value, 'A')
end

g.test_a_reply_longer_than_the_budget_is_an_overflow = function()
    t.assert_equals({ read(helper.bulk('abc'), 1, 8) }, {
        nil,
        {
            kind = 'overflow',
            message = 'ответ длиннее предела max_bytes: строка в 3 байт, а осталось 4',
        },
    })
    t.assert_equals({ read(helper.status('OK'), 1, 4) }, {
        nil,
        {
            kind = 'overflow',
            message = 'ответ длиннее предела max_bytes: строка не уложилась в 4 байт',
        },
    })
    -- Предел общий на все ответы подряд.
    t.assert_equals({ read(helper.status('OK') .. helper.status('A'), 2, 8) }, {
        nil,
        {
            kind = 'overflow',
            message = 'ответ длиннее предела max_bytes: строка не уложилась в 3 байт',
        },
    })
    t.assert_equals({ read(helper.status('OK') .. helper.status('A'), 2, 5) }, {
        nil,
        {
            kind = 'overflow',
            message = 'ответ длиннее предела max_bytes: строка не уложилась в 0 байт',
        },
    })
    -- Длина, обещанная сервером, сверяется до чтения.
    t.assert_equals({ read('$536870912\r\n', 1, 1024) }, {
        nil,
        {
            kind = 'overflow',
            message = 'ответ длиннее предела max_bytes: строка в 536870912 байт, а осталось 1012',
        },
    })
end

g.test_a_reply_not_in_resp2_is_broken = function()
    local cases = {
        { '%1\r\n', 'тип ответа «%» незнаком' },
        { '_\r\n', 'тип ответа «_» незнаком' },
        { '\r\n', 'тип ответа «» незнаком' },
        { ':abc\r\n', 'целое «abc»' },
        { ':\r\n', 'целое «»' },
        { ':1.5\r\n', 'целое «1.5»' },
        { ':-\r\n', 'целое «-»' },
        { ':0x10\r\n', 'целое «0x10»' },
        { ': 12\r\n', 'целое « 12»' },
        { ':+12\r\n', 'целое «+12»' },
        { ':12LL\r\n', 'целое «12LL»' },
        { ':99999999999999999999\r\n', 'целое «99999999999999999999» не умещается в 64 бита' },
        { ':-9223372036854775809\r\n', 'целое «-9223372036854775809» не умещается в 64 бита' },
        { '$x\r\n', 'длина «x»' },
        { '$\r\n', 'длина «»' },
        { '*-\r\n', 'длина «-»' },
        { '$0x10\r\n', 'длина «0x10»' },
        { '$-2\r\n', 'длина «-2»' },
        { '*-3\r\n', 'длина «-3»' },
        { '* 1\r\n', 'длина « 1»' },
        { '$3\r\nabcde', 'строка байтов длиной 3 не кончается CRLF' },
        { '$3\r\nabc\n\r', 'строка байтов длиной 3 не кончается CRLF' },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(
            { read(case[1]) },
            { nil, { kind = 'broken', message = 'ответ не по протоколу RESP2: ' .. case[2] } },
            case[1]
        )
    end
end

g.test_a_reply_cut_short_is_broken = function()
    local cut = {
        nil,
        { kind = 'broken', message = 'сервер закрыл соединение посреди ответа' },
    }

    t.assert_equals({ read('') }, cut)
    t.assert_equals({ read('+OK') }, cut)
    t.assert_equals({ read('+OK\r') }, cut)
    t.assert_equals({ read('$3\r\nab') }, cut)
    t.assert_equals({ read('$3\r\nabc\r') }, cut)
    t.assert_equals({ read(helper.array(helper.integer(1))) }, { { { value = { 1 } } }, nil })
    t.assert_equals({ read('*2\r\n' .. helper.integer(1)) }, cut)
end

g.test_a_trouble_of_the_link_goes_up_as_it_is = function()
    local trouble = { kind = 'timeout', message = 'ответа нет за срок вызова' }

    t.assert_equals({ resp.read(helper.receiver('', trouble), 1, 100) }, { nil, trouble })
    t.assert_equals({ resp.read(helper.receiver('$3\r\n', trouble), 1, 100) }, { nil, trouble })
    t.assert_equals({ resp.read(helper.receiver('*2\r\n:1\r\n', trouble), 1, 100) }, { nil, trouble })
end

--- Проверки настроек: умолчания, вход одним обменом, отказ на строке того,
--- кто завёл драйвер.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local resp = helper.resp
local settings_of = helper.settings

local g = t.group('tnt.redis.settings')

--- Настройки так, как их проверяет `redis.new`: через кадр фасада.
---
--- `check` винит третий кадр от себя, и зовёт его здесь замыкание,
--- как зовёт `redis.new` — не хвостовым вызовом.
---@param opts any
---@return TntRedisSettings
local function check(opts)
    local settings = settings_of.check(opts)

    return settings
end

g.test_the_defaults = function()
    t.assert_equals(settings_of.DEFAULT_HOST, '127.0.0.1')
    t.assert_equals(settings_of.DEFAULT_PORT, 6379)
    t.assert_equals(settings_of.DEFAULT_MAX_BYTES, 16777216)
    t.assert_equals(settings_of.DEFAULT_NAME, 'redis')

    t.assert_equals(check(nil), {
        name = 'redis',
        host = '127.0.0.1',
        port = 6379,
        where = '127.0.0.1:6379',
        greeting = resp.encode({ 'PING' }),
        greeting_count = 1,
        max_bytes = 16777216,
        limits = { timeout = 5, max_timeout = 60 },
        pool = {},
        retry = {},
    })
end

g.test_the_given_settings_are_kept = function()
    local pool = { size = 2, wait_timeout = 1 }
    local retry = { attempts = 5, jitter = 'decorrelated' }
    local settings = check({
        host = 'cache.local',
        port = 6380,
        db = 3,
        timeout = 2,
        max_timeout = 10,
        max_bytes = 1024,
        pool = pool,
        retry = retry,
        name = 'sessions',
    })

    t.assert_equals(settings.name, 'sessions')
    t.assert_equals(settings.where, 'cache.local:6380')
    t.assert_equals({ settings.host, settings.port }, { 'cache.local', 6380 })
    t.assert_equals(settings.max_bytes, 1024)
    t.assert_equals(settings.limits, { timeout = 2, max_timeout = 10 })
    t.assert(rawequal(settings.pool, pool))
    t.assert(rawequal(settings.retry, retry))
    t.assert_equals(settings.tls, nil)
end

g.test_the_greeting_is_one_exchange_with_ping_only_alone = function()
    -- PING — только когда входу больше нечего сказать: учётку без
    -- категории @connection он не пустил бы.
    local cases = {
        { {}, { { 'PING' } } },
        { { db = 0 }, { { 'PING' } } },
        { { db = 1 }, { { 'SELECT', '1' } } },
        { { password = 'pa ss"word' }, { { 'AUTH', 'pa ss"word' } } },
        { { password = '' }, { { 'AUTH', '' } } },
        {
            { username = 'app', password = 'app-secret', db = 15 },
            { { 'AUTH', 'app', 'app-secret' }, { 'SELECT', '15' } },
        },
    }

    for _, case in ipairs(cases) do
        local settings = check(case[1])
        local parts = {}

        for index, command in ipairs(case[2]) do
            parts[index] = resp.encode(command)
        end

        t.assert_equals(settings.greeting, table.concat(parts), case[2][1][1])
        t.assert_equals(settings.greeting_count, #case[2], case[2][1][1])
    end
end

g.test_tls_is_true_or_the_settings_of_tnt_tls = function()
    t.assert_equals(check({ tls = true }).tls, {})
    t.assert_equals(check({ tls = false }).tls, nil)

    local tls = {
        verify = false,
        ca_file = '/etc/ca.pem',
        ca_path = '/etc/ca',
        sni = 'cache',
        cert_file = '/etc/client.pem',
        key_file = '/etc/client.key',
    }

    t.assert(rawequal(check({ tls = tls }).tls, tls))
    -- Ключ в файле сертификата: одного cert_file довольно.
    t.assert_equals(check({ tls = { cert_file = '/etc/client.pem' } }).tls, { cert_file = '/etc/client.pem' })
end

g.test_wrong_settings_are_raised_at_the_line_of_new = function()
    helper.assert_blamed({
        {
            function()
                check(helper.wrong('redis://cache'))
            end,
            'настройки redis — таблица, а не строка',
        },
        {
            function()
                check({ pasword = 'x' })
            end,
            'настройки redis: ключа «pasword» нет, есть db, host, max_bytes, max_timeout, name, password, '
                .. 'pool, port, retry, timeout, tls, username',
        },
        {
            function()
                check({ port = 0 })
            end,
            'настройки redis.port — число от 1 до 65535, а не 0',
        },
        {
            function()
                check({ port = 65536 })
            end,
            'настройки redis.port — число от 1 до 65535, а не 65536',
        },
        {
            function()
                check({ port = '6379' })
            end,
            'настройки redis.port — целое число, а не строка',
        },
        {
            function()
                check({ db = -1 })
            end,
            'настройки redis.db — число не меньше 0, а не -1',
        },
        {
            function()
                check({ max_bytes = 0 })
            end,
            'настройки redis.max_bytes — число больше 0, а не 0',
        },
        {
            function()
                check({ host = '' })
            end,
            'настройки redis.host — непустая строка, а не пустая',
        },
        {
            function()
                check({ username = 'app' })
            end,
            'настройки redis.username без password: вход по учётной записи ACL требует пароля',
        },
        {
            function()
                check({ tls = 'yes' })
            end,
            'настройки redis.tls — логическое значение или таблица, а не «yes»',
        },
        {
            function()
                check({ tls = { verfy = false } })
            end,
            'настройки redis.tls: ключа «verfy» нет, есть ca_file, ca_path, cert_file, key_file, sni, verify',
        },
        {
            function()
                check({ tls = { key_file = '/etc/client.key' } })
            end,
            'настройки redis.tls.key_file без cert_file: ключ предъявляется только вместе с сертификатом',
        },
        {
            function()
                check({ tls = { cert_file = '' } })
            end,
            'настройки redis.tls.cert_file — непустая строка, а не пустая',
        },
        {
            function()
                check({ pool = { max_size = 2 } })
            end,
            'настройки redis.pool: ключа «max_size» нет, есть idle_timeout, leak_timeout, max_lifetime, '
                .. 'open_cooldown, size, sweep_interval, wait_timeout',
        },
        {
            function()
                check({ retry = { deadline = 1 } })
            end,
            'настройки redis.retry: ключа «deadline» нет, есть attempts, base, factor, jitter, max',
        },
        {
            function()
                check({ timeout = 0 })
            end,
            'timeout — число секунд больше нуля и меньше бесконечности, а не 0',
        },
        {
            function()
                check({ timeout = 90 })
            end,
            'timeout 90 с длиннее потолка max_timeout 60 с',
        },
    })
end

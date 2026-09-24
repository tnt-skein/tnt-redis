rockspec_format = '3.0'

package = 'tnt-redis'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-redis.git',
    branch = 'main',
}

description = {
    summary = 'Клиент Redis для Tarantool: RESP2 на неблокирующем сокете, пул, срок, повторы, отказ парой',
    detailed = [[
        Готового клиента Redis у Tarantool нет ни в ядре, ни среди
        официальных роков. Пакет говорит протоколом сам — RESP2 поверх
        встроенного неблокирующего сокета, на файберах, — и понимает его
        всякий Redis и совместимый с ним сервер.

        client:command шлёт команду — список { имя, аргумент, … } —
        и отдаёт ответ значением Lua; client:pipeline шлёт несколько
        команд одной записью и отдаёт ответы по порядку. Аргумент уходит
        строкой байтов: число — точной записью без степени, int64 —
        цифрами, decimal, uuid и время — текстом. Промах — nil без
        отказа, пустое внутри массива — box.NULL. Предел байтов ответа
        бережёт память узла, а разбор не падает на глубокой вложенности.

        Соединения живут в пуле с проверкой живости без сети, срок один
        на вызов, отказ — пара nil, err с родом по коду ошибки Redis,
        признаком отправки и приговором повтору. Повторяет вызов tnt-retry,
        после отправки — только с согласия вызывающего. Транзакций нет:
        MULTI и WATCH — исключение, атомарность даёт сценарий EVAL.
        Команды, после которых соединение в пуле досталось бы следующему
        чужим (SELECT, AUTH, SUBSCRIBE), драйвер не отправляет.

        Зависит от tnt-must (проверки аргументов), tnt-log (журнал),
        tnt-pool (соединения), tnt-retry (повторы), tnt-external (подмена
        сети и шифрования в проверках), tnt-storage (срок, отказ с родом
        и запись значения строкой) и tnt-tls (шифрование). Покрытие строк
        и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-redis',
    issues_url = 'https://github.com/tnt-skein/tnt-redis/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'redis', 'resp', 'database', 'driver', 'cache' },
}

dependencies = {
    'lua >= 5.1',
    -- Проверки настроек, команды и аргументов на строке вызывающего.
    'tnt-must',
    -- Запись о выброшенном соединении.
    'tnt-log',
    -- Соединения с проверкой живости без сети.
    'tnt-pool',
    -- Повторы вызова по полю retriable отказа.
    'tnt-retry',
    -- Подмена сети и шифрования в проверках.
    'tnt-external',
    -- Срок вызова, отказ с родом по коду Redis и запись значения строкой.
    'tnt-storage',
    -- Шифрование соединения с сервером.
    'tnt-tls',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.redis'] = 'tnt/redis.lua',
        ['tnt.redis.link'] = 'tnt/redis/link.lua',
        ['tnt.redis.resp'] = 'tnt/redis/resp.lua',
        ['tnt.redis.settings'] = 'tnt/redis/settings.lua',
    },
}

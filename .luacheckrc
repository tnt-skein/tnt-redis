-- Конфигурация luacheck.

-- Базовый стандарт — LuaJIT: Tarantool исполняет код именно на нём.
std = 'luajit'

-- Глобалы, которые Tarantool добавляет к стандартной библиотеке.
read_globals = {
    'box',
    '_TARANTOOL',
    'tonumber64',
    'utf8',
    -- Tarantool дописывает в стандартные таблицы свои функции: их нет
    -- в обычном Lua, и без объявления luacheck считает их опечатками.
    table = { fields = { 'deepcopy', 'copy', 'clear', 'new', 'equals' } },
    string = { fields = { 'hex', 'fromhex' } },
}

-- Поля 120 символов — та же планка, что в .editorconfig и stylua.toml.
max_line_length = 120

exclude_files = {
    '.rocks/**',
    'var/**',
    -- Временные файлы мутационного прогона.
    '.tmp_mutant.*',
    '**/*.um.backup.*',
}

files['test/*_test.lua'] = {
    -- luatest наполняет группу тестов присваиванием полей.
    std = '+busted',
}

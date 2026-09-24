--- Ловушка журнала: записи `tnt-log` на время проверки.
---
--- Проверять журнал приходится там, где о происходящем больше сказать
--- нечем: отказ, который никого не сорвал, виден только записью. Ловушка
--- ставится через внешнюю зависимость журнала, вместо журнала ядра: в процессе проверок
--- его уже настроил luatest, и настоящую запись здесь не прочитать.
--- Настоящий журнал ядра проверяется дочерним процессом (`tnt.testing.child`).
---
--- Каждая запись хранится и как есть (`record` — то, что ушло бы ядру),
--- и строкой `УРОВЕНЬ [модуль] тело`: по строке ищут подстроку, а тело —
--- тот же plain, что увидит человек, так что проверка «в записи есть
--- `attempt=3`» читается одинаково и в проверке, и в журнале.
---
--- Внешние зависимости у каждого экземпляра журнала свой, а экземпляров в процессе
--- проверок много: установленная копия, которую держат соседи, и исходники,
--- которые проверки грузят и выгружают. Ловушка на одном из них пропускала
--- бы записи остальных, и проверка «записи нет» проходила бы ложно.
--- Поэтому она ставится на все экземпляры, что видел загрузчик исходников,
--- и на каждый, что он соберёт, пока ловушка стоит.

local sources = require('tnt.testing.sources')

local Module = {}

--- Уровни журнала, которые ловушка перехватывает.
Module.LEVELS = { 'debug', 'info', 'warn', 'error' }

---@class TntTestingJournalRecord
---@field module string Имя журнала, которым писали
---@field level string debug, info, warn или error
---@field record table Запись, как она ушла бы ядру
---@field line string `УРОВЕНЬ [модуль] тело`

---@class TntTestingJournal
---@field logged fun(fragment: string): boolean Была ли запись с такой подстрокой
---@field find fun(fragment: string): TntTestingJournalRecord|nil Первая запись с такой подстрокой
---@field find_all fun(fragment: string): TntTestingJournalRecord[] Все записи с такой подстрокой, по порядку
---@field records fun(): TntTestingJournalRecord[] Накопленные записи
---@field forget fun() Забыть накопленное и поставить ловушку заново
---@field release fun() Вернуть ядро всем экземплярам журнала и не взводить новые

--- Имя журнала в `package.loaded`.
local JOURNAL = 'tnt.log'

--- Ставит средства каждому известному экземпляру журнала.
---
--- Под именем журнала проверка вправе на миг положить заглушку, и загрузчик
--- мог её видеть; внешних зависимостей у заглушки нет, и ловить ей нечего.
---@param make fun(log: table): table|nil Средства для экземпляра; nil — журнал ядра
---@return fun(log: any) put Та же установка одному экземпляру
local function install(make)
    local function put(log)
        if type(log) == 'table' and type(log._set_source) == 'function' then
            log._set_source(make(log))
        end
    end

    -- Журнал, которого ещё никто не брал, берётся так же, как его возьмёт
    -- код под проверкой: установленной копией. Имя — строкой, а не
    -- `JOURNAL`: проверка рокспеков узнаёт зависимость пакета по `require`
    -- со строкой.
    require('tnt.log')

    for _, log in ipairs(sources.instances(JOURNAL)) do
        put(log)
    end

    return put
end

--- Журнал ядра вместо ловушки.
---@return nil
local function core()
    return nil
end

--- Ставит ловушку журналу и отдаёт способы её читать.
---
--- Ловушка встаёт на все известные экземпляры журнала и на каждый, что
--- загрузчик исходников соберёт позже. Следит за новыми та, что взведена
--- последней: `forget` взводит её заново — и на экземпляры, загруженные
--- после прошлой установки.
---@return TntTestingJournal
function Module.capture()
    local records = {}

    --- Средства ловушки для одного экземпляра: строку записи собирает
    --- тот же экземпляр, которым писали.
    ---@param log table
    ---@return table
    local function trap(log)
        return {
            logger = function(name)
                local methods = {}

                for _, method in ipairs(Module.LEVELS) do
                    methods[method] = function(record)
                        table.insert(records, {
                            module = name,
                            level = method,
                            record = record,
                            line = ('%s [%s] %s'):format(method:upper(), name, log.render(record)),
                        })
                    end
                end

                return methods
            end,

            -- Уровень отладки: проверка ловит и отладочные записи, а вид
            -- json — чтобы запись приходила таблицей, а не готовой строкой.
            settings = function()
                return { level = 'debug', format = 'json' }
            end,
        }
    end

    local function arm()
        sources.follow(JOURNAL, install(trap))
    end

    arm()

    -- Все, а не первая: записи одного такта сверяют между собой — общий
    -- ли у них опознаватель, — а первая запись такой сверки не даёт.
    local function find_all(fragment)
        local found = {}

        for _, entry in ipairs(records) do
            -- Подстрока, а не образец: в записи бывают скобки и точки.
            if entry.line:find(fragment, nil, true) ~= nil then
                table.insert(found, entry)
            end
        end

        return found
    end

    local function find(fragment)
        return find_all(fragment)[1]
    end

    return {
        find = find,
        find_all = find_all,

        logged = function(fragment)
            return find(fragment) ~= nil
        end,

        records = function()
            return records
        end,

        forget = function()
            records = {}
            arm()
        end,

        -- Всем экземплярам, а не нынешнему: взведённый и забытый иначе
        -- так и глотал бы записи соседей.
        release = function()
            sources.follow(JOURNAL, nil)
            install(core)
        end,
    }
end

return Module

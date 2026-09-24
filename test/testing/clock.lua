--- Часы двойником и работа без уступки.
---
--- Настоящие часы сделали бы проверку минутного ожидания минутной,
--- а проверку часовой куки — часовой. Двойник показывает то, что в него
--- положили, и двигается только от паузы, от прямого перевода и от чтения
--- с шагом — так срок в проверке истекает мгновенно, но ровно там, где
--- истёк бы на самом деле.
---
--- Часы двойника ходят той же парой, что настоящие (`tnt-clock`):
--- `monotonic` — настоящие монотонные, `scheduler_now` — отметка цикла
--- событий. Отставание отметки задаёт `lag`: так она отстаёт после работы
--- без уступки. Пауза — это уступка, и на обороте цикла отметка догоняет
--- часы: `sleep` сбрасывает `lag`. Стенные часы `realtime` идут вровень
--- с монотонными, но от своей точки отсчёта.
---
--- Отсчёт начинается не с нуля нарочно: у настоящих монотонных часов
--- нулевой точки не бывает, а при нуле «сейчас минус начало» и «сейчас
--- плюс начало» дают одно и то же — и ошибка в знаке осталась бы
--- незамеченной.

local core = require('clock')

local Module = {}

--- С какого мига идут монотонные часы, если не сказано иного.
Module.DEFAULT_AT = 1000

--- Который час по стенным часам, если не сказано иного: 2023-11-14T22:13:20Z.
Module.DEFAULT_WALL = 1700000000

--- Сколько ожиданий подряд двойник считает признаком зацикливания.
---
--- Самому долгому ожиданию хватает десятка: код просыпается раз на паузу,
--- а пауза обычно удваивается. Сломанное условие выхода крутило бы
--- ожидание вхолостую, а подменённые часы не дали бы проверке упереться
--- хотя бы в настоящее время — она висела бы до конца гейта.
Module.MAX_WAITS = 100

---@class TntTestingClockOptions
---@field at number|nil Монотонные часы в начале; по умолчанию 1000
---@field wall number|nil Стенные часы в начале; по умолчанию 1700000000
---@field lag number|nil Отставание отметки планировщика; по умолчанию 0
---@field step number|nil На сколько часы уходят вперёд от каждого чтения; по умолчанию 0
---@field overshoot number|nil На сколько ожидание просыпает срок; по умолчанию 0

---@class TntTestingClock
---@field at number Монотонные часы сейчас
---@field wall number Стенные часы сейчас
---@field lag number Отставание отметки планировщика от часов
---@field step number Шаг от каждого чтения
---@field overshoot number На сколько ожидание просыпает срок
---@field slept number[] Паузы по порядку
---@field monotonic fun(): number Настоящие монотонные часы
---@field scheduler_now fun(): number Отметка цикла событий
---@field realtime fun(): number Стенные часы
---@field sleep fun(seconds: number) Пауза: записывается и двигает часы
---@field advance fun(seconds: number) Перевести часы вперёд
---@field cond fun(): table Условная переменная, чьё ожидание двигает часы

--- Часы, которые двигает только проверка.
---@param opts TntTestingClockOptions|nil
---@return TntTestingClock
function Module.new(opts)
    local given = opts or {}

    ---@type any
    local clock = {
        at = given.at or Module.DEFAULT_AT,
        wall = given.wall or Module.DEFAULT_WALL,
        lag = given.lag or 0,
        step = given.step or 0,
        overshoot = given.overshoot or 0,
        slept = {},
    }

    -- Сколько ожиданий было у всех условных переменных этих часов.
    local waits = 0

    clock.advance = function(seconds)
        clock.at = clock.at + seconds
        clock.wall = clock.wall + seconds
    end

    --- Чтение с шагом: часы уходят вперёд после того, как показали время.
    ---@param shown number
    ---@return number
    local function read(shown)
        clock.advance(clock.step)

        return shown
    end

    clock.monotonic = function()
        return read(clock.at)
    end

    clock.realtime = function()
        return read(clock.wall)
    end

    -- Отметка цикла от чтения не двигается — как настоящая: она обновляется
    -- на обороте цикла, а не при каждом вызове.
    clock.scheduler_now = function()
        return clock.at - clock.lag
    end

    -- Пауза — уступка: сколько попросили поспать, на столько часы и ушли,
    -- а отметка цикла догнала их.
    clock.sleep = function(seconds)
        table.insert(clock.slept, seconds)
        clock.advance(seconds)
        clock.lag = 0
    end

    -- Ожидание без настоящего времени: условная переменная, не получившая
    -- побудки, сама двигает часы на весь запрошенный срок. Для кода это
    -- неотличимо от сна, а проверка мгновенна и точна до доли секунды.
    clock.cond = function()
        local signalled = false

        local function wake()
            signalled = true
        end

        return {
            wait = function(_, seconds)
                waits = waits + 1

                if waits > Module.MAX_WAITS then
                    error('проверка зациклилась: ожидание не кончается')
                end

                if signalled then
                    signalled = false

                    return true
                end

                -- Планировщик будит не ровно в срок, а чуть позже: разница
                -- мала, но ожидание, кончающееся точным попаданием, на ней
                -- и ломается.
                clock.advance((seconds or 0) + clock.overshoot)

                return false
            end,

            signal = wake,
            broadcast = wake,
        }
    end

    return clock
end

--- Занимает файбер работой, не уступая управления.
---
--- Разница между настоящими часами и отметкой цикла событий видна только
--- на такой работе, и проверкам часов она нужна по всему дереву.
--- Длительность меряется настоящими часами ядра, а не подменяемыми: работа,
--- которую отметка цикла считает нулевой, иначе не кончилась бы никогда.
--- Часы приходят аргументом только ради проверки самой оснастки: границу
--- «ровно столько» на настоящих часах не поймать.
---@param seconds number
---@param monotonic (fun(): number)|nil Настоящие часы; по умолчанию — ядра
function Module.work_without_yielding(seconds, monotonic)
    local read = monotonic or core.monotonic
    local started = read()

    -- Тело пустое: работа — это само чтение часов, и ничего другого
    -- файберу делать не нужно.
    repeat
    until read() - started >= seconds
end

return Module

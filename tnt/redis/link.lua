--- Связь с Redis: открыть, обменяться командой, проверить, закрыть.
---
--- Здесь всё, что ходит в сеть. Пул (`tnt-pool`) зовёт `open`, `alive`
--- и `close`, фасад — `exchange`. Срок у каждого ожидания свой остаток
--- одного мига: `open` получает от пула остаток срока `take` и отмечает
--- по нему свой миг, `exchange` — миг вызова. Встроенный сокет срок
--- принимает сам, поэтому работник в отдельном файбере здесь не нужен:
--- ожидание ответа, не дождавшееся срока, возвращает управление,
--- и соединение выбрасывается — в нём остался недочитанный ответ.
---
--- Вход — одним обменом, без лишних кругов: `AUTH`, если задан пароль,
--- `SELECT`, если база не нулевая, а без них — `PING` (`tnt.redis.settings`).
--- Ответ на вход нужен всегда: сервер, у которого кончились места
--- («max number of clients reached») или включён защищённый режим,
--- отказывает на первую команду, и лучше услышать это при входе, чем
--- на команде вызывающего.
---
--- Живость без сети. Свободному соединению сервер не шлёт ничего, и если
--- читать есть что — конец потока после перезапуска сервера либо байты,
--- пришедшие после ответа, — соединение негодно. У открытого сокета это
--- `sysread` одного байта: не обращение к серверу и не уступка, а ответ
--- ядра на неблокирующий `recv`. Байты, пришедшие одним куском с ответом,
--- уже лежат в буфере сокета, и `sysread` их не видит; сервер RESP2 их
--- не шлёт. Под TLS сокет читать нельзя — в нём бывают служебные записи
--- протокола, и прочитанную запись в поток не вернуть, — поэтому живость
--- там спрашивается у `tnt-tls`: он смотрит в накопленное, в OpenSSL
--- и в сокет, не вынимая из него ни байта (`link:idle`).

local errno = require('errno')

local failure = require('tnt.storage.failure')
local resp = require('tnt.redis.resp')
local external = require('tnt.external')
local within = require('tnt.storage.within')

local Module = {}

--- Внешние средства: сеть и шифрование.
local source = external.install(Module, {
    connect = function(host, port, timeout)
        local socket = require('socket').tcp_connect(host, port, timeout)

        if socket == nil then
            return nil, errno.strerror()
        end

        return socket
    end,

    secure = function(socket, opts)
        return require('tnt.tls').wrap(socket, opts)
    end,
})

--- Ответ ядра «читать пока нечего»: соединение свободно и цело.
---
--- `EWOULDBLOCK` отдельно не сверяется: на Linux и macOS это то же число,
--- что и `EAGAIN` (11 и 35).
local AGAIN = errno.EAGAIN

--- Слово `tnt-tls` об отказе рукопожатия: сертификат сервера не принят.
---
--- Строкой договора, а не полем пакета: `tnt-tls` грузится, только когда
--- просят шифрования, и ради одного слова загружать его незачем.
local UNTRUSTED = 'untrusted'

---@class TntRedisIo
---@field read fun(self: TntRedisIo, opts: table, timeout: number): string|nil, string|nil
---@field write fun(self: TntRedisIo, data: string, timeout: number): boolean, string|nil
---@field close fun(self: TntRedisIo)
---@field idle fun(self: TntRedisIo): boolean Свободно ли: ничего не пришло и конца потока нет

---@class TntRedisLink
---@field io TntRedisIo Сокет либо соединение TLS с одним видом чтения и записи
---@field socket any Сам сокет
---@field secured boolean Идёт ли разговор под TLS

--- Сокет с тем же видом чтения и записи, что у соединения `tnt-tls`:
--- отказ — пара с текстом, а не `nil` и `errno` в сокете.
---@param socket any
---@return TntRedisIo
local function plain(socket)
    return {
        idle = function()
            -- Размер не задан: сколько прочесть, неважно — важно, есть ли что.
            -- Под pcall: сокет, закрытый соседом, бросает, и это «не живо».
            local ok, piece = pcall(socket.sysread, socket)

            return ok and piece == nil and socket:errno() == AGAIN
        end,

        read = function(_, opts, timeout)
            local piece = socket:read(opts, timeout)

            if piece == nil then
                return nil, socket:error()
            end

            return piece
        end,

        write = function(_, data, timeout)
            if socket:write(data, timeout) == nil then
                return false, socket:error()
            end

            return true
        end,

        close = function()
            socket:close()
        end,
    }
end

--- Беда связи: род, текст и то, что о ней надо знать повторам.
---@param kind string timeout либо broken
---@param message string
---@param sent boolean|nil Могла ли команда дойти до сервера; пусто — по роду
---@param retriable boolean|nil Приговор повтору, если его выносит связь
---@return table
local function trouble(kind, message, sent, retriable)
    return { kind = kind, message = message, sent = sent, retriable = retriable }
end

--- Род беды посреди обмена: срок вышел либо связь оборвалась.
---
--- Сокет и TLS называют истёкший срок каждый по-своему, а отказ сети —
--- словами ядра. Надёжнее спросить часы: остатка нет — это срок.
---@param deadline number
---@return string
local function kind_of(deadline)
    if within.left(deadline) <= 0 then
        return failure.TIMEOUT
    end

    return failure.BROKEN
end

--- Чтение байтов ответа в остаток срока.
---
--- Остаток не проверяется до чтения: сокет и TLS со сроком ноль и меньше
--- не ждут вовсе и отказывают сразу, а род отказа решают часы.
---@param io TntRedisIo
---@param deadline number
---@return fun(opts: table): string|nil, table|nil
local function receiver(io, deadline)
    return function(opts)
        -- Под pcall: сокет, закрытый соседом, бросает, а не отвечает.
        -- Отмену файбера бросает тоже; её фасад поднимает сам.
        local ok, piece, why = pcall(io.read, io, opts, within.left(deadline))

        if ok and piece ~= nil then
            return piece
        end

        if kind_of(deadline) == failure.TIMEOUT then
            return nil, trouble(failure.TIMEOUT, 'ответа нет за срок вызова')
        end

        return nil,
            trouble(
                failure.BROKEN,
                ('соединение оборвалось: %s'):format(tostring(ok and why or piece))
            )
    end
end

--- Отправляет команды и читает ответы на них.
---
--- Команда, которую не удалось записать целиком, до сервера не дошла:
--- неполную сервер не выполняет, а соединение выбрасывается. Такую
--- повторять можно всегда. Из нескольких команд подряд первые могли
--- уйти целиком — их повтор решает согласие вызывающего.
---@param link TntRedisLink
---@param payload string Команды байтами
---@param count integer Сколько в них команд
---@param deadline number Миг срока
---@param budget integer Предел байтов на все ответы
---@return TntRedisReply[]|nil replies
---@return table|nil trouble Род, текст, дошла ли команда
function Module.exchange(link, payload, count, deadline, budget)
    local io = link.io
    local ok, written, why = pcall(io.write, io, payload, within.left(deadline))

    if not (ok and written) then
        local kind = kind_of(deadline)
        local alone = count == 1

        return nil,
            trouble(
                kind,
                ('команда не ушла: %s'):format(tostring(ok and why or written)),
                not alone,
                (alone and kind == failure.BROKEN) or nil
            )
    end

    return resp.read(receiver(io, deadline), count, budget)
end

--- Закрывает соединение, чем бы оно ни кончилось.
---@param link TntRedisLink
function Module.close(link)
    pcall(link.io.close, link.io)
end

--- Живо ли свободное соединение — без сети и без уступки.
---
--- Бросок здесь не ловится: пул зовёт это под pcall и считает брошенное
--- ответом «не живо».
---@param link TntRedisLink
---@return boolean
function Module.alive(link)
    return link.io:idle()
end

---@class TntRedisTlsSettings
---@field verify boolean|nil Проверять ли сертификат; выключается только словом false
---@field ca_file string|nil Файл доверенных корней
---@field ca_path string|nil Каталог доверенных корней
---@field sni string|nil Имя для SNI
---@field cert_file string|nil Сертификат клиента PEM — серверу с `tls-auth-clients yes`
---@field key_file string|nil Ключ клиента PEM без пароля; по умолчанию из cert_file

---@class TntRedisLinkSettings
---@field host string Узел
---@field port integer Порт
---@field where string Узел и порт для текста отказа
---@field tls TntRedisTlsSettings|nil Шифрование; пусто — открытый текст
---@field greeting string Команды входа байтами
---@field greeting_count integer Сколько в них команд
---@field max_bytes integer Предел байтов ответа

--- Поднимает TLS поверх открытого сокета в остаток срока входа.
---@param settings TntRedisLinkSettings
---@param socket any
---@param deadline number
---@return TntRedisIo|nil io
---@return string|nil err
---@return string|nil kind Род отказа `tnt-tls`: `untrusted`, если не принят сертификат сервера
local function secure(settings, socket, deadline)
    local left = within.left(deadline)

    if left <= 0 then
        return nil, 'срок входа вышел до рукопожатия TLS'
    end

    local tls = settings.tls

    ---@cast tls TntRedisTlsSettings

    return source().secure(socket, {
        host = settings.host,
        timeout = left,
        verify = tls.verify,
        ca_file = tls.ca_file,
        ca_path = tls.ca_path,
        sni = tls.sni,
        cert_file = tls.cert_file,
        key_file = tls.key_file,
    })
end

--- Открывает соединение и входит — в срок, который дал пул.
---
--- Отказ — `TntStorageFailure`: пул отдаёт его взявшему как есть, если
--- повторять бессмысленно (`denied`, `retriable = false`), и повторяет
--- открытие внутри срока, если нет. Непринятый сертификат сервера — тоже
--- `denied`: время его не лечит, а повторы до конца срока выдавали бы
--- неверный корень или чужое имя за моргнувшую сеть.
---@param settings TntRedisLinkSettings
---@param left number Остаток срока `take`, секунд; больше нуля
---@return TntRedisLink|nil link
---@return TntStorageFailure|nil err
function Module.open(settings, left)
    local deadline = within.deadline(left)
    local where = settings.where
    local connected, socket, why = pcall(source().connect, settings.host, settings.port, left)

    if not connected or socket == nil then
        return nil,
            failure.new(
                failure.UNREACHABLE,
                ('redis %s: соединение не открылось: %s'):format(
                    where,
                    tostring(connected and why or socket)
                )
            )
    end

    ---@type TntRedisLink
    local link = { io = plain(socket), socket = socket, secured = settings.tls ~= nil }

    if link.secured then
        local secured, refusal, kind = secure(settings, socket, deadline)

        if secured == nil then
            pcall(socket.close, socket)

            return nil,
                failure.new(
                    kind == UNTRUSTED and failure.DENIED or failure.UNREACHABLE,
                    ('redis %s: рукопожатие TLS не прошло: %s'):format(where, tostring(refusal))
                )
        end

        link.io = secured
    end

    local replies, failed =
        Module.exchange(link, settings.greeting, settings.greeting_count, deadline, settings.max_bytes)

    if replies == nil then
        ---@cast failed TntRedisTrouble
        local text = ('redis %s: вход не завершился: %s'):format(where, failed.message)

        Module.close(link)

        return nil, failure.new(failure.UNREACHABLE, text)
    end

    for _, reply in ipairs(replies) do
        local fault = reply.fault

        if fault ~= nil then
            Module.close(link)

            return nil,
                failure.login(('redis %s: вход не удался: %s'):format(where, fault.text), fault.code)
        end
    end

    return link
end

return Module

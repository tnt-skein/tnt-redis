#!/usr/bin/env bash
# Поднимает Redis для живых проверок драйвера tnt-redis.
#
# Настоящий сервер, а не двойник: двойник показывает, что мы правильно
# разговариваем сами с собой, а чужой сервер — что нас понимает кто-то
# ещё. Разница вылезает на первом же отказе: текст WRONGPASS, ошибка
# внутри массива из EVAL, запись числа, которую INCRBY не принимает.
#
# Три контейнера, четыре порта. Первый — открытый порт с паролем
# пользователя default и двумя учётками ACL: `app` может всё, `reader` —
# только читать, чтобы отказ NOPERM был настоящим, — и порт TLS без
# сертификата клиента (`tls-auth-clients no`). Второй — только TLS,
# и сертификат клиента он требует (`tls-auth-clients yes`, умолчание
# Redis): так проверяется, что tnt-tls его предъявляет, а без него сервер
# не пускает. Порт TLS у Redis один на процесс, поэтому второй порт —
# второй сервер.
#
# Третий — только для проверки BUSY. Сценарий-долгожитель занимает весь
# сервер: пока он идёт, Redis отвечает BUSY всем клиентам. Стенд один
# на машину, а проверки идут разом из нескольких рабочих копий, и на общем
# сервере BUSY одной копии ронял бы живые проверки другой. Порог BUSY
# у третьего опущен до 100 мс, чтобы сценарий занимал его в проверке
# за доли секунды, а не за пять.
#
# Корень, серверный и клиентский сертификаты выпускаются здесь же
# и только для проверки: сервер выписан на 127.0.0.1 и localhost, клиент —
# на имя `tnt-redis-live-client`. Каталог — `REDIS_TLS_DIR`, по умолчанию
# общий на машину `/tmp/tnt-stand/<контейнер>`; живая проверка читает
# ту же переменную и то же умолчание. Не `test/stand/run/` своей копии:
# контейнер один на машину и переживает копию, которая его подняла, —
# сертификаты в ней видела бы только она, а копия со старыми сертификатами
# после чужого подъёма падала бы на рукопожатии.
#
# Имя первого контейнера — `STAND_REDIS_CONTAINER`, второй и третий
# зовутся так же с приставками `-mtls` и `-busy`; порты —
# `STAND_REDIS_PORT`, `STAND_REDIS_TLS_PORT`, `STAND_REDIS_MTLS_PORT`
# и `STAND_REDIS_BUSY_PORT`. Второй Redis поднимается рядом под другими
# именами и портами, не сбивая первый: каталог сертификатов у него свой,
# по имени контейнера.
#
#   test/stand/redis.sh          # поднять
#   test/stand/redis.sh stop     # погасить
set -euo pipefail

# Относительный каталог отсчитывается от места запуска: оттуда его
# читает и живая проверка. Ниже сценарий переходит в свой каталог, и без
# этого стенд лёг бы в одно место, а проверка искала бы его в другом.
case "${REDIS_TLS_DIR:-}" in
    '' | /*) ;;
    *) REDIS_TLS_DIR="${PWD}/${REDIS_TLS_DIR}" ;;
esac

cd "$(dirname "$0")"

IMAGE='redis:7.4-alpine'
CONTAINER="${STAND_REDIS_CONTAINER:-tnt-stand-redis}"
MTLS_CONTAINER="${CONTAINER}-mtls"
BUSY_CONTAINER="${CONTAINER}-busy"
PORT="${STAND_REDIS_PORT:-16379}"
TLS_PORT="${STAND_REDIS_TLS_PORT:-16380}"
MTLS_PORT="${STAND_REDIS_MTLS_PORT:-16381}"
BUSY_PORT="${STAND_REDIS_BUSY_PORT:-16382}"
DIR="${REDIS_TLS_DIR:-/tmp/tnt-stand/${CONTAINER}}"

# Пароли стенда: локальный сервер для проверок, а не развёртывание.
PASSWORD='stand-secret'

if ! command -v docker > /dev/null 2>&1; then
    echo 'docker не найден: Redis поднять нечем' >&2
    exit 1
fi

if [ "${1:-up}" = 'stop' ]; then
    docker rm -f "${CONTAINER}" "${MTLS_CONTAINER}" "${BUSY_CONTAINER}" > /dev/null 2>&1 || true
    echo 'Redis остановлен'
    exit 0
fi

if ! command -v openssl > /dev/null 2>&1; then
    echo 'openssl не найден: сертификаты выпустить нечем' >&2
    exit 1
fi

# Повторный запуск безвреден: контейнеры с теми же именами сносятся
# и поднимаются заново. Данных на диск стенд не пишет вовсе. Сносятся
# до выпуска сертификатов: каталог смонтирован в них, и проверки соседних
# копий иначе брали бы новый корень, пока отвечает старый сервер.
docker rm -f "${CONTAINER}" "${MTLS_CONTAINER}" "${BUSY_CONTAINER}" > /dev/null 2>&1 || true

mkdir -p "${DIR}"
DIR="$(cd "${DIR}" && pwd)"

# Выпускает ключ и сертификат, подписанный корнем.
#   $1 — имя файлов, $2 — CN, $3 — файл расширений
issue() {
    openssl req -newkey rsa:2048 -nodes -subj "/CN=$2" \
        -keyout "${DIR}/$1.key" -out "${DIR}/$1.csr" 2> /dev/null
    openssl x509 -req -in "${DIR}/$1.csr" -days 365 \
        -CA "${DIR}/ca.pem" -CAkey "${DIR}/ca.key" -CAcreateserial \
        -extfile "$3" -out "${DIR}/$1.pem" 2> /dev/null
}

# Сертификаты выпускаются заново на каждый подъём: вчерашний каталог дал
# бы отказ рукопожатия, неотличимый от того, ради которого проверка
# написана. Срок — год, а не сутки: контейнер общий на машину и живёт
# дольше задачи, которая его подняла, и сертификат на сутки назавтра
# ронял бы проверки TLS во всех копиях.
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj '/CN=tnt-redis-live-ca' \
    -keyout "${DIR}/ca.key" -out "${DIR}/ca.pem" 2> /dev/null
printf 'subjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n' > "${DIR}/server.ext"
printf 'extendedKeyUsage=clientAuth\n' > "${DIR}/client.ext"

issue server localhost "${DIR}/server.ext"
issue client tnt-redis-live-client "${DIR}/client.ext"

# Redis в образе запускается не от root: ключ должен читаться всеми.
chmod 644 "${DIR}"/*.key

docker run -d \
    --name "${CONTAINER}" \
    -p "127.0.0.1:${PORT}:6379" \
    -p "127.0.0.1:${TLS_PORT}:6380" \
    -v "${DIR}:/certs:ro" \
    "${IMAGE}" \
    redis-server \
    --save '' \
    --appendonly no \
    --requirepass "${PASSWORD}" \
    --user app on '>app-secret' '~*' '&*' '+@all' \
    --user reader on '>reader-secret' '~*' '&*' '+@read' \
    --tls-port 6380 \
    --tls-cert-file /certs/server.pem \
    --tls-key-file /certs/server.key \
    --tls-ca-cert-file /certs/ca.pem \
    --tls-auth-clients no > /dev/null

# Открытого порта у второго сервера нет (`--port 0`): всякий вход к нему —
# через TLS с сертификатом клиента.
docker run -d \
    --name "${MTLS_CONTAINER}" \
    -p "127.0.0.1:${MTLS_PORT}:6380" \
    -v "${DIR}:/certs:ro" \
    "${IMAGE}" \
    redis-server \
    --save '' \
    --appendonly no \
    --requirepass "${PASSWORD}" \
    --port 0 \
    --tls-port 6380 \
    --tls-cert-file /certs/server.pem \
    --tls-key-file /certs/server.key \
    --tls-ca-cert-file /certs/ca.pem \
    --tls-auth-clients yes > /dev/null

docker run -d \
    --name "${BUSY_CONTAINER}" \
    -p "127.0.0.1:${BUSY_PORT}:6379" \
    "${IMAGE}" \
    redis-server \
    --save '' \
    --appendonly no \
    --busy-reply-threshold 100 \
    --requirepass "${PASSWORD}" > /dev/null

# Готовности ждём: проверки, запущенные сразу после подъёма, иначе
# пропустятся — и это выглядит как «всё хорошо», хотя ничего
# не проверено.
ready() {
    docker exec "${CONTAINER}" redis-cli -a "${PASSWORD}" --no-auth-warning ping 2> /dev/null | grep -q PONG &&
        docker exec "${MTLS_CONTAINER}" redis-cli -p 6380 --tls --cacert /certs/ca.pem \
            --cert /certs/client.pem --key /certs/client.key \
            -a "${PASSWORD}" --no-auth-warning ping 2> /dev/null | grep -q PONG &&
        docker exec "${BUSY_CONTAINER}" redis-cli -a "${PASSWORD}" --no-auth-warning ping 2> /dev/null | grep -q PONG
}

for _ in $(seq 1 50); do
    if ready; then
        echo "Redis поднят: 127.0.0.1:${PORT}, TLS 127.0.0.1:${TLS_PORT}," \
            "TLS с сертификатом клиента 127.0.0.1:${MTLS_PORT}," \
            "для проверки BUSY 127.0.0.1:${BUSY_PORT}, сертификаты в ${DIR}"
        exit 0
    fi

    sleep 0.2
done

echo "Redis не ответил за 10 секунд: смотрите docker logs ${CONTAINER}, ${MTLS_CONTAINER} и ${BUSY_CONTAINER}" >&2
exit 1

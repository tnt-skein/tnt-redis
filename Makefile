# Проверки пакета: форматирование, линт, тесты, покрытие, мутанты.

LUATEST  := .rocks/bin/luatest
LUACHECK := .rocks/bin/luacheck
COVERAGE_MIN ?= 100

# luatest держит узлы в VARDIR и стирает этот каталог на старте. Умолчание —
# общий /tmp/t, а в окружении может стоять VARDIR другого проекта: прогон
# уносил бы чужие узлы и писал бы в чужой журнал. Правило то же, что
# у tnt-mutants, — проверки и мутационный прогон делят один каталог.
# Приставка держит значение непустым: пустой VARDIR luatest понял бы как
# текущий каталог и стёр бы репозиторий.
VARDIR := /tmp/t-$(shell printf '%s' "$$(pwd)" | cksum | cut -d' ' -f1)
export VARDIR

.PHONY: help
help: ## Список целей
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN { FS = ":.*?## " } { printf "  %-12s %s\n", $$1, $$2 }'

# cluacov считает исполняемые строки по байткоду: без него luacov относит
# попадание в выражение на несколько строк к последней из них, и первая
# строка константы числится непокрытой.
#
# cluacov собирается из C против своих копий заголовков LuaJIT, и копию
# он выбирает по LUAJIT_VERSION_NUM: Tarantool объявляет 20100, и берутся
# заголовки 2.1.0-beta3. В них GC64 на x86_64 включается только макросом
# LUAJIT_ENABLE_GC64 (на arm64 — всегда), а Tarantool собран с GC64. Без
# флага раскладка объектов у рока и у машины расходится, и cluacov падает
# segfault в l_deepactivelines — гейт покрытия и его проверка падают вместе
# с ним. На arm64 флаг ничего не меняет. Аргумент CFLAGS= заменяет значение
# luarocks целиком, поэтому -fPIC повторён: без него разделяемая библиотека
# не соберётся.
CLUACOV_CFLAGS := CFLAGS="-O2 -fPIC -DLUAJIT_ENABLE_GC64"

# Собранный cluacov проверяется сразу: подсказка нужна и тогда, когда
# рок роняет процесс, а не отвечает ошибкой. Скобки держат `||` на этой
# проверке — иначе подсказка печаталась бы и на отказе предыдущего шага.
CLUACOV_CHECK := { tarantool -e "local lines = require('cluacov.deepactivelines').get(loadstring('local a = 1\nreturn a')) \
	os.exit((lines[1] and lines[2]) and 0 or 1)" || \
	{ echo 'cluacov собран не под LuaJIT этого Tarantool: см. CLUACOV_CFLAGS в Makefile' >&2; false; }; }

# Зависимости пакета — с сервера роков tnt-skein, по rockspec. tnt-env
# нужен только проверкам: живая проверка читает из окружения порт
# и каталог сертификатов стенда.
.PHONY: deps
deps: ## Поставить зависимости пакета и инструменты проверок в .rocks
	tt rocks install --server=https://luarocks.org luatest
	tt rocks install --server=https://luarocks.org luacheck 1.2.0
	tt rocks install --server=https://luarocks.org luacov 0.17.0
	tt rocks install --server=https://luarocks.org cluacov 1.0.0 $(CLUACOV_CFLAGS) && \
	$(CLUACOV_CHECK)
	tt rocks install --server=https://tnt-skein.github.io/rocks --only-deps tnt-redis-scm-1.rockspec
	tt rocks install --server=https://tnt-skein.github.io/rocks tnt-env

.PHONY: fmt
fmt: ## Отформатировать код
	stylua .

.PHONY: fmt-check
fmt-check: ## Проверить форматирование, ничего не меняя
	stylua --check .

.PHONY: lint
lint: ## Линт
	$(LUACHECK) . --formatter plain --codes

.PHONY: test
test: ## Прогон проверок
	$(LUATEST) test/

.PHONY: coverage
coverage: ## Проверки с покрытием и порогом
	mkdir -p var && rm -f var/luacov.stats.out
	$(LUATEST) test/ --coverage
	tarantool tools/coverage_gate.lua $(COVERAGE_MIN)

# Мутационное тестирование — утилитой tnt-mutants (github.com/tnt-skein/tnt-mutants).
.PHONY: mutants
mutants: ## Мутационное тестирование изменённых модулей
	tnt-mutants

.PHONY: mutants-all
mutants-all: ## Мутационное тестирование всех модулей
	tnt-mutants $(shell find tnt -name '*.lua' | sort)

.PHONY: check
check: fmt-check lint test coverage ## Все проверки, кроме мутантов

.PHONY: clean
clean: ## Убрать рабочие каталоги
	rm -rf var

# Стенд живых проверок — Redis 7.4 в докере: пароль, учётки ACL для
# записи и только для чтения, порт TLS, сервер TLS, требующий сертификат
# клиента, и отдельный сервер для проверки BUSY. Сертификаты выпускаются
# на год в общий на машину каталог /tmp/tnt-stand/<контейнер>. Без стенда
# живые проверки пропускаются: гейты не должны зависеть от докера.
.PHONY: redis-up
redis-up: ## Поднять Redis 7.4 для живых проверок: пароль, учётки ACL, порт TLS, TLS с сертификатом клиента, сервер для BUSY
	test/stand/redis.sh

.PHONY: redis-down
redis-down: ## Погасить Redis
	test/stand/redis.sh stop

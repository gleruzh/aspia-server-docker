<!-- canonical: README.md df95a4fe57f00fb139753ca4919a69752062d679 -->
[English](../README.md) | **Русский**

# Aspia Server в Docker (Router + Relay)

[![CI](../../../actions/workflows/ci.yml/badge.svg)](../../../actions/workflows/ci.yml) [![Publish](../../../actions/workflows/publish.yml/badge.svg)](../../../actions/workflows/publish.yml)

Этот репозиторий собирает Docker-образ серверной части [Aspia](https://aspia.org/), системы удалённого доступа с открытым исходным кодом. В образе работают Aspia Router и Aspia Relay версии 3.0.22.

## Что это и чем не является

- Это неофициальная сборка. Разработчики Aspia не публикуют этот образ и не поддерживают его.
- Автор Aspia — Dmitry Chapyshev. Образ устанавливает официальные пакеты Router и Relay и проверяет их контрольные суммы. Этот проект продолжает Docker-образ для Aspia 2.x и опирается на чужую работу. См. [Лицензия и благодарности](#лицензия-и-благодарности) в конце.
- Это не документация Aspia. Про Router, Relay, Host и Client читайте документацию на [aspia.org](https://aspia.org/documentation.html).
- Образ не обновляется сам. Вы сами выбираете версию и сами обновляете образ вручную.

## Требования

- Сервер на Linux с процессором x86_64 (amd64). Образа для ARM нет, потому что Aspia не публикует серверные пакеты для ARM.
- Docker Engine 25.0 или новее с плагином Docker Compose (команда `docker compose`). Пользуйтесь [официальной инструкцией Docker](https://docs.docker.com/engine/install/).
- Публичный IP-адрес или DNS-имя сервера. Host и Client должны иметь возможность подключиться к нему.
- Порты из раздела [Порты](#порты) должны быть открыты в межсетевом экране.
- Aspia Client и Aspia Host версии 3.x. Скачайте их на странице [выпусков Aspia](https://github.com/dchapyshev/aspia/releases).

Для команд ниже нужен пользователь, которому разрешён доступ к Docker: `sudo` или [шаги после установки](https://docs.docker.com/engine/install/linux-postinstall/).

## Быстрый старт

Образ публикуется в GitHub Container Registry как `ghcr.io/<owner>/aspia-server`. Здесь `<owner>` — аккаунт GitHub, который публикует этот репозиторий. Это имя аккаунта в адресе репозитория: `https://github.com/<owner>/aspia-server-docker`. Замените `<owner>` во всех командах ниже.

1. Создайте каталог для сервера и скачайте в него два файла:

    ```shell
    mkdir aspia-server
    cd aspia-server
    curl -fsSLO https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/docker-compose.yml
    curl -fsSL -o .env https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/.env.example
    ```

2. Откройте файл `.env` в текстовом редакторе. В файле уже есть строка `EXTERNAL_IP=203.0.113.10`. Это только пример адреса. Замените его публичным адресом сервера. Если оставить его, сеансы через Relay не будут работать, и никакой ошибки вы не увидите. Затем укажите образ. У образа должен быть точный тег версии:

    ```shell
    # .env
    EXTERNAL_IP=203.0.113.10
    ASPIA_IMAGE=ghcr.io/<owner>/aspia-server:3.0.22
    ```

    `EXTERNAL_IP` — адрес, который Relay сообщает программам Client и Host. Это может быть IP-адрес или DNS-имя. Значение `auto` определяет публичный IP-адрес при каждом запуске.

3. Откройте порты из раздела [Порты](#порты) в межсетевом экране сервера.

4. Скачайте образ и запустите контейнер:

    ```shell
    docker compose pull
    docker compose up -d
    ```

5. Убедитесь, что контейнер работоспособен. Через несколько секунд в статусе появится `(healthy)`:

    ```shell
    docker compose ps
    ```

Чтобы посмотреть журнал:

```shell
docker compose logs aspia-server
```

Служба в `docker-compose.yml` называется `aspia-server`. В `compose.router.yml` она называется `aspia-router`, а в `compose.relay.yml` — `aspia-relay`. Если вы используете один из этих файлов, подставляйте имя службы из этого файла во все команды, где оно есть.

Термины в этом документе:

| Термин | Значение |
|---|---|
| Router | Программа Aspia, к которой подключаются Host и Client. Хранит пользователей и список Host. |
| Relay | Программа Aspia, которая передаёт сеанс, когда Client и Host не могут подключиться напрямую. |
| Host | Программа Aspia на компьютере, которым вы хотите управлять. |
| Client | Программа Aspia, с помощью которой вы подключаетесь к Host и управляете Router. |
| сервер | Машина, на которой вы запускаете этот образ. |

Сервер хранит данные в каталоге `data` рядом с `docker-compose.yml`:

| Каталог на сервере | Путь в контейнере | Содержимое |
|---|---|---|
| `./data/config` | `/etc/aspia` | Файлы конфигурации и ключи |
| `./data/database` | `/var/lib/aspia` | База данных Router |

Сохраните этот каталог. В нём лежат ключи Router. Если вы потеряете ключи, придётся заново настраивать каждый Host.

## Первый вход

### Открытый ключ для Host

Программе Host нужны адрес Router и открытый ключ для Host. Контейнер выводит ключ в журнал при каждом запуске:

```shell
docker compose logs aspia-server | grep 'Public key for hosts'
```

Ключ есть и в файле `host.pub`:

```shell
docker compose exec aspia-server cat /etc/aspia/host.pub
```

Не используйте для Host ключ из `relay.pub`. Этот ключ предназначен только для Relay.

### Подключение через Client и смена пароля

При первом запуске Router создаёт пользователя `admin` с паролем `admin`. Смените этот пароль после первого входа.

1. Установите Aspia Client. При первом запуске Client запрашивает мастер-пароль. Мастер-пароль обязателен, и восстановить его нельзя.
2. Добавьте Router: введите адрес вашего сервера (Router принимает Client на порту 8062), выберите в поле «Access Level» значение «Administrator» и войдите как `admin` с паролем `admin`.
3. В Aspia 3.x двухфакторная аутентификация обязательна. При первом входе Client потребует настроить её с помощью приложения-аутентификатора.
4. Откройте список пользователей Router и смените пароль `admin`.

Эти шаги описаны в документации Client: [Aspia Client](https://aspia.org/docs/client). В Aspia 3.x нет ни команды, ни параметра конфигурации для смены этого пароля. Сменить его можно только в Client.

### Подключение Host

1. Установите Aspia Host на компьютер.
2. В настройках Host откройте вкладку «Router». Введите адрес вашего сервера и открытый ключ для Host.
3. Router принимает Host версии Aspia 3.x на порту 8061.

Host, который подключается впервые, появляется в программе Client в разделе «Unapproved hosts». Оттуда к нему можно подключиться. Чтобы сохранить настройки Host, одобрите его. См. [Aspia Host](https://aspia.org/docs/host) и [Aspia Client](https://aspia.org/docs/client).

## Порты

Публикуйте каждый порт с одним и тем же номером на сервере и в контейнере. Relay сообщает программам Client и Host собственный номер порта, поэтому другой порт на сервере нарушит сеансы через Relay. В `docker-compose.yml` это уже сделано.

| Порт | Переменная | Служба | Назначение | Открыт для доступа из интернета |
|---|---|---|---|---|
| 8060/tcp | `ASPIA_ROUTER_LEGACY_PORT` | Router | Host версии Aspia 2.x | Только если у вас ещё есть Host версии Aspia 2.x |
| 8061/tcp | `ASPIA_ROUTER_HOST_PORT` | Router | Host версии Aspia 3.x | Да |
| 8062/tcp | `ASPIA_ROUTER_CLIENT_PORT` | Router | Client: адресная книга и управление Router | Да или только для сетей ваших пользователей |
| 8065/udp | `ASPIA_ROUTER_STUN_PORT` | Router | Встроенный сервер STUN | Да |
| 8070/tcp | `ASPIA_RELAY_PEER_PORT` | Relay | Client и Host в сеансе через Relay | Да. На сервере только с Relay это единственный порт, который нужно открыть. |
| 8063/tcp | нет | Router | Relay | Нет. `docker-compose.yml` его не публикует. Открывайте его только для Relay на другом сервере (см. [Запуск Relay на отдельном сервере](#запуск-relay-на-отдельном-сервере)). |

Это номера портов по умолчанию. Переменная меняет порт в файле конфигурации и опубликованный порт.

Docker добавляет собственные правила межсетевого экрана для опубликованных портов. Если на сервере работает `ufw`, прочитайте [Docker and ufw](https://docs.docker.com/engine/network/packet-filtering-firewalls/#docker-and-ufw).

## Переменные окружения

Задавайте переменные в файле `.env` рядом с `docker-compose.yml`. Файл `.env.example` перечисляет их все с комментариями. Переменные портов есть в таблице в разделе [Порты](#порты). Файлы compose берут опубликованный порт из той же переменной, поэтому порт на сервере и порт в контейнере совпадают. Если вы правите `ports:` сами, следите, чтобы они совпадали.

После изменения примените его:

```shell
docker compose up -d
```

Правила:

- Заданная переменная записывается в файл конфигурации при каждом запуске.
- Незаданная переменная файл конфигурации не меняет. Ваши собственные правки в `router.conf` и `relay.conf` сохраняются.
- Пустое значение считается незаданным. Например, `ASPIA_ROUTER_CLIENT_ALLOWED_IPS=` не очищает существующий список. Чтобы очистить список, отредактируйте `router.conf`.
- Недопустимое значение останавливает запуск. Тогда контейнер перезапускается снова и снова (статус `Restarting`). В журнале указано имя переменной. Ничего не меняется.

| Переменная | По умолчанию | Что задаёт |
|---|---|---|
| `EXTERNAL_IP` | нет, обязательна | Публичный адрес, который Relay сообщает программам Client и Host. IP-адрес, DNS-имя не длиннее 64 символов или `auto`. |
| `ASPIA_RELAY_PUBLIC_ADDRESS` | нет | Новое имя `EXTERNAL_IP` с тем же действием. Если обе переменные заданы разными значениями, используется эта. |
| `ASPIA_RELAY_IDLE_TIMEOUT` | `5` | Сколько минут Relay держит неактивное соединение. |
| `ASPIA_RELAY_MAX_PEERS` | `100` | Наибольшее число Client и Host, которых Relay обслуживает одновременно. |
| `ASPIA_ROUTER_STUN_ENABLED` | `1` | `1` включает встроенный сервер STUN, `0` выключает его. |
| `ASPIA_ROUTER_CLIENT_ALLOWED_IPS`, `ASPIA_ROUTER_HOST_ALLOWED_IPS` | пусто: все адреса | Адреса и подсети, которым разрешено подключаться как Client или как Host, через запятую, например `203.0.113.0/24`. |
| `ASPIA_ROUTER_RELAY_ALLOWED_IPS` | пусто: все адреса | Адреса и подсети, которым разрешено подключаться как Relay. При `ASPIA_ROLE=all` список должен содержать `127.0.0.1`, потому что Relay в том же контейнере подключается с этого адреса. |
| `ASPIA_ROLE` | `all` | Что запускает контейнер: `all` (Router и Relay), `router` или `relay`. Файлы compose задают её сами. Задавайте её вручную только для `docker run --env-file` или Podman. См. [Запуск Relay на отдельном сервере](#запуск-relay-на-отдельном-сервере). |
| `ASPIA_RELAY_ROUTER_ADDRESS` | нет | Только для `ASPIA_ROLE=relay`, и там обязательна: адрес Router. |
| `ASPIA_RELAY_ROUTER_PORT` | `8063` | Только для `ASPIA_ROLE=relay`: порт Router для Relay. |
| `ASPIA_RELAY_ROUTER_PUBLIC_KEY` | нет | Только для `ASPIA_ROLE=relay`, и там обязательна: содержимое файла `relay.pub` на Router. |
| `ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE` | нет | Только для `ASPIA_ROLE=relay`: путь к файлу с этим ключом вместо самого ключа. |
| `PUID`, `PGID` | `0` (root) | Запускать Router и Relay от имени пользователя и группы с этими ID. Задайте обе переменные или ни одной. При каждом запуске контейнер меняет владельца `./data/config` и `./data/database`. |
| `TZ` | `UTC` | Часовой пояс меток времени в журнале, например `Europe/Berlin`. |
| `ASPIA_LOG_LEVEL` | `1` | Минимальный уровень журнала: `0` TRACE, `1` INFO, `2` WARNING, `3` ERROR, `4` FATAL. |
| `ASPIA_IMAGE` | `aspia-server:3.0.22` | Образ, который запускает `docker compose`. Значение по умолчанию — имя локальной сборки. |

У некоторых параметров нет переменной: порт Router для Relay (`[relay] port` в `router.conf`) и адреса прослушивания (`listen_interface`). Для них отредактируйте `router.conf` или `relay.conf`. Контейнер никогда не перезаписывает такое изменение. Нет и переменной для пароля `admin` (см. [Первый вход](#первый-вход)).

`ASPIA_ROUTER_CONFIG_FILE`, `ASPIA_ROUTER_DB_FILE` и `ASPIA_RELAY_CONFIG_FILE` — переменные программ Aspia. Файлы compose не передают их в контейнер, поэтому в `.env` они не действуют. Этот образ пока их не поддерживает. Если вы зададите одну из них в контейнере сами (`docker run` или Podman), контейнер не запустится.

## Параметры безопасности

Файлы compose и юниты Podman запускают контейнер с минимальными привилегиями:

- Все capabilities Linux (отдельные права root) отключены, кроме пяти. Их список ниже.
- Ни один процесс не может получить новые привилегии. Программы с битом setuid не работают. Юниты Podman этого не задают (см. ниже).
- Файлы образа доступны только для чтения. Контейнер пишет только в свои два тома.
- В контейнере может быть не больше 128 процессов и потоков. Он использует меньше 30.

Пять capabilities, которые остаются:

- `CHOWN`: сделать `PUID`/`PGID` владельцем томов и сохранить владельца резервной копии.
- `DAC_OVERRIDE`: читать и записывать файлы другого пользователя, например в каталоге пользователя на сервере или после прежнего запуска с `PUID`/`PGID`. С `PUID`/`PGID` она нужна проверке состояния, чтобы прочитать конфигурацию.
- `SETUID`: переключиться на пользователя `PUID`.
- `SETGID`: переключиться на группу `PGID`.
- `KILL`: передать сигнал остановки процессам, которые работают от имени `PUID`/`PGID`.

Те же параметры с `docker run`:

```shell
docker run -d --name aspia-server --restart unless-stopped \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add SETUID --cap-add SETGID --cap-add KILL \
  --security-opt no-new-privileges:true --read-only --pids-limit 128 \
  -e EXTERNAL_IP=203.0.113.10 \
  -p 8060:8060 -p 8061:8061 -p 8062:8062 -p 8065:8065/udp -p 8070:8070 \
  -v "$PWD/data/config:/etc/aspia" -v "$PWD/data/database:/var/lib/aspia" \
  ghcr.io/<owner>/aspia-server:3.0.22
```

В простейшей установке ни одна из пяти capabilities не нужна: `PUID` и `PGID` не заданы, а тома принадлежат root. В этом случае можно убрать флаги `--cap-add` или `cap_add:` в файле compose.

Все порты по умолчанию выше 1024. Порту ниже 1024 нужна capability `NET_BIND_SERVICE`. Docker она нужна только тогда, когда контейнер использует сеть сервера: добавьте `--cap-add NET_BIND_SERVICE`. Podman она нужна всегда: добавьте `AddCapability=NET_BIND_SERVICE` в юнит.

Юниты Podman не задают `NoNewPrivileges`. На Ubuntu 24.04 AppArmor тогда блокирует сигнал остановки, и контейнер не останавливается корректно. Docker это не касается. Замеры описаны в [docs/dev/UPSTREAM-3.x-NOTES.md](dev/UPSTREAM-3.x-NOTES.md), раздел 21.

## Обновление

Образ никогда не обновляется сам. Вы обновляете его вручную, когда решите это сделать.

1. Прочитайте [список изменений Aspia](https://aspia.org/changelog).
2. Сделайте резервную копию (см. [Резервное копирование и восстановление](#резервное-копирование-и-восстановление)). Новая версия может преобразовать базу данных, и после этого старая версия может не прочитать её.
3. В `.env` замените версию в теге `ASPIA_IMAGE` на новую.
4. Скачайте образ и создайте контейнер заново, затем проверьте статус и журнал, как в разделе [Быстрый старт](#быстрый-старт):

    ```shell
    docker compose pull
    docker compose up -d
    docker compose ps
    ```

Чтобы вернуться к старой версии, впишите старый тег в `.env` и выполните `docker compose up -d`. Если новая версия преобразовала данные, восстановите и резервную копию.

Не запускайте `aspia_router --check-update` и `aspia_router --install-update` в контейнере. Обновление, установленное в контейнере, пропадает, когда контейнер создаётся заново.

### Теги и дайджесты

Тег `3.0.22` переназначается при каждой публикации: при отправке в `main` с изменением образа, при ручном запуске и при еженедельной пересборке с обновлениями безопасности Debian. Тег `3.0.22-YYYYMMDD`, например `3.0.22-20261005`, не переназначается никогда. Его создают только еженедельная пересборка или ручной запуск с тегом с датой. Короткие теги, например `3.0`, тоже переназначаются. Не используйте их на сервере. Подробности и проверку подписи образа смотрите в [docs/ci.md](ci.md).

Чтобы образ никогда не менялся, закрепите его по дайджесту. Покажите дайджесты скачанного образа:

```shell
docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' ghcr.io/<owner>/aspia-server:3.0.22
```

Если вы скачивали образ из обоих реестров, в списке будет и строка, которая начинается с `docker.io`. Используйте строку, которая начинается с `ghcr.io`. Она выглядит как `ghcr.io/<owner>/aspia-server@sha256:...`. Впишите её в `.env`:

```shell
# .env
ASPIA_IMAGE=ghcr.io/<owner>/aspia-server@sha256:2ff06f77e1e364bf03245bc5453646a62313a4b4dba0ae086c89446d4558d4a0
```

Дайджест в этом примере — только пример. Его показывает и сводка каждого запуска публикации на GitHub.

## Переход с 2.x

Этот раздел для сервера со старым образом `paprikkafox/aspia-server` (версия 2.7.0, обычно с тегом `latest`), файлом `docker-compose.yml` и каталогом `data`. Образ 3.0.22 сохраняет ваших пользователей, Host и ключи. Официальное [руководство по миграции](https://aspia.org/docs/migration) описывает порядок обновления, Console, адресные книги и двухфакторную аутентификацию.

Исходный образ удалён из Docker Hub в октябре 2026 года. Тот же образ (с тем же digest) сохранён как `gleruzh/aspia-server:2.7.0-paprikkafox`, для отката на 2.7.0.

1. Перейдите в каталог старой установки. Запишите `EXTERNAL_IP` из старого `docker-compose.yml`: старый файл задаёт его в списке `environment:`. Затем остановите контейнер:

    ```shell
    docker compose down
    ```

2. Сделайте резервную копию старых данных и старого файла compose:

    ```shell
    (umask 077; sudo tar -czf - data docker-compose.yml > aspia-2.7.0-backup.tar.gz)
    ```

3. Скачайте новые файлы. Новый `docker-compose.yml` заменяет старый, который теперь есть в резервной копии:

    ```shell
    curl -fsSLO https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/docker-compose.yml
    curl -fsSL -o .env https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/.env.example
    ```

4. Укажите в `.env` образ и адрес, откройте порты, затем скачайте образ и запустите контейнер, как в разделе [Быстрый старт](#быстрый-старт). Возьмите `EXTERNAL_IP` из шага 1. Оставьте открытым 8060/tcp для Host версии Aspia 2.x.

Что происходит при первом запуске:

- Контейнер копирует `router.json`, `relay.json` и `router.db3` в файлы с суффиксом `.pre-3.0.22-<time>` рядом с оригиналами.
- Aspia преобразует `router.json` в `router.conf`, а `relay.json` в `relay.conf`. Старые файлы она переименовывает в `router.json.bak` и `relay.json.bak`.
- Aspia переводит базу данных `router.db3` на новую версию. После этого Aspia 2.7.0 может не прочитать её.
- Router сохраняет свой ключ, поэтому Host, которые используют ключ из `router.pub`, продолжают работать. Контейнер копирует `router.pub` в `host.pub` и `relay.pub` — имена файлов в Aspia 3.x.
- Два параметра не переносятся: список разрешённых адресов администраторов (`AdminWhiteList`; в Aspia 3.x такого параметра нет) и параметры статистики Relay.
- Эти переменные действуют только со второго запуска: `ASPIA_ROUTER_CLIENT_PORT`, `ASPIA_ROUTER_HOST_PORT`, `ASPIA_ROUTER_STUN_PORT` и `ASPIA_ROUTER_STUN_ENABLED`. Если вы задали любую из них, выполните `docker compose restart` после первого запуска.

Чтобы вернуться к 2.7.0, остановите контейнер, восстановите резервную копию из шага 2, как описано в разделе [Резервное копирование и восстановление](#резервное-копирование-и-восстановление), и запустите старую версию. В резервной копии лежит старый `docker-compose.yml`.

## Резервное копирование и восстановление

В каталоге `data` лежит всё: конфигурация, ключи и база данных. Остановите контейнер перед резервным копированием, чтобы файлы базы данных были целыми.

Файлы в `data` принадлежат root (или `PUID`, если вы его задали), поэтому `tar` запускается с `sudo`. Файл архива создаёт ваша собственная оболочка, поэтому он принадлежит вам, и вы можете его скопировать. В архиве есть закрытые ключи. Команда `umask 077` делает архив доступным для чтения только вам:

```shell
docker compose stop
(umask 077; sudo tar -czf - data .env docker-compose.yml > aspia-backup-$(date +%Y%m%d-%H%M%S).tar.gz)
docker compose start
```

Если вы используете `compose.router.yml`, добавьте его в список файлов. На сервере Relay список такой: `data .env compose.relay.yml`. Чтобы восстановить данные, укажите имя вашего файла резервной копии:

```shell
docker compose down
sudo mv data data.old-$(date +%Y%m%d-%H%M%S)
sudo tar -xzf aspia-backup-20261002-114739.tar.gz
docker compose up -d
```

Храните резервную копию на другой машине.

## Запуск Relay на отдельном сервере

Тот же образ может запускать только Router (`ASPIA_ROLE=router`) или только Relay (`ASPIA_ROLE=relay`). Relay на другом сервере передаёт трафик сеансов вместо сервера Router. Один Router принимает одновременно не более пяти Relay. Без `ASPIA_ROLE` значение по умолчанию `all` запускает Router и Relay в одном контейнере. Таблица [Порты](#порты) показывает, какие порты нужны каждому серверу.

### На сервере Router

Эти шаги запускают только Router из `compose.router.yml`. Чтобы оставить Router и локальный Relay в одном контейнере, см. [Вариант: оставить объединённый контейнер](#вариант-оставить-объединённый-контейнер).

1. Скачайте `compose.router.yml` в каталог сервера. Он использует тот же каталог `data` и тот же `.env`, что и `docker-compose.yml`. Ключи остаются прежними, поэтому Host и Client менять не нужно.

    ```shell
    curl -fsSLO https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/compose.router.yml
    ```

2. Остановите объединённый контейнер. Затем сделайте `compose.router.yml` файлом, который `docker compose` использует в этом каталоге, и запустите только Router:

    ```shell
    docker compose down
    echo 'COMPOSE_FILE=compose.router.yml' >> .env
    docker compose up -d
    ```

    Теперь обычные команды `docker compose` работают с `compose.router.yml`. Добавьте этот файл в резервную копию.

3. Получите открытый ключ для Relay. Router выводит его в журнал как `Public key for relays`. Он есть и в файле `./data/config/relay.pub`.

    ```shell
    docker compose logs aspia-router | grep 'Public key for relays'
    ```

    При новой установке этот ключ отличается от ключа для Host. После перехода с 2.x оба ключа — это прежний `router.pub`.

4. Разрешите подключение только вашим Relay. В `.env` задайте адреса Relay такими, какими их видит Router. У Relay за NAT это публичный адрес его NAT. Затем примените изменение:

    ```shell
    # .env
    ASPIA_ROUTER_RELAY_ALLOWED_IPS=203.0.113.20
    ```

    ```shell
    docker compose up -d
    ```

    Без этой переменной Router принимает Relay с любого адреса, которому доступен порт 8063 и который имеет ключ из шага 3. Пока вы не зададите переменную, в журнале Router выводится предупреждение `WARNING`.

5. В межсетевом экране разрешите 8063/tcp только с серверов Relay.

### Вариант: оставить объединённый контейнер

Используйте его, если сервер Router должен сохранить собственный Relay и при этом принимать Relay с других серверов. Оставьте `docker-compose.yml` и не скачивайте `compose.router.yml`. Служба называется `aspia-server`. Отличия от шагов выше:

- Добавьте `"8063:8063"` в список `ports:` файла `docker-compose.yml`.
- Получите открытый ключ для Relay, как в шаге 3.
- В шаге 4 список должен содержать ещё и `127.0.0.1`, потому что Relay в том же контейнере подключается с этого адреса. Например, `ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1,203.0.113.20`.
- Выполните `docker compose up -d`, чтобы применить изменения.
- Шаг 5 выполните без изменений.

### На каждом сервере Relay

1. Создайте каталог и скачайте `compose.relay.yml`:

    ```shell
    mkdir aspia-relay
    cd aspia-relay
    curl -fsSLO https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/compose.relay.yml
    ```

2. Создайте в этом каталоге файл `.env` с такими строками. Укажите адрес вашего Router, публичный адрес этого сервера Relay и открытый ключ для Relay, который вы получили на сервере Router. `COMPOSE_FILE` заставляет обычные команды `docker compose` работать с `compose.relay.yml`:

    ```shell
    # .env
    COMPOSE_FILE=compose.relay.yml
    ASPIA_IMAGE=ghcr.io/<owner>/aspia-server:3.0.22
    EXTERNAL_IP=203.0.113.20
    ASPIA_RELAY_ROUTER_ADDRESS=203.0.113.10
    ASPIA_RELAY_ROUTER_PUBLIC_KEY=047d0004a25c7f61e501c3eadc701732ca94c6a2fb035b4935caf7da7b27c555
    ```

    Ключ в этом примере — только пример. Вместо самого ключа можно указать в `ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE` путь к копии `relay.pub`. Комментарии в `compose.relay.yml` показывают, как смонтировать файл.

3. Запустите Relay:

    ```shell
    docker compose pull
    docker compose up -d
    ```

    Если обязательного параметра нет, запуск завершается ошибкой, в которой указан этот параметр. Затем контейнер перезапускается снова и снова.

4. В межсетевом экране разрешите 8070/tcp для Client и Host.

### Проверка регистрации Relay

На сервере Relay:

```shell
docker compose ps
docker compose logs aspia-relay | grep 'Connection to the router'
```

Статус `(healthy)` означает, что Relay слушает порт 8070 и подключён к Router. В журнале есть строка `Connection to the router is established`.

На сервере Router:

```shell
docker compose logs aspia-router | grep -E 'New relay session|Received key pool'
```

В журнале виден адрес Relay, например `New relay session: "203.0.113.20"`.

Если Relay не подключается, он повторяет попытку каждые 15 секунд. Причину показывает его журнал:

| Сообщение в журнале Relay | Причина |
|---|---|
| `ACCESS_DENIED` | Неверный ключ. Используйте `relay.pub` сервера Router, а не `host.pub`. |
| `SPECIFIED_HOST_NOT_FOUND` | DNS-имя Router не удаётся разрешить в адрес. |
| `CONNECTION_REFUSED` | По этому адресу и порту никто не слушает. Проверьте, что порт 8063 опубликован на сервере Router. |
| `SOCKET_TIMEOUT` | Межсетевой экран отбрасывает пакеты. Сообщение появляется через 30 секунд. |
| `REMOTE_HOST_CLOSED` | Router отклонил Relay. Сообщение появляется сразу после подключения. Адреса Relay нет в `ASPIA_ROUTER_RELAY_ALLOWED_IPS`, или уже подключено пять Relay. |

Подключённый Relay всё равно может остаться без дела. Если Router не принимает публичный адрес Relay, это видно только в журнале Router: `Ignoring key pool with invalid peer endpoint`.

## Podman

Чтобы запустить сервер под Podman как службу systemd (Quadlet), прочитайте [podman/README.ru.md](../podman/README.ru.md).

## Локальная сборка

Образ можно собрать самостоятельно вместо опубликованного. При сборке пакеты Aspia скачиваются из официальных выпусков и проверяются по контрольным суммам из `versions.env`.

```shell
git clone https://github.com/<owner>/aspia-server-docker.git
cd aspia-server-docker
cp .env.example .env
```

Задайте `EXTERNAL_IP` в `.env`, а `ASPIA_IMAGE` оставьте незаданной. Затем соберите образ и запустите контейнер. Образ получит имя `aspia-server:3.0.22`:

```shell
docker compose up -d --build
```

Чтобы обновить локальную сборку, выполните `git pull`, а затем ту же команду ещё раз. Не используйте `--build`, когда задана `ASPIA_IMAGE`, и проверяйте вывод `docker compose pull` на ошибки: если скачивание не удалось, `docker compose up -d` соберёт образ локально под именем опубликованного образа.

Тесты и CI описаны в [docs/ci.md](ci.md).

## Устранение неполадок

| Признак | Что делать |
|---|---|
| Контейнер перезапускается снова и снова (статус `Restarting`). Журнал сообщает `ERROR: ASPIA_RELAY_PUBLIC_ADDRESS is not set`. | Задайте `EXTERNAL_IP` в `.env`. Затем выполните `docker compose up -d`. |
| Контейнер перезапускается снова и снова. В журнале указана другая переменная. | Исправьте значение этой переменной в `.env`. Затем выполните `docker compose up -d`. |
| `docker compose pull` сообщает `no matching manifest for linux/arm64`. | На сервере процессор ARM. Образ есть только для x86_64. |
| `EXTERNAL_IP=auto` останавливает запуск с ошибкой об определении адреса. | Сервер не может обратиться к интернет-службам, которые сообщают его адрес. Задайте адрес вручную. |
| В журнале есть `sd_login_monitor_new failed` или `Unable to install signal handler for SIGKILL`. | Ничего делать не нужно. В контейнере эти строки нормальны. |
| Статус `(unhealthy)`. | Прочитайте журнал: `docker compose logs aspia-server`. Контейнер считается работоспособным, если Router слушает свои порты, а Relay подключён к Router. |
| Host не подключается. | Проверьте, что порт 8061/tcp (8060/tcp для Aspia 2.x) открыт. Проверьте, что Host использует ключ из `host.pub`, а не из `relay.pub`. |
| Client не подключается к Router. | Проверьте, что порт 8062/tcp открыт. Если задана `ASPIA_ROUTER_CLIENT_ALLOWED_IPS`, проверьте, что в ней есть адрес Client. |
| Сеансы работают только в локальной сети, или сеансы через Relay не работают. | Проверьте, что порт 8070/tcp открыт и что `EXTERNAL_IP` — публичный адрес сервера, а не адрес из примера. Порт на сервере должен совпадать с портом в контейнере. |
| Пользователь потерял приложение-аутентификатор. | Сбросьте двухфакторную аутентификацию этого пользователя (см. ниже). |
| Вы забыли пароль `admin`. | Другой администратор может сменить его в Client. В Aspia 3.x нет команды для задания пароля. |
| Console из Aspia 2.x не работает с новым Router. | В Aspia 3.x программы Console больше нет. Используйте Client из Aspia 3.x. |
| Время в журнале неверное. | Задайте `TZ` в `.env`, например `TZ=Europe/Berlin`. Затем выполните `docker compose up -d`. |
| `Permission denied` при чтении файлов в `data`. | Файлы принадлежат root (или `PUID`). Используйте `sudo`. |
| Relay на другом сервере не регистрируется. | См. [Проверка регистрации Relay](#проверка-регистрации-relay). |

Чтобы сбросить двухфакторную аутентификацию пользователя, выполните эти команды. Замените `admin` именем пользователя:

```shell
docker compose exec aspia-server aspia_router --reset-otp admin
docker compose restart
```

## Лицензия и благодарности

Этот репозиторий распространяется по лицензии GNU General Public License v3.0: см. [LICENSE](../LICENSE). Aspia тоже распространяется по лицензии GNU General Public License v3.0.

Спасибо:

- Dmitry Chapyshev ([dchapyshev](https://github.com/dchapyshev)) — за Aspia: [dchapyshev/aspia](https://github.com/dchapyshev/aspia).
- Dmitry Fox ([paprikkafox](https://github.com/paprikkafox)) — за исходный Docker-образ aspia-server (GPL-3.0). Этот образ удалён из Docker Hub в октябре 2026 года. Текущий проект автора — [paprikkafox/aspia-docker](https://github.com/paprikkafox/aspia-docker).
- [SinitsaDA](https://github.com/SinitsaDA) за [SinitsaDA/aspia-server-docker](https://github.com/SinitsaDA/aspia-server-docker) (GPL-3.0). Из этого репозитория в образ 3.x перенесены серверный образ 3.x, обработка перехода с 2.x и проверка состояния, которая не открывает соединений.

Работа над этим репозиторием выполнена с помощью Claude — ИИ-ассистента от Anthropic — через Claude Code.

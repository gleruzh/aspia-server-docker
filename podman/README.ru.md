<!-- canonical: podman/README.md 0e1ac861dfffeb0fe04da328acfe3be03d541dde -->
[English](README.md) | **Русский**

# Сервер Aspia под Podman (systemd, Quadlet)

Запустите Aspia Router и Relay как службу systemd на машине, где есть Podman и нет Docker
(RHEL, AlmaLinux, Rocky, Fedora, Debian, Ubuntu). Скопируйте несколько файлов, выполните `systemctl daemon-reload`
и `systemctl start`: при сбое служба перезапустится, а после перезагрузки запустится снова.

- Нужны **Podman 4.5 или новее** и systemd. Для более старого Podman см. раздел 9.
- Образ собран только для linux/amd64. Ничто здесь не обновляет работающий контейнер: вы меняете версию и перезапускаете службу.
- Проверено на Podman 4.5.1, 4.9.3, 5.4.2 и 5.8.7 скриптом `tests/podman.sh` (замеры: `docs/dev/UPSTREAM-3.x-NOTES.md`, раздел 18).

| Файл | Что это |
|---|---|
| `aspia-server.container` | Юнит Quadlet: образ, порты, тома, окружение, проверка состояния, политика перезапуска. |
| `aspia-config.volume`, `aspia-data.volume` | Именованные тома для `/etc/aspia` (конфигурация и ключи) и `/var/lib/aspia` (база данных). |
| `aspia-server.env.example` | Файл окружения. Скопируйте его в `aspia-server.env`. Переменные описаны в таблицах [Порты](../docs/README.ru.md#порты) и [Переменные окружения](../docs/README.ru.md#переменные-окружения) основного README. |
| `aspia-relay.container`, `aspia-relay-config.volume`, `aspia-relay.env.example` | Отдельный Relay, подключённый к Router на другой машине (раздел 11). |

## 1. Выбор образа (одна строка)

Образ задаёт строка `Image=` в `aspia-server.container`, и это единственное место, которое нужно менять. **Используйте опубликованный
образ**, закреплённый по точному тегу версии (или по дайджесту):

```ini
Image=ghcr.io/<owner>/aspia-server:3.0.21
Image=ghcr.io/<owner>/aspia-server@sha256:<digest>
```

`<owner>` — это аккаунт, который публикует образ (см. [docs/ci.md](../docs/ci.md), там же описано, как
проверить подпись cosign). Дайджест каждого выпуска указан в сводке его запуска публикации и в
docs/ci.md. Никогда не используйте `latest`, `3` или `3.0`: при следующем скачивании образ под ними изменится.
Podman скачивает публичный образ при запуске службы, входить в реестр не нужно.

Значение по умолчанию в файле, `localhost/aspia-server:3.0.21`, — это имя, которое получает образ при локальной сборке. Чтобы собрать образ локально,
выполните команду в клоне этого репозитория от имени пользователя, который будет запускать службу (root для установки на всю систему):

```shell
podman build -t aspia-server:3.0.21 .
```

Для локальной сборки `podman build` нужен **Podman 5.1 или новее**: из-за `HEALTHCHECK --start-interval` в Dockerfile
более старый Podman завершается с ошибкой `flag provided but not defined: -start-interval`. На более старом Podman используйте опубликованный
образ или соберите образ в Docker и перенесите его: `docker save aspia-server:3.0.21 | podman load`
(после этого `Image=localhost/aspia-server:3.0.21` подойдёт, только если `podman images` показывает именно это имя; иначе присвойте образу тег).

## 2. Установка на всю систему (от root)

```shell
sudo install -d /etc/containers/systemd
sudo install -m 0644 podman/aspia-server.container podman/aspia-config.volume podman/aspia-data.volume /etc/containers/systemd/
sudo install -m 0644 podman/aspia-server.env.example /etc/containers/systemd/aspia-server.env
sudoedit /etc/containers/systemd/aspia-server.env         # укажите EXTERNAL_IP (или 'auto')
sudoedit /etc/containers/systemd/aspia-server.container   # строка Image= (раздел 1)
sudo systemctl daemon-reload
sudo systemctl start aspia-server.service
```

Команды `systemctl enable` здесь нет: Quadlet создаёт службу из файла `.container`, а его
раздел `[Install]` запускает её при загрузке. Проверка:

```shell
systemctl status aspia-server.service
sudo podman healthcheck run aspia-server     # код возврата 0 и пустой вывод, если контейнер работоспособен
sudo podman ps                               # после первой проверки в STATUS виден (healthy)
sudo podman logs aspia-server                # открытый ключ Router для Host выводится при первом запуске
sudo podman exec aspia-server cat /etc/aspia/host.pub   # тот же ключ, в любой момент
```

Остановить службу можно командой `sudo systemctl stop aspia-server.service`. Про первый вход (учётная запись администратора и открытый
ключ для Host) читайте в разделе [Первый вход](../docs/README.ru.md#первый-вход) основного README.

## 3. Установка rootless (обычный пользователь)

Контейнер работает в режиме rootless (без прав root), от имени непривилегированного пользователя. Выполняйте эти шаги от имени этого пользователя в полноценном сеансе входа (ssh или
консоль, не `sudo su`), чтобы работал `systemctl --user`.

```shell
# один раз, от root: службы пользователя работают без сеанса входа и запускаются при загрузке
sudo loginctl enable-linger "$USER"

# от имени пользователя
mkdir -p ~/.config/containers/systemd
install -m 0644 podman/aspia-server.container podman/aspia-config.volume podman/aspia-data.volume ~/.config/containers/systemd/
install -m 0644 podman/aspia-server.env.example ~/.config/containers/systemd/aspia-server.env
$EDITOR ~/.config/containers/systemd/aspia-server.env         # укажите EXTERNAL_IP (или 'auto')
$EDITOR ~/.config/containers/systemd/aspia-server.container   # строка Image= (раздел 1)
systemctl --user daemon-reload
systemctl --user start aspia-server.service
podman healthcheck run aspia-server
```

Файл юнита тот же, что и при установке на всю систему. Образы хранятся отдельно для каждого пользователя: собирайте или скачивайте их от имени этого пользователя. Все порты
выше 1024, поэтому sysctl настраивать не нужно. `PUID`/`PGID` не нужны (root в контейнере — это ваш пользователь), и под Podman
они не проверялись. **На Podman 4.x контейнер rootless не видит реальные адреса клиентов:
прочитайте раздел 4.**

## 4. Сеть: опубликованные порты или `Network=host`

Юнит публикует порты один к одному (порт на сервере = порт в контейнере) через `PublishPort=`: Relay сообщает
каждому клиенту собственный порт, поэтому `9070:8070` нарушил бы соединения через Relay. Порт 8063 (Router — Relay)
не публикуется.

| Вариант | Адрес клиента, который видит Router | Что использовать |
|---|---|---|
| На всю систему (root) | Реальный адрес. | Опубликованные порты. |
| Rootless, Podman 5.x (pasta; `podman info --format '{{.Host.RootlessNetworkCmd}}'` выводит `pasta`) | Реальный адрес для клиентов на других машинах. | Опубликованные порты. |
| Rootless, Podman 4.x (slirp4netns) | **`10.0.2.100` для каждого клиента.** | `Network=host`. |

Network=host открывает 8063 на всех интерфейсах, поэтому как вариант по умолчанию он небезопасен.

Из-за общего адреса не работают списки разрешённых адресов (`ASPIA_ROUTER_CLIENT_ALLOWED_IPS`, `ASPIA_ROUTER_HOST_ALLOWED_IPS`:
все клиенты выглядят одинаково), все клиенты делят общее ограничение частоты запросов Router для одного адреса, а
встроенный сервер STUN отвечает `10.0.2.100`. Замеры: `docs/dev/UPSTREAM-3.x-NOTES.md`, раздел 18.

### Network=host

В `aspia-server.container` удалите строки `PublishPort=` и раскомментируйте две помеченные строки
(`Network=host` и `Environment=ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1`). Затем примените изменения:

```shell
sudo systemctl daemon-reload && sudo systemctl restart aspia-server.service    # rootless: systemctl --user ...
```

Вторая строка важна: без списка разрешённых адресов для Relay любой, кто может подключиться к 8063, сможет зарегистрироваться как Relay (Router принимает до пяти).
`ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1` пропускает только Relay внутри этого контейнера (проверено на 4.9.3:
подключение к 8063 с другой машины отклоняется, а Relay подключается). Если вы задаёте эту переменную ещё и
в `aspia-server.env`, укажите в обоих местах одно и то же значение. Откройте в межсетевом экране те же порты, что и для опубликованных
портов (раздел 7). Чтобы вернуться, восстановите строки `PublishPort=` из
`podman/aspia-server.container` и закомментируйте эти две строки.

## 5. Тома: именованные (по умолчанию) или каталоги на сервере

По умолчанию используются два **именованных тома**, которые создают два файла `.volume`; они называются `systemd-aspia-config` и
`systemd-aspia-data` (`podman volume ls`). Для root и для rootless они работают одинаково, без настройки SELinux и
прав владельца.

```shell
sudo podman volume inspect systemd-aspia-config --format '{{.Mountpoint}}'   # где файлы лежат на сервере
sudo podman volume export systemd-aspia-config > aspia-config-backup.tar     # резервная копия ключей и конфигурации
```

**Другой вариант: каталоги на сервере.** Создайте их, удалите два файла `.volume` и замените две строки
`Volume=` в юните:

```ini
Volume=/var/lib/aspia-server/config:/etc/aspia:Z
Volume=/var/lib/aspia-server/data:/var/lib/aspia:Z
```

```shell
sudo install -d /var/lib/aspia-server/config /var/lib/aspia-server/data
```

`:Z` нужен для SELinux (режим enforcing на RHEL, AlmaLinux, Rocky, Fedora): он размечает каталог для этого контейнера,
а без него доступ запрещён. Там, где SELinux выключен, он безвреден. Проверяли без SELinux, поэтому действие
самого `:Z` не проверялось. Для rootless используйте каталоги в домашнем каталоге пользователя.

## 6. Конфигурация

Измените `aspia-server.env` (он лежит рядом с файлом `.container`), затем выполните `sudo systemctl restart aspia-server.service`
(rootless: `systemctl --user restart ...`). Все переменные и их значения по умолчанию описаны в таблицах
[Порты](../docs/README.ru.md#порты) и [Переменные окружения](../docs/README.ru.md#переменные-окружения) основного README.
Правила оттуда действуют без изменений.

Этот файл читает сам Podman, а не systemd: одна строка `VAR=value` на переменную, без кавычек и без комментариев в конце строки.
Для изменённой переменной порта нужна соответствующая строка `PublishPort=` (см. комментарии в юните).

## 7. Межсетевой экран

Откройте порты, которые нужны программам Client и Host. Порт 8060 нужен только для Host из Aspia 2.x. Порт 8063 не открывайте.

```shell
# firewalld (RHEL, AlmaLinux, Rocky, Fedora)
sudo firewall-cmd --permanent --add-port=8060-8062/tcp --add-port=8070/tcp --add-port=8065/udp
sudo firewall-cmd --reload

# ufw (Debian, Ubuntu)
sudo ufw allow 8060:8062/tcp
sudo ufw allow 8070/tcp
sudo ufw allow 8065/udp
```

Эти правила не проверялись. Опубликованные порты контейнера, запущенного от root, пробрасываются собственными правилами
межсетевого экрана Podman и могут быть доступны, даже если межсетевой экран сервера считает их закрытыми (как и с Docker).

## 8. Обновление (вручную, когда вы решите)

В юните нет метки `io.containers.autoupdate`; не включайте для него `podman-auto-update.timer`.

1. Прочитайте примечания к выпуску и сделайте резервную копию томов (раздел 5) или каталогов.
2. Измените тег (или дайджест) в строке `Image=`, например `3.0.21` на следующую версию. При локальной
   сборке сначала соберите новый образ.
3. `sudo systemctl daemon-reload`
4. `sudo systemctl restart aspia-server.service`

Rootless: то же самое без `sudo` и с `systemctl --user ...`. Файлы лежат в `~/.config/containers/systemd/`,
а не в `/etc/containers/systemd/`. При первом запуске нового образа база данных может быть преобразована; см. основной README, раздел [Обновление](../docs/README.ru.md#обновление).
Чтобы откатиться, укажите в юните старый тег и повторите шаги 3 и 4 (данные могут не откатиться вместе с версией, поэтому
нужен шаг 1). Ненужный старый образ удалите командой `podman image rm`.

## 9. Старый Podman: без Quadlet (запасной вариант)

Podman 4.4 и более ранние версии не могут использовать этот юнит: ключам проверки состояния нужен 4.5 (сам Quadlet появился в 4.4). На Debian 12
(Podman 4.3), Ubuntu 22.04 (3.4) и RHEL 8 до 8.10 используйте `podman run` от root, а затем пусть Podman создаст юнит systemd. В последней строке замените `<owner>` на аккаунт, который публикует образ (раздел 1; локальная
сборка на этих версиях невозможна). Вместо этого можно использовать образ, собранный в Docker и перенесённый командой `docker save | podman load`.

```shell
sudo install -d /etc/aspia-server
sudo install -m 0644 podman/aspia-server.env.example /etc/aspia-server/aspia-server.env
sudoedit /etc/aspia-server/aspia-server.env      # укажите EXTERNAL_IP (или 'auto')
sudo podman volume create aspia-config
sudo podman volume create aspia-data
sudo podman run -d --name aspia-server --env-file /etc/aspia-server/aspia-server.env \
  -p 8060:8060 -p 8061:8061 -p 8062:8062 -p 8065:8065/udp -p 8070:8070 \
  -v aspia-config:/etc/aspia -v aspia-data:/var/lib/aspia \
  --health-cmd /usr/bin/aspia_health --health-interval 30s --health-timeout 10s \
  --health-retries 3 --health-start-period 60s \
  ghcr.io/<owner>/aspia-server:3.0.21
cd /etc/systemd/system
sudo podman generate systemd --new --files --name --restart-policy=always aspia-server
sudo podman rm -f aspia-server
sudo systemctl daemon-reload
sudo systemctl enable --now container-aspia-server.service
```

Чтобы обновить, измените тег в `/etc/systemd/system/container-aspia-server.service`, затем выполните
`sudo systemctl daemon-reload && sudo systemctl restart container-aspia-server.service`.
В новых версиях Podman команда `podman generate systemd` объявлена устаревшей в пользу Quadlet.

## 10. Устранение неполадок

- `Unit aspia-server.service not found`: выполните `systemctl daemon-reload`; если в
  юните есть синтаксическая ошибка, запустите генератор в режиме пробного прогона: `/usr/lib/systemd/system-generators/podman-system-generator --dryrun`
  (для rootless добавьте `--user`; в некоторых дистрибутивах генератор — это `/usr/libexec/podman/quadlet`).
- Запуск завершается ошибкой `image not known` или ошибкой скачивания: имени из `Image=` нет в хранилище образов этого пользователя,
  либо по этому имени образ нельзя скачать (раздел 1).
- `netavark: nftables error: unable to execute nft` (Debian 13 без рекомендуемых пакетов): установите `nftables`.
- `EXTERNAL_IP ... is not set`: без этой переменной контейнер завершается намеренно. Задайте её в `aspia-server.env`.
- Служба rootless останавливается, когда вы выходите из системы: выполните `sudo loginctl enable-linger <user>`.
- `systemctl --user` выводит «Failed to connect to bus»: вы не в сеансе входа; войдите по ssh или
  используйте `machinectl shell <user>@`.

## 11. Relay на отдельном сервере или только Router

Шаги для обеих сторон, порты и способ убедиться, что Relay зарегистрировался, описаны в основном README,
в разделе [«Запуск Relay на отдельном сервере»](../docs/README.ru.md#запуск-relay-на-отдельном-сервере). Под Podman:

**Сервер Relay.** Установите `aspia-relay.container`, `aspia-relay-config.volume` и `aspia-relay.env.example` (как
`aspia-relay.env`) так же, как файлы сервера в разделе 2 (или 3), задайте строку `Image=` (раздел 1) и укажите
в `aspia-relay.env` значения `ASPIA_RELAY_ROUTER_ADDRESS`, `ASPIA_RELAY_ROUTER_PUBLIC_KEY` (файл `relay.pub` Router) и `EXTERNAL_IP`
(первые две в примере закомментированы, поэтому раскомментируйте их; вместо ключа можно
смонтировать копию `relay.pub` в `/run/aspia/router-relay.pub` и указать этот путь в `ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE`,
как показывает закомментированная строка `Volume=` в юните; не в `/etc/aspia`). Необязательно: `ASPIA_RELAY_ROUTER_PORT`. Затем выполните `systemctl daemon-reload` и `systemctl start aspia-relay.service` (rootless:
`systemctl --user ...`). Юнит задаёт `ASPIA_ROLE=relay`, публикует только 8070/tcp и становится работоспособным, как только Relay
подключится к Router: `podman healthcheck run aspia-relay`. Откройте 8070/tcp в межсетевом экране (раздел 7); подключение
к 8063/tcp на Router исходящее.

**Сервер с Router.** Оставьте `aspia-server.container`, задайте в `aspia-server.env` `ASPIA_ROLE=router` и `ASPIA_ROUTER_RELAY_ALLOWED_IPS` (адреса ваших
Relay), добавьте в юнит `PublishPort=8063:8063/tcp` и откройте 8063/tcp только для
серверов Relay. Кроме того, закомментируйте `EXTERNAL_IP` в `aspia-server.env` (в контейнере только с Router нет Relay, и
иначе при каждом запуске в журнале появляется `WARNING: Ignored: EXTERNAL_IP`); по той же причине строку `PublishPort=8070:8070/tcp`
можно убрать из юнита. Router rootless на Podman 4.x видит все подключения как приходящие с `10.0.2.100` (раздел 4,
замерено для клиентов; опубликованный 8063 проходит через ту же пересылку), поэтому список разрешённых адресов
не может их различить: используйте root, Podman 5 или межсетевой экран.

`tests/podman.sh relay` проверяет юнит Relay (на всю систему и rootless, с Router на той же машине). Он
не проверяет ни конфигурацию только с Router под Podman, ни вариант с двумя машинами.

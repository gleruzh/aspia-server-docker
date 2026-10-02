# Glossary for translations

The agreed translations of the terms in `README.md`. Use them in every translation, so that the
same English term always becomes the same word. How to translate is described in
[TRANSLATING.md](TRANSLATING.md).

To add a language, add a column to each table below and fill in every row.

## Never translated

Write these exactly as in English, capitalised, in every language.

| Term | Meaning |
|---|---|
| Router | The Aspia Router: the server that Hosts and Clients connect to. |
| Relay | The Aspia Relay: the server that carries a session when a Client and a Host cannot connect directly. |
| Host | The Aspia Host: the program on a computer that is controlled remotely. Not a computer in general. |
| Client | The Aspia Client: the program that connects to Hosts and manages the Router. |
| Console | The Aspia Console of version 2.x, removed in 3.x. |

Also not translated: Aspia, Docker, Docker Compose, Docker Engine, Podman, Quadlet, systemd, GitHub,
GitHub Container Registry, Debian, ufw, STUN, NAT, DNS, CI, the content of code, the names
of people and accounts, and log messages quoted from the container.

Inflection: in languages with grammatical cases, the five component names are not declined when
that would change their spelling. Put a noun before them, and decline the noun (Russian: "к серверу
Router", "на сервере Router", "подключение к Router", "на компьютере с Host", "в программе Client").

## Terms

| English | Russian (`ru`) | Notes |
|---|---|---|
| server (a computer) | сервер | Never "Host". |
| machine | машина, сервер | A computer. |
| host (a computer, in "Running a Relay on a separate host") | сервер | Not the Aspia Host. |
| container | контейнер | |
| image | образ | "Docker image" = "Docker-образ". |
| tag (of an image) | тег | |
| version tag | тег версии | |
| dated tag | тег с датой | |
| digest | дайджест | |
| pin (to a version or digest) | закрепить | "pin by digest" = "закрепить по дайджесту". |
| download (a file, for example with `curl`) | скачать | Same word as for an image. |
| pull (an image) | скачать | Same word as "download": "скачать образ". The command stays `docker compose pull`. |
| publish (an image) | опубликовать | |
| publish (a port) | опубликовать | "a published port" = "опубликованный порт". |
| port | порт | |
| open to the internet | открыть для доступа из интернета | Table header: "Открыт для доступа из интернета". |
| firewall | межсетевой экран | Not "файрвол" or "брандмауэр". |
| allow-list | список разрешённых адресов | Matches the `*_ALLOWED_IPS` variables. |
| volume | том | A Docker or Podman volume. |
| directory | каталог | |
| file | файл | |
| configuration file | файл конфигурации | |
| configuration | конфигурация | |
| setting | параметр | |
| environment variable | переменная окружения | |
| default (value) | значение по умолчанию | In table headers: "По умолчанию". |
| required | обязательный | |
| database | база данных | |
| key | ключ | |
| public key | открытый ключ | |
| private key | закрытый ключ | |
| public key for Hosts | открытый ключ для Host | Quoted log text stays `Public key for hosts`. |
| public key for Relays | открытый ключ для Relay | Quoted log text stays `Public key for relays`. |
| key pair | пара ключей | |
| health check | проверка состояния | The status words `healthy`, `unhealthy` stay in English in code. |
| healthy | работоспособен | Only in prose; the status itself is `(healthy)`. |
| log | журнал | "the log of the Router" = "журнал Router". |
| log level | уровень журнала | |
| time zone | часовой пояс | |
| start, startup | запуск | |
| first start | первый запуск | |
| restart | перезапуск, перезапустить | |
| update (to a newer 3.x version) | обновление, обновить | |
| upgrade (from 2.x to 3.x) | переход с 2.x | Section title: "Переход с 2.x". Keep it distinct from "обновление". |
| migration | миграция | |
| convert (configuration, database) | преобразовать | |
| roll back, go back | откатиться, вернуться | |
| backup (noun) | резервная копия | |
| back up (verb) | сделать резервную копию | |
| restore | восстановить | |
| build (an image) | собрать | |
| local build | локальная сборка | |
| repository | репозиторий | |
| release | выпуск | "the Aspia releases" = "выпуски Aspia". |
| changelog | список изменений | |
| checksum | контрольная сумма | |
| signature | подпись | |
| role | роль | `ASPIA_ROLE` values stay in English. |
| relayed session | сеанс через Relay | |
| session | сеанс | |
| connection | подключение | |
| connect | подключиться | |
| register (a Relay with the Router) | зарегистрироваться | |
| address | адрес | |
| public address | публичный адрес | |
| subnet | подсеть | |
| user | пользователь | |
| administrator | администратор | |
| password | пароль | |
| log in, login | войти, вход | |
| two-factor authentication | двухфакторная аутентификация | |
| authenticator app | приложение-аутентификатор | |
| address book | адресная книга | |
| groups of computers | группы компьютеров | |
| management of the Router | управление Router | |
| approve (a Host) | одобрить | |
| unapproved hosts | неодобренные Host | The Client label stays "Unapproved hosts" in quotes. |
| STUN server | STUN-сервер | |
| quick start | быстрый старт | |
| requirements | требования | |
| troubleshooting | устранение неполадок | |
| symptom | признак | Table header. |
| what to do | что делать | Table header. |
| licence | лицензия | |
| credits, thanks | благодарности | |
| unofficial packaging | неофициальная сборка | |
| rootless | rootless (без прав root) | Podman term; the first use gets the explanation in parentheses. |

# Glossary for translations

The agreed translations of the terms in `README.md` and `podman/README.md`. Use them in every
translation, so that the same English term always becomes the same word. How to translate is
described in [TRANSLATING.md](TRANSLATING.md). Only terms that need a decision are listed; look up
plain words in a dictionary.

To add a language, add a column to each table below and fill in every row.

## Never translated

Write these exactly as in English, capitalised, in every language.

| Term | Meaning |
|---|---|
| Router | The Aspia program that Hosts and Clients connect to. |
| Relay | The Aspia program that carries a session when a Client and a Host cannot connect directly. |
| Host | The Aspia program on a computer that is controlled remotely. Not a computer in general. |
| Client | The Aspia program that connects to Hosts and manages the Router. |
| Console | The Aspia Console of version 2.x, removed in 3.x. |

Also not translated: Aspia, Docker, Docker Compose, Docker Engine, Podman, Quadlet, systemd, GitHub,
GitHub Container Registry, Debian, ufw, STUN, NAT, DNS, CI, the content of code (commands, variable
names, file names, paths, port numbers, configuration keys, image names and tags), log messages and
error messages quoted from the container or from Aspia (`Public key for hosts`, `ACCESS_DENIED`),
and the names of people and accounts.

Router, Relay, Host and Client are programs. A "server" is the machine that runs them.

Inflection: in languages with grammatical cases, the five program names are not declined when that
would change their spelling. Put a noun before them, and decline the noun. Russian: "к программе
Router", "подключение к Router", "на компьютере с Host", "в программе Client". Use "на сервере
Router" only for the machine, as in "On the Router server".

## Terms

| English | Russian (`ru`) | Notes |
|---|---|---|
| server (a computer) | сервер | The machine. Never "Host". |
| host (a computer, in "Running a Relay on a separate host") | сервер | Not the Aspia Host. |
| image | образ | "Docker image" = "Docker-образ". |
| tag (of an image) | тег | "version tag" = "тег версии", "dated tag" = "тег с датой". |
| digest | дайджест | |
| pin (to a version or digest) | закрепить | "pin by digest" = "закрепить по дайджесту". |
| download (a file, for example with `curl`) | скачать | Same word as for an image. |
| pull (an image) | скачать | Same word as "download": "скачать образ". The command stays `docker compose pull`. |
| publish (an image, a port) | опубликовать | "a published port" = "опубликованный порт". |
| open to the internet | открыть для доступа из интернета | Table header: "Открыт для доступа из интернета". |
| firewall | межсетевой экран | Not "файрвол" or "брандмауэр". |
| allow-list | список разрешённых адресов | Matches the `*_ALLOWED_IPS` variables. |
| volume | том | A Docker or Podman volume. |
| setting | параметр | |
| default (value) | значение по умолчанию | In table headers: "По умолчанию". |
| public key for Hosts | открытый ключ для Host | Quoted log text stays `Public key for hosts`. |
| public key for Relays | открытый ключ для Relay | Quoted log text stays `Public key for relays`. |
| health check | проверка состояния | The status words `healthy`, `unhealthy` stay in English in code. |
| healthy | работоспособен | Only in prose; the status itself is `(healthy)`. |
| log | журнал | "the log of the Router" = "журнал Router". "log level" = "уровень журнала". |
| start, startup | запуск | "first start" = "первый запуск". |
| restart | перезапуск, перезапустить | |
| update (to a newer 3.x version) | обновление, обновить | |
| upgrade (from 2.x to 3.x) | переход с 2.x | Section title: "Переход с 2.x". Keep it distinct from "обновление". |
| roll back, go back | откатиться, вернуться | |
| backup (noun) | резервная копия | "back up" (verb) = "сделать резервную копию". |
| build (an image) | собрать | "local build" = "локальная сборка". |
| release | выпуск | "the Aspia releases" = "выпуски Aspia". |
| role | роль | `ASPIA_ROLE` values stay in English. |
| session | сеанс | "relayed session" = "сеанс через Relay". |
| register (a Relay with the Router) | зарегистрироваться | |
| public address | публичный адрес | |
| log in, login | войти, вход | |
| address book | адресная книга | |
| management of the Router | управление Router | |
| approve (a Host) | одобрить | |
| unapproved hosts | неодобренные Host | The Client label stays "Unapproved hosts" in quotes. |
| symptom | признак | Table header. |
| what to do | что делать | Table header. |
| credits, thanks | благодарности | |
| unofficial packaging | неофициальная сборка | |
| rootless | rootless (без прав root) | Podman term; the first use gets the explanation in parentheses. |
| unit (systemd, Quadlet) | юнит | Declined normally: "в юните", "файл юнита". "unit systemd" = "юнит systemd". |

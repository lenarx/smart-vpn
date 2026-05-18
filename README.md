# smart-vpn

Двухуровневый VPN: клиенты подключаются к серверу AmneziaWG на российском
VPS, а тот цепной маршрутизацией пропускает не-RU трафик через зарубежный
VPS вторым туннелем AmneziaWG. RU-трафик выходит напрямую с RU VPS (так что
`gosuslugi.ru`, банки и т.п. продолжают работать с российского IP), всё
остальное уходит через IP зарубежного VPS.

```
клиенты (Keenetic / iOS / Android / ноутбук)
  │  AmneziaWG  (управляется через приложение AmneziaVPN)
  ▼
RU VPS ─┬─ напрямую ──▶ RU-сайты и RU-IP          (внешний IP = RU VPS)
        │
        └─ интерфейс `foreign` ▶ AmneziaWG → зарубежный VPS ▶ всё остальное
                                  (управляется policy-routing'ом keen-pbr)
```

## Разделение ответственности

| Компонент                                            | Кто управляет       |
|------------------------------------------------------|---------------------|
| Сервер AmneziaWG на RU VPS                           | **приложение AmneziaVPN** |
| Сервер AmneziaWG на зарубежном VPS                   | **приложение AmneziaVPN** |
| Клиентские профили для ваших устройств               | **приложение AmneziaVPN** |
| Туннель AmneziaWG RU VPS → зарубежный VPS            | **вы** (положить `.conf` в `/etc/amnezia/amneziawg/` и выполнить `awg-quick up`) |
| Установка и сборка `keen-pbr`                        | инсталлятор из этого репозитория |
| Утилиты `awg`/`awg-quick` на хосте                   | инсталлятор из этого репозитория |
| Политика селективной маршрутизации (списки, правила) | **вы** (`/etc/keen-pbr/config.json` + веб-интерфейс) |

Инсталлятор в этом репозитории намеренно минимален: он ставит инструменты и
не лезет в остальное. Никаких конфигов не генерируется, никаких сервисов
не запускается, никакие правила фаервола не добавляются. Файлы
`/etc/amnezia/amneziawg/*.conf` и `/etc/keen-pbr/config.json` — ваши.

## Требования

- **RU VPS**: Debian 12, публичный IPv4, root по SSH.
- **Зарубежный VPS**: что угодно, куда AmneziaVPN умеет разворачиваться
  (Debian/Ubuntu), находящийся вне России, лучше всего NL/DE/FI.
- **Приложение AmneziaVPN**, установленное на управляющей рабочей станции
  (macOS/Windows/Linux), с SSH-доступом к обоим VPS.

## Порядок установки

### 1. Развернуть серверы AmneziaWG на обоих VPS через приложение AmneziaVPN

Установите [AmneziaVPN](https://amnezia.org/) на свою рабочую станцию. Для
каждого VPS: *Add server* → ввести SSH-креды → выбрать протокол
**AmneziaWG** → развернуть. Дождитесь окончания; в итоге получите два
рабочих сервера AmneziaWG.

Затем сгенерируйте клиентские профили:
- **На сервере RU VPS**: по одному профилю на каждое домашнее устройство
  (Keenetic, iPhone, ноутбук). Импортируйте каждый в клиент AmneziaWG на
  соответствующем устройстве.
- **На сервере зарубежного VPS**: один профиль с именем вроде `ru-vps-client`.
  Никуда не импортируйте — сам `.conf` положите на RU VPS.

### 2. Установить инструменты на RU VPS

```bash
ssh root@RU_VPS
curl -fsSL https://raw.githubusercontent.com/lenarx/smart-vpn/main/install-ru.sh | sudo bash
```

Bootstrap клонирует репозиторий в `/opt/smart-vpn` и запускает
`ru-vps/install.sh`, который ставит через apt сборочные зависимости,
собирает `keen-pbr` из исходников (~3–5 мин при первом запуске) и
оставляет всё в выключенном и ненастроенном состоянии.

### 3. Поднять туннель RU VPS → зарубежный VPS

Скопируйте `.conf` зарубежного клиента, сгенерированный на шаге 1, на RU
VPS и импортируйте его через helper `import-awg-conf.sh`. **Не** кладите
файл напрямую в `/etc/amnezia/amneziawg/` и не запускайте `awg-quick up`
поверх него — сгенерированный AmneziaVPN профиль содержит
`AllowedIPs = 0.0.0.0/0, ::/0`, что под обычным `awg-quick` отбирает
маршрут по умолчанию у хоста и моментально кладёт SSH.

```bash
scp foreign-client.conf root@RU_VPS:/tmp/
ssh root@RU_VPS
cd /opt/smart-vpn
sudo ./ru-vps/import-awg-conf.sh /tmp/foreign-client.conf foreign
sudo systemctl enable --now awg-quick@foreign
awg show foreign                  # 'latest handshake: <a few seconds ago>'
ip -brief addr show foreign       # interface up with the subnet IP from .conf
```

Что `import-awg-conf.sh` делает с файлом перед записью:

- Вставляет `Table = off` в секцию `[Interface]`, чтобы `awg-quick` поднял
  интерфейс без правки таблицы маршрутизации (keen-pbr сам направит туда
  нужные потоки через свою таблицу policy-routing).
- Вырезает строки `DNS = ...` — этот хост является шлюзом, а не
  клиентом; угонять `/etc/resolv.conf` ему незачем.
- Вырезает пустые строки `I2..I5 = ` / `S3..S4 = `, которые текущий
  `amneziawg-tools` отбрасывает с ошибкой `Line unrecognized`.

### 4. Настроить keen-pbr

Отредактируйте `/etc/keen-pbr/config.json`. В пакете уже лежит рабочий
пример по этому пути. Обычно вам потребуется:

- Outbound типа **`"interface"`**, указывающий на интерфейс `foreign` из
  шага 3 (туда уйдёт не-RU трафик).
- Списки RU-доменов и RU-IP для прямого маршрута (хорошие источники:
  `outside-raw.lst` из itdoginfo/allow-domains для доменов,
  `ru-aggregated.zone` с ipdeny.com для CIDR-блоков).
- Catch-all правило, отправляющее всё прочее в outbound `foreign`.
- `api.listen`, привязанный к внутреннему IP, чтобы веб-интерфейс не был
  публично доступен. Подходящие варианты: IP сервера AmneziaWG на этом
  VPS (доступен только через ваш домашний клиентский туннель) либо
  `127.0.0.1` (доступен только через SSH-туннель).

Затем:

```bash
systemctl restart keen-pbr
journalctl -u keen-pbr -f
```

Веб-интерфейс на `http://<ваш-bound-адрес>:12121/`.

## Структура репозитория

```
smart-vpn/
├── README.md
├── install-ru.sh              однострочный bootstrap (клонирует репозиторий, запускает ru-vps/install.sh)
├── lib/common.sh              общие bash-хелперы
└── ru-vps/
    ├── install.sh             ставит amneziawg-tools + keen-pbr; без конфигов и сервисов
    └── import-awg-conf.sh     обезопасить + установить AmneziaVPN-овский .conf в /etc/amnezia/amneziawg/
```

## Эксплуатационные заметки

- Повторный запуск инсталлятора безопасен. Если `keen-pbr` уже в PATH —
  пересборка пропускается. Если нет — сборка переиспользует существующий
  клон в `/opt/smart-vpn/build/keen-pbr` (`git fetch` + checkout на
  `KEENPBR_REF`, по умолчанию `main`).
- **Почему `keen-pbr` собирается из исходников?** В Debian-репозитории
  upstream пока нет опубликованных пакетов. Релизный workflow триггерится
  по pattern'у тега `v-*`, но реальные теги выглядят как `v2.2.1`, поэтому
  workflow никогда не запускался. Когда это исправят, инсталлятор
  автоматически подхватит бинарь, поставленный через apt.
- **Подводный камень с bun bootstrap:** в upstream-овском
  `build-frontend.sh` стоит `curl bun.sh/install | sh`. На Debian
  `/bin/sh` — это `dash`, который ломается на `set -o pipefail` из
  установщика bun. `install_keenpbr` предварительно ставит bun через
  bash, так что upstream-овский `ensure_bun()` уходит в короткую ветку.
- Переключаетесь между `amneziawg` и обычным `wireguard` для линка
  RU→зарубежный? Просто замените `.conf` в `/etc/amnezia/amneziawg/`
  (или в `/etc/wireguard/` для обычного WG), поднимите его и
  переключите outbound keen-pbr на новый интерфейс. Повторный запуск
  инсталлятора не нужен — инструменты для обоих уже стоят.

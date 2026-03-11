# ProxyMon

Легковесный API для мониторинга и управления прокси-серверами. Управляет **Cloudflare WARP**, **Xray** и собирает системную статистику — всё через простой REST API в Docker-контейнере.

---

## Быстрый старт

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/v2as/proxymon/main/proxymon.sh) install --token=YOUR_SECRET
```

Или пошагово:

```bash
git clone https://github.com/v2as/proxymon.git /opt/proxymon
cd /opt/proxymon
./proxymon.sh install --token=YOUR_SECRET
./proxymon.sh set-cli
```

После установки API доступен по адресу `http://<ip-сервера>:5757`.

---

## CLI — `proxymon.sh`

### `install`

Установка ProxyMon: проверяет Docker, создаёт конфиг, скачивает образ, запускает контейнер.

```bash
proxymon install --token=MY_TOKEN
proxymon install                    # без авторизации (не рекомендуется)
```

### `migrate`

Миграция со старого ansible-варианта `proxyapi` на Docker-версию ProxyMon.
Останавливает старый контейнер, очищает образы, **автоматически переносит сертификаты** из `/opt/proxyapi/certs/` и настраивает TLS.

```bash
proxymon migrate --token=MY_TOKEN
```

### `update`

Скачать последний образ и перезапустить контейнер.

```bash
proxymon update
```

### `edit`

Изменить переменную окружения в `.env` и перезапустить контейнер.

```bash
proxymon edit TOKEN new_secret
proxymon edit API_PORT 8080
proxymon edit WARP_RECONNECT_CMD "warp-cli --accept-tos connect"
```

### `gen-certs`

Сгенерировать самоподписанный TLS-сертификат, сохранить в `/opt/proxymon/certs/` и прописать пути в `.env`. Полностью неинтерактивная — `openssl` вызывается с `-subj`, без диалогов.

```bash
proxymon gen-certs                              # CN=proxymon, 10 лет
proxymon gen-certs --cn=myserver.com            # свой CN
proxymon gen-certs --cn=myserver.com --days=365 # свой CN и срок
```

### `set-certs`

Установить готовые TLS-сертификаты. Копирует файлы в `/opt/proxymon/certs/`, прописывает пути в `.env` и перезапускает контейнер.

```bash
proxymon set-certs --cert=/path/to/cert.pem --key=/path/to/key.pem
```

### `set-cli`

Зарегистрировать `proxymon` как системную команду (копирует скрипт в `/usr/local/bin/proxymon`).

```bash
proxymon set-cli
```

---

## Переменные окружения

Пример конфигурации — файл `.env.example`:

```env
# Bearer-токен для авторизации API (пусто = без авторизации)
TOKEN=

# Порт API
API_PORT=5757

# TLS — пути заполняются автоматически командами gen-certs / set-certs
TLS_CERT=
TLS_KEY=

# Команда переподключения WARP
WARP_RECONNECT_CMD=warp-cli --accept-tos connect
```

| Переменная | По умолчанию | Описание |
|---|---|---|
| `TOKEN` | *(пусто)* | Bearer-токен для авторизации API. Пусто = без авторизации |
| `API_PORT` | `5757` | Порт, на котором слушает API |
| `TLS_CERT` | *(пусто)* | Путь к TLS-сертификату внутри контейнера |
| `TLS_KEY` | *(пусто)* | Путь к приватному TLS-ключу внутри контейнера |
| `WARP_RECONNECT_CMD` | `warp-cli --accept-tos connect` | Команда для переподключения WARP |

---

## TLS-сертификаты

Сертификаты хранятся в `/opt/proxymon/certs/` и монтируются в контейнер как read-only volume. Пути к файлам прописываются в `.env` автоматически при использовании команд `gen-certs` / `set-certs`.

### Генерация самоподписанного сертификата

Одна команда — создаёт файлы `cert.pem` и `key.pem` в папке `certs/`, прописывает пути в `.env`, перезапускает контейнер:

```bash
proxymon gen-certs
proxymon gen-certs --cn=myserver.com --days=365
```

### Установка готовых сертификатов

```bash
proxymon set-certs --cert=/path/to/cert.pem --key=/path/to/key.pem
```

Команда автоматически:
1. Копирует файлы в `/opt/proxymon/certs/cert.pem` и `key.pem`
2. Выставляет права `600`
3. Прописывает `TLS_CERT` и `TLS_KEY` в `.env`
4. Перезапускает контейнер с HTTPS

### Миграция с proxyapi

При выполнении `proxymon migrate` сертификаты из `/opt/proxyapi/certs/` автоматически копируются в `certs/` и пути подключаются в `.env`.

---

## API

Все эндпоинты, кроме `/health`, требуют Bearer-токен (если `TOKEN` задан):

```
Authorization: Bearer YOUR_SECRET
```

Базовый URL: `http://<ip-сервера>:5757` (или `https://` при настроенном TLS)

---

### Health

#### `GET /health`

Проверка работоспособности. Авторизация не требуется.

```json
{ "status": "ok" }
```

---

### WARP

#### `GET /warp/status`

Получить текущий статус подключения Cloudflare WARP.

**Ответ:**

```json
{
  "warp_status": "Connected",
  "raw_stdout": "...",
  "exit_code": 0
}
```

`warp_status` — `Connected`, `Disconnected` или `Error`.

---

#### `POST /warp/reconnect`

Переподключить WARP (выполняет команду из `WARP_RECONNECT_CMD`).

**Ответ:**

```json
{
  "success": true,
  "exit_code": 0,
  "stdout": "...",
  "stderr": ""
}
```

---

### Система

#### `GET /stats`

Получить использование ресурсов: CPU, RAM, диск.

**Ответ:**

```json
{
  "cpu_usage": 12.5,
  "ram_usage": 45.3,
  "ram_total_mb": 2048,
  "ram_used_mb": 928,
  "disk_usage": 31.0
}
```

---

#### `POST /system/clear-logs`

Очистить системные логи (`/var/log/syslog`, `syslog.1`, `btmp`) для освобождения места на диске.

**Ответ:**

```json
{
  "success": true,
  "exit_code": 0,
  "stdout": "",
  "stderr": ""
}
```

---

#### `POST /system/update`

Запланировать самообновление: скачивает последний образ и пересоздаёт контейнер. API будет кратковременно недоступен во время перезапуска.

**Ответ:**

```json
{
  "success": true,
  "message": "Update scheduled. Container will restart shortly.",
  "log_file": "/tmp/proxymon-update.log"
}
```

---

### Xray

#### `GET /xray/config`

Получить текущую конфигурацию Xray.

**Ответ:**

```json
{
  "success": true,
  "config": { "...": "..." }
}
```

---

#### `PUT /xray/config`

Заменить конфигурацию Xray и перезапустить сервис.

**Тело запроса** — валидный JSON (новый конфиг):

```json
{
  "inbounds": [],
  "outbounds": []
}
```

**Ответ:**

```json
{
  "success": true,
  "xray_restarted": true,
  "message": "Config updated and xray restarted"
}
```

---

#### `GET /xray/status`

Проверить, активен ли сервис Xray, и получить его версию.

**Ответ:**

```json
{
  "success": true,
  "service_active": true,
  "service_status": "active",
  "version_output": "Xray 1.8.24 (Xray, Penetrates Everything.)"
}
```

---

#### `POST /xray/version`

Установить конкретную версию Xray через официальный скрипт XTLS и перезапустить сервис.

**Тело запроса:**

```json
{ "version": "1.8.24" }
```

**Ответ:**

```json
{
  "success": true,
  "version": "1.8.24",
  "stdout": "...",
  "stderr": "",
  "exit_code": 0
}
```

---

## Примеры использования

```bash
# Проверка работоспособности
curl http://localhost:5757/health

# Системная статистика
curl -H "Authorization: Bearer MY_TOKEN" http://localhost:5757/stats

# Статус WARP
curl -H "Authorization: Bearer MY_TOKEN" http://localhost:5757/warp/status

# Переподключить WARP
curl -X POST -H "Authorization: Bearer MY_TOKEN" http://localhost:5757/warp/reconnect

# Статус Xray
curl -H "Authorization: Bearer MY_TOKEN" http://localhost:5757/xray/status

# Обновить конфигурацию Xray
curl -X PUT -H "Authorization: Bearer MY_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"inbounds":[], "outbounds":[]}' \
     http://localhost:5757/xray/config

# Установить конкретную версию Xray
curl -X POST -H "Authorization: Bearer MY_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"version":"1.8.24"}' \
     http://localhost:5757/xray/version

# Очистить системные логи
curl -X POST -H "Authorization: Bearer MY_TOKEN" http://localhost:5757/system/clear-logs

# Самообновление
curl -X POST -H "Authorization: Bearer MY_TOKEN" http://localhost:5757/system/update
```

---

## Полная автоматизация (Ansible / скрипты)

Пример установки с генерацией сертификатов — без интерактивного ввода:

```bash
export DEBIAN_FRONTEND=noninteractive

# Установка
bash <(curl -fsSL https://raw.githubusercontent.com/v2as/proxymon/main/proxymon.sh) install --token=MY_TOKEN

# Генерация самоподписанного сертификата (файлы → certs/, пути → .env)
proxymon gen-certs --cn=myserver.com

# Регистрация CLI
proxymon set-cli
```

Или с готовыми сертификатами:

```bash
export DEBIAN_FRONTEND=noninteractive

bash <(curl -fsSL https://raw.githubusercontent.com/v2as/proxymon/main/proxymon.sh) install --token=MY_TOKEN
proxymon set-certs --cert=/tmp/cert.pem --key=/tmp/key.pem
proxymon set-cli
```

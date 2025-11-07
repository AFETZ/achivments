# Achievement #2 — Линейная 3-уровневая архитектура (Клиент ↔ Веб-сервер ↔ Сервер приложений ↔ БД)

Включает:
- UML **диаграмму компонентов** и **диаграмму последовательностей** (PlantUML и Mermaid).
- Реализацию на **Python** двух сервисов (веб-сервер и сервер приложений) + простой **клиент**.
- Проверки исключительных ситуаций:
  1) **Duplicate**: если число уже поступало ранее — `409 Conflict`.
  2) **PredecessorProcessed**: если число на единицу меньше уже обработанного числа — `422 Unprocessable Entity`.

## Быстрый старт (Windows PowerShell)

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
```

Окно 1 — **сервер приложений** (порт `5001`):
```powershell
$env:DB_PATH = "$PWD\numbers.db"
$env:N_MAX   = "1000000"
python app_server.py
```

Окно 2 — **веб-сервер** (порт `5000`):
```powershell
# При необходимости активируйте venv: .\.venv\Scripts\Activate.ps1
$env:APP_SERVER_URL = "http://127.0.0.1:5001"
python web_server.py
```

Окно 3 — **клиент**:
```powershell
python client.py --n 41    # -> {"result": 42}
python client.py --n 41    # -> 409 Duplicate
python client.py --n 40    # -> 422 PredecessorProcessed
```

### Примеры `curl`
```bash
curl -s -X POST http://127.0.0.1:5000/api/increment -H "Content-Type: application/json" -d "{"n":41}"
curl -s -X POST http://127.0.0.1:5000/api/increment -H "Content-Type: application/json" -d "{"n":41}"  # повтор -> 409
curl -s -X POST http://127.0.0.1:5000/api/increment -H "Content-Type: application/json" -d "{"n":40}"  # 40 на 1 меньше уже обработанного 41 -> 422
```

## Протокол
- Запрос: `POST /api/increment` c JSON `{"n": <int>}` где `0 ≤ n ≤ N_MAX`.
- Ответ успех: `200 OK`, `{"result": n+1}`.
- Ошибки: `400` (валидация/JSON), `409 Duplicate`, `422 PredecessorProcessed`, `502 UpstreamUnavailable`.

## База данных
- SQLite: `numbers(value INTEGER PRIMARY KEY, processed_at TEXT NOT NULL)`.
- Транзакции: `BEGIN IMMEDIATE` для атомарности проверок и вставки.

## Диаграммы
- PlantUML: `diagrams/*.puml` (рендер на https://www.plantuml.com/plantuml/).
- Mermaid: `diagrams/*.mmd`.

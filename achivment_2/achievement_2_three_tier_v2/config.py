import os
from pathlib import Path

# Максимально допустимое N (включительно)
N_MAX = int(os.getenv("N_MAX", "1000000"))

# URL/порты
APP_SERVER_URL = os.getenv("APP_SERVER_URL", "http://127.0.0.1:5001")
WEB_SERVER_HOST = os.getenv("WEB_SERVER_HOST", "127.0.0.1")
WEB_SERVER_PORT = int(os.getenv("WEB_SERVER_PORT", "5000"))
APP_SERVER_HOST = os.getenv("APP_SERVER_HOST", "127.0.0.1")
APP_SERVER_PORT = int(os.getenv("APP_SERVER_PORT", "5001"))

# База данных (для сервера приложений)
DB_PATH = os.getenv("DB_PATH", str(Path("./numbers.db").resolve()))

# Логи
LOG_DIR = os.getenv("LOG_DIR", str(Path("./logs").resolve()))
Path(LOG_DIR).mkdir(parents=True, exist_ok=True)

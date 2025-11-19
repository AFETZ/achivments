from flask import Flask, request, jsonify
import sqlite3
import os
import logging
from logging.handlers import RotatingFileHandler
from datetime import datetime

from config import N_MAX, APP_SERVER_HOST, APP_SERVER_PORT, DB_PATH, LOG_DIR

app = Flask(__name__)


def setup_logging():
    log_path = os.path.join(LOG_DIR, "app_server.log")
    handler = RotatingFileHandler(log_path, maxBytes=1_000_000, backupCount=3)
    fmt = logging.Formatter("[%(asctime)s] %(levelname)s %(message)s")
    handler.setFormatter(fmt)
    app.logger.setLevel(logging.INFO)
    app.logger.addHandler(handler)


def get_db():
    """
    Соединение с SQLite:
    - timeout=0 → НЕ ждём, если база залочена;
    - busy_timeout=0 → тоже fail-fast;
    - WAL → нормальная конкуренция чтений/записей.
    """
    conn = sqlite3.connect(DB_PATH, timeout=0, isolation_level=None)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA busy_timeout=0;")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS numbers(
            value INTEGER PRIMARY KEY,
            processed_at TEXT NOT NULL
        )
        """
    )
    return conn


# Flask 3.1+: явная инициализация вместо @before_first_request
def init_app():
    setup_logging()
    # прогреваем БД, чтобы таблица точно была создана
    with get_db() as c:
        pass
    app.logger.info(f"App server started. DB_PATH={DB_PATH} N_MAX={N_MAX}")


init_app()


def validate_input(n):
    if not isinstance(n, int):
        return False, "n must be integer"
    if n < 0 or n > N_MAX:
        return False, f"n must be between 0 and {N_MAX}"
    return True, None


@app.post("/process")
def process():
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict) or "n" not in payload:
        return (
            jsonify(
                error="InvalidJSON",
                message="Body must be JSON with integer field 'n'",
            ),
            400,
        )

    n = payload.get("n")
    ok, err = validate_input(n)
    if not ok:
        return jsonify(error="ValidationError", message=err), 400

    conn = get_db()
    in_tx = False
    try:
        # --- НЕБЛОКИРУЮЩИЙ СТАРТ ТРАНЗАКЦИИ ---
        try:
            conn.execute("BEGIN IMMEDIATE")
            in_tx = True
        except sqlite3.OperationalError as e:
            # fail-fast, если база залочена другим писателем
            if "locked" in str(e).lower():
                msg = "Database is busy (locked)"
                app.logger.warning(msg)
                # 503, чтобы клиент мог сделать retry
                return jsonify(error="DbBusy", message=msg), 503
            # если ошибка другая — пробрасываем дальше, поймаем ниже
            raise

        cur = conn.cursor()

        # Исключение №1: дубликат
        cur.execute("SELECT 1 FROM numbers WHERE value = ?", (n,))
        if cur.fetchone():
            msg = f"Duplicate number received: n={n}"
            app.logger.warning(msg)
            if in_tx:
                conn.execute("ROLLBACK")
                in_tx = False
            return jsonify(error="Duplicate", message=msg), 409

        # Исключение №2: n на единицу меньше уже обработанного
        cur.execute("SELECT 1 FROM numbers WHERE value = ?", (n + 1,))
        if cur.fetchone():
            msg = f"PredecessorProcessed: n={n} but n+1 already processed"
            app.logger.warning(msg)
            if in_tx:
                conn.execute("ROLLBACK")
                in_tx = False
            return jsonify(error="PredecessorProcessed", message=msg), 422

        # Вставка числа
        cur.execute(
            "INSERT INTO numbers(value, processed_at) VALUES(?, ?)",
            (n, datetime.utcnow().isoformat(timespec="seconds") + "Z"),
        )
        conn.execute("COMMIT")
        in_tx = False
        app.logger.info(f"Processed n={n} -> result={n + 1}")
        return jsonify(result=n + 1), 200

    except sqlite3.IntegrityError:
        # на всякий случай, если кто-то успел вставить тот же n между проверкой и INSERT
        if in_tx:
            conn.execute("ROLLBACK")
            in_tx = False
        msg = f"Duplicate (integrity): n={n}"
        app.logger.warning(msg)
        return jsonify(error="Duplicate", message=msg), 409

    except Exception as e:
        if in_tx:
            conn.execute("ROLLBACK")
            in_tx = False
        app.logger.exception("Unhandled error")
        return jsonify(error="ServerError", message=str(e)), 500

    finally:
        conn.close()


if __name__ == "__main__":
    app.run(host=APP_SERVER_HOST, port=APP_SERVER_PORT)

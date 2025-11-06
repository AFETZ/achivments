from flask import Flask, request, jsonify
import requests, logging, os
from logging.handlers import RotatingFileHandler
from config import N_MAX, WEB_SERVER_HOST, WEB_SERVER_PORT, APP_SERVER_URL, LOG_DIR

app = Flask(__name__)

def setup_logging():
    log_path = os.path.join(LOG_DIR, "web_server.log")
    handler = RotatingFileHandler(log_path, maxBytes=1_000_000, backupCount=3)
    fmt = logging.Formatter("[%(asctime)s] %(levelname)s %(message)s")
    handler.setFormatter(fmt)
    app.logger.setLevel(logging.INFO)
    app.logger.addHandler(handler)

# Flask 3.1+: явная инициализация
def init_app():
    setup_logging()
    app.logger.info(f"Web server started. N_MAX={N_MAX}, APP_SERVER_URL={APP_SERVER_URL}")

init_app()

def validate_input(n):
    if not isinstance(n, int):
        return False, "n must be integer"
    if n < 0 or n > N_MAX:
        return False, f"n must be between 0 and {N_MAX}"
    return True, None

@app.post("/api/increment")
def increment():
    payload = request.get_json(silent=True)
    if not isinstance(payload, dict) or "n" not in payload:
        return jsonify(error="InvalidJSON", message="Body must be JSON with integer field 'n'"), 400
    n = payload.get("n")
    ok, err = validate_input(n)
    if not ok:
        return jsonify(error="ValidationError", message=err), 400

    try:
        resp = requests.post(f"{APP_SERVER_URL}/process", json={"n": n}, timeout=5)
        app.logger.info(f"Forwarded n={n} -> {resp.status_code}")
        return (resp.text, resp.status_code, {"Content-Type": "application/json"})
    except requests.RequestException as e:
        app.logger.exception("App server unavailable")
        return jsonify(error="UpstreamUnavailable", message=str(e)), 502

if __name__ == "__main__":
    app.run(host=WEB_SERVER_HOST, port=WEB_SERVER_PORT)

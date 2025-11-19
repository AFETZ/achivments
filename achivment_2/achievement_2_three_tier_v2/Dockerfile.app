FROM python:3.11-slim

WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

# зависимости ОС по минимуму
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

# python deps
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && pip install --no-cache-dir gunicorn

# код
COPY app_server.py config.py ./

# нерутовый пользователь
RUN useradd -u 10001 -m appuser
USER appuser

# окружение приложения
ENV DB_PATH=/data/numbers.db \
    LOG_DIR=/data/logs \
    N_MAX=1000000

EXPOSE 5001

# прод-сервер
CMD ["gunicorn", "-b", "0.0.0.0:5001", "-w", "2", "app_server:app"]

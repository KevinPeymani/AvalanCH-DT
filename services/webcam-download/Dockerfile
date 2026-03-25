FROM python:3.11-slim

WORKDIR /service

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY config ./config
COPY pyproject.toml .

RUN mkdir -p /service/data/images /service/data/meta /service/data/state

CMD ["python", "-m", "app.main"]

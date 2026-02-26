FROM python:3.10-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    gdal-bin libgdal-dev proj-bin libproj-dev libgeos-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

ENV VENV=/opt/venv
RUN python -m venv $VENV
ENV PATH="$VENV/bin:$PATH"
RUN pip install --no-cache-dir -U pip setuptools wheel

WORKDIR /app

# 1) Déps du service seulement (super pour le cache)
COPY services/avaframe/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# 2) Code du service seulement (+ libs partagées si besoin)
COPY services/avaframe/ /app/services/avaframe/
# si tu as des libs internes partagées:
COPY libs/common_utils/ /app/libs/common_utils/

# 3) Lancement
ENTRYPOINT ["python", "/app/services/avaframe/runOperational.py"]
CMD ["/data/avaParabola"]

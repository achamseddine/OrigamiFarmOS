# The Origami FarmOS API for staging (master prompt Package 6): the backend
# and its Alembic migrations, nothing else. Built from the repository root
# (deploy/staging/docker-compose.yml). Runs as an unprivileged user and
# refuses to start without FARMOS_SECRET_KEY.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv/origami/backend

COPY backend/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/app ./app
COPY backend/alembic.ini ./alembic.ini
# alembic.ini: script_location = %(here)s/../database/migrations
COPY database/migrations /srv/origami/database/migrations

RUN useradd --system --home-dir /srv/origami origami && chown -R origami /srv/origami
USER origami

EXPOSE 8000
CMD ["sh", "-c", "test -n \"$FARMOS_SECRET_KEY\" || { echo 'FARMOS_SECRET_KEY is not set' >&2; exit 1; }; exec python -m uvicorn app.main:app --host 0.0.0.0 --port 8000"]

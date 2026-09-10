# Build with: docker build --build-arg SUPERSET_VERSION=4.1.1 -t superset-poc .
# To test the upgrade later, just rebuild with a newer SUPERSET_VERSION
# (or edit the default below). Confirm the actual current release tag on
# Docker Hub / the Superset GitHub releases page rather than assuming a
# literal "latest" tag always points where you expect.

ARG SUPERSET_VERSION=4.1.1
FROM apache/superset:${SUPERSET_VERSION}

USER root

RUN apt-get update && apt-get install -y \
        pkg-config \
        default-libmysqlclient-dev \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

    RUN rm -rf \
    /app/.venv/lib/python3.10/site-packages/flask_sqlalchemy \
    /app/.venv/lib/python3.10/site-packages/Flask_SQLAlchemy-*.dist-info \
    /app/.venv/lib/python3.10/site-packages/flask_sqlalchemy-*.dist-info && \
    pip install --no-cache-dir \
    --target=/app/.venv/lib/python3.10/site-packages \
    psycopg2-binary \
    redis \
    clickhouse-connect \
    mysqlclient \
    "apache-superset[fastmcp]" \
    "flask-sqlalchemy==3.0.5"

USER superset

FROM python:3.12.11-alpine

RUN pip install --no-cache-dir psycopg2-binary==2.9.10

WORKDIR /app
COPY demo-service.py /app/demo-service.py

USER 10001:10001
CMD ["python", "/app/demo-service.py"]

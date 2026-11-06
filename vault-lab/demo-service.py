import json
import os
import time

import psycopg2


credentials_path = "/secrets/db.json"

while True:
    try:
        with open(credentials_path, encoding="utf-8") as credentials_file:
            credentials = json.load(credentials_file)

        connection = psycopg2.connect(
            host="postgres",
            port=5432,
            dbname="vault_demo",
            user=credentials["username"],
            password=credentials["password"],
            connect_timeout=3,
        )
        try:
            with connection.cursor() as cursor:
                cursor.execute("SELECT current_user, COUNT(*) FROM public.poc_orders")
                username, row_count = cursor.fetchone()
        finally:
            connection.close()
        print(f"database query succeeded user={username} rows={row_count}", flush=True)
    except (OSError, KeyError, ValueError, psycopg2.Error) as error:
        sqlstate = getattr(error, "pgcode", None)
        print(
            f"database query failed error={type(error).__name__} sqlstate={sqlstate}",
            flush=True,
        )

    time.sleep(int(os.environ.get("QUERY_INTERVAL_SECONDS", "3")))

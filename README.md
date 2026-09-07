# Superset Upgrade POC — Local Environment

This is a local Docker Compose reproduction of the production Superset setup
(currently running on Nomad, pinned to `apache/superset:4.1.1`). It's meant
for an intern to test whether an upgrade from 4.1.1 to the latest stable
release is safe, before we attempt it in production.

Note: connection strings, secrets, hostnames, and the internal registry path
from the real Nomad job have been replaced with placeholders / environment
variables. Fill in your own **local, throwaway** values in `.env` — do not
point this at production infrastructure or use real credentials.

## What's in here

```
docker/
  Dockerfile            # apache/superset base image + extra DB drivers
  docker-compose.yml     # postgres + redis + superset-init + superset web
  superset_config.py     # same config shape as prod, values from env vars
  init.sh                 # db upgrade + admin user creation + superset init
  .env.example            # copy to .env and fill in local values
```

This mirrors the two Nomad tasks (`superset-init` as a prestart/one-shot job,
`superset` as the long-running web service) plus the Postgres + Redis
dependencies referenced in `superset_config.py`.

## Running it locally (starting point: 4.1.1)

```bash
cd docker
cp .env.example .env
# edit .env if you want different local passwords

docker compose up --build
```

- `superset-init` runs migrations and creates the admin user, then exits.
- `superset` starts on http://localhost:8088 (default admin creds from `.env`).

## Testing the upgrade to the latest version

1. Check Docker Hub / the Superset GitHub releases page for the current
   latest stable tag (don't assume a literal `latest` tag is what you want —
   pin to an explicit version number for reproducibility).
2. Update `SUPERSET_VERSION` in `.env` to that version.
3. Rebuild and restart:
   ```bash
   docker compose down
   docker compose up --build
   ```
4. `superset-init` will run `superset db upgrade` again against the new
   version's migrations. Watch its logs closely for errors.
5. If the container fails to start, check the Superset changelog for that
   version range for breaking config changes (deprecated config keys,
   changed defaults, etc.) and adjust `superset_config.py` accordingly.

See `jira-tickets.md` for the full breakdown of tasks, in the order they're
meant to be worked.

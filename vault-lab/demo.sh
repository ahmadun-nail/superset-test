#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export NOMAD_DATA_DIR="$ROOT/.nomad-data"
COMPOSE=(docker compose --project-directory "$ROOT" -f "$ROOT/compose.yaml")
VAULT_TOKEN=lab-only-root-token
JOB=postgres-credential-demo

vault() {
  "${COMPOSE[@]}" exec -T -e VAULT_TOKEN="$VAULT_TOKEN" vault vault "$@"
}

wait_for_service() {
  local service="$1"
  for _ in $(seq 1 60); do
    if "${COMPOSE[@]}" exec -T "$service" sh -c 'exit 0' >/dev/null 2>&1; then
      case "$service" in
        postgres) "${COMPOSE[@]}" exec -T postgres pg_isready -U postgres -d postgres >/dev/null 2>&1 && return 0 ;;
        vault) vault status >/dev/null 2>&1 && return 0 ;;
        nomad) "${COMPOSE[@]}" exec -T nomad nomad status >/dev/null 2>&1 && return 0 ;;
      esac
    fi
    sleep 2
  done
  echo "Timed out waiting for $service. Inspect with: ${COMPOSE[*]} logs $service" >&2
  return 1
}

configure_vault() {
  if ! vault secrets list -format=json | grep -q '"database/"'; then
    vault secrets enable database
  fi
  if ! vault auth list -format=json | grep -q '"jwt-nomad/"'; then
    vault auth enable -path=jwt-nomad jwt
  fi

  vault write auth/jwt-nomad/config \
    jwks_url=http://nomad:4646/.well-known/jwks.json \
    jwt_supported_algs=RS256,EdDSA \
    default_role=nomad-postgres-demo

  vault policy write nomad-postgres-demo - <<'POLICY'
path "database/creds/demo-rotation" {
  capabilities = ["read"]
}

path "sys/leases/renew" {
  capabilities = ["update"]
}
POLICY

  vault write auth/jwt-nomad/role/nomad-postgres-demo - <<'ROLE'
{
  "role_type": "jwt",
  "bound_audiences": ["vault.io"],
  "bound_claims": {
    "nomad_namespace": "default",
    "nomad_job_id": "postgres-credential-demo"
  },
  "bound_claims_type": "string",
  "user_claim": "/nomad_job_id",
  "user_claim_json_pointer": true,
  "token_policies": ["nomad-postgres-demo"],
  "token_type": "service",
  "token_period": "1h"
}
ROLE

  vault write database/config/lab-postgres \
    plugin_name=postgresql-database-plugin \
    connection_url='postgresql://{{username}}:{{password}}@postgres:5432/vault_demo?sslmode=disable' \
    username=vault_admin \
    password=lab-only-vault-db-admin \
    password_authentication=scram-sha-256 \
    allowed_roles=app_readonly,lab-readwrite,demo-rotation

  vault write database/roles/app_readonly \
    db_name=lab-postgres \
    creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '\''{{password}}'\'' VALID UNTIL '\''{{expiration}}'\''; GRANT app_readonly_privileges TO "{{name}}";' \
    revocation_statements='DROP ROLE IF EXISTS "{{name}}";' \
    default_ttl=1h \
    max_ttl=1h

  vault write database/roles/lab-readwrite \
    db_name=lab-postgres \
    creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '\''{{password}}'\'' VALID UNTIL '\''{{expiration}}'\''; GRANT app_readwrite TO "{{name}}";' \
    revocation_statements='DROP ROLE IF EXISTS "{{name}}";' \
    default_ttl=1h \
    max_ttl=1h

  vault write database/roles/demo-rotation \
    db_name=lab-postgres \
    creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '\''{{password}}'\'' VALID UNTIL '\''{{expiration}}'\''; GRANT app_readwrite TO "{{name}}";' \
    revocation_statements='DROP ROLE IF EXISTS "{{name}}";' \
    default_ttl=2m \
    max_ttl=2m
}

job_alloc_id() {
  "${COMPOSE[@]}" exec -T nomad nomad job allocs -json "$JOB" |
    python3 -c 'import json,sys; items=json.load(sys.stdin); print(next((a["ID"] for a in items if a.get("ClientStatus") == "running"), ""))'
}

credentials_json() {
  local alloc_id="$1"
  "${COMPOSE[@]}" exec -T nomad nomad alloc exec -task=db-demo -i=false -t=false \
    "$alloc_id" cat /secrets/db.json
}

task_restarts() {
  local alloc_id="$1"
  "${COMPOSE[@]}" exec -T nomad nomad alloc status -json "$alloc_id" |
    python3 -c 'import json,sys; a=json.load(sys.stdin); print(a.get("TaskStates",{}).get("db-demo",{}).get("Restarts",0))'
}

setup() {
  mkdir -p "$NOMAD_DATA_DIR"
  "${COMPOSE[@]}" up -d postgres vault nomad
  wait_for_service postgres
  wait_for_service vault
  wait_for_service nomad
  "${COMPOSE[@]}" build demo-service
  configure_vault
  "${COMPOSE[@]}" exec -T nomad nomad job run /etc/nomad.d/postgres-demo.nomad.hcl
  echo "Lab is ready. Watch the demo with: $0 logs"
}

rotate() {
  local alloc_id before_user before_restarts current_json current_user
  alloc_id="$(job_alloc_id)"
  if [[ -z "$alloc_id" ]]; then
    echo "No running allocation found for $JOB; run '$0 setup' first." >&2
    return 1
  fi

  current_json="$(credentials_json "$alloc_id")"
  before_user="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])' <<<"$current_json")"
  before_restarts="$(task_restarts "$alloc_id")"
  echo "Waiting for the 2-minute demo credential lease to rotate (up to 4 minutes)..."

  for _ in $(seq 1 120); do
    sleep 2
    current_json="$(credentials_json "$alloc_id")"
    current_user="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])' <<<"$current_json")"
    if [[ "$current_user" != "$before_user" ]]; then
      local after_restarts
      after_restarts="$(task_restarts "$alloc_id")"
      if [[ "$before_restarts" != "$after_restarts" ]]; then
        echo "Credential changed but task restart count changed ($before_restarts -> $after_restarts)." >&2
        return 1
      fi
      echo "Credential rotated: $before_user -> $current_user"
      echo "Task restart count stayed at $after_restarts; allocation: $alloc_id"
      return 0
    fi
  done

  echo "No new credential was rendered before timeout. Inspect Nomad and Vault logs." >&2
  return 1
}

revoke_current() {
  local alloc_id current_json old_user old_lease new_json new_user exists restarts
  alloc_id="$(job_alloc_id)"
  if [[ -z "$alloc_id" ]]; then
    echo "No running allocation found for $JOB; run '$0 setup' first." >&2
    return 1
  fi

  current_json="$(credentials_json "$alloc_id")"
  old_user="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])' <<<"$current_json")"
  old_lease="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["lease_id"])' <<<"$current_json")"
  restarts="$(task_restarts "$alloc_id")"
  vault lease revoke "$old_lease"

  for _ in $(seq 1 60); do
    sleep 2
    new_json="$(credentials_json "$alloc_id")"
    new_user="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])' <<<"$new_json")"
    if [[ "$new_user" != "$old_user" ]]; then
      if ! printf '%s' "$current_json" |
        "${COMPOSE[@]}" run --rm -T --no-deps demo-service python -c '
import json
import sys
import psycopg2

credentials = json.load(sys.stdin)
try:
    psycopg2.connect(
      host="postgres",
      port=5432,
      dbname="vault_demo",
      user=credentials["username"],
      password=credentials["password"],
      connect_timeout=3,
    )
except psycopg2.Error as error:
    message = str(error).lower()
    if error.pgcode in ("28P01", "28000") or "password authentication failed" in message or (
      "role" in message and "does not exist" in message
    ):
      print("revoked login rejected by PostgreSQL")
      raise SystemExit(0)
    print(f"could not verify revoked login rejection: {type(error).__name__} sqlstate={error.pgcode}")
    raise SystemExit(1)

print("revoked login unexpectedly authenticated")
raise SystemExit(1)
'; then
        echo "PostgreSQL did not prove that the revoked login was rejected." >&2
        return 1
      fi

      exists="$("${COMPOSE[@]}" exec -T postgres psql -U postgres -d postgres \
        -v username="$old_user" -At -f - <<'SQL'
SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'username');
SQL
      )"
      if [[ "$exists" != "f" ]]; then
        echo "Vault rendered a replacement but the revoked database role still exists: $old_user" >&2
        return 1
      fi
      if [[ "$(task_restarts "$alloc_id")" != "$restarts" ]]; then
        echo "Task restarted during lease revocation; inspect Nomad task events." >&2
        return 1
      fi
      echo "Revoked login $old_user was dropped by PostgreSQL."
      echo "Template rendered $new_user; the service kept running without a task restart."
      return 0
    fi
  done

  echo "No replacement credential was rendered. Inspect Vault and Nomad logs." >&2
  return 1
}

case "${1:-}" in
  setup)
    setup
    ;;
  logs)
    "${COMPOSE[@]}" logs -f nomad vault postgres
    ;;
  status)
    "${COMPOSE[@]}" ps
    "${COMPOSE[@]}" exec -T nomad nomad job status "$JOB"
    ;;
  rotate)
    rotate
    ;;
  revoke)
    revoke_current
    ;;
  fix)
    configure_vault
    "${COMPOSE[@]}" exec -T nomad nomad job run /etc/nomad.d/postgres-demo.nomad.hcl
    echo "Vault configuration restored and the Nomad job reconciled."
    ;;
  reset)
    echo "Removing the lab containers, PostgreSQL volume, and Nomad state."
    "${COMPOSE[@]}" down --volumes
    if [[ -d "$NOMAD_DATA_DIR" ]]; then
      rm -r -- "$NOMAD_DATA_DIR"
    fi
    ;;
  *)
    echo "Usage: $0 {setup|status|logs|rotate|revoke|fix|reset}" >&2
    exit 2
    ;;
esac

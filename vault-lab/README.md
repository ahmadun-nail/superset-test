# Vault-issued PostgreSQL credentials lab

This is a disposable, loopback-only Vault/Nomad/PostgreSQL lab. It never uses
production hosts or secrets. Vault runs in dev mode with an in-memory root
token, so do not reuse these settings outside the lab.

## Requirements and one-command setup

Requirements: Linux, Docker Engine with Compose, Python 3, and enough memory
for three small containers plus the demo task. Internet access is needed for
the initial image pulls and demo image build.

From the repository root:

```bash
./vault-lab/demo.sh setup
```

The script starts PostgreSQL, Vault, and a single-node Nomad lab cluster;
builds the demo task image; configures Vault's database and JWT auth methods;
and submits the Nomad job. The Nomad client uses the local Docker socket and
host cgroup interface to run its Docker task. This gives the Nomad container
host-level privileges; use only on a disposable, trusted lab machine. The
Nomad allocation directory is bind-mounted at the same host path so Docker
tasks can see rendered templates. The Vault UI is at <http://127.0.0.1:8200>
(lab token `lab-only-root-token`); Nomad is at
<http://127.0.0.1:4646>. PostgreSQL has no published host port.

The generated credentials are short lived and stay in the Nomad allocation's
secrets directory. Do not copy them into tickets or logs.

## What is configured

* Nomad 1.10 workload identity with audience `vault.io` is exchanged through
  Vault's `jwt-nomad` auth mount. The Vault role is bound to the exact default
  namespace and demo job ID. No Vault token is put in the job specification.
* Vault's PostgreSQL database engine provisions distinct `app_readonly` and
  `lab-readwrite` dynamic roles with 1-hour default and maximum TTLs. Each
  `app_readonly` lease creates a unique PostgreSQL login that inherits
  `app_readonly_privileges`, a separate `NOLOGIN` role with SELECT-only grants.
  The database management user has `CREATEROLE` and membership-admin rights
  only for the predeclared privilege roles.
* A third `demo-rotation` role uses a 2-minute TTL to make rotation testable
  without waiting an hour. It has read-write database grants and is limited to
  this demo job by Vault policy. Do not use this abbreviated TTL for production.
* Nomad's `template` renders the dynamic login to `secrets/db.json`, owned by
  the unprivileged demo task user with mode `0400`. The task rereads that file
  and opens a fresh database connection per query, so template updates take
  effect without restarting the task. This intentionally demonstrates the
  conservative pool size of zero; a production pool needs explicit lifetime
  and credential-reload behavior.

## Rotation, revocation, and recovery demo

Follow the service output:

```bash
./vault-lab/demo.sh logs
```

Wait for the two-minute demo lease to reach its maximum and cause Vault's
template lookup to obtain the next login. The command waits for a new database
username and verifies that the Nomad task restart count did not change:

```bash
./vault-lab/demo.sh rotate
```

For the failure/recovery exercise, revoke the currently rendered lease:

```bash
./vault-lab/demo.sh revoke
```

Vault drops the old PostgreSQL role, the script verifies it is gone, and the
script verifies an attempted connection with the stale login is rejected.
Then the template obtains a replacement, and the service keeps the same task
allocation while querying with the new login. This demonstrates that revoking
a lease invalidates that database principal immediately; it does not wait for
the original TTL. The `revoke` command fails explicitly if the old login still
authenticates, the old role remains, the new credentials are not rendered, or
Nomad restarts the task.

To deliberately break and then repair Vault's role/policy wiring, the script's
`fix` command re-applies the desired configuration and reconciles the job:

```bash
./vault-lab/demo.sh fix
```

For a clean rerun, delete only this lab's data volume and start again:

```bash
./vault-lab/demo.sh reset
./vault-lab/demo.sh setup
```

`reset` deletes this lab's PostgreSQL volume and Nomad state directory. The
Compose project uses the explicitly named `vault-lab` Docker network and its
own named volume; it does not remove the root Superset POC's volumes.

## Service migration runbook

This is a reviewable staging plan, not an instruction to apply changes to a
production cluster. An engineer must adapt it to the target service, database
topology, and organization controls, and obtain mentor and service-owner
approval before rollout.

### 1. Prepare and validate

1. Inventory the service's current database grants, connection-pool behavior,
   query duration, long-running transactions, background workers, and secret
   delivery. Record the current deployment and rollback method.
2. In an isolated staging copy, create a dedicated Vault database connection
   using a Vault-only PostgreSQL management account. Restrict its network path
   to Vault and PostgreSQL. Do not use the database superuser as Vault's
   management account.
3. Configure least-privilege Vault dynamic roles (read-only and/or read-write)
   with one-hour `default_ttl` and `max_ttl`. Grant application roles only
   required schema/table/sequence privileges. Test creation, renewal,
   expiration, and explicit revocation before onboarding the service.
4. Configure Nomad's Vault integration and Vault JWT auth using the cluster's
   JWKS endpoint over verified TLS. Bind the auth role to the specific Nomad
   namespace, job ID, and single expected audience. Give its policy read
   access only to that service's `database/creds/<role>` path.

### 2. Job-spec and application changes

Add a Vault workload identity to the task and request a task-scoped Vault
token through the Nomad `vault` block. Render credentials using a Nomad
`template` block, writing them to a secrets directory with restrictive
permissions. Do not put database passwords, Vault tokens, or long-lived
management credentials in job variables or environment variables.

Configure template change handling to match the application:

* If the application rereads an atomically replaced credential file and
  establishes new connections from it, use `change_mode = "noop"` and test
  that file replacement is atomic for the chosen runtime.
* Otherwise use `change_mode = "signal"` with a supported reload signal and a
  handler that drains old connections, loads the new credentials, and
  establishes a fresh connection. A restart is a last resort and should be
  explicitly tested against the service's availability objective.
* Never assume a password update revokes already authenticated PostgreSQL
  sessions. Expired/revoked logins block new sessions; existing sessions and
  long-running transactions may remain until terminated or closed.

### 3. Connection-pool settings and expiry safety

Set the pool's maximum connection lifetime and idle lifetime below the
credential TTL, with enough margin for template delivery, retries, clock skew,
and connection establishment. For a one-hour lease, begin validation with a
maximum connection age of 45–50 minutes and an idle timeout of 5–10 minutes;
confirm the values against observed query duration and service load. On a
credential change, stop handing out connections authenticated with the old
user, drain/close those connections, and create new ones using the new file.
Use bounded retries with jitter for transient authentication failures and
alert before the remaining lease becomes critically short. Do not pin a
connection for longer than the credential's effective validity.

The correct pool settings are service-specific. If the pool cannot reload
credentials and recycle connections safely, add that capability or schedule a
controlled restart before relying on dynamic credentials.

### 4. Staged rollout and validation

1. Keep the existing credential available as a controlled rollback for the
   approved overlap window, but remove it from new deployments after cutover.
2. Deploy to one staging instance. Verify the Nomad workload identity is
   accepted, only the intended Vault path is readable, the generated PostgreSQL
   role has the expected grants, and the service can perform representative
   reads/writes.
3. Observe at least one natural renewal/rotation cycle. Confirm the application
   changes credentials and replaces pooled sessions without a task restart.
4. Revoke a generated lease. Confirm PostgreSQL denies new connections for
   that principal, the service reconnects with a new rendered login, existing
   sessions are drained or explicitly terminated as required, and alerts/logs
   identify the event without recording passwords.
5. Expand gradually with error-rate, pool-exhaustion, authentication-failure,
   lease-renewal, and database connection-count monitoring. Stop rollout if
   pool churn, transaction failures, or Vault/Nomad availability exceed the
   service's agreed thresholds.

### 5. Risks, rollback, and ownership

* Open sessions are not reliably terminated merely because a Vault lease
  expires. PostgreSQL `VALID UNTIL` is checked at authentication, not on every
  statement. Enforce a bounded pool lifetime and explicitly drain or terminate
  sessions when immediate access removal is required.
* Vault, Nomad, the JWKS endpoint, and the database must be reachable during
  credential issue/refresh. Define retry/backoff behavior and an outage policy;
  do not silently fall back to a stale or hard-coded password.
* Keep clock synchronization healthy. Ensure all cluster components use
  verified TLS and have an audited, recoverable Vault management credential.
  Plan for Vault seal/recovery, backups, policy review, and Nomad workload
  identity key rotation.
* A rollback may require redeploying the prior job spec and restoring the
  prior credential through the approved secret store. Revoke Vault-issued
  users after rollback and verify they no longer exist. Do not remove the old
  credential until the rollback window closes.
* Assign the service owner for pool/reload changes and the platform owner for
  Vault database config, policies, and Nomad auth. Record the mentor review
  and production change approval before rollout; this lab does not constitute
  that review.

## Troubleshooting

```bash
./vault-lab/demo.sh status
docker compose --project-directory vault-lab -f vault-lab/compose.yaml logs nomad vault postgres
```

If provisioning fails after editing the lab, inspect the Vault and Nomad logs.
PostgreSQL init scripts run only on a fresh data volume; use `reset` before
re-running after changing `postgres-init.sql`.

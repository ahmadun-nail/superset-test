#!/bin/bash
set -e

echo "Running superset init"
superset db upgrade

superset fab create-admin \
  --username "${ADMIN_USERNAME:-admin}" \
  --firstname "${ADMIN_FIRSTNAME:-Admin}" \
  --lastname "${ADMIN_LASTNAME:-User}" \
  --email "${ADMIN_EMAIL:-admin@example.com}" \
  --password "${ADMIN_PASSWORD:-changeme}" || true

superset init

echo "Superset init finished"

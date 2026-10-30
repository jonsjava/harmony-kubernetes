#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Derived from Harmony's self-host/bootstrap.sh (https://github.com/y4my4my4m/harmony),
# Copyright (C) 2024-present y4my4my4m and the Harmony contributors. See NOTICE.
# Harmony database bootstrap for Kubernetes: a port of upstream
# self-host/bootstrap.sh that talks to Postgres over TCP instead of
# `docker exec`. Applies db_schema/migrations in version order, recorded in
# supabase_migrations.schema_migrations (the Supabase CLI's ledger), then sets
# the upload ceiling, the storage origin, the harmony_listener role, the
# instance name/domain on a new database and the registration policy.
#
# Environment: PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PGSSLMODE (libpq),
# MIGRATIONS_DIR, SCHEMA_WAIT, LISTENER_PASSWORD, DOMAIN, INSTANCE_NAME,
# STORAGE_ORIGIN, FILE_SIZE_LIMIT, REGISTRATION.
set -eu

info() { printf '==> %s\n' "$*"; }
ok()   { printf ' ✓ %s\n' "$*"; }
warn() { printf ' ! %s\n' "$*" >&2; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

export PGOPTIONS='-c client_min_messages=warning'
MIGRATIONS_DIR="${MIGRATIONS_DIR:-/src/db_schema/migrations}"
SCHEMA_WAIT="${SCHEMA_WAIT:-300}"

psql_q() { psql -X -v ON_ERROR_STOP=1 -q "$@"; }
psql_t() { psql -X -v ON_ERROR_STOP=1 -qtA "$@"; }

ls "$MIGRATIONS_DIR"/*.sql >/dev/null 2>&1 || die "no migrations in $MIGRATIONS_DIR"

# --- Postgres reachable ---------------------------------------------------------
info "Waiting for Postgres at $PGHOST:${PGPORT:-5432}..."
i=0
until psql_t -c 'SELECT 1' >/dev/null 2>&1; do
	i=$((i + 1))
	[ "$i" -lt 90 ] || die "Postgres did not answer within 180 s as $PGUSER@$PGHOST/$PGDATABASE"
	sleep 2
done
info "Connected as $PGUSER"

# --- Supabase's own schemas -----------------------------------------------------
# Realtime, storage-api and GoTrue create these through their own migrations;
# Harmony's migrations build on them (see upstream bootstrap.sh).
schema_missing() {
	psql_t <<'SQL' 2>/dev/null | tr -d '\n'
SELECT concat_ws(', ',
	CASE WHEN to_regclass('realtime.messages') IS NULL THEN 'realtime.messages'
	     WHEN (SELECT relkind FROM pg_class WHERE oid = to_regclass('realtime.messages')) <> 'p'
	     THEN 'partitioned realtime.messages' END,
	CASE WHEN to_regprocedure('realtime.send(jsonb,text,text,boolean)') IS NULL THEN 'realtime.send' END,
	CASE WHEN NOT EXISTS (SELECT 1 FROM pg_attribute
	                       WHERE attrelid = to_regclass('storage.buckets')
	                         AND attname = 'allowed_mime_types' AND NOT attisdropped)
	     THEN 'storage.buckets.allowed_mime_types' END,
	CASE WHEN to_regclass('auth.sessions') IS NULL THEN 'auth.sessions' END,
	CASE WHEN to_regclass('auth.mfa_factors') IS NULL THEN 'auth.mfa_factors' END);
SQL
}
start=$(date +%s)
missing="$(schema_missing)" || missing="?"
if [ -n "$missing" ]; then
	info "Waiting for the Realtime, Storage and Auth schemas (up to $SCHEMA_WAIT s)..."
	while [ -n "$missing" ]; do
		[ $(( $(date +%s) - start )) -lt "$SCHEMA_WAIT" ] ||
			die "still missing after $SCHEMA_WAIT s: $missing. Realtime creates realtime.* once it is healthy (its tenant is used), storage-api adds the bucket columns at start, GoTrue the auth tables."
		sleep 3
		missing="$(schema_missing)" || missing="?"
	done
fi

# --- migrations -----------------------------------------------------------------
info "Applying migrations..."
psql_q <<'SQL'
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
	version text PRIMARY KEY,
	name text,
	statements text[]
);
SQL
applied="$(psql_t -c 'SELECT version FROM supabase_migrations.schema_migrations')"
pending=0
for f in "$MIGRATIONS_DIR"/*.sql; do
	fname="$(basename "$f")"
	version="$(printf '%s' "$fname" | cut -c1-14)"
	name="$(printf '%s' "$fname" | cut -c16-)"; name="${name%.sql}"
	if printf '%s\n' "$applied" | grep -qxF "$version"; then continue; fi
	pending=$((pending + 1))
	if psql_q -f "$f" >/tmp/mig_out 2>&1; then
		psql_q -v version="$version" -v name="$name" <<'SQL'
INSERT INTO supabase_migrations.schema_migrations (version, name)
VALUES (:'version', :'name') ON CONFLICT (version) DO NOTHING;
SQL
		printf '  applied %s\n' "$fname"
	else
		printf 'Error: %s failed. It was not recorded; later migrations were skipped.\n' "$fname" >&2
		grep -E 'ERROR|FATAL' /tmp/mig_out | head -5 >&2 || true
		die "migration failed - database is at the last migration that succeeded"
	fi
done
if [ "$pending" -eq 0 ]; then ok "Migrations up to date"; else ok "Applied $pending migration(s)"; fi

# --- upload ceiling -------------------------------------------------------------
ceiling="${FILE_SIZE_LIMIT:-52428800}"
if printf '%s' "$ceiling" | grep -Eq '^[0-9]{1,15}$'; then
	psql_q -v bytes="$ceiling" <<'SQL' && ok "Upload ceiling: $ceiling bytes" || warn "upload ceiling not written"
INSERT INTO public.instance_config (config_key, config_value, description)
VALUES ('upload_ceiling_bytes', to_jsonb(:'bytes'::bigint), 'storage-api FILE_SIZE_LIMIT, bytes; set by the instance operator')
ON CONFLICT (config_key) DO UPDATE SET config_value = EXCLUDED.config_value, updated_at = now()
 WHERE instance_config.config_value IS DISTINCT FROM EXCLUDED.config_value;
SQL
else
	warn "FILE_SIZE_LIMIT is not a number of bytes; upload ceiling left as it is"
fi

# --- storage origin -------------------------------------------------------------
if [ -n "${STORAGE_ORIGIN:-}" ]; then
	psql_q -v origin="$STORAGE_ORIGIN" <<'SQL' && ok "Storage origin: $STORAGE_ORIGIN" || warn "storage origin not written"
INSERT INTO public.instance_config (config_key, config_value, description)
VALUES ('storage_origin', to_jsonb(:'origin'::text), 'Public origin of storage, as clients build object URLs (https://db.example.com). Sticker and emoji upload URLs must start with it; empty accepts any http(s) origin.')
ON CONFLICT (config_key) DO UPDATE SET config_value = EXCLUDED.config_value, updated_at = now()
 WHERE instance_config.config_value IS DISTINCT FROM EXCLUDED.config_value;
SQL
fi

# --- least-privilege listener role ------------------------------------------------
if [ -n "${LISTENER_PASSWORD:-}" ]; then
	psql_q -v pw="$LISTENER_PASSWORD" -v db="$PGDATABASE" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'harmony_listener') THEN
    CREATE ROLE harmony_listener WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
  END IF;
END
$$;
ALTER ROLE harmony_listener WITH PASSWORD :'pw';
GRANT CONNECT ON DATABASE :"db" TO harmony_listener;
SQL
	ok "Listener role ready"
fi

# --- instance name and domain (new database only) --------------------------------
if [ -n "${DOMAIN:-}" ]; then
	current="$(psql_t -v domain="$DOMAIN" -v name="${INSTANCE_NAME:-Harmony}" <<'SQL' | tail -1
BEGIN;
UPDATE public.instance_config
   SET config_value = to_jsonb(:'name'::text), updated_at = now()
 WHERE config_key = 'instance_name'
   AND EXISTS (SELECT 1 FROM public.instance_config
                WHERE config_key = 'domain' AND config_value = '"localhost"'::jsonb);
UPDATE public.instance_config
   SET config_value = to_jsonb(:'domain'::text), updated_at = now()
 WHERE config_key = 'domain' AND config_value = '"localhost"'::jsonb;
COMMIT;
SELECT config_value #>> '{}' FROM public.instance_config WHERE config_key = 'domain';
SQL
)" || die "could not set the instance name and domain in public.instance_config"
	if [ "$current" = "$DOMAIN" ]; then
		ok "Instance domain: $current"
	elif [ "$current" = localhost ]; then
		die "instance_config domain is still 'localhost'; $PGUSER cannot write public.instance_config"
	else
		info "instance_config domain is '$current' (set in the admin panel); harmony.domain is '$DOMAIN', left as is"
	fi
fi

# --- registration -----------------------------------------------------------------
# Never opened before a local admin exists: the first local profile becomes admin.
if [ -n "${REGISTRATION:-}" ]; then
	admins="$(psql_t -c 'SELECT count(*) FROM public.profiles WHERE is_local AND is_admin')"
	case "$REGISTRATION" in
		open) open_reg=true ;;
		*) open_reg=false ;;
	esac
	if [ "$open_reg" = true ] && [ "${admins:-0}" = 0 ]; then
		info "Registration stays as it is until an admin exists (admin.create, or a later upgrade)"
	else
		psql_q -c "UPDATE public.instance_config SET config_value = '$open_reg'::jsonb, updated_at = now() WHERE config_key = 'open_registration' AND config_value IS DISTINCT FROM '$open_reg'::jsonb"
		ok "Registration: $REGISTRATION (open_registration=$open_reg)"
	fi
fi

# --- app.settings.jwt_* -----------------------------------------------------------
# Supabase's db init may store the JWT secret as a database default every
# session can read; no Harmony function needs it. Resetting needs a superuser.
readers="$(psql_t -c "SELECT string_agg(DISTINCT n.nspname || '.' || p.proname, ', ')
	FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
	WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
	  AND p.prosrc LIKE '%app.settings.jwt_%'")" || readers="?"
jwt_set="$(psql_t -c "SELECT count(*) FROM pg_db_role_setting s
	JOIN pg_database d ON d.oid = s.setdatabase
	WHERE d.datname = current_database() AND s.setrole = 0
	  AND EXISTS (SELECT 1 FROM unnest(s.setconfig) c WHERE c LIKE 'app.settings.jwt\_%')")" || jwt_set=0
if [ "$jwt_set" != 0 ]; then
	if [ -n "$readers" ]; then
		warn "app.settings.jwt_secret kept: read by $readers"
	elif psql_q -v db="$PGDATABASE" >/dev/null 2>/tmp/jwt_err <<'SQL'
ALTER DATABASE :"db" RESET "app.settings.jwt_secret";
ALTER DATABASE :"db" RESET "app.settings.jwt_exp";
SQL
	then
		ok "Removed the JWT secret from the database defaults"
	else
		warn "app.settings.jwt_secret not reset ($(head -1 /tmp/jwt_err)); as a superuser: ALTER DATABASE $PGDATABASE RESET \"app.settings.jwt_secret\""
	fi
fi

psql_q -c "NOTIFY pgrst, 'reload schema';" || warn "PostgREST schema reload not sent; restart Supabase rest if the API serves an old schema"
ok "Bootstrap complete."

#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# sign_jwt is derived from Harmony's self-host/configure.sh
# (https://github.com/y4my4my4m/harmony), Copyright (C) 2024-present y4my4my4m
# and the Harmony contributors. See NOTICE.
# Creates the Secrets a Supabase release (supabase-community/supabase-kubernetes)
# and the Harmony chart share, in one namespace:
#
#   supabase-jwt     secret, anonKey, serviceKey   (JWT secret + keys signed with it)
#   supabase-db      password, database            (Postgres password)
#   harmony-admin    password                      (first admin account)
#
# The keys are HS256 JWTs for the anon and service_role roles, valid 10 years,
# signed as upstream self-host/configure.sh signs them.
#
# Usage: scripts/generate-secrets.sh [namespace]      (default: harmony)
# Prints the admin password once. Existing Secrets are left untouched.
set -euo pipefail
NS="${1:-harmony}"
command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }
sign_jwt() {
	local role="$1" secret="$2" now header payload body sig
	now=$(date +%s)
	header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
	payload=$(printf '{"role":"%s","iss":"supabase","iat":%d,"exp":%d}' "$role" "$now" $((now + 315360000)) | b64url)
	body="$header.$payload"
	sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" -binary | b64url)
	printf '%s.%s' "$body" "$sig"
}
exists() { kubectl -n "$NS" get secret "$1" >/dev/null 2>&1; }

kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

if exists supabase-jwt; then
	echo "supabase-jwt exists; kept"
else
	jwt_secret="$(openssl rand -hex 32)"
	kubectl -n "$NS" create secret generic supabase-jwt \
		--from-literal=secret="$jwt_secret" \
		--from-literal=anonKey="$(sign_jwt anon "$jwt_secret")" \
		--from-literal=serviceKey="$(sign_jwt service_role "$jwt_secret")"
fi

if exists supabase-db; then
	echo "supabase-db exists; kept"
else
	kubectl -n "$NS" create secret generic supabase-db \
		--from-literal=password="$(openssl rand -hex 24)" \
		--from-literal=database=postgres
fi

if exists harmony-admin; then
	echo "harmony-admin exists; kept"
else
	pw="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
	kubectl -n "$NS" create secret generic harmony-admin --from-literal=password="$pw"
	echo
	echo "Admin password (shown once; also in Secret harmony-admin): $pw"
fi

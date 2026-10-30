{{/* =========================================================================
Names and labels
========================================================================= */}}
{{- define "harmony.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "harmony.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Name of a component's objects: harmony.componentName (dict "root" $ "component" "web") */}}
{{- define "harmony.componentName" -}}
{{- printf "%s-%s" (include "harmony.fullname" .root | trunc (int (sub 62 (len .component)))) .component | trimSuffix "-" }}
{{- end }}

{{- define "harmony.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "harmony.labels" -}}
helm.sh/chart: {{ include "harmony.chart" .root }}
{{ include "harmony.selectorLabels" . }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: harmony
{{- with .root.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "harmony.selectorLabels" -}}
app.kubernetes.io/name: {{ include "harmony.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- if .component }}
app.kubernetes.io/component: {{ .component }}
{{- end }}
{{- end }}

{{- define "harmony.annotations" -}}
{{- with .Values.commonAnnotations }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{- define "harmony.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "harmony.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* =========================================================================
Instance values
========================================================================= */}}
{{- define "harmony.domain" -}}
{{- required "harmony.domain is required (public domain of the instance, no scheme)" .Values.harmony.domain | lower | trimPrefix "https://" | trimSuffix "/" }}
{{- end }}

{{- define "harmony.dbDomain" -}}
{{- default (printf "db.%s" (include "harmony.domain" .)) .Values.harmony.dbDomain | lower }}
{{- end }}

{{- define "harmony.liveDomain" -}}
{{- default (printf "live.%s" (include "harmony.domain" .)) .Values.harmony.liveDomain | lower }}
{{- end }}

{{- define "harmony.appUrl" -}}
{{- printf "https://%s" (include "harmony.domain" .) }}
{{- end }}

{{- define "harmony.supabasePublicUrl" -}}
{{- default (printf "https://%s" (include "harmony.dbDomain" .)) .Values.supabase.publicUrl | trimSuffix "/" }}
{{- end }}

{{- define "harmony.supabaseInternalUrl" -}}
{{- required "supabase.internalUrl is required (Kong as pods reach it, e.g. http://supabase-supabase-kong.supabase.svc:8000)" .Values.supabase.internalUrl | trimSuffix "/" }}
{{- end }}

{{/* Upstream for Caddy and nginx: host:port of Kong, scheme kept separately. */}}
{{- define "harmony.kongHostPort" -}}
{{- $u := urlParse (include "harmony.supabaseInternalUrl" .) }}
{{- if contains ":" $u.host }}{{ $u.host }}{{ else if eq $u.scheme "https" }}{{ $u.host }}:443{{ else }}{{ $u.host }}:80{{ end }}
{{- end }}

{{- define "harmony.kongScheme" -}}
{{- (urlParse (include "harmony.supabaseInternalUrl" .)).scheme | default "http" }}
{{- end }}

{{/* Image of one of Harmony's own images: harmony.image (dict "root" $ "repository" "harmony-web") */}}
{{- define "harmony.image" -}}
{{- $tag := default .root.Chart.AppVersion .root.Values.image.tag }}
{{- printf "%s/%s:%s" (.root.Values.image.registry | trimSuffix "/") .repository $tag }}
{{- end }}

{{- define "harmony.thirdPartyImage" -}}
{{- printf "%s:%s" .repository (toString .tag) }}
{{- end }}

{{/* =========================================================================
Secrets
========================================================================= */}}
{{- define "harmony.secretName" -}}
{{- default (include "harmony.componentName" (dict "root" . "component" "secrets")) .Values.secrets.existingSecret }}
{{- end }}

{{- define "harmony.supabaseSecretName" -}}
{{- default (include "harmony.componentName" (dict "root" . "component" "supabase")) .Values.supabase.existingSecret }}
{{- end }}

{{- define "harmony.dbSecretName" -}}
{{- default (include "harmony.componentName" (dict "root" . "component" "supabase")) .Values.supabase.db.existingSecret }}
{{- end }}

{{- define "harmony.dbSecretKey" -}}
{{- if .Values.supabase.db.existingSecret }}{{ .Values.supabase.db.existingSecretPasswordKey }}{{ else }}dbPassword{{ end }}
{{- end }}

{{/*
A generated secret: the value set in values.yaml, else the one already in the
release's Secret, else a new random one.
harmony.secretValue (dict "root" $ "key" "REDIS_PASSWORD" "value" .Values.secrets.redisPassword "generate" "...")
*/}}
{{- define "harmony.secretValue" -}}
{{- if .value }}
{{- .value }}
{{- else }}
{{- $existing := lookup "v1" "Secret" .root.Release.Namespace (include "harmony.secretName" .root) }}
{{- if and $existing $existing.data (hasKey $existing.data .key) }}
{{- index $existing.data .key | b64dec }}
{{- else }}
{{- .generate }}
{{- end }}
{{- end }}
{{- end }}

{{/* =========================================================================
Service names and addresses
========================================================================= */}}
{{- define "harmony.redisHost" -}}
{{- if .Values.redis.enabled }}{{ include "harmony.componentName" (dict "root" . "component" "redis") }}{{ else }}{{ required "redis.external.host is required with redis.enabled=false" .Values.redis.external.host }}{{ end }}
{{- end }}

{{- define "harmony.redisPort" -}}
{{- if .Values.redis.enabled }}6379{{ else }}{{ .Values.redis.external.port }}{{ end }}
{{- end }}

{{/* REDIS_URL built in the pod from $(REDIS_PASSWORD) (declared before it). */}}
{{- define "harmony.redisUrl" -}}
{{- $scheme := ternary "rediss" "redis" (and (not .Values.redis.enabled) .Values.redis.external.tls) }}
{{- printf "%s://:$(REDIS_PASSWORD)@%s:%s" $scheme (include "harmony.redisHost" .) (include "harmony.redisPort" .) }}
{{- end }}

{{- define "harmony.listenerUrl" -}}
{{- $db := .Values.supabase.db }}
{{- printf "postgresql://harmony_listener:$(LISTENER_PASSWORD)@%s:%v/%s?sslmode=%s" (required "supabase.db.host is required" $db.host) $db.port $db.database $db.sslmode }}
{{- end }}

{{/* =========================================================================
Shared pod pieces
========================================================================= */}}
{{- define "harmony.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/* nodeSelector/tolerations/affinity/topologySpreadConstraints of a component's values */}}
{{- define "harmony.scheduling" -}}
{{- with .nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .topologySpreadConstraints }}
topologySpreadConstraints:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/* Supabase keys as env */}}
{{- define "harmony.env.supabaseKeys" -}}
- name: SUPABASE_ANON_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "harmony.supabaseSecretName" . }}
      key: {{ .Values.supabase.existingSecretKeys.anonKey }}
- name: SUPABASE_SERVICE_ROLE_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "harmony.supabaseSecretName" . }}
      key: {{ .Values.supabase.existingSecretKeys.serviceRoleKey }}
{{- end }}

{{/* One env var from the chart's Secret: harmony.env.secret (dict "root" $ "name" "X" "key" "X" "optional" true) */}}
{{- define "harmony.env.secret" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "harmony.secretName" .root }}
      key: {{ default .name .key }}
      {{- if .optional }}
      optional: true
      {{- end }}
{{- end }}

{{/* =========================================================================
Validation
========================================================================= */}}
{{- define "harmony.validate" -}}
{{- $_ := include "harmony.domain" . }}
{{- $_ := include "harmony.supabaseInternalUrl" . }}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$" (include "harmony.domain" .)) }}
{{- fail (printf "harmony.domain %q is not a domain name" .Values.harmony.domain) }}
{{- end }}
{{- if not (regexMatch "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$" (.Values.harmony.adminEmail | default "" | trimPrefix "mailto:")) }}
{{- fail "harmony.adminEmail is required (VAPID contact address)" }}
{{- end }}
{{- if and (not .Values.supabase.existingSecret) (or (not .Values.supabase.anonKey) (not .Values.supabase.serviceRoleKey)) }}
{{- fail "set supabase.anonKey and supabase.serviceRoleKey, or supabase.existingSecret" }}
{{- end }}
{{- if .Values.migrations.enabled }}
{{- if not .Values.supabase.db.host }}
{{- fail "supabase.db.host is required (Postgres for the migrations job and the worker's listener)" }}
{{- end }}
{{- if and (not .Values.supabase.db.existingSecret) (not .Values.supabase.db.password) }}
{{- fail "set supabase.db.password or supabase.db.existingSecret" }}
{{- end }}
{{- end }}
{{- if and .Values.discordBridge.enabled (not .Values.botGateway.enabled) }}
{{- fail "discordBridge.enabled needs botGateway.enabled" }}
{{- end }}
{{- if not (has (.Values.harmony.registration | default "") (list "" "open" "invite" "closed")) }}
{{- fail "harmony.registration must be open, invite, closed or empty" }}
{{- end }}
{{- if .Values.admin.create }}
{{- if or (not .Values.admin.email) (not .Values.admin.username) (not .Values.admin.existingSecret) }}
{{- fail "admin.create needs admin.email, admin.username and admin.existingSecret (key: password)" }}
{{- end }}
{{- if not (regexMatch "^[a-z0-9_]{3,24}$" .Values.admin.username) }}
{{- fail "admin.username must be 3-24 characters of a-z, 0-9 and _" }}
{{- end }}
{{- end }}
{{- end }}

{{/* =========================================================================
KEDA ScaledObject
harmony.scaledObject (dict "root" $ "component" "web" "kind" "Deployment" "autoscaling" .Values.web.autoscaling "triggers" (list ...))
========================================================================= */}}
{{- define "harmony.scaledObject" -}}
{{- $a := .autoscaling }}
{{- $name := include "harmony.componentName" (dict "root" .root "component" .component) }}
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: {{ $name }}
  labels:
    {{- include "harmony.labels" (dict "root" .root "component" .component) | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: {{ default "Deployment" .kind }}
    name: {{ $name }}
  minReplicaCount: {{ $a.minReplicas }}
  maxReplicaCount: {{ $a.maxReplicas }}
  pollingInterval: {{ .root.Values.keda.pollingInterval }}
  cooldownPeriod: {{ .root.Values.keda.cooldownPeriod }}
  {{- with .root.Values.keda.horizontalPodAutoscalerConfig }}
  advanced:
    horizontalPodAutoscalerConfig:
      {{- toYaml . | nindent 6 }}
  {{- end }}
  triggers:
    {{- if $a.cpu }}
    - type: cpu
      metricType: Utilization
      metadata:
        value: {{ $a.cpu | quote }}
    {{- end }}
    {{- if $a.memory }}
    - type: memory
      metricType: Utilization
      metadata:
        value: {{ $a.memory | quote }}
    {{- end }}
    {{- with .triggers }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- with $a.extraTriggers }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
{{- end }}

{{/* Pod-template replicas: omitted when KEDA owns them. */}}
{{- define "harmony.replicas" -}}
{{- if not .autoscaling.enabled }}
replicas: {{ .replicas }}
{{- end }}
{{- end }}

{{/* redis_exporter check-single-keys: db0=harmony:<queue>:wait,... */}}
{{- define "harmony.redis.queueKeys" -}}
{{- $keys := list }}
{{- range .Values.redis.metrics.queues }}{{ $keys = append $keys (printf "db0=harmony:%s:wait" .) }}{{ end }}
{{- join "," $keys }}
{{- end }}

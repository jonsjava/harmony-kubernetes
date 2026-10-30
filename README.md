# Harmony on Kubernetes

A Helm chart for [Harmony](https://github.com/y4my4my4m/harmony), the federated
chat and social platform. It runs the same images and the same routing as
upstream's Docker self-host stack (`self-host/`), split into Kubernetes
workloads, with optional [KEDA](https://keda.sh) autoscaling.

Chart: [`charts/harmony`](charts/harmony) · App version: **1.9.2**

An unofficial community chart: it deploys upstream's unmodified, published images
and is not endorsed by the Harmony project.

## What gets deployed

```
                         Ingress / Gateway API (TLS)
             chat.example.com   db.example.com        live.example.com
                    │                 │                      │
                    ▼                 ▼                      ▼
              ┌──────────────── router (Caddy) ──┐      livekit (opt.)
              │  content-negotiated routes       │        TCP 7881 / UDP 7882
              │  (Accept, User-Agent, cookie)    │        via LoadBalancer
              └──┬──────────┬───────────┬────────┘        or hostNetwork
                 ▼          ▼           ▼
               web   federation-   media-cache ──► Supabase Kong
                       server                         (your Supabase release)
              bot-gateway (opt.)        federation-worker ──► Postgres (LISTEN)
              discord-bridge (opt.)            │
                                             redis
```

| Component | Kind | Image | Notes |
|---|---|---|---|
| `web` | Deployment | `ghcr.io/y4my4my4m/harmony-web` | Vue SPA; writes `/config.json` from env at start |
| `router` | Deployment | `caddy:2.10-alpine` | Port of upstream `self-host/Caddyfile`, plain HTTP behind your Ingress |
| `federation-server` | Deployment | `ghcr.io/y4my4my4m/harmony-federation` | ActivityPub, link previews, LiveKit tokens (`FEDERATION_MODE=server`) |
| `federation-worker` | Deployment | same image | BullMQ queues, delivery retries, LISTEN/NOTIFY (`FEDERATION_MODE=worker`) |
| `media-cache` | Deployment | `nginx:1.29-alpine` | Disk cache of public storage reads in front of Kong |
| `redis` | StatefulSet | `redis:7-alpine` | Or bring your own (`redis.enabled=false`) |
| `bot-gateway` | Deployment | `ghcr.io/y4my4my4m/harmony-bot-gateway` | `botGateway.enabled` |
| `discord-bridge` | StatefulSet | `ghcr.io/y4my4my4m/harmony-discord-bridge:2` | `discordBridge.enabled` (needs the bot gateway) |
| `livekit` | Deployment | `livekit/livekit-server:v1.9.4` | `livekit.enabled` |
| migrations | Job (hook) | `alpine/git` + `postgres:17-alpine` | Applies `db_schema/migrations` at the app version |
| admin | Job (hook) | federation image | Creates/promotes the first admin (`admin.create`) |

**Supabase is not part of this chart.** Harmony needs a Supabase stack (Postgres,
GoTrue, PostgREST, Realtime, Storage, imgproxy, Kong). Run it with the
[supabase-community chart](https://github.com/supabase-community/supabase-kubernetes)
([values for Harmony](examples/supabase-values.yaml)), point at an existing one, or use
Supabase Cloud.

## Requirements

- Kubernetes 1.25+, Helm 3.8+
- An Ingress controller or a Gateway API implementation, and cert-manager (or your own TLS secret)
- DNS for `<domain>` and `db.<domain>` (and `live.<domain>` with voice) pointing at it
- Supabase (below)
- KEDA 2.10+ if you enable any `autoscaling` block
- Pods need outbound HTTPS: federation talks to other servers, and the migrations job clones `github.com/y4my4my4m/harmony`

## Getting the chart

The chart is published from this repository on every version bump:

```bash
# OCI (GitHub Container Registry)
helm install harmony oci://ghcr.io/jonsjava/charts/harmony --version 0.2.0 \
  -n harmony -f harmony-values.yaml

# Classic Helm repository (GitHub Pages)
helm repo add harmony-k8s https://jonsjava.github.io/harmony-kubernetes
helm repo update
helm install harmony harmony-k8s/harmony -n harmony -f harmony-values.yaml
```

Every version is also attached to a
[GitHub Release](https://github.com/jonsjava/harmony-kubernetes/releases) as a
`.tgz`. From a checkout, `./charts/harmony` works in place of the chart reference.

## Install

### 1. Secrets shared by Supabase and Harmony

```bash
kubectl create namespace harmony
scripts/generate-secrets.sh harmony
```

This creates `supabase-jwt` (JWT secret plus anon/service keys signed with it),
`supabase-db` (Postgres password) and `harmony-admin` (the first admin's
password, printed once). Existing Secrets are left alone.

### 2. Supabase

```bash
git clone https://github.com/supabase-community/supabase-kubernetes
# edit examples/supabase-values.yaml: replace chat.example.com
helm install supabase ./supabase-kubernetes/charts/supabase -n harmony \
  -f examples/supabase-values.yaml \
  --set secret.dashboard.password="$(openssl rand -hex 16)" \
  --set secret.realtime.secretKeyBase="$(openssl rand -base64 48)" \
  --set secret.meta.cryptoKey="$(openssl rand -hex 16)" \
  --set secret.analytics.publicAccessToken="$(openssl rand -hex 32)" \
  --set secret.analytics.privateAccessToken="$(openssl rand -hex 32)"
kubectl -n harmony rollout status deploy/supabase-supabase-realtime
```

[`examples/supabase-values.yaml`](examples/supabase-values.yaml) carries Harmony's
changes to Supabase (upstream `self-host/supabase-overrides.yml`): GoTrue v2.196.0+
with custom OAuth providers, the callback and site URLs, sign-up closed until the
admin exists, imgproxy limits, and no Kong Ingress (Harmony's router fronts it).

> Harmony's CI installs its schema on Postgres 15 (`supabase/postgres:15.8.1.060`);
> the community chart currently defaults to Postgres 17. Upstream does not test 17.
> To match upstream exactly, pin `image.db.tag` in the Supabase release to a 15.x
> image before the first start (a major version cannot change in place later).

### 3. Harmony

```yaml
# harmony-values.yaml
harmony:
  domain: chat.example.com
  adminEmail: you@example.com
  instanceName: My Harmony
  registration: invite          # open | invite | closed

supabase:
  internalUrl: http://supabase-supabase-kong:8000
  existingSecret: supabase-jwt
  existingSecretKeys:
    anonKey: anonKey
    serviceRoleKey: serviceKey
  db:
    host: supabase-supabase-db
    existingSecret: supabase-db
    existingSecretPasswordKey: password

admin:
  create: true
  email: you@example.com
  username: owner
  existingSecret: harmony-admin

ingress:
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    nginx.ingress.kubernetes.io/proxy-body-size: 50m
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
```

```bash
helm install harmony oci://ghcr.io/jonsjava/charts/harmony -n harmony -f harmony-values.yaml
kubectl -n harmony logs job/harmony-migrations --all-containers -f
```

On install the migrations job runs after the workloads start (the release's
Secret must exist first); `federation-server` reports ready on its socket, not
`/health`, so `helm install --wait` does not deadlock on the empty schema. Then
the admin job creates the account, and `helm test harmony -n harmony` checks
the routing end to end.

Open `https://chat.example.com` and sign in as the admin. For open sign-up
afterwards, set `harmony.registration: open` here **and**
`GOTRUE_DISABLE_SIGNUP: "false"` in the Supabase release.

### Supabase Cloud or an existing Supabase

```yaml
supabase:
  internalUrl: https://<project>.supabase.co
  publicUrl: https://<project>.supabase.co
  proxy:
    enabled: false           # no db.<domain> route, no media cache
  anonKey: ...
  serviceRoleKey: ...
  db:
    host: db.<project>.supabase.co   # direct connection (session mode, 5432)
    password: ...
    sslmode: require
```

Upstream Harmony is built and tested against self-hosted Supabase; the
logout-scope rule and the WebP pin on `db.<domain>` only exist with
`supabase.proxy.enabled`.

## Configuration

Everything is documented inline in [`values.yaml`](charts/harmony/values.yaml).
The main groups:

| Key | What |
|---|---|
| `harmony.*` | domain, `dbDomain`/`liveDomain` (default `db.`/`live.` + domain), name, admin email, registration, OAuth buttons, legal/status URLs |
| `image.tag` | Harmony image tag; defaults to the chart's `appVersion`. `edge` follows upstream master (migrations then come from `master`) |
| `supabase.*` | Kong URL inside and outside the cluster, keys, Postgres connection, upload ceiling |
| `secrets.*` | Generated once and kept (`helm.sh/resource-policy: keep`): Redis password, listener role password, internal API secret, LiveKit key pair, bridge secret. Also VAPID keys, Klipy keys, FCM JSON. Or `secrets.existingSecret` |
| `web` / `router` / `federation.server` / `federation.worker` | replicas, resources, scheduling, `autoscaling` |
| `redis.*` | bundled StatefulSet or `external`; maxmemory, VPA, exporter, alerts |
| `botGateway` / `discordBridge` / `livekit` | optional services |
| `ingress` / `gateway` | Ingress and/or Gateway API HTTPRoutes |
| `migrations.*` / `admin.*` | hook jobs |
| `keda.*` | polling, cooldown, HPA behaviour shared by every ScaledObject |

### Generated secrets and GitOps

The chart generates its secrets on first install and finds them again on
upgrade through Helm's `lookup`. Tools that render without cluster access
(Argo CD, `helm template | kubectl apply`) cannot look them up and would
generate new ones on every render, changing the Redis and listener passwords
under running pods. With those tools, create a Secret yourself with every key
the chart uses (`REDIS_PASSWORD`, `INTERNAL_API_SECRET`, `LISTENER_PASSWORD`,
`LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `BRIDGE_HOST_SECRET`, and optionally
`VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `MEDIA_URL_SECRET`, `KLIPY_API_KEY_ADS`,
`KLIPY_API_KEY_NOADS`, `FCM_SERVICE_ACCOUNT_JSON`) and set
`secrets.existingSecret`. Passwords go into connection URLs: use URL-safe
characters (letters and digits).

### Push notifications

```bash
npx web-push generate-vapid-keys
```

Set `secrets.vapidPublicKey` / `secrets.vapidPrivateKey`. Without them Web Push
and UnifiedPush are off. FCM for the Android app: `secrets.fcmServiceAccountJson`.

## Autoscaling with KEDA

Every scalable component has an `autoscaling` block that renders a KEDA
`ScaledObject`; the Deployment then leaves `replicas` to KEDA. Install KEDA
first:

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda -n keda --create-namespace
```

```yaml
web:
  autoscaling: { enabled: true, minReplicas: 2, maxReplicas: 6, cpu: 75 }
router:
  autoscaling: { enabled: true, minReplicas: 2, maxReplicas: 6, cpu: 75 }
federation:
  server:
    autoscaling: { enabled: true, minReplicas: 2, maxReplicas: 8, cpu: 70, memory: 80 }
  worker:
    autoscaling:
      enabled: true
      maxReplicas: 3
      queueLengthTarget: 50
keda:
  cooldownPeriod: 300
```

- **`cpu` / `memory`** are average utilisation targets in percent (`null` turns the
  trigger off) and need the matching `resources.requests`, which the defaults set.
- **`extraTriggers`** appends raw KEDA triggers, e.g. a Prometheus query on request
  rate, or a `cron` trigger for busy hours.
- **The worker** scales on BullMQ backlog: one KEDA `redis` trigger per queue in
  `federation.worker.autoscaling.queues`, reading the list `harmony:<queue>:wait`
  (BullMQ prefix `harmony`), authenticated through a `TriggerAuthentication` on the
  chart's Redis password. KEDA adds a replica per `queueLengthTarget` waiting jobs
  in the busiest queue.

**Worker caveat.** Each worker replica also runs Harmony's 30-second retry pass
over `federation_delivery_queue`, which reads pending rows without claiming them,
and the 60-second sweep. With more than one worker a failed delivery can be
retried twice in the same interval (other servers dedupe activities by id, but
it is wasted work). Upstream runs one worker. The worker autoscaler is off by
default; if you enable it keep `maxReplicas` small. BullMQ itself hands each job
to exactly one worker.

What does **not** scale: `bot-gateway` (WebSocket sessions live in the process),
`discord-bridge` (one Discord connection per bridge), `livekit` (one SFU with fixed
media ports) and `media-cache`. Redis grows vertically instead; see below.

## Redis: memory, VPA and monitoring

Redis does not scale out for Harmony: BullMQ needs a single primary (every
enqueue and claim is a write, run as a multi-key Lua script), and Harmony's
queue prefix `harmony` carries no `{hash tag}`, so Redis Cluster is out.
Queue depth is held in Redis **memory**, so the chart sizes Redis vertically
and watches it.

- **maxmemory follows the memory limit.** Redis runs with
  `maxmemory-policy noeviction`, so a job key is never dropped; at `maxmemory`
  it refuses new writes instead. At start the container sets `maxmemory` to
  `redis.maxmemoryPercent` (85) of its cgroup memory limit, which leaves room
  for AOF rewrites and avoids an OOM kill. `redis.maxmemory` overrides it.
- **VPA** (`redis.vpa.enabled`, needs the
  [Vertical Pod Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler))
  sizes Redis memory from its usage between `minAllowed` and `maxAllowed`. Start
  with `updateMode: "Off"` and read the recommendation with
  `kubectl describe vpa harmony-redis`; `Recreate` applies it by restarting Redis
  (AOF keeps the queues), `InPlaceOrRecreate` resizes in place where the cluster
  supports it. Because `controlledValues: RequestsAndLimits` scales the limit too,
  and `maxmemory` is read from the limit at start, the two stay in step.
- **Metrics** (`redis.metrics.enabled`) add a
  [redis_exporter](https://github.com/oliver006/redis_exporter) sidecar on port
  9121. Besides the usual Redis metrics it exports every queue's waiting jobs as
  `redis_key_size{key="harmony:<queue>:wait"}`, by SCAN over
  `redis.metrics.queueKeyPattern`, or by direct lookup when you list
  `redis.metrics.queues`.
- **ServiceMonitor and PrometheusRule** (`redis.metrics.serviceMonitor.enabled`,
  `redis.metrics.prometheusRule.enabled`, Prometheus Operator) scrape it and alert:

| Alert | Fires when |
|---|---|
| `HarmonyRedisDown` | the exporter cannot reach Redis for 5 m |
| `HarmonyRedisMemoryHigh` | memory above 75% of `maxmemory` for 10 m (warning) |
| `HarmonyRedisMemoryCritical` | above 90% for 5 m |
| `HarmonyRedisRejectingWrites` | Redis answered OOM errors in the last 5 m: jobs are being refused |
| `HarmonyQueueBacklog` | one queue holds more than 1000 waiting jobs for 15 m (warning) |

Thresholds are under `redis.metrics.prometheusRule`; `extraRules` appends your own.
Label the ServiceMonitor and rule for your Prometheus' selectors, e.g.
`labels: {release: kube-prometheus-stack}`. These options cover the bundled
Redis; with `redis.enabled=false`, monitor your own Redis the same way.

A backlog alert means the consumers are behind: check the worker's logs and
the remote servers it delivers to, and consider `federation.worker.autoscaling`.

## Voice and video (LiveKit)

```yaml
livekit:
  enabled: true
  rtc:
    nodeIP: 203.0.113.10        # the external IP clients reach
    service:
      type: LoadBalancer         # TCP 7881 + UDP 7882 on one Service
```

Signalling goes through the Ingress at `live.<domain>`. Media needs TCP 7881 and
UDP 7882 reachable at the address LiveKit advertises:

- **LoadBalancer** (default): install, read the IP from
  `kubectl get svc harmony-livekit-rtc`, set `livekit.rtc.nodeIP` to it, upgrade.
  The cloud must support mixed-protocol LoadBalancers (Kubernetes 1.26+); otherwise
  annotate for your provider.
- **hostNetwork**: `livekit.hostNetwork: true` and leave `nodeIP` empty
  (`useExternalIP` asks STUN). Pin the pod with `nodeSelector` and open the ports
  in the node firewall.
- **NodePort**: set `rtc.tcpPort`/`rtc.udpPort` inside the NodePort range; the
  container listens on the same numbers.

TURN is off, as upstream. `livekit.extraConfig` is merged over the generated
`livekit.yaml` (e.g. `room.max_participants`, `turn`). The webhook to the
federation server is configured for you.

## Bots and Discord bridges

```yaml
botGateway:
  enabled: true
discordBridge:
  enabled: true
```

Then, in Harmony: Admin → Instance → Discord bridge → "Run communities' own
bots". The bot gateway sends its internal secret only over HTTPS, so it calls the
federation backend at `https://<domain>`: pods must be able to reach the public
address (hairpin through your load balancer). Override with
`botGateway.federationBackendUrl` if needed.

## Upgrades and migrations

```bash
helm upgrade harmony oci://ghcr.io/jonsjava/charts/harmony -n harmony -f harmony-values.yaml --set image.tag=<new version>
```

The migrations job is a `pre-upgrade` hook: it clones `db_schema/migrations` at
`v<tag>` and applies pending files in order, recorded in
`supabase_migrations.schema_migrations`, before the new pods roll (as upstream's
`harmony update` does). A failing migration stops the upgrade; the database stays
at the last migration that succeeded. It is a port of upstream
`self-host/bootstrap.sh`: it also sets the upload ceiling, the storage origin, the
`harmony_listener` role, the instance name and domain on a new database, applies
`harmony.registration`, and removes `app.settings.jwt_secret` from the database
defaults when the role may.

If public functions are owned by `supabase_admin` (objects created in Studio),
set `supabase.db.user: supabase_admin` with its password.

## Backups

The state lives in Supabase (Postgres and storage volumes) plus the Secrets:
`harmony-secrets` (generated keys, the listener role password),
`supabase-jwt`, `supabase-db`. Back up the Postgres database
(`pg_dump` or your operator's backups), the storage PVC, and those Secrets.
Redis only holds queues and caches; persistence keeps queued jobs across restarts.

## Differences from upstream's Docker stack

- TLS terminates at your Ingress/Gateway; Caddy runs without ACME on port 8080 and
  trusts `X-Forwarded-For` from private ranges (`router.trustedProxies`).
- LiveKit signalling is routed by the Ingress directly, not through Caddy.
- `harmony` CLI commands map to: `admin create` → `admin.create`;
  `registration` → `harmony.registration` (+ GoTrue's switch in Supabase);
  `update` → `helm upgrade`; `logs` → `kubectl logs`. Invites, password resets and
  OAuth providers have no chart equivalent yet; run the admin panel, or the
  upstream scripts against the cluster.

## Development

```bash
helm lint charts/harmony -f charts/harmony/ci/full-values.yaml --strict
helm template h charts/harmony -f charts/harmony/ci/minimal-values.yaml
```

CI ([`.github/workflows/lint.yaml`](.github/workflows/lint.yaml)) lints and
renders every `ci/*-values.yaml` and validates the output, including the KEDA,
Gateway API, VPA and Prometheus Operator CRDs, and on pull requests requires a
chart version bump when the chart changed.

### Releasing

Bump `version` in `charts/harmony/Chart.yaml` and merge to `main`.
[`.github/workflows/release.yaml`](.github/workflows/release.yaml) runs
[chart-releaser](https://github.com/helm/chart-releaser-action), which creates
the GitHub Release `harmony-<version>` with the packaged chart, adds it to
`index.yaml` on the `gh-pages` branch (served by GitHub Pages), and pushes it to
`oci://ghcr.io/jonsjava/charts/harmony`. A version that already exists is skipped.

## License

[MIT](LICENSE), except a few files derived from Harmony's own self-host
scripts (the migration and admin scripts, the router and media-cache
configuration, the Supabase example and the JWT signing in
`scripts/generate-secrets.sh`), which stay under Harmony's AGPL-3.0 with its
additional terms. [NOTICE](NOTICE) lists them; each carries an SPDX line.
Harmony itself, and its images, are © y4my4my4m and the Harmony contributors
under that license.

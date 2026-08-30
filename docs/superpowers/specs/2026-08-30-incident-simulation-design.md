# Design: Simulated Incident Drill (productcatalogservice fault, Grafana alerts, Jira lifecycle)

**Date:** 2026-08-30
**Status:** Approved

## Context

Live GKE Autopilot cluster `online-boutique` (project
`hl2-gcpp-ccoe-ge-h-itrace-1647`, region `us-central1`) runs Google's Online
Boutique demo, deployed via the existing `.github/workflows/deploy-gke.yaml`
(push to `main` touching `src/**`/`kustomize/**` → build all 11 service
images → `kubectl apply -k kustomize/` → `kubectl wait --for=condition=available`
per deployment). A kube-prometheus-stack Helm release (`monitoring` namespace,
release name `monitoring`) is already deployed, with Grafana 13.2.0 reachable
at `http://35.253.119.204/` (`admin`/`admin123`). Grafana has three
datasources — `Prometheus` (uid `prometheus`, kube-state-metrics + cAdvisor
only), `Alertmanager`, and `Google Cloud Monitoring` (Stackdriver) — all
`readOnly: true`, with zero alert rules and zero contact points currently
configured.

This machine has no working `gcloud`/`kubectl` (the GKE auth plugin and
gcloud CLI are both absent), so every cluster-affecting change in this drill
must go through the existing CI/CD pipeline (git push to `main`), and every
Grafana-affecting change must go through Grafana's own HTTP API.

No service in the app currently exposes Prometheus metrics. The chosen fault
— the pre-existing `EXTRA_LATENCY` env var on `productcatalogservice`
(`time.Sleep` at the top of `ListProducts`/`GetProduct`/`SearchProducts` in
`product_catalog.go`) — does not touch the gRPC health check
(`Check()` always returns `SERVING` immediately), so a pure-latency fault
produces no pod restart, no readiness flip, and no kube-state-metrics signal:
it is invisible to every alert Grafana could build on the datasources that
exist today. Making the fault detectable requires either (a) a harsher fault
that crashes/un-readies the pod, or (b) adding minimal application metrics.
Approach (b) was chosen (see Decision below) as the more realistic simulation
and the one that keeps the CI deploy's `kubectl wait` step green.

## Goal

Produce a real, observable, cascading incident against three downstream
services, driven by a single root-cause fault in `productcatalogservice`,
detected by real Grafana alert rules, and documented end-to-end in a Jira
issue (create → investigate → resolve), then cleanly reverted.

## Non-goals

- No Loki / log-aggregation stack, no Istio service mesh, no new GCP
  infrastructure (Cloud Logging log-based metrics, Cloud Monitoring alerting
  policies) — all out of reach without a working `gcloud` on this machine.
- No Slack/email delivery for alerts — no contact-point destination has been
  provided; alerts will fire and be visible in Grafana's Alerting UI, not
  paged externally.
- No changes to services other than `productcatalogservice` (the single
  root cause) and no changes to `frontend`/`checkoutservice`/
  `recommendationservice` (they are the *victims*, not modified).
- No permanent removal of the metrics instrumentation after the drill — only
  the fault env vars get reverted.

## Decision: fault severity & detectability

Two new env vars on `productcatalogservice`, both off by default:

- `EXTRA_LATENCY` (existing) → set to `2.5s` during the incident.
- `FAULT_ERROR_RATE` (new) → set to `0.25` during the incident: ~25% of
  `GetProduct`/`ListProducts` calls return `codes.Unavailable` instead of a
  real response, after the latency sleep.

This guarantees real failures (not just slowness) reach downstream callers
without crashing the pod or failing its health probe, so CI's post-deploy
`kubectl wait --for=condition=available` keeps passing on both the fault
commit and the revert commit.

Confirmed cascading impact (read directly from each caller):

| Service | Call site | Effect |
|---|---|---|
| `frontend` | `rpc.go`: `getProducts`→`ListProducts`, `getProduct`→`GetProduct` | Home page product grid and product detail pages slow down and intermittently error. |
| `checkoutservice` | `main.go` `prepOrderItems` (lines 339-357), one `GetProduct` call per cart item, no retry | `PlaceOrder` fails outright on the first errored item; latency compounds per item in the cart. |
| `recommendationservice` | `recommendation_server.py` line 73, `ListRecommendations`→`ListProducts` | Recommendation rail slows down and intermittently fails. |

To make this detectable, `productcatalogservice` gains minimal Prometheus
instrumentation (new file `metrics.go`, using `prometheus/client_golang`):

- `productcatalog_requests_total{method,status}` (counter)
- `productcatalog_request_duration_seconds{method}` (histogram)
- served via `promhttp.Handler()` on a new `METRICS_PORT` (default `8081`),
  started as a goroutine alongside the existing gRPC server in `main()`.

## Kustomize changes

`kustomize/base/productcatalogservice.yaml` (single file, already contains
Deployment + Service + ServiceAccount):

- Deployment: add `containerPort: 8081` (metrics); add env vars
  `METRICS_PORT=8081`, `EXTRA_LATENCY` and `FAULT_ERROR_RATE` present but
  unset/zero on the instrumentation commit (baseline), then set to `2.5s`/
  `0.25` on the fault commit, then removed on the revert commit.
- Service: add a second port, `name: metrics, port: 8081, targetPort: 8081`.
- New `ServiceMonitor` (apiVersion `monitoring.coreos.com/v1`) appended to
  the same file as a fourth `---` document, labeled `release: monitoring` to
  match the kube-prometheus-stack release name (confirmed from
  `helm_upgrade3.log`, the default selector convention for that chart),
  selecting the `productcatalogservice` Service's `metrics` port at path
  `/metrics`.

No `kustomization.yaml` edit needed (same file, no new resource entry).

## Alerting (Grafana HTTP API, `Prometheus` datasource)

Two alert rules, provisioned via `/api/v1/provisioning/alert-rules`:

1. **High error rate** —
   `sum(rate(productcatalog_requests_total{status!="OK"}[5m])) / sum(rate(productcatalog_requests_total[5m])) > 0.1`
   for 2m.
2. **High latency (p95)** —
   `histogram_quantile(0.95, rate(productcatalog_request_duration_seconds_bucket[5m])) > 1`
   for 2m.

Both use whatever default/no-op contact point Grafana provisions out of the
box — no external notification target exists yet, so "alerting" in this
drill means: the rule evaluates, transitions to `Firing`, and is visible in
Grafana's Alerting UI and via the provisioning API — not that anyone gets
paged. This is called out explicitly so it isn't mistaken for a fully wired
on-call flow.

## Rollout sequence

1. Commit + push metrics instrumentation (`metrics.go` + kustomize changes,
   fault env vars absent/zero) → CI builds+deploys → verify scrape success
   via Grafana Explore (`up{job="productcatalogservice"}` query against the
   `Prometheus` datasource, or equivalent `productcatalog_requests_total`
   query) before proceeding.
2. Create the two Grafana alert rules via the provisioning API → confirm
   both evaluate as healthy (not firing) against the current baseline.
3. Create a Jira Task in project `SCRUM` (no `Bug` issue type exists in this
   project) titled something like "productcatalogservice degraded —
   elevated latency & errors impacting frontend, checkout,
   recommendations", body describing the (about-to-happen) fault and
   expected blast radius.
4. Commit + push the fault (`EXTRA_LATENCY=2.5s`, `FAULT_ERROR_RATE=0.25`)
   → CI builds+deploys → poll Grafana until both alert rules report
   `Firing` → add a Jira comment noting detection (timestamp, which alerts
   fired).
5. Add a Jira comment documenting root cause (the two env var values) and
   the intended fix (revert).
6. Commit + push the revert (env vars removed) → CI builds+deploys → poll
   Grafana until both alert rules report back to healthy → add a closing
   Jira comment.
7. Transition the Jira Task to Done.

## Rollback

Every change is additive env vars plus one new Go file — reverting the
incident is a single follow-up commit restoring
`kustomize/base/productcatalogservice.yaml`'s env block to omit
`EXTRA_LATENCY`/`FAULT_ERROR_RATE`. The metrics instrumentation itself
(`metrics.go`, the `ServiceMonitor`, the alert rules) is left in place
permanently — it's harmless at baseline (zero counters incrementing past
normal traffic) and is generically useful observability, not scoped to this
drill.

## Testing / validation plan

- After step 1's deploy: query the `Prometheus` datasource via Grafana's
  `/api/ds/query` for `up{job=~".*productcatalog.*"}` (or the request
  counter) to confirm the `ServiceMonitor` was picked up and scraping is
  live, before trusting any alert rule built on top of it.
- After step 2: `GET /api/v1/provisioning/alert-rules` to confirm both rules
  exist and `GET /api/alertmanager/grafana/api/v2/alerts` (or the alert
  rule's own state) to confirm neither is firing yet.
- After step 4: re-poll the same endpoints until both rules show `Firing`,
  and manually exercise the site (home page, add-to-cart, checkout) to
  visually confirm the degraded behavior described above.
- After step 6: re-poll until both rules return to `Normal`/healthy, confirm
  a fresh checkout completes successfully end-to-end.

# sc-gen — a Dash0 Signal Control test bed

A small, self-contained Kubernetes workload that generates telemetry shaped to
exercise Dash0 Signal Control: spam filters, tail-sampling rules,
signal-to-metrics and time series aggregation.

Apply it, open the control panel to switch traffic on and see what is being
sent, then run `./verify.sh` to see what the rules actually did to it.

Use it to learn how the rules behave, to reproduce a bug, or to check a Signal
Control change before you point it at real traffic.

## Requirement: the Dash0 operator with the SignalControl Edge collector enabled

> [!IMPORTANT]
> Nothing in this repo works without the Dash0 operator installed in your
> cluster **and** the SignalControl Edge collector setting enabled. The
> `Dash0SpamFilter`, `Dash0SamplingRule`, `Dash0SignalToMetrics` and
> `Dash0TimeSeriesAggregation` custom resources do not exist until the operator
> installs their CRDs, and the rules have nothing to run on until the edge
> collector is on.
>
> This repo targets operator **`0.155.0`** or later. `Dash0TimeSeriesAggregation`
> arrived in `0.155.0`; on `0.154.0` and earlier, step 6 has to be done in the
> Dash0 UI instead.

Enabling Signal Control takes **two** steps, and it is easy to do only the first
and wonder why no rule ever fires:

1. A **Helm value** at install time, `operator.signalControl.enabled=true`, which
   permits Signal Control. It defaults to `false`. On its own it deploys
   nothing: the operator's own pods come up and no Signal Control component
   appears.
2. A **cluster-scoped `Dash0SignalControl` resource**, which is what actually
   makes the operator deploy the Edge Proxy and the Signal Control collector and
   wire their processors into the pipeline.

Already have the operator running? Skip to
[step 4](#4-enable-the-signal-control-pipeline) and check
`helm get values dash0-operator -n dash0-system` for
`signalControl.enabled: true`.

### 1. Collect your org's endpoints and a token

All three come from [app.dash0.com](https://app.dash0.com) → organization
settings:

| What | Where | Looks like |
| --- | --- | --- |
| OTLP/gRPC endpoint | **Endpoints** → OTLP/gRPC | `ingress.eu-west-1.aws.dash0.com:4317` |
| API endpoint | **Endpoints** | `https://api.eu-west-1.aws.dash0.com` |
| Auth token | **Auth Tokens** | `auth_...` |

```bash
export DASH0_ENDPOINT='ingress.eu-west-1.aws.dash0.com:4317'
export DASH0_API_URL='https://api.eu-west-1.aws.dash0.com'
export DASH0_AUTH_TOKEN='auth_...'
```

`verify.sh` reads `DASH0_API_URL`, so exporting it now saves passing it later.
Use your own region: the defaults throughout this repo are `eu-west-1`.

### 2. Create the token secret

Passing the token by `secretRef` rather than `operator.dash0Export.token` keeps
it out of the Helm release values. `verify.sh` reads this same secret, so the
name and key matter.

```bash
kubectl create namespace dash0-system

kubectl create secret generic dash0-authorization-secret \
  --namespace dash0-system \
  --from-literal=token="$DASH0_AUTH_TOKEN"
```

### 3. Install the operator with Signal Control enabled

```bash
helm repo add dash0-operator https://dash0hq.github.io/dash0-operator
helm repo update dash0-operator

helm install dash0-operator dash0-operator/dash0-operator \
  --namespace dash0-system \
  --set operator.dash0Export.enabled=true \
  --set operator.dash0Export.endpoint="$DASH0_ENDPOINT" \
  --set operator.dash0Export.apiEndpoint="$DASH0_API_URL" \
  --set operator.dash0Export.secretRef.name=dash0-authorization-secret \
  --set operator.dash0Export.secretRef.key=token \
  --set operator.signalControl.enabled=true
```

`operator.signalControl.enabled=true` is the one this repo cannot do without.

Wait for the operator itself:

```bash
kubectl -n dash0-system rollout status deploy/dash0-operator-controller
kubectl get pods -n dash0-system
```

At this point you should see three things and **no Signal Control components
yet**:

```
dash0-operator-cluster-metrics-collector-deployment-...    2/2  Running
dash0-operator-controller-...                              1/1  Running
dash0-operator-opentelemetry-collector-agent-daemonset-... 3/3  Running
```

> [!IMPORTANT]
> `signalControl.enabled=true` only *permits* Signal Control. It does not deploy
> anything by itself, so `deploy/dash0-operator-edge-proxy` does not exist yet
> and `rollout status` on it returns `NotFound`. That is expected here — the
> components arrive in step 4. If you are looking for them now, you are one step
> early.

> [!NOTE]
> The Signal Control collector and Edge Proxy are versioned **independently** of
> the operator and pinned by the chart, so their image tags do not track the
> chart's `appVersion`. Override with
> `operator.signalControlCollectorImage.*` and `operator.edgeProxyImage.*` if
> you need a specific build, and move both together — they speak a rules
> broadcast protocol to each other. To do that, see
> [Running a specific Signal Control build](#running-a-specific-signal-control-build)
> *after* step 4, not here: the deployments those overrides target do not exist
> until step 4 creates them.

### 4. Enable the Signal Control pipeline

A `Dash0SignalControl` resource is what makes the operator deploy the Signal
Control components and wire their processors into the collector pipeline. It is
cluster-scoped, and an empty spec beyond `enabled` runs every sub-feature at its
default, all of which are on:

| Sub-feature | Default |
| --- | --- |
| `edgeProxy` | on |
| `sampling` | on, `serialized_memory` reservoir, fallback ratio applied when the Decision Maker is unreachable |
| `spamFilter` | on |
| `signalToMetrics` | on |
| `redMetrics` | on, soft cap 5000 time series |
| `operationProcessor` | on, derives `dash0.operation.*` from semconv attributes |

This one is deliberately **not** in `manifests/`, because
`kubectl apply -f manifests/` would then change a cluster-wide setting. Apply it
yourself, once.

```bash
kubectl apply -f - <<'EOF'
apiVersion: operator.dash0.com/v1alpha1
kind: Dash0SignalControl
metadata:
  name: dash0-signal-control
spec:
  enabled: true
EOF
```

Applying it makes the operator create two more workloads in `dash0-system`: a
`signal-control-collector` Deployment (2 replicas) that applies the rules, and
an `edge-proxy` Deployment (2 replicas) that fetches org settings and brokers
the collectors' connections to the Decision Maker. **Now** wait for them:

```bash
kubectl -n dash0-system rollout status deploy/dash0-operator-edge-proxy
kubectl -n dash0-system rollout status \
  deploy/dash0-operator-signal-control-collector-deployment
kubectl get pods -n dash0-system
```

The `get pods` is the point of running this as two steps. Compare the full
list against [the one from step 3](#3-install-the-operator-with-signal-control-enabled):
the three operator workloads are unchanged, and everything marked below is new
since applying the resource above.

```
dash0-operator-cluster-metrics-collector-deployment-...    2/2  Running
dash0-operator-controller-...                              1/1  Running
dash0-operator-edge-proxy-...                              1/1  Running   <- new
dash0-operator-edge-proxy-...                              1/1  Running   <- new
dash0-operator-opentelemetry-collector-agent-daemonset-... 3/3  Running
dash0-operator-signal-control-collector-deployment-...     2/2  Running   <- new
dash0-operator-signal-control-collector-deployment-...     2/2  Running   <- new
```

Four new pods, two per Deployment. Note they interleave alphabetically rather
than appearing at the end, so read the names, not the positions. The collector
pods show `2/2` because each runs the collector alongside a
`configuration-reloader` sidecar, the same pairing as the operator's own
OpenTelemetry agent; the edge-proxy pods run a single container.

That is the whole visible effect of the `Dash0SignalControl` resource: the Helm
flag in step 3 changed nothing in the cluster, and applying six lines of YAML
is what actually built the pipeline.

Nothing downstream works until both Deployments are running.

> [!WARNING]
> Rolling these two pods clears the tail-sampling reservoir, the trace decision
> cache, and every in-memory Signal Control counter. Do it before you start a
> measurement, never in the middle of one. That applies to any Helm upgrade
> that retargets their images, including the one below.

#### Running a specific Signal Control build

You do not need this for a normal install. Chart `0.155.0` defaults to
`signal-control-collector:1.2.0` and `edge-proxy:1.2.0` — a matched pair, and
the supported path. Take the default unless you are deliberately testing
another build.

Earlier charts did need an override. `0.153.0` and `0.154.0` both defaulted to
`v2.0.3005`, a build tag rather than a release, so a fresh install did not pick
up the `1.1.0` components; `0.155.0` replaced that with a real version. If you
are on an older chart, upgrade rather than pin.

To point the two components at a particular build:

```bash
helm upgrade dash0-operator dash0-operator/dash0-operator \
  --namespace dash0-system --reuse-values \
  --set operator.signalControlCollectorImage.tag=1.2.0 \
  --set operator.edgeProxyImage.tag=1.2.0
```

Three things to know before you do:

- **`--reuse-values` is not optional.** Without it you lose
  `operator.signalControl.enabled` and `operator.dash0Export.*`, and Signal
  Control switches itself off.
- **Run it after step 4.** The override retargets the two Deployments the
  operator manages, and they do not exist until the `Dash0SignalControl`
  resource is applied.
- **Move both together.** They speak a rules broadcast protocol to each other,
  so a mismatched pair is not a supported configuration.

The collector is also published under a second repository,
`ghcr.io/dash0hq/signal-control-edge-collector`, with the same tags but
different digests. The chart points at `signal-control-collector`; add
`--set operator.signalControlCollectorImage.repository=...` if you specifically
need the other one. Tags and build dates are not reliable discriminators
between them — match by the git revision label instead:

```bash
docker buildx imagetools inspect \
  --format '{{range $p,$i := .Image}}{{index $i.Config.Labels "org.opencontainers.image.revision"}}{{"\n"}}{{break}}{{end}}' \
  ghcr.io/dash0hq/edge-proxy:1.2.0
```

Then confirm what landed and wait for the rollout:

```bash
kubectl -n dash0-system get pods \
  -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[*].image' \
  | grep -E 'signal-control|edge-proxy'

kubectl -n dash0-system rollout status deploy/dash0-operator-edge-proxy
kubectl -n dash0-system rollout status \
  deploy/dash0-operator-signal-control-collector-deployment
```

### 5. Verify the install

```bash
kubectl get pods -n dash0-system
kubectl get crd | grep dash0
kubectl get dash0signalcontrol dash0-signal-control \
  -o jsonpath='{.status.conditions[?(@.type=="Available")]}{"\n"}'
```

A healthy install reports `"status":"True","reason":"ReconcileFinished"`.

That is the operator's own view, though. To confirm that telemetry from this
cluster is genuinely going through the **edge** collector rather than being
processed SaaS-side, ask for the edge collector's own throughput.

This needs **step 4 applied and the collector running**, but it does not need a
workload: the operator's own self-telemetry is enough to register. Run it a few
minutes after step 4, not before.

```bash
curl -sG -H "Authorization: Bearer $DASH0_AUTH_TOKEN" \
  --data-urlencode 'query=sum by (dash0_signal_control_component) (rate({otel_metric_name="dash0.signal_control.spans_in", dash0_signal_control_environment="edge"}[5m]))' \
  "$DASH0_API_URL/api/prometheus/api/v1/query"
```

A non-zero rate against `dash0_signal_control_environment="edge"` means your
cluster's own collector is doing the work. The same metric reports
`environment="saas"` for signals processed in the backend instead, so the label
is the actual answer to "is this cluster on the edge path". Measured on a
cluster with step 4 applied but no application workload at all, this reported
`0.41` spans/s through `component="filter"`.

> [!NOTE]
> With Signal Control on and no sampling rules, traces keep flowing. Measured
> at 95% retention on a fresh cluster, the shortfall being spans still in
> flight at the window edges. Enabling Signal Control does not itself reduce
> anything — the rules do, so step 2 below is a genuine unfiltered baseline.

## Quick start

This brings the whole test bed up, rules included, in one go. If you are
demonstrating Signal Control to someone, use
[Guided rollout](#guided-rollout-adding-the-rules-one-step-at-a-time) instead:
it starts with no rules so each one is visible as you add it.

1. Apply everything. The filename prefixes give the right order, and
   `kubectl apply` walks the directory alphabetically: the workload and control
   panel in `00` to `07`, then the rules in `10` to `13`.

   ```bash
   kubectl apply -f manifests/
   ```

2. Wait for the workloads.

   ```bash
   kubectl -n sc-test rollout status deploy/checkout-service
   kubectl -n sc-test rollout status deploy/inventory-service
   kubectl -n sc-test rollout status deploy/load-generator
   kubectl -n sc-test rollout status deploy/metric-emitter
   kubectl -n sc-test rollout status deploy/control-panel
   ```

3. Open the control panel to switch traffic on and off and see what is being
   sent.

   ```bash
   kubectl -n sc-test port-forward svc/control-panel 8000:80
   open http://localhost:8000
   ```

4. Give the rules up to 5 minutes to sync to the backend and reach the edge
   collector, then check what actually landed in Dash0.

   ```bash
   ./verify.sh
   ```

5. Tear it all down.

   ```bash
   kubectl delete -f manifests/
   ```

## Guided rollout: adding the rules one step at a time

The quick start applies everything at once, which is the wrong way round for a
demo: the rules are already in place before you have seen what the traffic looks
like without them. This walkthrough starts a fresh cluster and a fresh Dash0
org, gets traffic flowing with **no rules at all**, then adds each rule kind as
its own step so you can watch it take effect.

The manifests are numbered for exactly this. `00` through `07` are the workload
and the control panel; `10` through `13` are the rules. Nothing in `00-07`
depends on a rule existing.

The rules are numbered in the order the **collector** applies them, not in the
order the Dash0 UI lists them: the spam filter (`10`) drops signals outright, so
everything after it only ever sees what survived; metric derivation (`11`) then
happens on a branch that parallels the sampling pipeline, so sampling (`12`)
cannot affect it. Aggregation (`13`) comes last because it is the only one that
runs in the Dash0 backend rather than in your cluster, downstream of everything
the edge collector did. Following that order means each step's effect is visible
in the steps after it, and the demo builds instead of doubling back.

> [!IMPORTANT]
> **Allow up to 5 minutes after applying a rule before concluding anything.**
> Every step below says this, and it is the single most common way to talk
> yourself into a bug that is not there. A rule has to be accepted by the
> backend, reach the edge collector, and then be picked up by the processor that
> enforces it, and each of those hops has its own cache or poll interval. For
> signal-to-metrics there is a further wait, because derived metrics are only
> emitted on a flush interval — so the rule can be live and correct and still
> have produced no data point yet.
>
> `.status.synchronizationStatus` going to `successful` only tells you the
> *first* hop finished. It is not a signal that the rule is in force.

### Step 1: the operator and Signal Control — no manifests

Work through
[Requirement: the Dash0 operator with the SignalControl Edge collector enabled](#requirement-the-dash0-operator-with-the-signalcontrol-edge-collector-enabled)
above, all five steps, using the new org's endpoints and token. A brand-new
cluster needs every one of them.

When install step 5 reports `"status":"True","reason":"ReconcileFinished"`, the
Signal Control pods are up, and its edge-throughput check returns a non-zero
rate, you have a cluster producing no *application* telemetry yet, with Signal
Control armed and no rules. That is the starting line.

### Step 2: traffic, with no rules — `00` to `07`

```bash
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/01-dash0-monitoring.yaml
kubectl apply -f manifests/02-checkout-service.yaml
kubectl apply -f manifests/03-inventory-service.yaml
kubectl apply -f manifests/04-load-profile.yaml
kubectl apply -f manifests/05-load-generator.yaml
kubectl apply -f manifests/06-metric-emitter.yaml
kubectl apply -f manifests/07-control-panel.yaml

for d in checkout-service inventory-service load-generator metric-emitter control-panel; do
  kubectl -n sc-test rollout status deploy/$d
done
```

Open the panel and leave it open for the rest of the walkthrough:

```bash
kubectl -n sc-test port-forward svc/control-panel 8000:80
open http://localhost:8000
```

Every signal row should show a filled dot and a live rate. Expand any trace
signal and you will see the panel's own warning that no rule names it. Confirm
the same from the backend:

```bash
./verify.sh --only rules,traces
```

**What to point out.** `rules synced to the backend` is empty, and stored spans
match RED metrics almost exactly — measured at 95%, the gap being spans in
flight at the window edges. This is the unfiltered baseline every later step is
measured against: Signal Control is on, and it is doing nothing yet, because you
have given it no rules. Note the cost, too. Every `/health` span and every
healthcheck log is being stored, which is what the next step removes.

> [!TIP]
> Write the numbers down. Every claim in steps 3 to 6 is a comparison against
> this baseline, and it is far more convincing to show the delta than to assert
> it.

#### Making it look like one application

Before applying any rules, it is worth opening **Services → Catalog** and
**Services → Map**, because the test bed is deliberately set up to read as a
single application rather than a bag of unrelated workloads. Two attributes do
all of the work.

`service.namespace=sc-gen` is set on every workload that emits telemetry, and
it is what Dash0 groups the catalog and the map by:

| Workload | `service.name` | `service.namespace` | In the map? |
| --- | --- | --- | --- |
| checkout-service | `checkout-service` | `sc-gen` | yes, with an outgoing edge |
| inventory-service | `inventory-service` | `sc-gen` | yes, as its callee |
| metric-emitter | `sc-gen-metric-emitter` | `sc-gen` | catalog only |

The map edge comes from trace context, not from configuration. `/checkout`
makes a real HTTP call to inventory-service, the injected agent propagates
`traceparent` across it, and Dash0 infers the dependency from the resulting
parent-child spans. Nothing declares the topology.

> [!IMPORTANT]
> **The pod labels, not the environment variables, are the identity that covers
> everything.** These three:
>
> | Pod label | Becomes |
> | --- | --- |
> | `app.kubernetes.io/name` | `service.name` |
> | `app.kubernetes.io/part-of` | `service.namespace` |
> | `app.kubernetes.io/version` | `service.version` |
>
> are read by **two independent mechanisms**, covering both telemetry paths:
>
> 1. **SDK telemetry.** At admission the operator injects
>    `OTEL_INJECTOR_SERVICE_NAME` into each instrumented container as a *field
>    reference* to the pod label, and the injector turns it into `service.name`
>    on spans and metrics.
> 2. **Container logs.** The injected agent sets `OTEL_LOGS_EXPORTER=none`, so
>    logs are scraped from stdout by the node agent, which derives identity from
>    the same labels in a collector transform.
>
> Both defer to an explicit value: the operator skips injection for any
> container that sets `OTEL_SERVICE_NAME`, or `service.name=` inside
> `OTEL_RESOURCE_ATTRIBUTES`, and the log transform only fires when
> `service.name` is unset.
>
> The asymmetry is what bites. `OTEL_SERVICE_NAME` reaches **only** the SDK
> path, so a workload with the variable and no labels gets identified spans and
> *unidentified logs*. The labels reach both. And a plain `app:` label — the
> obvious thing to write, and what this repo used at first — is read by neither,
> so nothing is identified at all.
>
> You may not notice, because the backend correlates stored logs back to their
> pod and the UI then *shows* the right service. But that happens downstream of
> Signal Control, so a rule sees the unidentified resource. The visible symptom
> is a signal-to-metrics rule over logs: it has no `service.name` to keep, so
> its output metric is attributed to `service.name="signal-to-metrics"` while
> the equivalent rule over spans is attributed to the workload. Every workload
> here now carries both labels for exactly this reason.
>
> The workloads still set `OTEL_SERVICE_NAME` as well, which is now redundant
> for `service.name` — the labels would supply it. It is kept because it states
> each service's identity where a reader of the manifest looks for it, and
> because `OTEL_RESOURCE_ATTRIBUTES` is still doing real work:
> `deployment.environment.name` has no label equivalent.

Two things are worth knowing about the limits of this:

- **The metric emitter can appear in the catalog but never in the map.** It
  emits metrics only, and metrics carry no trace context, so there is no edge
  to infer. The shared `service.namespace` is what ties it to the other two.
- **The load generator is invisible on purpose.** It is labelled
  `dash0.com/enable: "false"`, so it is uninstrumented and produces no spans of
  its own. That keeps the span volume reaching Signal Control equal to what
  checkout-service and inventory-service generate, which is what makes the
  before-and-after numbers in the later steps clean. Remove the label and you
  gain a third node with an inbound edge, at the cost of every rule in steps 3
  to 5 also matching the generator's client spans.

> [!NOTE]
> Splitting `/inventory` out into its own service changed no telemetry volume.
> It is still three spans per `/checkout` with the same operation names and the
> same attributes; the `/inventory` SERVER span simply carries a different
> `service.name` now. The rules in `10` through `13` match on
> `dash0.operation.name` and HTTP attributes, never on `service.name`, so none
> of them needed changing.

### Step 3: two spam filters — `10`

One targets spans and the other log records, so between them they show that a
filter is scoped to a signal type rather than to an endpoint:

| Filter | Drops |
| --- | --- |
| `drop-health-spans` | `GET /health` spans |
| `drop-healthcheck-logs` | `healthcheck probe served` log records |

```bash
kubectl apply -f manifests/10-spam-filters.yaml
kubectl -n sc-test get dash0spamfilter
```

Give it up to 5 minutes to reach the edge collector, then:

```bash
./verify.sh --only rules,traces,logs
```

**What to point out.** Against the step 2 baseline, `GET /health` spans and
`healthcheck probe served` logs stop reaching storage entirely, and nothing else
moves. Measured before and after on the same cluster:

```
straddling the sync (10m)          fully after it (2m)
  25  GET /health [200]              (absent)
  41  healthcheck probe served       (absent)
```

`GET /health` also disappears from the **RED metrics**, not just from storage.
That is the lesson, and it surprises people: `dash0filter` runs ahead of the
`dash0redmetrics` connector, so a spam-filtered operation costs nothing at all —
but you also lose its RED series, so you cannot use RED to see what you filtered.
The control panel tags both rules `drop` on the `/health` row.

> [!IMPORTANT]
> Do not judge this by the clock. `synchronizedAt` records the operator's push
> to the Dash0 API, not the moment the edge collector enforces the rule — the
> edge proxy has to poll the settings feed first. Measured on a fresh cluster,
> the filters were still passing traffic at 3m21s and were enforced by 6m36s.
> Re-run `verify.sh` until the effect appears rather than waiting a fixed time.

### Step 4: signal-to-metrics — `11`

Metrics come before sampling here because that is the order the collector works
in. The `traces/sc/default` pipeline runs the spam filter from step 3, then
**fans the surviving spans out to three independent consumers**:

```
pipeline traces/sc/default
  otlp -> … -> dash0operation -> dash0filter
                                      |
     +--------------------------------+--------------------------+
     v                                v                          v
forward/traces-to-sampling     dash0redmetrics        dash0signaltometrics
     |                                |                          |
     v                                +------------+-------------+
traces/sampled  (step 5)                           v
                                        pipeline metrics/derived -> exporter
```

The two metric connectors are **siblings** of the sampling branch, not
downstream of it, and their output leaves through a separate `metrics/derived`
pipeline that the trace data never re-enters. Nothing the sampler decides can
reach them.

Doing this step first turns the sampling step that follows into a measurement
rather than a promise: derive the metrics, note the numbers, then throw almost
all the traces away and watch the numbers not move. You can read the pipeline
off your own cluster with:

```bash
kubectl -n dash0-system get cm dash0-operator-signal-control-collector-cm \
  -o jsonpath='{.data.config\.yaml}' | grep -A 12 'traces/sc/default:'
```

#### First: RED metrics you get for free

Before applying a rule, it is worth being clear that Signal Control is *already*
deriving metrics from spans, with no rule at all. The `dash0redmetrics` connector
turns every span into a duration histogram called `dash0.spans.red`, and that
synthetic metric is what **every RED number in the Dash0 app** is read from — the
request rates, error percentages and latency percentiles in the service catalog,
and the per-operation breakdown when you open a service. None of it is computed
from stored spans, which is why those numbers will still be correct in step 5,
once sampling has thrown most of the spans away.

It keeps **four span-derived attributes**, and only four:

| Attribute | Notes |
| --- | --- |
| `dash0.operation.name` | **Required.** A span without it produces no RED metric. |
| `dash0.operation.type` | **Required**, same. |
| `otel.span.kind` | `SERVER`, `CLIENT`, … |
| `otel.span.status.code` | This is the E in RED. |

On the resource side it keeps **everything** — the incoming resource map is
emitted verbatim, so all ~50 attributes ride along: every `k8s.*`, `process.*`,
`host.*`, `container.*` and `service.*` key, and every pod label and annotation.
Worth knowing before adding labels to a busy workload, since each one becomes a
dimension on a high-cardinality metric. `k8s.pod.label.pod-template-hash` is in
there too, so RED series turn over on every rollout.

> [!IMPORTANT]
> The required operation name is what silently excludes whole classes of span.
> Operation enrichment happens in the collector, one processor *before* the RED
> connector, and it only covers **SERVER, CONSUMER and root** spans. So the
> `/checkout` → inventory-service call — a CLIENT span with a parent — is never
> given an operation name and produces **no RED metric at all**. That is why
> `verify.sh` compares RED against stored spans *per operation* and buckets
> client spans separately: once the sampling step is in place, comparing the
> two totals would look like sampling had dropped something it did not.
>
> Do not read this off the stored span. Dash0 assigns operation names again on
> ingest, so a client span in the UI often *does* show a
> `dash0.operation.name` — long after the RED connector declined to count it.

So this step is not "how do I get metrics from spans" — you have those. It is how
to get a metric you *chose*, over the signals and dimensions you picked.

#### So when is a rule worth writing?

RED already answers "how is this operation doing", completely and for free. A
signal-to-metrics rule earns its place when it measures something RED
structurally cannot, and there are three of those:

- **A span RED skips.** A CLIENT span with a parent gets no operation name and
  so no RED metric, which means how long *your* service waits on a dependency is
  unavailable from RED at all. That is the gap the first rule fills.
- **A dimension RED does not keep.** RED's datapoint attributes are fixed at the
  four above. Anything else on the span — `net.peer.name`,
  `http.request.method`, a queue name, a tenant id — cannot become a label on
  `dash0.spans.red` at any cardinality. A rule picks its own.
- **A signal RED does not read.** RED is spans only. Counting log records — the
  second rule below — has no other route.

The mental model to leave people with: RED is one fixed-shape metric per
operation, produced for everything, whether or not anyone asked. A
signal-to-metrics rule is a narrow, named metric over a slice you chose, with
the dimensions you chose, at the interval you chose.

#### Now the rules

```bash
kubectl apply -f manifests/11-signal-to-metrics.yaml
kubectl -n sc-test get dash0signaltometrics
```

Wait up to 5 minutes, then:

```bash
./verify.sh --only metrics
```

**What to point out.** The rules pick up where RED stops.
`sc_test.dependency.duration` matches `otel.span.kind = CLIENT`, so it measures
the checkout-service → inventory-service call broken out by `net.peer.name` — a
span RED refuses and a label RED cannot carry. There is deliberately no RED
series to compare it to; that is the point. `sc_test.checkout.failures` counts
log records, which RED never looks at.

**Write the numbers down before moving on.** Both metrics, and the RED series,
are about to be put through a sampler that discards almost everything. Step 5
is where they either hold or they don't.

> [!WARNING]
> **`keepSignalAttributes` names must match the raw span, not the span you see
> in Dash0.** The connector copies attributes off the span as it arrives at the
> collector. Dash0 normalises old semantic conventions to current ones on
> ingest — deliberately, so that conventions are consistent across the platform
> regardless of SDK age — but that happens *after* the edge. The Node agent
> here still emits `http.method` and
> `http.status_code`; the UI shows them as `http.request.method` and
> `http.response.status_code`. A rule that names what the UI shows matches the
> spans fine and then keeps **nothing** — you get a valid metric that is just
> missing the labels you asked for, with no error anywhere. `11` lists both
> spellings for exactly this reason. If a label you expected is absent, suspect
> this before anything else.
>
> The reverse also holds: `otel.span.status.code` appears on the metric even
> though the rule never asks for it. Span rules always get it, so there is no
> need to list it.

### Step 5: sampling rules — `12`

```bash
kubectl apply -f manifests/12-sampling-rules.yaml
kubectl -n sc-test get dash0samplingrule
```

Wait up to 5 minutes, then:

```bash
./verify.sh --only rules,traces,metrics
```

**What to point out.** Two things now, and the second is the one that lands.

First, traces come back selectively. Every `GET /checkout [500]` is retained by
`keep-all-errors`; roughly a quarter of the `[200]`s by `sample-checkout-25pct`;
`GET /orders/:id` appears only at the 1% baseline. Each rule shows on its signal
row in the panel, tagged `keep`.

Second, compare the metrics section against the numbers you noted in step 4.
Stored traces have collapsed, while `sc_test.dependency.duration`,
`sc_test.checkout.failures` and the RED series **keep climbing at the same
rate** — they are counting every signal the spam filter passed, whatever the
sampler then decided, because they were derived on a branch the sampler never
touches. Run it twice a minute apart if you want the rate rather than the
totals. That is the whole argument for Signal Control: sample as hard as the
budget demands and keep the numbers anyway.

Note the qualifier. These metrics see 100% of what reaches the connectors, which
is 100% of what **step 3 let through** — a spam-filtered operation has no RED
series and cannot be counted by a rule either. Sampling is free of that
tradeoff; spam filtering is not.

To show one rule's contribution in isolation, delete the others and put them
back. Rules are OR'd, so removing one only ever retains less:

```bash
kubectl -n sc-test delete dash0samplingrule baseline-sample-1pct \
  sample-checkout-25pct rate-limit-search
./verify.sh --only traces --window 10m      # errors only

kubectl apply -f manifests/12-sampling-rules.yaml
```

### Step 6: time series aggregation — `13`

```bash
kubectl apply -f manifests/13-time-series-aggregation.yaml
kubectl -n sc-test get dash0timeseriesaggregation
```

Wait up to 5 minutes, then:

```bash
./verify.sh --only metrics
```

Three rules against the emitter's metrics:

| Rule | Priority | Match | Setting | Shows |
| --- | --- | --- | --- | --- |
| spatial | 2 | `sc_gen.synthetic.gauge` | `drop_attributes` on `sc_gen.tier`, context **datapoint**, interval **10s** | 18 series → 9 |
| temporal | 2 | `sc_gen.synthetic.counter` | interval **1m** | 10s → 60s sampling |
| catchall | 3 | `starts_with sc_gen` | interval **5m** | nothing — see below |

**What to point out.** Two things.

First, volume is `series × samples per series`, and the first two rules move
different factors. See
[Measuring a time series aggregation rule](#measuring-a-time-series-aggregation-rule)
for the arithmetic and the traps, especially the `context` one — a rule with the
wrong context syncs cleanly, drops nothing, and *increases* volume.

Second, `catchall` is the precedence lesson, and it is worth the two minutes.
It matches **both** metrics the other rules match, and at a far more aggressive
5m interval — yet it changes nothing. Only one rule is ever applied to a
datapoint, and the **lower `priority` wins**, so `spatial` and `temporal` at 2
keep their metrics. Raise `catchall` to `1`, wait, and re-run: it takes both
over and the other two go quiet. That is the whole model — matching is not
winning.

> [!IMPORTANT]
> Operator `0.155.0` added `Dash0TimeSeriesAggregation`. Before it, aggregation
> was the one rule type with no CRD, so this step had to be recreated by hand
> in the Dash0 UI for every new org. If you are on `0.154.0` or earlier the CRD
> does not exist and `kubectl apply` fails — use the UI, or upgrade.

> [!NOTE]
> **Every** Signal Control rule lives in the org, this one included. The
> operator does not evaluate the CRs in your cluster: it syncs each one to the
> Dash0 API and the rule then applies org-wide within its dataset. The
> `.status.synchronizationStatus` field on a CR is reporting exactly that push.
>
> A corollary worth stating: a rule is **not** scoped to the namespace its CR
> sits in. The namespace only decides which dataset it is pushed to. A
> `Dash0SamplingRule` in `sc-test` governs everything in that dataset.

### Resetting between runs

Take the rules away and keep the traffic, to get back to the step 2 baseline
without waiting for pods:

```bash
kubectl delete -f manifests/10-spam-filters.yaml \
               -f manifests/11-signal-to-metrics.yaml \
               -f manifests/12-sampling-rules.yaml \
               -f manifests/13-time-series-aggregation.yaml
```

## What each file does

### The workload

- **[manifests/00-namespace.yaml](manifests/00-namespace.yaml).** Creates the
  `sc-test` namespace. Applying it against a cluster that already has the
  namespace is a no-op.
- **[manifests/01-dash0-monitoring.yaml](manifests/01-dash0-monitoring.yaml).**
  A `Dash0Monitoring` resource with `instrumentWorkloads.mode: all`. This is
  what auto-instruments checkout-service and inventory-service and collects
  their logs. Without it the namespace produces no telemetry.
- **[manifests/02-checkout-service.yaml](manifests/02-checkout-service.yaml).**
  A dependency-free Node.js HTTP server, source inlined in a ConfigMap and run
  on the stock `node:22-alpine` image. No build, no registry, no image pull
  beyond a public base image. `/checkout` calls inventory-service, so it
  produces a three-span distributed trace and you can see whether a sampling
  decision applies to the whole trace or just one span.
- **[manifests/03-inventory-service.yaml](manifests/03-inventory-service.yaml).**
  The downstream half of that trace, serving the single `/inventory` call. It
  exists so the trace crosses a service boundary: the injected agent propagates
  `traceparent` on the outbound call, which is what lets Dash0 draw a
  **checkout-service → inventory-service edge** in the service map. `/inventory`
  used to be a handler on checkout-service calling `127.0.0.1`, which produced
  the same three spans but no edge, because both ends were the same service.

  Numbered `03`, straight after checkout-service, since the two are one request
  path. Neither has to be applied first: checkout-service retries per request,
  so whichever starts second just ends the brief window where `/checkout`
  returns 500.

  > [!NOTE]
  > Both set `OTEL_SERVICE_NAME` explicitly, which is belt-and-braces rather
  > than required: their `app.kubernetes.io/name` pod label already gives the
  > operator what it needs to inject a service name. Setting the variable makes
  > the operator skip that derivation, and the value is identical either way.
  >
  > What a new workload actually cannot do without is **one of the two**. With
  > neither the label nor the variable, the Node SDK falls back to its own
  > default and every span, log and RED metric arrives as
  > `service.name="unknown_service:node"` — even though `k8s.deployment.name` is
  > set correctly. The label is the better choice of the two, because it also
  > covers container logs, which the variable does not.

  > [!NOTE]
  > Both also set `OTEL_RESOURCE_ATTRIBUTES=service.namespace=sc-gen,...`, and
  > the metric emitter sets the same `service.namespace` on its own resource.
  > That attribute is what makes Dash0 present these as components of one
  > application rather than unrelated services that happen to share a cluster —
  > it groups them in the catalog and the map. See
  > [Making it look like one application](#making-it-look-like-one-application).
- **[manifests/04-load-profile.yaml](manifests/04-load-profile.yaml).** A
  ConfigMap defining the traffic: one entry per stream, with a path, a request
  interval, and the `dash0.operation.name` its spans will carry. **This is the
  file you edit to change what the test bed sends.** The generator re-reads it
  every 10 seconds, so an edit takes effect without a restart. Allow up to a
  minute for kubelet to propagate the change into the pod.
- **[manifests/05-load-generator.yaml](manifests/05-load-generator.yaml).** A
  dependency-free Node generator that drives one loop per stream and reports
  what it actually sent on `GET /stats`. Labelled `dash0.com/enable: "false"`
  so the operator leaves it uninstrumented: only checkout-service spans reach
  Signal Control, and the generator's own stats endpoint produces no telemetry.
- **[manifests/06-metric-emitter.yaml](manifests/06-metric-emitter.yaml).**
  Emits synthetic OTLP metrics every 10 seconds, for experimenting with time
  series aggregation. Ships a gauge and a monotonic sum, each with 18 series:
  one per combination of `sc_gen.service` × `sc_gen.region` × `sc_gen.tier`.
  Find them in Dash0 with the constant attribute `sc_gen.source="sc-gen"`.

  Attribute keys use dots in OTLP and underscores in PromQL:

  ```promql
  {otel_metric_name="sc_gen.synthetic.gauge", sc_gen_source="sc-gen"}
  sum by (sc_gen_region) ({otel_metric_name="sc_gen.synthetic.gauge"})
  sum by (sc_gen_tier) (rate({otel_metric_name="sc_gen.synthetic.counter"}[5m]))
  ```

  It posts OTLP/JSON directly to the node-local collector on port 40318, the
  same endpoint the operator injects into instrumented workloads. The collector
  accepts JSON as well as protobuf on `/v1/metrics`, which is what keeps the
  emitter dependency-free: no OTel SDK, no protobuf, no build step. Edit the
  metric names, dimensions, and interval in the `metric-profile` ConfigMap.

  > [!WARNING]
  > Do not set `startupDelaySeconds` to 0. Resource enrichment is not complete
  > the instant a pod starts, and an emit that lands before it finishes gets a
  > different resource identity, which splits every series in two and doubles
  > any sum across them.

The traffic mix is deliberate. Each stream exists to be a target for one kind of
rule:

| Endpoint | Rate | What it is for |
| --- | --- | --- |
| `/health` | ~5/s | High-volume, zero-value telemetry. The spam-filter target. |
| `/checkout` | ~1/s | Distributed three-span trace across two services, 12% HTTP 500. Error and probabilistic sampling, plus signal-to-metrics. |
| `/search?q=<rand>` | ~0.5/s | The rate-limit target. |
| `/orders/<rand>` | ~0.5/s | A high-cardinality path, and a workload with no rule of its own. |

### The control panel

**[manifests/07-control-panel.yaml](manifests/07-control-panel.yaml)** is a web
UI for the test bed. It is numbered `06` so that `kubectl apply -f manifests/`
brings it up **before** the rules in `10` to `13`: the panel is how you watch
each rule land, so it needs to be running and showing an unfiltered baseline
before the first rule exists. Reach it with a port-forward:

```bash
kubectl -n sc-test port-forward svc/control-panel 8000:80
open http://localhost:8000
```

It gives you two things:

- **A toggle per generating workload**, load generator and metric emitter, each
  scaling its Deployment between 0 and 1 replicas. Traffic stops within a few
  seconds and starts again in about ten.
- **A live list of the signals**, one row per signal, each showing:
  - its OTLP **signal type** as a badge: `traces`, `logs`, or `metrics`
  - the **attributes** it carries, with an example value, behind an expander
  - the observed rate against the configured one
  - the Signal Control rules that target it, tagged `drop`, `keep`, or `metric`,
    with an out-of-sync rule flagged inline

For metric signals the attribute table also gives the PromQL label name, since
PromQL turns `sc_gen.region` into `sc_gen_region`, and each row carries two
ready-made queries to paste into Dash0.

The list is not a hardcoded copy of the traffic table above. The panel reads the
same `load-profile` and `metric-profile` ConfigMaps the workloads run from, asks
each workload what it actually sent, and reads the rule custom resources from
the cluster. Edit a profile and the panel follows.

The declared attributes were read off real telemetry from this test bed, not
copied from the semantic conventions. That matters: the injected Node.js agent
emits old-semconv HTTP attributes, so `url.path` does not exist here and a rule
written against it never matches.

> [!NOTE]
> RED metrics (`dash0.spans.red`) are derived from spans by the collector rather
> than produced by a workload, so they are not listed as signals. `verify.sh`
> shows them.

> [!NOTE]
> The panel matches a rule to a signal by looking for the signal's
> `dash0.operation.name` in the rule's spec. It is a textual match, not an OTTL
> evaluation. Rules that key on something else, such as a log body or the error
> flag, cannot be attributed to one signal and are listed separately. They still
> apply.

> [!NOTE]
> Before any rule is applied, every trace signal shows the panel's "no rule
> names this signal" warning. That is the correct no-rules baseline, not a
> misconfiguration.

It talks to the Kubernetes API with its own ServiceAccount. The Role is
namespaced and deliberately narrow: `get` and `patch` on the two named
Deployments' `scale` subresource, `get` on the two named ConfigMaps, `list` on
pods, and `list` on the three Signal Control rule kinds. Patching `scale` rather
than the Deployment means the panel cannot change an image, a command, or
anything else about a pod. Nothing in the panel edits a rule.

There is no authentication. It assumes whoever can port-forward to it is already
allowed to change the test bed. Do not expose it with an Ingress or a
LoadBalancer.

### The rules

These come last in the apply order on purpose, so the test bed has a visible
unfiltered baseline before any of them exist. Each is an example to read and
edit, not a recommended production config. Delete the ones you do not want.

- **[manifests/10-spam-filters.yaml](manifests/10-spam-filters.yaml).** Two
  `Dash0SpamFilter` resources that drop `/health` spans and their debug log
  lines at the edge, before they leave the cluster.
- **[manifests/11-signal-to-metrics.yaml](manifests/11-signal-to-metrics.yaml).**
  Two `Dash0SignalToMetrics` resources: a dependency-latency histogram derived
  from CLIENT spans, and a failure counter derived from log records. Both are
  chosen to be things RED metrics cannot produce. They are numbered ahead of the
  sampling rules because the collector derives metrics on a branch that parallels
  the sampling pipeline rather than following it, so they stay accurate no matter
  how little the sampler retains.
- **[manifests/12-sampling-rules.yaml](manifests/12-sampling-rules.yaml).** Four
  `Dash0SamplingRule` resources covering the distinct condition kinds: keep all
  errors, keep 25% of one operation via `and(ottl, probabilistic)`, rate-limit
  one operation to 10/min, and a 1% baseline under everything else. Rules are
  OR'd, so the baseline adds to what the others keep rather than diluting it.
- **[manifests/13-time-series-aggregation.yaml](manifests/13-time-series-aggregation.yaml).**
  Three `Dash0TimeSeriesAggregation` resources against the emitter's metrics:
  one spatial (drops an attribute, collapsing series), one temporal (resamples
  slower, cutting samples per series), and a deliberately inert catchall that
  matches both of the others' metrics at a more aggressive interval and still
  changes nothing — because only one rule applies per datapoint and the lower
  `priority` wins. Requires operator `0.155.0`, which introduced the CRD.

To add them one step at a time and see each one take effect, follow
[Guided rollout](#guided-rollout-adding-the-rules-one-step-at-a-time) rather
than applying the whole directory.

### The verifier

**[verify.sh](verify.sh)** reads the cluster's own ingest token from the
operator's authorization secret and queries the Dash0 API with it. It prints, in
order:

1. Whether each rule synced to the backend.
2. What the edge collector actually compiled, from `/api/edge/settings` and
   `/api/sampling-rules`.
3. RED metrics per operation, which are generated pre-sampling and so show total
   traffic.
4. Spans that survived to storage, counted by operation and status code.
5. Log records that survived, counted by message.

> [!IMPORTANT]
> A single `/api/spans` or `/api/logs` response returns at most 200 records, so
> counting one response under-reports any busy window. `verify.sh` walks the
> window in sub-ranges instead and de-duplicates across them. If you query
> those endpoints yourself, do the same — otherwise a busy window reads as
> exactly 200 and you will draw conclusions from a ceiling rather than a count.
6. The signal-to-metrics output series.

Comparing 3 against 4 is the whole point: RED shows what was generated, stored
spans show what the rules kept.

Reading the token from the cluster secret is deliberate. Your cluster may ship
to a different Dash0 org than the one your browser or MCP connector is logged
into, and in that case the UI shows you nothing while the data is landing fine.
The token settles the question.

Configure it with environment variables:

| Variable | Default | Notes |
| --- | --- | --- |
| `DASH0_API_URL` | `https://api.eu-west-1.aws.dash0.com` | Set this to your region's API host. |
| `DASH0_DATASET` | `default` | |
| `DASH0_AUTH_TOKEN` | read from the cluster secret | Set it to skip the `kubectl get secret` lookup. |
| `SECRET_NAMESPACE` | `dash0-system` | Where the operator's auth secret lives. |
| `SECRET_NAME` | `dash0-authorization-secret` | |
| `NAMESPACE` | `sc-test` | Must match the namespace in the manifests. |
| `METRIC_PREFIX` | `sc_test` | Must match the output names in `11-signal-to-metrics.yaml`. |
| `EMITTER_METRICS` | the two `sc_gen.synthetic.*` metrics | Space-separated. Volume is decomposed for each. |
| `RATIO_WINDOW` | `30m` | `rate()` window for the aggregation in/out ratio. |

```bash
# Last 15 minutes, against a US region.
DASH0_API_URL=https://api.us-west-2.aws.dash0.com ./verify.sh 900
```

Requirements: `kubectl`, `python3`, and `bash`.

It is concise by default. Flags:

| Flag | What it does |
| --- | --- |
| `--only <sections>` | Comma-separated from `rules`, `traces`, `logs`, `metrics`. Default all. |
| `-v`, `--verbose` | Add trend charts over the lookback and fuller breakdowns. |
| `--window <dur>` | Measurement window for stored-signal and datapoint counts. Default `5m`. |
| `--before <dur>` | Compare metric volume now against that long ago, and split the change into spatial and temporal. |
| `<seconds>` | Lookback for the verbose trend charts. Default `3600`. |

### Measuring a time series aggregation rule

Datapoint volume is the product of two independent factors:

```
datapoints/min  =  series count  x  samples per series per minute
                   (spatial)        (temporal)
```

Spatial aggregation drops labels, so series count falls and the interval holds.
Temporal aggregation resamples, so series count holds and the interval grows.
A measure that sees only one factor will report no change when the other one
moves.

```bash
./verify.sh --only metrics --before 45m
```

```
metric                                series        interval            dp/min    volume
sc_gen.synthetic.gauge            18 -> 9       10.0s ->  12.0s   108.0 ->   45.0     58.3%
                               spatial 50.0% fewer series | temporal 16.7% fewer samples per series
sc_gen.synthetic.counter          18 -> 18      10.0s ->  77.1s   108.0 ->   14.0     87.0%
                               spatial none, series count unchanged | temporal 87.0% fewer samples per series
```

Both measured against real rules: a `drop_attributes` rule on the gauge and a
1 minute resample on the counter. The gauge shows spatial, the counter shows
temporal. Dash0's own per-rule counter independently reported 50.0% and 83.3%
for the same two rules.

> [!IMPORTANT]
> A rule always carries a `sample.interval`; it cannot be disabled. To isolate a
> spatial change, set the interval equal to the source emission interval. Expect
> a few percent of residual temporal reduction from aliasing, the 16.7% above.

> [!CAUTION]
> A dropped attribute keeps its label with one arbitrary value. After dropping
> `sc_gen.tier`, all 9 surviving series carry `sc_gen_tier="free"` while
> aggregating both `free` and `pro`. Queries filtering `tier="free"` therefore
> include `pro`, and `tier="pro"` returns nothing. Do not trust the value of a
> label that survived an aggregation — check what the rule aggregated over.

> [!WARNING]
> `context` in a `drop_attributes` rule must match the attribute's OTLP level.
> This repo's `sc_gen.*` attributes are **datapoint** attributes; the emitter's
> scope has no attributes at all. A wrong context syncs cleanly, drops nothing,
> and still creates an aggregated variant, so volume goes **up**: 18 series
> became 36 and datapoints rose 4.8%.

> [!NOTE]
> Keep `RATIO_WINDOW` inside the rule's lifetime. A window reaching back before
> the rule started working reported 19.5% for a rule genuinely cutting 50%. The
> script now flags this automatically.

> [!CAUTION]
> Scope `dash0.signal_control.metric_data_points_{in,out}` by
> `dash0_signal_control_component` before dividing them. Unscoped they are not a
> matched pair, and their ratio read 0.99 while aggregation was really cutting
> 90% of its input.

> [!NOTE]
> An aggregated series is a **new** series: Dash0 tags it with
> `dash0_metric_datapoint_interval` and `dash0_tsa_instance_id`. Raw and
> aggregated variants coexist in any window that straddles the change, so a
> plain `count()` can report double the series you expect. The script splits
> them by that label.

> [!WARNING]
> Aggregation rules execute in the Dash0 backend, not at the edge collector, so
> `timeSeriesAggregationSettings` in `/api/edge/settings` stays empty even with
> a working rule. That empty list is not the bug you are looking for — check
> `/api/time-series-aggregations` instead, which is where they show up.
>
> This is the one rule type whose CR is declared in the cluster but never
> evaluated there at all: `Dash0TimeSeriesAggregation` (operator `0.155.0`+) is
> a management interface onto a backend rule. Its metering therefore arrives
> tagged `dash0.signal_control.environment="saas"`, never `edge`.

## Running in a different namespace

Change the name in `00-namespace.yaml`, in the `metadata.namespace` of every
other manifest, and in the metric output names in `11-signal-to-metrics.yaml`.
Then pass `NAMESPACE` and `METRIC_PREFIX` to `verify.sh`.

There is no templating here on purpose. The manifests are meant to be read and
edited by hand.

## License

MIT. See [LICENSE](LICENSE).

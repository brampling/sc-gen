#!/usr/bin/env bash
# Verify Signal Control rule behaviour against a live Dash0 org.
#
# Reads the cluster's own ingest token out of the operator's authorization
# secret, then queries the Dash0 API directly. That matters when the cluster
# ships to a different org than the one your browser or MCP connector is logged
# into: the token is the ground truth for where the telemetry actually landed.
#
# Usage:
#   ./verify.sh                       # concise, every section
#   ./verify.sh --only metrics        # one signal type
#   ./verify.sh --only traces,logs
#   ./verify.sh -v --only metrics     # add trends and per-series detail
#   ./verify.sh --window 15m          # measurement window for datapoint counts
#   ./verify.sh --before 1h           # compare volume now against 1h ago
#   ./verify.sh 1800                  # lookback in seconds for trend charts
#
# Sections: rules, traces, logs, metrics. Default: all.
#
# Environment:
#   DASH0_API_URL    default https://api.eu-west-1.aws.dash0.com
#   DASH0_DATASET    default "default"
#   DASH0_AUTH_TOKEN default: read from the secret below
#   SECRET_NAMESPACE default dash0-system
#   SECRET_NAME      default dash0-authorization-secret
#   NAMESPACE        default sc-test
#   METRIC_PREFIX    default sc_test   (matches 11-signal-to-metrics.yaml)
#   EMITTER_METRICS  default the two sc_gen.synthetic.* metrics
#   RATIO_WINDOW     default 30m       (rate() window for the in/out ratio)
set -euo pipefail

LOOKBACK=3600
ONLY=all
VERBOSE=0
WINDOW=5m
BEFORE=

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    --window) WINDOW="$2"; shift 2 ;;
    --window=*) WINDOW="${1#*=}"; shift ;;
    --before) BEFORE="$2"; shift 2 ;;
    --before=*) BEFORE="${1#*=}"; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    ''|*[!0-9]*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) LOOKBACK="$1"; shift ;;
  esac
done

NAMESPACE="${NAMESPACE:-sc-test}"
SECRET_NAMESPACE="${SECRET_NAMESPACE:-dash0-system}"
SECRET_NAME="${SECRET_NAME:-dash0-authorization-secret}"

if [[ -n "${DASH0_AUTH_TOKEN:-}" ]]; then
  TOKEN="$DASH0_AUTH_TOKEN"
else
  TOKEN=$(kubectl get secret -n "$SECRET_NAMESPACE" "$SECRET_NAME" \
    -o jsonpath='{.data.token}' | base64 -d) || {
    echo "Could not read the ingest token from secret $SECRET_NAMESPACE/$SECRET_NAME." >&2
    echo "Set DASH0_AUTH_TOKEN instead, or point SECRET_NAMESPACE/SECRET_NAME at your secret." >&2
    exit 1
  }
fi

# The kubectl-sourced parts stay in bash; everything that builds a PromQL query
# lives in the Python program below, because escaping label selectors through
# bash into curl --data-urlencode is a reliable source of quoting bugs.
want() {
  [[ "$ONLY" == all ]] && return 0
  [[ ",$ONLY," == *",$1,"* ]] && return 0
  return 1
}

if want rules; then
  echo "=== rules synced to the backend ==="
  # dash0timeseriesaggregations needs operator 0.155.0 or later; on older
  # operators the CRD is absent and kubectl errors on the whole request, so it
  # is queried separately and its failure ignored.
  kubectl get dash0samplingrules,dash0spamfilters,dash0signaltometrics -n "$NAMESPACE" \
    -o custom-columns='KIND:.kind,NAME:.metadata.name,SYNC:.status.synchronizationStatus'
  kubectl get dash0timeseriesaggregations -n "$NAMESPACE" \
    -o custom-columns='KIND:.kind,NAME:.metadata.name,SYNC:.status.synchronizationStatus' \
    2>/dev/null | tail -n +2 || true
  echo "  (on a failure, the reason is in .status.synchronizationResults[].synchronizationError)"
  echo
fi

TOKEN="$TOKEN" \
DASH0_API_URL="${DASH0_API_URL:-https://api.eu-west-1.aws.dash0.com}" \
DASH0_DATASET="${DASH0_DATASET:-default}" \
SC_NAMESPACE="$NAMESPACE" \
METRIC_PREFIX="${METRIC_PREFIX:-sc_test}" \
EMITTER_METRICS="${EMITTER_METRICS:-sc_gen.synthetic.gauge sc_gen.synthetic.counter}" \
RATIO_WINDOW="${RATIO_WINDOW:-30m}" \
SC_ONLY="$ONLY" SC_VERBOSE="$VERBOSE" SC_WINDOW="$WINDOW" SC_LOOKBACK="$LOOKBACK" \
SC_BEFORE="$BEFORE" \
python3 - <<'PYEOF'
import json, os, time, datetime, urllib.parse, urllib.request, collections

TOKEN = os.environ['TOKEN']
BASE = os.environ['DASH0_API_URL'].rstrip('/')
DATASET = os.environ['DASH0_DATASET']
NAMESPACE = os.environ['SC_NAMESPACE']
METRIC_PREFIX = os.environ['METRIC_PREFIX']
EMITTER_METRICS = os.environ['EMITTER_METRICS'].split()
RATIO_WINDOW = os.environ['RATIO_WINDOW']
ONLY = os.environ['SC_ONLY']
VERBOSE = os.environ['SC_VERBOSE'] == '1'
WINDOW = os.environ['SC_WINDOW']
BEFORE = os.environ.get('SC_BEFORE', '')
LOOKBACK = int(os.environ['SC_LOOKBACK'])

NOW = int(time.time())
START = NOW - LOOKBACK


def want(section):
    return ONLY == 'all' or section in ONLY.split(',')


def seconds(window):
    unit = window[-1]
    n = float(window[:-1])
    return n * {'s': 1, 'm': 60, 'h': 3600, 'd': 86400}[unit]


def api(path, params=None, body=None):
    url = f'{BASE}{path}'
    sep = '&' if '?' in url else '?'
    url = f'{url}{sep}dataset={DATASET}'
    if params:
        url = f'{url}&{urllib.parse.urlencode(params)}'
    headers = {'Authorization': f'Bearer {TOKEN}', 'Accept': 'application/json'}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=45) as r:
            return json.load(r)
    except Exception as e:
        return {'status': 'error', 'error': str(e)}


# The /api/spans and /api/logs endpoints truncate a response to 200 records and
# say nothing about it. `pageSize` asks for more and is ignored, and the opaque
# cursors the response carries were not honoured by any request parameter we
# could find. Counting a single response therefore under-reports any busy
# window: measured 200 against a true 1722 over ten minutes, an 8.6x error that
# silently became wrong conclusions about what sampling had retained.
#
# So walk the window in sub-ranges. Start with one call, and whenever a range
# comes back saturated, shrink the chunk and retry that same position; once a
# size works it is reused for the rest of the walk. A quiet window still costs
# a single request. Records are de-duplicated because range edges may overlap.
PAGE_CAP = 200
MAX_CALLS = 400


def _rel(offset):
    """An offset in seconds before now, in the API's relative time syntax."""
    return 'now' if offset <= 0 else f'now-{int(round(offset))}s'


def walk_records(path, container, scope_key, record_key, ident, window):
    """Every record in the last `window`, defeating the 200-record cap.

    Returns (records, truncated). `truncated` is True when a range stayed
    saturated at the finest granularity attempted, making the count a floor.
    """
    total = seconds(window)
    out = {}
    truncated = False
    chunk = total
    pos = total
    calls = 0

    while pos > 0 and calls < MAX_CALLS:
        end = max(0.0, pos - chunk)
        d = api(path, body={
            'timeRange': {'from': _rel(pos), 'to': _rel(end)},
            'pageSize': 500,
            'filter': [{'key': 'k8s.namespace.name',
                        'operator': 'is', 'value': NAMESPACE}],
        })
        calls += 1

        if d.get('status') == 'error':
            truncated = True
            pos = end
            continue

        batch = []
        for res in d.get(container, []):
            for scope in res.get(scope_key, []):
                batch.extend(scope.get(record_key, []))

        # Saturated: this range hides an unknown number of records. Shrink and
        # retry the same position rather than accepting a truncated count.
        if len(batch) >= PAGE_CAP and chunk > 1:
            chunk = max(1.0, chunk / 4)
            continue
        if len(batch) >= PAGE_CAP:
            truncated = True

        for rec in batch:
            out[ident(rec)] = rec
        pos = end

    if pos > 0:
        truncated = True
    return list(out.values()), truncated


def span_ident(sp):
    return (sp.get('traceId'), sp.get('spanId'))


def log_ident(lr):
    return (
        lr.get('timeUnixNano'),
        lr.get('observedTimeUnixNano'),
        lr.get('severityNumber'),
        json.dumps(lr.get('body', {}), sort_keys=True),
    )


def cap_warning(truncated):
    if truncated:
        print("    WARNING: a sub-range stayed at the API's 200-record cap even")
        print('    after splitting, so this count is a floor, not a total.')


def instant(query):
    """Return {frozenset(labels): value} for an instant query."""
    d = api('/api/prometheus/api/v1/query', {'query': query})
    if d.get('status') != 'success':
        return None
    out = {}
    for s in d['data']['result']:
        labels = {k: v for k, v in s['metric'].items()}
        out[json.dumps(labels, sort_keys=True)] = float(s['value'][1])
    return out


def scalar(query):
    r = instant(query)
    if r is None or not r:
        return None
    return sum(r.values())


def trend(query, label, step=None, keep=None):
    step = step or max(60, LOOKBACK // 20)
    d = api('/api/prometheus/api/v1/query_range',
            {'query': query, 'start': START, 'end': NOW, 'step': step})
    print(f'  -- {label}')
    if d.get('status') != 'success':
        print(f'     ERR {json.dumps(d)[:200]}')
        return
    res = d['data']['result']
    if not res:
        print('     (no series)')
        return
    for s in res[:12]:
        labels = {k: v for k, v in s['metric'].items() if k != 'otel_metric_name'}
        if keep:
            labels = {k: v for k, v in labels.items() if k in keep}
        name = ', '.join(str(v) for v in labels.values()) or 'total'
        pts = [(datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime('%H:%M'),
                round(float(v), 1)) for t, v in s['values']][-14:]
        print(f'     {name[:46]:46}', pts)


def fmt(v, spec='.1f', dash='-'):
    return dash if v is None else format(v, spec)


# ---------------------------------------------------------------- rules
if want('rules'):
    print('=== compiled rules at the edge ===')
    d = api('/api/edge/settings')
    if d.get('status') == 'error':
        print(f'  ERR {d["error"]}')
    else:
        # signalControlEdge is an ORG entitlement flag ("this org may use
        # Signal Control"), not a statement about this cluster -- the request
        # carries no cluster identity. It reads enabled:true before the
        # operator is installed and after it is removed, so never treat it as
        # an install check. Labelled 'org entitled' here for that reason.
        # It is also a pre-release gate expected to vanish at GA.
        ent = (d.get('signalControlEdge') or {}).get('enabled')
        print(f'  org: {d.get("technicalID")} | org entitled to signal control: {ent}')
        filters = [f for s in d.get('datasetSettings', []) for f in s.get('telemetryFilters', [])]
        # timeSeriesAggregationSettings is the EDGE-side list and stays empty
        # for a normal aggregation rule: those execute in the SaaS backend
        # (dash0_signal_control_environment="saas"), not at the edge collector.
        # The metrics section reads /api/time-series-aggregations instead.
        print(f'  spam filters: {len(filters)} | signal-to-metrics: {len(d.get("signalToMetricsSettings", []))}'
              f' | edge-side aggregations: {len(d.get("timeSeriesAggregationSettings", []))}')
        if VERBOSE:
            for f in filters:
                print(f'    [{f.get("context")}] {(f.get("condition") or "")[:150]}')
    sr = api('/api/sampling-rules')
    rules = sr.get('samplingRules', []) if sr.get('status') != 'error' else []
    print(f'  sampling rules: {len(rules)}')
    if VERBOSE:
        for r in rules:
            print(f'    {r["metadata"]["name"]}: {json.dumps(r["spec"].get("conditions"))[:110]}')
    print()


# --------------------------------------------------------------- traces
if want('traces'):
    print('=== traces ===')
    print('  RED metrics count ALL spans, generated before sampling. A')
    print('  spam-filtered operation drops to zero here too, because dash0filter')
    print('  runs ahead of the dash0redmetrics connector.')
    red = instant('sum by (dash0_operation_name) ({otel_metric_name="dash0.spans.red"})')
    if red:
        rows = []
        for k, v in red.items():
            op = json.loads(k).get('dash0_operation_name', '?')
            rows.append((op, v))
        for op, v in sorted(rows, key=lambda x: -x[1])[:12]:
            print(f'    {op[:44]:44} {v:12.0f} spans (cumulative)')
    else:
        print('    (no RED series)')

    spans, truncated = walk_records('/api/spans', 'resourceSpans', 'scopeSpans',
                                    'spans', span_ident, WINDOW)
    c = collections.Counter()
    for sp in spans:
        a = {x['key']: list(x['value'].values())[0] for x in sp.get('attributes', [])}
        c[(a.get('dash0.operation.name'), a.get('http.response.status_code'))] += 1
    print(f'  stored spans in the last {WINDOW}: {len(spans)}')
    for k, v in c.most_common(20 if VERBOSE else 8):
        print(f'    {v:5d}  {k[0]} [{k[1]}]')
    cap_warning(truncated)
    if VERBOSE:
        trend('sum by (dash0_operation_name) ({otel_metric_name="dash0.spans.red"})',
              'RED metrics by operation', keep={'dash0_operation_name'})
    print()


# ----------------------------------------------------------------- logs
if want('logs'):
    print('=== logs ===')
    records, truncated = walk_records('/api/logs', 'resourceLogs', 'scopeLogs',
                                      'logRecords', log_ident, WINDOW)
    c = collections.Counter()
    for lr in records:
        b = lr.get('body', {}).get('stringValue', '')
        try:
            b = json.loads(b).get('message', b)
        except Exception:
            pass
        c[b[:60]] += 1
    print(f'  stored log records in the last {WINDOW}: {len(records)}')
    for k, v in c.most_common(10 if VERBOSE else 5):
        print(f'    {v:5d}  {k}')
    cap_warning(truncated)
    print()


# -------------------------------------------------------------- metrics
if want('metrics'):
    print('=== metrics ===')

    # -- signal-to-metrics output
    # Names come from manifests/11-signal-to-metrics.yaml. Rename a rule's
    # output there and this list has to follow.
    for suffix, source in (('dependency.duration', 'spans'),
                           ('checkout.failures', 'logs')):
        name = f'{METRIC_PREFIX}.{suffix}'
        v = scalar(f'sum({{otel_metric_name="{name}"}})')
        print(f'  signal-to-metrics  {name:34} {fmt(v, ".1f")}  (from {source})')

    # -- the emitter's own volume, decomposed
    #
    # Total datapoints = series count x samples per series. Aggregation can cut
    # either factor, so reporting only one of them hides half the story:
    #   spatial  aggregation drops labels      -> fewer series, same interval
    #   temporal aggregation resamples slower  -> same series, longer interval
    #
    # Dash0 tags an aggregated series with dash0_metric_datapoint_interval, so
    # the raw and aggregated variants of one metric are separate series and can
    # be compared directly. That label is the before/after discriminator.
    win_s = seconds(WINDOW)
    print()
    print(f'  emitter volume, measured over {WINDOW}. Total = series x samples/series,')
    print('  so spatial and temporal aggregation are both visible:')
    print()
    print(f'    {"metric":30} {"variant":10} {"series":>7} {"interval":>9} {"dp/min":>9} {"share":>7}')

    def volume(metric, offset=''):
        """Series count, effective emission interval, and datapoints/min per
        variant of one metric. offset is a PromQL offset such as '1h'."""
        off = f' offset {offset}' if offset else ''
        series = instant(f'count by (dash0_metric_datapoint_interval) '
                         f'({{otel_metric_name="{metric}"}}{off})')
        points = instant(f'sum by (dash0_metric_datapoint_interval) '
                         f'(count_over_time({{otel_metric_name="{metric}"}}[{WINDOW}]{off}))')
        if not series:
            return []
        rows = []
        for key, s_count in series.items():
            interval_label = json.loads(key).get('dash0_metric_datapoint_interval', '') or ''
            pts = points.get(key, 0.0) if points else 0.0
            samples_per_series = (pts / s_count) if s_count else 0
            rows.append({
                'variant': interval_label or 'raw',
                'series': int(s_count),
                'interval': (win_s / samples_per_series) if samples_per_series else None,
                'dp_min': pts / win_s * 60,
            })
        rows.sort(key=lambda r: (r['variant'] != 'raw', r['variant']))
        return rows

    def totals(rows):
        """Collapse variants into one figure per metric. Series counts add up
        across variants; the effective interval is derived from the totals so it
        stays meaningful when a metric has both a raw and an aggregated variant."""
        s = sum(r['series'] for r in rows)
        dp = sum(r['dp_min'] for r in rows)
        interval = (60.0 * s / dp) if dp else None
        return s, interval, dp

    for metric in EMITTER_METRICS:
        rows = volume(metric)
        if not rows:
            print(f'    {metric[:30]:30} {"(no series)":10}')
            continue
        total = sum(r['dp_min'] for r in rows) or 1.0
        for i, r in enumerate(rows):
            label = metric[:30] if i == 0 else ''
            print(f'    {label:30} {r["variant"][:10]:10} {r["series"]:7d} '
                  f'{fmt(r["interval"], ".1f"):>8}s {r["dp_min"]:9.1f} {r["dp_min"] / total * 100:6.1f}%')

    if BEFORE:
        print()
        print(f'  before/after: now versus {BEFORE} ago, same {WINDOW} window.')
        print('  spatial = fewer series (labels dropped).')
        print('  temporal = longer interval (resampled).')
        print('  volume = the product, which is what you actually pay for.')
        print()
        print(f'    {"metric":30} {"series":>13} {"interval":>15} {"dp/min":>17} {"volume":>9}')
        for metric in EMITTER_METRICS:
            after = volume(metric)
            before = volume(metric, BEFORE)
            if not after and not before:
                print(f'    {metric[:30]:30} (no data in either window)')
                continue
            s_b, i_b, d_b = totals(before)
            s_a, i_a, d_a = totals(after)
            print(f'    {metric[:30]:30} '
                  f'{s_b:5d} -> {s_a:<5d} '
                  f'{fmt(i_b, ".1f"):>6}s -> {fmt(i_a, ".1f"):>5}s '
                  f'{fmt(d_b, ".1f"):>7} -> {fmt(d_a, ".1f"):>6} ', end='')
            if d_b and d_a is not None:
                print(f'{(1 - d_a / d_b) * 100:8.1f}%')
            else:
                print(f'{"-":>9}')
            bits = []
            if s_b and s_a > s_b:
                # More series after than before. An aggregation rule cannot add
                # series, so this means the raw and aggregated variants are both
                # live and the window still straddles the change.
                bits.append(f'spatial NONE, series went UP {s_b} -> {s_a}')
            elif s_b and s_a != s_b:
                bits.append(f'spatial {(1 - s_a / s_b) * 100:.1f}% fewer series')
            elif s_b:
                bits.append('spatial none, series count unchanged')
            if i_b and i_a:
                if abs(i_a - i_b) / i_b > 0.05:
                    bits.append(f'temporal {(1 - i_b / i_a) * 100:.1f}% fewer samples per series')
                else:
                    bits.append('temporal none, interval unchanged')
            if bits:
                print(f'    {"":30} {" | ".join(bits)}')
            # A blended interval across a raw and an aggregated variant is not a
            # real number, so say when the reading is still transitional.
            variants = {r['variant'] for r in after}
            if len(variants) > 1:
                print(f'    {"":30} TRANSITIONAL: raw and aggregated variants both live '
                      f'({", ".join(sorted(variants))}).')
                print(f'    {"":30} Wait for the raw series to age out, then re-read.')

    # -- configured aggregation rules, and each rule's own accounting
    print()
    agg = api('/api/time-series-aggregations')
    rules = agg.get('timeSeriesAggregations', []) if agg.get('status') != 'error' else []

    # The per-rule counters identify a rule by its dash0.com/id UUID, not by
    # its name, so build the mapping to keep the output readable.
    rule_names = {}
    rule_updated = {}
    for r in rules:
        meta = r.get('metadata', {})
        rid = meta.get('labels', {}).get('dash0.com/id')
        if rid:
            rule_names[rid] = meta.get('name', rid)
            stamp = meta.get('annotations', {}).get('dash0.com/updated-at')
            if stamp:
                try:
                    rule_updated[rid] = datetime.datetime.fromisoformat(
                        stamp.replace('Z', '+00:00')).timestamp()
                except ValueError:
                    pass

    print(f'  time series aggregation rules: {len(rules)}')
    if not rules:
        print('    none. Create one in the Dash0 UI, then re-run with --before to compare.')
    for r in rules:
        spec = r.get('spec', {})
        match = spec.get('match', {}).get('metricNameMatcher', {})
        sample = spec.get('sample', {})
        target = f'{match.get("operator", "?")} {match.get("value", "?")}'
        bits = [f'interval {sample.get("interval")}'] if sample.get('interval') else []
        if sample.get('delay'):
            bits.append(f'delay {sample["delay"]}')
        if sample.get('staleAfter'):
            bits.append(f'staleAfter {sample["staleAfter"]}')
        enabled = '' if spec.get('enabled', True) else '  [disabled]'
        print(f'    {r["metadata"]["name"]}: {target} | {", ".join(bits) or "no sampling"}{enabled}')
        if VERBOSE:
            print(f'      {json.dumps(spec)[:300]}')

    # Per-rule datapoints in and out. This is Dash0's own accounting of what
    # each rule did, and it is the independent check on the per-metric table
    # above.
    per_in = instant(f'sum by (dash0_signal_control_rule_id) '
                     f'(rate({{otel_metric_name="dash0.signal_control.per_rule.metric_data_points_in"}}[{RATIO_WINDOW}]))')
    per_ratio = instant(
        f'sum by (dash0_signal_control_rule_id) '
        f'(rate({{otel_metric_name="dash0.signal_control.per_rule.metric_data_points_out"}}[{RATIO_WINDOW}]))'
        f' / '
        f'sum by (dash0_signal_control_rule_id) '
        f'(rate({{otel_metric_name="dash0.signal_control.per_rule.metric_data_points_in"}}[{RATIO_WINDOW}]))')
    if per_in:
        print()
        print(f'  per-rule datapoint accounting (rate window {RATIO_WINDOW}):')
        by_id = {}
        for key, v in per_in.items():
            rid = json.loads(key).get('dash0_signal_control_rule_id', '?')
            by_id.setdefault(rid, {})['in'] = v
        for key, v in (per_ratio or {}).items():
            rid = json.loads(key).get('dash0_signal_control_rule_id', '?')
            by_id.setdefault(rid, {})['ratio'] = v
        for rid, vals in sorted(by_id.items(), key=lambda kv: -(kv[1].get('in') or 0)):
            name = rule_names.get(rid, rid)
            rate_in = vals.get('in')
            ratio = vals.get('ratio')
            # A ratio at or above 1 is not a real result: these are separate
            # counters at low absolute rates, so a few percent of phase skew
            # swamps the signal. Say so rather than printing a negative
            # reduction.
            if ratio is None:
                verdict = '(no ratio)'
            elif ratio > 1.02:
                verdict = 'no reduction (skew at low rate)'
            elif ratio > 0.98:
                verdict = 'no reduction'
            else:
                verdict = f'{(1 - ratio) * 100:.1f}% reduction'
            print(f'    {name[:44]:44} in {fmt(rate_in, "7.4f")} dp/s  '
                  f'out/in {fmt(ratio, ".3f"):>6}  {verdict}')
            # A rate window that reaches back past the rule's last change
            # averages in the period when the rule was absent or different, and
            # pulls the reduction toward zero. Measured on a rule that had just
            # changed: 50.0% at a 5m window, 19.5% at 30m, for the same rule.
            changed = rule_updated.get(rid)
            if changed and changed > NOW - seconds(RATIO_WINDOW):
                age = int(NOW - changed)
                print(f'    {"":44} ^ rule changed {age}s ago, inside the {RATIO_WINDOW} rate '
                      f'window. This number is')
                print(f'    {"":44}   diluted. Re-run with --window and RATIO_WINDOW under '
                      f'{age}s.')
        print('    (the remove_connector_id_* rules are generated by Dash0 for each')
        print('     Dash0SignalToMetrics resource. They rewrite a label rather than')
        print('     drop datapoints, so they are expected to show no reduction.)')

    # -- dataset-wide accounting, per Signal Control component
    #
    # These must be scoped by component before dividing. The in and out counters
    # do not cover the same populations: in carries both the 'filter' and
    # 'time_series_aggregation' components across the edge and saas
    # environments, while out may carry only some of them at a given moment.
    # Dividing the unscoped sums compares different populations and produced a
    # meaningless 0.99 while aggregation was really cutting 90% of its input.
    print()
    print(f'  dataset-wide datapoints by Signal Control component (rate window {RATIO_WINDOW}):')
    for component in ('time_series_aggregation', 'filter'):
        sel = f'dash0_signal_control_component="{component}"'
        c_in = scalar(f'sum(rate({{otel_metric_name="dash0.signal_control.metric_data_points_in", {sel}}}[{RATIO_WINDOW}]))')
        c_out = scalar(f'sum(rate({{otel_metric_name="dash0.signal_control.metric_data_points_out", {sel}}}[{RATIO_WINDOW}]))')
        # One expression for the ratio. Two separate requests get two evaluation
        # instants, which on a bursty counter perturbs the result.
        c_ratio = scalar(
            f'sum(rate({{otel_metric_name="dash0.signal_control.metric_data_points_out", {sel}}}[{RATIO_WINDOW}]))'
            f' / '
            f'sum(rate({{otel_metric_name="dash0.signal_control.metric_data_points_in", {sel}}}[{RATIO_WINDOW}]))')
        line = (f'    {component:24} in {fmt(c_in, "9.4f")} dp/s  '
                f'out {fmt(c_out, "9.4f")} dp/s  out/in {fmt(c_ratio, ".3f"):>6}')
        if c_ratio is None:
            print(f'{line}')
        elif c_ratio > 1.02:
            print(f'{line}  (out exceeds in: not a matched pair, ignore)')
        elif c_ratio > 0.98:
            print(f'{line}  no reduction')
        else:
            print(f'{line}  {(1 - c_ratio) * 100:.1f}% reduction')
    print('    time_series_aggregation is the one to read for an aggregation rule.')
    print('    filter sits at 1.000 for metrics because the spam filters in this')
    print('    repo target spans and logs, not metric datapoints.')

    if VERBOSE:
        print()
        for metric in EMITTER_METRICS:
            trend(f'sum(count_over_time({{otel_metric_name="{metric}", dash0_metric_datapoint_interval=""}}[{WINDOW}]))'
                  f' / {win_s / 60:g}', f'{metric} RAW dp/min')
            trend(f'sum(count_over_time({{otel_metric_name="{metric}", dash0_metric_datapoint_interval!=""}}[{WINDOW}]))'
                  f' / {win_s / 60:g}', f'{metric} AGGREGATED dp/min')
        trend(f'sum(rate({{otel_metric_name="dash0.signal_control.metric_data_points_in"}}[{RATIO_WINDOW}]))',
              'Signal Control dp/sec IN')
        trend(f'sum(rate({{otel_metric_name="dash0.signal_control.metric_data_points_out"}}[{RATIO_WINDOW}]))',
              'Signal Control dp/sec OUT')
        trend('sum by (dash0_signal_control_rule_id) '
              f'(rate({{otel_metric_name="dash0.signal_control.per_rule.metric_data_points_in"}}[{RATIO_WINDOW}]))',
              'per-rule dp/sec IN', keep={'dash0_signal_control_rule_id'})
        trend('sum by (dash0_signal_control_rule_id) '
              f'(rate({{otel_metric_name="dash0.signal_control.per_rule.metric_data_points_out"}}[{RATIO_WINDOW}]))',
              'per-rule dp/sec OUT', keep={'dash0_signal_control_rule_id'})
    print()
PYEOF

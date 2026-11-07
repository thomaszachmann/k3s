#import "../lib.typ": *

#kapitel(
  [Bringing It All Together],
  ziel: [Individual tools become an architecture: one dashboard, alerts and an attack drill across all layers.],
  zeit: [90 minutes],
  braucht: [Chapters 1 to 11],
)

== The Security Dashboard

A good dashboard answers one question in ten seconds: Is something going on right now? In Grafana, go to *Dashboards > New*, create a new dashboard and build these panels. You learn more this way than by importing a finished JSON file.

#tabelle(
  (auto, auto, 1fr),
  ([Panel], [Source], [Query]),
  [Falco by rule], [Loki], [See query below],
  [Dropped packets], [Prometheus], [`sum by (reason) (rate(hubble_drop_total[5m]))`],
  [Critical CVEs], [Prometheus], [`sum(trivy_image_vulnerabilities{severity="Critical"})`],
  [Misconfigurations], [Prometheus], [`sum by (severity) (trivy_resource_configaudits)`],
  [Denied API requests], [Loki], [See query below],
  [Slow webhooks], [Tempo], [See query below],
)

Falco by rule (panel type *Bar chart*):

```logql
sum by (rule) (
  count_over_time(
    {namespace="falco", container="falco"}
    | json | priority =~ "Warning|Error|Critical" [1h]
  )
)
```

Denied API requests (panel type *Time series*):

```logql
sum(
  count_over_time(
    {job="audit"} | json | responseStatus_code="403" [5m]
  )
)
```

Webhook calls over 100 milliseconds (panel type *Table*):

```traceql
{ resource.service.name = "apiserver" && name =~ ".*webhook.*"
  && duration > 100ms }
```

Human access to secrets (panel type *Logs*):

```logql
{job="audit"} | json
  | objectRef_resource="secrets"
  | user_username !~ "system:.*"
```

The Kyverno status, which you see with `kubectl get polr -A`, fits in here as well. If you want it on the dashboard, set `serviceMonitor.enabled: true` for `admissionController` and `reportsController` in `kyverno/values.yaml`.

#warum[
  Export the finished dashboard as JSON to `security/dashboard.json`. Stored in the repo, it survives a rebuild of the VM.
]

== Alerts

A dashboard only helps if someone looks at it. For the most important cases, you create rules.

#datei("security/alerts.yaml", ```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: security
  namespace: monitoring
spec:
  groups:
    - name: security
      rules:
        - alert: KritischeSchwachstelle
          expr: sum(trivy_image_vulnerabilities{severity="Critical"}) > 0
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: Images with critical CVEs are running.
        - alert: VieleBlockiertePakete
          expr: sum(rate(hubble_drop_total{reason="POLICY_DENIED"}[5m])) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: Unusually many blocked connections.
```, erklaerung: [
  `for: 1h` avoids alerts on short-lived spikes. Thanks to `ruleSelectorNilUsesHelmValues: false` from Chapter 10, Prometheus finds the rule.
])

#cmd("Mac")[```bash
kubectl apply -f security/alerts.yaml
```][Loads the rules.]

#cmd("Mac")[```bash
kubectl port-forward -n monitoring \
  svc/kps-kube-prometheus-stack-prometheus 9090
```][At #link("http://localhost:9090/alerts") you see the state of the alerts.]

#falle[
  The reason value `POLICY_DENIED` is a common value of `hubble_drop_total`, but it can differ between versions. Check the real values with `sum by (reason) (hubble_drop_total)` before you rely on the alert.
]

For Falco, you create a Grafana alert: open the panel *Falco by rule*, choose *More > New alert rule*, set the threshold to greater than zero and save. Grafana then evaluates the LogQL query regularly.

== The Attack Drill

Now you play through a break-in across all layers. Keep your dashboard open. You take on the role of an attacker who has gained a remote shell in the `frontend`.

Before you start, get out your notes from Chapter 1. Do your expectations hold up?

=== Phase 1: Looking Around

#cmd("Mac")[```bash
kubectl exec -it -n demo deploy/frontend -- sh
```][This simulates the break-in. *Falco* immediately reports `Terminal shell in container`.]

#cmd("Pod")[```bash
id
```][You are user 100, not root. That is *PSA*: `restricted` requires `runAsNonRoot`.]

#cmd("Pod")[```bash
ls /var/run/secrets/kubernetes.io/serviceaccount/
```][Error: the directory does not exist. That is *RBAC* from Chapter 3: `automountServiceAccountToken: false`. Without a token, the attacker cannot talk to the API server.]

=== Phase 2: Spreading Out

#cmd("Pod")[```bash
curl -s -m 3 -o /dev/null -w '%{http_code}\n' \
  http://kps-grafana.monitoring.svc.cluster.local/
```][Timeout (`000`). *Cilium* blocks it, because this path is not allowed.]

#cmd("Pod")[```bash
curl -s -m 3 -o /dev/null -w '%{http_code}\n' \
  http://backend:8080/admin
```][Expected: `403`. *Cilium* only lets `GET /` through.]

=== Phase 3: Exfiltrating Data

#cmd("Pod")[```bash
curl -s -m 5 -o /dev/null -w '%{http_code}\n' https://example.org/
```][Timeout (`000`). *Cilium* only allows `example.com`. The way out is closed.]

=== Phase 4: Gaining a Foothold

#cmd("Pod")[```bash
echo test > /usr/bin/hintertuer
```][`Permission denied`. You are not root, and the system directory does not belong to you.]

#cmd("Pod")[```bash
exit
```][The attacker is stuck.]

=== Phase 5: The Detour Through the API Server

Imagine the attacker has stolen alice's credentials. Her certificate from Chapter 3 has expired by now, which already shows the value of short lifetimes. For the drill, you therefore act as alice with `--as`:

#cmd("Mac")[```bash
kubectl run ausbruch -n demo --image=busybox:1.36 \
  --privileged --as=alice --as-group=plattform
```][alice may create pods here, but *PSA* rejects the privileged pod.]

#cmd("Mac")[```bash
kubectl get secrets -n kube-system --as=alice --as-group=plattform
```][`Forbidden`. *RBAC* only applies in `demo`. The attempt is now recorded in the *audit log*.]

== The Investigation

Switch roles: you are now the defense. Answer the questions using only Grafana.

#tabelle(
  (1fr, auto),
  ([Question], [Where you look]),
  [When did the incident start, and in which pod?], [Falco in Loki],
  [Which connections were attempted?], [Hubble],
  [Did anyone access secrets?], [Audit log in Loki],
  [Who attempted a privileged pod?], [Audit log, `responseStatus_code="403"`],
  [What happened in the API request?], [Tempo, if captured],
)

#cmd("Mac")[```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --from-pod demo/frontend \
  --verdict DROPPED --last 20
```][Shows all blocked attempts by the `frontend`. Hubble only keeps the most recent flows in memory; for a longer period, you use the metrics.]

This query shows every denial for alice:

```logql
{job="audit"} | json
  | user_username="alice"
  | responseStatus_code="403"
```

#pruefe[
  You can tell the story of the attack: when it started, what was attempted and where each layer stepped in. That is exactly the difference between a collection of tools and an architecture.
]

== What the Drill Showed

#tabelle(
  (auto, auto, auto),
  ([Action], [Prevented by], [Detected by]),
  [Shell in the container], [nothing], [Falco],
  [Root privileges], [PSA], [Audit log],
  [Stealing a token], [RBAC, no mount], [nothing needed],
  [Reaching other services], [Cilium], [Hubble],
  [Sending to the internet], [Cilium], [Hubble],
  [Privileged pod], [PSA], [Audit log],
  [Reading secrets], [RBAC], [Audit log],
)

Note the first row: nothing prevented the shell itself. The break-in gains nothing because of how the other layers work together.

#aufgabe[
  Look for the weaknesses in your own architecture. What if the attacker had landed in the `backend` instead of the `frontend`? What can someone do with your admin access on the Mac? Which of these gaps does none of the tools close? Write down three points for your next round of learning.
]

#gelernt(
  [Individual tools only become an architecture when they work together.],
  [Not every layer prevents; some detect, and both roles are needed.],
  [A drill shows whether your assumptions hold.],
  [A dashboard without alerts only helps if someone looks at it.],
)

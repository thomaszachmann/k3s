#import "../lib.typ": *

#kapitel(
  [Tempo: Following a Request],
  ziel: [You store traces in Tempo and see what happens during an API request, all the way to the check by Kyverno.],
  zeit: [60 minutes],
  braucht: [Chapter 10],
)

== Three Kinds of Signals

#tabelle(
  (auto, 1fr, auto),
  ([Signal], [Answers], [Storage]),
  [Metrics], [How much, how often?], [Prometheus],
  [Logs], [What exactly happened?], [Loki],
  [Traces], [Which path did a request take, and where did the time go?], [Tempo],
)

A trace consists of *spans*. Each span is one unit of work with a start and a duration.

#hinweis("What Tempo Does for Security", akzent, akzent-hell)[
  Tempo is not a security tool in the strict sense, and applications in your cluster only deliver traces once you instrument them. It is still useful: the API server can deliver its requests as traces. You then see, for example, how long the Kyverno webhook holds up a request. This helps with outages caused by admission webhooks, and later, in your own applications, it shows which path a suspicious request took.
]

== Bucket and S3 Account

You know the pattern from Chapter 10.

#cmd("Mac")[```bash
kubectl exec -n monitoring deploy/s3 -- sh -c \
  "echo 's3.bucket.create -name tempo' | weed shell -master=localhost:9333"
```][Creates the bucket `tempo`.]

#cmd("Mac")[```bash
TEMPO_ACCESS=$(openssl rand -hex 10)
TEMPO_SECRET=$(openssl rand -hex 20)
ALT=$(kubectl get secret s3-config -n monitoring \
  -o jsonpath='{.data.s3\.json}' | base64 -d)
```][Generates the credentials and reads the account list.]

#cmd("Mac")[```bash
NEU=$(printf '%s' "$ALT" | jq \
  --arg a "$TEMPO_ACCESS" --arg s "$TEMPO_SECRET" \
  '.identities += [{
     name: "tempo",
     credentials: [{accessKey: $a, secretKey: $s}],
     actions: ["Read:tempo","Write:tempo","List:tempo","Tagging:tempo"]
   }]')
```][Appends the account. Tempo may only access its own bucket.]

#cmd("Mac")[```bash
printf '%s' "$NEU" | kubectl create secret generic s3-config \
  -n monitoring --from-file=s3.json=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deploy/s3 -n monitoring
kubectl rollout status deploy/s3 -n monitoring
```][Writes the list back and restarts SeaweedFS.]

#cmd("Mac")[```bash
kubectl create secret generic tempo-s3 -n monitoring \
  --from-literal=S3_ACCESS_KEY="$TEMPO_ACCESS" \
  --from-literal=S3_SECRET_KEY="$TEMPO_SECRET"
unset TEMPO_ACCESS TEMPO_SECRET ALT NEU
```][Stores the credentials and cleans up the shell.]

== Installing Tempo

#datei("monitoring/tempo-values.yaml", ```yaml
tempo:
  retention: 168h
  storage:
    trace:
      backend: s3
      s3:
        bucket: tempo
        endpoint: s3.monitoring.svc.cluster.local:8333
        # Tempo replaces these at startup from the environment variables.
        access_key: ${S3_ACCESS_KEY}
        secret_key: ${S3_SECRET_KEY}
        insecure: true
        forcepathstyle: true
      wal:
        path: /var/tempo/wal
  extraArgs:
    config.expand-env: "true"
  extraEnvFrom:
    - secretRef:
        name: tempo-s3
  resources:
    requests:
      cpu: 50m
      memory: 256Mi
    limits:
      memory: 768Mi

persistence:
  enabled: true
  size: 2Gi
  storageClassName: local-path
```, erklaerung: [
  Unlike with Loki, you have to set `config.expand-env` yourself here. The endpoint is given without `http://`; `insecure: true` takes care of the protocol. The `wal` lives locally and buffers traces before they move to S3.
])

#cmd("Mac")[```bash
helm upgrade --install tempo grafana-community/tempo \
  -n monitoring --version 3.2.1 \
  -f monitoring/tempo-values.yaml --wait --timeout 5m
```][Installs Tempo as a single process, which fits your single node.]

#cmd("Mac")[```bash
kubectl logs -n monitoring statefulset/tempo --tail=20
```][Checks the startup. `AccessDenied` again points to the account.]

== Alloy Accepts Traces

Alloy does more than collect logs. It also accepts traces via OTLP and forwards them to Tempo. That way there is only one collection point for all signals. Append these blocks to `monitoring/config.alloy`:

#datei("monitoring/config.alloy (append at the end)", ```hcl
// Accept traces via OTLP
otelcol.receiver.otlp "default" {
  grpc {
    endpoint = "0.0.0.0:4317"
  }
  output {
    traces = [otelcol.processor.batch.default.input]
  }
}

// Send in batches, which is easier on the network
otelcol.processor.batch "default" {
  output {
    traces = [otelcol.exporter.otlp.tempo.input]
  }
}

otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "tempo.monitoring.svc.cluster.local:4317"
    tls {
      insecure = true
    }
  }
}
```)

The API server runs on the host and does not know cluster DNS names. It therefore needs a fixed IP. Add this to `monitoring/alloy-values.yaml`:

#datei("monitoring/alloy-values.yaml (add)", ```yaml
alloy:
  # ... as before, plus:
  extraPorts:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP

# New top-level block
service:
  clusterIP: 10.43.0.50
```, erklaerung: [
  `10.43.0.50` is in the service network and is reachable only inside the cluster and on the node, not from your home network. Cilium cannot serve a `hostPort` on `127.0.0.1` in this mode, which is why you take this route.
])

#cmd("Mac")[```bash
kubectl create configmap alloy-config -n monitoring \
  --from-file=config.alloy=monitoring/config.alloy \
  --dry-run=client -o yaml | kubectl apply -f -
```][Updates the ConfigMap.]

#cmd("Mac")[```bash
kubectl delete svc alloy -n monitoring
helm upgrade alloy grafana/alloy \
  -n monitoring --version 1.15.0 \
  -f monitoring/alloy-values.yaml --wait
```][You cannot change the ClusterIP of a Service. So you delete it, and Helm creates it again with the new IP.]

#cmd("Mac")[```bash
kubectl get svc alloy -n monitoring
kubectl logs -n monitoring ds/alloy -c alloy --tail=20
```][The `CLUSTER-IP` column shows `10.43.0.50`, and the log shows no errors.]

== The First Trace

The test program `telemetrygen` generates synthetic traces.

#cmd("Mac")[```bash
kubectl run telemetrygen -n monitoring --rm -it --restart=Never \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.164.1 \
  -- traces --otlp-endpoint=alloy.monitoring.svc.cluster.local:4317 \
  --otlp-insecure --traces=5
```][Sends five traces to Alloy. They travel on to Tempo.]

In Grafana, open *Explore*, select the *Tempo* data source and the *TraceQL* query type:

```traceql
{ resource.service.name = "telemetrygen" }
```

#pruefe[
  You see a list of traces. A click shows the spans as a waterfall. If nothing shows up, wait a minute and check the Alloy logs for connection errors to Tempo.
]

== The API Server Delivers Traces

#datei("security/tracing.yaml", ```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: TracingConfiguration
endpoint: 10.43.0.50:4317
# 100000 out of a million: every tenth request
samplingRatePerMillion: 100000
```, erklaerung: [
  For the lab, every tenth request is easy to see. In long-term operation you lower the value, because traces cost storage. According to the Kubernetes docs, the connection is unencrypted and cannot do TLS, so it must only run internally.
])

#cmd("Mac")[```bash
scp security/tracing.yaml <user>@172.16.0.136:/tmp/tracing.yaml
```][Copies the file to the node.]

In `k3s/config.yaml`, add one line under `kube-apiserver-arg`:

#datei("k3s/config.yaml (add)", ```yaml
  - "tracing-config-file=/var/lib/rancher/k3s/server/tracing.yaml"
```)

#cmd("Mac")[```bash
scp k3s/config.yaml <user>@172.16.0.136:/tmp/config.yaml
ssh <user>@172.16.0.136
```][Transfers the configuration and opens the session.]

#cmd("Node")[```bash
sudo install -m 600 -o root -g root /tmp/tracing.yaml \
  /var/lib/rancher/k3s/server/tracing.yaml
sudo install -m 600 -o root -g root /tmp/config.yaml \
  /etc/rancher/k3s/config.yaml
rm /tmp/tracing.yaml /tmp/config.yaml
sudo systemctl restart k3s
```][Puts both files in place and restarts k3s.]

#cmd("Node")[```bash
exit
```][Back to the laptop.]

#cmd("Mac")[```bash
kubectl get pods -A > /dev/null
kubectl run trace-test -n falco-lab --image=nginx:1.29-alpine
kubectl delete pod trace-test -n falco-lab
```][Generates API requests. Repeat this a few times, because only every tenth one is recorded.]

```traceql
{ resource.service.name = "apiserver" }
```

Open a trace for creating a pod and look at the spans. To search specifically for webhook calls, use this:

```traceql
{ resource.service.name = "apiserver" && name =~ ".*webhook.*" }
```

#pruefe[
  You find spans for webhook calls, including the one to Kyverno, with their duration. The exact span names depend on the Kubernetes version. If you find nothing, remove the name filter and search the waterfall.
]

#falle[
  Traces can contain internal URLs and object names. So treat Tempo like logs: no access from outside. Also, the OTLP port accepts anything without authentication, which means any pod in the cluster could submit traces. In namespaces with default deny this is blocked until you allow it.
]

== Jumping from Traces to Logs

The data source has `tracesToLogsV2` set from Chapter 10. In a span, click *Logs for this span*, and Grafana opens the matching Loki lines. This takes you from “this request was slow” to “this is what the log said at the time”.

#aufgabe[
  Stop Kyverno with `kubectl scale deploy -n kyverno kyverno-admission-controller --replicas=0` and create a pod in `falco-lab`. What happens, and what does the trace look like? Afterwards, be sure to scale back up to `1`.
]

#gelernt(
  [Metrics count, logs tell, traces show the path.],
  [Alloy is the shared collection point for logs and traces.],
  [The API server delivers traces too, and they show you the admission webhooks.],
  [Services on the host need a fixed IP, because they do not know cluster DNS.],
)

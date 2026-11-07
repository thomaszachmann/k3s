#import "../lib.typ": *

#kapitel(
  [A Central View: Grafana and Loki],
  ziel: [All layers report to one place: audit log, Falco, Trivy and Hubble end up in Grafana.],
  zeit: [90 minutes],
  braucht: [Chapters 7, 8 and 9],
)

== What You Build

So far, all your findings are scattered: in the audit log on the node, in the Falco logs, in Trivy objects. Now you bring them together.

#tabelle(
  (auto, 1fr),
  ([Component], [Job]),
  [SeaweedFS], [S3 storage for logs and traces, from your repo],
  [Prometheus], [Stores metrics],
  [Loki], [Stores logs],
  [Alloy], [Collects logs on the node],
  [Grafana], [Shows everything in one place],
)

#warum[
  Logs that only live on the node can be deleted by an attacker. Once they reach Loki, they sit in object storage, out of the attacker's reach. That is exactly why visibility is a security measure in itself.
]

#hinweis("What about Thanos?", akzent, akzent-hell)[
  Your repo also contains Thanos for long-term metric storage. You don't need it for this book, and leaving it out saves about 0.5 GB of RAM. If you want to add it later, follow the repo's README.
]

== Starting SeaweedFS

The `monitoring` namespace has existed since Chapter 4 with the `privileged` level.

#cmd("Mac")[```bash
./seaweedfs/create-secrets.sh
```][Your script from the repo. It creates the `s3-config` Secret with the first account, which you will add more accounts to in a moment.]

#falle[
  `seaweedfs/seaweedfs.yaml` limits storage with `-volume.max=16` to 16 × 256 MB, so about 4 GB. That gets tight for Loki and Tempo. Raise the value in the file to `-volume.max=32` before you apply it. Your disk can handle the 8 GB.
]

#cmd("Mac")[```bash
kubectl apply -f seaweedfs/seaweedfs.yaml
```][Creates the PVC, Deployment and Service for the S3 storage.]

#cmd("Mac")[```bash
kubectl rollout status deploy/s3 -n monitoring
```][Waits until the pod is ready. `apply` returns immediately; this command does not.]

#cmd("Mac")[```bash
kubectl exec -n monitoring deploy/s3 -- sh -c \
  "echo 's3.bucket.create -name loki' | weed shell -master=localhost:9333"
```][Creates the `loki` bucket through the SeaweedFS admin shell.]

== A Dedicated S3 Account for Loki

Each service gets its own account with access only to its own bucket. If a service is compromised, only that bucket is affected.

#cmd("Mac")[```bash
LOKI_ACCESS=$(openssl rand -hex 10)
LOKI_SECRET=$(openssl rand -hex 20)
```][Generates two random values and stores them in shell variables. They appear neither on screen nor in a file.]

#cmd("Mac")[```bash
ALT=$(kubectl get secret s3-config -n monitoring \
  -o jsonpath='{.data.s3\.json}' | base64 -d)
```][Reads the existing account list. Kubernetes stores Secrets Base64-encoded; `base64 -d` makes them readable again. The backslash in `s3\.json` is needed because the dot would otherwise count as a path separator.]

#cmd("Mac")[```bash
NEU=$(printf '%s' "$ALT" | jq \
  --arg a "$LOKI_ACCESS" --arg s "$LOKI_SECRET" \
  '.identities += [{
     name: "loki",
     credentials: [{accessKey: $a, secretKey: $s}],
     actions: ["Read:loki","Write:loki","List:loki","Tagging:loki"]
   }]')
```][`jq` appends a new account to the list. `--arg` passes the values safely instead of pasting them into the text. `actions` restricts the account to the `loki` bucket.]

#cmd("Mac")[```bash
printf '%s' "$NEU" | kubectl create secret generic s3-config \
  -n monitoring --from-file=s3.json=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -
```][Builds a new Secret locally (`--dry-run=client -o yaml`) and applies it. The data goes through standard input so that it doesn't show up in the process list.]

#cmd("Mac")[```bash
kubectl rollout restart deploy/s3 -n monitoring
kubectl rollout status deploy/s3 -n monitoring
```][SeaweedFS reads the accounts only at startup, so you have to restart it.]

#cmd("Mac")[```bash
kubectl create secret generic loki-s3 -n monitoring \
  --from-literal=S3_ACCESS_KEY="$LOKI_ACCESS" \
  --from-literal=S3_SECRET_KEY="$LOKI_SECRET"
```][Stores the credentials for Loki. The key names later become environment variables.]

#cmd("Mac")[```bash
unset LOKI_ACCESS LOKI_SECRET ALT NEU
```][Removes the secrets from your shell.]

== Installing Prometheus and Grafana

First create a values file that adapts the stack to k3s:

#datei("monitoring/kps-k3s-values.yaml", ```yaml
grafana:
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
  additionalDataSources:
    - name: Loki
      uid: loki
      type: loki
      access: proxy
      url: http://loki.monitoring.svc.cluster.local:3100
      editable: false
    - name: Tempo
      uid: tempo
      type: tempo
      access: proxy
      url: http://tempo.monitoring.svc.cluster.local:3200
      editable: false
      jsonData:
        tracesToLogsV2:
          datasourceUid: loki

# Cilium replaces kube-proxy, so there is nothing to monitor.
kubeProxy:
  enabled: false
# In k3s these run inside the k3s process, not as separate pods.
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false

prometheus:
  prometheusSpec:
    retention: 2d
    # Also pick up ServiceMonitors without the label "release: kps".
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
```, erklaerung: [
  The last three values are important: by default, Prometheus only looks at objects from its own Helm release. With `false` it also finds the ServiceMonitors from Trivy and Cilium and your rules. The Tempo data source is already in place; Tempo itself comes in Chapter 11.
])

#cmd("Mac")[```bash
kubectl create secret generic grafana-admin -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -hex 16)"
```][Creates a random Grafana password. It is not in any file, only in the cluster.]

#cmd("Mac")[```bash
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts
helm repo update
```][If the repository is already added, Helm just tells you so. `update` fetches the current version lists.]

#cmd("Mac")[```bash
helm upgrade --install kps \
  prometheus-community/kube-prometheus-stack \
  -n monitoring --version 92.18.0 \
  -f monitoring/kps-k3s-values.yaml \
  --wait --timeout 10m
```][Installs Prometheus, Alertmanager, Grafana and the exporters. The version matches your README.]

== Installing Loki

The Loki chart has moved to the Grafana community. The old `grafana/loki` is stuck at version 7.5.0 and is no longer kept up to date.

#datei("monitoring/loki-values.yaml", ```yaml
deploymentMode: Monolithic

loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  schemaConfig:
    configs:
      - from: "2026-01-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  storage:
    type: s3
    bucketNames:
      chunks: loki
      ruler: loki
      admin: loki
    s3:
      endpoint: http://s3.monitoring.svc.cluster.local:8333
      region: us-east-1
      # Loki replaces these from the environment variables at startup.
      accessKeyId: ${S3_ACCESS_KEY}
      secretAccessKey: ${S3_SECRET_KEY}
      s3ForcePathStyle: true
      insecure: true
  compactor:
    retention_enabled: true
    delete_request_store: s3
  limits_config:
    retention_period: 168h

singleBinary:
  replicas: 1
  extraEnvFrom:
    - secretRef:
        name: loki-s3
  persistence:
    size: 5Gi
    storageClass: local-path
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 1Gi

# On a small node, turning these off saves a lot of RAM.
gateway:
  enabled: false
chunksCache:
  enabled: false
resultsCache:
  enabled: false
lokiCanary:
  enabled: false
test:
  enabled: false
backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0
```, erklaerung: [
  `replication_factor: 1` is mandatory with only one instance, otherwise requests fail. `s3ForcePathStyle` is required for SeaweedFS, and `retention_period: 168h` keeps logs for seven days. With `${...}` no secrets end up in the file. The chart sets `-config.expand-env=true` itself.
])

#cmd("Mac")[```bash
helm repo add grafana-community \
  https://grafana-community.github.io/helm-charts
helm repo update
```][The new home of the charts for Loki and Tempo.]

#cmd("Mac")[```bash
helm upgrade --install loki grafana-community/loki \
  -n monitoring --version 21.0.0 \
  -f monitoring/loki-values.yaml --wait --timeout 5m
```][Installs Loki as a single process. According to the docs, that is enough for a few tens of GB per day.]

#cmd("Mac")[```bash
kubectl logs -n monitoring statefulset/loki --tail=20
```][Checks the startup. If there are S3 problems, you see messages like `AccessDenied` here, which means the account is wrong.]

== Alloy Collects the Logs

Alloy runs as a DaemonSet, so once per node. It reads the container logs under `/var/log/pods` and your audit log, and sends both to Loki. You keep the configuration separate from the Helm values so that you can change it easily.

#datei("monitoring/config.alloy", ```hcl
// Find pods on this node
discovery.kubernetes "pods" {
  role = "pod"
  selectors {
    role  = "pod"
    field = "spec.nodeName=" + sys.env("HOSTNAME")
  }
}

// Set labels and build the path to the log file
discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets

  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_uid",
                     "__meta_kubernetes_pod_container_name"]
    separator     = "/"
    replacement   = "/var/log/pods/*$1/*.log"
    target_label  = "__path__"
  }
}

local.file_match "pods" {
  path_targets = discovery.relabel.pods.output
}

loki.source.file "pods" {
  targets    = local.file_match.pods.targets
  forward_to = [loki.process.pods.receiver]
}

// Unpack the containerd CRI format
loki.process "pods" {
  stage.cri {}
  forward_to = [loki.write.default.receiver]
}

// API server audit log from Chapter 9
local.file_match "audit" {
  path_targets = [{
    "__path__" = "/k3s-logs/audit.log",
    "job"      = "audit",
  }]
}

loki.source.file "audit" {
  targets    = local.file_match.audit.targets
  forward_to = [loki.write.default.receiver]
}

loki.write "default" {
  endpoint {
    url = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
  }
}
```, erklaerung: [
  Read the file from bottom to top: `loki.write` is the destination, and each block passes data on with `forward_to`.
])

#datei("monitoring/alloy-values.yaml", ```yaml
alloy:
  # The audit log belongs to root and is readable only by root.
  securityContext:
    runAsUser: 0
    runAsGroup: 0
  configMap:
    create: false
    name: alloy-config
    key: config.alloy
  mounts:
    varlog: true
    extra:
      - name: k3s-logs
        mountPath: /k3s-logs
        readOnly: true

controller:
  type: daemonset
  volumes:
    extra:
      - name: k3s-logs
        hostPath:
          path: /var/lib/rancher/k3s/server/logs
          type: DirectoryOrCreate
```, erklaerung: [
  Alloy has to run as root here, and that is a deliberate trade-off: the pod has read access to the host, but in return it mounts the audit directory read-only. The chart also gives the pod the permissions it needs for `discovery.kubernetes`.
])

#cmd("Mac")[```bash
kubectl create configmap alloy-config -n monitoring \
  --from-file=config.alloy=monitoring/config.alloy
```][Stores the configuration as a ConfigMap. For later changes, add `--dry-run=client -o yaml | kubectl apply -f -`.]

#cmd("Mac")[```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```][Alloy stays in Grafana's main repository.]

#cmd("Mac")[```bash
helm upgrade --install alloy grafana/alloy \
  -n monitoring --version 1.15.0 \
  -f monitoring/alloy-values.yaml --wait
```][Starts Alloy as a DaemonSet.]

#cmd("Mac")[```bash
kubectl logs -n monitoring ds/alloy -c alloy --tail=20
```][Syntax errors in `config.alloy` show up here with a line number.]

== Connecting Hubble and Trivy

Both services are already running. Now that Prometheus has brought along the ServiceMonitor CRDs, they can deliver metrics.

#datei("cilium/metrics-values.yaml", ```yaml
prometheus:
  enabled: true
  serviceMonitor:
    enabled: true
operator:
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: true
hubble:
  metrics:
    enabled:
      - dns
      - drop
      - tcp
      - flow
      - policy:sourceContext=workload-name;destinationContext=workload-name
    serviceMonitor:
      enabled: true
```)

#cmd("Mac")[```bash
helm upgrade cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 -n kube-system \
  -f cilium/values.yaml -f cilium/metrics-values.yaml --wait
```][Merges both files. The agents restart in the process; existing connections usually keep running.]

In `trivy/values.yaml`, change the line under `serviceMonitor` to `enabled: true`.

#cmd("Mac")[```bash
helm upgrade trivy-operator aqua/trivy-operator \
  -n trivy-system --version 0.38.1 \
  -f trivy/values.yaml --wait
```][Creates the ServiceMonitor for Trivy.]

Falco already writes to standard output, so there is nothing more to do for it. However, the default deny from Chapter 6 locks Prometheus out of `demo`. If your application should deliver metrics, you allow that explicitly:

#datei("security/netpol/05-prometheus.yaml", ```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: prometheus-darf-scrapen
  namespace: demo
spec:
  endpointSelector: {}
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: monitoring
            app.kubernetes.io/name: prometheus
```, erklaerung: [
  With `io.kubernetes.pod.namespace` you select pods from another namespace. Only Prometheus is meant here, not the whole namespace.
])

#cmd("Mac")[```bash
kubectl apply -f security/netpol/05-prometheus.yaml
```][Loads the rule.]

== Opening Grafana

#cmd("Mac")[```bash
kubectl get secret grafana-admin -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```][Shows the Grafana password once in the terminal.]

#cmd("Mac")[```bash
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
```][Grafana is now available at #link("http://localhost:3000"). Log in as `admin`.]

Open *Explore*, choose the *Loki* data source and enter this query:

```logql
{namespace="kube-system", container="coredns"}
```

#pruefe[
  The CoreDNS log lines appear. If you switch to the *Prometheus* data source and query `hubble_flows_processed_total`, you see the Hubble metrics.
]

== Querying Audit Logs

Now you rewrite the `jq` queries from Chapter 9 in LogQL. `| json` parses each line, and nested fields like `objectRef.name` become `objectRef_name`.

Who besides system components has read Secrets?

```logql
{job="audit"} | json
  | objectRef_resource="secrets"
  | verb=~"get|list"
  | user_username!~"system:.*"
```

Which requests were denied?

```logql
{job="audit"} | json | responseStatus_code="403"
```

Who changed RBAC rules?

```logql
{job="audit"} | json
  | objectRef_apiGroup="rbac.authorization.k8s.io"
  | verb=~"create|update|patch|delete"
```

== Querying Falco Alerts

`line_format` shows only the rule name:

```logql
{namespace="falco", container="falco"} | json | line_format "{{.rule}}"
```

Only the serious alerts:

```logql
{namespace="falco", container="falco"}
  | json
  | priority =~ "Warning|Error|Critical|Alert|Emergency"
```

Counted by rule:

```logql
sum by (rule) (
  count_over_time(
    {namespace="falco", container="falco"} | json | rule != "" [1h]
  )
)
```

== Querying Trivy Results

Choose the *Prometheus* data source. First check under *Explore* whether `up{job=~".*trivy.*"}` returns the value `1`.

```promql
sum by (severity) (trivy_image_vulnerabilities)
```

```promql
topk(5, sum by (namespace, image_repository)
  (trivy_image_vulnerabilities{severity="Critical"}))
```

```promql
sum by (severity) (trivy_resource_configaudits)
```

#aufgabe[
  Write a LogQL query that shows all log lines containing the word `error` from the `monitoring` namespace. Hint: you append filters to the label selector with `|=`.
]

#gelernt(
  [An attacker can't simply delete logs that live outside the node.],
  [Each service gets its own S3 account, so a breach stays contained.],
  [Prometheus only picks up other releases' ServiceMonitors once you allow it.],
  [All layers now end up in one place and can be queried together.],
)

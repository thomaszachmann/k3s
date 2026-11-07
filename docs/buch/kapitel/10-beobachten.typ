#import "../lib.typ": *

#kapitel(
  [Zentrale Sicht: Grafana und Loki],
  ziel: [Alle Schichten melden an einen Ort: Audit-Log, Falco, Trivy und Hubble landen in Grafana.],
  zeit: [90 Minuten],
  braucht: [Kapitel 7, 8 und 9],
)

== Was du aufbaust

Bisher liegen alle Erkenntnisse verstreut: im Audit-Log auf dem Node, in den Falco-Logs, in Trivy-Objekten. Jetzt führst du sie zusammen.

#tabelle(
  (auto, 1fr),
  ([Komponente], [Aufgabe]),
  [SeaweedFS], [S3-Speicher für Logs und Traces, aus deinem Repo],
  [Prometheus], [Speichert Metriken],
  [Loki], [Speichert Logs],
  [Alloy], [Sammelt Logs auf dem Node ein],
  [Grafana], [Zeigt alles an einer Stelle],
)

#warum[
  Logs, die nur auf dem Node liegen, kann ein Angreifer löschen. Sobald sie in Loki landen, liegen sie außerhalb seiner Reichweite im Objektspeicher. Genau deshalb ist Sichtbarkeit selbst eine Sicherheitsmaßnahme.
]

#hinweis("Und Thanos?", akzent, akzent-hell)[
  Dein Repo enthält auch Thanos für die Langzeit-Speicherung von Metriken. Für dieses Buch brauchst du es nicht, und es spart rund 0,5 GB RAM. Möchtest du es später ergänzen, folge dem README des Repos.
]

== SeaweedFS starten

Der Namespace `monitoring` existiert seit Kapitel 4 mit der Stufe `privileged`.

#cmd("Mac")[```bash
./seaweedfs/create-secrets.sh
```][Dein Skript aus dem Repo. Es erzeugt das Secret `s3-config` mit dem ersten Konto, an das du gleich weitere anhängst.]

#falle[
  `seaweedfs/seaweedfs.yaml` begrenzt den Speicher mit `-volume.max=16` auf 16 × 256 MB, also rund 4 GB. Für Loki und Tempo wird das eng. Erhöhe den Wert in der Datei auf `-volume.max=32`, bevor du sie anwendest. Deine Disk verkraftet die 8 GB.
]

#cmd("Mac")[```bash
kubectl apply -f seaweedfs/seaweedfs.yaml
```][Legt PVC, Deployment und Service des S3-Speichers an.]

#cmd("Mac")[```bash
kubectl rollout status deploy/s3 -n monitoring
```][Wartet, bis der Pod bereit ist. `apply` kehrt sofort zurück, dieser Befehl nicht.]

#cmd("Mac")[```bash
kubectl exec -n monitoring deploy/s3 -- sh -c \
  "echo 's3.bucket.create -name loki' | weed shell -master=localhost:9333"
```][Legt den Bucket `loki` über die SeaweedFS-Verwaltungsshell an.]

== Ein eigenes S3-Konto für Loki

Jeder Dienst bekommt sein eigenes Konto mit Zugriff nur auf seinen Bucket. Wird ein Dienst kompromittiert, ist nur dieser Bucket betroffen.

#cmd("Mac")[```bash
LOKI_ACCESS=$(openssl rand -hex 10)
LOKI_SECRET=$(openssl rand -hex 20)
```][Erzeugt zwei Zufallswerte und legt sie in Shell-Variablen. Sie erscheinen weder auf dem Bildschirm noch in einer Datei.]

#cmd("Mac")[```bash
ALT=$(kubectl get secret s3-config -n monitoring \
  -o jsonpath='{.data.s3\.json}' | base64 -d)
```][Liest die bestehende Kontenliste. Kubernetes speichert Secrets Base64-kodiert, `base64 -d` macht sie wieder lesbar. Der Backslash in `s3\.json` ist nötig, weil der Punkt sonst als Pfadtrenner gilt.]

#cmd("Mac")[```bash
NEU=$(printf '%s' "$ALT" | jq \
  --arg a "$LOKI_ACCESS" --arg s "$LOKI_SECRET" \
  '.identities += [{
     name: "loki",
     credentials: [{accessKey: $a, secretKey: $s}],
     actions: ["Read:loki","Write:loki","List:loki","Tagging:loki"]
   }]')
```][`jq` hängt ein neues Konto an die Liste an. `--arg` übergibt die Werte sicher, statt sie in den Text einzusetzen. `actions` beschränkt das Konto auf den Bucket `loki`.]

#cmd("Mac")[```bash
printf '%s' "$NEU" | kubectl create secret generic s3-config \
  -n monitoring --from-file=s3.json=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -
```][Baut lokal ein neues Secret (`--dry-run=client -o yaml`) und wendet es an. Die Daten laufen über die Standardeingabe, damit sie nicht in der Prozessliste auftauchen.]

#cmd("Mac")[```bash
kubectl rollout restart deploy/s3 -n monitoring
kubectl rollout status deploy/s3 -n monitoring
```][SeaweedFS liest die Konten nur beim Start, also musst du neu starten.]

#cmd("Mac")[```bash
kubectl create secret generic loki-s3 -n monitoring \
  --from-literal=S3_ACCESS_KEY="$LOKI_ACCESS" \
  --from-literal=S3_SECRET_KEY="$LOKI_SECRET"
```][Legt die Zugangsdaten für Loki ab. Die Schlüsselnamen werden später zu Umgebungsvariablen.]

#cmd("Mac")[```bash
unset LOKI_ACCESS LOKI_SECRET ALT NEU
```][Entfernt die Geheimnisse aus deiner Shell.]

== Prometheus und Grafana installieren

Lege zuerst eine Werte-Datei an, die den Stack an k3s anpasst:

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

# Cilium ersetzt kube-proxy, also gibt es nichts zu überwachen.
kubeProxy:
  enabled: false
# Bei k3s laufen diese im k3s-Prozess, nicht als eigene Pods.
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false

prometheus:
  prometheusSpec:
    retention: 2d
    # Auch ServiceMonitors ohne Label "release: kps" einsammeln.
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
```, erklaerung: [
  Die letzten drei Werte sind wichtig: Standardmäßig beachtet Prometheus nur Objekte seines eigenen Helm-Releases. Mit `false` findet es auch die ServiceMonitors von Trivy und Cilium und deine Regeln. Die Datenquelle Tempo liegt schon bereit, Tempo selbst kommt in Kapitel 11.
])

#cmd("Mac")[```bash
kubectl create secret generic grafana-admin -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -hex 16)"
```][Legt ein zufälliges Grafana-Passwort an. Es steht in keiner Datei, nur im Cluster.]

#cmd("Mac")[```bash
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts
helm repo update
```][Falls das Repository schon eingetragen ist, meldet Helm das nur. `update` holt die aktuellen Versionslisten.]

#cmd("Mac")[```bash
helm upgrade --install kps \
  prometheus-community/kube-prometheus-stack \
  -n monitoring --version 92.18.0 \
  -f monitoring/kps-k3s-values.yaml \
  --wait --timeout 10m
```][Installiert Prometheus, Alertmanager, Grafana und die Exporter. Die Version entspricht deinem README.]

== Loki installieren

Das Loki-Chart ist in die Grafana-Community umgezogen. Das alte `grafana/loki` hängt auf Version 7.5.0 fest und wird nicht mehr aktuell gehalten.

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
      # Loki ersetzt das beim Start aus den Umgebungsvariablen.
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

# Auf einem kleinen Node sparen diese Abschaltungen viel RAM.
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
  `replication_factor: 1` ist Pflicht bei nur einer Instanz, sonst schlagen Anfragen fehl. `s3ForcePathStyle` ist für SeaweedFS nötig, und `retention_period: 168h` hält Logs sieben Tage. Mit `${...}` stehen keine Geheimnisse in der Datei. Das Chart setzt `-config.expand-env=true` selbst.
])

#cmd("Mac")[```bash
helm repo add grafana-community \
  https://grafana-community.github.io/helm-charts
helm repo update
```][Das neue Zuhause der Charts für Loki und Tempo.]

#cmd("Mac")[```bash
helm upgrade --install loki grafana-community/loki \
  -n monitoring --version 21.0.0 \
  -f monitoring/loki-values.yaml --wait --timeout 5m
```][Installiert Loki als einen einzigen Prozess. Das reicht laut Doku für einige zehn GB pro Tag.]

#cmd("Mac")[```bash
kubectl logs -n monitoring statefulset/loki --tail=20
```][Prüft den Start. Bei S3-Problemen stehen hier Meldungen wie `AccessDenied`, dann stimmt das Konto nicht.]

== Alloy sammelt die Logs ein

Alloy läuft als DaemonSet, also einmal pro Node. Es liest die Container-Logs unter `/var/log/pods` und dein Audit-Log und schickt beides an Loki. Die Konfiguration trennst du von den Helm-Werten, damit du sie leicht ändern kannst.

#datei("monitoring/config.alloy", ```hcl
// Pods auf diesem Node finden
discovery.kubernetes "pods" {
  role = "pod"
  selectors {
    role  = "pod"
    field = "spec.nodeName=" + sys.env("HOSTNAME")
  }
}

// Labels setzen und den Pfad zur Logdatei bauen
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

// Das CRI-Format von containerd auspacken
loki.process "pods" {
  stage.cri {}
  forward_to = [loki.write.default.receiver]
}

// Audit-Log des API-Servers aus Kapitel 9
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
  Lies die Datei von unten nach oben: `loki.write` ist das Ziel, jeder Block leitet mit `forward_to` weiter.
])

#datei("monitoring/alloy-values.yaml", ```yaml
alloy:
  # Das Audit-Log gehört root und ist nur für root lesbar.
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
  Alloy muss hier als root laufen, das ist ein bewusster Kompromiss: Der Pod hat Lesezugriff auf den Host, dafür mountet er das Audit-Verzeichnis nur lesend. Das Chart gibt dem Pod auch die nötigen Rechte für `discovery.kubernetes`.
])

#cmd("Mac")[```bash
kubectl create configmap alloy-config -n monitoring \
  --from-file=config.alloy=monitoring/config.alloy
```][Legt die Konfiguration als ConfigMap ab. Bei Änderungen ergänzt du `--dry-run=client -o yaml | kubectl apply -f -`.]

#cmd("Mac")[```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```][Alloy bleibt im Hauptrepository von Grafana.]

#cmd("Mac")[```bash
helm upgrade --install alloy grafana/alloy \
  -n monitoring --version 1.15.0 \
  -f monitoring/alloy-values.yaml --wait
```][Startet Alloy als DaemonSet.]

#cmd("Mac")[```bash
kubectl logs -n monitoring ds/alloy -c alloy --tail=20
```][Syntaxfehler in `config.alloy` stehen hier mit Zeilennummer.]

== Hubble und Trivy anbinden

Beide Dienste laufen schon. Jetzt, da Prometheus die ServiceMonitor-CRDs mitgebracht hat, können sie Metriken liefern.

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
```][Führt beide Dateien zusammen. Die Agenten starten dabei neu, bestehende Verbindungen laufen meist weiter.]

Ändere in `trivy/values.yaml` die Zeile unter `serviceMonitor` auf `enabled: true`.

#cmd("Mac")[```bash
helm upgrade trivy-operator aqua/trivy-operator \
  -n trivy-system --version 0.38.1 \
  -f trivy/values.yaml --wait
```][Legt den ServiceMonitor für Trivy an.]

Falco schreibt schon auf die Standardausgabe, dafür ist nichts weiter zu tun. Default-Deny aus Kapitel 6 sperrt Prometheus aber aus `demo` aus. Soll deine Anwendung Metriken liefern, erlaubst du das ausdrücklich:

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
  Mit `io.kubernetes.pod.namespace` wählst du Pods aus einem anderen Namespace aus. Hier ist nur Prometheus gemeint, nicht der ganze Namespace.
])

#cmd("Mac")[```bash
kubectl apply -f security/netpol/05-prometheus.yaml
```][Lädt die Regel.]

== Grafana öffnen

#cmd("Mac")[```bash
kubectl get secret grafana-admin -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```][Zeigt das Grafana-Passwort einmalig im Terminal an.]

#cmd("Mac")[```bash
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
```][Grafana ist nun unter #link("http://localhost:3000") erreichbar. Anmeldung mit `admin`.]

Öffne *Explore*, wähle die Datenquelle *Loki* und gib diese Abfrage ein:

```logql
{namespace="kube-system", container="coredns"}
```

#pruefe[
  Die Log-Zeilen von CoreDNS erscheinen. Wechselst du zur Datenquelle *Prometheus* und fragst `hubble_flows_processed_total` ab, siehst du die Hubble-Metriken.
]

== Audit-Logs abfragen

Die `jq`-Abfragen aus Kapitel 9 schreibst du jetzt in LogQL. `| json` zerlegt jede Zeile, verschachtelte Felder wie `objectRef.name` werden dabei zu `objectRef_name`.

Wer außer Systemkomponenten hat Secrets gelesen?

```logql
{job="audit"} | json
  | objectRef_resource="secrets"
  | verb=~"get|list"
  | user_username!~"system:.*"
```

Welche Anfragen wurden abgelehnt?

```logql
{job="audit"} | json | responseStatus_code="403"
```

Wer hat RBAC-Regeln geändert?

```logql
{job="audit"} | json
  | objectRef_apiGroup="rbac.authorization.k8s.io"
  | verb=~"create|update|patch|delete"
```

== Falco-Meldungen abfragen

`line_format` zeigt nur den Regelnamen:

```logql
{namespace="falco", container="falco"} | json | line_format "{{.rule}}"
```

Nur die ernsten Meldungen:

```logql
{namespace="falco", container="falco"}
  | json
  | priority =~ "Warning|Error|Critical|Alert|Emergency"
```

Nach Regel gezählt:

```logql
sum by (rule) (
  count_over_time(
    {namespace="falco", container="falco"} | json | rule != "" [1h]
  )
)
```

== Trivy-Ergebnisse abfragen

Wähle die Datenquelle *Prometheus*. Prüfe zuerst unter *Explore*, ob `up{job=~".*trivy.*"}` den Wert `1` liefert.

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
  Schreibe eine LogQL-Abfrage, die alle Log-Zeilen mit dem Wort `error` aus dem Namespace `monitoring` zeigt. Tipp: Filter hängst du mit `|=` an den Label-Selektor an.
]

#gelernt(
  [Logs außerhalb des Nodes kann ein Angreifer nicht einfach löschen.],
  [Jeder Dienst bekommt sein eigenes S3-Konto, damit ein Einbruch begrenzt bleibt.],
  [Prometheus sammelt fremde ServiceMonitors erst ein, wenn du es erlaubst.],
  [Alle Schichten landen jetzt an einem Ort und lassen sich gemeinsam abfragen.],
)

#import "../lib.typ": *

#kapitel(
  [Tempo: Dem Weg einer Anfrage folgen],
  ziel: [Du speicherst Traces in Tempo und siehst, was während einer API-Anfrage passiert, bis hin zur Prüfung durch Kyverno.],
  zeit: [60 Minuten],
  braucht: [Kapitel 10],
)

== Drei Arten von Signalen

#tabelle(
  (auto, 1fr, auto),
  ([Signal], [Beantwortet], [Speicher]),
  [Metriken], [Wie viel, wie oft?], [Prometheus],
  [Logs], [Was genau ist passiert?], [Loki],
  [Traces], [Welchen Weg nahm eine Anfrage, und wo verging die Zeit?], [Tempo],
)

Ein Trace besteht aus *Spans*. Jeder Span ist ein Arbeitsschritt mit Start und Dauer.

#hinweis("Was Tempo für die Sicherheit leistet", akzent, akzent-hell)[
  Tempo ist kein Sicherheitstool im engeren Sinn, und in deinem Cluster liefern Anwendungen erst Traces, wenn du sie instrumentierst. Nützlich ist es trotzdem: Der API-Server kann seine Anfragen als Traces liefern. Du siehst dann, wie lange etwa der Kyverno-Webhook eine Anfrage aufhält. Das hilft bei Störungen durch Admission-Webhooks und zeigt später in eigenen Anwendungen, welchen Weg eine verdächtige Anfrage genommen hat.
]

== Bucket und S3-Konto

Das Muster kennst du aus Kapitel 10.

#cmd("Mac")[```bash
kubectl exec -n monitoring deploy/s3 -- sh -c \
  "echo 's3.bucket.create -name tempo' | weed shell -master=localhost:9333"
```][Legt den Bucket `tempo` an.]

#cmd("Mac")[```bash
TEMPO_ACCESS=$(openssl rand -hex 10)
TEMPO_SECRET=$(openssl rand -hex 20)
ALT=$(kubectl get secret s3-config -n monitoring \
  -o jsonpath='{.data.s3\.json}' | base64 -d)
```][Erzeugt die Zugangsdaten und liest die Kontenliste.]

#cmd("Mac")[```bash
NEU=$(printf '%s' "$ALT" | jq \
  --arg a "$TEMPO_ACCESS" --arg s "$TEMPO_SECRET" \
  '.identities += [{
     name: "tempo",
     credentials: [{accessKey: $a, secretKey: $s}],
     actions: ["Read:tempo","Write:tempo","List:tempo","Tagging:tempo"]
   }]')
```][Hängt das Konto an. Tempo darf nur in seinen eigenen Bucket.]

#cmd("Mac")[```bash
printf '%s' "$NEU" | kubectl create secret generic s3-config \
  -n monitoring --from-file=s3.json=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deploy/s3 -n monitoring
kubectl rollout status deploy/s3 -n monitoring
```][Schreibt die Liste zurück und startet SeaweedFS neu.]

#cmd("Mac")[```bash
kubectl create secret generic tempo-s3 -n monitoring \
  --from-literal=S3_ACCESS_KEY="$TEMPO_ACCESS" \
  --from-literal=S3_SECRET_KEY="$TEMPO_SECRET"
unset TEMPO_ACCESS TEMPO_SECRET ALT NEU
```][Legt die Zugangsdaten ab und räumt die Shell auf.]

== Tempo installieren

#datei("monitoring/tempo-values.yaml", ```yaml
tempo:
  retention: 168h
  storage:
    trace:
      backend: s3
      s3:
        bucket: tempo
        endpoint: s3.monitoring.svc.cluster.local:8333
        # Tempo ersetzt das beim Start aus den Umgebungsvariablen.
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
  Anders als bei Loki musst du `config.expand-env` hier selbst setzen. Die Endpoint-Angabe steht ohne `http://`, das `insecure: true` regelt das Protokoll. Der `wal` liegt lokal und puffert Traces, bevor sie ins S3 wandern.
])

#cmd("Mac")[```bash
helm upgrade --install tempo grafana-community/tempo \
  -n monitoring --version 3.2.1 \
  -f monitoring/tempo-values.yaml --wait --timeout 5m
```][Installiert Tempo als einzelnen Prozess, passend zu deinem einen Node.]

#cmd("Mac")[```bash
kubectl logs -n monitoring statefulset/tempo --tail=20
```][Prüft den Start. `AccessDenied` weist wieder auf das Konto hin.]

== Alloy nimmt Traces an

Alloy sammelt nicht nur Logs ein, es nimmt auch Traces per OTLP an und reicht sie an Tempo weiter. So gibt es für alle Signale nur einen Sammelpunkt. Hänge diese Blöcke an `monitoring/config.alloy` an:

#datei("monitoring/config.alloy (am Ende ergänzen)", ```hcl
// Traces per OTLP annehmen
otelcol.receiver.otlp "default" {
  grpc {
    endpoint = "0.0.0.0:4317"
  }
  output {
    traces = [otelcol.processor.batch.default.input]
  }
}

// In Paketen senden, das schont das Netz
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

Der API-Server läuft auf dem Host und kennt keine Cluster-DNS-Namen. Er braucht daher eine feste IP. Ergänze dafür `monitoring/alloy-values.yaml`:

#datei("monitoring/alloy-values.yaml (ergänzen)", ```yaml
alloy:
  # ... wie bisher, zusätzlich:
  extraPorts:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP

# Neuer Block auf oberster Ebene
service:
  clusterIP: 10.43.0.50
```, erklaerung: [
  `10.43.0.50` liegt im Service-Netz und ist nur im Cluster und auf dem Node erreichbar, nicht aus deinem Heimnetz. Einen `hostPort` auf `127.0.0.1` kann Cilium in dieser Betriebsart nicht bedienen, deshalb dieser Weg.
])

#cmd("Mac")[```bash
kubectl create configmap alloy-config -n monitoring \
  --from-file=config.alloy=monitoring/config.alloy \
  --dry-run=client -o yaml | kubectl apply -f -
```][Aktualisiert die ConfigMap.]

#cmd("Mac")[```bash
kubectl delete svc alloy -n monitoring
helm upgrade alloy grafana/alloy \
  -n monitoring --version 1.15.0 \
  -f monitoring/alloy-values.yaml --wait
```][Die ClusterIP eines Service lässt sich nicht ändern. Deshalb löschst du ihn, und Helm legt ihn mit der neuen IP an.]

#cmd("Mac")[```bash
kubectl get svc alloy -n monitoring
kubectl logs -n monitoring ds/alloy -c alloy --tail=20
```][Die Spalte `CLUSTER-IP` zeigt `10.43.0.50`, und im Log stehen keine Fehler.]

== Der erste Trace

Das Testprogramm `telemetrygen` erzeugt künstliche Traces.

#cmd("Mac")[```bash
kubectl run telemetrygen -n monitoring --rm -it --restart=Never \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.164.1 \
  -- traces --otlp-endpoint=alloy.monitoring.svc.cluster.local:4317 \
  --otlp-insecure --traces=5
```][Schickt fünf Traces an Alloy. Sie gehen weiter an Tempo.]

Öffne in Grafana *Explore*, wähle die Datenquelle *Tempo* und den Abfragetyp *TraceQL*:

```traceql
{ resource.service.name = "telemetrygen" }
```

#pruefe[
  Du siehst eine Liste von Traces. Ein Klick zeigt die Spans als Wasserfall. Falls nichts erscheint, warte eine Minute und prüfe die Alloy-Logs auf Verbindungsfehler zu Tempo.
]

== Der API-Server liefert Traces

#datei("security/tracing.yaml", ```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: TracingConfiguration
endpoint: 10.43.0.50:4317
# 100000 von einer Million: jede zehnte Anfrage
samplingRatePerMillion: 100000
```, erklaerung: [
  Für das Lab ist jede zehnte Anfrage gut sichtbar. Im Dauerbetrieb senkst du den Wert, denn Traces kosten Speicher. Die Verbindung läuft laut Kubernetes-Doku unverschlüsselt und kann kein TLS, sie darf also nur intern laufen.
])

#cmd("Mac")[```bash
scp security/tracing.yaml <user>@172.16.0.136:/tmp/tracing.yaml
```][Bringt die Datei auf den Node.]

Ergänze in `k3s/config.yaml` unter `kube-apiserver-arg` eine Zeile:

#datei("k3s/config.yaml (ergänzen)", ```yaml
  - "tracing-config-file=/var/lib/rancher/k3s/server/tracing.yaml"
```)

#cmd("Mac")[```bash
scp k3s/config.yaml <user>@172.16.0.136:/tmp/config.yaml
ssh <user>@172.16.0.136
```][Überträgt die Konfiguration und öffnet die Sitzung.]

#cmd("Node")[```bash
sudo install -m 600 -o root -g root /tmp/tracing.yaml \
  /var/lib/rancher/k3s/server/tracing.yaml
sudo install -m 600 -o root -g root /tmp/config.yaml \
  /etc/rancher/k3s/config.yaml
rm /tmp/tracing.yaml /tmp/config.yaml
sudo systemctl restart k3s
```][Setzt beide Dateien ein und startet k3s neu.]

#cmd("Node")[```bash
exit
```][Zurück zum Laptop.]

#cmd("Mac")[```bash
kubectl get pods -A > /dev/null
kubectl run trace-test -n falco-lab --image=nginx:1.29-alpine
kubectl delete pod trace-test -n falco-lab
```][Erzeugt API-Anfragen. Wiederhole das ein paarmal, denn nur jede zehnte wird aufgezeichnet.]

```traceql
{ resource.service.name = "apiserver" }
```

Öffne einen Trace zum Anlegen eines Pods und betrachte die Spans. Webhook-Aufrufe suchst du gezielt so:

```traceql
{ resource.service.name = "apiserver" && name =~ ".*webhook.*" }
```

#pruefe[
  Du findest Spans für Webhook-Aufrufe, darunter den von Kyverno, mit ihrer Dauer. Die genauen Span-Namen hängen von der Kubernetes-Version ab. Findest du nichts, entferne den Namensfilter und suche im Wasserfall.
]

#falle[
  Traces können interne URLs und Objektnamen enthalten. Behandle Tempo daher wie Logs: kein Zugriff von außen, und der OTLP-Port nimmt ohne Anmeldung alles an. Jeder Pod im Cluster könnte also Traces einliefern. In Namespaces mit Default-Deny ist das gesperrt, bis du es erlaubst.
]

== Von Traces zu Logs springen

Die Datenquelle hat `tracesToLogsV2` aus Kapitel 10 gesetzt. Klicke in einem Span auf *Logs for this span*, dann öffnet Grafana passende Loki-Zeilen. Auf diese Weise kommst du von „diese Anfrage war langsam“ zu „das stand dabei im Log“.

#aufgabe[
  Stoppe Kyverno mit `kubectl scale deploy -n kyverno kyverno-admission-controller --replicas=0` und lege einen Pod in `falco-lab` an. Was passiert, und wie sieht der Trace aus? Skaliere danach unbedingt wieder auf `1` hoch.
]

#gelernt(
  [Metriken zählen, Logs erzählen, Traces zeigen den Weg.],
  [Alloy ist der gemeinsame Sammelpunkt für Logs und Traces.],
  [Auch der API-Server liefert Traces, darin siehst du Admission-Webhooks.],
  [Dienste auf dem Host brauchen eine feste IP, weil sie kein Cluster-DNS kennen.],
)

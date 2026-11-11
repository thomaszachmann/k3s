#import "../lib.typ": *

#kapitel(
  [Die Zentrale: Prometheus und Thanos Receive],
  ziel: [Auf obs läuft Prometheus, schreibt seine Metriken an Thanos Receive, und Thanos legt sie dauerhaft in S3 ab. Thanos Query zeigt alles an einer Stelle.],
  zeit: [75 Minuten, dazu zwei Stunden Wartezeit für den ersten Block in S3],
  braucht: [Kapitel 3 (SeaweedFS mit Bucket `thanos` und Secret `thanos-objstore`)],
)

== Was du aufbaust

In diesem Kapitel entsteht der Kern der Metrik-Zentrale. Noch schreibt nur obs selbst hinein. Die App-Cluster folgen in Kapitel 5 über genau denselben Weg.

#tabelle(
  (auto, 1fr),
  ([Komponente], [Aufgabe]),
  [Prometheus], [Sammelt die Metriken von obs ein, wertet die Standardregeln aus und schickt alles per Remote Write weiter],
  [Alertmanager], [Nimmt Alarme an, die Konfiguration folgt in Kapitel 7],
  [Thanos Receive], [Nimmt Remote Write an, trennt nach Mandant, hält 6 Stunden lokal und lädt Blöcke nach S3],
  [Thanos Store], [Macht die Blöcke in S3 abfragbar],
  [Thanos Query], [Fragt Receive, Store und Ruler gleichzeitig ab und entfernt Duplikate],
  [Thanos Compact], [Fasst Blöcke zusammen, rechnet sie herunter und löscht nach Ablauf],
  [Thanos Ruler], [Wertet Regeln über alle Cluster aus, die Regeln selbst kommen in Kapitel 7],
  [Grafana], [Startet mit Standardwerten, wird in Kapitel 6 eingerichtet],
)

Der Weg einer Messung sieht so aus: Prometheus holt sie ab und schickt sie sofort an Receive. Receive hält sie im Speicher und auf seiner Platte. Alle zwei Stunden schreibt Receive einen fertigen Block in den Bucket `thanos`. Ab dann liefert Thanos Store die Daten aus S3, und Receive löscht seine Kopie nach sechs Stunden. Thanos Query sieht beide Quellen und setzt sie für jede Abfrage nahtlos zusammen.

#warum[
  Das Security-Buch nutzt den Thanos Sidecar. Er sitzt neben Prometheus und lädt dessen Blöcke hoch. Das passt, solange es nur einen Prometheus gibt. Hier schicken drei Cluster ihre Daten in die Zentrale, und die App-Cluster haben gar keinen eigenen Prometheus. Receive ist der eine Empfänger für alle, und er kennt Mandanten. Mehr Hintergrund im Buch Kubernetes Observability Hands-On.
]

== Die Werte für kube-prometheus-stack

Die Werte liegen in `observability/central/kps/values.yaml`. Kapitel 6 und 7 ergänzen später eigene Dateien, diese hier bleibt die Grundlage. Der erste Teil beschreibt Prometheus:

#datei("observability/central/kps/values.yaml (Ausschnitt)", ```yaml
prometheus:
  prometheusSpec:
    retention: 6h
    scrapeInterval: 30s
    evaluationInterval: 30s
    externalLabels:
      cluster: obs
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
    scrapeConfigSelectorNilUsesHelmValues: false
    ruleSelector:
      matchLabels:
        auswertung: lokal
    ruleNamespaceSelector: {}
    remoteWrite:
      - name: thanos-receive
        url: http://thanos-receive.monitoring.svc:19291/api/v1/receive
        headers:
          THANOS-TENANT: obs
        sendExemplars: true
    enableFeatures:
      - exemplar-storage
```, erklaerung: [
  `retention: 6h` reicht, weil Prometheus hier nur noch Zwischenstation ist. `externalLabels` hängt an jede Serie `cluster="obs"`, genau wie Alloy es in Kapitel 5 für die App-Cluster tut. Der Header `THANOS-TENANT` macht obs in Receive zum Mandanten `obs`. Die vier `...NilUsesHelmValues: false` lassen Prometheus auch fremde ServiceMonitors einsammeln, etwa die von Thanos. `sendExemplars` und `exemplar-storage` bereiten den Sprung von einer Metrik zum passenden Trace in Kapitel 9 vor.
])

Im Rest der Datei stehen die Regel-Auswahl, der Thanos Ruler und die k3s-Besonderheiten:

#datei("observability/central/kps/values.yaml (Ausschnitt)", ```yaml
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeProxy:
  enabled: false
kubeEtcd:
  enabled: true
  endpoints:
    - 172.16.0.126
  service:
    port: 2381
    targetPort: 2381

defaultRules:
  create: true
  labels:
    auswertung: lokal

thanosRuler:
  enabled: true
  thanosRulerSpec:
    ruleSelector:
      matchLabels:
        auswertung: global
    ruleNamespaceSelector: {}
    queryEndpoints:
      - thanos-query.monitoring.svc.cluster.local:10902
    evaluationInterval: 30s
```, erklaerung: [
  Controller-Manager, Scheduler und kube-proxy laufen bei k3s im k3s-Prozess und lauschen nur auf `127.0.0.1`. Prometheus erreicht sie nicht, sie würden dauerhaft als `down` erscheinen. etcd dagegen bietet seine Metriken dank `etcd-expose-metrics` aus Kapitel 2 auf der Node-IP an.
])

Die Regel-Auswahl verdient einen genaueren Blick. Ein Label-Selektor kennt kein „oder“. Deshalb bekommen die Standardregeln des Charts mit `defaultRules.labels` dasselbe Label wie deine lokalen Regeln.

#tabelle(
  (auto, auto, 1fr),
  ([Label am PrometheusRule], [Wertet aus], [Sieht]),
  [`auswertung: lokal`], [Prometheus auf obs], [Nur die Daten von obs, dafür ohne Umweg],
  [`auswertung: global`], [Thanos Ruler], [Alle Cluster, über Thanos Query],
  [kein Label], [niemand], [Die Regel bleibt wirkungslos],
)

#falle[
  Die Standardregeln laufen in Prometheus auf obs. Ihre Ergebnisse, etwa die Aufnahmeregeln für CPU pro Pod, gibt es deshalb zunächst nur für `cluster="obs"`. Wie du solche Regeln für alle Cluster auswertest, zeigen die Kapitel 7 und 10.
]

Der Thanos Ruler fragt nicht Prometheus, sondern Thanos Query. So sieht er die Daten aller Cluster. Er gehört zum Helm-Release und läuft ab jetzt mit, Regeln und den Weg zum Alertmanager bekommt er in Kapitel 7.

== kube-prometheus-stack installieren

#cmd("Mac")[```bash
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community
```][Trägt das Chart-Repository ein und holt die aktuelle Versionsliste. Ist es schon eingetragen, meldet Helm das nur.]

#cmd("Mac")[```bash
helm --kube-context obs upgrade --install kps \
  prometheus-community/kube-prometheus-stack \
  -n monitoring --version 92.18.0 \
  -f observability/central/kps/values.yaml \
  --wait --timeout 10m
```][Installiert Operator, Prometheus, Alertmanager, Thanos Ruler, Grafana, kube-state-metrics und node-exporter auf obs. `--wait` kehrt erst zurück, wenn alle Pods bereit sind.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring get pods
```][Zeigt alle Pods im Namespace.]

#pruefe[
  Neben `s3` laufen unter anderem `prometheus-kps-kube-prometheus-stack-prometheus-0` (2/2), `alertmanager-kps-kube-prometheus-stack-alertmanager-0`, `thanos-ruler-kps-kube-prometheus-stack-thanos-ruler-0`, `kps-grafana-...`, `kps-kube-state-metrics-...` und `kps-prometheus-node-exporter-...`. Alle stehen auf `Running`.
]

Prometheus versucht schon jetzt, an Receive zu schreiben. Den Empfänger gibt es noch nicht.

#cmd("Mac")[```bash
kubectl --context obs -n monitoring logs \
  prometheus-kps-kube-prometheus-stack-prometheus-0 \
  -c prometheus --tail=50 | grep -i remote
```][Filtert die Meldungen zum Remote Write heraus.]

#pruefe[
  Eine Meldung wie `level=WARN ... msg="Failed to send batch, retrying" component=remote ... no such host` für `thanos-receive.monitoring.svc`. Das ist im Moment richtig. Prometheus puffert die Daten in seinem Write-Ahead-Log und schickt sie nach, sobald Receive da ist.
]

== Thanos Receive

Receive läuft als StatefulSet mit einer Replika. Es nimmt Daten an, verteilt sie über einen Hashring und speichert sie. In großen Installationen sind das zwei getrennte Rollen, _Router_ und _Ingestor_. Hier erledigt ein Pod beides.

#datei("observability/central/thanos/receive.yaml (Ausschnitt)", ```yaml
args:
  - receive
  - --grpc-address=0.0.0.0:10901
  - --http-address=0.0.0.0:10902
  - --remote-write.address=0.0.0.0:19291
  - --tsdb.path=/data
  - --tsdb.retention=6h
  - --tsdb.max-exemplars=100000
  - --objstore.config-file=/etc/thanos/objstore.yml
  - --receive.tenant-header=THANOS-TENANT
  - --receive.tenant-label-name=tenant_id
  - --receive.default-tenant-id=unbekannt
  - --receive.hashrings-file=/etc/thanos-hashring/hashrings.json
  - --receive.local-endpoint=thanos-receive-0.thanos-receive.monitoring.svc.cluster.local:10901
  - --receive.replication-factor=1
  - --label=receive_replica="0"
```, erklaerung: [
  Port `19291` nimmt Remote Write an, `10901` beantwortet Abfragen von Thanos Query per gRPC. Jeder Mandant bekommt eine eigene TSDB und das Label `tenant_id`. Wer ohne Header schreibt, landet bei `unbekannt`, so fällt ein falsch eingerichteter Sender sofort auf. `--tsdb.max-exemplars` hebt Exemplars für Kapitel 9 auf.
])

Der Hashring ist eine kleine JSON-Datei in einer ConfigMap derselben Datei. Er enthält genau einen Eintrag: den Pod selbst. Weil dieser Eintrag exakt mit `--receive.local-endpoint` übereinstimmt, weiß Receive, dass es die Daten selbst speichern soll, statt sie weiterzuleiten. Der Name stammt vom headless Service `thanos-receive`, der jedem Pod eines StatefulSets einen festen DNS-Namen gibt.

#warum[
  Ohne Hashring würde Receive ebenfalls laufen. Mit Hashring ist die Rolle aber ausdrücklich beschrieben, und der Weg zu mehr Replikas steht offen: weitere Einträge in die Liste, `--receive.replication-factor=3`, fertig. Das `receive_replica`-Label unterscheidet dann die Kopien, und Thanos Query fasst sie wieder zusammen.
]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring get secret thanos-objstore
```][Prüft, ob die S3-Zugangsdaten aus Kapitel 3 da sind. Receive startet ohne sie nicht.]

#cmd("Mac")[```bash
kubectl --context obs apply -f observability/central/thanos/receive.yaml
```][Legt Hashring-ConfigMap, StatefulSet und Service an.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring rollout status \
  statefulset/thanos-receive --timeout=3m
```][Wartet, bis der Pod bereit ist.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring logs \
  thanos-receive-0 --tail=30
```][Zeigt den Start von Receive.]

#pruefe[
  Zeilen mit `level=info`, keine mit `level=error`. Gleich beim Start öffnet Receive eine leere TSDB für den Standard-Mandanten, `tenant=unbekannt msg="opening TSDB"`. Das ist normal. Nach spätestens einer Minute schreibt Prometheus, und es folgt die entscheidende Zeile:
  ```
  level=info component=receive component=multi-tsdb tenant=obs msg="TSDB is now ready"
  ```
  Fehlermeldungen zu S3 wie `Access Denied` bedeuten, dass `thanos-objstore` nicht stimmt.
]

=== So testest du Receive

Receive hat keine eigene Oberfläche. Ob er arbeitet, verraten dir zwei Endpunkte auf seinem HTTP-Port 10902. Leite ihn dafür in einem zweiten Terminal um:

#cmd("Mac")[```bash
kubectl --context obs -n monitoring port-forward thanos-receive-0 12902:10902
```][Port 12902 auf dem Mac, damit er nicht mit Thanos Query kollidiert, das später 10902 bekommt.]

#cmd("Mac")[```bash
curl -s localhost:12902/-/ready; echo
curl -s localhost:12902/metrics | grep -E '^prometheus_tsdb_head_series\{'
curl -s localhost:12902/metrics | grep 'handler="receive"'
```][`/-/ready` ist dieselbe Prüfung, die Kubernetes als Readiness-Probe nutzt. `/metrics` zeigt die Messwerte von Receive selbst: wie viele Serien jeder Mandant gerade im Speicher hat und wie viele Schreibanfragen angekommen sind.]

#pruefe[
  ```
  OK
  prometheus_tsdb_head_series{tenant="obs"} 124765
  prometheus_tsdb_head_series{tenant="unbekannt"} 0
  http_requests_total{code="200",handler="receive",method="post",tenant="obs"} 406
  ```
  Die Zahlen wachsen mit jedem Aufruf. Steht bei `obs` eine Null oder fehlt die Zeile mit `code="200"`, kommt bei Receive nichts an. Dann zeigen die Logs von Prometheus den Grund. Beende den Port-Forward danach mit `Ctrl-C`.
]

Damit kannst du Receive für jeden Sender nutzen, der Prometheus Remote Write spricht: Prometheus, Grafana Alloy, das OpenTelemetry Collector, Telegraf oder eigene Programme. Der Sender braucht nur die URL `/api/v1/receive` auf Port 19291 und den Header `THANOS-TENANT`.

== Query, Store und Compact

Die drei übrigen Komponenten sind zustandslos. Ihre lokalen Daten lassen sich jederzeit aus S3 neu aufbauen, deshalb reicht jeweils ein `emptyDir`. Wichtig ist bei Query die Liste der Endpunkte:

#datei("observability/central/thanos/query.yaml (Ausschnitt)", ```yaml
args:
  - query
  - --grpc-address=0.0.0.0:10901
  - --http-address=0.0.0.0:10902
  - --query.replica-label=receive_replica
  - --query.replica-label=prometheus_replica
  - --query.replica-label=thanos_ruler_replica
  - |-
    --endpoint.sd-config=endpoints:
      - address: dns+thanos-receive.monitoring.svc.cluster.local:10901
      - address: dns+thanos-store.monitoring.svc.cluster.local:10901
      - address: dnssrv+_grpc._tcp.thanos-ruler-operated.monitoring.svc.cluster.local
```, erklaerung: [
  `dns+` löst einen Namen in die Pod-IPs auf, `dnssrv+` liest zusätzlich den Port aus einem SRV-Eintrag. Den Ruler bindest du ein, damit seine `ALERTS`-Serien und die Ergebnisse globaler Aufnahmeregeln in Query sichtbar sind. Die drei `replica-label` nennen die Labels, in denen sich nur Kopien derselben Daten unterscheiden.
])

Beim Compactor legst du fest, wie lange Daten in S3 bleiben:

#datei("observability/central/thanos/compact.yaml (Ausschnitt)", ```yaml
args:
  - compact
  - --wait
  - --wait-interval=5m
  - --data-dir=/data
  - --objstore.config-file=/etc/thanos/objstore.yml
  - --retention.resolution-raw=30d
  - --retention.resolution-5m=90d
  - --retention.resolution-1h=365d
  - --delete-delay=1h
```, erklaerung: [
  Rohdaten bleiben 30 Tage. Daraus rechnet der Compactor Mittelwerte über 5 Minuten (90 Tage) und über eine Stunde (ein Jahr). Für einen Jahresverlauf braucht niemand jeden 30-Sekunden-Wert. `--wait` hält den Prozess am Leben, statt nach einem Durchlauf zu enden.
])

#falle[
  Pro Bucket darf genau ein Compactor laufen. Zwei Compactors bearbeiten dieselben Blöcke gleichzeitig und beschädigen die Daten. Deshalb ist das Deployment auf eine Replika und die Strategie `Recreate` festgelegt.
]

#cmd("Mac")[```bash
kubectl --context obs apply \
  -f observability/central/thanos/store.yaml \
  -f observability/central/thanos/query.yaml \
  -f observability/central/thanos/compact.yaml
```][Legt die drei Deployments und ihre Services an.]

#cmd("Mac")[```bash
kubectl --context obs apply \
  -f observability/central/thanos/servicemonitor.yaml
```][Ein ServiceMonitor für alle Thanos-Komponenten. Er wählt jeden Service mit dem Label `app.kubernetes.io/part-of: thanos` und liest dessen Port `http`. Das Label `job` heißt dann wie der Service, etwa `thanos-receive`.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring get pods \
  -l app.kubernetes.io/part-of=thanos
```][Zeigt nur die Thanos-Pods.]

#pruefe[
  Vier Pods auf `Running` und `1/1`: `thanos-receive-0`, `thanos-query-...`, `thanos-store-...` und `thanos-compact-...`. Der Thanos Ruler gehört zum Helm-Release und trägt dieses Label nicht.
]

== Thanos Query ansehen

#cmd("Mac")[```bash
kubectl --context obs -n monitoring port-forward \
  svc/thanos-query 10902:10902
```][Leitet Port 10902 auf deinen Laptop um. Lass das Terminal offen und öffne #link("http://localhost:10902") im Browser.]

#cmd("Mac")[```bash
curl -s http://localhost:10902/api/v1/stores | jq '.data | keys'
```][Fragt in einem zweiten Terminal, welche Endpunkte Query kennt.]

#pruefe[
  ```
  [
    "receive",
    "rule",
    "store"
  ]
  ```
  Direkt nach dem Start fehlt `store` oft noch für etwa eine halbe Minute, bis Thanos Store den Bucket gelesen hat. Fehlt ein Typ dauerhaft, prüfe mit `kubectl --context obs -n monitoring logs deploy/thanos-query` die DNS-Auflösung der Endpunkte.
]

Die Seite *Endpoints* im Menü oben zeigt dasselbe wie der `curl`-Befehl, nur ausführlicher: welche Quellen Thanos Query kennt, ob sie erreichbar sind (`UP`) und welche Mandanten sie anbieten.

#bild("bilder/04-query-endpoints.png", [Thanos Query, Seite „Endpoints“: Receive bietet die Mandanten `obs` und `unbekannt` an, dazu kommen Ruler und Store. Store zeigt noch keine Labels, weil in S3 noch kein Block liegt.])

Wechsle zurück auf *Graph*. Klicke in das Eingabefeld, gib diese Abfrage ein und klicke auf *Execute*:

```promql
count by (tenant_id, cluster) (up)
```

#bild("bilder/04-query-mandanten.png", [Eingabefeld und *Execute* sind rot markiert. Im Reiter *Table* erscheint das Ergebnis als Zahl.])

#pruefe[
  Eine Zeile mit `tenant_id="obs"` und `cluster="obs"`. Die Zahl ist die Menge der Scrape-Ziele auf obs, im Labor um die 19. Siehst du stattdessen `tenant_id="unbekannt"`, fehlt der Header in `remoteWrite`.
]

Schalte in der Oberfläche die Deduplizierung einmal aus und wieder ein. Ohne Deduplizierung siehst du die Labels `prometheus_replica` und `receive_replica`, mit ihr verschwinden sie. Genau das bewirken die `replica-label`-Argumente.

== Läuft der Remote Write sauber?

Prometheus führt über seinen Remote Write genau Buch. Zwei Abfragen in Thanos Query genügen:

```promql
rate(prometheus_remote_storage_samples_total{cluster="obs"}[5m])
```

```promql
rate(prometheus_remote_storage_samples_failed_total{cluster="obs"}[5m])
```

Wähle für Kurven vor dem Klick auf *Execute* den Reiter *Graph* unter dem Eingabefeld. Mit `-` und `+` links daneben stellst du den Zeitraum ein.

#bild("bilder/04-query-remote-write.png", [Reiter *Graph*: Prometheus schickt einige tausend Werte pro Sekunde an Receive. Die Kurve beginnt dort, wo Receive gestartet wurde.])

#pruefe[
  Die erste Kurve liegt dauerhaft über null, im Labor bei einigen tausend Werten pro Sekunde. Die zweite ist leer oder null. Steigen die Fehler, steht der Grund in den Logs von `thanos-receive-0`.
]

#falle[
  Startet Receive neu, während Prometheus schreibt, meldet Receive oft kurz `out of order sample` oder `409 Conflict`. Prometheus wiederholt dann alte Daten, die Receive schon hat. Das legt sich nach wenigen Minuten von selbst. Bleibt es, zeigt Kapitel 14 die Ursachen.
]

== Der erste Block in S3

Receive lädt Blöcke alle zwei Stunden hoch. Mach eine Pause oder arbeite mit Kapitel 5 weiter und komm danach zurück.

#cmd("Mac")[```bash
kubectl --context obs -n monitoring exec deploy/thanos-compact -- \
  thanos tools bucket inspect \
  --objstore.config-file=/etc/thanos/objstore.yml
```][Nutzt das Thanos-Programm im Compactor-Pod, um den Bucket zu lesen. Dort liegt die S3-Konfiguration schon, du brauchst keine Zugangsdaten auf dem Laptop.]

#pruefe[
  Eine Tabelle mit mindestens einer Zeile. Die Spalte `RANGE` zeigt `2h0m0s`, die Spalte `LABELS` enthält `receive_replica` mit dem Wert `0` und `tenant_id` mit dem Wert `obs`. Später kommen Zeilen für `app1` und `app2` dazu und, nach einigen Tagen, längere Blöcke des Compactors.
]

Thanos Store findet neue Blöcke von selbst. Ab jetzt beantwortet Query Abfragen, die mehr als sechs Stunden zurückreichen, aus S3.

#aufgabe[
  Schreib mit `curl` direkt an Receive, ohne Header. Leite dazu Port 19291 per `port-forward` um und sende eine leere POST-Anfrage an `/api/v1/receive`. Welche Antwort kommt zurück, und warum? Überlege danach: Welche Labels hätte eine Serie, die ein Sender ohne `THANOS-TENANT` erfolgreich schreibt?
]

#gelernt(
  [Thanos Receive nimmt Remote Write von beliebig vielen Sendern an und trennt sie über den Header `THANOS-TENANT` in Mandanten.],
  [Ein Hashring mit einem Eintrag macht Receive zum Router und Ingestor zugleich und lässt Raum für mehr Replikas.],
  [Thanos Query verbindet frische Daten aus Receive mit alten aus S3 und entfernt Kopien über die Replika-Labels.],
  [Ein Label am PrometheusRule entscheidet, ob Prometheus lokal oder der Thanos Ruler global auswertet.],
  [`thanos tools bucket inspect` zeigt, welche Blöcke wirklich in S3 liegen.],
)

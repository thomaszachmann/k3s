#import "../lib.typ": *

#kapitel(
  [Traces mit Tempo und OpenTelemetry],
  ziel: [Eine Demo-App in `app1` schickt Traces über Alloy an Tempo auf `obs`. Du findest sie mit TraceQL, siehst den Service-Graphen und springst zwischen Logs, Traces und Metriken hin und her.],
  zeit: [90 Minuten],
  braucht: [Kapitel 8],
)

== Was du aufbaust

Ein *Trace* ist der Weg einer einzelnen Anfrage durch deine Dienste. Er besteht aus *Spans*. Jeder Span ist ein Arbeitsschritt mit Start, Dauer, Status und Attributen, etwa ein HTTP-Aufruf oder eine Datenbankabfrage. Alle Spans eines Traces teilen sich dieselbe Trace-ID. Steht diese ID auch im Log, kommst du vom Log zum Trace.

#tabelle(
  (auto, auto, 1fr),
  ([Komponente], [Wo], [Aufgabe]),
  [HotROD], [`app1`, Namespace `demo`], [Demo-App aus dem Jaeger-Projekt, erzeugt Traces per OpenTelemetry],
  [Alloy (`traces.alloy`)], [alle drei], [Nimmt OTLP an, ergänzt Kubernetes-Daten und `cluster`, schickt an Tempo],
  [Tempo], [`obs`], [Speichert Traces im Bucket `tempo`, ein Mandant pro Cluster],
  [Metrics-Generator], [`obs`, in Tempo], [Erzeugt aus Spans Metriken und schreibt sie an Thanos Receive],
  [Grafana], [`obs`], [Datenquelle Tempo mit Sprüngen zu Loki und Thanos],
)

Anwendungen schicken ihre Spans nie direkt an die Zentrale, sondern an das Alloy im eigenen Cluster. Die App kennt damit nur einen Namen im Cluster und keine Zugangsdaten. Alloy ergänzt, was die App nicht weiß, etwa Namespace und Cluster, und kümmert sich um TLS, Basic Auth und Wiederholungen.

== Tempo auf obs installieren

Bucket `tempo` und Secret `tempo-s3` stammen aus Kapitel 3.

#datei("observability/central/tempo/values.yaml (Ausschnitt)", ```yaml
tempo:
  multitenancyEnabled: true
  retention: 168h
  storage:
    trace:
      backend: s3
      s3:
        bucket: tempo
        endpoint: s3.monitoring.svc.cluster.local:8333
        access_key: ${AWS_ACCESS_KEY_ID}
        secret_key: ${AWS_SECRET_ACCESS_KEY}
        insecure: true
        forcepathstyle: true
  queryFrontend:
    multi_tenant_queries_enabled: true
  metricsGenerator:
    enabled: true
    processor:
      service_graphs:
        dimensions: [cluster]
      span_metrics:
        dimensions: [cluster]
    storage:
      path: /var/tempo/generator/wal
      remote_write:
        - url: http://thanos-receive.monitoring.svc:19291/api/v1/receive
          send_exemplars: true
          headers:
            THANOS-TENANT: obs
  overrides:
    defaults:
      metrics_generator:
        processors: [service-graphs, span-metrics]
  extraArgs:
    config.expand-env: "true"
  extraEnvFrom:
    - secretRef:
        name: tempo-s3
```, erklaerung: [
  `multitenancyEnabled` verlangt wie bei Loki den Header `X-Scope-OrgID`. Anders als bei Loki musst du `config.expand-env` selbst setzen, sonst stünde `${AWS_ACCESS_KEY_ID}` wörtlich in der Konfiguration. Der Endpunkt steht ohne `http://`, `insecure: true` regelt das Protokoll. Den Metrics-Generator schaltest du an zwei Stellen ein: unter `metricsGenerator` die Konfiguration, unter `overrides` die Prozessoren für alle Mandanten.
])

#warum[
  Der Metrics-Generator schreibt als Mandant `obs` an Thanos Receive, nicht als `app1` oder `app2`. Er läuft auf `obs`, und Tempo könnte den Mandanten nur im Header `X-Scope-OrgID` weitergeben. Thanos Receive liest aber `THANOS-TENANT`. Die Herkunft geht trotzdem nicht verloren: Über `dimensions: [cluster]` wird das Span-Attribut `cluster` zum Label jeder erzeugten Serie.
]

#cmd("Mac")[```bash
helm --kube-context obs upgrade --install tempo grafana-community/tempo \
  -n monitoring --version 3.2.1 \
  -f observability/central/tempo/values.yaml --wait --timeout 10m
```][Installiert Tempo als StatefulSet `tempo` mit einem Pod. Verteiler, Speicher, Abfrage und Metrics-Generator laufen in diesem einen Prozess.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring logs tempo-0 --tail=30 \
  | grep -iE 'level=(error|warn)'
```][Zeigt nur Warnungen und Fehler der letzten 30 Zeilen.]

#pruefe[
  Keine Ausgabe. `AccessDenied` weist auf das S3-Konto hin. Fehler mit `remote_write` und `connection refused` bedeuten, dass Thanos Receive nicht erreichbar ist. Das prüfst du in Kapitel 4 nach.
]

== Alloy nimmt Traces an

`traces.alloy` baut eine Kette aus fünf Gliedern: annehmen, Kubernetes-Daten ergänzen, `cluster` setzen, bündeln, senden.

#datei("observability/cluster/alloy/traces.alloy (Ausschnitt)", ```hcl
otelcol.receiver.otlp "traces_in" {
  grpc {
    endpoint = "0.0.0.0:4317"
  }
  http {
    endpoint = "0.0.0.0:4318"
  }
  output {
    traces = [otelcol.processor.k8sattributes.traces_k8s.input]
  }
}

otelcol.processor.k8sattributes "traces_k8s" {
  extract {
    metadata = ["k8s.namespace.name", "k8s.pod.name",
                "k8s.deployment.name"]
  }
  pod_association {
    source {
      from = "connection"
    }
  }
  output {
    traces = [otelcol.processor.transform.traces_cluster.input]
  }
}

otelcol.processor.transform "traces_cluster" {
  trace_statements {
    context    = "resource"
    statements = [
      string.format(`set(attributes["cluster"], "%s")`,
                    sys.env("CLUSTER_NAME")),
    ]
  }
  output {
    traces = [otelcol.processor.batch.traces_batch.input]
  }
}

// otelcol.processor.batch "traces_batch" -> traces_tempo

otelcol.exporter.otlphttp "traces_tempo" {
  client {
    endpoint = "https://tempo.obs.internal"
    auth     = otelcol.auth.basic.traces_obs.handler
    headers  = { "X-Scope-OrgID" = sys.env("CLUSTER_NAME") }
    tls {
      ca_file = "/etc/obs-ca/ca.crt"
    }
  }
}
```, erklaerung: [
  `k8sattributes` erkennt den sendenden Pod an seiner IP-Adresse und hängt Namespace, Pod und Deployment an. Genau diese Attribute braucht Grafana später, um zu einem Span die passenden Logs zu finden. `transform` setzt das Ressourcen-Attribut `cluster`. Der Exporter schickt OTLP über HTTPS an Traefik, `otelcol.auth.basic` liefert Benutzer und Passwort aus `obs-remote-auth`. Die nötigen Leserechte für Pods und Namespaces bringt das Alloy-Chart schon mit.
])

#falle[
  `k8sattributes` muss direkt hinter dem Empfänger stehen. Hinter `batch` ist die IP-Adresse des Absenders verloren, weil Spans verschiedener Pods dann gemischt in einem Paket liegen. Die Spans kommen trotzdem an, nur ohne Namespace und Pod. Der Sprung zu den Logs findet dann nichts.
]

Die Ports 4317 und 4318 hat der Alloy-Service seit Kapitel 5. Jetzt kommt `traces.alloy` in die ConfigMap, auf dieselbe Weise wie in Kapitel 8:

#cmd("Mac")[```bash
for c in app1 app2; do
  kubectl --context $c -n monitoring create configmap alloy-config \
    --from-file=observability/cluster/alloy/metrics.alloy \
    --from-file=observability/cluster/alloy/logs.alloy \
    --from-file=observability/cluster/alloy/traces.alloy \
    --dry-run=client -o yaml | kubectl --context $c apply -f -
  kubectl --context $c -n monitoring rollout restart ds/alloy
  kubectl --context $c -n monitoring rollout status ds/alloy
done
```][In den App-Clustern liegen jetzt alle drei Dateien in der ConfigMap.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring create configmap alloy-config \
  --from-file=observability/cluster/alloy/logs.alloy \
  --from-file=observability/cluster/alloy/traces.alloy \
  --dry-run=client -o yaml | kubectl --context obs apply -f -
kubectl --context obs -n monitoring rollout restart ds/alloy
kubectl --context obs -n monitoring rollout status ds/alloy
```][Auf `obs` ohne `metrics.alloy`, wie gehabt.]

#cmd("Mac")[```bash
kubectl --context app1 -n monitoring logs ds/alloy -c alloy --tail=50 \
  | grep -E 'traces_|level=error'
```][Prüft, ob die neuen Komponenten ohne Fehler laufen.]

#pruefe[
  Meldungen mit `traces_` im Namen, etwa zum Start des Empfängers auf `0.0.0.0:4317` und `0.0.0.0:4318`, aber keine Zeilen mit `level=error`. Ein Tippfehler in der Datei erscheint hier mit Zeilennummer, und Alloy behält dann die alte Konfiguration.
]

== Die Demo-App

HotROD ist eine kleine Fahrdienst-App aus dem Jaeger-Projekt. Ein Aufruf von `/dispatch` geht durch die Dienste `frontend`, `customer`, `driver` und `route`, dazu kommen simulierte Aufrufe an MySQL und Redis. Einige Redis-Aufrufe enden absichtlich mit einem Fehler, die MySQL-Abfrage dauert absichtlich rund 300 ms. Alle vier Dienste laufen in einem Pod.

#datei("observability/demo/hotrod.yaml (Ausschnitt)", ```yaml
      containers:
        - name: hotrod
          image: jaegertracing/example-hotrod:2.22.0
          args: ["all"]
          env:
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: http://alloy.monitoring.svc.cluster.local:4318
```, erklaerung: [
  `all` startet alle Dienste in einem Prozess. `OTEL_EXPORTER_OTLP_ENDPOINT` ist die Standard-Variable des OpenTelemetry-SDK. HotROD hängt `/v1/traces` selbst an und schickt unverschlüsselt, weil die Adresse mit `http://` beginnt. Das ist in Ordnung, denn die Verbindung bleibt im Cluster. Die Datei legt außerdem den Namespace `demo` und einen Service an.
])

HotROD erzeugt nur Traces, wenn jemand eine Fahrt bestellt. Das übernimmt ein kleiner Lastgenerator in `observability/demo/last.yaml`. Er ruft alle drei Sekunden `/dispatch` für einen der vier Kunden auf.

#cmd("Mac")[```bash
kubectl --context app1 apply -f observability/demo/
```][Legt Namespace, HotROD und den Lastgenerator an.]

#cmd("Mac")[```bash
kubectl --context app1 -n demo rollout status deploy/hotrod
```][Wartet, bis HotROD bereit ist.]

#cmd("Mac")[```bash
kubectl --context app1 -n demo logs deploy/hotrod --tail=5
```][Zeigt die letzten Log-Zeilen von HotROD.]

#pruefe[
  Zeilen wie `HTTP request received` oder `Search successful`. Am Ende jeder Zeile steht ein JSON-Block, der unter anderem `"trace_id"` und `"span_id"` enthält. Diese IDs nutzt du später für den Sprung vom Log zum Trace.
]

#aufgabe[
  Leite HotROD auf den Mac um, mit `kubectl --context app1 -n demo port-forward svc/hotrod 8080:8080`, und öffne #link("http://localhost:8080"). Klicke ein paarmal schnell hintereinander auf einen Kunden. Was fällt dir an den angezeigten Zeiten auf? Die Erklärung findest du gleich im Trace.
]

== Traces in Grafana

#datei("observability/grafana/datasources/tempo.yaml (Ausschnitt)", ```yaml
      - name: Tempo
        uid: tempo
        type: tempo
        url: http://tempo.monitoring.svc:3200
        jsonData:
          httpHeaderName1: X-Scope-OrgID
          tracesToLogsV2:
            datasourceUid: loki
            filterByTraceID: true
            tags:
              - {key: cluster, value: cluster}
              - {key: k8s.namespace.name, value: namespace}
              - {key: k8s.pod.name, value: pod}
          serviceMap:
            datasourceUid: thanos
          nodeGraph:
            enabled: true
        secureJsonData:
          httpHeaderValue1: obs|app1|app2
```, erklaerung: [
  Auch hier fragt Grafana alle Mandanten zugleich ab. `tracesToLogsV2` übersetzt Attribute eines Spans in Loki-Labels: Aus `k8s.namespace.name` wird `namespace`, aus `k8s.pod.name` wird `pod`. `serviceMap` sagt Grafana, wo die Metriken für den Service-Graphen liegen. Die vollständige Datei enthält zusätzlich einen Sprung zu den Span-Metriken.
])

#cmd("Mac")[```bash
kubectl --context obs apply -f observability/grafana/datasources/tempo.yaml
```][Der Sidecar lädt die Datenquelle nach.]

Öffne *Explore*, wähle *Tempo*, stelle den Abfragetyp auf *TraceQL* und gib ein:

```traceql
{ resource.cluster = "app1" && resource.service.name = "frontend" }
```

#pruefe[
  Eine Liste von Traces, deren Wurzel-Span `/dispatch` heißt, etwa alle drei Sekunden einer. Ein Klick öffnet den Wasserfall. Ganz oben steht `frontend`, darunter `customer` mit dem langen MySQL-Span, dann `driver` mit vielen kurzen Redis-Spans und mehrere parallele `route`-Aufrufe. Unter *Resource attributes* eines Spans stehen `cluster`, `k8s.namespace.name` und `k8s.pod.name`.
]

#falle[
  Erscheint nichts, geh die Kette von vorn nach hinten durch: HotROD-Log auf Verbindungsfehler zu `alloy.monitoring.svc`, dann das Alloy-Log auf `401` oder `x509`, dann das Tempo-Log. Erst nach etwa einer Minute sind neue Traces in der Suche sichtbar.
]

== TraceQL-Grundlagen

TraceQL sucht nach Spans und gibt die Traces zurück, zu denen sie gehören. Eine Abfrage steht in geschweiften Klammern. Attribute haben einen Bereich als Präfix: `resource.` für Attribute des Dienstes, `span.` für Attribute des einzelnen Spans. Dazu kommen eingebaute Felder wie `name`, `duration` und `status`.

Langsame Abfragen beim Dienst `customer`:

```traceql
{ resource.service.name = "customer" && duration > 250ms }
```

Alle Spans mit Fehler, in allen Clustern:

```traceql
{ status = error }
```

Traces, in denen unter `frontend` irgendwo ein Redis-Fehler auftritt. Der Operator `>>` heißt „ist Nachfahre von“:

```traceql
{ resource.service.name = "frontend" }
  >> { resource.service.name = "redis-manual" && status = error }
```

Traces aus dem Namespace `demo` mit besonders vielen Spans:

```traceql
{ resource.k8s.namespace.name = "demo" } | count() > 20
```

#warum[
  Mit TraceQL fragst du nach Mustern, nicht nach einzelnen IDs. „Zeig mir alle Anfragen, bei denen Redis ausfiel und die trotzdem schnell waren“ wäre mit Logs allein eine mühsame Suche. Hier ist es eine Zeile.
]

== Service-Graph und Span-Metriken

Der Metrics-Generator wertet jede ankommende Span aus und schreibt zwei Arten von Metriken an Thanos Receive:

#tabelle(
  (auto, 1fr),
  ([Metrik], [Inhalt]),
  [`traces_spanmetrics_calls_total`], [Anzahl der Spans je Dienst, Span-Name und Status],
  [`traces_spanmetrics_latency_bucket`], [Histogramm der Span-Dauer, mit Exemplars],
  [`traces_service_graph_request_total`], [Aufrufe von Dienst A nach Dienst B],
  [`traces_service_graph_request_failed_total`], [davon fehlgeschlagen],
)

Wähle in *Explore* die Datenquelle *Thanos* und frage ab:

```promql
sum by (cluster, service) (rate(traces_spanmetrics_calls_total[5m]))
```

#pruefe[
  Je eine Serie für `frontend`, `customer`, `driver`, `route` und `redis-manual`, alle mit `cluster="app1"` und zusätzlich `tenant_id="obs"`. Kommen keine Serien an, prüfe das Tempo-Log auf Fehler beim Schreiben an Thanos Receive.
]

Wechsle zurück zur Datenquelle *Tempo* und wähle den Abfragetyp *Service Graph*.

#pruefe[
  Ein Graph mit den Diensten als Knoten und Pfeilen von `frontend` zu `customer`, `driver` und `route`. Ein Klick auf einen Knoten zeigt Anfragerate, Fehlerrate und Dauer. Datenbanken wie MySQL erscheinen je nach Attributen als eigener Knoten oder gar nicht.
]

== Von der Metrik zum Trace: Exemplars

Ein *Exemplar* ist eine einzelne Messung, an der eine Trace-ID hängt. Der Metrics-Generator speichert zu jedem Bucket des Latenz-Histogramms einige Beispiele unter dem Label `traceID`. Thanos Receive bewahrt sie auf, und die Datenquelle Thanos verweist für dieses Label auf Tempo. Beides ist seit Kapitel 4 und 6 vorbereitet.

```promql
histogram_quantile(0.95, sum by (le, service) (
  rate(traces_spanmetrics_latency_bucket{cluster="app1"}[5m])
))
```

Schalte unter der Abfrage den Schalter *Exemplars* ein.

#pruefe[
  Im Diagramm erscheinen kleine Rauten über den Linien. Fährst du mit der Maus darüber, zeigt Grafana die `traceID` und einen Knopf, der den Trace in Tempo öffnet. So kommst du von „das 95. Perzentil steigt“ direkt zu einer Anfrage, die langsam war.
]

== Von Logs zu Traces und zurück

Die Datenquelle Loki aus Kapitel 8 erkennt `trace_id` im Log-Text. HotROD schreibt bei jedem Redis-Fehler eine Zeile `redis timeout` mit der Trace-ID:

```logql
{cluster="app1", namespace="demo"} |= "redis timeout"
```

Klappe eine Zeile auf. Unter *Links* steht *Trace in Tempo öffnen*. Ein Klick öffnet den Trace in einer geteilten Ansicht neben den Logs. Dort findest du den fehlerhaften Redis-Span rot markiert.

Der Weg zurück: Klicke im Trace auf einen Span von `driver` und dann auf das Log-Symbol. Grafana baut daraus eine Loki-Abfrage mit `cluster`, `namespace` und `pod` und filtert auf die Trace-ID.

#pruefe[
  Im rechten Bereich erscheinen genau die Log-Zeilen dieser einen Anfrage, nicht alle Logs des Pods. Erscheint die Meldung, dass Labels fehlen, fehlen dem Span die Attribute aus `k8sattributes`. Prüfe dann die Reihenfolge in `traces.alloy`.
]

#aufgabe[
  Erzeuge gleichzeitige Anfragen mit `kubectl --context app1 -n demo scale deploy/hotrod-last --replicas=5`. Beobachte im Exemplar-Diagramm, wie sich die Latenz von `customer` verändert, und öffne über eine Raute einen langsamen Trace. Wo wartet die Anfrage? Tipp: Vergleiche die Startzeit des MySQL-Spans mit der seines Eltern-Spans. Skaliere danach zurück auf `1`.
]

#gelernt(
  [Ein Trace zeigt den Weg einer Anfrage, ein Span einen Schritt darin. Die Trace-ID verbindet beides mit den Logs.],
  [Anwendungen schicken OTLP an das Alloy im eigenen Cluster. Alloy ergänzt Kubernetes-Daten und `cluster` und schickt als Mandant an Tempo.],
  [TraceQL sucht nach Mustern über Attribute, Dauer, Status und die Struktur eines Traces.],
  [Der Metrics-Generator macht aus Spans Metriken für Service-Graph und Exemplars und schreibt sie als Mandant `obs` an Thanos.],
  [Grafana springt von Metrik zu Trace, von Log zu Trace und von Trace zu Log, wenn die Attribute zusammenpassen.],
)

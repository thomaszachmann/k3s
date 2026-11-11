#import "../lib.typ": *

#kapitel(
  [Logs mit Loki und Alloy],
  ziel: [Die Logs aller Pods und die Kubernetes-Events aus allen drei Clustern landen in Loki auf `obs`. Du fragst sie mit LogQL ab, und ein Log-Alarm erreicht den zentralen Alertmanager.],
  zeit: [90 Minuten],
  braucht: [Kapitel 3, 5, 6 und 7],
)

== Was du aufbaust

Metriken sagen dir, dass ein Pod neu startet. Warum er neu startet, steht im Log. Bisher liegen diese Logs nur auf dem jeweiligen Node, und nach einem Neustart des Pods sind sie weg. Jetzt sammelst du sie zentral.

#tabelle(
  (auto, auto, 1fr),
  ([Komponente], [Wo], [Aufgabe]),
  [Loki], [`obs`], [Speichert Logs im Bucket `loki`, ein Mandant pro Cluster],
  [Alloy (`logs.alloy`)], [alle drei], [Liest Pod-Logs und Events über die Kubernetes-API, schickt sie an Loki],
  [Loki-Ruler], [`obs`], [Wertet LogQL-Regeln aus, schickt Alarme an den Alertmanager],
  [Grafana], [`obs`], [Datenquelle Loki, fragt alle Mandanten zugleich ab],
)

Loki unterscheidet sich in einem Punkt grundlegend von einer Volltextsuche: Es indiziert nur die *Labels* eines Log-Streams, nicht den Text. Ein Stream ist die Menge aller Zeilen mit genau derselben Label-Kombination. Bei einer Abfrage wählt Loki zuerst die Streams über ihre Labels aus und durchsucht dann nur deren Zeilen. Das macht Loki billig im Betrieb, verlangt aber Disziplin bei den Labels.

== Wenige, stabile Labels

Jede neue Label-Kombination erzeugt einen neuen Stream. Für jeden Stream hält Loki eigene Puffer im Speicher und schreibt eigene kleine Blöcke ins S3. Ein Label wie `user_id` oder `trace_id` würde aus einem Stream Tausende machen. Dieses Buch setzt deshalb genau fünf Labels:

#tabelle(
  (auto, 1fr, auto),
  ([Label], [Herkunft], [Werte im Labor]),
  [`cluster`], [Umgebungsvariable `CLUSTER_NAME` in Alloy], [3],
  [`namespace`], [Namespace des Pods], [rund 5 pro Cluster],
  [`pod`], [Name des Pods], [rund 20 pro Cluster],
  [`container`], [Name des Containers], [meist 1 bis 2 pro Pod],
  [`app`], [Pod-Label `app.kubernetes.io/name`, sonst `app`], [rund 15],
)

`pod` ist das einzige Label mit spürbarer Veränderung, weil jeder neue Pod einen neuen Namen bekommt. Das ist gewollt, denn nach dem Pod suchst du am häufigsten. Alles andere bleibt im Text der Zeile.

In Grafana wirst du drei weitere Labels sehen, die du nicht selbst gesetzt hast. `job` und `instance` hängt Alloy an: `job` ist für alle Pod-Logs gleich, `instance` ist `namespace/pod:container`. `service_name` leitet Loki selbst aus `app` ab. Keines davon erzeugt neue Streams, denn ihr Wert ergibt sich aus den fünf Labels oben.

Die Logstufe, also `info` oder `error`, legt Alloy als *strukturierte Metadaten* mit dem Namen `level` ab. Sie hängen an der einzelnen Zeile, erzeugen keinen neuen Stream und lassen sich trotzdem filtern. Loki rät die Stufe zusätzlich selbst und legt sie als `detected_level` daneben. Meist sind beide gleich. `level` stammt aus deiner Regel in Alloy und ist deshalb der verlässlichere Wert.

#warum[
  Zu viele Streams sind der häufigste Grund, warum Loki langsam wird oder Daten ablehnt. Die Werte-Datei unten begrenzt deshalb jeden Mandanten auf 5000 Streams. Bei Verstoß antwortet Loki mit HTTP 429, und Alloy meldet das im Log. Ein solcher Fehler zeigt fast immer ein falsch gewähltes Label an, kein zu kleines Limit.
]

== Loki auf obs installieren

Bucket `loki` und Secret `loki-s3` hast du in Kapitel 3 angelegt. Die Werte-Datei folgt dem Muster der anderen Komponenten: ein Prozess, S3 als Speicher, keine Caches.

#datei("observability/central/loki/values.yaml (Ausschnitt)", ```yaml
deploymentMode: Monolithic

loki:
  auth_enabled: true
  commonConfig:
    replication_factor: 1
  storage:
    type: s3
    s3:
      endpoint: http://s3.monitoring.svc.cluster.local:8333
      accessKeyId: ${AWS_ACCESS_KEY_ID}
      secretAccessKey: ${AWS_SECRET_ACCESS_KEY}
      s3ForcePathStyle: true
  querier:
    multi_tenant_queries_enabled: true
  limits_config:
    retention_period: 168h
    max_global_streams_per_user: 5000
  rulerConfig:
    alertmanager_url: http://alertmanager-operated.monitoring.svc:9093
    # ... Regeln lokal unter /rules, siehe Abschnitt Log-Alarme

singleBinary:
  replicas: 1
  extraEnvFrom:
    - secretRef:
        name: loki-s3
```, erklaerung: [
  `auth_enabled: true` schaltet die Mandanten ein. Jede Anfrage braucht dann den Header `X-Scope-OrgID`, sonst lehnt Loki sie ab. `multi_tenant_queries_enabled` erlaubt Abfragen mit mehreren Mandanten, getrennt durch `|`. Die S3-Schlüssel setzt Loki beim Start aus den Umgebungsvariablen ein, das Chart startet Loki dafür mit `-config.expand-env=true`. Die vollständige Datei schaltet außerdem Gateway, Caches und Canary ab, legt das Schema `v13` fest und konfiguriert den Compactor.
])

Die Helm-Charts für Loki und Tempo pflegt inzwischen die Community in einem eigenen Repository, nicht mehr Grafana Labs im Repository `grafana`, aus dem Alloy stammt. Trag es einmal ein:

#cmd("Mac")[```bash
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update grafana-community
```][Ohne diesen Schritt meldet der nächste Befehl `repo grafana-community not found`.]

#cmd("Mac")[```bash
helm --kube-context obs upgrade --install loki grafana-community/loki \
  -n monitoring --version 21.0.0 \
  -f observability/central/loki/values.yaml --wait --timeout 10m
```][Installiert Loki als StatefulSet `loki` mit einem Pod. Im Pod läuft neben Loki ein zweiter Container, der Regeln aus ConfigMaps einsammelt. Den brauchst du für die Alarme.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring logs loki-0 -c loki --tail=30
```][Zeigt die letzten Zeilen des Loki-Containers.]

#pruefe[
  In den ersten Sekunden nach dem Start meldet Loki `failed to fast-join the memberlist cluster` und `empty ring`. Loki sucht dabei sich selbst über einen DNS-Namen, den Kubernetes erst vergibt, wenn der Pod bereit ist. Das legt sich von allein. Danach kommen keine Zeilen mit `level=error` mehr. Meldungen wie `AccessDenied` oder `NoSuchBucket` weisen auf Konto oder Bucket aus Kapitel 3 hin. Hinweise des Rulers auf fehlende Regeln sind bis zum Abschnitt über Alarme normal, der Ordner `/rules` ist noch leer.
]

Jetzt prüfst du die Mandanten. Öffne dafür ein zweites Terminal:

#cmd("Mac")[```bash
kubectl --context obs -n monitoring port-forward svc/loki 3100:3100
```][Macht Loki unter `localhost:3100` erreichbar, bis du mit `Ctrl-C` beendest.]

#cmd("Mac")[```bash
curl -s localhost:3100/loki/api/v1/labels
```][Eine Anfrage ohne Mandant. Erwartet ist die Antwort `no org id`: Loki verweigert Anfragen ohne Header.]

#cmd("Mac")[```bash
curl -s -H "X-Scope-OrgID: obs" localhost:3100/loki/api/v1/labels
```][Dieselbe Anfrage für den Mandanten `obs`. Jetzt kommt `{"status":"success"}` zurück, noch ohne Labels, denn Alloy schreibt erst ab dem nächsten Abschnitt.]

== Alloy schickt die Logs

Alloy liest die Logs nicht aus Dateien auf dem Node, sondern über die Kubernetes-API, genau wie `kubectl logs`. Dafür braucht Alloy keine Root-Rechte und keinen Zugriff auf Dateien des Nodes. Den Mount von `/var/log` aus der Werte-Datei von Kapitel 5 nutzt `logs.alloy` nicht. Für Ein-Node-Cluster wie im Labor ist das die einfachste Lösung. Bei großen Clustern mit viel Log-Volumen belastet dieser Weg den API-Server, dort liest man besser die Dateien unter `/var/log/pods`.

#datei("observability/cluster/alloy/logs.alloy (Ausschnitt)", ```hcl
discovery.kubernetes "logs_pods" {
  role = "pod"
  // ... nur Pods auf dem eigenen Node
}

discovery.relabel "logs_pods" {
  targets = discovery.kubernetes.logs_pods.targets
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  // ... ebenso pod, container und app
}

loki.source.kubernetes "logs_pods" {
  targets    = discovery.relabel.logs_pods.output
  forward_to = [loki.process.logs_pods.receiver]
}

loki.process "logs_pods" {
  // ... zieht level aus der Zeile, legt es als Metadaten ab
  forward_to = [loki.write.logs_loki.receiver]
}

loki.source.kubernetes_events "logs_events" {
  job_name   = "kubernetes-events"
  log_format = "logfmt"
  forward_to = [loki.write.logs_loki.receiver]
}

loki.write "logs_loki" {
  endpoint {
    url       = "https://loki.obs.internal/loki/api/v1/push"
    tenant_id = sys.env("CLUSTER_NAME")
    basic_auth {
      username = sys.env("OBS_USER")
      password = sys.env("OBS_PASSWORD")
    }
    tls_config {
      ca_file = "/etc/obs-ca/ca.crt"
    }
  }
  external_labels = { cluster = sys.env("CLUSTER_NAME") }
}
```, erklaerung: [
  Lies die Kette von oben nach unten: Pods finden, Labels setzen, Logs lesen, Logstufe herausziehen, schreiben. `tenant_id` setzt den Header `X-Scope-OrgID` auf den Clusternamen, `external_labels` hängt an jeden Stream das Label `cluster`. Die Events laufen ohne Umweg direkt zu `loki.write`. Alle Namen beginnen mit `logs_`, damit sie sich nicht mit `metrics.alloy` aus Kapitel 5 überschneiden. Die vollständige Datei liest außerdem nur Pods auf dem eigenen Node und verwirft beendete Pods.
])

Auch `obs` schickt über `https://loki.obs.internal` und nicht direkt an den Service. So ist `logs.alloy` in allen drei Clustern identisch, und der Weg über Traefik wird bei jedem Cluster gleich geprüft.

Wie in Kapitel 5 liegen alle `.alloy`-Dateien eines Clusters in der ConfigMap `alloy-config`, und Alloy lädt sie gemeinsam. In `app1` und `app2` kommt `logs.alloy` zu `metrics.alloy` dazu:

#cmd("Mac")[```bash
kubectl --context app1 -n monitoring create configmap alloy-config \
  --from-file=observability/cluster/alloy/metrics.alloy \
  --from-file=observability/cluster/alloy/logs.alloy \
  --dry-run=client -o yaml | kubectl --context app1 apply -f -
kubectl --context app1 -n monitoring rollout restart ds/alloy
kubectl --context app1 -n monitoring rollout status ds/alloy
```][Baut die ConfigMap für app1 lokal neu, ersetzt die alte, startet Alloy neu und wartet, bis der Pod wieder läuft. Von selbst bemerkt Alloy die Änderung auch, aber erst nach bis zu einer Minute.]

#cmd("Mac")[```bash
kubectl --context app2 -n monitoring create configmap alloy-config \
  --from-file=observability/cluster/alloy/metrics.alloy \
  --from-file=observability/cluster/alloy/logs.alloy \
  --dry-run=client -o yaml | kubectl --context app2 apply -f -
kubectl --context app2 -n monitoring rollout restart ds/alloy
kubectl --context app2 -n monitoring rollout status ds/alloy
```][Dasselbe für app2.]

Auf `obs` läuft Alloy noch gar nicht, denn Metriken sammelt dort Prometheus. Die Voraussetzungen sind aber da: das Secret `obs-remote-auth` mit dem Benutzer `obs` aus Kapitel 5 und die ConfigMap `obs-ca` aus Kapitel 2.

#cmd("Mac")[```bash
kubectl --context obs -n monitoring create configmap alloy-config \
  --from-file=observability/cluster/alloy/logs.alloy \
  --dry-run=client -o yaml | kubectl --context obs apply -f -
```][Auf `obs` enthält die ConfigMap nur `logs.alloy`, ohne `metrics.alloy`.]

#cmd("Mac")[```bash
helm --kube-context obs upgrade --install alloy grafana/alloy \
  -n monitoring --version 1.15.0 \
  -f observability/cluster/alloy/values.yaml --wait
```][Dieselbe Werte-Datei wie in den App-Clustern. Was Alloy tut, bestimmen allein die Dateien in der ConfigMap.]

#cmd("Mac")[```bash
kubectl --context app1 -n monitoring logs ds/alloy -c alloy --tail=50 \
  | grep -E 'logs_|level=error'
```][Filtert die Meldungen der neuen Komponenten und alle Fehler.]

#pruefe[
  Meldungen mit `component_id=loki.source.kubernetes.logs_pods` oder `loki.write.logs_loki`, aber keine Zeilen mit `level=error`. `server returned HTTP status 401` heißt, die Basic-Auth-Daten passen nicht. `x509: certificate signed by unknown authority` heißt, die ConfigMap `obs-ca` fehlt oder ist nicht eingebunden.
]

#cmd("Mac")[```bash
curl -s -H "X-Scope-OrgID: obs"  localhost:3100/loki/api/v1/label/cluster/values
curl -s -H "X-Scope-OrgID: app1" localhost:3100/loki/api/v1/label/cluster/values
curl -s -H "X-Scope-OrgID: app2" localhost:3100/loki/api/v1/label/cluster/values
```][Fragt für jeden Mandanten die Werte des Labels `cluster` ab. Der Port-Forward aus dem zweiten Terminal muss noch laufen.]

#pruefe[
  Drei Zeilen, jede mit genau ihrem eigenen Clusternamen:
  ```
  {"status":"success","data":["obs"]}
  {"status":"success","data":["app1"]}
  {"status":"success","data":["app2"]}
  ```
  Jeder Mandant sieht nur seine eigenen Daten. Zum Vergleich: Mit `-H "X-Scope-OrgID: obs|app1|app2"` bekommst du alle drei Werte in einer Antwort.
]

#falle[
  Den Header `X-Scope-OrgID` setzt der Absender selbst. Mit den Zugangsdaten von `app1` könnte jemand also auch als `app2` schreiben. Basic Auth schützt vor Fremden, nicht vor einem falsch konfigurierten eigenen Cluster. Wie man den Mandanten fest an den Benutzer bindet, zeigt Kapitel 13.
]

== Logs in Grafana

Die Datenquelle legst du wie in Kapitel 6 als ConfigMap ab:

#datei("observability/grafana/datasources/loki.yaml (Ausschnitt)", ```yaml
      - name: Loki
        uid: loki
        type: loki
        url: http://loki.monitoring.svc:3100
        jsonData:
          httpHeaderName1: X-Scope-OrgID
          derivedFields:
            - name: TraceID
              matcherType: regex
              matcherRegex: 'trace_?id"?[=:]\s*"?(\w+)'
              datasourceUid: tempo
              url: '$${__value.raw}'
        secureJsonData:
          httpHeaderValue1: obs|app1|app2
```, erklaerung: [
  Grafana schickt bei jeder Abfrage den Header `X-Scope-OrgID: obs|app1|app2` und sieht damit alle drei Mandanten. Das Feld `derivedFields` macht aus einer Trace-ID im Log-Text einen Link zu Tempo. Er funktioniert ab Kapitel 9. In Provisioning-Dateien ersetzt Grafana `$NAME` durch Umgebungsvariablen, deshalb steht dort `$$` für ein einzelnes Dollarzeichen.
])

#cmd("Mac")[```bash
kubectl --context obs apply -f observability/grafana/datasources/loki.yaml
```][Der Sidecar von Grafana bemerkt die ConfigMap und lädt die Datenquelle nach, ohne Neustart.]

Öffne #link("https://grafana.obs.internal")[grafana.obs.internal], dann *Explore*, wähle *Loki* und gib ein:

```logql
{cluster="app1", namespace="kube-system"}
```

#bild("bilder/08-grafana-loki-explore.png", [*Explore* mit der Datenquelle *Loki*: oben die Menge der Zeilen über die Zeit, darunter die Zeilen selbst. Die Warnung von CoreDNS über fehlende `*.override`-Dateien ist harmlos, k3s sucht diese Dateien immer.])

#pruefe[
  Log-Zeilen von CoreDNS, Traefik und dem Metrics-Server aus `app1`. Klappst du eine Zeile auf, stehen darunter die Labels und die strukturierten Metadaten `level` und `detected_level`. Zusätzlich zeigt Grafana das Label `__tenant_id__`. Loki fügt es bei Abfragen über mehrere Mandanten hinzu.
]

Über *Label browser* über dem Eingabefeld klickst du dir Abfragen zusammen, ohne die Labels auswendig zu kennen. Schalte für LogQL wie bei PromQL auf *Code*.

== LogQL in vier Schritten

LogQL baut auf denselben Ideen auf wie PromQL. Eine Abfrage beginnt immer mit einem Stream-Selektor in geschweiften Klammern. Danach folgen, durch `|` getrennt, Filter und Verarbeitungsschritte.

*1. Streams wählen.* Mindestens ein Label muss genau passen oder ein nicht leeres Muster haben:

```logql
{namespace="monitoring", app=~"alloy|loki"}
```

*2. Zeilen filtern.* `|=` sucht Text, `!=` schließt aus, `|~` nimmt einen regulären Ausdruck. Filter sind schnell, weil Loki dafür nichts zerlegen muss:

```logql
{cluster="app1"} |~ "(?i)error|timeout" != "level=debug"
```

*3. Zeilen zerlegen.* `| logfmt` und `| json` machen aus Feldern im Text vorübergehende Labels, nach denen du filtern kannst:

```logql
{namespace="monitoring", app="alloy"} | logfmt | level="error"
```

Auf strukturierte Metadaten filterst du ohne Parser, weil sie schon da sind:

```logql
{cluster=~"app1|app2"} | level="error"
```

*4. Zählen statt lesen.* Mit `count_over_time` und `rate` wird aus Log-Zeilen eine Zeitreihe. Das ist die Grundlage für Diagramme und Alarme:

```logql
sum by (cluster, namespace) (
  count_over_time({namespace=~".+"} |~ "(?i)error" [5m])
)
```

Mit `| line_format "{{.msg}}"` zeigst du am Ende nur noch die Felder, die dich interessieren.

#bild("bilder/08-grafana-loki-zaehlen.png", [Die Zähl-Abfrage aus Schritt 4 in *Explore*: Aus Log-Zeilen wird eine Kurve pro Cluster und Namespace. Genau so eine Kurve wertet gleich der Loki-Ruler aus.])

#falle[
  `{cluster="app1"} |= "error"` liest alle Logs von `app1` im gewählten Zeitraum. Bei einer Stunde ist das im Labor kein Problem, bei 30 Tagen schon. Schränke zuerst über Labels ein, dann über Text. Grafana zeigt unter *Query inspector* an, wie viele Bytes Loki gelesen hat.
]

== Kubernetes-Events

Events sind die Notizen, die Kubernetes zu Objekten schreibt: Pod geplant, Image gezogen, Container neu gestartet, Speicher voll. Der API-Server löscht sie nach einer Stunde. In Loki bleiben sie so lange wie alle anderen Logs.

```logql
{job="kubernetes-events"} | logfmt | type="Warning"
```

Welche Gründe gab es in der letzten Stunde, je Cluster?

```logql
sum by (cluster, reason) (
  count_over_time({job="kubernetes-events"} | logfmt | type="Warning" [1h])
)
```

Die Felder im Text heißen unter anderem `kind`, `name`, `reason`, `type` und `msg`. In einem frischen Cluster gibt es kaum Warnungen. Fehlen auch die Events mit `type="Normal"`, prüfe in den Alloy-Logs die Komponente `logs_events`.

== Log-Alarme über den Loki-Ruler

Manches siehst du nur im Log, etwa eine Häufung von Fehlermeldungen oder bestimmte Events. Dafür hat Loki einen eigenen Ruler. Er wertet LogQL-Regeln aus und schickt Alarme an denselben Alertmanager wie Prometheus und der Thanos Ruler. Routing, Mailpit und Stummschalten aus Kapitel 7 gelten also auch hier.

Der Ruler arbeitet pro Mandant. Eine Regel im Mandanten `app1` sieht nur die Logs von `app1`. Abfragen über mehrere Mandanten wie in Grafana sind für Regeln nicht vorgesehen. Deshalb lädst du dieselbe Regeldatei dreimal, einmal pro Mandant.

#datei("observability/rules/loki/log-alarme.yaml (Ausschnitt)", ```yaml
groups:
  - name: logs
    rules:
      - alert: LogFehlerHaeufig
        expr: |
          sum by (cluster, namespace, pod) (
            rate({namespace=~".+"} |~ "(?i)(error|exception|panic)" [5m])
          ) > 1
        for: 10m
        labels:
          severity: warning
      - alert: KubernetesWarnEvent
        expr: |
          sum by (cluster, namespace, reason) (
            count_over_time(
              {job="kubernetes-events"} | logfmt
                | type="Warning"
                | reason=~"BackOff|FailedScheduling|FailedMount|OOMKilling|Evicted" [10m]
            )
          ) > 0
        for: 5m
        labels:
          severity: warning
```, erklaerung: [
  Das Format ist dasselbe wie bei Prometheus-Regeln, nur steht in `expr` LogQL. Weil jede Regel nach `cluster` gruppiert, trägt der Alarm dieses Label, und das Routing aus Kapitel 7 greift. Die erste Regel ist bewusst grob. Passe das Muster an deine Anwendungen an, bevor du dich auf sie verlässt.
])

#datei("observability/rules/loki/kustomization.yaml (Ausschnitt)", ```yaml
generatorOptions:
  disableNameSuffixHash: true
  labels:
    loki_rule: "1"
configMapGenerator:
  - name: loki-regeln-app1
    files: [log-alarme.yaml]
    options:
      annotations: {loki_rule_folder: app1}
  # ... ebenso für obs und app2
```, erklaerung: [
  Kustomize erzeugt drei ConfigMaps aus derselben Datei. Der Regel-Sidecar im Loki-Pod sucht ConfigMaps mit dem Label `loki_rule` und legt sie in den Ordner aus der Annotation `loki_rule_folder`. Der Ruler erwartet genau diese Struktur: `/rules/<mandant>/<datei>`.
])

#cmd("Mac")[```bash
kubectl --context obs apply -k observability/rules/loki/
```][Legt die drei ConfigMaps im Namespace `monitoring` an.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring exec loki-0 -c loki-sc-rules -- ls -R /rules
```][Zeigt, was der Sidecar abgelegt hat. Der Befehl läuft im Sidecar, nicht im Container `loki`: Das Loki-Image enthält kein `ls`. Beide Container teilen sich das Verzeichnis `/rules`.]

#pruefe[
  Drei Ordner `obs`, `app1` und `app2`, in jedem die Datei `log-alarme.yaml`. Der Ruler liest den Ordner regelmäßig neu ein, ein Neustart ist nicht nötig.
]

Dateien im Ordner heißen noch nicht, dass der Ruler sie geladen hat. Das verrät dir seine API:

#cmd("Mac")[```bash
curl -s -H "X-Scope-OrgID: app1" \
  localhost:3100/prometheus/api/v1/rules | jq -c '.data.groups[].rules[].name'
```][Fragt den Ruler, welche Regeln er für den Mandanten `app1` geladen hat. Der Port-Forward muss noch laufen. Die Ruler-API nimmt nur einen Mandanten pro Anfrage, `obs|app1|app2` liefert hier nichts.]

#pruefe[
  Die Namen `"LogFehlerHaeufig"` und `"KubernetesWarnEvent"`. Fehlen sie, obwohl die Datei im Ordner liegt, hat Loki sie nicht lesen können. Die Ursache steht dann im Log von `loki-0`, meist ein YAML- oder LogQL-Fehler.
]

Jetzt löst du einen Alarm aus. Ein Pod, der sofort endet, landet in `CrashLoopBackOff`, und Kubernetes schreibt `BackOff`-Events:

#cmd("Mac")[```bash
kubectl --context app1 run kaputt --image=busybox:1.36 \
  --restart=Always -- sh -c "exit 1"
```][Startet einen Pod in `default`, der immer wieder abstürzt.]

#cmd("Mac")[```bash
curl -s -H "X-Scope-OrgID: app1" \
  localhost:3100/prometheus/api/v1/alerts | jq '.data.alerts[].labels'
```][Fragt den Ruler nach aktiven Alarmen des Mandanten `app1`. Der Port-Forward muss noch laufen.]

#pruefe[
  Nach etwa einer Minute ein Alarm `KubernetesWarnEvent` mit `cluster: "app1"`, `namespace: "default"` und `reason: "BackOff"`, zuerst im Zustand `pending`. Im Labor wechselte er nach 6 Minuten auf `firing`, 30 Sekunden später lag in Mailpit `[FIRING:1] KubernetesWarnEvent app1 (default loki BackOff warning)`. Kommt keine Mail, obwohl der Alarm feuert, schau im Alertmanager nach: Eine noch laufende Silence aus Kapitel 7 auf `cluster="app1"` schaltet ihn stumm. Daneben feuert meist auch der Metrik-Alarm aus Kapitel 7 für den Crashloop. Das ist kein Fehler: Zwei Signale bestätigen dasselbe Problem.
]

#cmd("Mac")[```bash
kubectl --context app1 delete pod kaputt
```][Räumt auf. Der Alarm löst sich auf, sobald die Events aus dem Zehn-Minuten-Fenster fallen.]

== Aufbewahrung und Compactor

Loki schreibt Logs in Blöcken ins S3 und legt dazu einen Index an. Gelöscht wird nichts von selbst. Das übernimmt der *Compactor*, der im selben Prozess läuft. Er fasst die kleinen Index-Dateien zusammen und löscht mit `retention_enabled: true` alles, was älter ist als `retention_period`, hier sieben Tage.

`retention_delete_delay: 2h` lässt zwischen Markieren und Löschen eines Blocks zwei Stunden Zeit, in denen du einen Fehler noch bemerken kannst. Löschaufträge legt der Compactor laut `delete_request_store` im S3 ab. Zeilen, die älter als sieben Tage sind, nimmt Loki wegen `reject_old_samples_max_age` gar nicht erst an.

#falle[
  Ohne `retention_enabled: true` wächst der Bucket unbegrenzt, auch wenn `retention_period` gesetzt ist. Lege für den Loki-Bucket auch keine eigene S3-Lifecycle-Regel an, die Dateien nach Alter löscht. Der Index wüsste davon nichts und zeigte auf fehlende Blöcke.
]

Die Aufbewahrung lässt sich pro Mandant ändern, ohne Neustart über die Laufzeit-Konfiguration. Das brauchst du, wenn ein Cluster aus rechtlichen Gründen kürzer oder länger aufbewahren muss. Kapitel 13 greift das beim Thema Datenschutz wieder auf.

#aufgabe[
  `app2` soll nur drei Tage aufbewahren. Ergänze in `observability/central/loki/values.yaml` unter `loki` einen Block `runtimeConfig` mit `overrides`, darunter den Mandanten `app2` und dort `retention_period: 72h`. Prüfe die Datei mit `helm template`, bevor du `helm upgrade` ausführst. Wie kontrollierst du danach, ob Loki den Wert übernommen hat? Tipp: Loki zeigt die aktive Laufzeit-Konfiguration unter dem Pfad `/runtime_config`.
]

Beende zum Schluss den Port-Forward im zweiten Terminal mit `Ctrl-C`.

#gelernt(
  [Loki indiziert nur Labels. Wenige, stabile Labels halten die Zahl der Streams klein, alles andere bleibt im Text oder in strukturierten Metadaten.],
  [Jeder Cluster schreibt als eigener Mandant. Grafana fragt mit `obs|app1|app2` alle zugleich ab.],
  [Eine LogQL-Abfrage wählt zuerst Streams, filtert dann Text und zählt am Ende Zeilen.],
  [Der Loki-Ruler arbeitet pro Mandant und schickt Alarme an denselben Alertmanager wie Prometheus.],
  [Gelöscht wird nur, wenn der Compactor die Retention ausführt.],
)

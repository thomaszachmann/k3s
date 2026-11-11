#import "../lib.typ": *

#kapitel(
  [Fertige Dashboards],
  ziel: [Sieben eigene Dashboards aus dem Repo beantworten die Fragen, die du im Alltag wirklich stellst. Dazu weißt du, welche mitgelieferten und welche Community-Dashboards sich lohnen.],
  zeit: [45 Minuten],
  braucht: [Kapitel 6 und 7, für die Dashboards *Logs* und *Services* auch Kapitel 8 und 9],
)

== Warum eigene Dashboards

kube-prometheus-stack bringt rund 30 Dashboards mit, und auf grafana.com gibt es Tausende. Trotzdem lohnen sich eigene. Die mitgelieferten sind für einen Cluster mit eigenem Prometheus gebaut. Viele ihrer Panels nutzen Recording Rules, also vorberechnete Serien wie `node_namespace_pod_container:container_cpu_usage_seconds_total:sum_rate5m`. Diese Serien berechnet in deinem Labor nur Prometheus auf obs, und zwar nur für obs. Wählst du in *Kubernetes / Compute Resources / Cluster* den Cluster app1, bleiben deshalb einige Panels leer.

Man könnte diese Regeln zusätzlich im Thanos Ruler auswerten. Das sind aber rund zwei Dutzend Regeln mit Joins über mehrere Metriken, und für obs entstünden dieselben Serien doppelt, einmal von Prometheus und einmal vom Ruler. Dieses Buch geht deshalb den anderen Weg: Die eigenen Dashboards kommen ganz ohne Recording Rules aus.

Die Dashboards in `observability/dashboards/` folgen vier Regeln:

- *Eine Frage pro Dashboard.* Der Titel sagt, was du erfährst, die Beschreibung jedes Panels, wie du es liest.
- *Nur Rohdaten.* Alle Abfragen nutzen Serien, die Alloy, kube-state-metrics und node-exporter direkt liefern. Sie funktionieren deshalb für jeden Cluster.
- *Zwei Variablen.* `datasource` wählt die Datenquelle, `cluster` den Cluster. Keine feste UID einer Datenquelle steht im JSON.
- *Verlinkt.* Oben rechts führt *Weitere Dashboards* zu den anderen, mit derselben Auswahl und demselben Zeitraum.

#tabelle(
  (auto, auto, 1fr),
  ([Datei], [Ordner], [Frage]),
  [`multi-cluster.json`], [Plattform], [Sind alle Cluster da, gesund und liefern sie Daten?],
  [`node.json`], [Plattform], [Wie geht es einem einzelnen Node?],
  [`workloads.json`], [Plattform], [Was läuft in einem Namespace, was verbraucht es, was ist kaputt?],
  [`thanos-speicher.json`], [Plattform], [Kommen die Metriken an, und landen sie im S3?],
  [`alarme.json`], [Plattform], [Was feuert gerade, und kommen die Benachrichtigungen an?],
  [`logs.json`], [Signale], [Was steht in den Logs, und wo häufen sich Fehler?],
  [`services.json`], [Signale], [Wie viele Anfragen, Fehler und welche Latenz hat ein Service?],
)

== So ist ein Dashboard gebaut

Jedes Dashboard beginnt mit denselben zwei Variablen:

#datei("observability/dashboards/plattform/multi-cluster.json (Ausschnitt)", ```json
"templating": { "list": [
  { "name": "datasource", "label": "Datenquelle",
    "type": "datasource", "query": "prometheus",
    "current": { "text": "default", "value": "default" } },
  { "name": "cluster", "label": "Cluster", "type": "query",
    "datasource": { "type": "prometheus", "uid": "${datasource}" },
    "query": "label_values(up, cluster)",
    "refresh": 2, "multi": true, "includeAll": true, "allValue": ".*" }
]}
```, erklaerung: [
  Eine Variable vom Typ `datasource` listet alle Datenquellen des Typs `prometheus`. Der Wert `default` steht für die Standard-Datenquelle, bei dir Thanos. Das ist keine feste UID: In einer anderen Grafana-Instanz wählt dasselbe Dashboard deren Standard. `refresh: 2` liest die Cluster bei jeder Änderung des Zeitraums neu. Kommt ein vierter Cluster dazu, erscheint er von selbst.
])

Jedes Panel verweist dann auf die Variable statt auf eine feste Datenquelle:

```json
"datasource": { "type": "prometheus", "uid": "${datasource}" },
"targets": [{ "expr": "count(group by (cluster) (up{cluster=~\"$cluster\"}))",
              "instant": true }]
```

Das `=~` ist wichtig. Bei Mehrfachauswahl setzt Grafana für `$cluster` einen regulären Ausdruck wie `app1|app2` ein, bei *All* den Wert aus `allValue`, also `.*`. Mit `=` statt `=~` fände die Abfrage dann nichts.

#falle[
  Lässt du `current` leer, also `"current": {}`, wählt Grafana 13 nicht zuverlässig die Standard-Datenquelle. Im Labor landete das Dashboard bei `Prometheus`, dem lokalen Prometheus auf obs. Seine Serien tragen kein Label `cluster`, denn das hängt erst der Remote Write an. Das Dashboard öffnet dann mit leerer Cluster-Auswahl und lauter leeren Panels.
]

#falle[
  Ein Stat-Panel mit `count(...)` zeigt *No data* statt `0`, wenn nichts passt, denn `count` über eine leere Menge ist leer und nicht null. Deshalb enden solche Abfragen mit `or vector(0)`. Ohne das sieht „keine Alarme“ genauso aus wie „Abfrage kaputt“.
]

== Einspielen

Die Dashboards landen als zwei ConfigMaps im Cluster. Die Datei `kustomization.yaml` baut sie mit einem `configMapGenerator`:

#datei("observability/dashboards/kustomization.yaml (Ausschnitt)", ```yaml
namespace: monitoring
generatorOptions:
  disableNameSuffixHash: true
  labels:
    grafana_dashboard: "1"
configMapGenerator:
  - name: dashboards-plattform
    options:
      annotations:
        grafana_folder: Plattform
    files:
      - plattform/multi-cluster.json
      - plattform/node.json
      # ...
  - name: dashboards-signale
    options:
      annotations:
        grafana_folder: Signale
    files:
      - signale/logs.json
      - signale/services.json
```, erklaerung: [
  Das Label holt der Sidecar aus Kapitel 6, die Annotation bestimmt den Ordner. `disableNameSuffixHash` hält die Namen stabil, sonst hinge Kustomize bei jeder Änderung einen neuen Hash an und ließe die alte ConfigMap liegen.
])

#cmd("Mac")[```bash
kubectl --context obs apply -k observability/dashboards/ --server-side
```][`--server-side` ist nötig: Ein normales `apply` speichert die ganze ConfigMap zusätzlich in einer Annotation, und die darf höchstens 256 KB groß sein. Die ConfigMap `dashboards-plattform` ist schon rund 150 KB groß (gemessen an der Ausgabe von `kubectl kustomize`). Mit einem weiteren großen Dashboard wäre die Grenze überschritten, also gewöhnst du dir `--server-side` gleich an.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring logs deploy/kps-grafana \
  -c grafana-sc-dashboard --tail=20
```][Der Dashboard-Sidecar meldet jede Datei, die er schreibt.]

#pruefe[
  Sieben Zeilen, in denen der Sidecar die Dateien unter `/tmp/dashboards/Plattform/` und `/tmp/dashboards/Signale/` ablegt. In Grafana stehen unter *Dashboards* die Ordner *Kubernetes*, *Plattform* und *Signale*. Jedes Dashboard öffnet mit `default` als Datenquelle und einer gefüllten Auswahl *Cluster*.
]

== Die Dashboards im Einzelnen

=== Multi-Cluster-Überblick

Dein Einstieg jeden Morgen. Oben sechs Kennzahlen: wie viele Cluster Daten liefern, welcher Anteil der Targets erreichbar ist, wie viele Alarme feuern, das älteste Datenalter, Nodes und laufende Pods. Darunter eine Tabelle mit einer Zeile pro Cluster, deren Zellen rot werden, wenn etwas nicht stimmt. Im unteren Teil CPU und Speicher je Cluster sowie Proben pro Sekunde und aktive Serien je Mandant in Thanos Receive.

#bild("bilder/10-dashboard-multi-cluster.png", [Der Multi-Cluster-Überblick im Normalbetrieb: drei Cluster, alle Targets erreichbar, das Datenalter überall grün. Wie dasselbe Dashboard während eines Ausfalls aussieht, zeigt Kapitel 15.])

#warum[
  Das Panel *Ältester Datenpunkt* rechnet für jeden Cluster, wie lange sein letzter `up`-Wert her ist. Es zeigt dasselbe wie der Alarm `ClusterSchweigt` aus Kapitel 7, aber sofort und ohne `for`-Zeit. Ein Wert über zwei Minuten heißt: Dieser Cluster schickt gerade nichts.

  Die Abfrage braucht dafür einen Trick. Ein einfaches `time() - timestamp(up)` findet nur Serien, die in den letzten fünf Minuten einen Wert hatten. Ein schweigender Cluster verschwindet damit nach fünf Minuten aus der Tabelle, statt rot zu werden. Deshalb schaut die Abfrage mit einer Unterabfrage sechs Stunden zurück:
  ```promql
  time() - max by (cluster) (
    max_over_time(timestamp(up{cluster=~"$cluster"})[6h:1m]))
  ```
  `[6h:1m]` wertet `timestamp(up)` sechs Stunden lang einmal pro Minute aus, `max_over_time` nimmt davon den jüngsten Zeitpunkt. Weil die Unterabfrage nur minütlich rechnet, zeigt auch ein gesunder Cluster bis zu gut einer Minute an. Das ist der Grund für die Schwelle von zwei Minuten.
]

=== Node

Wähle Cluster und Node. Die obere Reihe zeigt Laufzeit, Kerne, Arbeitsspeicher und die aktuelle Belegung von CPU, RAM und `/`. Darunter CPU nach Modus (viel `iowait` heißt: Die Disk bremst), Load im Vergleich zur Zahl der Kerne, Speicher aufgeteilt in belegt, Cache und verfügbar, die Belegung aller Dateisysteme sowie Disk- und Netzwerk-Durchsatz. Senden und Schreiben zeigen nach unten, so liest du beide Richtungen in einem Panel.

=== Workloads

Wähle einen Cluster und einen oder mehrere Namespaces. Oben laufende und gestörte Pods, nicht bereite Container und Neustarts der letzten Stunde. Die Tabelle *Anforderung und Verbrauch je Pod* stellt CPU und RAM den Requests und Limits gegenüber. Liegt der Verbrauch weit unter dem Request, verschenkst du Platz. Liegt er nah am Limit, droht `OOMKilled`. Unten drei Tabellen für die Fehlersuche: Neustarts, wartende Container mit Grund (etwa `CrashLoopBackOff` oder `ImagePullBackOff`) und Deployments mit gewünschten und verfügbaren Replikas.

#bild("bilder/10-dashboard-workloads.png", [*Workloads* für `app1` und den Namespace `demo`: oben der Zustand, darunter CPU und Speicher je Pod, unten der Vergleich mit den Requests.])

=== Thanos-Speicher

Die Gesundheit der Speicherkette auf obs. Oben Schreibanfragen pro Sekunde, Fehlerquote 5xx, abgelehnte Anfragen 4xx, Serien gesamt, Upload-Fehler und ob der Compactor angehalten hat. Darunter Antworten nach HTTP-Code, Schreiblatenz p50 und p99, Proben und Serien je Mandant. Im zweiten Teil Block-Uploads, S3-Fehler je Komponente, die Zahl der Blöcke im Store Gateway und fehlgeschlagene Kompaktierungen. Zum Schluss Speicher und CPU der Thanos-Pods und von SeaweedFS. Die Variable `cluster` filtert hier die Mandanten.

=== Alarme

Oben die Zahl kritischer, warnender und wartender Alarme, aktive Silences, der Watchdog (muss `1` sein) und Zustellfehler der letzten Stunde. Darunter die Tabelle aller feuernden Alarme mit Cluster, Schwere und Namespace, dann der Verlauf je Cluster und je Alarmname, die Benachrichtigungen je Kanal und die Fehler bei der Regelauswertung in Prometheus und Thanos Ruler.

=== Logs

Nutzt die Datenquelle Loki aus Kapitel 8. Die Variablen `cluster` und `namespace` liest das Dashboard aus den Labels in Loki, dazu kommt ein Suchfeld für einen regulären Ausdruck. Du siehst die Log-Zeilen je Namespace als Balken, Zeilen mit `error`, `fatal` oder `panic` je Cluster, die zehn gesprächigsten Pods und darunter die Log-Zeilen selbst.

#bild("bilder/10-dashboard-logs.png", [Das Dashboard *Logs* über alle Cluster: Zeilen je Namespace, Fehlerzeilen je Cluster, die gesprächigsten Pods und darunter die Zeilen selbst.])

#falle[
  *Loki mag kein `.*`.* Bei der Auswahl *All* setzt Grafana den Wert aus `allValue` ein. Für Prometheus ist `.*` richtig, für Loki nicht: Loki verlangt in jedem Selektor mindestens einen Matcher, der keine leeren Werte zulässt, und antwortet sonst mit `queries require at least one regexp or equality matcher that does not have an empty-compatible value`. Alle Panels zeigen dann ein rotes Warndreieck. Im Logs-Dashboard steht deshalb `"allValue": ".+"`.
]

#falle[
  Loki trennt die Cluster als Mandanten. Damit das Dashboard alle drei auf einmal zeigt, muss die Loki-Datenquelle aus Kapitel 8 den Header `X-Scope-OrgID: obs|app1|app2` senden, und in Loki müssen Abfragen über mehrere Mandanten erlaubt sein. Sonst zeigt die Auswahl `cluster` nur einen Wert.
]

=== Services

Die RED-Methode für jeden Service: *Rate*, *Errors*, *Duration*. Die Daten kommen nicht aus der Anwendung, sondern aus Tempos Metrics-Generator (Kapitel 9). Er macht aus jeder Span die Serien `traces_spanmetrics_calls_total` und `traces_spanmetrics_latency_bucket`, und aus Aufrufen zwischen Services die Serien `traces_service_graph_request_total`. Du siehst Anfragen pro Sekunde, Fehlerquote und Latenz p95 je Service, eine Tabelle der Endpunkte und eine Tabelle „Wer ruft wen?“. Die Punkte im Latenz-Panel sind Exemplars: Ein Klick öffnet den passenden Trace in Tempo.

#bild("bilder/10-dashboard-services.png", [*Services* für `app1`. Die Kurven beginnen erst um 14 Uhr, davor lag der Ausfalltest aus Kapitel 15, in dem keine Traces ankamen. *Fehlerquote* zeigt *No data*: Die Redis-Fehler von HotROD hängen an Client-Spans, das Panel zählt nur Spans vom Typ Server, und die waren fehlerfrei. Die Rauten im Latenz-Panel sind Exemplars.])

#falle[
  Der Metrics-Generator schreibt alle Span-Metriken als Mandant `obs`, egal aus welchem Cluster die Spans stammen. `tenant_id` hilft hier also nicht weiter. Die Abfragen filtern deshalb auf das Label `cluster`, das Tempo aus dem Ressourcen-Attribut `cluster` als Dimension übernimmt (Kapitel 9). Fehlt diese Dimension, bleibt das Dashboard leer, sobald du einen Cluster auswählst.
]

#aufgabe[
  Öffne das Dashboard *Workloads*, wähle `app1` und den Namespace `demo`. Welcher Pod hat den größten Abstand zwischen RAM-Request und tatsächlichem Verbrauch? Prüfe deine Antwort mit `kubectl --context app1 -n demo top pods` und vergleiche mit `kubectl get pod -o yaml`. Warum weichen die Werte von `kubectl top` und vom Dashboard leicht ab?
]

== Mitgelieferte und Community-Dashboards

Die eigenen Dashboards ersetzen nicht alles. Die folgenden sind einen Blick wert. Die ersten liegen schon im Ordner *Kubernetes*.

#tabelle(
  (4.8cm, 2cm, 1fr),
  ([Dashboard], [Herkunft], [Wofür, und was in diesem Labor gilt]),
  [Node Exporter / Nodes], [kps], [Ausführliche Node-Ansicht aus Rohdaten mit Auswahl `cluster`, funktioniert für alle Cluster],
  [Kubernetes / Kubelet], [kps], [Pods, Volumes und Latenz des Kubelets, ohne Recording Rules],
  [Kubernetes / Persistent Volumes], [kps], [Belegung der PVCs. Bei local-path oft leer, weil der Kubelet für hostPath-Volumes keine Volume-Statistik liefert],
  [Kubernetes / Networking / Pod und Cluster], [kps], [Netzwerkverkehr aus cAdvisor-Daten, ohne Recording Rules],
  [Kubernetes / Compute Resources / ...], [kps], [Sehr gut für obs. Für app1 und app2 bleiben die Panels mit Recording Rules leer],
  [Node Exporter / USE Method], [kps], [USE-Methode je Node und Cluster, nur für obs, weil vollständig aus Recording Rules],
  [Alertmanager / Overview], [kps], [Eingehende Alarme und Benachrichtigungen des Alertmanagers],
  [Prometheus / Remote Write], [kps], [Warteschlange und Fehler des Remote Write von Prometheus auf obs],
  [CoreDNS], [kps], [Anfragen und Fehler von CoreDNS],
  [Node Exporter Full (ID 1860)], [grafana.com], [Der Klassiker mit jeder Metrik des node-exporter],
  [Kubernetes / Views / Global, Namespaces, Nodes, Pods (ID 15757 bis 15760)], [grafana.com], [Moderne, übersichtliche Kubernetes-Ansichten. Prüfe nach dem Einspielen, ob sie eine Auswahl `cluster` anbieten, sonst mischen sie alle Cluster],
)

Community-Dashboards holst du genauso ins Repo wie deine eigenen. Lade das JSON einer bestimmten Revision herunter, zum Beispiel mit `curl -sL https://grafana.com/api/dashboards/1860/revisions/<revision>/download`, prüfe es mit `jq empty` und lege es in einen eigenen Ordner mit eigenem `configMapGenerator`. Enthält es einen Block `__inputs`, ersetze die Platzhalter wie `${DS_PROMETHEUS}` durch eine Variable `datasource`, aus demselben Grund wie in Kapitel 6.

#falle[
  Ein Community-Dashboard kennt deine Job-Namen nicht. Viele erwarten `job="node-exporter"` oder `job="kubelet"`. Genau deshalb hat Kapitel 5 diese Namen für app1 und app2 übernommen. Bleibt ein Panel trotzdem leer, öffne es mit *Edit* und vergleiche die Labels in der Abfrage mit denen, die *Explore* für dieselbe Metrik zeigt.
]

#aufgabe[
  Ergänze das Dashboard *Node* um ein Panel „Offene Dateien“ mit der Abfrage `node_filefd_allocated{cluster="$cluster", instance="$instance"}`. Baue es in Grafana, exportiere das JSON wie in Kapitel 6 beschrieben, ersetze `observability/dashboards/plattform/node.json`, prüfe mit `jq empty` und spiele es mit `kubectl apply -k` ein. Was zeigt `git diff` außer deinem neuen Panel noch an, und warum?
]

#gelernt(
  [Mitgelieferte Dashboards nutzen oft Recording Rules, die es nur für den Cluster mit eigenem Prometheus gibt.],
  [Eigene Dashboards mit Rohdaten und einer Variable `cluster` funktionieren für jeden Cluster.],
  [Die Variable `datasource` ersetzt feste UIDs, dann laufen Dashboards in jeder Grafana-Instanz.],
  [Mehrfachauswahl braucht `=~` in der Abfrage, und `or vector(0)` macht aus „keine Daten“ eine Null.],
  [Große Dashboards spielst du mit `kubectl apply --server-side` ein.],
)

#import "../lib.typ": *

#kapitel(
  [Was sonst noch fehlt],
  ziel: [Du prüfst deine Endpunkte von außen, überwachst die Überwachung, hältst die Serienzahl im Griff und formulierst ein erstes SLO.],
  zeit: [2 Stunden, die Abschnitte sind unabhängig voneinander],
  braucht: [Kapitel 4 bis 9],
)

Der Stack läuft. Metriken, Logs und Traces kommen an, Alarme gehen raus. Dieses Kapitel schließt die Lücken, die man erst bemerkt, wenn es zu spät ist: ein abgelaufenes Zertifikat, ein Cluster, der still verstummt, eine Anwendung, die plötzlich Millionen Serien erzeugt. Jeder Abschnitt steht für sich. Nimm dir zuerst den vor, der dir am meisten Sorgen macht.

== Von außen prüfen: der Blackbox-Exporter

Alle bisherigen Metriken kommen von innen. Prometheus weiß, dass der Grafana-Pod läuft. Ob Grafana über `https://grafana.obs.internal` auch erreichbar ist, weiß er nicht. Dazwischen liegen DNS, Traefik, das Zertifikat und der Ingress. Der Blackbox-Exporter prüft genau diesen Weg, so wie ihn ein Nutzer geht.

#datei("observability/extras/blackbox-values.yaml (Ausschnitt)")[```yaml
config:
  modules:
    http_2xx:
      prober: http
      timeout: 5s
      http:
        preferred_ip_protocol: ip4
        fail_if_not_ssl: true
        tls_config:
          ca_file: /etc/obs-ca/ca.crt
    http_basic_auth:
      prober: http
      http:
        valid_status_codes: [200, 401]
        fail_if_not_ssl: true
        tls_config:
          ca_file: /etc/obs-ca/ca.crt
extraConfigmapMounts:
  - name: obs-ca
    mountPath: /etc/obs-ca
    configMap: obs-ca
    readOnly: true
```, erklaerung: [Zwei Prüfarten. `http_2xx` erwartet eine erfolgreiche Antwort. `http_basic_auth` ist für Endpunkte hinter Basic Auth: Eine `401` beweist dort, dass DNS, TLS und Traefik funktionieren. Beide prüfen das Zertifikat gegen deine CA aus Kapitel 2.]]

#cmd("Mac")[```bash
helm --kube-context obs upgrade --install blackbox \
  prometheus-community/prometheus-blackbox-exporter --version 11.21.1 \
  -n monitoring -f observability/extras/blackbox-values.yaml --wait
```][Installiert den Exporter auf `obs`. Er heißt danach `blackbox-prometheus-blackbox-exporter` und lauscht auf Port 9115.]

Was geprüft wird, steht nicht im Exporter, sondern in `Probe`-Objekten. Der Prometheus-Operator macht daraus Scrape-Jobs.

#datei("observability/extras/probes.yaml (Ausschnitt)")[```yaml
kind: Probe
metadata:
  name: obs-endpunkte
  namespace: monitoring
spec:
  jobName: blackbox
  interval: 60s
  module: http_basic_auth
  prober:
    url: blackbox-prometheus-blackbox-exporter.monitoring.svc:9115
  targets:
    staticConfig:
      static:
        - https://receive.obs.internal/api/v1/receive
        - https://loki.obs.internal/loki/api/v1/push
        - https://tempo.obs.internal/v1/traces
        - https://alertmanager.obs.internal/
```, erklaerung: [Eine zweite Probe `obs-grafana` prüft `https://grafana.obs.internal/api/health` mit `http_2xx`.]]

#cmd("Mac")[```bash
kubectl --context obs apply -f observability/extras/probes.yaml
```][Legt beide Probes an. Prometheus übernimmt sie nach etwa einer Minute.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring port-forward svc/blackbox-prometheus-blackbox-exporter 9115
```][Öffnet die Oberfläche des Exporters. Lass das Terminal offen.]

#cmd("Mac")[```bash
curl -s 'http://localhost:9115/probe?module=http_2xx&target=https://grafana.obs.internal/api/health' \
  | grep -E '^probe_(success|ssl_earliest|http_status)'
```][Löst eine Prüfung von Hand aus und filtert die wichtigsten Werte.]

#pruefe[
  `probe_success 1`, `probe_http_status_code 200` und `probe_ssl_earliest_cert_expiry` mit einem Unix-Zeitstempel rund 825 Tage nach dem Tag, an dem du das Zertifikat in Kapitel 2 ausgestellt hast. Steht `probe_success 0`, zeigt dieselbe Anfrage mit `&debug=true` am Ende der URL das vollständige Protokoll der Prüfung.
]

Jetzt der Alarm, den Kapitel 2 angekündigt hat. Das Wildcard-Zertifikat gilt 825 Tage. Das ist lang genug, um es zu vergessen.

#datei("observability/extras/blackbox-rules.yaml (Ausschnitt)")[```yaml
metadata:
  labels:
    auswertung: lokal
spec:
  groups:
    - name: blackbox
      rules:
        - alert: EndpunktNichtErreichbar
          expr: probe_success{job="blackbox"} == 0
          for: 5m
        - alert: ZertifikatLaeuftBaldAb
          expr: (probe_ssl_earliest_cert_expiry{job="blackbox"} - time()) / 86400 < 30
          for: 1h
```, erklaerung: [Warnung 30 Tage vor Ablauf, ein zweiter, kritischer Alarm bei 7 Tagen. Die Rechnung zieht die aktuelle Zeit vom Ablaufdatum ab und teilt durch die Sekunden eines Tages.]]

#warum[
  Diese Regeln tragen `auswertung: lokal`. Prometheus auf `obs` wertet sie also selbst aus, ohne Umweg über Thanos. Ein Alarm „Endpunkt nicht erreichbar“ soll auch dann feuern, wenn gerade Thanos der Grund ist.
]

#cmd("Mac")[```bash
kubectl --context obs apply -f observability/extras/blackbox-rules.yaml
```][Legt die Regeln an.]

#aufgabe[
  Teste den Zertifikatsalarm, ohne zwei Jahre zu warten. Ändere in einer Kopie der Regel die Schwelle von `30` auf `900` Tage und wende sie unter anderem Namen an. Nach einer Stunde erscheint der Alarm in Alertmanager und in Mailpit. Lösche die Kopie danach wieder.
]

== Wer überwacht die Überwachung?

Ein Monitoring, das ausfällt, meldet nichts. Das sieht genauso aus wie ein gesunder Cluster. Gegen diesen Fall hast du in Kapitel 7 schon die wichtigste Sicherung gebaut: den Watchdog. Er feuert immer, und der externe Dead Man's Switch schlägt Alarm, wenn er ausbleibt. Damit erfährst du, wenn die ganze Kette steht. Was der Watchdog nicht sieht, sind Teilausfälle.

#tabelle(
  (auto, 1fr),
  ([Teilausfall], [Woran du ihn erkennst]),
  [Ein App-Cluster schickt nichts mehr], [Seine Serien verschwinden aus Thanos. Alarm `ClusterSchweigt`],
  [Receive lehnt Daten ab], [`http_requests_total{handler="receive"}` mit Code 4xx oder 5xx],
  [Compactor hat aufgegeben], [`thanos_compact_halted == 1`],
  [etcd auf `obs` ist krank], [Standardregeln des Charts, etwa `etcdNoLeader`. Die Daten kommen über Port 2381, den die k3s-Config mit `etcd-expose-metrics` öffnet],
  [Alloy verliert Daten], [Logs von Alloy, siehe Kapitel 14],
)

#datei("observability/extras/meta-rules.yaml (Ausschnitt)")[```yaml
- alert: ClusterSchweigt
  expr: |
    group by (cluster) (up offset 1h)
      unless
    group by (cluster) (up)
  for: 10m
```, erklaerung: [Lies die Abfrage so: alle Cluster, die vor einer Stunde Daten hatten, abzüglich der Cluster, die jetzt Daten haben. Übrig bleibt der Cluster, der verstummt ist. Das funktioniert für jeden neuen Cluster automatisch, ohne dass du ihn in die Regel schreibst.]]

#cmd("Mac")[```bash
kubectl --context obs apply -f observability/extras/meta-rules.yaml
```][Drei Regeln mit `auswertung: global` für den Thanos Ruler, denn nur er sieht alle Cluster.]

#aufgabe[
  Simuliere den Ausfall: `kubectl --context app2 -n monitoring scale ds/alloy --replicas=0` geht bei einem DaemonSet nicht. Finde einen anderen Weg, Alloy in `app2` für 15 Minuten anzuhalten, und warte auf `ClusterSchweigt`. Hinweis: Ein DaemonSet lässt sich über einen `nodeSelector` auf ein Label beschränken, das kein Node trägt.
]

Alloy kann auch über sich selbst berichten, mit der Komponente `prometheus.exporter.self`. Dann siehst du etwa, wie viele Samples Alloy nicht loswird. In diesem Buch fehlt das bewusst, um `metrics.alloy` kurz zu halten. Es ist eine gute nächste Übung.

== Kardinalität: wenn Serien explodieren

Jede einzigartige Kombination aus Metrikname und Labels ist eine Serie. Ein Label mit der Benutzer-ID oder der vollen URL macht aus einer Metrik schnell hunderttausend Serien. Receive braucht dann mehr Speicher, als die VM hat, und alle Cluster leiden mit.

#cmd("Mac")[```bash
kubectl --context obs -n monitoring port-forward svc/thanos-query 10902
```][Öffnet die Oberfläche von Thanos Query auf `localhost:10902`. Du kannst die folgenden Abfragen genauso in Grafana unter *Explore* stellen.]

Die wichtigste Abfrage zeigt die zehn Metriken mit den meisten Serien:

```
topk(10, count by (__name__)({__name__=~".+"}))
```

Diese Abfrage ist selbst teuer, denn sie fasst jede Serie an. Stelle sie nur von Hand und nie in ein Dashboard mit automatischer Aktualisierung. Hast du eine verdächtige Metrik gefunden, suchst du das schuldige Label:

```
count by (cluster, job) (kube_pod_container_status_restarts_total)
```

Die Serien pro Mandant zeigt dir Receive selbst:

```
sum by (tenant) (prometheus_tsdb_head_series{job="thanos-receive"})
```

#pruefe[
  Drei Mandanten `obs`, `app1` und `app2` mit jeweils einigen zehntausend Serien. Ganz oben in der `topk`-Liste stehen typischerweise Metriken von cAdvisor und kube-state-metrics. Die genauen Zahlen hängen von deinem Cluster ab.
]

Gegen einen Ausreißer hilft ein Limit pro Mandant. Thanos Receive liest es aus einer Datei.

#datei("observability/extras/receive-limits.yaml (Ausschnitt)")[```yaml
write:
  global:
    max_concurrency: 30
  default:
    request:
      series_limit: 5000
      samples_limit: 20000
  tenants:
    obs:
      request:
        series_limit: 0
        samples_limit: 0
```, erklaerung: [Pro Remote-Write-Anfrage höchstens 5000 Serien und 20000 Samples. Was darüber liegt, lehnt Receive mit HTTP 413 ab. `0` heißt unbegrenzt, für `obs` selbst. Ein Limit für die Gesamtzahl aktiver Serien (`head_series_limit`) gibt es auch, es braucht aber eine Meta-Monitoring-Abfrage gegen einen zweiten Prometheus.]]

Die Datei liegt als ConfigMap im Repo. Damit Receive sie liest, ergänzt du in `observability/central/thanos/receive.yaml` drei Dinge: das Argument `--receive.limits-config-file=/etc/thanos-limits/limits.yaml`, ein Volume aus der ConfigMap `thanos-receive-limits` und den passenden `volumeMount`.

#aufgabe[
  Baue die Ergänzung selbst ein und wende beide Dateien an. Prüfe danach in den Logs von `thanos-receive`, dass die Limits geladen wurden. Was passiert in Alloy, wenn eine Anfrage mit 413 abgelehnt wird? Tipp: Alloy versucht es bei 413 nicht erneut, die Daten sind verloren. Deshalb gehören Limits großzügig gesetzt.
]

== SLOs mit Burn-Rate-Alarmen

Bisher alarmierst du auf Ursachen: Pod startet neu, Disk wird voll. Ein SLO dreht das um. Es beschreibt, was der Nutzer erlebt, und alarmiert nur, wenn das Versprechen in Gefahr ist.

Die Begriffe in einem Satz: Das *SLI* ist die Messgröße, hier der Anteil fehlerfreier Anfragen an den `frontend`-Dienst von HotROD. Das *SLO* ist das Ziel, hier 99 Prozent über 30 Tage. Das *Fehlerbudget* ist der Rest: 1 Prozent der Anfragen dürfen scheitern.

Die *Burn-Rate* sagt, wie schnell du das Budget verbrauchst. Bei Burn-Rate 1 ist es nach genau 30 Tagen leer. Bei 14,4 ist nach einer Stunde schon 2 Prozent des Monatsbudgets weg. Gute Alarme schauen auf zwei Zeitfenster gleichzeitig: ein langes, damit ein kurzer Ausreißer nicht weckt, und ein kurzes, damit der Alarm endet, sobald das Problem behoben ist.

#tabelle(
  (auto, auto, auto, 1fr),
  ([Burn-Rate], [Langes Fenster], [Kurzes Fenster], [Bedeutung]),
  [14,4], [1 Stunde], [5 Minuten], [2 % des Budgets in einer Stunde, sofort handeln],
  [6], [6 Stunden], [30 Minuten], [5 % in sechs Stunden, sofort handeln],
  [3], [1 Tag], [2 Stunden], [10 % an einem Tag, heute noch anschauen],
  [1], [3 Tage], [6 Stunden], [10 % in drei Tagen, ein Ticket],
)

Die Werte stammen aus dem SRE Workbook von Google. Die Daten liefern die Span-Metriken von Tempo aus Kapitel 9.

#datei("observability/extras/slo-rules.yaml (Ausschnitt)")[```yaml
- record: slo:demo_fehlerquote:rate1h
  expr: |
    sum by (cluster) (rate(traces_spanmetrics_calls_total{service="frontend",
        span_kind="SPAN_KIND_SERVER", status_code="STATUS_CODE_ERROR"}[1h]))
      /
    sum by (cluster) (rate(traces_spanmetrics_calls_total{service="frontend",
        span_kind="SPAN_KIND_SERVER"}[1h]))
# ... dieselbe Regel fuer 5m, 30m, 2h, 6h, 1d und 3d
- alert: DemoFehlerbudgetBrenntSchnell
  expr: |
    slo:demo_fehlerquote:rate1h > (14.4 * 0.01)
      and
    slo:demo_fehlerquote:rate5m > (14.4 * 0.01)
  for: 2m
```, erklaerung: [Recording Rules rechnen die Fehlerquote für sieben Fenster einmal pro Minute vor. Die Alarme vergleichen dann nur noch fertige Werte. `0.01` ist das Fehlerbudget. Die Datei enthält alle vier Zeilen der Tabelle.]]

#cmd("Mac")[```bash
kubectl --context obs apply -f observability/extras/slo-rules.yaml
```][Die Regeln tragen `auswertung: global`. Die Span-Metriken kommen über Receive, deshalb sieht sie nur der Thanos Ruler.]

#pruefe[
  Nach zwei, drei Minuten liefert `slo:demo_fehlerquote:rate5m` in Grafana einen Wert pro Cluster mit HotROD. Ist die Abfrage leer, gab es im Fenster keinen einzigen Fehler: Dann ist der Zähler leer, und die Division liefert nichts. Das ist kein Fehler der Regel.
]

#falle[
  Ein SLO auf 99,99 Prozent klingt gut. Bei einer Demo-App mit einer Anfrage alle drei Sekunden sind das rund 860000 Anfragen im Monat. Schon 87 Fehler leeren das Budget. Fang mit einem Ziel an, das du heute schon erreichst, und verschärfe es später.
]

#aufgabe[
  Ergänze ein zweites SLO für die Latenz: 95 Prozent der Anfragen an `frontend` sollen schneller als 500 Millisekunden sein. Die Daten stehen in `traces_spanmetrics_latency_bucket`. Überlege zuerst, wie du „Anteil schneller als 500 ms“ aus einem Histogramm mit `le`-Grenzen ausrechnest, bevor du die Regel schreibst.
]

== Profiling mit Pyroscope (optional)

Metriken sagen, *dass* ein Dienst viel CPU braucht, Traces, *welche* Anfrage langsam ist. Profile zeigen, *welche Funktion* im Code die Zeit verbraucht. Grafana Pyroscope speichert solche Profile und zeigt sie als Flammendiagramm. Es ist das vierte Signal, und das jüngste.

Für einen ersten Blick reicht ein einzelner Pod auf `obs`.

#cmd("Mac")[```bash
helm --kube-context obs upgrade --install pyroscope grafana/pyroscope \
  --version 2.4.3 -n monitoring -f observability/extras/pyroscope-values.yaml --wait
kubectl --context obs apply -f observability/extras/pyroscope-datasource.yaml
```][Installiert Pyroscope mit 5 GiB lokalem Speicher und ohne das mitgelieferte zweite Alloy. Die Datenquelle erscheint nach einer Minute in Grafana.]

Daten sammelt Alloy, entweder per eBPF für alle Prozesse eines Nodes (`pyroscope.ebpf`, braucht privilegierte Rechte) oder indem es Go-Programme über ihre pprof-Schnittstelle abfragt (`pyroscope.scrape`). Beides ist eine eigene `.alloy`-Datei wert. Wie man Profile liest, zeigt das Buch „Kubernetes Observability Hands-On“ ausführlicher. Willst du Pyroscope nicht behalten, entfernst du es mit `helm uninstall pyroscope` und löschst das PVC.

== Absicherung und Datenschutz

Observability-Daten sind Betriebsdaten, aber nicht harmlos. Logs enthalten IP-Adressen, Benutzernamen, manchmal E-Mail-Adressen in URLs oder ganze Anfragen. Das sind personenbezogene Daten im Sinne der DSGVO. Fünf Fragen solltest du für dein Setup beantworten können.

*Was steht in den Logs?* Such einmal gezielt danach, etwa mit `{cluster="app1"} |~ "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+"` in Grafana. Am besten entfernst du solche Daten schon im Cluster, bevor sie das Haus verlassen. In Alloy geht das mit einer Stufe `stage.replace` in `loki.process`, die ein Muster durch einen Platzhalter ersetzt.

*Wie lange liegt was?* Die Aufbewahrung steht in deinen Werten: 7 Tage für Logs und Traces, bis zu 365 Tage für verdichtete Metriken. Schreib diese Zahlen und ihren Zweck auf. Das ist der Kern dessen, was ein Verarbeitungsverzeichnis von dir wissen will. Einzelne Log-Zeilen löschst du vor Ablauf über die Lösch-API von Loki. Einen Teil der Voraussetzungen, `delete_request_store`, hast du in Kapitel 8 schon gesetzt. Was sonst noch nötig ist, steht in der Loki-Doku unter „Log entry deletion“.

Brauchen die Cluster unterschiedliche Fristen, kann Loki das pro Mandant. Im Chart setzt du dafür unter `loki.runtimeConfig` einen Block `overrides`, darin pro Mandant ein eigenes `retention_period`, etwa `app2: {retention_period: 72h}`. Loki liest diese Datei im laufenden Betrieb neu ein. Bei Thanos gilt die Retention des Compactors dagegen für den ganzen Bucket. Unterschiedliche Fristen pro Mandant gehen dort nur mit mehreren Compactors, die sich über `--selector.relabel-config` nach dem Label `tenant_id` aufteilen. Das ist für ein Labor zu viel Aufwand.

*Wer darf was sehen?* In Grafana hat jeder angemeldete Benutzer mindestens die Rolle *Viewer* und sieht damit alle Datenquellen. Lege Teams an und vergib Rechte pro Ordner. Wer nur die Logs von `app1` sehen darf, bekommt eine eigene Loki-Datenquelle mit `X-Scope-OrgID: app1` statt der Mehrmandanten-Abfrage `obs|app1|app2`.

*Kann sich ein Cluster als anderer ausgeben?* Ja, im jetzigen Aufbau schon. Basic Auth prüft, *wer* schreibt. Den Mandanten bestimmt aber der Header, den Alloy mitschickt, also `THANOS-TENANT` oder `X-Scope-OrgID`. Wer das Passwort von `app1` kennt, kann mit dem Header `app2` in dessen Mandanten schreiben. Für ein Labor mit drei eigenen Clustern ist das vertretbar. Für mehr brauchst du eine Instanz, die den Header aus der Anmeldung ableitet und nicht dem Client glaubt. Traefik bietet dafür in der Basic-Auth-Middleware die Option `headerField`: Sie schreibt den angemeldeten Benutzernamen in einen Header deiner Wahl. Weil deine Benutzer genauso heißen wie die Mandanten, wäre das mit je einer Middleware pro Header-Namen eine schlanke Lösung. Teste aber selbst, was mit einem Header passiert, den der Client schon mitschickt, bevor du dich darauf verlässt. Die robuste Alternative ist ein eigener Proxy vor Receive, Loki und Tempo, etwa der Enterprise Gateway von Grafana oder oauth2-proxy mit einer Zuordnung von Benutzer zu Mandant.

*Wie oft wechseln die Zugänge?* Die Basic-Auth-Passwörter der Cluster laufen nie ab. Wechsle sie regelmäßig, mindestens aber, wenn jemand das Team verlässt. Weil der Benutzername zugleich der Clustername ist, kann es pro Cluster nur einen Eintrag in `obs-basic-auth-users` geben. Tausche deshalb das Passwort dort und in `obs-remote-auth` direkt nacheinander und starte Alloy sofort neu. In der Lücke dazwischen lehnt Traefik mit `401` ab, und diese Daten gehen verloren. Bei den S3-Schlüsseln geht es ohne Lücke: Ein AWS-Benutzer darf zwei Schlüssel gleichzeitig haben, ein SeaweedFS-Konto mehrere Einträge unter `credentials`.

#warum[
  Rotation scheitert selten an der Technik, sondern an der Reihenfolge. Wo zwei Geheimnisse gleichzeitig gelten dürfen, gilt: erst das neue ergänzen, dann alle Nutzer umstellen, dann das alte entfernen. So entsteht kein Zeitfenster, in dem niemand schreiben darf.
]

== Ausblick: GitOps

Du hast in diesem Buch jede Änderung mit `kubectl apply` und `helm upgrade` vom Mac aus ausgerollt. Das ist zum Lernen richtig, denn du siehst jeden Schritt. Im Alltag wird es mühsam: Hat jemand etwas von Hand geändert? Ist `app2` auf demselben Stand wie `app1`? Werkzeuge wie Flux oder Argo CD drehen den Weg um. Sie laufen in jedem Cluster, lesen dieses Repo und gleichen den Cluster laufend mit dem Stand im Git ab. Weicht etwas ab, setzen sie es zurück. Deine Ordnerstruktur unter `observability/` ist dafür schon gut vorbereitet, denn alles liegt als Datei vor. Offen bleiben die Secrets, die du bewusst nie ins Git geschrieben hast. Dafür brauchst du dann ein Werkzeug wie External Secrets oder SOPS.

#gelernt(
  [Der Blackbox-Exporter prüft den Weg eines Nutzers von außen, inklusive Zertifikatsablauf.],
  [Der Watchdog meldet den Totalausfall, Teilausfälle brauchen eigene Regeln wie `ClusterSchweigt`.],
  [Kardinalität findest du mit `topk` über `count by (__name__)`, und Limits pro Mandant schützen Receive.],
  [Burn-Rate-Alarme mit zwei Fenstern melden, wenn das Fehlerbudget in Gefahr ist, nicht bei jedem Ausreißer.],
  [Logs enthalten personenbezogene Daten. Aufbewahrung, Zugriff und Rotation gehören dokumentiert.],
)

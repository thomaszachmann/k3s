#import "../lib.typ": *

#kapitel(
  [Alarme, die ankommen],
  ziel: [Regeln über alle Cluster lösen Alarme aus, der Alertmanager sortiert sie nach Cluster und Schwere, und eine Mail kommt an. Fällt die ganze Kette aus, meldet sich ein Dienst von außen.],
  zeit: [90 Minuten],
  braucht: [Kapitel 6: Grafana mit den Datenquellen Thanos und Alertmanager],
)

== Die Kette

Ein Dashboard schaut niemand um drei Uhr nachts an. Dafür gibt es Alarme. Damit einer ankommt, muss eine ganze Kette funktionieren:

#tabelle(
  (auto, 1fr),
  ([Glied], [Aufgabe in diesem Labor]),
  [Prometheus auf obs], [Wertet die Standardregeln des Charts und Regeln mit `auswertung: lokal` aus. Sieht nur `obs`.],
  [Thanos Ruler], [Wertet Regeln mit `auswertung: global` aus. Fragt Thanos Query, sieht also alle Cluster.],
  [Alertmanager], [Bündelt, sortiert, unterdrückt und verschickt Alarme.],
  [Mailpit], [Fängt im Labor alle Mails ab. Später ersetzt du es durch einen echten Mailserver.],
  [healthchecks.io], [Dead Man's Switch: schlägt Alarm, wenn der Alertmanager sich *nicht* mehr meldet.],
)

#warum[
  Prometheus auf obs hält nur sechs Stunden Daten von `obs` selbst. Eine Regel wie „Node-Speicher in app1 fast voll“ kann er nicht auswerten, denn die Daten von app1 liegen in Thanos Receive. Der Thanos Ruler stellt dieselbe Frage an Thanos Query und bekommt die Antwort aus allen Clustern. Deshalb leben die globalen Regeln dort.
]

== Mailpit als Test-Empfänger

Mailpit ist ein kleiner SMTP-Server mit Weboberfläche. Er nimmt jede Mail an und stellt keine einzige zu. Ideal, um Routing zu testen, ohne Postfächer zu fluten.

Die Datei `observability/central/mailpit/mailpit.yaml` enthält ein Deployment mit dem Image `axllent/mailpit:v1.33.1` und einen Service `mailpit` mit den Ports 1025 (SMTP) und 8025 (Oberfläche und API). Der Container läuft ohne Root und mit schreibgeschütztem Dateisystem, `MP_MAX_MESSAGES` löscht alte Mails.

#cmd("Mac")[```bash
kubectl --context obs apply -f observability/central/mailpit/
kubectl --context obs -n monitoring rollout status deploy/mailpit
```][Startet Mailpit und wartet, bis es bereit ist.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring port-forward svc/mailpit 8025:8025
```][Läuft im Vordergrund weiter. Öffne ein zweites Terminal für die nächsten Schritte. Die Oberfläche erreichst du jetzt unter #link("http://localhost:8025").]

#pruefe[
  Mailpit zeigt einen leeren Posteingang.
]

== Der Dead Man's Switch

Was passiert, wenn der Alertmanager selbst ausfällt, oder der ganze Cluster obs? Dann kommt keine Mail, und Stille sieht aus wie „alles gut“. Dagegen hilft ein Alarm, der *immer* feuert: `Watchdog` aus den Standardregeln des Charts. Der Alertmanager schickt ihn jede Minute an einen Dienst außerhalb des Labors. Bleibt das Signal aus, schlägt dieser Dienst Alarm.

Lege bei #link("https://healthchecks.io")[healthchecks.io] ein kostenloses Konto und einen Check an. Stell *Period* auf 5 Minuten und *Grace* auf 5 Minuten, und hinterlege dort deine echte Mail-Adresse oder dein Handy. Kopiere die Ping-URL des Checks, sie sieht aus wie `https://hc-ping.com/<uuid>`.

#cmd("Mac")[```bash
read -rs HC_URL
```][Liest die URL ein, ohne sie anzuzeigen. Füge sie ein und drücke Enter. Die URL ist ein Geheimnis: Wer sie kennt, kann deinen Check grün halten.]

#cmd("Mac")[```bash
printf '%s' "$HC_URL" | kubectl --context obs -n monitoring \
  create secret generic alertmanager-deadmansswitch --from-file=url=/dev/stdin
unset HC_URL
```][Legt das Secret mit dem Schlüssel `url` an. Der Wert läuft über die Standardeingabe und taucht nicht in der Prozessliste auf.]

#falle[
  Das Secret muss existieren, bevor du gleich `helm upgrade` ausführst. Der Alertmanager-Pod hängt es als Datei ein. Fehlt es, bleibt der Pod in `ContainerCreating` hängen, und `kubectl describe pod` meldet `secret "alertmanager-deadmansswitch" not found`.
]

== Die Alertmanager-Konfiguration

Die Konfiguration steht in `observability/central/kps/alerting.yaml` unter `alertmanager.config`. Das Herz ist der Routing-Baum.

#datei("observability/central/kps/alerting.yaml (Ausschnitt: route)", ```yaml
    route:
      receiver: plattform
      group_by: [cluster, alertname]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      routes:
        - receiver: deadmansswitch
          matchers:
            - alertname = "Watchdog"
          group_wait: 0s
          group_interval: 1m
          repeat_interval: 1m
        - receiver: "null"
          matchers:
            - alertname = "InfoInhibitor"
        - receiver: "null"
          matchers:
            - severity = "info"
        - receiver: plattform
          matchers:
            - cluster = "obs"
          routes:
            - receiver: plattform-kritisch
              matchers:
                - severity = "critical"
              group_wait: 10s
              repeat_interval: 1h
        - receiver: apps
          matchers:
            - cluster =~ "app1|app2"
          routes:
            - receiver: apps-kritisch
              matchers:
                - severity = "critical"
              group_wait: 10s
              repeat_interval: 1h
```, erklaerung: [
  Der Alertmanager geht die Routen von oben nach unten durch und nimmt die erste, die passt. Unterrouten erben alle Werte, die sie nicht selbst setzen.
])

#tabelle(
  (auto, 1fr),
  ([Einstellung], [Bedeutung]),
  [`group_by: [cluster, alertname]`], [Eine Mail pro Cluster und Alarmname. Ohne `cluster` stünden `app1` und `app2` in derselben Mail, und eine Silence für einen Cluster träfe beide.],
  [`group_wait`, `group_interval`], [Wartezeit vor der ersten Mail einer Gruppe, und Abstand, wenn neue Alarme in die Gruppe kommen.],
  [`repeat_interval`], [Nach dieser Zeit kommt eine Erinnerung, solange der Alarm feuert. Kritisch jede Stunde, sonst alle vier.],
  [Watchdog-Route], [So oft wie möglich, damit healthchecks.io jede Minute ein Lebenszeichen bekommt.],
  [`severity = "info"`], [Info-Alarme siehst du in der Oberfläche, aber sie wecken niemanden.],
)

Die Empfänger dazu sind kurz. Die Mails gehen über `mailpit.monitoring.svc:1025`, eingestellt unter `global` mit `smtp_smarthost` und `smtp_require_tls: false`.

#datei("observability/central/kps/alerting.yaml (Ausschnitt: receivers)", ```yaml
    receivers:
      - name: "null"
      - name: deadmansswitch
        webhook_configs:
          - url_file: /etc/alertmanager/secrets/alertmanager-deadmansswitch/url
            send_resolved: false
      - name: apps-kritisch
        email_configs:
          - to: apps@obs.internal, bereitschaft@obs.internal
            send_resolved: true
```, erklaerung: [
  `url_file` liest die URL aus der Datei, die `alertmanagerSpec.secrets` aus dem Secret einhängt. So steht sie weder im Repo noch in der Helm-Release. Die übrigen Empfänger `plattform`, `plattform-kritisch` und `apps` sind genauso gebaut. Die Adressen gibt es nicht, Mailpit nimmt sie trotzdem an.
])

=== Folgealarme unterdrücken

Fällt ein ganzer Cluster aus, fallen dessen Dienste mit aus. Du willst dann eine Mail „Cluster weg“ und nicht zwanzig über einzelne Pods. Das erledigen Inhibit-Regeln: Solange ein Quell-Alarm feuert, werden passende Ziel-Alarme stumm geschaltet.

#datei("observability/central/kps/alerting.yaml (Ausschnitt: inhibit_rules)", ```yaml
    inhibit_rules:
      - source_matchers:
          - alertname = "ClusterSchweigt"
        target_matchers:
          - alertname != "ClusterSchweigt"
        equal: [cluster]
      - source_matchers:
          - severity = "critical"
        target_matchers:
          - severity =~ "warning|info"
        equal: [cluster, namespace, alertname]
```, erklaerung: [
  `equal: [cluster]` ist entscheidend: Nur Alarme mit *demselben* Wert für `cluster` werden unterdrückt. Ohne diese Zeile würde ein Ausfall von app2 auch alle Alarme aus app1 und obs verschlucken. Die zweite Regel stammt aus den Standardwerten des Charts, hier ergänzt um `cluster`.
])

#falle[
  Helm führt Werte-Dateien zusammen, aber nur Maps, keine Listen. Setzt du `inhibit_rules` in deiner Datei, ersetzt sie die Liste des Charts komplett. Deshalb stehen in `alerting.yaml` auch die drei übrigen Standardregeln, jeweils mit `cluster` in `equal`. Dasselbe gilt für `routes` und `receivers`.
]

=== Der Thanos Ruler

Den Ruler hat Kapitel 4 schon eingeschaltet: `values.yaml` wählt Regeln mit `auswertung: global`, setzt `queryEndpoints` auf Thanos Query und wertet alle 30 Sekunden aus. Es fehlt noch, wohin er Alarme schickt.

#datei("observability/central/kps/alerting.yaml (Ausschnitt: thanosRuler)", ```yaml
thanosRuler:
  thanosRulerSpec:
    ruleSelectorNilUsesHelmValues: false
    ruleSelector:
      matchLabels:
        auswertung: global
    objectStorageConfig:
      existingSecret:
        name: thanos-objstore
        key: objstore.yml
    alertmanagersConfig:
      secret:
        alertmanagers:
          - api_version: v2
            scheme: http
            static_configs:
              - alertmanager-operated.monitoring.svc:9093
```, erklaerung: [
  `alertmanagersConfig` schickt die Alarme an den Alertmanager. Ohne diesen Block wertet der Ruler zwar aus, aber niemand erfährt davon. `objectStorageConfig` lädt die Blöcke des Rulers alle zwei Stunden in den Bucket `thanos`, so bleibt der Alarmverlauf länger als die 24 Stunden lokaler Retention erhalten. `ruleSelectorNilUsesHelmValues: false` verhindert, dass das Chart zusätzlich nach dem Label `release: kps` filtert.
])

Die Alarme, die der Ruler erzeugt, speichert er als Serie `ALERTS` in seiner eigenen kleinen TSDB. Damit Grafana sie über Thanos Query findet, hat Kapitel 4 den Ruler bereits als Endpunkt von `thanos-query` eingetragen, mit `thanos_ruler_replica` als Replika-Label.

== Ausrollen

#cmd("Mac")[```bash
helm --kube-context obs upgrade kps \
  prometheus-community/kube-prometheus-stack \
  --version 92.18.0 -n monitoring \
  -f observability/central/kps/values.yaml \
  -f observability/central/kps/grafana.yaml \
  -f observability/central/kps/alerting.yaml \
  --wait --timeout 10m
```][Ab jetzt immer mit allen drei Dateien. Der Operator schreibt die Konfiguration in ein Secret, der Alertmanager lädt sie ohne Neustart.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring get pods \
  -l 'app.kubernetes.io/name in (alertmanager,thanos-ruler)'
```][Zeigt die Pods von Alertmanager und Thanos Ruler.]

#pruefe[
  Zwei Pods, beide `Running`: `alertmanager-kps-kube-prometheus-stack-alertmanager-0` mit `2/2` Containern und `thanos-ruler-kps-kube-prometheus-stack-thanos-ruler-0`, ebenfalls mit `2/2`. Der zweite Container ist jeweils der Config-Reloader.
]

Nach ein bis zwei Minuten wird der Check bei healthchecks.io grün. Der Watchdog kommt an.

#falle[
  Mailpit füllt sich möglicherweise sofort mit Alarmen von `obs`. Das sind Standardregeln des Charts, die auf k3s nicht passen, etwa für Komponenten, die k3s im Hauptprozess betreibt. Kapitel 4 hat die bekannten Fälle abgeschaltet. Taucht trotzdem einer auf, schalte die Regel in `values.yaml` unter `defaultRules.disabled` mit ihrem Namen ab, etwa `KubeProxyDown: true`, statt sie dauerhaft stummzuschalten.
]

== Globale Regeln

Die Regeln liegen in `observability/rules/`, eine Datei pro Thema. Die wichtigste prüft, ob ein Cluster überhaupt noch Daten schickt.

#datei("observability/rules/cluster.yaml (Ausschnitt)", ```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: global-cluster
  namespace: monitoring
  labels:
    auswertung: global
spec:
  groups:
    - name: cluster
      rules:
        - alert: ClusterSchweigt
          expr: |
            group by (cluster) (max_over_time(up{cluster!=""}[6h]))
            unless
            group by (cluster) (up{cluster!=""})
          for: 3m
          labels:
            severity: critical
          annotations:
            summary: "Cluster {{ $labels.cluster }} liefert keine Metriken mehr"
            runbook_url: https://github.com/thomaszachmann/k3s/blob/main/
              observability/rules/runbooks.md#clusterschweigt
```, erklaerung: [
  Die erste Hälfte liefert jeden Cluster, der in den letzten sechs Stunden irgendeine `up`-Serie hatte. `unless` entfernt alle, die *jetzt* noch eine haben. Übrig bleiben die Cluster, die verstummt sind. Das funktioniert für jeden neuen Cluster ohne Änderung an der Regel. Die Grenze: Schweigt ein Cluster länger als sechs Stunden, fällt er aus dem Fenster, und der Alarm endet von selbst. Die `runbook_url` steht in der Datei in einer Zeile, hier ist sie nur umbrochen.
])

#tabelle(
  (auto, auto, auto, 1fr),
  ([Datei], [Alarm], [Schwere], [Bedingung]),
  [`cluster.yaml`], [`ClusterSchweigt`], [critical], [keine `up`-Serie mehr seit 3 Minuten],
  [`knoten.yaml`], [`NodeSpeicherKnapp`], [warning], [RAM über 90 % für 10 Minuten],
  [], [`NodeSpeicherKritisch`], [critical], [RAM über 97 % für 5 Minuten],
  [], [`NodeDiskKnapp`], [warning], [weniger als 15 % frei auf `/`],
  [`workloads.yaml`], [`PodCrashLoop`], [warning], [Container 10 Minuten in `CrashLoopBackOff`],
  [], [`DeploymentUnvollstaendig`], [warning], [weniger bereite als gewünschte Replikas für 15 Minuten],
  [`thanos.yaml`], [`ReceiveFehler`], [critical], [über 5 % der Schreibanfragen mit 5xx],
  [], [`ReceiveLehntAb`], [warning], [über 5 % mit 4xx, etwa 409 oder 429],
  [], [`ReceiveUploadFehler`], [warning], [Block-Upload ins S3 gescheitert],
  [], [`CompactorAngehalten`], [critical], [`thanos_compact_halted` ist 1],
)

Jeder Alarm hat eine Annotation `runbook_url`. Sie zeigt auf einen Abschnitt in `observability/rules/runbooks.md`: Was bedeutet der Alarm, was prüfst du zuerst, wie behebst du es. Der Link steht in jeder Mail und in der Oberfläche des Alertmanagers. Ein Alarm ohne Runbook ist um drei Uhr nachts nur halb so viel wert.

#cmd("Mac")[```bash
kubectl --context obs apply -f observability/rules/
```][`kubectl` überspringt `runbooks.md`, weil es nur `.yaml`, `.yml` und `.json` liest. Prometheus auf obs ignoriert die Regeln, weil er nur `auswertung: lokal` auswählt.]

#cmd("Mac")[```bash
kubectl --context obs get --raw \
  "/api/v1/namespaces/monitoring/services/thanos-ruler-operated:web/proxy/api/v1/rules" \
  | jq -r '.data.groups[].rules[] | "\(.name)\t\(.health)\t\(.state)"'
```][Fragt die Regel-API des Rulers über den Service-Proxy des API-Servers ab. Das spart ein `port-forward`.]

#pruefe[
  Zehn Zeilen, jede mit `ok` als Gesundheit und meist `inactive` als Zustand. Steht dort `err`, zeigt `.lastError` in derselben Antwort den Grund, oft ein Tippfehler im Ausdruck oder Thanos Query nicht erreichbar. Fehlt eine Regel ganz, prüfe das Label `auswertung: global`.
]

== Ein Alarm von Anfang bis Ende

Jetzt löst du absichtlich einen Alarm aus: Du nimmst Alloy in app2 vom Netz. Ein DaemonSet lässt sich nicht auf null skalieren, also gibst du ihm einen `nodeSelector`, den kein Node erfüllt.

#cmd("Mac")[```bash
kubectl --context app2 -n monitoring patch daemonset alloy --type merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"obs-pause":"true"}}}}}'
```][Der Alloy-Pod in app2 wird beendet und nicht neu gestartet. app2 schickt keine Metriken mehr.]

Mit `kubectl --context app2 -n monitoring get daemonset alloy` siehst du, dass `DESIRED` und `CURRENT` auf `0` stehen.

Jetzt heißt es warten. Die Zeiten sind geschätzt:

#tabelle(
  (auto, 1fr),
  ([Nach etwa], [Was passiert]),
  [0 Minuten], [Alloy ist weg. Die letzten Proben von app2 liegen in Thanos Receive.],
  [5 Minuten], [Die letzten Proben sind älter als das Lookback-Fenster von Abfragen. `up{cluster="app2"}` liefert nichts mehr.],
  [5,5 Minuten], [Bei der nächsten Auswertung (alle 30 Sekunden) sieht der Ruler die Bedingung erfüllt. `ClusterSchweigt` steht auf `pending`.],
  [8,5 Minuten], [Nach `for: 3m` wechselt der Alarm auf `firing` und geht an den Alertmanager.],
  [8,5 Minuten und 10 Sekunden], [Nach `group_wait` verschickt der Alertmanager die Mail.],
)

In Grafana kannst du zusehen: *Explore* mit Thanos und `count by (cluster) (up)` zeigt app2 ab etwa Minute fünf nicht mehr. Unter *Alerting → Alert rules* siehst du mit der Datenquelle Thanos die Regeln des Rulers mit ihrem Zustand.

Den Alertmanager fragst du über seinen Ingress ab. Er ist per Basic Auth geschützt, du nutzt den Benutzer `obs` aus Kapitel 5.

#cmd("Mac")[```bash
AM_PW=$(kubectl --context obs -n monitoring get secret obs-remote-auth \
  -o jsonpath='{.data.password}' | base64 -d)
```][Liest das Passwort für den Benutzer `obs` in eine Variable.]

#cmd("Mac")[```bash
curl -s --cacert observability/tls/ca.crt -u "obs:$AM_PW" \
  https://alertmanager.obs.internal/api/v2/alerts \
  | jq -r '.[] | "\(.labels.alertname)\t\(.labels.cluster)\t\(.labels.severity)\t\(.status.state)"'
```][Listet alle Alarme, die der Alertmanager gerade kennt, mit Cluster, Schwere und Zustand.]

#pruefe[
  Eine Zeile `ClusterSchweigt app2 critical active`, dazu `Watchdog obs none active`. Der Zustand `active` heißt: weder stumm geschaltet noch unterdrückt. Folgealarme aus app2 hätten hier `suppressed`.
]

#cmd("Mac")[```bash
kubectl --context obs get --raw \
  "/api/v1/namespaces/monitoring/services/mailpit:http/proxy/api/v1/messages" \
  | jq -r '.messages[] | "\(.Subject)  ->  \([.To[].Address] | join(", "))"'
```][Fragt die API von Mailpit ab, wieder über den Service-Proxy.]

#pruefe[
  Eine Mail mit einem Betreff wie `[FIRING:1] ClusterSchweigt app2 (critical)` an `apps@obs.internal, bereitschaft@obs.internal`. Die Route `cluster =~ "app1|app2"` und darunter `severity = "critical"` haben gegriffen. In der Oberfläche unter #link("http://localhost:8025") siehst du die ganze Mail mit dem Runbook-Link.
]

Jetzt holst du Alloy zurück. Der Patch entfernt genau den Schlüssel, den du eben gesetzt hast.

#cmd("Mac")[```bash
kubectl --context app2 -n monitoring patch daemonset alloy --type json \
  -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector/obs-pause"}]'
```][Alloy startet wieder und schickt Metriken, auch die gepufferten aus seinem WAL, soweit es welche hat.]

#pruefe[
  Nach zwei bis drei Minuten liegt in Mailpit eine zweite Mail mit `[RESOLVED]` im Betreff. Das bewirkt `send_resolved: true`.
]

== Stummschalten ohne amtool

Planst du Wartung, willst du keine Alarme. Dafür gibt es Silences: Sie schalten alle Alarme stumm, deren Labels zu den Matchern passen. Den Alertmanager-Befehl `amtool` brauchst du dafür nicht. Es gibt drei Wege: die Oberfläche unter #link("https://alertmanager.obs.internal") (Schaltfläche *New Silence*), Grafana unter *Alerting → Silences* mit der Datenquelle Alertmanager, und die HTTP-API. Die API ist der Weg, den du in Skripte einbauen kannst.

Zum Üben brauchst du einen Alarm. Den schickst du selbst an die API, so wie es der Ruler tut:

#cmd("Mac")[```bash
jq -n '[{labels: {alertname: "Testalarm", cluster: "app1",
  severity: "warning"}, annotations: {summary: "Nur ein Test"}}]' \
  | curl -s --cacert observability/tls/ca.crt -u "obs:$AM_PW" \
    -H 'Content-Type: application/json' -d @- \
    https://alertmanager.obs.internal/api/v2/alerts
```][Legt einen Alarm an. Ohne `endsAt` gilt er nach `resolve_timeout` (fünf Minuten) als erledigt, wenn ihn niemand erneut schickt.]

#cmd("Mac")[```bash
jq -n --arg start "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg ende "$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ)" \
  '{matchers: [{name: "cluster", value: "app1", isRegex: false, isEqual: true}],
    startsAt: $start, endsAt: $ende, createdBy: "thomas",
    comment: "Wartung app1, Übung Kapitel 7"}' \
  | curl -s --cacert observability/tls/ca.crt -u "obs:$AM_PW" \
    -H 'Content-Type: application/json' -d @- \
    https://alertmanager.obs.internal/api/v2/silences
```][Schaltet für eine Stunde alles mit `cluster="app1"` stumm. `date -v+1H` ist die macOS-Schreibweise, unter Linux hieße es `date -u -d '+1 hour' ...`. Die Antwort enthält die `silenceID`.]

#cmd("Mac")[```bash
curl -s --cacert observability/tls/ca.crt -u "obs:$AM_PW" \
  https://alertmanager.obs.internal/api/v2/alerts \
  | jq -r '.[] | select(.labels.alertname=="Testalarm")
      | "\(.status.state) \(.status.silencedBy)"'
```][Zeigt, ob der Testalarm stumm ist und durch welche Silence.]

#pruefe[
  `suppressed` und eine Liste mit der ID deiner Silence. In Mailpit kommt keine Mail für `Testalarm` an.
]

Alle Silences liefert `GET /api/v2/silences`. Mit `curl -X DELETE .../api/v2/silence/<id>` beendest du eine vorzeitig, beachte das Singular `silence` im Pfad.

#falle[
  Eine Silence auf `cluster="app1"` verschluckt *alles* aus app1, auch einen echten Ausfall während der Wartung. Gib deshalb immer ein Ende an und halte Silences so eng wie möglich, etwa mit einem zusätzlichen Matcher auf `alertname` oder `namespace`.
]

#cmd("Mac")[```bash
unset AM_PW
```][Entfernt das Passwort aus der Shell.]

#aufgabe[
  Prüfe die Inhibit-Regel selbst. Schicke wie oben zwei Alarme gleichzeitig an die API: `ClusterSchweigt` mit `cluster: "app2"` und `severity: "critical"`, dazu `Testalarm` mit `cluster: "app2"`. Welcher Zustand steht beim Testalarm, und was steht in `.status.inhibitedBy`? Wiederhole es mit `cluster: "app1"` beim Testalarm. Warum wird er jetzt zugestellt?
]

#gelernt(
  [Globale Regeln gehören in den Thanos Ruler, weil nur er über Thanos Query alle Cluster sieht.],
  [`group_by` und `equal` brauchen das Label `cluster`, sonst vermischen sich Alarme verschiedener Cluster.],
  [Inhibit-Regeln machen aus einem Clusterausfall eine Mail statt zwanzig.],
  [Ein Watchdog mit Dead Man's Switch meldet, wenn die Alarmkette selbst ausfällt. Die URL gehört in ein Secret.],
  [Silences legst du über Oberfläche oder API an, immer mit Ende und so eng wie möglich.],
)

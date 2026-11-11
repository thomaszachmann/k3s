#import "../lib.typ": *

#kapitel(
  [Grafana als Code],
  ziel: [Grafana startet mit Datenquellen, Ordnern und Login aus dem Repo. Nichts, was zählt, entsteht durch Klicks in der Oberfläche.],
  zeit: [45 Minuten],
  braucht: [Kapitel 4 und 5: kube-prometheus-stack läuft auf obs, Thanos Query kennt alle drei Cluster],
)

== Warum keine Klicks

Grafana lädt zum Klicken ein. Eine Datenquelle ist schnell angelegt, ein Panel schnell gebaut. Nach drei Monaten weiß niemand mehr, wer was geändert hat, und nach einem Neuaufbau ist alles weg. Deshalb gilt in diesem Buch eine Regel: *Die Quelle der Wahrheit ist das Repo.* Die Oberfläche ist zum Lesen und Ausprobieren da.

#tabelle(
  (2.9cm, 6.2cm, 1fr),
  ([Was], [Wo im Repo], [Wie es in Grafana landet]),
  [Login, Ingress, Sidecars], [`observability/central/kps/grafana.yaml`], [Helm-Werte für `kps`],
  [Admin-Passwort], [nirgends], [Secret `grafana-admin`, erzeugt mit `openssl rand`],
  [Datenquellen], [`observability/grafana/datasources/`], [ConfigMaps mit Label `grafana_datasource: "1"`],
  [Dashboards], [`observability/dashboards/`], [ConfigMaps mit Label `grafana_dashboard: "1"` (Kapitel 10)],
)

Im Grafana-Pod laufen neben Grafana zwei kleine Sidecar-Container. Sie beobachten die Kubernetes-API und schreiben jede passende ConfigMap als Datei in Grafanas Provisioning-Verzeichnis. Grafana liest diese Dateien und lädt sie neu. Du legst also nur ConfigMaps an, den Rest erledigen die Sidecars.

#warum[
  Grafana braucht so keinen eigenen Speicher. Fällt der Pod aus oder ziehst du auf einen neuen Cluster um, startet Grafana leer und baut sich aus den ConfigMaps in Sekunden wieder auf. Das spart ein PVC und eine Backup-Aufgabe in Kapitel 12.
]

== Das Admin-Passwort

Grafana hat einen lokalen Administrator. Sein Passwort gehört in ein Secret, nicht in die Werte-Datei.

#cmd("Mac")[```bash
kubectl --context obs -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -hex 20)"
```][Erzeugt ein zufälliges Passwort mit 40 Hex-Zeichen und legt es direkt im Cluster ab. Es erscheint weder auf dem Bildschirm noch in einer Datei.]

#falle[
  Grafana übernimmt das Passwort nur beim allerersten Start in seine Datenbank. Ohne PVC ist das bei jedem Neustart so, deshalb wirkt eine Änderung am Secret nach `kubectl rollout restart`. Mit PVC müsstest du das Passwort zusätzlich mit `grafana cli admin reset-admin-password` ändern.
]

== Die Helm-Werte

Die Grafana-Werte liegen in einer eigenen Datei. So bleibt `values.yaml` aus Kapitel 4 übersichtlich, und du siehst auf einen Blick, was Grafana betrifft.

#datei("observability/central/kps/grafana.yaml (Ausschnitt)", ```yaml
grafana:
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
  persistence:
    enabled: false
  ingress:
    enabled: true
    ingressClassName: traefik
    annotations:
      traefik.ingress.kubernetes.io/router.entrypoints: websecure
      traefik.ingress.kubernetes.io/router.tls: "true"
    hosts:
      - grafana.obs.internal
    tls:
      - secretName: obs-tls
        hosts:
          - grafana.obs.internal
  grafana.ini:
    server:
      root_url: https://grafana.obs.internal
    users:
      allow_sign_up: false
  sidecar:
    dashboards:
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: ALL
      folderAnnotation: grafana_folder
      annotations:
        grafana_folder: Kubernetes
      multicluster:
        global:
          enabled: true
      provider:
        foldersFromFilesStructure: true
        allowUiUpdates: false
    datasources:
      label: grafana_datasource
      labelValue: "1"
      defaultDatasourceEnabled: true
      isDefaultDatasource: false
      alertmanager:
        enabled: false
```, erklaerung: [
  Die Datei enthält zusätzlich Ressourcen-Grenzen und Analytics-Schalter. Die wichtigen Stellen:
])

#tabelle(
  (auto, 1fr),
  ([Schlüssel], [Wirkung]),
  [`admin.existingSecret`], [Login aus dem Secret `grafana-admin`],
  [`persistence.enabled: false`], [Keine Datenbank auf Disk, alles kommt aus ConfigMaps],
  [`ingress`], [Traefik liefert Grafana unter `https://grafana.obs.internal` mit dem Zertifikat aus `obs-tls` aus],
  [`folderAnnotation`], [Die Annotation `grafana_folder` an einer ConfigMap bestimmt den Ordner in Grafana],
  [`annotations`], [Die rund 30 mitgelieferten Dashboards des Charts landen im Ordner `Kubernetes`],
  [`multicluster.global.enabled`], [Die mitgelieferten Dashboards zeigen die Auswahl `cluster` an, sonst ist sie versteckt],
  [`allowUiUpdates: false`], [Dashboards aus ConfigMaps lassen sich in der UI nicht überschreiben],
  [`isDefaultDatasource: false`], [Die lokale Prometheus-Datenquelle bleibt, Standard wird Thanos],
  [`alertmanager.enabled: false`], [Die Alertmanager-Datenquelle kommt aus dem Repo statt vom Chart],
)

#falle[
  `foldersFromFilesStructure` und `folderAnnotation` gehören zusammen. Setzt du nur die Annotation, landen trotzdem alle Dashboards im Ordner *Dashboards*, denn Grafana übernimmt die Ordnerstruktur der Sidecar-Dateien nur mit diesem Schalter.
]

== Datenquellen als ConfigMap

Eine Datenquelle ist eine kleine YAML-Datei im Provisioning-Format von Grafana, verpackt in eine ConfigMap.

#datei("observability/grafana/datasources/thanos.yaml", ```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-ds-thanos
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  thanos.yaml: |
    apiVersion: 1
    datasources:
      - name: Thanos
        uid: thanos
        type: prometheus
        access: proxy
        url: http://thanos-query.monitoring.svc:10902
        isDefault: true
        editable: false
        jsonData:
          prometheusType: Thanos
          httpMethod: POST
          timeInterval: 30s
          exemplarTraceIdDestinations:
            - name: traceID
              datasourceUid: tempo
```, erklaerung: [
  Thanos Query spricht die Prometheus-API, deshalb ist der Typ `prometheus`. `prometheusType: Thanos` schaltet in Grafana die passenden Abfrage-Optionen frei. `timeInterval` sagt Grafana, wie dicht die Daten liegen, damit `$__rate_interval` nie kürzer als zwei Proben wird. Die feste `uid: thanos` brauchst du für Links zwischen Datenquellen: `exemplarTraceIdDestinations` führt von einem Exemplar mit dem Label `traceID` zum Trace in Tempo, das in Kapitel 9 dazukommt. Bis dahin ist der Eintrag einfach ohne Wirkung.
])

Daneben liegt `alertmanager.yaml`. Sie zeigt auf `http://alertmanager-operated.monitoring.svc:9093`, den Service, den der Prometheus Operator für jeden Alertmanager anlegt. Damit siehst du in Kapitel 7 Alarme und Silences auch in Grafana. Die Datenquellen für Loki und Tempo kommen in Kapitel 8 und 9 ins selbe Verzeichnis.

#cmd("Mac")[```bash
kubectl --context obs apply \
  -f observability/grafana/datasources/thanos.yaml \
  -f observability/grafana/datasources/alertmanager.yaml
```][Legt beide ConfigMaps an. Die Dateien für Loki und Tempo liegen schon im Verzeichnis, sie kommen erst in Kapitel 8 und 9 dran. Der Sidecar bemerkt sie sofort und lässt Grafana die Datenquellen neu laden. Grafana selbst läuft vielleicht noch mit alten Werten, das ändert der nächste Schritt.]

== Grafana neu ausrollen

#cmd("Mac")[```bash
helm --kube-context obs upgrade kps \
  prometheus-community/kube-prometheus-stack \
  --version 92.18.0 -n monitoring \
  -f observability/central/kps/values.yaml \
  -f observability/central/kps/grafana.yaml \
  --wait --timeout 10m
```][Spätere Dateien überschreiben frühere. Ab Kapitel 7 kommt `alerting.yaml` als dritte Datei dazu. Lass nie eine Datei weg, sonst setzt Helm deren Werte auf die Standardwerte zurück.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring rollout status deploy/kps-grafana
```][Wartet, bis der neue Grafana-Pod bereit ist.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring logs deploy/kps-grafana \
  -c grafana-sc-datasources --tail=20
```][Zeigt das Protokoll des Datenquellen-Sidecars. Der Containername `grafana-sc-datasources` stammt aus dem Grafana-Chart.]

#pruefe[
  Zeilen, in denen der Sidecar `thanos.yaml` und `alertmanager.yaml` nach `/etc/grafana/provisioning/datasources/` schreibt, außerdem `datasource.yaml`, die Datei des Charts für die lokale Prometheus-Datenquelle. Danach ruft er Grafana auf:
  ```
  "msg": "None sent to http://localhost:3000/api/admin/provisioning/datasources/reload.
          Response: 200 OK {\"message\":\"Datasources config reloaded\"}"
  ```
  Davor stehen oft einige `WARNING ... Retrying`-Zeilen. Der Sidecar startet schneller als Grafana und versucht es einfach erneut, das ist harmlos.
]

== Der erste Login

Die Namen unter `obs.internal` hast du in Kapitel 2 in `/etc/hosts` eingetragen, die CA kennt dein Browser, wenn du sie im Schlüsselbund als vertrauenswürdig markiert hast.

#cmd("Mac")[```bash
kubectl --context obs -n monitoring get secret grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d | pbcopy
```][Kopiert das Passwort in die Zwischenablage, ohne es anzuzeigen. Öffne dann #link("https://grafana.obs.internal") und melde dich als `admin` an.]

#bild("bilder/06-grafana-login.png", [Die Anmeldeseite von Grafana: oben `admin` eintragen, darunter das Passwort mit `Cmd-V` einfügen, dann *Log in*.], breite: 80%)

Zeigt der Browser stattdessen eine Zertifikatswarnung, vertraut er deiner CA noch nicht. Hol den optionalen Schritt mit dem Schlüsselbund aus Kapitel 2 nach und lade die Seite neu.

Dieselbe Prüfung geht ohne Browser über die HTTP-API von Grafana:

#cmd("Mac")[```bash
GF_PW=$(kubectl --context obs -n monitoring get secret grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d)
```][Legt das Passwort nur in einer Shell-Variable ab.]

#cmd("Mac")[```bash
curl -s --cacert observability/tls/ca.crt -u "admin:$GF_PW" \
  https://grafana.obs.internal/api/datasources \
  | jq -r '.[] | "\(.name)\t\(.type)\tStandard=\(.isDefault)"'
```][Listet alle Datenquellen. `--cacert` prüft das Zertifikat gegen deine eigene CA, statt die Prüfung mit `-k` abzuschalten.]

#pruefe[
  Drei Zeilen, alphabetisch sortiert:
  ```
  Alertmanager  alertmanager  Standard=false
  Prometheus    prometheus    Standard=false
  Thanos        prometheus    Standard=true
  ```
  Unter *Dashboards* gibt es den Ordner *Kubernetes*.
]

In der Oberfläche findest du dieselbe Liste im Menü links unter *Connections → Data sources*:

#bild("bilder/06-grafana-datenquellen.png", [*Connections → Data sources*: Thanos trägt das Etikett `default`. Klickst du eine Datenquelle an, steht oben der Hinweis, dass sie per Provisioning angelegt wurde und sich nicht bearbeiten lässt.])

#cmd("Mac")[```bash
unset GF_PW
```][Entfernt das Passwort aus der Shell.]

== Eine Abfrage über alle Cluster

Klicke im Menü links auf *Explore*. Oben links wählst du die Datenquelle, darunter liegt das Eingabefeld für die Abfrage. Steht dort ein Schalter *Builder* und *Code*, wähle *Code*, dann kannst du PromQL direkt tippen. Wähle *Thanos*, gib diese Abfrage ein und drücke `Shift-Enter` oder den blauen Knopf oben rechts:

```promql
count by (cluster) (up)
```

#bild("bilder/06-grafana-explore.png", [*Explore*: Datenquelle und Eingabefeld sind rot markiert. Der Graph zeigt eine Linie pro Cluster, die Tabelle darunter den aktuellen Wert.])

#pruefe[
  Drei Zeilen: `obs`, `app1` und `app2`, jeweils mit der Zahl der Scrape-Targets. Fehlt ein Cluster, liegt das Problem vor Grafana. Prüfe dann zuerst Kapitel 5.
]

Wechselst du auf die Datenquelle *Prometheus*, siehst du nur `obs`. Das ist der lokale Prometheus mit seinen sechs Stunden Daten. Er ist praktisch, wenn du wissen willst, ob ein Fehler im Remote Write oder in Thanos liegt.

Öffne nun über *Dashboards* den Ordner *Kubernetes* und darin das Dashboard *Kubernetes / Compute Resources / Cluster*. Oben findest du die Auswahl *cluster*. Stell sie auf `app1`.

#bild("bilder/06-grafana-dashboard-cluster.png", [Die Auswahl *cluster* ist rot markiert. Für `app1` bleiben die oberen Kacheln und *CPU Usage* leer, *CPU Quota* und *Memory* zeigen Daten.])

Die leeren Panels sind kein Fehler deines Aufbaus. Sie nutzen Aufnahmeregeln, die nur der Prometheus auf obs auswertet, also nur für `cluster="obs"`. Wie die eigenen Dashboards das vermeiden, steht in Kapitel 10.

== Ändern, ohne zu klicken

Du willst ein Dashboard anpassen? Der Weg ist immer derselbe:

+ In Grafana das Dashboard öffnen, *Edit* wählen und so lange ändern, bis es passt.
+ Speichern geht nicht. Wähle stattdessen *Export → Export as JSON* und kopiere das JSON.
+ Ersetze die Datei unter `observability/dashboards/` und prüfe sie mit `jq empty`.
+ Mit `git diff` die Änderung ansehen, mit `kubectl apply -k` ausrollen, committen.

#falle[
  Schalte beim Export *Export for sharing externally* nicht ein. Diese Variante ersetzt die Datenquellen durch Platzhalter wie `${DS_THANOS}` und legt einen Block `__inputs` an. Den füllt nur der Import-Dialog aus, der Sidecar nicht. Das Dashboard zeigt dann überall „Datasource not found“. Die eigenen Dashboards nutzen stattdessen eine Variable `datasource`, die beim Laden die Standard-Datenquelle wählt.
]

Bei Datenquellen ist es noch einfacher: Datei ändern, `kubectl apply -f`, fertig. Der Sidecar lädt neu, ein Neustart ist nicht nötig.

#aufgabe[
  Lege in `observability/grafana/datasources/` eine dritte Datenquelle `Thanos (roh)` an, die auf denselben Dienst zeigt, aber in `jsonData` den Eintrag `customQueryParameters: "dedup=false"` setzt. Mit ihr siehst du die Daten vor der Deduplizierung. Wende sie an und prüfe mit der API-Abfrage von oben, ob sie erscheint. Was passiert, wenn du in der neuen Datei aus Versehen auch `isDefault: true` setzt? Schau ins Log des Containers `grafana`.
]

#gelernt(
  [Grafana braucht keinen eigenen Speicher, wenn alles aus ConfigMaps kommt.],
  [Sidecars machen aus ConfigMaps mit einem bestimmten Label Datenquellen und Dashboards.],
  [Die Annotation `grafana_folder` sortiert Dashboards in Ordner, aber nur zusammen mit `foldersFromFilesStructure`.],
  [Das Admin-Passwort gehört in ein Secret, erzeugt mit `openssl rand`.],
  [Änderungen entstehen in der UI, werden aber als JSON exportiert und über das Repo ausgerollt.],
)

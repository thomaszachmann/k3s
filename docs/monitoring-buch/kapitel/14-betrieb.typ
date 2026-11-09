#import "../lib.typ": *

#kapitel(
  [Betrieb und Fehlersuche],
  ziel: [Du aktualisierst den Stack in einer sicheren Reihenfolge, misst seinen Verbrauch und findest typische Fehler nach einem festen Muster.],
  zeit: [30 Minuten Lesen, danach als Nachschlagewerk],
  braucht: [Ein laufender Stack aus Kapitel 2 bis 9],
)

== Updates in der richtigen Reihenfolge

Ein Update betrifft selten nur eine Komponente. Alloy spricht mit Receive, Grafana mit Thanos Query, der Compactor mit den Blöcken, die Receive hochlädt. Die Grundregel: Erst wird aktualisiert, wer empfängt, dann wer sendet. Ein neuer Empfänger versteht fast immer noch die alten Sender, umgekehrt ist das nicht garantiert.

#tabelle(
  (auto, 1fr),
  ([Schritt], [Was und warum]),
  [0], [etcd-Snapshot auf allen drei VMs (Kapitel 12). Das ist dein Rückweg.],
  [1], [Release Notes lesen, ab deiner Version bis zur Zielversion. Achte auf „breaking“ und auf geänderte Werte-Namen.],
  [2], [SeaweedFS. Alles andere hängt am Speicher.],
  [3], [Thanos: erst Store, Compactor und Query, dann Receive.],
  [4], [kube-prometheus-stack. Vorher die CRDs aktualisieren, das macht Helm bei einem Upgrade nicht. Die Befehle stehen im README des Charts unter „Upgrading“.],
  [5], [Loki und Tempo.],
  [6], [Alloy, kube-state-metrics und node-exporter, erst in `app2`, dann `app1`, zuletzt `obs`.],
  [7], [k3s selbst, eine VM nach der anderen, `app2` zuerst, `obs` zuletzt.],
)

#cmd("Mac")[```bash
for c in obs app1 app2; do echo "== $c"; helm --kube-context $c list -A; done
```][Zeigt alle Releases mit Chart- und App-Version pro Cluster. Vergleiche sie mit der Versions-Tabelle im Anhang.]

#cmd("Mac")[```bash
helm repo update
helm search repo grafana-community/loki --versions | head -5
```][Zeigt die neuesten Chart-Versionen. Spring nicht über mehrere Hauptversionen auf einmal.]

#cmd("Mac")[```bash
helm template loki grafana-community/loki --version <neu> \
  -f observability/central/loki/values.yaml > /dev/null
```][Rendert die neue Version mit deinen Werten, ohne etwas zu installieren. Ein Fehler hier kostet dich nichts, im Cluster schon.]

#falle[
  Aktualisiere nie alles in einem Rutsch. Nach jedem Schritt wartest du, bis alle Pods `Running` sind, und schaust in Grafana, ob Daten aus allen drei Clustern ankommen. Erst dann kommt der nächste Schritt. Geht etwas schief, weißt du genau, welcher es war.
]

== Ressourcen messen statt schätzen

Die Speicherangaben in Kapitel 1 waren Schätzungen. Jetzt, wo alles läuft, misst du. k3s bringt den metrics-server mit, daher funktioniert `kubectl top` sofort.

#cmd("Mac")[```bash
kubectl --context obs top nodes
kubectl --context obs -n monitoring top pods --sort-by=memory
```][Momentaufnahme von Node und Pods, die größten Verbraucher oben.]

#pruefe[
  Ganz oben stehen typischerweise Prometheus, Thanos Receive, Loki und Tempo. Liegt der Node über 85 Prozent Speicher, wird es eng. Dann hilft eine größere VM mehr als jede Feineinstellung.
]

Eine Momentaufnahme lügt, wenn gerade nichts los ist. Der Verlauf in Grafana sagt mehr. Diese Abfragen zeigen Speicher und CPU pro Pod und die Lücke zur Anfrage im Manifest:

```
sum by (pod) (container_memory_working_set_bytes{cluster="obs", namespace="monitoring", container!=""})

sum by (pod) (rate(container_cpu_usage_seconds_total{cluster="obs", namespace="monitoring", container!=""}[5m]))

sum by (pod) (kube_pod_container_resource_requests{cluster="obs", namespace="monitoring", resource="memory"})
```

Setze die Anfragen (`requests`) auf den typischen Verbrauch über eine Woche und das Speicherlimit auf etwa das Doppelte des höchsten Werts. Der Platz auf der Disk ist die dritte Größe:

```
node_filesystem_avail_bytes{cluster="obs", mountpoint="/"} / node_filesystem_size_bytes{cluster="obs", mountpoint="/"}
```

#cmd("obs")[```bash
sudo du -sh /var/lib/rancher/k3s/storage/*
```][`local-path` legt jedes PVC als Ordner auf der VM ab. So siehst du, welches am meisten belegt.]

== Typische Fehler

Geh bei jedem Problem von außen nach innen vor: Was sagt Grafana, was sagen die Logs des Senders, was die Logs des Empfängers? Die Tabelle sammelt die Fehler, die in diesem Aufbau am häufigsten auftreten.

#[
#set par(justify: false)
#tabelle(
  (1fr, 1fr, 1.2fr, 1fr),
  ([Symptom], [Ursache], [Prüfen mit], [Lösung]),
  [Receive-Log: `out of order sample`], [Zwei Sender schreiben dieselbe Serie, oder die Uhr einer VM geht falsch], [`kubectl logs sts/thanos-receive -n monitoring | grep -i "out of order"`, auf der VM `timedatectl`], [Eindeutige Labels (`cluster`, Replika-Label), nur ein Scraper pro Ziel, NTP an],
  [Alloy-Log: HTTP `429` oder `413`], [Limit in Receive überschritten, zu viele Serien], [`kubectl logs ds/alloy -c alloy -n monitoring | grep -E "429|413"`], [Kardinalität senken (Kapitel 13), Limit anheben],
  [Receive nimmt nichts an], [Falsches Passwort (`401`), fehlender Header (Mandant `unbekannt`) oder unbekannte CA (`x509`)], [Alloy-Log nach `receive` filtern, in Grafana `count by (tenant_id) (up)`], [`obs-remote-auth` gegen Basic Auth prüfen, Header in `metrics.alloy`, ConfigMap `obs-ca`],
  [`thanos_compact_halted 1`, Log: `overlaps found`], [Zwei Blöcke mit gleichen Labels und überlappender Zeit, etwa nach doppeltem Upload], [`kubectl logs deploy/thanos-compact -n monitoring | grep -i overlap`], [Doppelten Block löschen oder mit `thanos tools bucket mark` ausschließen, Compactor neu starten],
  [Loki: `entry too far behind`], [Zeilen sind älter als das erlaubte Fenster hinter der neuesten Zeile ihres Streams, oft nach einem Alloy-Neustart], [`kubectl logs ds/alloy -c alloy -n monitoring | grep "too far behind"`], [Meist harmlos und einmalig. Tritt es dauernd auf, Labels und Zeitstempel prüfen],
  [Tempo zeigt keine Traces], [App sendet nicht, `traces.alloy` fehlt in der ConfigMap oder falscher Mandant in der Datenquelle], [Alloy-Log nach `traces_` filtern, `sum by (tenant) (rate(tempo_distributor_spans_received_total[5m]))`], [OTLP-Endpunkt der App, ConfigMap neu bauen, Mandant in Grafana],
  [Keine Span-Metriken oder kein Exemplar-Link für `app1`], [Der Metrics-Generator schreibt als Mandant `obs`. Ein Filter auf `tenant_id="app1"` findet nichts. Exemplars hängen unter dem Label `traceID`], [`count by (tenant_id, cluster) (traces_spanmetrics_calls_total)`], [Nach `cluster` filtern, nicht nach `tenant_id`. In der Datenquelle Thanos muss `traceID` auf Tempo verweisen],
  [Alloy-Pod nicht `Ready`], [Syntaxfehler, doppelter Komponentenname, fehlendes Secret], [`kubectl logs ds/alloy -c alloy -n monitoring | head -30`], [Datei korrigieren, Präfix pro Datei einhalten, Secret anlegen],
  [`no such host` für `*.obs.internal`], [`coredns-custom` fehlt oder Schlüssel endet nicht auf `.server`], [Siehe Befehl unten], [ConfigMap anwenden, `kubectl rollout restart deploy/coredns -n kube-system`],
  [`x509: certificate has expired`], [Wildcard-Zertifikat abgelaufen], [Siehe Befehl unten], [Neu ausstellen wie in Kapitel 2, Secret `obs-tls` ersetzen],
)
]

#cmd("Mac")[```bash
kubectl --context app1 run dnstest --rm -it --restart=Never \
  --image=busybox:1.37 -- nslookup receive.obs.internal
```][Startet einen Wegwerf-Pod und fragt CoreDNS. Erwartet ist die Adresse `172.16.0.150`.]

#cmd("Mac")[```bash
openssl s_client -connect 172.16.0.150:443 -servername grafana.obs.internal \
  </dev/null 2>/dev/null | openssl x509 -noout -enddate
```][Zeigt das Ablaufdatum des Zertifikats, das Traefik gerade ausliefert. Den Alarm dafür hast du in Kapitel 13 gebaut.]

#falle[
  Ein angehaltener Compactor fällt zuerst nicht auf. Receive lädt weiter hoch, Abfragen funktionieren. Aber nichts wird mehr verdichtet und nichts gelöscht, und der Bucket wächst ungebremst. Der Alarm `ThanosCompactorAngehalten` aus Kapitel 13 ist deshalb einer der wichtigsten.
]

#aufgabe[
  Erzeuge absichtlich einen der Fehler aus der Tabelle, etwa ein falsches Passwort in `obs-remote-auth` in `app2`. Finde ihn nur mit den Befehlen aus der Spalte „Prüfen mit“, ohne nachzusehen, was du geändert hast. Wie lange hat es gedauert, bis ein Alarm kam?
]

== Aufräumen

Wenn du das Labor abbaust, geh in umgekehrter Reihenfolge vor. So bleibt nichts zurück, was weiter Geld kostet.

#cmd("Mac")[```bash
aws s3 rb "s3://$PRAEFIX-obs-thanos" --force
aws s3 rb "s3://$PRAEFIX-obs-loki" --force
aws s3 rb "s3://$PRAEFIX-obs-tempo" --force
```][Leert und löscht die drei Buckets ohne Versionierung. Nur wenn du Kapitel 11 gemacht hast.]

#falle[
  Beim Backup-Bucket funktioniert `--force` nicht vollständig. Er hat Versionierung, und `rb --force` löscht nur die aktuellen Versionen. Leere ihn in der AWS-Konsole mit *Empty* und lösche ihn danach. Genau diesen Schutz hast du in Kapitel 11 gewollt.
]

#cmd("Mac")[```bash
for u in obs-lab obs-lab-backup; do
  for k in $(aws iam list-access-keys --user-name $u --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name $u --access-key-id $k
  done
  for p in $(aws iam list-user-policies --user-name $u --query 'PolicyNames' --output text); do
    aws iam delete-user-policy --user-name $u --policy-name $p
  done
  aws iam delete-user --user-name $u
done
```][Ein IAM-Benutzer lässt sich erst löschen, wenn Schlüssel und Policies weg sind.]

#cmd("app1")[```bash
sudo /usr/local/bin/k3s-uninstall.sh
```][Entfernt k3s samt allen Daten von der VM. Auf allen drei VMs ausführen. Danach sind auch SeaweedFS und alle PVCs weg.]

#cmd("Mac")[```bash
for c in obs app1 app2; do kubectl config delete-context $c; done
```][Entfernt die drei Kontexte aus `~/.kube/config`. Die Einträge für Cluster und Benutzer listet `kubectl config get-clusters` und `kubectl config get-users`, du löschst sie mit `delete-cluster` und `delete-user`.]

Zum Schluss entfernst du die Zeilen mit `obs.internal` aus `/etc/hosts` auf dem Mac und löschst den privaten CA-Schlüssel `observability/tls/ca.key`. Ohne ihn kann niemand mehr Zertifikate ausstellen, denen deine Rechner vertrauen.

#gelernt(
  [Updates laufen in fester Reihenfolge: Snapshot, Release Notes, Empfänger vor Sendern, ein Schritt nach dem anderen.],
  [Ressourcen misst du mit `kubectl top` für den Moment und mit PromQL für den Verlauf.],
  [Die meisten Fehler zeigen sich in den Logs von Alloy oder Receive. Die Tabelle sagt dir, wonach du suchst.],
  [Ein angehaltener Compactor ist leise, aber teuer. Er braucht einen eigenen Alarm.],
  [Aufräumen heißt auch: versionierte Buckets, IAM-Schlüssel und den CA-Schlüssel nicht vergessen.],
)

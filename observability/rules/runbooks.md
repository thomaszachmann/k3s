# Runbooks für die globalen Alarme

Jeder Alarm in diesem Verzeichnis verlinkt mit `runbook_url` auf einen Abschnitt hier.
Ein Runbook beantwortet drei Fragen: Was bedeutet der Alarm? Was prüfe ich zuerst? Wie behebe ich es?
Ausführlich erklärt im Buch „Kubernetes beobachten“, Kapitel 7 und 14.

## ClusterSchweigt

Bedeutung: Von einem Cluster kommt keine einzige `up`-Serie mehr bei Thanos an. Alle anderen Alarme dieses Clusters werden unterdrückt.

Prüfen:
1. Läuft der Cluster? `kubectl --context <cluster> get nodes`
2. Läuft Alloy? `kubectl --context <cluster> -n monitoring get pods -l app.kubernetes.io/name=alloy`
3. Schreibfehler im Log? `kubectl --context <cluster> -n monitoring logs ds/alloy -c alloy --tail=50 | grep -i remote`
4. Kommt Receive an? Auf obs: `kubectl --context obs -n monitoring logs thanos-receive-0 --tail=50`

Beheben: Alloy oder den Cluster wieder starten. Zugangsdaten (`obs-remote-auth`) und DNS (`coredns-custom`) prüfen.
Hinweis: Der Alarm verschwindet von selbst, wenn der Cluster länger als sechs Stunden schweigt. Dann ist er auch aus dem Fenster der Regel gefallen.

## NodeSpeicherKnapp

Bedeutung: Auf einem Node sind über 90 % (warning) bzw. 97 % (critical) des Arbeitsspeichers belegt.

Prüfen:
1. Größte Verbraucher: Dashboard „Workloads“ mit dem betroffenen Cluster, oder `kubectl --context <cluster> top pods -A --sort-by=memory`
2. Gab es OOM-Kills? `kubectl --context <cluster> get events -A --field-selector reason=OOMKilling`

Beheben: Limits setzen, Replikas verringern oder der VM mehr RAM geben.

## NodeDiskKnapp

Bedeutung: Auf `/` sind weniger als 15 % frei.

Prüfen: `sudo du -xh --max-depth=2 /var/lib/rancher | sort -h | tail` auf der VM. Häufig: Container-Images, local-path-Volumes, etcd-Snapshots.

Beheben: `sudo k3s crictl rmi --prune`, alte Snapshots löschen, Volumes verkleinern oder die Disk vergrößern.

## PodCrashLoop

Bedeutung: Ein Container startet seit mindestens 10 Minuten immer wieder neu.

Prüfen:
1. `kubectl --context <cluster> -n <namespace> describe pod <pod>` (Abschnitt Events, Last State)
2. `kubectl --context <cluster> -n <namespace> logs <pod> -c <container> --previous`

Beheben: Ursache aus dem Log beheben (Konfiguration, fehlendes Secret, OOMKilled → Limit erhöhen).

## DeploymentUnvollstaendig

Bedeutung: Ein Deployment hat seit 15 Minuten weniger bereite Pods als gewünscht.

Prüfen: `kubectl --context <cluster> -n <namespace> get pods -l <selector>` und die Events der Pods (Pending wegen Ressourcen, ImagePullBackOff, fehlgeschlagene Readiness-Probe).

## ReceiveFehler

Bedeutung: Thanos Receive beantwortet über 5 % der Schreibanfragen mit 5xx.

Prüfen:
1. `kubectl --context obs -n monitoring logs thanos-receive-0 --tail=100`
2. Speicher und Disk des Pods: Dashboard „Thanos-Speicher“
3. Ist das PVC voll? `kubectl --context obs -n monitoring exec thanos-receive-0 -- df -h`

Beheben: Ressourcen erhöhen, PVC vergrößern. Die Absender puffern im WAL, ein kurzer Ausfall kostet keine Daten.

## ReceiveLehntAb

Bedeutung: Über 5 % der Schreibanfragen werden mit 4xx abgelehnt.

Prüfen: Welcher Code? Dashboard „Thanos-Speicher“, Panel „Antworten nach Code“.
- 401 am Ingress: Basic-Auth-Daten im Cluster stimmen nicht.
- 409: Proben außerhalb der Reihenfolge, meist doppelte Absender mit gleichen Labels.
- 429: Limits erreicht.

## ReceiveUploadFehler

Bedeutung: Receive kann fertige Blöcke nicht in den Bucket `thanos` schreiben.

Prüfen: `kubectl --context obs -n monitoring logs thanos-receive-0 | grep -i upload`, danach SeaweedFS (`deploy/s3`) und das Secret `thanos-objstore`.

## CompactorAngehalten

Bedeutung: `thanos_compact_halted` ist 1. Der Compactor hat einen Fehler im Bucket gefunden und arbeitet nicht weiter.

Prüfen: Pod finden mit `kubectl --context obs -n monitoring get pods | grep compact`, dann `kubectl --context obs -n monitoring logs <pod> --tail=100` (Meldung „critical error detected; halting“).

Beheben: Die betroffenen Blöcke stehen im Log. Vorgehen siehe Kapitel 14 des Buches.

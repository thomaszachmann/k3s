#import "../lib.typ": *

#kapitel(
  [Backup und Restore],
  ziel: [Du sicherst genau das, was sich nicht neu bauen lässt, und holst es in einer Übung zurück.],
  zeit: [90 Minuten],
  braucht: [Kapitel 3 und 9, für die AWS-Variante Kapitel 11],
)

Eine Sicherung, die nie zurückgespielt wurde, ist eine Hoffnung. Dieses Kapitel endet deshalb nicht beim ersten grünen Haken, sondern bei zwei Wiederherstellungen: einmal den ganzen Datastore eines Clusters, einmal einen gelöschten Namespace.

== Was gesichert werden muss und was nicht

Der größte Teil deines Stacks braucht keine Sicherung. Er steht im Git oder liegt schon in S3. Geh die Liste einmal bewusst durch.

#tabelle(
  (auto, 1fr, auto),
  ([Was], [Warum], [Sicherung]),
  [Helm-Werte, Manifeste, Dashboards, Regeln], [Liegen in diesem Repo], [Git],
  [Metriken, Logs, Traces], [Liegen in S3. Ein Verlust der letzten Stunden ist verschmerzbar], [Keine, oder S3 selbst (siehe unten)],
  [etcd jedes Clusters], [Enthält alle Secrets, die du per `openssl rand` erzeugt hast, und alles, was nicht im Git steht], [k3s-Snapshots nach S3],
  [k3s-Token], [Ohne ihn lässt sich ein Snapshot auf neuer Hardware nicht entschlüsseln], [Passwort-Manager],
  [Namespace `demo`], [Steht als Beispiel für Anwendungen, die nicht aus Git kommen], [Velero],
  [Grafana-Datenbank], [Kein PVC (Kapitel 6), alles kommt aus ConfigMaps], [Keine],
  [PVC von SeaweedFS], [Nur wenn du nicht auf AWS umgezogen bist: Hier liegen dann alle Langzeitdaten auf einer einzigen Disk], [`aws s3 sync` nach außen],
)

#warum[
  Die Secrets sind der Grund, warum etcd so wichtig ist. Die Passwörter für Basic Auth, S3 und Grafana gibt es nur im Cluster. Ist etcd weg, musst du sie neu erzeugen und in allen drei Clustern neu verteilen. Mit einem Snapshot dauert das fünf Minuten.
]

== SeaweedFS von außen erreichbar machen

Bisher ist SeaweedFS nur im Cluster `obs` erreichbar, unter `s3.monitoring.svc`. Die Snapshots von `app1` und `app2` und Velero in `app1` kommen dort nicht hin. Du gibst S3 deshalb einen eigenen Namen hinter Traefik: `s3.obs.internal`.

Die Datei `observability/backup/s3-ingress.yaml` ist gebaut wie die Ingresse aus Kapitel 5: nur HTTPS über `websecure`, Zertifikat aus `obs-tls`, Ziel ist der Service `s3` auf Port 8333. Es fehlt nur bewusst die Basic-Auth-Middleware.

#warum[
  S3 authentifiziert jede einzelne Anfrage selbst. Der Client signiert sie mit seinem Schlüssel (Signature Version 4) und schickt die Signatur im Header `Authorization`. Basic Auth bräuchte genau diesen Header für sich. Beides zusammen geht also nicht, und es ist auch nicht nötig: Ohne gültige Signatur antwortet SeaweedFS mit `AccessDenied`.
]

#cmd("Mac")[```bash
kubectl --context obs apply -f observability/backup/s3-ingress.yaml
```][Legt den Ingress auf `obs` an.]

In den Pods der Cluster löst CoreDNS den Namen `s3.obs.internal` schon auf, und dein Mac kennt ihn ebenfalls. Beides hast du in Kapitel 2 eingetragen.

k3s selbst läuft aber nicht im Cluster, sondern als Dienst auf der VM. Für die etcd-Snapshots fragt es den Resolver des Betriebssystems und nicht CoreDNS. Jede VM braucht deshalb einen eigenen Eintrag in `/etc/hosts`:

#cmd("Mac")[```bash
ssh -t <user>@172.16.0.126 'echo "172.16.0.126 s3.obs.internal" | sudo tee -a /etc/hosts'
ssh -t <user>@172.16.0.228 'echo "172.16.0.126 s3.obs.internal" | sudo tee -a /etc/hosts'
ssh -t <user>@172.16.0.83  'echo "172.16.0.126 s3.obs.internal" | sudo tee -a /etc/hosts'
```][Ergänzt den Eintrag auf allen drei VMs. Alle zeigen auf die IP von obs. `-t` braucht `sudo` für die Passwortabfrage.]

#cmd("Mac")[```bash
curl -s --cacert observability/tls/ca.crt https://s3.obs.internal/ | head -c 200
```][Eine Anfrage ohne Signatur vom Mac, über TLS mit deiner CA.]

#pruefe[
  Eine kurze XML-Antwort von SeaweedFS, typischerweise mit `AccessDenied`. Das ist der Erfolg: TLS, Traefik und der Service funktionieren. Ein `404 page not found` in Klartext kommt von Traefik und heißt, dass der Ingress nicht greift. Ein Zertifikatsfehler heißt, dass `curl` die CA nicht bekommen hat.
]

#hinweis("Entscheidung: ein Konto für alle Sicherungen", akzent, akzent-hell)[
  Kapitel 3 hat für die Sicherungen ein einziges SeaweedFS-Konto `velero` angelegt, das nur auf den Bucket `backup` darf. Alle drei Cluster nutzen dieses Konto. Jeder schreibt aber in seinen eigenen Ordner: `etcd/obs`, `etcd/app1`, `etcd/app2` und `velero/app1`. Der Grund: SeaweedFS vergibt Rechte pro Bucket, nicht pro Ordner. Drei Konten würden also nichts trennen, solange es nur einen Bucket gibt. Der Preis: Wer den Schlüssel aus `app1` stiehlt, kann auch die Sicherungen von `app2` löschen. Auf AWS fängt die Versionierung aus Kapitel 11 genau diesen Fall ab.
]

== etcd-Snapshots nach S3

#hinweis("Nicht im Labor durchgespielt", warn, warn-hell)[
  Die Schritte dieses und des nächsten Abschnitts laufen per SSH direkt auf den VMs. Sie wurden beim Testlauf dieses Buches nicht ausgeführt, nur gegen die k3s-Doku geprüft. Der Velero-Teil weiter unten lief dagegen vollständig im Labor.
]

k3s macht schon von sich aus alle zwölf Stunden einen Snapshot, aber nur lokal auf der VM. Stirbt die Disk, ist er mit weg. Du stellst auf alle sechs Stunden um und lässt k3s jede Kopie zusätzlich nach S3 schieben.

Die Zugangsdaten sollen nicht in die k3s-Config auf der VM. k3s kann sie deshalb aus einem Secret im Namespace `kube-system` lesen. Zuerst holst du die Schlüssel des Kontos `velero` aus `obs`.

#cmd("Mac")[```bash
CLOUD=$(kubectl --context obs -n monitoring get secret velero-s3 \
  -o jsonpath='{.data.cloud}' | base64 -d)
AK=$(echo "$CLOUD" | awk -F= '/aws_access_key_id/ {print $2}')
SK=$(echo "$CLOUD" | awk -F= '/aws_secret_access_key/ {print $2}')
echo "${#AK} ${#SK}"
```][Liest die Schlüssel in Shell-Variablen und gibt nur ihre Längen aus. Laut Kapitel 3 sind das `32 64`.]

#cmd("Mac")[```bash
kubectl --context obs -n kube-system create secret generic k3s-etcd-s3 \
  --type=etcd.k3s.cattle.io/s3-config-secret \
  --from-literal=etcd-s3-endpoint=s3.obs.internal \
  --from-literal=etcd-s3-bucket=backup \
  --from-literal=etcd-s3-folder=etcd/obs \
  --from-file=etcd-s3-endpoint-ca=observability/tls/ca.crt \
  --from-file=etcd-s3-access-key=<(printf %s "$AK") \
  --from-file=etcd-s3-secret-key=<(printf %s "$SK")
```][Das Secret für obs, mit dem Ordner `etcd/obs`.]

#cmd("Mac")[```bash
kubectl --context app1 -n kube-system create secret generic k3s-etcd-s3 \
  --type=etcd.k3s.cattle.io/s3-config-secret \
  --from-literal=etcd-s3-endpoint=s3.obs.internal \
  --from-literal=etcd-s3-bucket=backup \
  --from-literal=etcd-s3-folder=etcd/app1 \
  --from-file=etcd-s3-endpoint-ca=observability/tls/ca.crt \
  --from-file=etcd-s3-access-key=<(printf %s "$AK") \
  --from-file=etcd-s3-secret-key=<(printf %s "$SK")
kubectl --context app2 -n kube-system create secret generic k3s-etcd-s3 \
  --type=etcd.k3s.cattle.io/s3-config-secret \
  --from-literal=etcd-s3-endpoint=s3.obs.internal \
  --from-literal=etcd-s3-bucket=backup \
  --from-literal=etcd-s3-folder=etcd/app2 \
  --from-file=etcd-s3-endpoint-ca=observability/tls/ca.crt \
  --from-file=etcd-s3-access-key=<(printf %s "$AK") \
  --from-file=etcd-s3-secret-key=<(printf %s "$SK")
```][Dasselbe für app1 und app2. Die drei Befehle unterscheiden sich nur in Kontext und Ordner. Der Typ `etcd.k3s.cattle.io/s3-config-secret` ist Pflicht. Die CA steht direkt als PEM im Secret. Die beiden Schlüssel kommen über `<(printf ...)` als Datei, damit sie nicht in der Prozessliste auftauchen. Region und Adressierung bleiben auf den Standardwerten `us-east-1` und `auto`, und `auto` wählt für fremde Endpunkte den Pfad-Stil.]

#datei("observability/backup/k3s-etcd-s3.yaml")[```yaml
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 8
etcd-snapshot-compress: true
etcd-s3: true
etcd-s3-config-secret: k3s-etcd-s3
```, erklaerung: [Ein Drop-in für k3s. Alle sechs Stunden ein Snapshot, lokal bleiben die letzten acht, komprimiert als ZIP. `etcd-s3: true` schaltet die Kopie ein, alles Weitere steht im Secret.]]

#falle[
  Setze hier keine weitere `etcd-s3-*`-Option, auch nicht `etcd-s3-retention`. Laut k3s-Doku ignoriert k3s das Secret, sobald irgendeine andere S3-Option gesetzt ist. Die Snapshots landen dann ohne Fehlermeldung nur lokal.
]

k3s liest neben `/etc/rancher/k3s/config.yaml` auch alle Dateien in `/etc/rancher/k3s/config.yaml.d/`. Deine Haupt-Config aus Kapitel 2 bleibt also unverändert.

#cmd("Mac")[```bash
scp observability/backup/k3s-etcd-s3.yaml <user>@172.16.0.126:/tmp/etcd-s3.yaml
scp observability/backup/k3s-etcd-s3.yaml <user>@172.16.0.228:/tmp/etcd-s3.yaml
scp observability/backup/k3s-etcd-s3.yaml <user>@172.16.0.83:/tmp/etcd-s3.yaml
```][Kopiert das Drop-in auf alle drei VMs.]

#cmd("Mac")[```bash
ssh <user>@172.16.0.228
```][Meldet dich auf `k3s-app1` an. Die nächsten Schritte mit dem Etikett *app1* laufen dort.]

#cmd("app1")[```bash
sudo install -D -m 600 /tmp/etcd-s3.yaml \
  /etc/rancher/k3s/config.yaml.d/etcd-s3.yaml
sudo systemctl restart k3s
```][Legt die Datei mit Rechten nur für root ab und startet k3s neu. Die Pods laufen dabei weiter. Wiederhole diesen Schritt auf `k3s-obs` und `k3s-app2`.]

#cmd("app1")[```bash
sudo k3s etcd-snapshot save --name manuell
sudo k3s etcd-snapshot ls
```][Ein Snapshot von Hand, damit du nicht sechs Stunden warten musst. Danach die Liste aller Snapshots, lokal und in S3.]

#pruefe[
  Zwei Zeilen mit `manuell-k3s-app1-...`: eine mit einem Pfad unter `/var/lib/rancher/k3s/server/db/snapshots/`, eine mit `s3://backup/etcd/app1/...`. Fehlt die S3-Zeile, zeigt `sudo journalctl -u k3s | grep -i s3 | tail` den Grund. Häufig ist es der fehlende `/etc/hosts`-Eintrag.
]

Sichere jetzt auch das Server-Token aus `/var/lib/rancher/k3s/server/token`, für jede VM einzeln, in deinem Passwort-Manager und nirgendwo sonst.

#falle[
  Der Snapshot von `obs` liegt im SeaweedFS von `obs`, also auf derselben Disk. Für Bedienfehler hilft er trotzdem, gegen einen Plattentod nicht. Erst mit AWS (am Ende dieses Kapitels) liegt auch er außer Haus.
]

== Die Wiederherstellung üben

Du übst an `app2`, dort ist am wenigsten zu verlieren. Der Plan: eine Markierung anlegen, Snapshot ziehen, Markierung löschen, Snapshot zurückspielen. Ist die Markierung danach wieder da, hat es funktioniert.

#cmd("Mac")[```bash
kubectl --context app2 create configmap restore-probe --from-literal=stand=vorher
```][Die Markierung, im Namespace `default`.]

#cmd("Mac")[```bash
ssh <user>@172.16.0.83
```][Öffne eine zweite Sitzung auf `k3s-app2`. Die Befehle mit dem Etikett *Mac* laufen weiter im ersten Terminal.]

#cmd("app2")[```bash
sudo k3s etcd-snapshot save --name vor-uebung
sudo ls /var/lib/rancher/k3s/server/db/snapshots/
```][Zieht den Snapshot und zeigt den vollständigen Dateinamen. Er beginnt mit `vor-uebung-k3s-app2-` und endet mit `.zip`.]

#cmd("Mac")[```bash
kubectl --context app2 delete configmap restore-probe
```][Der „Unfall“.]

#cmd("app2")[```bash
sudo systemctl stop k3s
sudo k3s server --cluster-reset --etcd-s3=false \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<datei>
```][k3s muss stehen, bevor du den Datastore zurücksetzt. Dann spielt die zweite Zeile den lokalen Snapshot zurück. Setze für `<datei>` den Namen aus dem vorletzten Schritt ein. `--etcd-s3=false` ist nötig, weil im Drop-in `etcd-s3: true` steht. Sonst würde k3s die Datei in S3 suchen. Der Befehl beendet sich selbst und meldet, dass du k3s jetzt ohne diese Optionen starten sollst.]

#cmd("app2")[```bash
sudo systemctl start k3s
```][Startet k3s normal.]

#pruefe[
  `kubectl --context app2 get configmap restore-probe -o jsonpath='{.data.stand}'` auf dem Mac gibt `vorher` aus. Der Cluster steht wieder auf dem Stand des Snapshots. Pods, die nach dem Snapshot entstanden sind, räumt Kubernetes in den nächsten Minuten auf.
]

#aufgabe[
  Spiele denselben Snapshot aus S3 zurück. Dabei hilft das Secret nicht, denn beim Restore läuft noch kein Cluster, aus dem k3s es lesen könnte. Die S3-Angaben müssen deshalb als Optionen auf die Kommandozeile: `--etcd-s3`, `--etcd-s3-endpoint`, `--etcd-s3-endpoint-ca` (hier als Dateipfad auf der VM), `--etcd-s3-bucket`, `--etcd-s3-folder` und die beiden Schlüssel. Als Restore-Pfad gibst du dann nur den Dateinamen an, ohne Ordner. Überlege vorher: Wo stehen die Schlüssel während des Befehls sichtbar, und wie räumst du danach auf?
]

== Velero für Anwendungen

Ein etcd-Snapshot sichert alles oder nichts. Willst du nur einen Namespace zurückholen, ohne den Rest des Clusters zurückzudrehen, brauchst du Velero. Velero liest die Objekte über die Kubernetes-API, packt sie in ein Archiv und legt es in S3 ab.

Velero läuft in `app1` im eigenen Namespace `velero`. Das ist die Voreinstellung der Velero-CLI und trennt die Sicherung sauber von der Observability in `monitoring`.

#cmd("Mac")[```bash
brew install velero
kubectl --context app1 create namespace velero
```][Installiert die CLI, ihre Version sollte zur Server-Version 1.18 passen. Dann der Namespace für Velero.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring get secret velero-s3 \
  -o jsonpath='{.data.cloud}' | base64 -d |
kubectl --context app1 -n velero create secret generic velero-s3 \
  --from-file=cloud=/dev/stdin --dry-run=client -o yaml |
kubectl --context app1 apply -f -
```][Kopiert das Secret `velero-s3` von `obs` nach `app1`, ohne dass der Inhalt auf dem Bildschirm erscheint. Der Schlüssel `cloud` enthält eine AWS-credentials-Datei.]

#cmd("Mac")[```bash
kubectl --context app1 -n velero create secret generic obs-ca \
  --from-file=ca.crt=observability/tls/ca.crt
```][Velero liest die CA für `s3.obs.internal` aus einem Secret, nicht aus einer ConfigMap.]

#datei("observability/backup/velero-values.yaml (Ausschnitt)")[```yaml
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.14.4
credentials:
  useSecret: true
  existingSecret: velero-s3
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: backup
      prefix: velero/app1
      default: true
      caCertRef: {name: obs-ca, key: ca.crt}
      config:
        region: us-east-1
        s3ForcePathStyle: "true"
        s3Url: https://s3.obs.internal
  defaultBackupTTL: 168h0m0s
snapshotsEnabled: false
deployNodeAgent: false
schedules:
  demo-taeglich:
    schedule: "0 3 * * *"
    template:
      ttl: 168h0m0s
      includedNamespaces: [demo]
```, erklaerung: [Das AWS-Plugin spricht jedes S3, auch SeaweedFS. `s3ForcePathStyle` ist für SeaweedFS nötig. Volume-Snapshots sind aus, weil `local-path` keine kennt. Der Zeitplan sichert `demo` jede Nacht um drei, jede Sicherung lebt sieben Tage.]]

#falle[
  Das Plugin muss zur Velero-Version passen. Laut Kompatibilitätstabelle im Repository `velero-plugin-for-aws` gehört zu Velero 1.18 die Plugin-Reihe 1.14. Das Chart nennt im Kommentar noch `v1.13.1` als Beispiel. Mit der falschen Reihe startet Velero, aber der Speicherort bleibt `Unavailable`.
]

#cmd("Mac")[```bash
helm --kube-context app1 upgrade --install velero vmware-tanzu/velero \
  --version 12.2.4 -n velero -f observability/backup/velero-values.yaml --wait
```][Installiert Velero 1.18.2. Das Chart legt auch die CRDs an.]

#cmd("Mac")[```bash
velero --kubecontext app1 backup-location get
```][Zeigt den Speicherort und seinen Zustand.]

#pruefe[
  ```
  NAME      PROVIDER   BUCKET/PREFIX        PHASE       LAST VALIDATED   ACCESS MODE   DEFAULT
  default   aws        backup/velero/app1   Available   ...              ReadWrite     true
  ```
  Eine Zeile `default` mit Provider `aws`, Bucket `backup/velero/app1` und Phase `Available`. Steht dort `Unavailable`, zeigt `kubectl --context app1 -n velero logs deploy/velero | grep -i error` den Grund. Typisch sind ein Zertifikatsfehler (CA-Secret fehlt) oder `AccessDenied` (falsches Secret).
]

#cmd("Mac")[```bash
velero --kubecontext app1 backup create demo-manuell \
  --include-namespaces demo --wait
```][Eine Sicherung von Hand. `--wait` wartet, bis sie fertig ist.]

#pruefe[
  `velero --kubecontext app1 backup describe demo-manuell --details --cacert observability/tls/ca.crt` zeigt `Phase: Completed`, `Errors: 0` und eine Liste mit Deployments, Services und dem Namespace `demo`. Für `--details` lädt die CLI direkt aus S3, deshalb braucht sie die CA und den `/etc/hosts`-Eintrag auf dem Mac.
]

Jetzt der Ernstfall. Du löschst den ganzen Namespace.

#cmd("Mac")[```bash
kubectl --context app1 delete namespace demo
```][HotROD und der Lastgenerator sind weg. In Grafana reißt die Linie der Traces ab.]

#cmd("Mac")[```bash
velero --kubecontext app1 restore create demo-zurueck \
  --from-backup demo-manuell --wait
```][Holt alle Objekte aus der Sicherung zurück.]

#pruefe[
  `Restore completed with status: Completed.` Danach zeigt `kubectl --context app1 -n demo get pods` die Pods `hotrod-...` und `hotrod-last-...`, im Labor nach gut 30 Sekunden auf `Running`. Die Pods tragen sogar wieder denselben Namen wie vorher, denn Velero stellt die Objekte so wieder her, wie sie gesichert wurden. Nach ein paar weiteren Minuten kommen in Grafana wieder Traces aus `app1` an.
]

Velero sichert hier nur Objekte, keine Daten in Volumes. Für die Demo-App reicht das. Für PVCs auf `local-path` bräuchtest du das File System Backup mit `deployNodeAgent: true`.

== Alarm, wenn die Sicherung ausbleibt

Eine Sicherung, die still scheitert, merkst du erst beim Restore. Velero meldet deshalb Metriken auf Port 8085. Alloy in `app1` holt sie mit einer kleinen Zusatzdatei ab und schickt sie wie alle anderen Metriken an Thanos Receive.

#datei("observability/backup/backup.alloy (Ausschnitt)")[```
prometheus.scrape "backup_velero" {
  targets         = discovery.relabel.backup_velero.output
  job_name        = "velero"
  scrape_interval = "60s"
  forward_to      = [prometheus.remote_write.metrics_obs.receiver]
}
```, erklaerung: [Davor stehen eine Pod-Suche im Namespace `velero` und eine Regel, die nur den Port `http-monitoring` behält. Der Versand nutzt `metrics_obs` aus `metrics.alloy`. Alle Namen tragen das Präfix `backup_`.]]

#cmd("Mac")[```bash
kubectl --context app1 -n monitoring create configmap alloy-config \
  --from-file=observability/cluster/alloy/metrics.alloy \
  --from-file=observability/cluster/alloy/logs.alloy \
  --from-file=observability/cluster/alloy/traces.alloy \
  --from-file=observability/backup/backup.alloy \
  --dry-run=client -o yaml | kubectl --context app1 apply -f -
kubectl --context app1 -n monitoring rollout restart ds/alloy
```][Die ConfigMap aus Kapitel 5, 8 und 9 bekommt `backup.alloy` dazu. Nur in `app1`, denn nur dort läuft Velero.]

#cmd("Mac")[```bash
kubectl --context obs apply -f observability/backup/velero-rules.yaml
```][Drei Alarme mit `auswertung: global`, ausgewertet vom Thanos Ruler.]

Sie melden eine gescheiterte letzte Sicherung, eine erfolgreiche Sicherung, die älter als 25 Stunden ist, und gescheiterte Versuche in der letzten Stunde.

#pruefe[
  In Grafana liefert `velero_backup_last_successful_timestamp{cluster="app1"}` eine Serie mit `schedule="demo-taeglich"`, sobald der Zeitplan einmal gelaufen ist. Davor gibt es die Serie nur für manuelle Sicherungen mit leerem `schedule`.
]

Für die etcd-Snapshots gibt es keine fertige Metrik. Prüfe sie deshalb regelmäßig von Hand mit `k3s etcd-snapshot ls`, oder schau in S3 nach dem Datum der neuesten Datei.

== Variante: Sicherungen auf AWS

Mit Kapitel 11 hast du den Bucket `<praefix>-obs-backup` mit Versionierung und den Benutzer `obs-lab-backup`. Der Umstieg tauscht nur Schlüssel und Ziel.

Erzeuge zuerst wie in Kapitel 11 mit `aws iam create-access-key` einen Schlüssel für `obs-lab-backup` und lies ihn mit `read -r AK SK` in die Shell.

#cmd("Mac")[```bash
printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$AK" "$SK" |
kubectl --context app1 -n velero create secret generic velero-s3 \
  --from-file=cloud=/dev/stdin --dry-run=client -o yaml |
kubectl --context app1 apply -f -
```][Ersetzt das Velero-Secret in `app1` durch den AWS-Schlüssel.]

#cmd("Mac")[```bash
sed "s|PRAEFIX|$PRAEFIX|" observability/backup/velero-aws.yaml |
helm --kube-context app1 upgrade velero vmware-tanzu/velero --version 12.2.4 \
  -n velero -f observability/backup/velero-values.yaml -f - --wait
```][`velero-aws.yaml` ersetzt den Speicherort komplett: Bucket in `eu-central-1`, kein `s3Url`, keine eigene CA.]

Für die etcd-Snapshots baust du das Secret `k3s-etcd-s3` neu, mit `etcd-s3-endpoint=s3.eu-central-1.amazonaws.com`, `etcd-s3-region=eu-central-1`, dem Bucket `$PRAEFIX-obs-backup` und ohne `etcd-s3-endpoint-ca`. Das Drop-in bleibt unverändert. Zum Schluss `unset AK SK`.

#gelernt(
  [Gesichert wird nur, was nicht im Git oder in S3 steht: vor allem etcd mit seinen Secrets und das k3s-Token.],
  [S3 braucht keine Basic Auth, denn jede Anfrage ist signiert. Der Name muss aber für Pods und für den Dienst auf der VM auflösbar sein.],
  [k3s liest die S3-Zugangsdaten für Snapshots aus einem Secret, beim Restore aber nur von der Kommandozeile.],
  [Velero sichert einzelne Namespaces. Das Plugin muss zur Velero-Version passen.],
  [Eine Sicherung zählt erst, wenn die Wiederherstellung geübt ist und ein Alarm ihr Ausbleiben meldet.],
)

#import "../lib.typ": *

#kapitel(
  [S3 im Cluster mit SeaweedFS],
  ziel: [Auf der Zentrale läuft ein S3-Speicher mit vier Buckets. Jede Komponente hat ein eigenes Konto, das nur ihren Bucket sieht.],
  zeit: [40 Minuten],
  braucht: [Kapitel 2],
)

== Warum S3 schon im Labor

Thanos, Loki und Tempo halten nur die jüngsten Daten lokal. Alles Ältere schreiben sie in einen Objektspeicher mit S3-Schnittstelle. Das ist der Grund, warum die Zentrale Wochen und Monate aufbewahren kann, ohne dass ihre Disk wächst wie die Datenmenge.

Im Labor übernimmt das SeaweedFS. Es läuft als ein einziger Pod, spricht S3 und braucht wenig Speicher. In Kapitel 11 ziehst du auf echtes S3 bei AWS um. Weil alle Komponenten nur die S3-Schnittstelle kennen, ändern sich dabei nur Endpunkt und Zugangsdaten.

#tabelle(
  (auto, auto, 1fr),
  ([Bucket], [Konto], [Secret im Namespace `monitoring`]),
  [`thanos`], [`thanos`], [`thanos-objstore` (Schlüssel `objstore.yml`)],
  [`loki`], [`loki`], [`loki-s3` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)],
  [`tempo`], [`tempo`], [`tempo-s3` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)],
  [`backup`], [`velero`], [`velero-s3` (Schlüssel `cloud`, AWS-credentials-Format)],
)

Dazu kommt das Secret `s3-config`. Es enthält alle vier Konten und ist die Konfiguration von SeaweedFS selbst.

#warum[
  Ein Konto pro Komponente klingt nach Mehraufwand. Es zahlt sich aus, sobald etwas schiefgeht. Löscht ein falsch konfigurierter Compactor Daten, trifft es nur den Bucket `thanos`. Und gelangt ein Schlüssel in ein Log, tauschst du genau diesen einen aus.
]

== Die Zugangsdaten erzeugen

Das Skript `observability/seaweedfs/create-secrets.sh` erzeugt alle Schlüssel mit `openssl rand` und legt sie nur als Kubernetes-Secrets ab. Sie stehen in keiner Datei und erscheinen nie auf dem Bildschirm.

#datei("observability/seaweedfs/create-secrets.sh (Ausschnitt)", ```bash
# Konto:Bucket
ACCOUNTS="thanos:thanos loki:loki tempo:tempo velero:backup"
...
  NEW=$(printf '%s' "$NEW" | N="$name" B="$bucket" AK="$AK" SK="$SK" jq \
    '.identities += [{
       name: env.N,
       credentials: [{accessKey: env.AK, secretKey: env.SK}],
       actions: ["Read:\(env.B)", "Write:\(env.B)", "List:\(env.B)", "Tagging:\(env.B)"]
     }]')
```, erklaerung: [
  Für jedes Paar aus Konto und Bucket hängt `jq` ein Konto an die Liste an. Die Rechte in `actions` gelten nur für den genannten Bucket. Die Schlüssel übergibt das Skript über Umgebungsvariablen statt als Argumente, damit sie nicht in der Prozessliste auftauchen. Gibt es `s3-config` schon, übernimmt das Skript die vorhandenen Schlüssel. Ein zweiter Lauf ändert also nichts und ergänzt höchstens fehlende Secrets.
])

#cmd("Mac")[```bash
./observability/seaweedfs/create-secrets.sh
```][Arbeitet standardmäßig mit dem Kontext `obs`. Für einen anderen Kontext setzt du davor `KUBE_CONTEXT=<name>`.]

#pruefe[
  Vier Zeilen der Form `Konto thanos: neu erzeugt (Bucket thanos)`, danach `Secrets s3-config, thanos-objstore, loki-s3, tempo-s3 und velero-s3 in monitoring (Kontext obs) angelegt.` Bei einem zweiten Lauf steht statt „neu erzeugt“ jeweils „vorhanden, Schlüssel bleiben“.
]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring get secret \
  s3-config thanos-objstore loki-s3 tempo-s3 velero-s3
```][Listet die fünf Secrets, ohne ihren Inhalt zu zeigen.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring get secret s3-config \
  -o jsonpath='{.data.s3\.json}' | base64 -d \
  | jq -c '.identities[] | {name, actions}'
```][Zeigt die Konten und ihre Rechte, aber nicht die Schlüssel. Der Backslash in `s3\.json` ist nötig, weil der Punkt sonst als Pfadtrenner gilt.]

#pruefe[
  Vier Zeilen, zum Beispiel `{"name":"velero","actions":["Read:backup","Write:backup","List:backup","Tagging:backup"]}`. Kein Konto nennt einen fremden Bucket.
]

== SeaweedFS starten

Das Manifest enthält ein PersistentVolumeClaim, ein Deployment und einen Service. Drei Stellen darin verdienen einen Blick:

#datei("observability/seaweedfs/seaweedfs.yaml (Ausschnitt)", ```yaml
spec:
  strategy:
    type: Recreate
  template:
    spec:
      enableServiceLinks: false
      containers:
        - name: s3
          image: chrislusf/seaweedfs:4.52
          args:
            - server
            - -dir=/data
            - -s3
            - -s3.config=/etc/seaweedfs/s3.json
            - -master.volumeSizeLimitMB=256
            - -volume.max=120
            - -volume.minFreeSpace=2GiB
```, erklaerung: [
  `weed server` startet Master, Volume-Server, Filer und S3-Gateway in einem Prozess. Die Konten liest es aus `s3.json`, das aus dem Secret `s3-config` stammt. `Recreate` sorgt dafür, dass nie zwei Pods gleichzeitig auf dasselbe Datenverzeichnis zugreifen.
])

#falle[
  *Der Service-Name `s3`.* Kubernetes setzt für jeden Service im Namespace Umgebungsvariablen, hier also `S3_PORT=tcp://10.43.x.x:8333`. SeaweedFS liest Flags auch aus der Umgebung, hält das für `-s3.port` und stürzt beim Start ab. Deshalb steht im Manifest `enableServiceLinks: false`. Fehlt die Zeile, siehst du einen `CrashLoopBackOff` mit einem Fehler beim Parsen des Ports.
]

#falle[
  *Die Größe.* `local-path` setzt die Größe des PersistentVolumeClaims nicht durch. Das Volume ist einfach ein Verzeichnis auf der Node-Disk. Das echte Limit setzen die weed-Flags: 120 Volumes zu je 256 MB, also rund 30 GB. Jeder Bucket belegt beim ersten Schreiben gleich mehrere Volumes. Ein zu kleines `-volume.max` führt deshalb schnell zu Schreibfehlern, obwohl die Disk noch leer ist.
]

#cmd("Mac")[```bash
kubectl --context obs apply -f observability/seaweedfs/seaweedfs.yaml
```][Legt PVC, Deployment und Service an. Das Secret `s3-config` muss schon existieren, sonst bleibt der Pod in `ContainerCreating` stehen.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring rollout status deploy/s3
```][Wartet, bis der Pod bereit ist. `apply` kehrt sofort zurück, dieser Befehl erst, wenn die Readiness-Probe auf Port 8333 antwortet.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring get pod -l app=s3
kubectl --context obs -n monitoring get pvc s3-data
```][Zeigt Pod und Volume.]

#pruefe[
  Der Pod `s3-...` steht auf `Running` und `1/1`, `RESTARTS` ist `0`. Das PVC `s3-data` ist `Bound` mit der StorageClass `local-path`.
]

== Die Buckets anlegen

Buckets legst du mit der Verwaltungsshell `weed shell` im Pod an. Das Skript `observability/seaweedfs/create-buckets.sh` prüft zuerst, welche Buckets es schon gibt, und legt nur die fehlenden an.

#cmd("Mac")[```bash
./observability/seaweedfs/create-buckets.sh
```][Führt im Pod `s3.bucket.list` und für jeden fehlenden Bucket `s3.bucket.create` aus.]

#pruefe[
  Vier Zeilen: `Bucket thanos: angelegt`, ebenso für `loki`, `tempo` und `backup`. Bei einem zweiten Lauf steht dort jeweils `vorhanden`.
]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring exec deploy/s3 -- \
  sh -c "echo 's3.bucket.list' | weed shell -master=localhost:9333"
```][Fragt SeaweedFS direkt nach seinen Buckets. So siehst du, was das Skript getan hat.]

== Die Rechte prüfen

Ein Konto, das zu viel darf, fällt im normalen Betrieb nicht auf. Prüfe deshalb jetzt, dass das Konto `loki` seinen Bucket lesen kann und den von Thanos nicht.

Der S3-Port ist nur im Cluster erreichbar. Für den Test leitest du ihn kurz auf den Mac um. Öffne dafür ein zweites Terminal:

#cmd("Mac")[```bash
kubectl --context obs -n monitoring port-forward svc/s3 8333:8333
```][Macht den Service unter `localhost:8333` erreichbar, bis du ihn mit `Ctrl-C` beendest.]

Zurück im ersten Terminal liest du die Schlüssel des Kontos `loki` in Shell-Variablen. Sie erscheinen dabei nicht auf dem Bildschirm.

#cmd("Mac")[```bash
AK=$(kubectl --context obs -n monitoring get secret loki-s3 \
  -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
SK=$(kubectl --context obs -n monitoring get secret loki-s3 \
  -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
```][Kubernetes speichert Secret-Werte Base64-kodiert, `base64 -d` macht sie wieder lesbar.]

#cmd("Mac")[```bash
printf 'user = "%s:%s"\n' "$AK" "$SK" | curl -s -K - \
  --aws-sigv4 "aws:amz:us-east-1:s3" http://localhost:8333/loki/
```][`curl` kann S3-Anfragen selbst signieren. `-K -` liest die Zugangsdaten aus der Standardeingabe, damit sie nicht als Argument in der Prozessliste stehen. Die Anfrage listet den Inhalt des Buckets `loki`.]

#pruefe[
  Eine kurze XML-Antwort mit `<ListBucketResult>` und `<Name>loki</Name>`. Der Bucket ist noch leer, deshalb folgen keine `<Contents>`-Einträge.
]

#cmd("Mac")[```bash
printf 'user = "%s:%s"\n' "$AK" "$SK" | curl -s -K - \
  --aws-sigv4 "aws:amz:us-east-1:s3" http://localhost:8333/thanos/
```][Dieselbe Anfrage, nur an den fremden Bucket `thanos`.]

#pruefe[
  Eine XML-Fehlermeldung mit `<Code>AccessDenied</Code>`. Genau so soll es sein: Das Konto `loki` sieht nur seinen eigenen Bucket.
]

#cmd("Mac")[```bash
unset AK SK
```][Entfernt die Schlüssel aus deiner Shell. Beende danach den Port-Forward im zweiten Terminal mit `Ctrl-C`.]

#falle[
  Löschst du den SeaweedFS-Pod von Hand, startet der neue manchmal, bevor der alte die Sperre auf seine LevelDB-Dateien freigegeben hat. Der neue Pod startet dann ein- oder zweimal neu und läuft danach normal. Das ist harmlos. Für geplante Neustarts nimm `kubectl --context obs -n monitoring rollout restart deploy/s3`, dank `Recreate` wartet Kubernetes dann sauber.
]

== Was die anderen Komponenten wissen müssen

Ab Kapitel 4 greifen Thanos, Loki, Tempo und Velero auf diesen Speicher zu. Alle nutzen dieselben Grundwerte:

#tabelle(
  (auto, 1fr),
  ([Einstellung], [Wert]),
  [Endpunkt], [`http://s3.monitoring.svc.cluster.local:8333`],
  [Region], [`us-east-1` (SeaweedFS ignoriert sie, die Clients verlangen aber eine)],
  [Adressierung], [Pfad-Stil (`/bucket/objekt`), nicht `bucket.host`],
  [TLS], [aus, der Verkehr bleibt im Cluster],
)

#warum[
  Der Pfad-Stil ist wichtig. Viele S3-Clients setzen den Bucket-Namen standardmäßig vor den Hostnamen, also `thanos.s3.monitoring.svc...`. Diesen Namen gibt es im Cluster-DNS nicht. Deshalb steht in `thanos-objstore` die Zeile `bucket_lookup_type: path`, und Loki und Tempo bekommen später die entsprechende Option.
]

#aufgabe[
  Wiederhole den Test mit den Schlüsseln aus `velero-s3`. Dort liegen sie nicht als einzelne Werte, sondern in einer Datei im AWS-Format unter dem Schlüssel `cloud`. Wie kommst du mit `jsonpath`, `base64` und `awk` an die beiden Werte? Welcher Bucket muss antworten, welcher nicht?
]

#gelernt(
  [Thanos, Loki und Tempo lagern ältere Daten in S3 aus. Im Labor spielt SeaweedFS diese Rolle.],
  [Ein Konto pro Komponente begrenzt den Schaden bei Fehlern und bei verlorenen Schlüsseln.],
  [Zugangsdaten entstehen mit `openssl rand` und leben nur in Kubernetes-Secrets.],
  [`enableServiceLinks: false` verhindert, dass Kubernetes-Umgebungsvariablen SeaweedFS verwirren.],
  [Mit `curl --aws-sigv4` prüfst du S3-Rechte ohne zusätzliche Werkzeuge.],
)

#import "../lib.typ": *

#kapitel(
  [S3 auf AWS],
  ziel: [Die Langzeitdaten ziehen von SeaweedFS in vier verschlüsselte AWS-Buckets um, und jede Komponente darf nur an ihren eigenen.],
  zeit: [90 Minuten],
  braucht: [Kapitel 3 bis 9, ein AWS-Konto und die `aws` CLI auf dem Mac],
)

SeaweedFS hat dich bis hierher gut getragen. Es hat aber einen Haken: Es liegt auf derselben VM wie alles andere. Stirbt die Disk von `k3s-obs`, sind Metriken, Logs und Traces weg, und die Sicherungen aus Kapitel 12 gleich mit. AWS S3 löst genau das. Die Daten liegen außerhalb deines Labors, mehrfach gespiegelt, und du zahlst nur, was du belegst.

#hinweis("Nicht im Labor durchgespielt", warn, warn-hell)[
  Anders als die Kapitel 2 bis 10 lief dieses Kapitel nicht gegen ein echtes AWS-Konto. Die Befehle folgen der AWS-Doku und sind syntaktisch geprüft, aber Ausgaben und Fehlermeldungen können abweichen. Gehe Schritt für Schritt vor und vergleiche nach jedem Schritt mit dem Kasten „Das solltest du sehen“.
]

Der Umbau ist kleiner, als er klingt. Thanos, Loki und Tempo sprechen schon S3. Du tauschst nur Endpunkt, Bucket und Schlüssel aus.

#warum[
  Wer Observability-Daten in die Cloud legt, öffnet einen neuen Angriffsweg. Ein falsch gesetzter Bucket ist öffentlich lesbar, ein zu breiter Schlüssel löscht alles. Deshalb baust du in diesem Kapitel erst die Riegel ein und schreibst danach die ersten Daten.
]

== Die aws CLI vorbereiten

Für die Einrichtung brauchst du die AWS CLI v2 und einen IAM-Benutzer mit Administrationsrechten, nicht das Root-Konto. Seine Schlüssel liegen nur in `~/.aws/credentials` auf deinem Mac, nie im Repo.

#cmd("Mac")[```bash
aws configure --profile obs-admin
```][Fragt Access Key, Secret Key, Region (`eu-central-1`) und Ausgabeformat (`json`) ab. Das Profil heißt `obs-admin`, damit es nicht mit anderen Projekten kollidiert.]

#cmd("Mac")[```bash
export AWS_PROFILE=obs-admin AWS_REGION=eu-central-1 PRAEFIX=tz7
aws sts get-caller-identity
```][Bucket-Namen sind weltweit eindeutig. Wähle deshalb ein eigenes, kurzes Präfix aus Kleinbuchstaben und Ziffern statt `tz7`. Alle Befehle dieses Kapitels laufen in derselben Terminal-Sitzung. Die zweite Zeile fragt AWS, wer du gerade bist.]

#pruefe[
  Eine JSON-Ausgabe mit `Account` und einer `Arn`, die auf `:user/...` endet. Steht dort `:root`, arbeitest du mit dem Root-Konto. Lege dann zuerst einen eigenen Admin-Benutzer an.
]

== Vier Buckets anlegen

Wie in SeaweedFS bekommt jede Komponente ihren eigenen Bucket. So kannst du Rechte, Lebensdauer und Versionierung pro Bucket festlegen.

#tabelle(
  (auto, auto, 1fr),
  ([Bucket], [Nutzer], [Besonderheit]),
  [`<praefix>-obs-thanos`], [Thanos], [Ablauf nach der Compactor-Retention],
  [`<praefix>-obs-loki`], [Loki], [Ablauf nach der Loki-Retention],
  [`<praefix>-obs-tempo`], [Tempo], [Ablauf nach der Tempo-Retention],
  [`<praefix>-obs-backup`], [k3s, Velero], [Versionierung an],
)

#cmd("Mac")[```bash
aws s3api create-bucket --bucket "$PRAEFIX-obs-thanos" \
  --create-bucket-configuration LocationConstraint=eu-central-1
aws s3api create-bucket --bucket "$PRAEFIX-obs-loki" \
  --create-bucket-configuration LocationConstraint=eu-central-1
aws s3api create-bucket --bucket "$PRAEFIX-obs-tempo" \
  --create-bucket-configuration LocationConstraint=eu-central-1
aws s3api create-bucket --bucket "$PRAEFIX-obs-backup" \
  --create-bucket-configuration LocationConstraint=eu-central-1
```][Legt die vier Buckets in Frankfurt an. `$PRAEFIX` hast du oben gesetzt, die Shell ersetzt es in jedem Befehl. Außerhalb von `us-east-1` verlangt AWS die Region zusätzlich als `LocationConstraint`.]

Meldet AWS `BucketAlreadyExists`, hat jemand anderes auf der Welt diesen Namen schon. Wähle dann ein anderes Präfix.

== Die Riegel vor dem ersten Byte

Neue Buckets sind heute schon privat und verschlüsselt. Du setzt alles trotzdem ausdrücklich. Dann steht es im Befehlsverlauf, und eine geänderte Voreinstellung bei AWS ändert nichts an deinen Buckets.

#cmd("Mac")[```bash
BLOCK=BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-public-access-block --bucket "$PRAEFIX-obs-thanos" \
  --public-access-block-configuration "$BLOCK"
aws s3api put-public-access-block --bucket "$PRAEFIX-obs-loki" \
  --public-access-block-configuration "$BLOCK"
aws s3api put-public-access-block --bucket "$PRAEFIX-obs-tempo" \
  --public-access-block-configuration "$BLOCK"
aws s3api put-public-access-block --bucket "$PRAEFIX-obs-backup" \
  --public-access-block-configuration "$BLOCK"
```][Block Public Access mit allen vier Schaltern. Selbst eine versehentlich öffentliche Policy oder ACL greift dann nicht mehr.]

#cmd("Mac")[```bash
aws s3api put-bucket-encryption --bucket "$PRAEFIX-obs-thanos" \
  --server-side-encryption-configuration file://observability/aws/encryption.json
aws s3api put-bucket-encryption --bucket "$PRAEFIX-obs-loki" \
  --server-side-encryption-configuration file://observability/aws/encryption.json
aws s3api put-bucket-encryption --bucket "$PRAEFIX-obs-tempo" \
  --server-side-encryption-configuration file://observability/aws/encryption.json
aws s3api put-bucket-encryption --bucket "$PRAEFIX-obs-backup" \
  --server-side-encryption-configuration file://observability/aws/encryption.json
```][`observability/aws/encryption.json` setzt `"SSEAlgorithm": "AES256"`. Das ist SSE-S3: AWS verschlüsselt jedes Objekt beim Schreiben mit eigenen Schlüsseln.]

#warum[
  SSE-KMS mit eigenem Schlüssel klingt sicherer. Es bringt dir zwei Dinge: ein Protokoll jeder Entschlüsselung in CloudTrail und die Möglichkeit, den Schlüssel zu sperren. Dafür kostet jeder Lese- und Schreibzugriff eine KMS-Anfrage, und jede Komponente braucht zusätzlich `kms:Decrypt` und `kms:GenerateDataKey`. Thanos Store und Loki lesen sehr viele kleine Stücke. Für ein Labor ist SSE-S3 deshalb die bessere Wahl. In einer Firma mit Prüfpflichten nimmst du SSE-KMS mit Bucket Key, der die Zahl der KMS-Anfragen stark senkt.
]

Verschlüsselung im Bucket hilft nicht, wenn die Daten unverschlüsselt hinfließen. Eine Bucket-Policy verbietet deshalb jeden Zugriff ohne TLS.

#datei("observability/aws/bucket-policy-tls.json (Ausschnitt)")[```json
"Effect": "Deny",
"Principal": "*",
"Action": "s3:*",
"Resource": ["arn:aws:s3:::BUCKET", "arn:aws:s3:::BUCKET/*"],
"Condition": {"Bool": {"aws:SecureTransport": "false"}}
```, erklaerung: [Ein `Deny` schlägt jedes `Allow`. `BUCKET` ist ein Platzhalter, der Befehl setzt den echten Namen ein.]]

#cmd("Mac")[```bash
sed "s|BUCKET|$PRAEFIX-obs-thanos|g" observability/aws/bucket-policy-tls.json > /tmp/policy.json
aws s3api put-bucket-policy --bucket "$PRAEFIX-obs-thanos" --policy file:///tmp/policy.json
```][Setzt die TLS-Pflicht für den Bucket `thanos`. `sed` setzt den echten Namen in die Vorlage ein, die Datei in `/tmp` enthält keine Geheimnisse.]

#cmd("Mac")[```bash
sed "s|BUCKET|$PRAEFIX-obs-loki|g" observability/aws/bucket-policy-tls.json > /tmp/policy.json
aws s3api put-bucket-policy --bucket "$PRAEFIX-obs-loki" --policy file:///tmp/policy.json
sed "s|BUCKET|$PRAEFIX-obs-tempo|g" observability/aws/bucket-policy-tls.json > /tmp/policy.json
aws s3api put-bucket-policy --bucket "$PRAEFIX-obs-tempo" --policy file:///tmp/policy.json
sed "s|BUCKET|$PRAEFIX-obs-backup|g" observability/aws/bucket-policy-tls.json > /tmp/policy.json
aws s3api put-bucket-policy --bucket "$PRAEFIX-obs-backup" --policy file:///tmp/policy.json
```][Dasselbe für die übrigen drei Buckets, je zwei Zeilen pro Bucket.]

#cmd("Mac")[```bash
aws s3api put-bucket-versioning --bucket "$PRAEFIX-obs-backup" \
  --versioning-configuration Status=Enabled
```][Versionierung nur für den Backup-Bucket. Überschreibt oder löscht jemand eine Sicherung, bleibt die alte Version erhalten.]

#pruefe[
  `aws s3api get-public-access-block --bucket "$PRAEFIX-obs-backup"` zeigt vier Mal `true`. `get-bucket-versioning` zeigt für den Backup-Bucket `"Status": "Enabled"`, für die anderen drei nichts. Das ist richtig so.
]

#falle[
  Schalte die Versionierung nicht für Thanos, Loki und Tempo ein. Der Thanos Compactor fasst Blöcke ständig zusammen und löscht die alten. Mit Versionierung bleiben alle gelöschten Blöcke als alte Versionen liegen, und du zahlst sie weiter, ohne sie je zu lesen.
]

== Lebensdauer: Lifecycle-Regeln

Eine Lifecycle-Regel löscht Objekte nach einer festen Zahl von Tagen oder verschiebt sie in eine günstigere Speicherklasse. Das klingt nach der idealen Retention. Für Thanos, Loki und Tempo ist sie es aber nicht.

#warum[
  Jedes dieser Tools führt eigene Buchhaltung über seine Objekte. Thanos kennt jeden Block über seine `meta.json`, Loki führt einen Index über seine Chunks, Tempo eine Blockliste pro Mandant. Löscht S3 ein Objekt, bevor das Tool es selbst aufgibt, zeigt der Index ins Leere. Abfragen brechen mit „object not found“ ab, und der Thanos Compactor hält mit einem Fehler an. Deshalb gilt: Die Retention macht das Tool. Die Lifecycle-Regel ist nur ein Sicherheitsnetz und muss *später* greifen als die Tool-Retention.
]

#tabelle(
  (auto, 1fr, auto),
  ([Bucket], [Retention im Tool], [Lifecycle-Ablauf]),
  [`thanos`], [Compactor: Rohdaten 30 Tage, 5-Minuten-Daten 90 Tage, 1-Stunden-Daten 365 Tage (Kapitel 4)], [400 Tage],
  [`loki`], [`retention_period: 168h`, also 7 Tage (Kapitel 8)], [60 Tage],
  [`tempo`], [`retention: 168h`, also 7 Tage (Kapitel 9)], [30 Tage],
  [`backup`], [Velero-TTL und etcd-Retention (Kapitel 12)], [alte Versionen nach 30 Tagen],
)

#datei("observability/aws/lifecycle-thanos.json (Ausschnitt)")[```json
{ "ID": "abgebrochene-uploads", "Status": "Enabled",
  "Filter": {"Prefix": ""},
  "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7} },
{ "ID": "sicherheitsnetz-nach-thanos-retention", "Status": "Enabled",
  "Filter": {"Prefix": ""},
  "Expiration": {"Days": 400} }
```, erklaerung: [Die erste Regel räumt halbe Uploads weg. Sie entstehen, wenn ein Pod mitten im Hochladen eines großen Blocks stirbt, sind unsichtbar und kosten trotzdem. Die zweite Regel liegt 35 Tage hinter der längsten Thanos-Retention. `lifecycle-loki.json` und `lifecycle-tempo.json` sind genauso gebaut, nur mit anderen Tagen.]]

Erhöhst du später die Retention in Loki oder Tempo, passt du zuerst die Lifecycle-Regel an. Sonst löscht S3 Daten, die das Tool noch für gültig hält.

#cmd("Mac")[```bash
aws s3api put-bucket-lifecycle-configuration --bucket "$PRAEFIX-obs-thanos" \
  --lifecycle-configuration file://observability/aws/lifecycle-thanos.json
aws s3api put-bucket-lifecycle-configuration --bucket "$PRAEFIX-obs-loki" \
  --lifecycle-configuration file://observability/aws/lifecycle-loki.json
aws s3api put-bucket-lifecycle-configuration --bucket "$PRAEFIX-obs-tempo" \
  --lifecycle-configuration file://observability/aws/lifecycle-tempo.json
aws s3api put-bucket-lifecycle-configuration --bucket "$PRAEFIX-obs-backup" \
  --lifecycle-configuration file://observability/aws/lifecycle-backup.json
```][Setzt pro Bucket die passende Regel. Jeder Bucket bekommt seine eigene Datei.]

#pruefe[
  `aws s3api get-bucket-lifecycle-configuration --bucket "$PRAEFIX-obs-backup"` zeigt die Regel `alte-versionen-und-uploads` mit `NoncurrentVersionExpiration` von 30 Tagen. Alte Versionen einer Sicherung verschwinden also erst nach einem Monat.
]

#falle[
  Ein Übergang nach `STANDARD_IA` oder Glacier spart Speicherkosten, schadet hier aber. Thanos Store und der Compactor lesen auch alte Blöcke regelmäßig, und jeder Lesezugriff auf IA kostet extra. Objekte in Glacier Flexible Retrieval kann Thanos gar nicht mehr lesen. Übergänge lohnen sich nur für Daten, die du fast nie liest, etwa alte Sicherungen.
]

== Ein Benutzer, eine Policy pro Bucket

Thanos, Loki und Tempo laufen auf `obs` und teilen sich den IAM-Benutzer `obs-lab`. Er bekommt für jeden Bucket eine eigene, kleine Policy. Die Sicherungen schreiben dagegen alle drei Cluster, deshalb bekommen sie einen zweiten Benutzer `obs-lab-backup`. Ein gestohlener Schlüssel aus `app1` reicht dann nicht an deine Metriken heran.

#datei("observability/aws/iam-policy-thanos.json (Ausschnitt)")[```json
{ "Effect": "Allow",
  "Action": ["s3:ListBucket"],
  "Resource": "arn:aws:s3:::PRAEFIX-obs-thanos" },
{ "Effect": "Allow",
  "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
  "Resource": "arn:aws:s3:::PRAEFIX-obs-thanos/*" }
```, erklaerung: [`ListBucket` gilt für den Bucket, die drei Objektrechte nur für seinen Inhalt. Mehr braucht Thanos nicht. Tempo bekommt zusätzlich `s3:GetObjectTagging` und `s3:PutObjectTagging`.]]

Die Backup-Policy erlaubt Schreiben und Löschen, verbietet aber ausdrücklich `s3:DeleteObjectVersion`, `s3:PutBucketVersioning` und `s3:PutLifecycleConfiguration`. Wer den Backup-Schlüssel stiehlt, kann Sicherungen also nur scheinbar löschen. Die alten Versionen bleiben 30 Tage liegen, und weder Versionierung noch Lifecycle lassen sich mit diesem Schlüssel abschalten.

#cmd("Mac")[```bash
aws iam create-user --user-name obs-lab
aws iam create-user --user-name obs-lab-backup
```][Legt die beiden technischen Benutzer an. Sie haben kein Passwort und können sich nicht in der Konsole anmelden.]

#cmd("Mac")[```bash
sed "s|PRAEFIX|$PRAEFIX|g" observability/aws/iam-policy-thanos.json > /tmp/policy.json
aws iam put-user-policy --user-name obs-lab \
  --policy-name obs-thanos --policy-document file:///tmp/policy.json
sed "s|PRAEFIX|$PRAEFIX|g" observability/aws/iam-policy-loki.json > /tmp/policy.json
aws iam put-user-policy --user-name obs-lab \
  --policy-name obs-loki --policy-document file:///tmp/policy.json
sed "s|PRAEFIX|$PRAEFIX|g" observability/aws/iam-policy-tempo.json > /tmp/policy.json
aws iam put-user-policy --user-name obs-lab \
  --policy-name obs-tempo --policy-document file:///tmp/policy.json
```][Hängt drei Inline-Policies an `obs-lab`, eine pro Bucket. Inline-Policies verschwinden mit dem Benutzer, du räumst später also nichts doppelt auf.]

#cmd("Mac")[```bash
sed "s|PRAEFIX|$PRAEFIX|g" observability/aws/iam-policy-backup.json > /tmp/policy.json
aws iam put-user-policy --user-name obs-lab-backup \
  --policy-name obs-backup --policy-document file:///tmp/policy.json
```][Die Backup-Policy für den zweiten Benutzer. Seinen Schlüssel erzeugst du erst in Kapitel 12.]

#pruefe[
  `aws iam list-user-policies --user-name obs-lab` nennt `obs-loki`, `obs-tempo` und `obs-thanos`.
]

Jetzt der heikle Moment: der Zugangsschlüssel. AWS zeigt den geheimen Teil genau einmal. Er wandert deshalb direkt in zwei Shell-Variablen und von dort in Kubernetes-Secrets, ohne je auf dem Bildschirm oder in einer Datei zu landen.

#cmd("Mac")[```bash
read -r AK SK <<< "$(aws iam create-access-key --user-name obs-lab \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)"
```][Erzeugt den Schlüssel und liest beide Teile in `AK` und `SK`. Schließe das Terminal erst, wenn alle Secrets dieses Kapitels angelegt sind.]

#pruefe[
  `echo "${#AK} ${#SK}"` gibt nur die Längen aus: `20 40`. Steht dort `0 0`, ist der Befehl fehlgeschlagen. Ein Benutzer darf höchstens zwei Schlüssel haben. Prüfe mit `aws iam list-access-keys --user-name obs-lab` und lösche überzählige mit `aws iam delete-access-key`.
]

== Thanos umziehen

Die Reihenfolge ist wichtig. Erst hält der Compactor an, dann kopierst du die Blöcke, dann schaltest du um, und zum Schluss kopierst du noch einmal, was in der Zwischenzeit dazugekommen ist. So läuft nie ein Compactor auf zwei Buckets gleichzeitig.

#cmd("Mac")[```bash
kubectl --context obs -n monitoring scale deployment thanos-compact --replicas=0
```][Hält den Compactor an. Er ist der Einzige, der Blöcke löscht und umschreibt. Receive und Store laufen weiter.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring port-forward svc/s3 8333:8333
```][Macht SeaweedFS auf `localhost:8333` erreichbar. Lass dieses Terminal offen und arbeite in einem zweiten weiter. Dort musst du `AWS_PROFILE`, `AWS_REGION` und `PRAEFIX` erneut setzen.]

#cmd("Mac")[```bash
SW=$(kubectl --context obs -n monitoring get secret s3-config \
  -o jsonpath='{.data.s3\.json}' | base64 -d)
SWAK=$(echo "$SW" | jq -r '.identities[] | select(.name=="thanos") | .credentials[0].accessKey')
SWSK=$(echo "$SW" | jq -r '.identities[] | select(.name=="thanos") | .credentials[0].secretKey')
```][Liest die Schlüssel des SeaweedFS-Kontos `thanos` aus `s3-config` in zwei Variablen, ohne sie anzuzeigen.]

#cmd("Mac")[```bash
AWS_ACCESS_KEY_ID=$SWAK AWS_SECRET_ACCESS_KEY=$SWSK \
  aws s3 sync s3://thanos ./umzug/thanos --endpoint-url http://localhost:8333
```][Lädt alle Blöcke aus SeaweedFS in den Ordner `umzug/thanos`. Die beiden Variablen gelten nur für diesen einen Aufruf. Laut Kapitel 3 sind das höchstens einige Gigabyte.]

#falle[
  `umzug/` liegt im Repo-Verzeichnis. Trag es in `.gitignore` ein, bevor du `git add` tippst, sonst landen Gigabytes an Metriken in Git. Alternativ legst du den Ordner unter `/tmp` an.
]

#cmd("Mac")[```bash
aws s3 sync ./umzug/thanos "s3://$PRAEFIX-obs-thanos"
```][Lädt die Blöcke nach AWS. Jetzt gilt wieder dein Profil `obs-admin`.]

#datei("observability/aws/thanos-objstore-aws.yml")[```yaml
type: S3
config:
  bucket: PRAEFIX-obs-thanos
  endpoint: s3.eu-central-1.amazonaws.com
  region: eu-central-1
  insecure: false
  bucket_lookup_type: virtual-hosted
```, erklaerung: [Gegenüber SeaweedFS ändern sich vier Dinge: der Bucket, der AWS-Endpunkt, `insecure: false` für HTTPS und die virtuelle Adressierung `<bucket>.s3...` statt Pfad-Stil. Die Schlüsselzeilen fehlen absichtlich.]]

#cmd("Mac")[```bash
{ sed "s|PRAEFIX|$PRAEFIX|" observability/aws/thanos-objstore-aws.yml
  printf '  access_key: %s\n  secret_key: %s\n' "$AK" "$SK"; } |
kubectl --context obs -n monitoring create secret generic thanos-objstore \
  --from-file=objstore.yml=/dev/stdin --dry-run=client -o yaml |
kubectl --context obs -n monitoring apply -f -
```][Baut das neue `objstore.yml` aus Vorlage und Schlüsseln und ersetzt das Secret. `printf` ist in die Shell eingebaut. Die Schlüssel tauchen deshalb weder in der Prozessliste noch in einer Datei auf.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring rollout restart \
  statefulset/thanos-receive deployment/thanos-store
```][Secrets werden nur beim Start gelesen. Beim Herunterfahren lädt Receive seine letzten Blöcke noch nach SeaweedFS hoch, danach schreibt es nach AWS.]

#cmd("Mac")[```bash
AWS_ACCESS_KEY_ID=$SWAK AWS_SECRET_ACCESS_KEY=$SWSK \
  aws s3 sync s3://thanos ./umzug/thanos --endpoint-url http://localhost:8333
aws s3 sync ./umzug/thanos "s3://$PRAEFIX-obs-thanos"
```][Der zweite Durchgang holt, was Receive beim Herunterfahren noch nach SeaweedFS geschrieben hat. `sync` überträgt nur, was neu ist.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring scale deployment thanos-compact --replicas=1
```][Startet den Compactor wieder, jetzt gegen AWS.]

#pruefe[
  `kubectl --context obs -n monitoring logs deployment/thanos-store --tail=20` zeigt keine Zeilen mit `level=error`. In Grafana zeigt eine Abfrage über die letzten sieben Tage, etwa `sum by (cluster) (up)`, eine durchgehende Linie ohne Lücke vor dem Umzug. Lücken von wenigen Minuten während des Neustarts sind normal.
]

== Loki und Tempo umschalten

Loki und Tempo lesen ihre Schlüssel aus `loki-s3` und `tempo-s3`. Endpunkt und Bucket stehen in den Helm-Werten. Für AWS kommen zwei kleine Zusatzdateien dazu.

#datei("observability/aws/loki-aws.yaml")[```yaml
loki:
  storage:
    bucketNames:
      chunks: PRAEFIX-obs-loki
      ruler: PRAEFIX-obs-loki
      admin: PRAEFIX-obs-loki
    s3:
      endpoint: s3.eu-central-1.amazonaws.com
      region: eu-central-1
      s3ForcePathStyle: false
      insecure: false
```, erklaerung: [Wird *nach* `observability/central/loki/values.yaml` angegeben und überschreibt nur diese Felder. `tempo-aws.yaml` setzt dasselbe unter `tempo.storage.trace.s3`.]]

#cmd("Mac")[```bash
printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$AK" "$SK" |
  kubectl --context obs -n monitoring create secret generic loki-s3 \
    --from-env-file=/dev/stdin --dry-run=client -o yaml |
  kubectl --context obs -n monitoring apply -f -
printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$AK" "$SK" |
  kubectl --context obs -n monitoring create secret generic tempo-s3 \
    --from-env-file=/dev/stdin --dry-run=client -o yaml |
  kubectl --context obs -n monitoring apply -f -
```][Ersetzt die SeaweedFS-Schlüssel in beiden Secrets durch den AWS-Schlüssel von `obs-lab`.]

#cmd("Mac")[```bash
sed "s|PRAEFIX|$PRAEFIX|g" observability/aws/loki-aws.yaml |
helm --kube-context obs upgrade loki grafana-community/loki --version 21.0.0 \
  -n monitoring -f observability/central/loki/values.yaml -f -
```][`-f -` liest die zweite Wertedatei von der Standardeingabe, nachdem `sed` das Präfix eingesetzt hat. Das Upgrade startet Loki neu, und Loki liest dabei auch das neue Secret.]

#cmd("Mac")[```bash
sed "s|PRAEFIX|$PRAEFIX|g" observability/aws/tempo-aws.yaml |
helm --kube-context obs upgrade tempo grafana-community/tempo --version 3.2.1 \
  -n monitoring -f observability/central/tempo/values.yaml -f -
```][Dasselbe für Tempo.]

Zum Schluss löscht `unset AK SK SWAK SWSK` alle Schlüssel aus der Shell. Ab jetzt stehen sie nur noch in den Secrets.

#pruefe[
  In Grafana unter *Explore* liefert die Datenquelle Loki mit `{cluster="app1"}` neue Zeilen, und Tempo findet Traces der letzten Minuten. `aws s3 ls "s3://$PRAEFIX-obs-loki/" --recursive | head` zeigt neue Objekte.
]

#aufgabe[
  Ziehe auch die alten Logs und Traces um. Das Muster kennst du von Thanos. Hinweise: Die SeaweedFS-Schlüssel für `loki` und `tempo` stehen in `s3-config`, wie bei Thanos. Halte Loki vorher mit `kubectl scale statefulset loki --replicas=0` an, damit sich der Bucket während der Kopie nicht ändert. Überlege: Warum reicht es bei Loki nicht, nur die Chunks zu kopieren, und welcher Ordner muss unbedingt mit?
]

== Was kostet das?

Eine feste Zahl kann dir niemand nennen. Die Preise ändern sich, und sie hängen von Region und Speicherklasse ab. Den Rechenweg kannst du aber selbst gehen. Schlag die aktuellen Preise für `eu-central-1` auf der offiziellen Seite #link("https://aws.amazon.com/s3/pricing/")[aws.amazon.com/s3/pricing] nach.

#tabelle(
  (auto, 1fr, 1fr),
  ([Posten], [So misst du die Menge], [Rechnung]),
  [Speicher], [`aws s3 ls s3://<bucket> --recursive --summarize` (Zeile `Total Size`)], [GB × Preis pro GB und Monat],
  [Schreibanfragen], [Thanos: `sum(increase(thanos_objstore_bucket_operations_total{operation="upload"}[30d]))`], [Anzahl ÷ 1000 × Preis pro 1000 PUT],
  [Leseanfragen], [Dieselbe Metrik mit `operation=~"get|get_range"`], [Anzahl ÷ 1000 × Preis pro 1000 GET],
  [Datenabfluss], [Was Store Gateway, Loki und Tempo aus S3 lesen], [GB × Preis pro GB Datentransfer ins Internet],
)

#warum[
  Der letzte Posten wird gern vergessen. Deine VMs stehen nicht in AWS. Jede Grafana-Abfrage über alte Daten zieht Blöcke aus Frankfurt zu dir nach Hause, und das ist Datentransfer ins Internet. Speicher ist billig, Abfluss nicht. Ein Dashboard mit 30-Tage-Zeitraum und automatischer Aktualisierung kann teurer werden als der ganze Speicher. Lege dir deshalb in der AWS-Konsole unter *Billing* ein Budget mit Warnung an, bevor die erste Rechnung kommt.
]

== Spiegelung, wenn eine Kopie nicht reicht

Auch eine Region kann ausfallen. Für Sicherungen bietet AWS deshalb die Replikation in einen zweiten Bucket an, auch in einer anderen Region. Beide Buckets brauchen Versionierung, und du zahlst Speicher und Übertragung doppelt. Für Metriken, Logs und Traces lohnt sich das im Labor nicht. Für den Backup-Bucket reicht oft eine einfachere Lösung: SeaweedFS bleibt als zweite, lokale Kopie, die du gelegentlich mit `aws s3 sync` abgleichst.

#gelernt(
  [Ein Bucket pro Komponente erlaubt eigene Rechte, Lebensdauer und Versionierung.],
  [Block Public Access, SSE-S3 und eine TLS-Pflicht setzt du, bevor das erste Byte fließt.],
  [Die Retention steuert das Tool. Eine Lifecycle-Regel ist nur das Sicherheitsnetz und muss später greifen.],
  [Schlüssel gehen per `printf` und Standardeingabe direkt in Secrets, nie in Dateien oder auf den Bildschirm.],
  [Bei Speicher außerhalb des Labors kostet vor allem das Lesen, nicht das Liegen.],
)

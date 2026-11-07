#import "../lib.typ": *

#kapitel(
  [Zusatz: External Secrets],
  ziel: [Werte aus OpenBao erscheinen automatisch als Kubernetes-Secrets, und Änderungen im Tresor kommen von selbst im Cluster an.],
  zeit: [60 Minuten],
  braucht: [Kapitel 15],
)

== Wie die Teile zusammenspielen

Deine Anwendungen kennen nur normale Kubernetes-Secrets. Sie sollen nichts von OpenBao wissen müssen. Der External Secrets Operator (ESO) schlägt die Brücke:

+ Du beschreibst in einem `ExternalSecret`, welche Werte du brauchst.
+ ESO meldet sich bei OpenBao an, mit einem kurzlebigen ServiceAccount-Token.
+ OpenBao prüft das Token beim Kubernetes-API-Server.
+ ESO holt die Werte und schreibt ein normales Secret.
+ Ändert sich der Wert im Tresor, aktualisiert ESO das Secret.

#warum[
  Im Git liegt jetzt nur noch die Beschreibung, wo ein Wert liegt, nie der Wert selbst. Damit lässt sich die gesamte Konfiguration gefahrlos einchecken. Das Secret im Cluster bleibt als Kopie bestehen, ist aber dank `secrets-encryption` aus Kapitel 2 im Datastore verschlüsselt.
]

== Installieren

#cmd("Mac")[```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
```][Trägt das Repository ein.]

#cmd("Mac")[```bash
helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --version 2.14.0 --wait
```][Installiert den Operator mit Webhook und Cert-Controller.]

#cmd("Mac")[```bash
kubectl get pods -n external-secrets
```][Drei Pods sollten laufen.]

== Das Konto für den Zugriff

ESO bekommt ein eigenes Konto. OpenBao wird genau diesem Konto vertrauen.

#cmd("Mac")[```bash
kubectl create serviceaccount eso-openbao -n external-secrets
```][Dieses Konto hat keine Rechte in Kubernetes und braucht auch keine. Es dient nur als Ausweis gegenüber OpenBao.]

== OpenBao vertraut Kubernetes

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- sh
```][Shell im Pod. Der Tresor muss entsiegelt sein.]

#cmd("Pod")[```bash
bao login
```][Anmelden mit dem Root Token.]

#cmd("Pod")[```bash
bao auth enable kubernetes
```][Aktiviert die Anmeldung per ServiceAccount.]

#cmd("Pod")[```bash
bao write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc:443
```][Sagt OpenBao, wo der API-Server liegt. CA-Zertifikat und Prüf-Token nimmt OpenBao automatisch aus dem eigenen Pod. Das Chart hat seinem Konto dafür die Rolle `system:auth-delegator` gegeben.]

#cmd("Pod")[```bash
bao write auth/kubernetes/role/eso \
  bound_service_account_names=eso-openbao \
  bound_service_account_namespaces=external-secrets \
  audience=openbao \
  policies=eso-lesen \
  ttl=1h
```][Verbindet alles: Das Konto `eso-openbao` aus `external-secrets` bekommt die Policy `eso-lesen`. `audience` legt fest, für wen das Token ausgestellt sein muss. So kann ein Token für einen anderen Dienst hier nicht missbraucht werden.]

#cmd("Pod")[```bash
rm -f ~/.bao-token
exit
```][Entfernt das gemerkte Root Token und führt zurück zum Mac.]

== Die Verbindung beschreiben

#datei("security/secrets/store.yaml", ```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao
spec:
  provider:
    vault:
      server: https://openbao.openbao.svc.cluster.local:8200
      path: secret
      version: v2
      caProvider:
        type: Secret
        name: openbao-tls
        namespace: openbao
        key: ca.crt
      auth:
        kubernetes:
          mountPath: kubernetes
          role: eso
          serviceAccountRef:
            name: eso-openbao
            namespace: external-secrets
            audiences:
              - openbao
```, erklaerung: [
  Laut ESO-Doku läuft OpenBao über den `vault`-Provider, weil OpenBao dieselbe API spricht. In den CRDs gibt es inzwischen auch einen eigenen Schlüssel `openBao`, dieses Buch bleibt aber beim dokumentierten Weg. `caProvider` nimmt das Vertrauen aus dem Zertifikat von Kapitel 15. `audiences` muss zur Rolle in OpenBao passen.
])

#cmd("Mac")[```bash
kubectl apply -f security/secrets/store.yaml
kubectl get clustersecretstore openbao
```][Die Spalte `STATUS` zeigt `Valid`, `READY` zeigt `True`.]

#falle[
  Bei `InvalidProviderConfig` hilft `kubectl describe clustersecretstore openbao`. Häufige Ursachen: Der Tresor ist versiegelt, die `audience` passt nicht, oder die Rolle nennt ein falsches Konto.
]

== Das erste externe Secret

#datei("security/secrets/demo-db.yaml", ```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: demo-db
  namespace: demo
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: demo-db
  data:
    - secretKey: password
      remoteRef:
        key: apps/demo
        property: password
```, erklaerung: [
  `refreshInterval: 1m` ist fürs Lernen kurz, im Betrieb reichen eine Stunde oder mehr. `remoteRef.key` ist der Pfad im Tresor, ohne `secret/` und ohne `data/`. `property` wählt den Wert darin. `target.name` ist der Name des entstehenden Secrets.
])

#cmd("Mac")[```bash
kubectl apply -f security/secrets/demo-db.yaml
kubectl get externalsecret -n demo
```][`STATUS` sollte `SecretSynced` zeigen.]

#cmd("Mac")[```bash
kubectl get secret demo-db -n demo \
  -o jsonpath='{.data.password}' | base64 -d; echo
```][Zeigt den Wert aus dem Tresor. Du hast nie eine Secret-Datei angelegt.]

== Ändern und mitverfolgen

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- sh
```][Wieder in den Tresor.]

#cmd("Pod")[```bash
bao login
```][Anmelden.]

#cmd("Pod")[```bash
bao kv put secret/apps/demo \
  password="drittes-passwort" user=demo
```][Ändert den Wert. Nur noch hier wird er gepflegt.]

#cmd("Pod")[```bash
rm -f ~/.bao-token
exit
```][Entfernt das Token und führt zurück zum Mac.]

#cmd("Mac")[```bash
kubectl get secret demo-db -n demo \
  -o jsonpath='{.data.password}' | base64 -d; echo
```][Nach spätestens einer Minute erscheint der neue Wert.]

#falle[
  Das Secret ändert sich, die Pods aber nicht zwingend. Ein als *Volume* eingebundenes Secret wird nach kurzer Zeit im Container aktualisiert, die Anwendung muss die Datei allerdings neu lesen. Ein als *Umgebungsvariable* eingebundenes Secret ändert sich dagegen nie im laufenden Prozess. Dann hilft nur `kubectl rollout restart`.
]

== Wer darf jetzt was?

Prüfe das Modell einmal gegen das, was du gelernt hast:

#cmd("Mac")[```bash
kubectl auth can-i get secrets -n demo \
  --as=system:serviceaccount:demo:app
```][Erwartet: `no`. Das Konto `app` darf nur Pods lesen. Genau deshalb hast du in Kapitel 3 so eng geschnitten.]

Probiere auch den Audit-Blick in Grafana:

```logql
{namespace="openbao"} |= "secret/data/apps/demo"
```

Damit siehst du jeden Lesezugriff von ESO auf diesen Pfad, mit Zeitpunkt und Konto.

== Lokis Zugangsdaten umziehen

Jetzt übernimmst du eine echte Anwendung. Lokis S3-Secret aus Kapitel 10 wandert in den Tresor.

#cmd("Mac")[```bash
ACCESS=$(kubectl get secret loki-s3 -n monitoring \
  -o jsonpath='{.data.S3_ACCESS_KEY}' | base64 -d)
SECRET=$(kubectl get secret loki-s3 -n monitoring \
  -o jsonpath='{.data.S3_SECRET_KEY}' | base64 -d)
```][Liest die Werte in Shell-Variablen.]

#cmd("Mac")[```bash
kubectl exec -i openbao-0 -n openbao -- sh -c 'bao login -no-print -'
```][Liest das Token von der Standardeingabe. Füge es ein und drücke `Ctrl-D`. So landet es nicht in der Historie.]

#cmd("Mac")[```bash
printf '{"S3_ACCESS_KEY":"%s","S3_SECRET_KEY":"%s"}' "$ACCESS" "$SECRET" \
  | kubectl exec -i openbao-0 -n openbao -- \
    bao kv put secret/apps/loki-s3 -
```][Überträgt die Werte als JSON über die Standardeingabe. Sie tauchen weder in der Prozessliste noch im Log auf.]

#cmd("Mac")[```bash
unset ACCESS SECRET
kubectl exec openbao-0 -n openbao -- rm -f /home/openbao/.bao-token
```][Entfernt die Werte aus der Shell und das Token aus dem Pod. Prüfe mit `kubectl exec openbao-0 -n openbao -- sh -c 'echo $HOME'`, ob das Home-Verzeichnis bei dir so heißt.]

#datei("security/secrets/loki-s3.yaml", ```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: loki-s3
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: loki-s3
    creationPolicy: Merge
  dataFrom:
    - extract:
        key: apps/loki-s3
```, erklaerung: [
  `dataFrom.extract` übernimmt alle Schlüssel des Pfades. `creationPolicy: Merge` schreibt in das bestehende Secret, denn das gehört noch dir und nicht ESO.
])

#cmd("Mac")[```bash
kubectl apply -f security/secrets/loki-s3.yaml
kubectl get externalsecret -n monitoring
```][Ab jetzt ist OpenBao die Quelle der Wahrheit für dieses Secret.]

#aufgabe[
  Migriere nach demselben Muster das Grafana-Passwort. Überlege vorher: Was müsste passieren, damit Grafana ein geändertes Passwort auch wirklich übernimmt?
]

#gelernt(
  [ESO übersetzt Tresor-Pfade in normale Kubernetes-Secrets.],
  [Im Git liegt nur noch der Verweis auf einen Wert, nie der Wert selbst.],
  [OpenBao prüft ServiceAccount-Tokens beim API-Server, und `audience` bindet sie an einen Dienst.],
  [Umgebungsvariablen ändern sich nie im laufenden Prozess.],
  [Kubernetes-Secrets sind die Kopie, der Tresor bleibt die Quelle.],
)

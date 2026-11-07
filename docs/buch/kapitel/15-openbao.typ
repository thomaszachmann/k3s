#import "../lib.typ": *

#kapitel(
  [Zusatz: OpenBao als Tresor],
  ziel: [Du betreibst einen eigenen Secrets-Server mit TLS und Audit-Log und verstehst, wie Versiegeln, Richtlinien und Anmelden funktionieren.],
  zeit: [75 Minuten],
  braucht: [Kapitel 14],
)

== Warum ein Tresor

Bisher liegen deine Secrets als Kubernetes-Objekte vor, erzeugt von Skripten. Das hat Grenzen: Es gibt keine Historie, keine feinen Rechte pro Pfad und kein Protokoll, wer welchen Wert gelesen hat. OpenBao ist ein quelloffener Fork von Vault und löst genau das.

#tabelle(
  (auto, 1fr),
  ([Begriff], [Bedeutung]),
  [Seal/Unseal], [Der Tresor startet versiegelt, die Daten sind verschlüsselt und unzugänglich.],
  [Unseal Keys], [Teilschlüssel, von denen eine Mindestzahl den Tresor öffnet.],
  [Root Token], [Allmächtiges Anfangs-Token, nur für die Ersteinrichtung.],
  [Secrets Engine], [Speicherort. `kv-v2` ist ein Schlüssel-Wert-Speicher mit Versionen.],
  [Auth Method], [Wie sich jemand anmeldet, hier per Kubernetes-ServiceAccount.],
  [Policy], [Was ein angemeldetes Token darf, pro Pfad.],
)

#warum[
  Versiegeln schützt die Daten, wenn jemand die Disk stiehlt oder an den Pod kommt: Ohne Unseal Keys sind die Daten wertlos. Der Preis dafür: Nach jedem Neustart muss jemand den Tresor öffnen. Wer das tut, musst du entscheiden. Bei einem einzelnen Node im Heimnetz bist du das, von Hand.
]

== Das TLS-Zertifikat vorbereiten

#cmd("Mac")[```bash
kubectl create namespace openbao
```][Der Standard `baseline` genügt, OpenBao braucht keinen Host-Zugriff.]

#datei("security/tls/openbao-cert.yaml", ```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openbao-tls
  namespace: openbao
spec:
  secretName: openbao-tls
  duration: 2160h
  renewBefore: 720h
  dnsNames:
    - openbao
    - openbao.openbao
    - openbao.openbao.svc
    - openbao.openbao.svc.cluster.local
    - localhost
  ipAddresses:
    - 127.0.0.1
  issuerRef:
    name: k3s2-ca
    kind: ClusterIssuer
    group: cert-manager.io
```, erklaerung: [
  `127.0.0.1` und `localhost` sind nötig, weil der `bao`-Befehl im Pod die lokale Adresse `https://127.0.0.1:8200` anspricht. Das Chart setzt das so.
])

#cmd("Mac")[```bash
kubectl apply -f security/tls/openbao-cert.yaml
kubectl get certificate -n openbao
```][Das Secret `openbao-tls` muss bereitstehen, bevor der Pod startet.]

== Installieren

#datei("openbao/values.yaml", ```yaml
global:
  tlsDisable: false

injector:
  enabled: false

server:
  standalone:
    enabled: true
    config: |
      ui = true

      listener "tcp" {
        address         = "[::]:8200"
        cluster_address = "[::]:8201"
        tls_cert_file   = "/openbao/tls/tls.crt"
        tls_key_file    = "/openbao/tls/tls.key"
      }

      storage "pebbledb" {
        path = "/openbao/data/pebbledb"
      }

      audit "file" "to-stdout" {
        description = "Audit-Log auf die Standardausgabe"
        options {
          file_path = "stdout"
        }
      }
  dataStorage:
    enabled: true
    size: 1Gi
    storageClass: local-path
  extraEnvironmentVars:
    BAO_CACERT: /openbao/tls/ca.crt
  volumes:
    - name: tls
      secret:
        secretName: openbao-tls
  volumeMounts:
    - name: tls
      mountPath: /openbao/tls
      readOnly: true
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 256Mi

ui:
  enabled: true
```, erklaerung: [
  `tlsDisable: false` schaltet die Verschlüsselung ein. Der Injector entfällt, weil External Secrets die Werte liefert. Das Audit-Gerät schreibt auf die Standardausgabe, und Alloy bringt es nach Loki. Werte stehen dort nur gehasht im Log. Die Option `log_raw` aus der Doku würde sie im Klartext zeigen, setze sie also nicht.
])

#cmd("Mac")[```bash
helm upgrade --install openbao openbao/openbao \
  -n openbao --version 0.30.7 -f openbao/values.yaml
```][Das Repository `openbao` ist bei dir schon eingetragen, sonst `helm repo add openbao https://openbao.github.io/openbao-helm`.]

#falle[
  Verwende hier *kein* `--wait`. Der Pod wird erst `Ready`, wenn der Tresor entsiegelt ist. Helm würde also bis zum Timeout warten und einen Fehler melden, obwohl alles richtig läuft.
]

#cmd("Mac")[```bash
kubectl get pods -n openbao
```][`openbao-0` steht auf `Running`, aber `0/1`. Das ist hier der richtige Zustand.]

== Initialisieren und entsiegeln

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- bao operator init \
  -key-shares=3 -key-threshold=2
```][Erzeugt den Hauptschlüssel und zerlegt ihn in drei Teile, von denen zwei reichen. Der Befehl läuft nur einmal im Leben dieses Tresors.]

#falle[
  Die Ausgabe zeigt die drei Unseal Keys und das Root Token nur *dieses eine Mal*. Speichere sie sofort in deinem Passwort-Manager, niemals im Repo und niemals in einer Datei in Dropbox. Verlierst du die Keys, sind alle Daten im Tresor unwiederbringlich verloren.
]

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- bao operator unseal
```][Fragt verdeckt nach dem ersten Unseal Key. Schreibe Keys nicht direkt in die Befehlszeile, sonst landen sie in der Shell-Historie.]

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- bao operator unseal
```][Fragt nach dem zweiten Key. Nach dem zweiten von zwei nötigen Teilen ist der Tresor offen.]

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- bao status
```][Zeigt den Zustand.]

#pruefe[
  `Initialized` steht auf `true`, `Sealed` auf `false`. `kubectl get pods -n openbao` zeigt jetzt `1/1`.
]

== Erste Schritte im Tresor

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- sh
```][Öffnet eine Shell im Pod. Die folgenden Befehle laufen darin.]

#cmd("Pod")[```bash
bao login
```][Fragt verdeckt nach dem Root Token und merkt es sich im Pod für die laufende Sitzung.]

#cmd("Pod")[```bash
bao secrets enable -path=secret kv-v2
```][Aktiviert einen versionierten Schlüssel-Wert-Speicher unter dem Pfad `secret/`. Bei einem echten Server ist das nicht von selbst aktiv.]

#cmd("Pod")[```bash
bao kv put secret/apps/demo \
  password="erstes-passwort" user=demo
```][Legt zwei Werte unter einem Pfad ab.]

#cmd("Pod")[```bash
bao kv get secret/apps/demo
```][Liest sie wieder aus.]

#cmd("Pod")[```bash
bao kv put secret/apps/demo \
  password="zweites-passwort" user=demo
```][Schreibt eine neue Version.]

#cmd("Pod")[```bash
bao kv get -version=1 secret/apps/demo
```][Holt die alte Version zurück. Das ist die Historie, die einem Kubernetes-Secret fehlt.]

== Rechte vergeben: die Policy

Das Root Token darf alles, deine Anwendungen sollen das nicht. In OpenBao ist alles verboten, was nicht erlaubt wurde, ganz wie bei RBAC.

#cmd("Pod")[```bash
bao policy write eso-lesen - <<'EOF'
path "secret/data/apps/*" {
  capabilities = ["read"]
}
path "secret/metadata/apps/*" {
  capabilities = ["read", "list"]
}
EOF
```][Erstellt die Richtlinie `eso-lesen`. Wichtig: Bei `kv-v2` liegen die Werte unter `secret/data/`, nicht unter `secret/`. Das ist die häufigste Fehlerquelle.]

Die Richtlinie braucht jetzt noch jemanden, der sie benutzt. Das erledigt Kapitel 16.

#cmd("Pod")[```bash
rm -f ~/.bao-token
exit
```][`bao login` merkt sich das Token in `~/.bao-token`. Ein Root Token gehört nicht in eine Datei, deshalb löschst du sie und verlässt den Pod. Am Ende jeder Sitzung mit dem Root Token gilt: Datei löschen.]

== Versiegeln erleben

#cmd("Mac")[```bash
kubectl delete pod openbao-0 -n openbao
```][Simuliert einen Neustart des Nodes.]

#cmd("Mac")[```bash
kubectl get pods -n openbao
```][Nach kurzer Zeit läuft der neue Pod, bleibt aber auf `0/1`.]

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- bao status
```][`Sealed` steht auf `true`. Die Daten sind noch da, aber unzugänglich, bis du entsiegelst. Dieser Ablauf gehört künftig zu jedem Neustart.]

Führe nun zweimal `bao operator unseal` aus, wie oben.

#cmd("Mac")[```bash
kubectl logs -n openbao openbao-0 --tail=5
```][Hier siehst du das Audit-Log mit JSON-Zeilen. In Grafana findest du es unter `{namespace="openbao"}`.]

#hinweis("Automatisch entsiegeln?", akzent, akzent-hell)[
  Im Betrieb stört das manuelle Entsiegeln. Die Lösung heißt Auto-Unseal, dabei öffnet ein Cloud-KMS oder ein zweiter Tresor den ersten. Der Schlüssel läge dann aber woanders, und du brauchst diese Infrastruktur. Für dein Lab ist das Handbetrieb die lehrreichere Wahl.
]

#aufgabe[
  Melde dich an, schreibe eine zweite Policy `nur-lesen-demo`, die *nur* `secret/data/apps/demo` lesen darf, und erzeuge dafür ein Token mit `bao token create -policy=nur-lesen-demo -ttl=1h`. Teste es mit `BAO_TOKEN=... bao kv get secret/apps/demo`. Was passiert bei `secret/apps/anderes`?
]

#gelernt(
  [Versiegeln schützt ruhende Daten, kostet aber Arbeit bei jedem Neustart.],
  [Unseal Keys und Root Token gehören in den Passwort-Manager, nie ins Repo.],
  [`kv-v2` speichert Versionen und legt Werte unter `secret/data/` ab.],
  [Das Audit-Gerät zeigt, wer was gelesen hat, ohne die Werte preiszugeben.],
)

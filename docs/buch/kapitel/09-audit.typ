#import "../lib.typ": *

#kapitel(
  [Audit-Logs: Wer hat was getan?],
  ziel: [Der API-Server protokolliert jede wichtige Anfrage, und du wertest das Protokoll aus.],
  zeit: [30 Minuten],
  braucht: [Kapitel 4],
)

== Die Überwachungskamera des API-Servers

Jede Änderung im Cluster läuft über den API-Server. Damit ist er der perfekte Ort für ein Protokoll. Das Audit-Log beantwortet nach einem Vorfall die zentralen Fragen: Wer hat wann welche Aktion an welchem Objekt ausgeführt, und von wo aus?

Bei k3s läuft der API-Server im k3s-Prozess, nicht als Pod. Das Audit-Log ist deshalb eine Datei auf dem Host. Noch liest du sie direkt dort, in Kapitel 10 bringt Alloy sie nach Loki.

== Die vier Protokoll-Stufen

#tabelle(
  (auto, 1fr),
  ([Stufe], [Was protokolliert wird]),
  [`None`], [Nichts],
  [`Metadata`], [Wer, was, wann, Ergebnis. Keine Inhalte.],
  [`Request`], [Zusätzlich der Inhalt der Anfrage],
  [`RequestResponse`], [Zusätzlich der Inhalt der Antwort],
)

#warum[
  Bei Secrets darfst du nie `Request` oder `RequestResponse` verwenden, sonst stehen die Passwörter im Klartext im Log, und dein Log wird selbst zum Risiko. Die erste passende Regel gewinnt, die Reihenfolge in der Datei entscheidet also.
]

== Die Audit-Policy schreiben

#datei("security/audit-policy.yaml", ```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Lärm weglassen: Gesundheitschecks und Metriken
  - level: None
    nonResourceURLs:
      - /healthz*
      - /readyz*
      - /livez*
      - /metrics
  # Events und Leader-Leases feuern ständig
  - level: None
    resources:
      - group: ""
        resources: [events]
      - group: coordination.k8s.io
        resources: [leases]
  # Inhalte von Secrets nie ins Log schreiben
  - level: Metadata
    resources:
      - group: ""
        resources: [secrets, configmaps]
      - group: authentication.k8s.io
        resources: [tokenreviews]
  # Rechteänderungen vollständig festhalten
  - level: RequestResponse
    verbs: [create, update, patch, delete]
    resources:
      - group: rbac.authorization.k8s.io
  # Alles andere nur als Metadaten
  - level: Metadata
```, erklaerung: [
  Ohne die beiden `None`-Regeln am Anfang füllt sich das Log mit wertlosen Einträgen. `omitStages` lässt die erste Phase jeder Anfrage weg, sonst stünde jede Aktion doppelt im Log.
])

== Auf dem Node aktivieren

#cmd("Mac")[```bash
scp security/audit-policy.yaml \
  <user>@172.16.0.136:/tmp/audit.yaml
```][Bringt die Policy auf den Node.]

Öffne jetzt `k3s/config.yaml` und kommentiere auch die Audit-Zeilen ein. Die `admission-control`-Zeile ist seit Kapitel 4 aktiv.

#datei("k3s/config.yaml (Ausschnitt)", ```yaml
kube-apiserver-arg:
  - "admission-control-config-file=/var/lib/rancher/k3s/server/psa.yaml"
  - "audit-policy-file=/var/lib/rancher/k3s/server/audit.yaml"
  - "audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
```, erklaerung: [
  `maxsize` rotiert die Datei bei 100 MB, `maxbackup` behält zehn alte Dateien, `maxage` löscht nach 30 Tagen. Das begrenzt den Platzbedarf auf rund 1,1 GB.
])

#cmd("Mac")[```bash
scp k3s/config.yaml <user>@172.16.0.136:/tmp/config.yaml
ssh <user>@172.16.0.136
```][Bringt die geänderte Konfiguration auf den Node und öffnet die Sitzung.]

#cmd("Node")[```bash
sudo install -m 600 -o root -g root /tmp/audit.yaml \
  /var/lib/rancher/k3s/server/audit.yaml
```][Die Policy muss vor dem Neustart an ihrem Platz liegen, sonst startet der API-Server nicht.]

#cmd("Node")[```bash
sudo install -m 600 -o root -g root /tmp/config.yaml \
  /etc/rancher/k3s/config.yaml
rm /tmp/audit.yaml /tmp/config.yaml
```][Setzt die neue Konfiguration ein und räumt `/tmp` auf.]

#cmd("Node")[```bash
sudo systemctl restart k3s
```][k3s liest `config.yaml` nur beim Start. Die Pods laufen während des Neustarts weiter.]

#cmd("Node")[```bash
sudo tail -n 1 /var/lib/rancher/k3s/server/logs/audit.log | jq .
```][Zeigt den letzten Eintrag lesbar an. Lies ihn einmal ganz durch: `user`, `verb`, `objectRef`, `sourceIPs`, `responseStatus`.]

#falle[
  Startet k3s nicht mehr, ist meist die Policy-Datei schuld. `sudo journalctl -u k3s -n 50` nennt den Fehler. Zur Not kommentierst du die Zeilen in `/etc/rancher/k3s/config.yaml` aus und startest neu.
]

== Das Log auswerten

Lass die SSH-Sitzung offen und öffne ein zweites Terminal auf dem Laptop.

#cmd("Mac")[```bash
kubectl create secret generic audit-test \
  --from-literal=wert=streng-geheim
```][Erzeugt ein Test-Secret, das du gleich im Log wiederfinden willst.]

#cmd("Mac")[```bash
kubectl get secret audit-test -o yaml
```][Liest es, damit auch ein Lesezugriff im Log steht.]

#cmd("Node")[```bash
sudo jq -c 'select(.objectRef.name == "audit-test")
  | {verb, user: .user.username, code: .responseStatus.code}' \
  /var/lib/rancher/k3s/server/logs/audit.log
```][`jq` liest das Log als Strom von JSON-Objekten. `select` filtert, die zweite Stufe baut eine kurze Zeile.]

#pruefe[
  Du siehst Einträge mit `create` und `get` und deinem Admin-Nutzer.
]

#cmd("Node")[```bash
sudo grep -c streng-geheim \
  /var/lib/rancher/k3s/server/logs/audit.log
```][Muss `0` ausgeben: Der geheime Wert steht *nicht* im Log. Genau das hat die `Metadata`-Regel bewirkt.]

#cmd("Mac")[```bash
kubectl delete secret audit-test
```][Räumt das Test-Objekt auf.]

== Nützliche Auswertungen

Wer außer Systemkomponenten hat Secrets gelesen?

#cmd("Node")[```bash
sudo jq -c 'select(.objectRef.resource == "secrets"
    and (.verb == "get" or .verb == "list")
    and (.user.username | startswith("system:") | not))
  | {verb, user: .user.username, name: .objectRef.name}' \
  /var/lib/rancher/k3s/server/logs/audit.log
```][Die wichtigste Abfrage für den Alltag. In Kapitel 10 schreibst du sie in LogQL neu.]

Welche Anfragen wurden abgelehnt?

#cmd("Node")[```bash
sudo jq -c 'select(.responseStatus.code == 403)
  | {verb, user: .user.username, res: .objectRef.resource}' \
  /var/lib/rancher/k3s/server/logs/audit.log
```][Abgelehnte Anfragen zeigen oft Fehlkonfigurationen, manchmal aber auch einen Angreifer, der sich umsieht.]

#cmd("Node")[```bash
exit
```][Beendet die SSH-Sitzung.]

#aufgabe[
  Führe `kubectl get secrets -A --as=system:anonymous` aus. Was antwortet der Cluster, und was steht danach im Audit-Log? Starte dann einen normalen `nginx`-Pod in einem neuen Namespace und suche im Log die Annotation `pod-security.kubernetes.io/audit-violations`. Das ist der Audit-Modus von PSA aus Kapitel 4.
]

#gelernt(
  [Das Audit-Log beantwortet nach einem Vorfall: wer, was, wann, von wo.],
  [Die erste passende Regel gewinnt, daher stehen die `None`-Regeln oben.],
  [Secrets gehören nur auf Stufe `Metadata` ins Log.],
  [Bei k3s ist das Audit-Log eine Host-Datei. Solange es nur dort liegt, kann ein Angreifer es löschen.],
)

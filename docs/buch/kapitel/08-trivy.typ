#import "../lib.typ": *

#kapitel(
  [Trivy Operator: Regelmäßig scannen],
  ziel: [Der Cluster prüft sich selbst auf bekannte Schwachstellen und Fehlkonfigurationen, und du wertest die Berichte aus.],
  zeit: [45 Minuten],
  braucht: [Kapitel 4],
)

== Bekannte Schwächen finden

Ein Image, das heute sauber ist, kann morgen verwundbar sein, weil eine neue Lücke bekannt wird. Einmaliges Scannen reicht also nicht. Der Trivy Operator beobachtet den Cluster und scannt alles, was läuft. Die Ergebnisse legt er als Kubernetes-Objekte ab.

#tabelle(
  (auto, auto, 1fr),
  ([Bericht], [Kurzname], [Inhalt]),
  [`VulnerabilityReport`], [`vuln`], [Bekannte CVEs in Images],
  [`ConfigAuditReport`], [`configaudit`], [Unsichere Pod-Einstellungen],
  [`ExposedSecretReport`], [`exposedsecret`], [Passwörter, die im Image liegen],
  [`RbacAssessmentReport`], [`rbacassessment`], [Zu weite Rollen],
  [`InfraAssessmentReport`], [`infraassessment`], [Einstellungen der Nodes],
  [`ClusterComplianceReport`], [`compliance`], [Prüfung gegen Standards wie CIS],
)

#warum[
  Weil die Berichte Kubernetes-Objekte sind, gelten für sie RBAC, `kubectl` und Prometheus. Du brauchst keinen eigenen Scan-Server, und jedes Team sieht die Berichte seines Namespace.
]

== Installieren

#datei("trivy/values.yaml", ```yaml
# Kapitel 10 schaltet das ein, sobald Prometheus läuft.
serviceMonitor:
  enabled: false

trivy:
  # Nur Lücken zeigen, für die es eine Korrektur gibt
  ignoreUnfixed: true
  severity: HIGH,CRITICAL

operator:
  # Nur ein Scan gleichzeitig, um den Node zu schonen
  scanJobsConcurrentLimit: 1
  # Berichte nach 24 Stunden neu erstellen
  scannerReportTTL: 24h
```, erklaerung: [
  `ignoreUnfixed` blendet Meldungen aus, gegen die du gerade nichts tun kannst. `scanJobsConcurrentLimit: 1` ist auf 8 GB RAM wichtig, der Standardwert 10 könnte deinen Node überlasten. `scannerReportTTL` legt fest, dass täglich neu gescannt wird.
])

#cmd("Mac")[```bash
helm repo add aqua https://aquasecurity.github.io/helm-charts/
helm repo update
```][Trägt das Repository ein.]

#cmd("Mac")[```bash
helm upgrade --install trivy-operator aqua/trivy-operator \
  -n trivy-system --version 0.38.1 \
  -f trivy/values.yaml --wait --timeout 5m
```][Installiert den Operator in den vorbereiteten Namespace. `trivy-system` hat seit Kapitel 4 die Stufe `privileged`, weil der Node-Collector Host-Dateien prüft.]

#cmd("Mac")[```bash
kubectl get jobs -n trivy-system
```][Der Operator legt für jeden Workload einen kurzlebigen Scan-Job an. Bei einem frischen Start dauert es eine Weile, bis alle durch sind, und die Schwachstellendatenbank wird einmalig geladen.]

== Ein altes Image finden lassen

#cmd("Mac")[```bash
kubectl create deployment altlast -n falco-lab --image=nginx:1.21.6
```][Startet ein Image von 2022. Es enthält reichlich bekannte Lücken. Der Namespace `falco-lab` erlaubt root.]

#cmd("Mac")[```bash
kubectl get vuln -n falco-lab -o wide
```][Nach ein paar Minuten erscheint ein Bericht. Die Spalten zeigen die Anzahl pro Schweregrad. Solange die Liste leer ist, läuft der Scan noch.]

#cmd("Mac")[```bash
kubectl get vuln -n falco-lab -o json | jq -r '
  .items[].report.vulnerabilities[]
  | select(.severity == "CRITICAL")
  | "\(.vulnerabilityID)  \(.resource)  fix: \(.fixedVersion)"
' | sort -u | head -20
```][Zeigt die kritischen Lücken mit dem Paket und der Version, die sie behebt.]

#pruefe[
  Du siehst eine Liste von CVE-Nummern, etwa für `openssl` oder `zlib`, jeweils mit `fix:`-Version. Die genaue Liste ändert sich mit der Datenbank.
]

#aufgabe[
  Aktualisiere das Deployment: `kubectl set image deploy/altlast -n falco-lab altlast=nginx:1.29-alpine`. Wie viele kritische Lücken meldet der neue Bericht? Dieses Vorgehen ist in der Praxis der häufigste Weg, Lücken zu schließen: nicht patchen, sondern ein neues Image ausrollen.
]

== Fehlkonfigurationen finden

#cmd("Mac")[```bash
kubectl get configaudit -A -o wide
```][Zeigt pro Workload die Anzahl der Befunde. Dein Pod in `demo` sollte deutlich besser abschneiden als `opfer` in `falco-lab`, weil er `restricted` erfüllt.]

#cmd("Mac")[```bash
kubectl get configaudit -n falco-lab -o json | jq -r '
  .items[].report.checks[]
  | select(.success == false)
  | "\(.severity)  \(.checkID)  \(.title)"
' | sort -u
```][Listet alle fehlgeschlagenen Prüfungen. Viele davon entsprechen genau den Regeln, die du aus Kapitel 4 kennst.]

#cmd("Mac")[```bash
kubectl get rbacassessment -A -o wide
```][Bewertet deine Rollen. Hier siehst du, wie Trivy die Rechte aus Kapitel 3 einschätzt.]

#cmd("Mac")[```bash
kubectl get exposedsecret -A
```][Zeigt Geheimnisse, die jemand fest in ein Image eingebaut hat. Diese Liste sollte leer sein.]

#falle[
  Die Infra-Prüfungen erwarten oft Standardpfade von `kubeadm`. Bei k3s läuft der API-Server im k3s-Prozess, deshalb erzeugt `infraassessment` einige Fehlalarme. Prüfe solche Meldungen, bevor du handelst, und vergleiche sie mit dem #link("https://docs.k3s.io/security/hardening-guide")[k3s-Hardening-Guide].
]

== Die Regel, die alles verbindet

Kapitel 5 und dieses Kapitel lassen sich verbinden: Trivy meldet, dass ein Image verwundbar ist, und Kyverno kann per `ImageValidatingPolicy` verlangen, dass nur geprüfte Images starten. Das führt zu signierten Images und ist ein gutes nächstes Lernprojekt.

#gelernt(
  [Scannen ist kein Einmal-Ereignis, denn neue Lücken treffen auch alte Images.],
  [Trivy legt Berichte als Kubernetes-Objekte ab, also gelten RBAC und `kubectl`.],
  [Auf kleinen Nodes begrenzt `scanJobsConcurrentLimit` die Last.],
  [Lücken schließt man meist durch ein neues Image, nicht durch einen Patch im Container.],
)

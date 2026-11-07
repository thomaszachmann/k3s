#import "../lib.typ": *

#kapitel(
  [Pod Security Admission],
  ziel: [Du legst fest, welche Pods überhaupt starten dürfen: clusterweit als Standard und pro Namespace strenger oder lockerer.],
  zeit: [45 Minuten],
  braucht: [Kapitel 3],
)

== Der Türsteher

Pod Security Admission (PSA) prüft jeden neuen Pod, bevor er angelegt wird. Es ist fest in Kubernetes eingebaut. Du wählst pro Namespace eine Stufe und einen Modus.

#tabelle(
  (auto, 1fr),
  ([Stufe], [Bedeutung]),
  [`privileged`], [Keine Einschränkungen. Für Systemkomponenten.],
  [`baseline`], [Verbietet bekannte Gefahren wie `privileged`, `hostNetwork`, `hostPath`.],
  [`restricted`], [Am strengsten: kein Root, Capabilities entfernt, Seccomp nötig.],
)

#tabelle(
  (auto, 1fr),
  ([Modus], [Wirkung bei einem Verstoß]),
  [`enforce`], [Der Pod wird abgelehnt.],
  [`audit`], [Der Pod startet, der Verstoß landet im Audit-Log.],
  [`warn`], [Der Pod startet, `kubectl` zeigt eine Warnung.],
)

#warum[
  PSA prüft nur *beim Anlegen*. Laufende Pods bleiben unberührt, auch wenn du die Stufe verschärfst. Ein Problem zeigt sich dann erst beim nächsten Neustart. Prüfe also vorher, wen eine Änderung treffen würde.
]

== Wer braucht welche Stufe?

Falco muss den Kernel beobachten und braucht einen privilegierten Container mit vielen `hostPath`-Mounts. `restricted` würde ihn sofort ablehnen. Dasselbe gilt für alles, was den Node selbst betrachtet.

#tabelle(
  (auto, auto, 1fr),
  ([Namespace], [Stufe], [Grund]),
  [`kube-system`], [ausgenommen], [Cilium, Traefik, CoreDNS brauchen Host-Zugriff],
  [`monitoring`], [`privileged`], [node-exporter nutzt `hostNetwork` und `hostPID`, Alloy nutzt `hostPath`],
  [`falco`], [`privileged`], [eBPF-Treiber, viele `hostPath`-Mounts],
  [`trivy-system`], [`privileged`], [Der Node-Collector prüft Host-Dateien],
  [`demo`], [`restricted`], [Deine Anwendungen],
  [alle anderen], [`baseline`], [Clusterweiter Standard],
)

Der Standard gilt auch für neue Namespaces. Wer eine Ausnahme braucht, muss sie sich aktiv holen. Das ist das Prinzip *secure by default*.

== Die Wirkung testen, bevor sie zuschlägt

#cmd("Mac")[```bash
kubectl label --dry-run=server --overwrite ns --all \
  pod-security.kubernetes.io/enforce=baseline
```][`--dry-run=server` lässt den API-Server die Änderung prüfen, ohne sie zu speichern. Er warnt dich vor jedem laufenden Pod, der gegen `baseline` verstößt.]

#pruefe[
  Du bekommst Warnungen für `kube-system`, zum Beispiel wegen `hostPath` oder `hostNetwork`. Dieser Namespace braucht seine Ausnahme. Noch laufen keine weiteren Host-nahen Dienste, die kommen erst später.
]

== Ausnahmen setzen

Setze die Ausnahmen *zuerst*, auch für Dienste, die erst später kommen. Sonst lehnt der neue Standard sie ab, sobald sie starten wollen.

#cmd("Mac")[```bash
kubectl create namespace monitoring
kubectl create namespace falco
kubectl create namespace trivy-system
```][Legt die drei Namespaces schon jetzt an, damit sie ihre Stufe haben, bevor die ersten Pods darin starten.]

#cmd("Mac")[```bash
kubectl label namespace monitoring \
  pod-security.kubernetes.io/enforce=privileged
```][Erlaubt in `monitoring` alles. Label am Namespace schlagen den clusterweiten Standard.]

#cmd("Mac")[```bash
kubectl label namespace monitoring \
  pod-security.kubernetes.io/warn=baseline \
  pod-security.kubernetes.io/audit=baseline
```][Blockiert nichts, macht aber Verstöße sichtbar. So bleibt die Ausnahme nachvollziehbar.]

#cmd("Mac")[```bash
kubectl label namespace falco trivy-system \
  pod-security.kubernetes.io/enforce=privileged
```][Gibt beiden die nötige Stufe.]

== Den Clusterstandard festlegen

#datei("security/psa.yaml", ```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: baseline
        enforce-version: latest
        audit: restricted
        audit-version: latest
        warn: restricted
        warn-version: latest
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces:
          - kube-system
```, erklaerung: [
  Der Standard setzt `baseline` durch und meldet alles, was `restricted` nicht erfüllen würde. Nur `kube-system` ist ganz ausgenommen. Ausnahmen gelten für ganze Namespaces, halte die Liste also kurz.
])

#cmd("Mac")[```bash
scp security/psa.yaml <user>@172.16.0.136:/tmp/psa.yaml
```][Bringt die Datei auf den Node.]

Kommentiere in `k3s/config.yaml` jetzt diese beiden Zeilen ein. Die `audit-`-Zeilen bleiben auskommentiert, sie sind für Kapitel 9.

#datei("k3s/config.yaml (Ausschnitt)", ```yaml
kube-apiserver-arg:
  - "admission-control-config-file=/var/lib/rancher/k3s/server/psa.yaml"
```)

#cmd("Mac")[```bash
scp k3s/config.yaml <user>@172.16.0.136:/tmp/config.yaml
ssh <user>@172.16.0.136
```][Überträgt die Konfiguration und öffnet die Sitzung.]

#cmd("Node")[```bash
sudo install -m 600 -o root -g root /tmp/psa.yaml \
  /var/lib/rancher/k3s/server/psa.yaml
```][Die Datei muss vor dem Neustart bereitliegen.]

#cmd("Node")[```bash
sudo install -m 600 -o root -g root /tmp/config.yaml \
  /etc/rancher/k3s/config.yaml
rm /tmp/psa.yaml /tmp/config.yaml
sudo systemctl restart k3s
```][Setzt die Konfiguration ein und startet k3s neu.]

#cmd("Node")[```bash
exit
```][Zurück zum Mac.]

== Den Standard testen

#cmd("Mac")[```bash
kubectl create namespace psa-test
```][Ein frischer Namespace ohne Label, hier gilt also der Clusterstandard.]

#datei("security/psa-boese.yaml", ```yaml
apiVersion: v1
kind: Pod
metadata:
  name: boese
  namespace: psa-test
spec:
  hostNetwork: true
  containers:
    - name: c
      image: busybox:1.36
      command: [sleep, "3600"]
      securityContext:
        privileged: true
```)

#cmd("Mac")[```bash
kubectl apply -f security/psa-boese.yaml
```][Erwartet: `Forbidden`. Die Meldung nennt beide Verstöße, `hostNetwork` und `privileged`.]

#cmd("Mac")[```bash
kubectl delete namespace psa-test
```][Räumt auf.]

== `demo` auf `restricted` setzen

#cmd("Mac")[```bash
kubectl label namespace demo \
  pod-security.kubernetes.io/enforce=restricted
```][Ab jetzt laufen in `demo` nur noch Pods, die alle Regeln der strengsten Stufe einhalten.]

#cmd("Mac")[```bash
kubectl run test --image=nginx:1.29-alpine -n demo
```][Erwartet: `Forbidden`. Lies die Meldung genau, denn sie sagt dir, welche Felder fehlen.]

#tabelle(
  (auto, 1fr),
  ([Feld im Pod], [Zweck]),
  [`allowPrivilegeEscalation: false`], [Prozesse können keine Rechte hinzugewinnen],
  [`capabilities.drop: [ALL]`], [Entfernt alle Linux-Sonderrechte],
  [`runAsNonRoot: true`], [Der Container startet nicht als root],
  [`seccompProfile.type: RuntimeDefault`], [Sperrt seltene, gefährliche Systemaufrufe],
)

Normales `nginx` startet als root und läuft deshalb hier nicht. Du brauchst ein Image, das ohne root auskommt:

#datei("security/psa-gut.yaml", ```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gut
  namespace: demo
  labels:
    team: plattform
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: web
      image: nginxinc/nginx-unprivileged:1.29-alpine
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
      resources:
        limits:
          memory: 64Mi
```)

#cmd("Mac")[```bash
kubectl apply -f security/psa-gut.yaml
kubectl get pod gut -n demo
```][Dieser Pod erfüllt alle Regeln und läuft.]

#cmd("Mac")[```bash
kubectl delete pod gut -n demo
```][Räumt auf.]

#aufgabe[
  Starte in einem neuen Namespace einen normalen `nginx`-Pod. Er besteht `baseline`, verstößt aber gegen `restricted`. Welche Warnung zeigt `kubectl`? Der Modus `audit` schreibt denselben Verstoß ins Audit-Log, das du in Kapitel 9 aktivierst.
]

#gelernt(
  [PSA prüft nur beim Anlegen, laufende Pods bleiben unberührt.],
  [`--dry-run=server` zeigt vorab, wen eine Verschärfung trifft.],
  [Ausnahmen zuerst setzen, dann den Standard verschärfen.],
  [Der Standard `baseline` macht auch neue Namespaces automatisch sicherer.],
  [`restricted` braucht vier Einstellungen und ein Image, das ohne root läuft.],
)

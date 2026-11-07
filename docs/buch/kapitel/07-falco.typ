#import "../lib.typ": *

#kapitel(
  [Falco: Verdächtiges erkennen],
  ziel: [Falco beobachtet Systemaufrufe auf dem Node und meldet, wenn sich ein Container verdächtig verhält.],
  zeit: [60 Minuten],
  braucht: [Kapitel 4],
)

== Die Alarmanlage im Kernel

Bisher hast du verhindert. Was aber, wenn jemand durchkommt? Falco sitzt per eBPF im Kernel und sieht jeden Systemaufruf jedes Containers. Es vergleicht sie mit Regeln und meldet Treffer.

#tabelle(
  (1fr, 1fr),
  ([Falco sieht], [Falco sieht nicht]),
  [Eine Shell startet im Container], [Den Inhalt einer Verschlüsselung],
  [Ein Prozess liest `/etc/shadow`], [Ob eine Aktion fachlich erlaubt ist],
  [Ein neues Programm wird ausgeführt], [Was außerhalb des Nodes passiert],
)

#warum[
  Falco blockiert nichts, es meldet nur. Deshalb ergänzt es Cilium und PSA: Was die Prävention durchlässt, sieht Falco. Eine Regel, die nie anschlägt, kann auch nichts stören. Eine laute Regel dagegen sorgt dafür, dass echte Alarme untergehen. Das Feintuning ist deshalb die eigentliche Arbeit.
]

== Installieren

Falco schreibt seine Meldungen als JSON auf die Standardausgabe. Fürs Erste liest du sie mit `kubectl logs`. In Kapitel 10 sammelt Alloy sie automatisch ein und bringt sie nach Loki. Du brauchst also kein weiteres Zusatzprogramm und sparst RAM.

#datei("falco/values.yaml", ```yaml
# Zeilen sofort ausgeben, nicht puffern
tty: true

driver:
  # Moderner eBPF-Treiber, kein Kernel-Modul nötig
  kind: modern_ebpf

falco:
  json_output: true
  json_include_output_property: true

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    memory: 768Mi

customRules:
  eigene-regeln.yaml: |-
    - rule: Paketmanager im Container
      desc: Jemand installiert Software in einem laufenden Container
      condition: >
        spawned_process and container
        and proc.name in (apt, apt-get, apk, dnf, yum)
      output: >
        Paketmanager gestartet (user=%user.name cmd=%proc.cmdline
        pod=%k8s.pod.name ns=%k8s.ns.name
        image=%container.image.repository)
      priority: WARNING
      tags: [container, mitre_persistence]
```, erklaerung: [
  `modern_ebpf` läuft auf deinem Kernel 6.8 ohne Kompilieren. Den k3s-Socket `/run/k3s/containerd/containerd.sock` kennt das Chart von Haus aus, du musst ihn nicht eintragen. So bekommt Falco Container-Namen und Image-Infos.
])

#cmd("Mac")[```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
```][Trägt das Repository ein.]

#cmd("Mac")[```bash
helm upgrade --install falco falcosecurity/falco \
  -n falco --version 9.2.2 \
  -f falco/values.yaml --wait --timeout 5m
```][Der Namespace `falco` existiert seit Kapitel 4 mit der Stufe `privileged`. Hättest du ihn nicht angelegt, würde der clusterweite Standard Falco ablehnen.]

#cmd("Mac")[```bash
kubectl logs -n falco ds/falco -c falco --tail=20
```][Prüft den Start. Du solltest sehen, dass Regeln geladen und die eBPF-Probe aktiv ist. Fehler in deinen eigenen Regeln stehen ebenfalls hier.]

== Einen Angriff simulieren

Du brauchst ein Opfer, das als root läuft. In `demo` geht das wegen `restricted` nicht. Dieser Unterschied ist schon die erste Lektion.

#cmd("Mac")[```bash
kubectl create namespace falco-lab
```][Ein Namespace mit dem Standard `baseline`, hier darf root laufen.]

#cmd("Mac")[```bash
kubectl run opfer -n falco-lab --image=nginx:1.29-alpine
kubectl wait pod/opfer -n falco-lab --for=condition=Ready
```][Startet das Opfer und wartet, bis es bereit ist.]

Öffne ein zweites Terminal und verfolge Falco live:

#cmd("Mac")[```bash
kubectl logs -n falco ds/falco -c falco -f --tail=0
```][`-f` folgt dem Log, `--tail=0` zeigt nur Neues. Lass dieses Terminal offen.]

Zurück im ersten Terminal führst du typische Angreifer-Aktionen aus:

#cmd("Mac")[```bash
kubectl exec -it opfer -n falco-lab -- sh
```][Öffnet eine Shell im Container. Schon das löst die Regel `Terminal shell in container` aus.]

#cmd("Pod")[```bash
cat /etc/shadow
```][Liest die Passwort-Hashes. Regel: `Read sensitive file untrusted`.]

#cmd("Pod")[```bash
apk add --no-cache curl
```][Installiert Software. Das löst deine eigene Regel `Paketmanager im Container` aus.]

#cmd("Pod")[```bash
exit
```][Verlässt den Container.]

#pruefe[
  Im zweiten Terminal erscheinen JSON-Zeilen mit `rule`, `priority` und `output_fields`. Du siehst Pod, Namespace, Image und die genaue Befehlszeile. Eine fehlende Zeile bei `Paketmanager` weist meist auf einen Fehler in `eigene-regeln.yaml` hin, schau dann in die Start-Logs.
]

== Fehlalarme abstellen

Stell dir vor, dein Team öffnet täglich Shells in `falco-lab`. Dann wird die Regel `Terminal shell in container` zum Rauschen. Du erweiterst sie mit einer Ausnahme, statt sie abzuschalten.

Ergänze in `falco/values.yaml` unter `customRules` eine zweite Datei:

#datei("falco/values.yaml (Ausschnitt)", ```yaml
customRules:
  eigene-regeln.yaml: |-
    # ... wie oben ...
  ausnahmen.yaml: |-
    - rule: Terminal shell in container
      condition: and not k8s.ns.name = "falco-lab"
      override:
        condition: append
```, erklaerung: [
  `override: condition: append` hängt deinen Text an die bestehende Bedingung an. So bleibt die Originalregel erhalten, und du bekommst Updates weiterhin. Die Dateien werden in alphabetischer Reihenfolge nach den Standardregeln geladen.
])

#cmd("Mac")[```bash
helm upgrade falco falcosecurity/falco \
  -n falco --version 9.2.2 -f falco/values.yaml --wait
```][Lädt die neuen Regeln.]

#cmd("Mac")[```bash
kubectl exec opfer -n falco-lab -it -- sh -c 'echo test'
```][Falco sollte jetzt schweigen. In allen anderen Namespaces meldet es Shells weiter.]

#falle[
  Schränke Ausnahmen so eng wie möglich ein. Eine Ausnahme für einen ganzen Namespace ist für ein Lab in Ordnung. In Produktion nimmst du besser eine Kombination aus Image und Benutzer. Sonst baust du dem Angreifer einen blinden Fleck.
]

#aufgabe[
  Schreibe eine Regel, die anschlägt, wenn ein Container eine Verbindung auf Port 4444 öffnet, den typischen Port von Reverse Shells. Tipp: Schau dir das Makro `outbound` und das Feld `fd.sport` in der Falco-Doku an. Teste mit `nc` im Pod `opfer`.
]

#gelernt(
  [Falco sieht Systemaufrufe, blockiert aber nichts.],
  [JSON auf der Standardausgabe reicht, Kapitel 10 sammelt es zentral ein.],
  [Das Feintuning ist die eigentliche Arbeit, denn laute Regeln verdecken echte Alarme.],
  [Mit `override: append` ergänzt du Regeln, ohne sie zu überschreiben.],
)

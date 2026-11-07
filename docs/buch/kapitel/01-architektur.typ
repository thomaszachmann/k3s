#import "../lib.typ": *

#kapitel(
  [Die Architektur im Überblick],
  ziel: [Du verstehst, welche Schicht welchen Angriff abfängt und warum der Aufbau genau so abläuft.],
  zeit: [20 Minuten Lesen],
)

== Das Grundprinzip: Verteidigung in Schichten

Keine einzelne Maßnahme ist perfekt. Ein Angreifer findet vielleicht eine Lücke in deiner Web-Anwendung, und schon liegt Code in deinem Cluster. Die Frage ist dann nicht mehr, ob etwas passiert ist, sondern wie weit er kommt und ob du es bemerkst.

Deshalb baust du mehrere unabhängige Schichten. Jede geht davon aus, dass die davor versagt hat. Die Reise eines Angriffs zeigt, wie das zusammenspielt:

#tabelle(
  (auto, 1fr, auto),
  ([Phase], [Was der Angreifer versucht], [Wer greift ein]),
  [Vorbereiten], [Ein verwundbares Image läuft im Cluster], [Trivy, Kyverno],
  [Eindringen], [Er nutzt die Lücke und landet im Pod], [Falco meldet es],
  [Ausbreiten], [Er ruft andere Dienste oder das Internet auf], [Cilium blockiert],
  [Rechte ausweiten], [Er nutzt das Service-Account-Token], [RBAC begrenzt],
  [Ausbrechen], [Er startet einen privilegierten Pod], [PSA, Kyverno],
  [Beute holen], [Er sucht Passwörter], [RBAC, Audit-Log],
  [Spuren verwischen], [Er löscht lokale Logs], [Loki hält sie außerhalb],
)

== Die vier Ebenen deiner Architektur

Es hilft, die Tools nach dem Zeitpunkt zu ordnen, an dem sie wirken:

#tabelle(
  (auto, 1fr, 1fr),
  ([Ebene], [Frage], [Tools]),
  [*Vor dem Start*], [Darf das überhaupt ins Cluster?], [RBAC, PSA, Kyverno],
  [*Zur Laufzeit*], [Was darf es tun, wenn es läuft?], [Cilium, Falco],
  [*Dauerhaft*], [Wo stecken bekannte Schwächen?], [Trivy],
  [*Nachweisen*], [Was ist tatsächlich passiert?], [Audit-Logs, Grafana, Loki, Tempo],
)

Damit siehst du auch, wo sich Tools überschneiden und wo nicht:

- *PSA und Kyverno* prüfen beide beim Anlegen. PSA kennt nur drei feste Stufen, Kyverno versteht beliebige eigene Regeln. PSA ist die einfache Grundlage, Kyverno die Ergänzung.
- *Falco und Cilium* wirken beide zur Laufzeit. Falco beobachtet und meldet, Cilium blockiert. Falco kann also nichts verhindern, aber es sieht Dinge, die im Netzwerk nie auftauchen.
- *Trivy und Kyverno* ergänzen sich. Trivy findet Schwächen, Kyverno kann verhindern, dass bestimmte Images überhaupt starten.
- *Loki und Tempo* speichern Verschiedenes: Loki die Log-Zeilen, Tempo den Weg einer einzelnen Anfrage durch das System.

== Der Aufbau dieses Buches

Du gehst von innen nach außen vor: erst die Rechte, dann die Regeln, dann das Netz, dann das Erkennen, und am Ende führst du alles zentral zusammen.

#tabelle(
  (auto, 1fr, auto),
  ([Kap.], [Baustein], [Rolle]),
  [2], [k3s und Cilium auf der Ubuntu-VM, Kubeconfig], [Fundament],
  [3], [RBAC], [Zugriff],
  [4], [Pod Security Admission], [Zulassung],
  [5], [Kyverno], [Zulassung],
  [6], [Cilium Default-Deny], [Laufzeit],
  [7], [Falco], [Laufzeit],
  [8], [Trivy Operator], [Dauerhaft],
  [9], [Kubernetes-Audit-Logs], [Nachweis],
  [10], [Grafana, Prometheus, Loki], [Zentrale Sicht],
  [11], [Tempo], [Zentrale Sicht],
  [12], [Dashboard und Angriffsübung], [Zusammenführung],
  [13], [Betrieb und Fehlersuche], [Dauerbetrieb],
)

Die Kapitel 14 bis 16 sind ein freiwilliger Zusatzteil zu TLS und Secrets mit cert-manager, OpenBao und External Secrets. Für den Hauptteil brauchst du sie nicht.

=== Funktioniert das ohne Monitoring am Anfang?

Ja. Beim Sperren musst du sehen, was gerade blockiert wird, und das kannst du von Anfang an:

#tabelle(
  (auto, 1fr),
  ([Kapitel], [Deine Sicht, solange Grafana noch fehlt]),
  [RBAC], [`kubectl auth can-i`],
  [PSA], [Warnungen von `kubectl`, `--dry-run=server`],
  [Kyverno], [`kubectl get polr -A`],
  [Cilium], [`hubble observe --verdict DROPPED`],
  [Falco], [`kubectl logs`],
  [Trivy], [`kubectl get vuln -A`],
  [Audit-Logs], [`jq` direkt auf dem Node],
)

Eines musst du dafür vorausplanen: Monitoring-Dienste brauchen Host-Zugriff, der Namespace `monitoring` bekommt seine PSA-Ausnahme daher schon in Kapitel 4, lange bevor dort etwas läuft.

=== Die Regel in jedem Kapitel

Unabhängig vom Tool gilt immer dieselbe Abfolge:

+ *Melden.* Regeln laufen im Audit-Modus und blockieren nichts.
+ *Auswerten.* Du liest die Meldungen und passt Regeln an.
+ *Durchsetzen.* Erst jetzt wird wirklich blockiert.

== Der Ressourcenplan

Deine VM hat 8 GB RAM. Die Tabelle zeigt grobe Schätzungen für den Speicherbedarf, keine Messwerte. Vergleiche sie mit `kubectl top pods -A`, sobald alles läuft.

#tabelle(
  (1fr, auto),
  ([Komponente], [RAM (geschätzt)]),
  [k3s selbst, CoreDNS, Traefik, Metrics Server], [1,0 GB],
  [Cilium, Hubble], [0,5 GB],
  [Kyverno], [0,4 GB],
  [Falco], [0,3 GB],
  [Trivy Operator (Scans kurzzeitig mehr)], [0,3 GB],
  [Prometheus, Grafana, Alertmanager, Exporter], [1,5 GB],
  [SeaweedFS, Loki, Alloy], [0,8 GB],
  [Tempo], [0,3 GB],
  [*Summe Hauptteil*], [*etwa 5,4 GB*],
)

Es bleibt Luft für deine Lab-Anwendung, aber nicht viel. Der Zusatzteil braucht rund 0,3 GB mehr. Trivy lässt du nur einen Scan gleichzeitig ausführen, das ist in Kapitel 8 bereits eingestellt.

#aufgabe[
  Nimm dir dein eigenes Szenario: Ein Angreifer hat eine Remote-Shell im `frontend`-Pod. Schreibe drei Dinge auf, die er als Nächstes versuchen würde, und notiere, welche Schicht jeweils reagieren sollte. In Kapitel 12 spielst du genau das durch und vergleichst.
]

#gelernt(
  [Jede Schicht geht davon aus, dass die vorherige versagt hat.],
  [Tools lassen sich danach ordnen, wann sie wirken: vor dem Start, zur Laufzeit, dauerhaft und im Nachhinein.],
  [Sichtbarkeit beginnt nicht erst mit Grafana, `kubectl` und Hubble reichen für den Anfang.],
  [Erst melden, dann auswerten und zuletzt durchsetzen.],
)

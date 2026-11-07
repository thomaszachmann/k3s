#import "../lib.typ": *
#set heading(numbering: none)

#pagebreak(to: "odd")
#heading(level: 1, numbering: none)[Zusatzteil]

Hier endet der Hauptteil. Die folgenden drei Kapitel sind freiwillig, du brauchst sie für nichts davor.

Sie schließen zwei Lücken, die der Hauptteil offen lässt: Dienste sprechen unverschlüsselt miteinander, und Secrets entstehen durch Skripte, ohne Historie und ohne Protokoll darüber, wer sie gelesen hat.

#tabelle(
  (auto, 1fr),
  ([Kapitel], [Inhalt]),
  [14], [cert-manager: eigene CA und automatische Zertifikate],
  [15], [OpenBao: ein Tresor mit Versiegelung, Rechten und Audit-Log],
  [16], [External Secrets: Tresor-Werte werden zu Kubernetes-Secrets],
)

Die Kapitel bauen aufeinander auf und setzen Kapitel 10 voraus. Nach einem Neustart der VM musst du OpenBao jedes Mal von Hand entsiegeln, das erklärt Kapitel 15.

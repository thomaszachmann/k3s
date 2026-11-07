#import "../lib.typ": *
#set heading(numbering: none)

#heading(level: 1, numbering: none, outlined: false)[Inhalt]

#{
  show outline.entry.where(level: 1): it => {
    v(0.55em, weak: true)
    strong(it)
  }
  outline(title: none, depth: 2, indent: 1.2em)
}

#pagebreak(to: "odd")
#heading(level: 1, numbering: none)[So benutzt du dieses Buch]

Einzelne Sicherheitstools sind schnell installiert. Schwer ist etwas anderes: zu verstehen, welches Tool welche Lücke schließt, wo sie sich überschneiden und was passiert, wenn eines ausfällt. Genau das lernst du hier, und zwar an deinem eigenen Cluster `k3s2`.

Du baust die Architektur Schicht für Schicht auf. Jedes Kapitel hat denselben Ablauf: Du erfährst zuerst, welches Problem gelöst wird. Dann tippst du Befehl für Befehl, prüfst das Ergebnis und probierst selbst etwas aus. Lange Skripte gibt es nicht.

== Wo du einen Befehl ausführst

Jeder Befehl trägt ein farbiges Etikett. Es sagt dir, wo du dich gerade befindest:

#tabelle(
  (auto, 1fr),
  ([Etikett], [Bedeutung]),
  [#etikett(akzent, "Mac")], [Dein Terminal auf dem Laptop, im Wurzelverzeichnis dieses Repos.],
  [#etikett(warn, "Node")], [Eine SSH-Sitzung auf der VM `k3s2` (172.16.0.136).],
  [#etikett(lila, "Pod")], [Eine Shell in einem Container, die du vorher mit `kubectl exec` geöffnet hast.],
)

Ersetze `<user>` jeweils durch deinen SSH-Login. Alle Pfade wie `security/psa.yaml` sind relativ zum Repo.

== Die Kästen

#warum[Hier steht der Hintergrund, der dir beim nächsten Problem hilft.]
#falle[Hier steht, was typischerweise schiefgeht und woran du es erkennst.]
#pruefe[Hier steht das erwartete Ergebnis. Weicht deine Ausgabe ab, geh nicht weiter, sondern kläre zuerst den Unterschied.]
#aufgabe[Hier bist du dran. Überlege zuerst selbst, bevor du nachschlägst.]

== Was geprüft wurde und was nicht

Ein Buch voller Befehle ist nur so gut wie seine Prüfung. Deshalb steht hier ehrlich, wie weit sie ging.

*Geprüft am 6. November 2026:*
- Alle Chart-Versionen stammen aus den offiziellen Helm-Repositories.
- Alle Helm-Werte in diesem Buch wurden mit `helm template` gegen genau diese Chart-Versionen gerendert.
- Die drei Kyverno-Policies aus Kapitel 5 liefen mit der Kyverno-CLI 1.19.1 gegen gute und schlechte Beispiel-Pods.
- `ValidatingPolicy`, `ClusterSecretStore` und `ExternalSecret` wurden gegen die CRD-Schemas der Charts geprüft.
- Die Image-Tags der Lab-Workloads wurden in der Registry nachgeschlagen.

*Nicht geprüft:*
- Das Buch wurde *nicht* komplett auf einem echten Cluster durchgespielt. Der Testcluster beim Schreiben lief noch mit Flannel und Kubernetes 1.37.
- Die Alloy-Konfiguration, die Falco-Regeln, die `CiliumNetworkPolicy`-Manifeste, die TraceQL-Abfragen und die `bao`-Befehle folgen der offiziellen Doku, liefen aber nicht gegen die echten Programme.

Rechne also damit, dass an einer Stelle etwas abweicht. Das ist kein Grund zur Sorge, sondern Übung: Die Fehlersuche gehört zum Lernen, und Kapitel 13 hilft dir dabei.

== Was du brauchst

- Eine frische Ubuntu-24.04-VM mit 4 CPUs, 8 GB RAM und mindestens 40 GB Disk. Außer Ubuntu ist nichts installiert.
- Auf dem Laptop `kubectl`, `helm`, `jq`, `openssl`, `curl` und die Kyverno-CLI.
- Dieses Repo mit `k3s/config.yaml` und `cilium/values.yaml`.
- Rund zwei Wochenenden Zeit, oder ein Kapitel pro Abend.

#hinweis("Ein Wort zur Reihenfolge", akzent, akzent-hell)[
  Das Buch folgt deinem Plan: erst RBAC und PSA, dann Kyverno und Network Policies, dann Falco, dann Trivy und zum Schluss Audit-Logs mit Grafana, Loki und Tempo. Kapitel 1 erklärt, warum das auch ohne frühes Monitoring gut funktioniert. cert-manager, OpenBao und External Secrets stehen als freiwilliger Zusatzteil am Ende.
]

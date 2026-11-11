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

Prometheus ist schnell installiert, Grafana auch. Schwer wird es, sobald mehr als ein Cluster im Spiel ist. Woher weißt du, welche Metrik aus welchem Cluster stammt? Wo liegen die Daten von vor drei Wochen? Und wer merkt es, wenn das Monitoring selbst ausfällt?

Genau diese Fragen beantwortest du in diesem Buch, und zwar an drei eigenen k3s-Clustern. Einer davon ist die Zentrale `obs`. Die beiden anderen, `app1` und `app2`, spielen deine Anwendungs-Cluster. Sie schicken Metriken, Logs und Traces an die Zentrale. Dort landet alles in einem S3-Speicher und ist in Grafana abfragbar.

Jedes Kapitel hat denselben Ablauf. Du erfährst zuerst, welches Problem gelöst wird. Dann tippst du Befehl für Befehl, prüfst das Ergebnis und probierst selbst etwas aus. Lange Skripte zum Abtippen gibt es nicht. Wer den Hintergrund zu den Konzepten vertiefen möchte, findet ihn im Buch _Kubernetes Observability Hands-On_. Hier wird gebaut.

== Zuerst das Repo klonen

Alle Dateien, auf die sich das Buch bezieht, liegen in einem öffentlichen Repository auf GitHub: #link("https://github.com/thomaszachmann/k3s")[github.com/thomaszachmann/k3s]. Alles zu diesem Buch steht im Ordner `observability/`.

#cmd("Mac")[```bash
git clone https://github.com/thomaszachmann/k3s.git
```][Lädt das Repo mit allen Dateien in den neuen Ordner `k3s`.]

#cmd("Mac")[```bash
cd k3s
```][Wechselt ins Wurzelverzeichnis des Repos. Von hier aus laufen alle Befehle mit dem Etikett *Mac*. Pfade wie `observability/k3s/config-obs.yaml` sind immer relativ zu diesem Ordner.]

== Wo du einen Befehl ausführst

Jeder Befehl trägt ein farbiges Etikett. Es sagt dir, wo du dich gerade befindest:

#tabelle(
  (auto, 1fr),
  ([Etikett], [Bedeutung]),
  [#etikett(akzent, "Mac")], [Dein Terminal auf dem Laptop, im Wurzelverzeichnis des Repos. Von hier aus steuerst du alle drei Cluster mit `kubectl --context <name>`.],
  [#etikett(warn, "obs")], [Eine SSH-Sitzung auf der VM `k3s-obs` (`172.16.0.126`), der Zentrale.],
  [#etikett(warn, "app1")], [Eine SSH-Sitzung auf der VM `k3s-app1` (`172.16.0.228`).],
  [#etikett(warn, "app2")], [Eine SSH-Sitzung auf der VM `k3s-app2` (`172.16.0.83`).],
  [#etikett(lila, "Pod")], [Eine Shell in einem Container, die du vorher mit `kubectl exec` geöffnet hast.],
)

Ersetze `<user>` jeweils durch deinen SSH-Login. Die meiste Zeit arbeitest du auf dem Mac. Auf die VMs gehst du nur in Kapitel 2 und beim Backup in Kapitel 12.

#warum[
  Mit drei Clustern ist der häufigste Fehler der falsche Kontext. Deshalb steht in jedem Befehl ausdrücklich `--context obs`, `--context app1` oder `--context app2`. Den aktiven Standardkontext von `kubectl` nutzt dieses Buch nie.
]

== Die Kästen

#warum[Hier steht der Hintergrund, der dir beim nächsten Problem hilft.]
#falle[Hier steht, was typischerweise schiefgeht und woran du es erkennst.]
#pruefe[Hier steht das erwartete Ergebnis. Weicht deine Ausgabe ab, geh nicht weiter, sondern kläre zuerst den Unterschied.]
#aufgabe[Hier bist du dran. Überlege zuerst selbst, bevor du nachschlägst.]

== Was geprüft wurde und was nicht

Ein Buch voller Befehle ist nur so gut wie seine Prüfung. Deshalb steht hier ehrlich, wie weit sie ging.

*Auf echten Clustern durchgespielt am 11. November 2026:* Die Kapitel 2 bis 10 und 13 und der Velero-Teil von Kapitel 12 liefen Befehl für Befehl auf drei Ubuntu-VMs mit k3s `v1.36.6+k3s1`, mit genau den Versionen aus dem Anhang. Die Ausgaben in den Kästen „Das solltest du sehen“ stammen aus diesem Lauf, die Bilder der Oberflächen ebenfalls. Wo der Lauf Fehler im Buch aufgedeckt hat, sind sie korrigiert. Ausnahmen:

- Die Installation von k3s und das Zusammenführen der Kubeconfig in Kapitel 2 lagen vor dem Lauf und wurden nicht wiederholt.
- Den Dead Man's Switch bei healthchecks.io ersetzte im Test eine interne Adresse, weil dafür ein eigenes Konto nötig ist.
- Kapitel 11 (AWS) lief nicht gegen ein echtes AWS-Konto. Die etcd-Snapshots in Kapitel 12 brauchen SSH auf die VMs und wurden ebenfalls nicht ausgeführt. Beide Stellen sind im Text markiert.
- Aus Kapitel 14 liefen die Messungen und Prüfbefehle, nicht aber Updates und das Aufräumen.
- Kapitel 15 und 16 sind Lesekapitel. Was dort im Labor gemessen oder getestet wurde, steht ausdrücklich dabei, etwa ein Ausfall der Zentrale über 66 Minuten und die Mandantentrennung mit Thanos. Alles andere sind Architekturbeispiele.

*Zusätzlich geprüft am 9. November 2026:* Alle Helm-Werte wurden mit `helm template` gegen die Chart-Versionen gerendert, alle Manifeste mit `kubeconform` gegen Kubernetes 1.36 geprüft, die Shell-Skripte bestehen `shellcheck`.

Rechne also damit, dass an einer Stelle etwas abweicht. Das ist kein Grund zur Sorge, sondern Übung: Die Fehlersuche gehört zum Lernen, und Kapitel 14 hilft dir dabei.

== Was du brauchst

- Drei frische Ubuntu-24.04-VMs mit festen IP-Adressen im selben Netz:

#tabelle(
  (auto, auto, auto, 1fr),
  ([VM], [Hostname], [IP], [Größe]),
  [Zentrale], [`k3s-obs`], [`172.16.0.126`], [4 CPUs, 12 GB RAM (mindestens 8), 80 GB Disk],
  [App-Cluster 1], [`k3s-app1`], [`172.16.0.228`], [2 CPUs, 4 GB RAM, 30 GB Disk],
  [App-Cluster 2], [`k3s-app2`], [`172.16.0.83`], [2 CPUs, 4 GB RAM, 30 GB Disk],
)

- Auf dem Laptop `kubectl`, `helm`, `jq`, `openssl`, `curl` und `git`. Ab Kapitel 11 zusätzlich die `aws`-CLI.
- SSH-Zugang zu allen drei VMs mit einem Benutzer, der `sudo` darf.
- Für Kapitel 11 ein AWS-Konto. Alles andere läuft ohne Cloud.
- Rund drei Wochenenden Zeit, oder ein Kapitel pro Abend.

#hinweis("Andere IP-Adressen?", akzent, akzent-hell)[
  Die drei Adressen stehen in den k3s-Konfigurationen unter `observability/k3s/`, in `observability/k3s/coredns-custom.yaml` und in vielen Befehlen. Hast du andere, ersetze sie überall, bevor du mit Kapitel 2 beginnst. Ein `grep -rnE "172\.16\.0\.(126|228|83)" observability/` zeigt dir jede Stelle.
]

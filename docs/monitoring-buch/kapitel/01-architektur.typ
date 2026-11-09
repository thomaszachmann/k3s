#import "../lib.typ": *

#kapitel(
  [Die Architektur im Überblick],
  ziel: [Du weißt, welche Daten aus welchem Cluster wohin fließen, und warum die App-Cluster ihre Daten selbst zur Zentrale schicken.],
  zeit: [20 Minuten Lesen],
)

== Die Frage hinter allem

Ein Cluster allein ist schnell überwacht. Ein Prometheus, ein Grafana, fertig. Mit dem zweiten Cluster beginnen die Probleme. Du hast zwei Grafanas, zwei Sätze Alarme und zwei Orte, an denen du nachsehen musst. Beim dritten Cluster sucht niemand mehr in allen.

Dieses Buch baut deshalb eine *Zentrale*. Sie sammelt die Daten aller Cluster, bewahrt sie günstig in S3 auf und beantwortet Fragen über alle Cluster hinweg. Die App-Cluster bleiben schlank. Sie sammeln nur ein und schicken weiter.

== Die vier Signale

Observability ruht auf vier Arten von Daten. Jede beantwortet eine andere Frage:

#tabelle(
  (auto, 1fr, 1fr),
  ([Signal], [Frage], [Beispiel]),
  [*Metriken*], [Wie viel, wie oft, wie schnell?], [CPU-Last eines Nodes, Anfragen pro Sekunde, Fehlerquote],
  [*Logs*], [Was genau ist passiert?], [Eine Fehlermeldung mit Stacktrace, ein Kubernetes-Event],
  [*Traces*], [Wo ist die Zeit geblieben?], [Eine Anfrage durch drei Dienste mit der Dauer jedes Schritts],
  [*Profile*], [Welche Codezeile verbraucht die CPU?], [Ein Flammendiagramm einer Go-Funktion],
)

Metriken sind billig und schnell. Sie sagen dir, *dass* etwas nicht stimmt. Logs und Traces sagen dir, *was* und *wo*. Profile gehen bis auf die Funktion hinunter. Die ersten drei Signale baust du vollständig auf, Profile streift Kapitel 13 mit Pyroscope.

#warum[
  Erst die Verbindung macht die Signale wertvoll. Ein Alarm auf eine Metrik führt dich zu den Logs der betroffenen Pods, ein Log-Eintrag mit Trace-ID zum Trace, ein Trace zum langsamen Dienst. Deshalb tragen alle Daten dasselbe Label `cluster`, und Grafana kann zwischen ihnen springen.
]

== Zentral oder dezentral

Für mehrere Cluster gibt es zwei Grundmuster:

#tabelle(
  (auto, 1fr, 1fr),
  ([], [Dezentral], [Zentral]),
  [Speicher], [Jeder Cluster speichert selbst], [Eine Zentrale speichert alles],
  [Abfragen], [Pro Cluster getrennt, oder ein Query-Layer, der alle Cluster erreicht], [An einer Stelle, über alle Cluster],
  [Last in den App-Clustern], [Hoch: Prometheus, Speicher, eventuell Grafana], [Gering: nur ein Sammler],
  [Ausfall der Zentrale], [Kein Problem], [Keine Sicht mehr, Daten puffern kurz im Sammler],
)

Dieses Buch wählt die zentrale Variante. Sie ist einfacher zu betreiben, und die App-Cluster brauchen kaum Ressourcen. Den Nachteil, dass die Zentrale ein einzelner Punkt ist, behandelst du mit Meta-Monitoring und einem Dead Man's Switch in den Kapiteln 7 und 13.

== Push statt Pull

Prometheus holt sich Metriken normalerweise selbst ab (_Pull_). Für die Zentrale drehen wir das um: Die App-Cluster schicken ihre Metriken per _Remote Write_ an Thanos Receive (_Push_). Dafür gibt es drei Gründe.

*NAT und Firewalls.* In der Praxis steht ein App-Cluster oft hinter NAT, in einem anderen Rechenzentrum oder einer anderen Cloud. Die Zentrale kann ihn nicht erreichen, er die Zentrale aber schon. Push braucht nur eine ausgehende HTTPS-Verbindung zu einem einzigen Namen. Im Labor liegen alle VMs im selben Netz, der Aufbau funktioniert aber genauso, wenn sie das nicht tun.

*Ein einziges S3-Ziel.* Die Alternative wäre ein Thanos Sidecar in jedem Cluster. Dann bräuchte jeder Cluster eigene S3-Zugangsdaten, und die Zentrale müsste per gRPC in jeden Cluster hinein, um aktuelle Daten abzufragen. Mit Push kennt nur die Zentrale den S3-Speicher.

*Ein Muster für alles.* Loki und Tempo arbeiten ohnehin nach dem Push-Prinzip. Mit Remote Write für Metriken schickt ein einziger Sammler, Grafana Alloy, alle drei Signale auf dieselbe Weise: über HTTPS, mit Basic Auth und mit dem Clusternamen als Mandant.

#falle[
  Push hat einen Preis. Fällt ein App-Cluster komplett aus, kommen von ihm einfach keine Daten mehr, und das sieht zunächst aus wie Ruhe. Du brauchst deshalb einen Alarm auf _fehlende_ Daten. Den baust du in Kapitel 7.
]

== Wie die Daten fließen

Jedes Signal nimmt seinen eigenen Weg, aber alle enden in S3 und in Grafana:

#tabelle(
  (auto, 1fr, 1fr, auto, auto),
  ([Signal], [Sammler im Cluster], [Endpunkt auf obs], [Speicher], [Ansicht]),
  [Metriken (obs)], [Prometheus aus `kps`], [Thanos Receive intern, Port 19291], [Bucket `thanos`], [Grafana über Thanos Query],
  [Metriken (app1, app2)], [Alloy, kube-state-metrics, node-exporter], [`https://receive.obs.internal`], [Bucket `thanos`], [Grafana über Thanos Query],
  [Logs], [Alloy], [`https://loki.obs.internal`], [Bucket `loki`], [Grafana mit LogQL],
  [Traces], [Alloy (OTLP)], [`https://tempo.obs.internal`], [Bucket `tempo`], [Grafana mit TraceQL],
  [Profile], [Pyroscope (optional)], [nur auf obs], [lokal], [Grafana],
  [Alarme], [Prometheus, Thanos Ruler, Loki-Ruler], [Alertmanager auf obs], [–], [Mailpit, Watchdog-Dienst],
)

Jeder Cluster schreibt als eigener *Mandant*. Thanos Receive erhält den Clusternamen im Header `THANOS-TENANT`, Loki und Tempo im Header `X-Scope-OrgID`. Zusätzlich trägt jede Serie, jeder Log-Stream und jede Span das Label `cluster`. So bleibt die Herkunft auch dann erkennbar, wenn du über alle Mandanten hinweg abfragst.

Die Zentrale ist von außen nur über Traefik erreichbar, mit TLS aus einer eigenen kleinen CA und Basic Auth. Jeder Cluster hat einen eigenen Benutzer. Den S3-Speicher sieht niemand außerhalb von `obs`.

#aufgabe[
  Lies die Tabelle noch einmal und überlege: Welche Verbindungen gehen von `app1` aus, und welche gehen in `app1` hinein? Wenn deine Antwort bei „hinein“ leer ist, hast du das Push-Prinzip verstanden.
]

== Der Weg durch das Buch

#tabelle(
  (auto, 1fr, auto),
  ([Kap.], [Inhalt], [Cluster]),
  [2], [Drei k3s-Cluster, Kubeconfig-Kontexte, DNS und TLS], [alle],
  [3], [S3 im Cluster mit SeaweedFS], [obs],
  [4], [Die Zentrale: Prometheus und Thanos Receive], [obs],
  [5], [Metriken aus den App-Clustern mit Alloy], [app1, app2],
  [6], [Grafana als Code], [obs],
  [7], [Alarme, die ankommen], [obs],
  [8], [Logs mit Loki und Alloy], [alle],
  [9], [Traces mit Tempo und OpenTelemetry], [alle],
  [10], [Fertige Dashboards], [obs],
  [11], [S3 auf AWS], [obs],
  [12], [Backup und Restore], [alle],
  [13], [Was sonst noch fehlt], [alle],
  [14], [Betrieb und Fehlersuche], [alle],
  [15], [Anhang: Versionen, Repo, Spickzettel], [–],
)

Die Reihenfolge folgt dem Muster „erst beobachten, dann scharf schalten“. Zuerst fließen Metriken, dann siehst du sie in Grafana, erst danach kommen Alarme. Logs und Traces folgen, wenn das Fundament steht.

== Der Ressourcenplan

Wie viel Speicher die Komponenten brauchen, hängt stark von der Datenmenge ab. Die folgenden Werte sind *geschätzt* für ein Labor mit drei Ein-Node-Clustern und einer kleinen Demo-App. In Kapitel 14 misst du die echten Werte nach.

#tabelle(
  (1fr, auto, auto),
  ([Komponente auf obs], [RAM (geschätzt)], [Disk (geschätzt)]),
  [k3s mit Traefik, CoreDNS, local-path], [0,8 GB], [5 GB],
  [SeaweedFS], [0,3 bis 1 GB], [bis 30 GB (Limit)],
  [Prometheus (6 h Retention)], [0,8 GB], [2 GB],
  [Thanos Receive (6 h lokal)], [1 GB], [5 GB],
  [Thanos Query, Store, Compact, Ruler], [1 GB], [5 GB],
  [Alertmanager, Grafana, Mailpit], [0,4 GB], [1 GB],
  [Loki (SingleBinary)], [1 GB], [5 GB],
  [Tempo mit Metrics-Generator], [1 GB], [5 GB],
  [Alloy, node-exporter, kube-state-metrics], [0,4 GB], [–],
  [*Summe*], [*rund 7 bis 8 GB*], [*rund 60 GB*],
)

#tabelle(
  (1fr, auto, auto),
  ([Komponente auf app1 und app2], [RAM (geschätzt)], [Disk (geschätzt)]),
  [k3s mit Traefik, CoreDNS, local-path], [0,7 GB], [5 GB],
  [Alloy (Metriken, Logs, Traces)], [0,3 GB], [1 GB WAL],
  [kube-state-metrics, node-exporter], [0,1 GB], [–],
  [Demo-App (nur app1)], [0,3 GB], [–],
  [*Summe*], [*rund 1,5 GB*], [*rund 10 GB*],
)

Daraus ergeben sich die Größen aus dem Vorwort: 12 GB RAM für `obs` mit Luft für Spitzen, 4 GB für jeden App-Cluster. Mit 8 GB auf `obs` kommst du aus, wenn du Tempo erst in Kapitel 9 startest und die Retention knapp hältst.

#gelernt(
  [Metriken, Logs, Traces und Profile beantworten verschiedene Fragen. Erst zusammen erklären sie einen Fehler.],
  [Eine Zentrale mit schlanken App-Clustern ist einfacher zu betreiben als ein Speicher pro Cluster.],
  [Push per Remote Write braucht nur ausgehende Verbindungen und hält die S3-Zugangsdaten an einer Stelle.],
  [Jeder Cluster schreibt als eigener Mandant und trägt zusätzlich das Label `cluster`.],
  [Ausbleibende Daten sind bei Push unsichtbar. Dagegen hilft ein eigener Alarm.],
)

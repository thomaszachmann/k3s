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

=== Was passiert, wenn obs ausfällt?

An dieser Frage erkennst du, wie zuverlässig eine Architektur wirklich ist. Für dieses Buch wurde sie im Labor gemessen: Die Zentrale war für die App-Cluster 66 Minuten lang nicht erreichbar. Das Ergebnis in einem Satz: *Metriken kamen vollständig an, Logs zur Hälfte, Traces gar nicht.*

#tabelle(
  (auto, 1fr, auto),
  ([Signal], [Wie Alloy puffert], [Nach 66 Minuten Ausfall]),
  [Metriken], [Write-Ahead-Log auf der Platte, bis zu 8 Stunden], [nichts verloren],
  [Logs], [im Speicher, gibt nach rund 8 Minuten auf], [rund 32 Minuten verloren],
  [Traces], [im Speicher, gibt nach 5 Minuten auf], [alles verloren],
)

Alarme gibt es während des Ausfalls trotzdem: Die Zentrale merkt nach acht Minuten, dass zwei Cluster schweigen. Fällt dagegen die Zentrale selbst aus, kann sie niemanden mehr warnen. Das übernimmt der Dead Man's Switch aus Kapitel 7. Wie die Messung im Detail ablief und wie du die Plattform so baust, dass ein Ausfall möglichst nichts kostet, beschreibt Kapitel 15.

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

== Was läuft wo

Die Tabelle oben zeigt die Wege der Daten. Die Skizze zeigt, auf welcher VM am Ende was läuft. Sie ist bewusst einfach gehalten: drei Kästen, ein Pfeil.

#datei("Was läuft auf welcher VM (Endstand nach Kapitel 9)", ```text
  Dein Mac: kubectl, helm, Browser
     │ Port 6443 zu allen drei Clustern, Port 443 zu grafana.obs.internal
     ▼
  ┌─ k3s-obs (172.16.0.126), die Zentrale ──────────────────────┐
  │ Traefik :443   receive · loki · tempo · grafana ·            │
  │                alertmanager · s3  (.obs.internal)            │
  │ Metriken  Prometheus ─► Thanos Receive ─► SeaweedFS (S3)     │
  │           Thanos Query · Store · Compact · Ruler             │
  │ Logs      Loki          ─► SeaweedFS                         │
  │ Traces    Tempo         ─► SeaweedFS                         │
  │ Ansicht   Grafana       Alarme  Alertmanager · Mailpit       │
  │ Sammler   Alloy (nur Logs und Traces von obs selbst)         │
  └──────────────────────────────▲───────────────────────────────┘
                                 │ HTTPS mit Basic Auth,
                                 │ nur ausgehend von app1 und app2
             ┌───────────────────┴───────────────────┐
  ┌─ k3s-app1 (172.16.0.228) ─┐       ┌─ k3s-app2 (172.16.0.83) ─┐
  │ Alloy                     │       │ Alloy                     │
  │ node-exporter             │       │ node-exporter             │
  │ kube-state-metrics        │       │ kube-state-metrics        │
  │ HotROD (Demo, Kapitel 9)  │       │                           │
  └───────────────────────────┘       └───────────────────────────┘
```, erklaerung: [
  Alles Schwere läuft auf obs. In app1 und app2 laufen nur drei kleine Sammler und deine Anwendungen. Prometheus gibt es nur auf obs. In den App-Clustern übernimmt Alloy das Einsammeln und schickt die Daten weiter. SeaweedFS ist nur innerhalb von obs erreichbar. Erst Kapitel 12 öffnet es unter `s3.obs.internal` für die Backups.
])

Jeder Cluster schreibt als eigener *Mandant*. Thanos Receive erhält den Clusternamen im Header `THANOS-TENANT`, Loki und Tempo im Header `X-Scope-OrgID`. Zusätzlich trägt jede Serie, jeder Log-Stream und jede Span das Label `cluster`. So bleibt die Herkunft auch dann erkennbar, wenn du über alle Mandanten hinweg abfragst.

Die Zentrale ist von außen nur über Traefik erreichbar, mit TLS aus einer eigenen kleinen CA und Basic Auth. Jeder Cluster hat einen eigenen Benutzer. Den S3-Speicher sieht niemand außerhalb von `obs`.

#aufgabe[
  Lies die Tabelle noch einmal und überlege: Welche Verbindungen gehen von `app1` aus, und welche gehen in `app1` hinein? Wenn deine Antwort bei „hinein“ leer ist, hast du das Push-Prinzip verstanden.
]

== Der Weg durch das Buch

Das Buch baut die Plattform Schicht für Schicht auf. Jede Schicht prüfst du, bevor die nächste darauf aufsetzt. Die Tabelle zeigt die Reihenfolge, wo du arbeitest und woran du erkennst, dass ein Schritt gelungen ist:

#tabelle(
  (auto, 1fr, auto, 1fr),
  ([Kap.], [Was entsteht], [Wo], [Woran du siehst, dass es läuft]),
  [2], [Drei k3s-Cluster, Kontexte auf dem Mac, Namen `*.obs.internal`, eigene CA], [alle], [`kubectl get nodes` in jedem Kontext, `nslookup` aus einem Pod],
  [3], [S3-Speicher SeaweedFS mit vier Buckets und Konten], [obs], [`aws s3 ls` mit dem Konto `loki` zeigt nur `loki`],
  [4], [Prometheus, Thanos Receive, Query, Store, Compact, Ruler], [obs], [Thanos Query zeigt `cluster="obs"`],
  [5], [Alloy, node-exporter und kube-state-metrics, Zugang über HTTPS], [app1, app2], [Thanos Query zeigt alle drei Cluster],
  [6], [Grafana mit Datenquellen aus dem Repo], [obs], [Login unter `grafana.obs.internal`, Explore zeigt drei Cluster],
  [7], [Alarmregeln, Alertmanager, Mailpit, Dead Man's Switch], [obs], [Ein absichtlicher Ausfall erzeugt eine Mail],
  [8], [Loki, Alloy sammelt Logs und Events, Log-Alarme], [alle], [Explore mit Loki zeigt Logs aller Cluster],
  [9], [Tempo, Alloy nimmt Traces an, Demo-App HotROD], [alle], [TraceQL findet Traces, Sprung vom Log zum Trace],
  [10], [Sieben fertige Dashboards], [obs], [Ordner *Plattform* und *Signale* in Grafana],
  [11], [Umzug der Buckets zu AWS S3 (optional)], [obs], [Neue Blöcke landen bei AWS],
  [12], [Backups: etcd-Snapshots und Velero], [alle], [Ein gelöschter Namespace kommt zurück],
  [13], [Was sonst noch fehlt: Zertifikate, Profile, Rechte], [alle], [je Abschnitt],
  [14], [Betrieb und Fehlersuche], [alle], [–],
  [15], [Vom Labor zur Enterprise-Architektur: Hochverfügbarkeit], [–], [Ein Lesekapitel ohne Installation],
  [16], [Enterprise-Observability: Multi-Tenancy mit Thanos], [–], [Ein Lesekapitel mit Tests im Labor],
  [17], [Anhang: Versionen, Repo, Spickzettel], [–], [–],
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

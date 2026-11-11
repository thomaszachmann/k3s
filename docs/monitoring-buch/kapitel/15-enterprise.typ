#import "../lib.typ": *

#kapitel(
  [Vom Labor zur Enterprise-Architektur: Hochverfügbarkeit und Datenverlust vermeiden],
  ziel: [Du weißt, was mit Metriken, Logs und Traces passiert, wenn die Zentrale ausfällt, welche Bausteine dein Labor zu einer hochverfügbaren Plattform machen und wie du einen Standortausfall übersteht.],
  zeit: [60 Minuten Lesen],
  braucht: [Kapitel 1 bis 12. Dieses Kapitel installiert nichts.],
)

Bis hierher hast du eine Plattform gebaut, die funktioniert und die du verstehst. Sie hat aber eine Schwäche, die du von Anfang an kanntest: Alles Wichtige läuft auf einer einzigen VM. Fällt `obs` aus, sieht niemand mehr etwas, und ein Teil der Daten ist verloren.

Dieses Kapitel zeigt, wie aus dem Labor eine Plattform wird, die auch im Ernstfall trägt. Es beginnt mit einer Messung im Labor: Was passiert wirklich, wenn `obs` eine Stunde lang nicht erreichbar ist? Danach gehst du die Bausteine einzeln durch und siehst, wie jeder redundant wird. Am Ende steht eine Referenzarchitektur mit Aufwand und Kosten.

#hinweis("Skizzen, keine fertigen Rezepte", warn, warn-hell)[
  Die Laborkapitel enthalten getestete Befehle. Dieses Kapitel nicht. Die YAML-Ausschnitte hier zeigen, *welche* Einstellung zählt, nicht eine fertige Konfiguration für deinen Betrieb. Sie wurden nicht auf einem hochverfügbaren Cluster getestet. Prüfe jede Einstellung gegen die Doku deiner Versionen und teste sie mit den Ausfalltests am Ende dieses Kapitels, bevor du dich darauf verlässt.
]

== Wo das Labor an seine Grenzen stößt

Ein *Single Point of Failure* ist ein Teil, dessen Ausfall das Ganze lahmlegt. Im Labor ist das fast jede Komponente:

#tabelle(
  (auto, auto, 1fr),
  ([Komponente], [Im Labor], [Was ein Ausfall bewirkt]),
  [VM `obs`], [ein Node], [Alles auf der Zentrale steht: Speichern, Abfragen, Alarme],
  [Traefik], [ein Pod], [Kein Cluster kann mehr schreiben, Grafana ist nicht erreichbar],
  [Thanos Receive], [eine Replika], [Keine neuen Metriken, Alloy puffert],
  [Loki], [ein Prozess, `replication_factor: 1`], [Keine neuen Logs, Alloy puffert kurz],
  [Tempo], [ein Prozess], [Keine neuen Traces, Alloy puffert sehr kurz],
  [SeaweedFS], [ein Pod, eine Kopie jeder Datei], [Kein Upload, keine alten Daten; Plattendefekt heißt Datenverlust],
  [Alertmanager], [eine Replika], [Keine Benachrichtigungen. Nur der Dead Man's Switch merkt es],
  [Grafana], [eine Replika, ohne Datenbank], [Keine Ansicht, aber kein Datenverlust],
  [Alloy in den App-Clustern], [ein Pod pro Node, Puffer im Container], [Neustart löscht den Puffer],
)

Die letzte Zeile ist leicht zu übersehen, und sie betrifft dich auch ohne Ausfall der Zentrale. Darauf kommt der Abschnitt über Pufferung zurück.

== Gemessen: obs fällt eine Stunde aus

Bevor du Hochverfügbarkeit planst, solltest du wissen, was ein Ausfall heute kostet. Deshalb wurde das Labor für dieses Kapitel absichtlich gestört.

*Der Versuch.* Traefik auf `obs` wurde auf null Replikas skaliert:

```bash
kubectl --context obs -n kube-system scale deploy traefik --replicas=0
```

Für `app1` und `app2` ist die Zentrale damit unerreichbar, Verbindungen laufen ins Leere. Auf `obs` selbst läuft alles weiter, so lässt sich danach genau nachzählen, was angekommen ist. Nach 66 Minuten wurde Traefik wieder gestartet. Während des Ausfalls hat ein kleines Skript alle fünf Minuten die Zähler von Alloy in `app1` mitgeschrieben. Danach wurde für jedes Signal gezählt, was aus der Ausfallzeit gespeichert ist. Die Demo-App HotROD lief die ganze Zeit mit gleichbleibender Last.

=== Was während des Ausfalls passiert

#tabelle(
  (auto, 1fr),
  ([Nach], [Beobachtung]),
  [2 Minuten], [Alloy hält 12.423 Metrik-Proben im WAL zurück. Erste Traces stehen in der Warteschlange.],
  [5 bis 7 Minuten], [Die ersten 242 Spans sind endgültig verworfen. Ihre fünf Minuten für Wiederholungen sind abgelaufen.],
  [8 Minuten], [`ClusterSchweigt` feuert für `app1` und `app2`. Der Alarm kommt aus der Zentrale, die ja noch läuft.],
  [12 Minuten], [Alloy verwirft die ersten 47 Log-Zeilen. Nach 37 Minuten sind es 16.348.],
  [42 Minuten], [Die Warteschlange für Traces ist voll, 1000 Anfragen. Neue Spans lehnt Alloy jetzt sofort ab.],
  [62 Minuten], [Verworfen: 24.621 Log-Zeilen, 2.074 Spans nach Ablauf der Wiederholungen, 23.592 Spans ohne Platz in der Warteschlange. Metriken: keine.],
)

#bild("bilder/15-ausfall-multi-cluster.png", [Das Multi-Cluster-Dashboard aus Kapitel 10 nach knapp zehn Minuten Ausfall. Für `app1` und `app2` gibt es keine aktuellen Werte mehr, das Datenalter steht rot bei fast zehn Minuten.])

=== Was nach dem Ausfall ankommt

Zwei Minuten nach dem Neustart von Traefik hatte Alloy die Metriken aus dem WAL vollständig nachgeliefert, ohne eine einzige abgelehnte Probe. Dann wurde gezählt:

#tabelle(
  (auto, 1fr, 1fr),
  ([Signal], [Aus 66 Minuten Ausfall gespeichert], [Grund]),
  [Metriken], [*alles*: in jedem 5-Minuten-Fenster alle 10 Proben von `up`], [WAL auf der Platte. Jeder Cluster ist ein eigener Mandant, deshalb lagen die nachgelieferten Proben nicht „zu weit zurück“.],
  [Logs], [*etwa die Hälfte*: die erste Minute und die letzten 33 Minuten. Rund 32 Minuten fehlen.], [Puffer im Speicher, nach zehn Versuchen verworfen. Siehe die Erklärung unten.],
  [Traces], [*nichts*], [Warteschlange im Speicher, nach fünf Minuten verworfen, danach voll.],
)

#bild("bilder/15-ausfall-logs-luecke.png", [Log-Zeilen der Demo-App pro Minute in Loki, nach dem Ausfall abgefragt. Links die Zeit vor dem Ausfall, in der Mitte die Lücke von gut einer halben Stunde, rechts ab dem letzten Drittel des Ausfalls wieder vollständig. Die Achse zeigt Ortszeit.])

*Warum die Logs zur Hälfte zurückkamen.* Die Zeilen der ersten halben Stunde hatte die Quelle `loki.source.kubernetes` schon gelesen und an `loki.write` übergeben. Dort scheiterten sie nach zehn Versuchen und wurden verworfen. Danach war der Puffer von `loki.write` voll, und die Quelle konnte keine neuen Zeilen mehr loswerden. Sie hörte auf zu lesen, und ihre gemerkte Position blieb stehen. Nach dem Ausfall las sie ab dieser Position weiter, über die Kubernetes-API, die die Logs der laufenden Pods noch hatte. Das ist die Deutung des Verhaltens anhand der Zähler und des Quellcodes von Alloy, nicht eine dokumentierte Zusage. Wäre ein Pod in der Zwischenzeit neu gestartet oder sein Log rotiert worden, wären auch diese Zeilen verloren gewesen.

#warum[
  Die Messung zeigt das Muster, das du dir merken solltest: *Metriken überstehen einen Ausfall von einer Stunde, Logs nur zum Teil und Traces gar nicht.* Bei längeren Ausfällen kommen für Metriken zwei Grenzen dazu: `max_keepalive_time` (8 Stunden) und der Neustart von Alloy, der den WAL im Labor löscht. Welche Daten du verlieren darfst, ist eine Entscheidung, die du vor dem Ausfall triffst, nicht danach.
]


== Wie Alloy puffert, und wo die Grenzen liegen

Alloy behandelt die drei Signale völlig unterschiedlich. Das ist kein Versehen, sondern folgt aus den Komponenten, die du in den Kapiteln 5, 8 und 9 eingesetzt hast.

=== Metriken: der Write-Ahead-Log

`prometheus.remote_write` schreibt jede Probe zuerst in einen *Write-Ahead-Log* (WAL) auf der Platte und schickt sie erst danach los. Antwortet Receive nicht oder mit einem 5xx-Fehler, versucht Alloy es wieder, mit wachsenden Pausen bis `max_backoff` (Standard 5 Sekunden). Die Proben bleiben im WAL, bis sie angekommen sind.

#tabelle(
  (auto, auto, 1fr),
  ([Einstellung], [Standard], [Bedeutung]),
  [`wal.max_keepalive_time`], [`8h`], [Proben, die älter sind, löscht Alloy aus dem WAL, auch wenn sie nie angekommen sind],
  [`wal.min_keepalive_time`], [`5m`], [So lange bleiben Proben mindestens im WAL],
  [`wal.truncate_frequency`], [`2h`], [Wie oft Alloy den WAL aufräumt],
  [`queue_config.max_backoff`], [`5s`], [Längste Pause zwischen zwei Versuchen],
  [`queue_config.retry_on_http_429`], [`true`], [Bei „zu viele Anfragen“ nach `Retry-After` erneut senden],
)

Zwei Grenzen musst du kennen. Erstens wirft Alloy Proben weg, die Receive mit einem 4xx-Fehler außer 429 ablehnt. Die Doku sagt dazu: „Other HTTP 4xx status code responses are never considered recoverable errors.“ Genau so einen Fehler erzeugt Receive, wenn Proben zu alt sind (dazu gleich mehr). Zweitens liegt der WAL dort, wo Alloy seinen Speicher hat.

#falle[
  *Der WAL überlebt im Labor keinen Neustart.* Die Werte aus Kapitel 5 starten Alloy mit `--storage.path=/tmp/alloy`, und `/tmp/alloy` liegt im Dateisystem des Containers, nicht auf einem Volume. Jeder Neustart des Pods, auch das `rollout restart` nach einer Änderung der Konfiguration, löscht damit alles, was noch nicht angekommen war. Für den Betrieb gehört der Speicherpfad auf ein `hostPath`-Volume des Nodes oder auf ein PersistentVolume. Dann übersteht der Puffer auch einen Neustart.
]

=== Logs: Puffer im Speicher, begrenzte Geduld

`loki.write` sammelt Zeilen im Arbeitsspeicher und schickt sie in Paketen. Scheitert ein Paket, versucht Alloy es mit wachsender Pause erneut, standardmäßig höchstens zehnmal (`max_backoff_retries = 10`, Pausen von 500 ms bis höchstens 5 Minuten). Danach verwirft es das Paket und zählt die Zeilen in `loki_write_dropped_entries_total`. Rechnerisch gibt Alloy ein Paket nach rund achteinhalb Minuten auf.

Dazu kommt `loki.source.kubernetes`, die Quelle der Pod-Logs. Sie merkt sich, bis wohin sie gelesen hat, und liest nach einem Neustart ab dieser Stelle weiter. Die Stelle rückt aber vor, sobald eine Zeile an `loki.write` übergeben ist, nicht erst, wenn Loki sie bestätigt hat. Was im Speicher von `loki.write` verloren geht, liest die Quelle also nicht erneut.

Es gibt zwei Stellschrauben, beide mit Vorsicht zu genießen:

- `max_backoff_retries = 0` wiederholt unbegrenzt. Dann wächst der Speicher von Alloy während eines Ausfalls, und irgendwann blockiert die Quelle.
- Ein `wal`-Block für `loki.write` existiert, ist aber *experimentell*. Alloy muss dafür mit `--stability.level=experimental` laufen, und die Funktion kann sich in einer späteren Version ändern oder wegfallen.

=== Traces: kurze Warteschlange im Speicher

`otelcol.exporter.otlphttp` hält eine Warteschlange von 1000 Anfragen im Speicher (`sending_queue`). Scheitert eine Anfrage, wiederholt der Exporter sie mit Pausen von 5 bis 30 Sekunden, aber höchstens fünf Minuten lang (`retry_on_failure.max_elapsed_time`). Danach ist die Anfrage verloren, sie erscheint in `otelcol_exporter_send_failed_spans_total`.

Eine persistente Warteschlange ist möglich: Die Komponente `otelcol.storage.file` speichert die Warteschlange auf der Platte, und `sending_queue` verweist mit `storage` darauf. `otelcol.storage.file` ist allerdings als *Public preview* eingestuft, also noch nicht allgemein freigegeben.

#datei("Skizze: persistente Warteschlange für Traces (nicht getestet)", ```hcl
otelcol.storage.file "traces_queue" {
  // Verzeichnis unter dem Speicherpfad von Alloy, der persistent sein muss
}

otelcol.exporter.otlphttp "traces_tempo" {
  sending_queue {
    storage    = otelcol.storage.file.traces_queue.handler
    queue_size = 5000
  }
  retry_on_failure {
    max_elapsed_time = "0s"   // unbegrenzt wiederholen
  }
  // client { ... } wie in Kapitel 9
}
```, erklaerung: [
  Die Skizze zeigt nur das Prinzip. Ob die Warteschlange einen Ausfall von zwei Stunden übersteht, hängt von Datenmenge, `queue_size` und Plattenplatz ab. Eine garantierte Pufferdauer gibt es nicht.
])

=== Zusammengefasst

#tabelle(
  (auto, 1fr, 1fr, 1fr),
  ([], [Metriken], [Logs], [Traces]),
  [Puffer], [WAL auf der Platte], [Speicher], [Speicher],
  [Gibt auf nach], [`max_keepalive_time` (8 h) oder bei 4xx], [10 Versuchen (rund 8,5 min)], [`max_elapsed_time` (5 min)],
  [Persistent machbar], [ja, Speicherpfad auf Volume], [nur experimentell], [mit `otelcol.storage.file` (Preview)],
  [Zähler für Verluste], [`prometheus_remote_storage_samples_failed_total`], [`loki_write_dropped_entries_total`], [`otelcol_exporter_send_failed_spans_total`],
)

#warum[
  Keine Pufferung ist ein Ersatz für eine erreichbare Zentrale. Puffer überbrücken Minuten, vielleicht Stunden, aber sie haben eine Grenze, und diese Grenze hängt von Datenmenge und Plattenplatz ab. Wer Datenverlust vermeiden will, macht deshalb zuerst die Empfänger hochverfügbar und nutzt Puffer nur für die verbleibenden kurzen Lücken.
]

== Ein hochverfügbarer Kubernetes-Cluster für obs

Die Grundlage ist ein Cluster, der den Ausfall eines Nodes übersteht.

#datei("Skizze: obs als hochverfügbarer Cluster", ```text
                 Load Balancer (virtuelle IP, z. B. kube-vip oder Hardware)
                 :6443 API-Server       :443 Ingress
                    │                      │
      ┌─────────────┼──────────────────────┼──────────────┐
      ▼             ▼                      ▼              ▼
  ┌─ cp1 ─┐    ┌─ cp2 ─┐    ┌─ cp3 ─┐   Control Plane: k3s server
  │ etcd  │    │ etcd  │    │ etcd  │   mit eingebettetem etcd
  └───────┘    └───────┘    └───────┘
  ┌─ w1 ──────┐  ┌─ w2 ──────┐  ┌─ w3 ──────┐   Worker: k3s agent
  │ Traefik   │  │ Traefik   │  │ Traefik   │   je eine Replika jeder
  │ Receive-0 │  │ Receive-1 │  │ Receive-2 │   zustandsbehafteten
  │ Loki-0    │  │ Loki-1    │  │ Loki-2    │   Komponente pro Node
  └───────────┘  └───────────┘  └───────────┘
```, erklaerung: [
  Drei Server-Nodes bilden das Quorum für etcd: Zwei von dreien müssen erreichbar sein. Die Worker tragen die Last. Jede wichtige Komponente läuft mindestens dreimal, je einmal pro Worker.
])

#tabelle(
  (auto, 1fr),
  ([Baustein], [Wozu und worauf du achtest]),
  [Drei Control-Plane-Nodes], [k3s mit eingebettetem etcd braucht eine ungerade Zahl von Servern. Der erste startet mit `--cluster-init`, die anderen treten mit `--server` und demselben Token bei. Bei drei Servern darf einer ausfallen.],
  [Feste Adresse für den API-Server], [Ein Load Balancer oder eine virtuelle IP vor den drei Servern. Diese Adresse gehört mit `--tls-san` ins Zertifikat, und die Kubeconfig zeigt auf sie, nicht auf einen einzelnen Node.],
  [Drei Worker], [Getrennt von der Control Plane, damit eine speicherhungrige Abfrage nicht etcd ausbremst.],
  [Redundanter Ingress], [Traefik mit mindestens zwei Replikas auf verschiedenen Nodes, davor ein Load Balancer, der nur gesunde Nodes anspricht. Ohne Load Balancer bleibt die eine IP aus `/etc/hosts` ein Single Point of Failure.],
  [Pod-Anti-Affinity], [Verhindert, dass zwei Replikas derselben Komponente auf einem Node landen. Sonst nimmt ein Node-Ausfall alle Kopien mit.],
  [PodDisruptionBudgets], [Erlauben bei Wartung, etwa `kubectl drain`, immer nur so viele Pods zu stoppen, dass das Quorum erhalten bleibt.],
  [Speicher für Volumes], [`local-path` bindet ein Volume an einen Node. Das ist für Receive, Loki und Tempo mit Replikation in Ordnung, denn die Kopien liegen auf anderen Nodes. Eine verteilte Speicherlösung wie Longhorn oder Ceph RBD ist nicht zwingend.],
)

#datei("Skizze: Anti-Affinity und PodDisruptionBudget für Receive (nicht getestet)", ```yaml
# im StatefulSet thanos-receive, spec.template.spec:
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels: {app.kubernetes.io/name: thanos-receive}
        topologyKey: kubernetes.io/hostname
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: thanos-receive, namespace: monitoring}
spec:
  maxUnavailable: 1
  selector:
    matchLabels: {app.kubernetes.io/name: thanos-receive}
```)

== Thanos Receive mit Replikation

Mehrere Receive-Pods allein machen noch keine Hochverfügbarkeit. Entscheidend ist, wie sie zusammenarbeiten.

*Der Hashring* aus Kapitel 4 bekommt so viele Einträge wie Pods. Für neue Installationen empfiehlt die Thanos-Doku den Algorithmus `ketama` (`--receive.hashrings-algorithm=ketama`). Der Standard `hashmod` verteilt beim Hinzufügen eines Pods fast alle Serien neu.

*Der Replikationsfaktor* `--receive.replication-factor=3` schreibt jede Serie auf drei Pods. Receive bestätigt eine Schreibanfrage, sobald ein Quorum geantwortet hat: bei drei Kopien zwei. Fällt ein Pod aus, geht das Schreiben weiter. Fallen zwei aus, antwortet Receive mit `503`, und Alloy puffert und wiederholt.

*Router und Ingestor trennen.* In großen Installationen nehmen eigene Pods die Anfragen an und verteilen sie (Router), andere speichern (Ingestor). Router sind zustandslos und lassen sich beliebig skalieren und neu starten, ohne dass Daten in Bewegung geraten. Ein Receive ohne `--receive.local-endpoint`, aber mit Hashring, arbeitet als reiner Router.

*Deduplizierung in Thanos Query.* Jeder Ingestor hängt sein eigenes Label an, etwa `receive_replica="0"`, `"1"` und `"2"`. Thanos Query fasst mit `--query.replica-label=receive_replica` die drei Kopien wieder zu einer Serie zusammen. Das hast du in Kapitel 4 schon vorbereitet.

Warum reicht es nicht, einfach `replicas: 3` ins StatefulSet zu schreiben?

- Ohne passenden Hashring wissen die Pods nichts voneinander. Jeder speichert, was bei ihm ankommt, und ein Ausfall verliert genau diesen Anteil.
- Ohne `replication-factor` gibt es keine Kopien.
- Ohne PersistentVolume pro Pod verliert ein neu gestarteter Ingestor seine TSDB und seinen WAL, also alles seit dem letzten Upload nach S3, bis zu zwei Stunden.
- Ohne Anti-Affinity liegen womöglich alle Kopien auf einem Node.
- Ohne Load Balancer vor Traefik bleibt der Eingang ein einzelner Punkt.

#falle[
  *Nachgelieferte Daten können abgewiesen werden.* Eine TSDB nimmt nur Proben an, die höchstens rund eine Stunde hinter der jüngsten Probe dieses Mandanten liegen. Ältere gelten als „out of bounds“, Receive antwortet mit `409`, und Alloy verwirft sie, weil 4xx nicht wiederholt wird. Dass jeder Cluster bei dir ein eigener Mandant ist, hilft: Der Kopf der TSDB von `app1` wandert während eines Ausfalls nicht weiter, weil niemand anderes in diesen Mandanten schreibt. Teilen sich mehrere Sender einen Mandanten, wird die Nachlieferung nach langen Ausfällen abgewiesen. Thanos kennt dafür ein Zeitfenster für Proben außer der Reihe (`--tsdb.out-of-order.time-window`). Es ist experimentell und verlangt, dass der Compactor mit `--compact.enable-vertical-compaction` läuft, sonst hält er an.
]

== Loki hochverfügbar

Loki kennt drei Betriebsarten:

#tabelle(
  (auto, 1fr),
  ([Betriebsart], [Wann]),
  [Monolithisch], [Ein Prozess mit allen Rollen. Laut Doku geeignet bis etwa 20 GB Logs pro Tag. Mehrere Instanzen mit gemeinsamem S3 und `replication_factor: 3` ergeben eine hochverfügbare Variante.],
  [Simple Scalable], [Getrennte Pfade für Schreiben, Lesen und Hintergrundarbeit. Wird mit Loki 4.0 entfernt, deshalb nicht mehr für neue Installationen.],
  [Microservices], [Jede Rolle einzeln skaliert. Für sehr große Datenmengen, mit entsprechend viel Betriebsaufwand.],
)

Für die meisten Plattformen ist der *monolithische Betrieb mit drei Instanzen* der richtige nächste Schritt. Dafür ändern sich im Wesentlichen drei Dinge gegenüber Kapitel 8:

- `replication_factor: 3`. Der Distributor schreibt jede Zeile an drei Ingester und wartet auf zwei Bestätigungen.
- Ein PersistentVolume pro Instanz für den WAL des Ingesters. Der WAL ist bei Loki standardmäßig an. Nach einem Neustart spielt der Ingester ihn wieder ein, statt die Zeilen im Speicher zu verlieren, die noch nicht im S3 liegen.
- Optional Zonen: Mit `zone_awareness_enabled` verteilt Loki die drei Kopien auf verschiedene Zonen, etwa Brandabschnitte oder Rechenzentren.

#falle[
  *Späte Logs haben ein Zeitfenster.* Loki lehnt eine Zeile ab, wenn sie mehr als die halbe `max_chunk_age` hinter der jüngsten Zeile desselben Streams liegt, standardmäßig also mehr als etwa eine Stunde. Die Antwort ist `400`, und Alloy wiederholt sie nicht. Grafana rät davon ab, `max_chunk_age` zu erhöhen. Für Logs heißt das: Ein Puffer, der länger als eine Stunde zurückhält, hilft nur, wenn in der Zwischenzeit nichts Neueres für denselben Stream angekommen ist.
]

Der *Compactor* von Loki, der die Aufbewahrung durchsetzt, darf nur einmal laufen. Das gilt auch bei drei Instanzen.

== Tempo hochverfügbar

Mit Tempo 3 hat sich die Architektur grundlegend geändert. Die früheren *Ingester* gibt es nicht mehr.

- Im *verteilten Betrieb* schreibt der Distributor jede Span in Kafka. Kafka ist der WAL: Der Distributor bestätigt erst, wenn Kafka die Daten hat. Daraus bauen *Block-Builder* die Blöcke für S3, und *Live-Stores* beantworten Abfragen auf frischen Daten. Weil Kafka die Daten sichert, hält Tempo selbst nur eine Kopie.
- Im *monolithischen Betrieb*, wie im Labor, gibt es kein Kafka. Der Distributor übergibt die Spans im selben Prozess an den Live-Store, der sie zuerst im Speicher sammelt und dann in einen lokalen WAL schreibt.

Hochverfügbarkeit heißt bei Tempo also: Kafka hochverfügbar betreiben (drei Broker, Replikation) und Distributor, Block-Builder und Live-Store mehrfach starten. Das ist deutlich mehr Betriebsaufwand als bei Loki. Der *Backend-Scheduler*, der die Kompaktierung steuert, läuft wie der Compactor bei Thanos und Loki nur einmal. Seine Meldungen `no jobs found` kennst du aus Kapitel 9.

Eine gute Nachricht: Spans dürfen jederzeit nachkommen. Tempo fügt sie bei einer Abfrage nach Trace-ID zusammen. Anders als bei Metriken und Logs gibt es kein Zeitfenster, das späte Daten abweist.

== S3-Speicher im Vergleich

#tabelle(
  (auto, 1fr, 1fr, 1fr, 1fr),
  ([], [SeaweedFS, ein Pod], [SeaweedFS verteilt], [Ceph RGW], [AWS S3]),
  [Kopien], [eine], [einstellbar, z. B. `010` = zweite Kopie in anderem Rack], [einstellbar, Replikation oder Erasure Coding], [mindestens drei Availability Zones],
  [Ausfall eines Rechners], [Speicher weg], [übersteht ihn mit Kopien], [übersteht ihn], [für dich unsichtbar],
  [Zweiter Standort], [nein], [mit Kopie `100` in anderem Rechenzentrum], [Multisite mit Zonen, Abgleich asynchron], [Cross-Region Replication, asynchron],
  [Betrieb], [sehr einfach], [3 oder 5 Master mit Raft, mehrere Volume-Server, Filer mit gemeinsamer Datenbank], [aufwendig, eigenes Fachwissen nötig], [kein eigener Betrieb],
  [Kosten], [Platte], [Platte mal Zahl der Kopien], [Platte mal Kopien, viel RAM und CPU], [nach Menge und Abrufen],
  [Geeignet für], [Labor], [kleine und mittlere Plattformen on-premises], [große Plattformen on-premises], [Cloud oder hybrid],
)

AWS gibt für S3 eine Haltbarkeit von 99,999999999 % an und eine Verfügbarkeit von 99,99 % bei S3 Standard, vertraglich zugesichert sind 99,9 %. Kapitel 11 hat gezeigt, wie der Umzug funktioniert.

#falle[
  *Ein Bucket, zwei Compactors: Datenverlust.* Der Compactor von Thanos „must be deployed as a singleton against a bucket“, so die Doku. Zwei Compactors auf demselben Bucket bearbeiten dieselben Blöcke, erzeugen Überlappungen, und der Compactor hält an, bis du die Blöcke von Hand reparierst. Dasselbe Prinzip gilt für den Compactor von Loki und den Backend-Scheduler von Tempo. Teilen sich zwei Zentralen einen Bucket, darf nur eine davon kompaktieren.
]

== Zwei Zentralen: Active/Passive und Active/Active

Ein hochverfügbarer Cluster übersteht den Ausfall eines Nodes, aber nicht den eines Rechenzentrums. Dafür brauchst du eine zweite Zentrale an einem anderen Standort.

=== Active/Passive

Eine Zentrale arbeitet, die zweite steht bereit. Die App-Cluster schreiben an einen Namen wie `receive.obs.example`, der im Normalfall auf Standort A zeigt.

#tabelle(
  (auto, 1fr),
  ([Frage], [Antwort]),
  [Umschalten], [Per DNS mit kurzer TTL oder über einen globalen Load Balancer mit Gesundheitsprüfung. Wer umschaltet, ein Mensch oder ein Automat, muss vorher feststehen.],
  [Daten der Vergangenheit], [Liegen im S3 von Standort A. Damit B sie lesen kann, repliziert der Speicher asynchron nach B, oder B liest den Bucket von A mit, solange A erreichbar ist.],
  [Compactor], [Läuft nur am aktiven Standort. Nach dem Umschalten muss er in A sicher aus sein, bevor er in B startet.],
  [Datenlücke], [Was zwischen Ausfall und Umschalten anfällt, puffert Alloy. Danach landen die Daten in B.],
)

=== Active/Active

Beide Zentralen arbeiten gleichzeitig, und jeder App-Cluster schreibt an *beide*. Alloy kann das: Ein `prometheus.remote_write` darf mehrere `endpoint`-Blöcke haben, `loki.write` ebenso, und für Traces leitet ein Empfänger an zwei Exporter weiter. Fällt ein Standort aus, hat der andere die Daten bereits.

#datei("Skizze: zwei Zentralen, jeder Cluster schreibt an beide", ```text
      app1, app2, ...                  jeder Alloy hat zwei Ziele
        │  │
        │  └────────────────────────────┐
        ▼                               ▼
  ┌─ Zentrale A (RZ 1) ─────┐    ┌─ Zentrale B (RZ 2) ─────┐
  │ Receive · Loki · Tempo  │    │ Receive · Loki · Tempo  │
  │ eigener Bucket A        │    │ eigener Bucket B        │
  │ eigener Compactor       │    │ eigener Compactor       │
  └───────────▲─────────────┘    └─────────────▲───────────┘
              │      Thanos Query liest beide   │
              └──────────── Grafana ────────────┘
```, erklaerung: [
  Jede Zentrale hat ihren eigenen Bucket und ihren eigenen Compactor, so kommen sie sich nie in die Quere. Eine Thanos Query kann beide Standorte als Endpunkte einbinden und fasst die doppelten Serien über ein Label wie `site` zusammen, genau wie die Replikas eines Standorts.
])

Active/Active kostet doppelten Speicher und doppelten Netzverkehr aus jedem App-Cluster. Dafür gibt es kein Umschalten und keine Lücke beim Ausfall eines Standorts. Ein Nachteil bleibt: Die Alarme. Beide Standorte werten dieselben Regeln aus. Damit nicht jeder Alarm doppelt ankommt, bilden die Alertmanager beider Standorte einen gemeinsamen Cluster (`--cluster.peer`, Port 9094 über TCP und UDP). Dann teilen sie Silences und wissen voneinander, welche Benachrichtigung schon verschickt ist.

== Monitoring des Monitorings

Die wichtigste Regel: *Wer die Zentrale überwacht, darf nicht in der Zentrale laufen.* Fällt obs aus, kann obs dir nicht mehr Bescheid geben.

- *Dead Man's Switch.* Der Watchdog aus Kapitel 7 meldet sich jede Minute bei einem Dienst außerhalb. Bleibt das Signal aus, schlägt dieser Dienst Alarm, über einen eigenen Weg, etwa SMS oder eine App. Ohne Umleitung schickt kube-prometheus-stack den Watchdog übrigens an den Empfänger `null`, er würde also nie jemanden erreichen.
- *Prüfung von außen.* Ein externer Dienst ruft regelmäßig `https://grafana.obs.internal/api/health` und den Schreibpfad von Receive auf. Er bemerkt, wenn der Eingang ausfällt, auch wenn obs selbst noch läuft.
- *Gegenseitige Überwachung.* Bei zwei Standorten überwacht jeder den anderen. Fällt einer aus, alarmiert der andere über seinen eigenen Alertmanager.
- *Unabhängiger Kanal.* Die Benachrichtigung über den Ausfall der Zentrale darf nicht über einen Mailserver laufen, der an derselben Zentrale hängt.

Im Labor hast du gesehen, wie schnell das greift: `ClusterSchweigt` feuerte 8 Minuten nach Beginn des Ausfalls, und der Dead Man's Switch bei healthchecks.io meldet sich mit den Werten aus Kapitel 7 nach spätestens 10 Minuten.

== Ausfälle üben: Disaster Recovery

Zwei Kennzahlen beschreiben, was ein Ausfall kosten darf:

- *RPO*, Recovery Point Objective: Wie viele Daten dürfen höchstens verloren gehen? Gemessen als Zeitspanne, etwa „höchstens 5 Minuten Logs“.
- *RTO*, Recovery Time Objective: Wie lange darf es dauern, bis die Plattform wieder arbeitet? Etwa „Grafana nach 30 Minuten wieder erreichbar“.

Beide legst du fest, bevor etwas passiert, und dann prüfst du sie mit Tests. Ein Test, den du nie gemacht hast, ist eine Hoffnung.

#tabelle(
  (auto, 1fr, 1fr),
  ([Test], [So simulierst du ihn], [Was du prüfst]),
  [Node fällt aus], [`kubectl drain` oder VM hart abschalten], [Schreiben geht weiter, Quorum hält, keine Lücke in den Daten],
  [Receiver fällt aus], [Einen Receive-Pod löschen, ein PVC verlieren], [Query liefert weiter vollständige Daten, der neue Pod holt auf],
  [Netzwerktrennung], [Traefik auf 0 skalieren oder Firewall-Regel, wie im Labor], [Wann feuert `ClusterSchweigt`, was liefert Alloy nach, wo bleibt eine Lücke],
  [S3 fällt aus], [SeaweedFS auf 0 skalieren, Zugangsdaten falsch setzen], [Receive puffert lokal bis zur Retention, Alarm `ReceiveUploadFehler`, Abfragen alter Daten scheitern sichtbar],
  [Zentrale fällt aus], [ganzen Cluster stoppen], [Dead Man's Switch meldet sich von außen, Umschalten auf Standort B gelingt innerhalb des RTO],
)

*Lücken kontrollieren.* Nach jedem Test misst du, was fehlt. Die Abfragen dafür kennst du aus dem Messabschnitt am Anfang dieses Kapitels: Proben pro Minute in Thanos, Zeilen pro Minute in Loki, Traces pro Minute in Tempo. Eine Lücke, die du nur vermutest, kannst du nicht beheben.

== Eine Referenzarchitektur

Für eine Plattform mit einigen Dutzend Clustern an einem Standort empfiehlt sich dieser Aufbau. Für einen zweiten Standort verdoppelst du ihn und schreibst Active/Active.

#tabelle(
  (auto, 1fr),
  ([Baustein], [Empfehlung]),
  [Kubernetes], [3 Control-Plane-Nodes, 3 bis 5 Worker, Load Balancer vor API-Server und Ingress],
  [Ingress], [Traefik mit 3 Replikas, Anti-Affinity, PodDisruptionBudget],
  [Metriken], [Thanos Receive mit 2 Routern und 3 Ingestoren, `replication-factor=3`, `ketama`, PVC je Ingestor; Query mit 2 Replikas; Store mit 2 Replikas; Compactor genau einmal],
  [Logs], [Loki monolithisch mit 3 Instanzen, `replication_factor: 3`, WAL auf PVC; Compactor einmal],
  [Traces], [Tempo verteilt mit Kafka (3 Broker), sobald Traces geschäftskritisch sind; bis dahin monolithisch mit dem Wissen, dass ein Ausfall Traces kostet],
  [Speicher], [AWS S3 oder ein anderer verwalteter Objektspeicher; on-premises Ceph RGW oder SeaweedFS mit drei Mastern und Replikation `010`],
  [Alarme], [Alertmanager mit 3 Replikas im Cluster-Verbund, Ruler mit 2 Replikas],
  [Grafana], [2 Replikas mit externer PostgreSQL-Datenbank für Sitzungen und Einstellungen; Dashboards weiter aus dem Repo],
  [Sammler], [Alloy mit Speicherpfad auf `hostPath`, damit der WAL Neustarts übersteht],
  [Außenwelt], [Dead Man's Switch, externe Prüfung der Eingänge, unabhängiger Benachrichtigungskanal],
)

== Aufwand, Ressourcen und Kosten

Mehr Verfügbarkeit kostet Rechner, Speicher und vor allem Betriebszeit. Die Werte für das Labor stammen aus Kapitel 1, die für die Enterprise-Variante sind grobe Schätzungen für eine kleine Plattform mit wenigen App-Clustern, nicht gemessen.

#tabelle(
  (auto, 1fr, 1fr),
  ([], [Labor], [Enterprise, ein Standort (geschätzt)]),
  [Nodes für die Zentrale], [1], [6 (3 Control Plane, 3 Worker)],
  [RAM der Zentrale], [rund 8 GB], [rund 60 bis 100 GB über alle Worker],
  [Lokale Platte], [rund 60 GB], [rund 3 × 200 GB, weil Receive, Loki und Tempo je drei Kopien halten],
  [Objektspeicher], [eine Kopie], [drei Kopien oder verwalteter Dienst],
  [Komponenten im Dauerbetrieb], [rund 15 Pods], [rund 40 bis 60 Pods, mit Kafka mehr],
  [Betriebsaufwand], [ein Wochenende zum Aufbau], [laufende Pflege: Updates, Tests, Bereitschaft],
)

Die größte Position ist meist nicht die Hardware, sondern die Zeit. Jede zusätzliche Komponente will aktualisiert, überwacht und geübt werden. Fang deshalb dort an, wo der Verlust am meisten schmerzt: Bei den meisten Teams sind das Metriken und Alarme. Logs folgen, Traces zuletzt.

#gelernt(
  [Fällt die Zentrale aus, puffert Alloy Metriken im WAL, Logs und Traces nur kurz im Speicher. Was darüber hinausgeht, ist verloren.],
  [Im Labor liegt der Puffer von Alloy im Container und überlebt keinen Neustart. Für den Betrieb gehört er auf ein Volume.],
  [Hochverfügbarkeit entsteht aus Replikation mit Quorum, persistenten Volumes, Anti-Affinity und einem Load Balancer, nicht aus der Zahl der Pods allein.],
  [Späte Daten haben Grenzen: Thanos und Loki weisen Proben ab, die mehr als rund eine Stunde zurückliegen. Tempo nimmt späte Spans an.],
  [Compactor und vergleichbare Dienste laufen genau einmal pro Bucket, auch bei zwei Standorten.],
  [Wer die Zentrale überwacht, muss außerhalb von ihr laufen. RPO und RTO legst du vorher fest und prüfst sie mit Ausfalltests.],
)

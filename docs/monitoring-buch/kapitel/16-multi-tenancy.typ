#import "../lib.typ": *

#kapitel(
  [Enterprise-Observability: Multi-Tenancy mit Thanos],
  ziel: [Du weißt, wie eine Plattform die Metriken vieler Kunden mit beliebig vielen Clustern sicher trennt: beim Schreiben, beim Lesen und in Grafana. Und du weißt, wie du diese Trennung prüfst.],
  zeit: [75 Minuten Lesen],
  braucht: [Kapitel 4 bis 7 und 13. Dieses Kapitel ändert nichts an deinem Labor.],
)

Im Labor ist jeder Cluster ein eigener Mandant: `obs`, `app1` und `app2`. Das passt, solange dir alle drei Cluster gehören. In einem Unternehmen, das Kubernetes für andere betreibt, sieht die Welt anders aus. Ein Kunde hat mehrere Cluster, etwa für Produktion und Entwicklung, und er darf seine eigenen Daten sehen, aber nie die eines anderen Kunden. Der Betreiber wiederum will seine eigene Infrastruktur überwachen, ohne dass Kunden darin herumstöbern.

Dieses Kapitel spielt das an einem *ausgedachten* Cloud-Anbieter durch. Alle Namen sind erfunden:

#tabelle(
  (auto, 1fr, 1fr),
  ([Mandant], [Cluster], [Wer ist das]),
  [`kunde-a`], [`production-eu`, `development-eu`], [ein Kunde mit zwei Clustern],
  [`kunde-b`], [`production-de`, `staging-de`], [ein zweiter Kunde],
  [`platform`], [`management`], [der Betreiber selbst],
)

#hinweis("Was getestet ist und was nicht", warn, warn-hell)[
  Dieses Kapitel unterscheidet drei Arten von Aussagen. *Im Labor getestet* steht ausdrücklich dabei, mit dem Ergebnis. *Laut Quellcode oder Doku von Thanos v0.42.5* heißt: geprüft gegen die eingesetzte Version, aber nicht im Labor ausprobiert. Alles andere ist ein *Architekturbeispiel*, das du vor dem Einsatz selbst prüfen musst. Kein YAML in diesem Kapitel ist eine fertige Produktionskonfiguration.
]

== Plattform-Monitoring und Kunden-Monitoring

Ein Betreiber hat zwei Arten von Metriken, und sie gehören in getrennte Welten:

#tabelle(
  (auto, 1fr, 1fr),
  ([], [Plattform-Monitoring], [Kunden-Monitoring]),
  [Fragt], [Läuft unsere Infrastruktur? Knoten, Netze, Speicher, Control Planes], [Läuft die Anwendung des Kunden? Seine Pods, Anfragen, Fehler],
  [Wer liest], [Betriebsteam des Anbieters], [der Kunde, eventuell sein Dienstleister],
  [Wer wird alarmiert], [Bereitschaft des Anbieters], [Bereitschaft des Kunden],
  [Mandant], [`platform`], [ein Mandant pro Kunde],
  [Dashboards], [Plattformsicht über alle Cluster], [nur die eigenen Cluster],
)

Die beiden Welten überschneiden sich: Der Anbieter muss auch in Kundenclustern Knoten und Kubelets überwachen, denn die gehören zu seiner Leistung. Diese Infrastruktur-Metriken schickt der Sammler im Kundencluster deshalb an den Mandanten `platform`, die Anwendungsmetriken an den Mandanten des Kunden. Ein Alloy kann das: zwei `prometheus.remote_write`-Komponenten mit unterschiedlichen Zugangsdaten, und jede Scrape-Komponente schickt an die passende.

#warum[
  Wer alles in einen Topf wirft, muss später jede einzelne Abfrage filtern, und ein vergessener Filter zeigt einem Kunden die Knoten aller anderen Kunden. Getrennte Mandanten machen die Grenze zur Voreinstellung, nicht zur Disziplin.
]

== Architektur und Datenfluss

#datei("Datenfluss mit Gateways", ```text
 SCHREIBEN
  Cluster production-eu ─┐                 ┌───────────────────────┐
  Cluster development-eu ┼─ Remote Write ─►│ Ingestion-Gateway      │
  Cluster production-de ─┤   mit eigener   │ prüft Identität,       │
  Cluster staging-de ────┤   Identität     │ setzt THANOS-TENANT    │
  Cluster management ────┘                 └──────────┬────────────┘
                                                      ▼
                                   Thanos Receive (Router ─► Ingestoren)
                                                      │ alle 2 h
                                                      ▼
                                              Objektspeicher (S3)
 LESEN                                                ▲
  Grafana ─► Query-Gateway ─► Thanos Query ──► Receive (frisch)
           prüft Nutzer,     erzwingt den   └─► Store Gateway (alt) ─┘
           setzt Mandant     Mandanten
```, erklaerung: [
  Beide Wege haben ein Gateway, das die Identität prüft und den Mandanten festlegt. Thanos selbst prüft keine Identität. Es glaubt dem Header, der bei ihm ankommt.
])

Ein Punkt verdient Betonung: *Ein gemeinsamer Eingang zum Schreiben heißt nicht, dass alle alles lesen dürfen.* Im Labor schreiben alle Cluster an `receive.obs.internal`, und Grafana liest mit einer Datenquelle alle Mandanten. Das ist für ein Labor in Ordnung. In einer Plattform für mehrere Kunden sind Schreiben und Lesen zwei getrennte Türen mit getrennten Schlössern.

== Thanos Receive: Mandant und Cluster sind zwei Dinge

Im Labor fallen zwei Begriffe zusammen, die du jetzt trennen musst:

- Die *Mandanten-ID* (`tenant_id`) sagt, *wem* die Daten gehören. Receive legt pro Mandant eine eigene TSDB an und hängt die ID als externes Label an jede Serie und an jeden Block in S3.
- Die *Cluster-ID* (`cluster`) sagt, *woher* die Daten kommen. Sie ist ein ganz normales Label, das der Sammler setzt.

Ein Mandant hat beliebig viele Cluster. Im Labor ist beides gleich, weil Kapitel 5 den Benutzernamen gleichzeitig als Clusternamen und als Mandanten verwendet. Für Kunden mit mehreren Clustern geht das nicht mehr.

=== Die Flags von Receive

Diese Flags hast du in Kapitel 4 schon gesetzt. Hier ihre genaue Bedeutung, geprüft im Quellcode von Thanos v0.42.5:

#tabelle(
  (auto, auto, 1fr),
  ([Flag], [Standard], [Bedeutung]),
  [`--receive.tenant-header`], [`THANOS-TENANT`], [Der HTTP-Header, aus dem Receive den Mandanten liest.],
  [`--receive.tenant-label-name`], [`tenant_id`], [Unter diesem Label erscheint der Mandant an jeder Serie, als externes Label der TSDB.],
  [`--receive.default-tenant-id`], [`default-tenant`], [Mandant für Anfragen ohne Header. Im Labor `unbekannt`, damit ein falsch eingerichteter Sender auffällt.],
  [`--receive.tenant-certificate-field`], [leer], [Liest den Mandanten statt aus dem Header aus dem Client-Zertifikat: `organization`, `organizationalUnit` oder `commonName`. Der Header wird dann ignoriert. Ohne Zertifikat oder ohne das Feld scheitert die Anfrage.],
  [`--receive.split-tenant-label-name`], [leer], [Ein Label in den Serien selbst bestimmt den Mandanten und wird danach entfernt. Hat Vorrang vor dem Header. Nur sinnvoll, wenn der Sender vertrauenswürdig ist.],
  [`--receive.replication-factor`], [`1`], [Wie oft jede Serie gespeichert wird. Quorum ist `RF/2+1`, bei drei Kopien also zwei (Kapitel 15).],
)

Der *Hashring* kann Mandanten einzelnen Gruppen von Ingestoren zuweisen. Im Feld `tenants` stehen Mandanten-IDs, mit `"tenant_matcher_type": "glob"` auch Muster wie `kunde-*`. So bekommt ein großer Kunde eigene Ingestoren, und sein Datenaufkommen trifft die anderen nicht.

#datei("Skizze: Hashring mit eigener Gruppe für einen großen Kunden (nicht getestet)", ```json
[
  { "hashring": "gross",  "tenants": ["kunde-a"],
    "endpoints": ["ingest-a-0:10901", "ingest-a-1:10901", "ingest-a-2:10901"] },
  { "hashring": "standard",
    "endpoints": ["ingest-0:10901", "ingest-1:10901", "ingest-2:10901"] }
]
```, erklaerung: [
  Der erste Eintrag nimmt nur `kunde-a`, der zweite ohne `tenants` alle übrigen. Die Reihenfolge zählt: Receive nimmt den ersten passenden Eintrag.
])

=== Zwei Cluster eines Kunden mit Alloy

In Kapitel 5 liest Alloy `CLUSTER_NAME`, `OBS_USER` und den Header aus demselben Benutzernamen. Für Kunden trennst du die Werte. Der Clustername steht in einer eigenen Variable, der Mandant ergibt sich aus der Anmeldung am Gateway, nicht aus der Konfiguration des Clusters.

#datei("Skizze: metrics.alloy für Kundencluster (Architekturbeispiel)", ```hcl
prometheus.remote_write "kunde" {
  external_labels = {
    // Woher: der Name dieses Clusters, z. B. production-eu
    cluster = sys.env("CLUSTER_NAME"),
  }
  endpoint {
    url = "https://ingest.plattform.example/api/v1/receive"
    // Wem: KEIN eigener THANOS-TENANT-Header. Den setzt das Gateway
    // aus der Identität. Ein Header hier wäre bestenfalls wirkungslos.
    basic_auth {
      username = sys.env("INGEST_USER")      // technische Identität des Clusters
      password = sys.env("INGEST_PASSWORD")
    }
    tls_config { ca_file = "/etc/plattform-ca/ca.crt" }
  }
}
```, erklaerung: [
  Für die beiden Cluster von `kunde-a` sieht die Datei identisch aus. Nur die Umgebungsvariablen unterscheiden sich: `CLUSTER_NAME=production-eu` und `development-eu`, dazu je eine eigene Identität. Beide Identitäten ordnet das Gateway dem Mandanten `kunde-a` zu. Wird ein Cluster stillgelegt, sperrst du nur seine Identität.
])

#tabelle(
  (auto, auto, auto, auto),
  ([Cluster], [`CLUSTER_NAME`], [Identität am Gateway], [Mandant, vom Gateway gesetzt]),
  [production-eu], [`production-eu`], [`ka-production-eu`], [`kunde-a`],
  [development-eu], [`development-eu`], [`ka-development-eu`], [`kunde-a`],
  [production-de], [`production-de`], [`kb-production-de`], [`kunde-b`],
  [staging-de], [`staging-de`], [`kb-staging-de`], [`kunde-b`],
  [management], [`management`], [`plattform-management`], [`platform`],
)

== Die Sicherheitsgrenze beim Schreiben

Thanos prüft keine Identität. Receive glaubt dem Header, der ankommt. Wer Receive erreicht, kann in jeden beliebigen Mandanten schreiben.

#hinweis("Im Labor getestet", probe, probe-hell)[
  Ein Prometheus-Agent gab sich als Cluster `staging-de` aus, der `kunde-b` gehört. Er schickte direkt an Receive, ohne Gateway, mit dem Header `THANOS-TENANT: kunde-a`. Ergebnis: Seine Serien erschienen bei einer Abfrage von `kunde-a` neben dessen eigenen Clustern:
  ```
  [["kunde-a","development-eu","1"],["kunde-a","production-eu","1"],["kunde-a","staging-de","1"]]
  ```
  Der fremde Cluster hat sich in die Daten von `kunde-a` eingeschleust. Das ist nicht nur ein Datenschutzproblem: Er kann damit auch Alarme von `kunde-a` auslösen oder verdecken.
]

Die Grenze muss deshalb ein *Ingestion-Gateway* ziehen, das drei Dinge zuverlässig tut:

+ *Authentifizieren.* Jede Anfrage trägt eine Identität, die das Gateway prüft.
+ *Den Mandanten ableiten.* Aus der Identität, nicht aus der Anfrage. Die Zuordnung „Identität gehört zu Mandant“ steht beim Gateway, nicht beim Sender.
+ *Eingehende Mandanten-Header entfernen oder überschreiben.* Ein mitgeschickter `THANOS-TENANT` darf nie durchkommen.

#tabelle(
  (auto, 1fr, 1fr),
  ([Verfahren], [Wie die Identität entsteht], [Worauf du achtest]),
  [mTLS], [Jeder Cluster hat ein Client-Zertifikat. Receive kann den Mandanten mit `--receive.tenant-certificate-field=organization` direkt aus dem Feld `O` lesen.], [Eine eigene CA nur für Clients, kurze Laufzeiten, automatische Erneuerung, Sperrliste. Wer Zertifikate ausstellt, legt Mandanten fest.],
  [OIDC], [Der Sammler holt sich ein Token von einem Identity Provider, das Gateway prüft es und liest den Mandanten aus einem Claim.], [Gateway muss Signatur, Ablauf und Zielgruppe prüfen. Alloy unterstützt dafür `oauth2`.],
  [Basic Auth mit Zuordnung], [Benutzer und Passwort pro Cluster, das Gateway setzt den Mandanten aus dem Benutzer.], [Einfach, aber Passwörter lassen sich kopieren. Rotation und eine Zuordnung Benutzer zu Mandant sind Pflicht.],
)

#falle[
  *Drei typische Lücken.* Erstens: Das Gateway prüft die Anmeldung, reicht aber den Header des Clients unverändert durch. Dann schützt die Anmeldung nur vor Fremden, nicht vor Kunden untereinander. Genau so ist das Labor gebaut, Kapitel 5 weist darauf hin. Zweitens: Receive ist auch direkt erreichbar, an Traefik vorbei, etwa über einen `NodePort` oder aus einem anderen Namespace. Eine NetworkPolicy, die Port 19291 nur vom Gateway aus erlaubt, schließt diesen Weg. Drittens: Der Benutzername ist gleich dem Mandanten, und jemand legt versehentlich einen Benutzer `kunde-a` für einen Cluster von `kunde-b` an. Die Zuordnung braucht deshalb dieselbe Sorgfalt wie ein Passwort.
]

=== Ein Gateway mit Traefik

Für Basic Auth kann Traefik das Gateway selbst sein. Die Option `headerField` der Basic-Auth-Middleware schreibt den angemeldeten Benutzernamen in einen Header. Laut Quellcode von Traefik v3.7.1, der Version in k3s `v1.36.6`, löscht die Middleware dabei zuerst jeden gleichnamigen Header des Clients und setzt dann den Benutzernamen, und zwar nur nach erfolgreicher Anmeldung. Der Benutzername ist damit der Mandant.

#datei("Middleware für ein Mandanten-Gateway (im Labor getestet)", ```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: {name: gw-tenant, namespace: tenancy-test}
spec:
  basicAuth:
    secret: gw-users            # htpasswd: Benutzer = Mandant, z. B. kunde-a
    removeHeader: true          # Passwort nicht an Thanos weiterreichen
    headerField: THANOS-TENANT  # Mandant aus der Anmeldung, überschreibt den Client
```, erklaerung: [
  Dieselbe Middleware sitzt vor dem Schreibpfad von Receive und vor dem Lesepfad von Query. Beim Schreiben braucht so jeder *Cluster* einen Benutzer, der wie sein Mandant heißt. Für mehrere Cluster pro Kunde teilen sich die Cluster eines Kunden diesen Benutzer, oder du nutzt mTLS mit `--receive.tenant-certificate-field`, wo jedes Zertifikat eigen ist, aber denselben Mandanten im Feld `O` trägt.
])

#hinweis("Im Labor getestet", probe, probe-hell)[
  Ein Prometheus-Agent meldete sich am Gateway als `kunde-b` an und versuchte zweierlei: Er schickte den Header `THANOS-TENANT: kunde-a` und trug zusätzlich das Label `tenant_id="kunde-a"` an allen Serien. Ergebnis der Abfragen danach:
  ```
  als kunde-b:  [["kunde-b","production-de"],["kunde-b","staging-de-gw"]]
  als kunde-a:  [["kunde-a","development-eu"],["kunde-a","production-eu"],["kunde-a","staging-de"]]
  ```
  Die Daten landeten bei `kunde-b`. Traefik hat den Header ersetzt, und Receive hat das mitgeschickte Label durch sein eigenes `tenant_id` überschrieben. Der Cluster `staging-de` bei `kunde-a` stammt übrigens noch aus dem Versuch *ohne* Gateway: Wer an Traefik vorbei direkt an Receive schreibt, kommt weiterhin durch.
]

Die letzte Zeile zeigt, warum zum Gateway immer eine NetworkPolicy gehört, die Receive nur für das Gateway erreichbar macht.


== Die Sicherheitsgrenze beim Lesen

Auch Thanos Query glaubt dem Header. Seit einigen Versionen kann Query die Mandanten aber *erzwingen*. Die Flags in v0.42.5, geprüft im Quellcode:

#tabelle(
  (auto, auto, 1fr),
  ([Flag], [Standard], [Bedeutung]),
  [`--query.enforce-tenancy`], [aus], [Schaltet die Erzwingung ein. Antworten enthalten nur Serien, deren `tenant_id` zum Mandanten im Header passt.],
  [`--query.tenant-header`], [`THANOS-TENANT`], [Header, aus dem Query den Mandanten liest.],
  [`--query.tenant-label-name`], [`tenant_id`], [Label, auf das Query einschränkt.],
  [`--query.default-tenant-id`], [`default-tenant`], [Mandant, wenn der Header fehlt.],
  [`--query.tenant-certificate-field`], [leer], [Mandant aus dem Client-Zertifikat statt aus dem Header.],
)

*Wie es funktioniert:* Query nutzt dieselbe Logik wie das Werkzeug `prom-label-proxy`. Es fügt in *jeden* Selektor einer PromQL-Abfrage den Matcher `tenant_id="<mandant>"` ein. Steht dort schon ein `tenant_id`-Matcher, ersetzt Query ihn stillschweigend.

#hinweis("Im Labor getestet", probe, probe-hell)[
  Eine zweite Thanos Query mit `--query.enforce-tenancy` vor einem Test-Receive mit drei fiktiven Clustern. Jede Abfrage mit dem Header `THANOS-TENANT: kunde-a`:
  #tabelle(
    (1fr, auto),
    ([Abfrage], [Ergebnis]),
    [`count by (tenant_id, cluster) (up)`], [nur `kunde-a`],
    [`... (up{tenant_id="kunde-b"})`], [nur `kunde-a`, der Selektor wurde ersetzt],
    [`... (up{tenant_id=~".*"})`], [nur `kunde-a`],
    [`... (up) or ... (up{tenant_id="kunde-b"})`], [nur `kunde-a`],
    [`/api/v1/series`, `/api/v1/label/tenant_id/values`], [nur `kunde-a`],
    [ohne Header], [leer, Standard-Mandant],
    [Header `kunde-b`], [*alles von `kunde-b`*],
  )
  Die letzte Zeile ist die Lehre: Die Erzwingung ist nur so gut wie die Herkunft des Headers.
]

*Was die Erzwingung nicht abdeckt.* Laut Quellcode von v0.42.5 gilt sie für `query`, `query_range`, die `explain`-Varianten, `series`, `labels`, `label/<name>/values` und `status/tsdb`. Sie gilt *nicht* für `/api/v1/rules`, `/api/v1/alerts`, `/api/v1/targets`, `/api/v1/metadata`, `/api/v1/query_exemplars` und `/api/v1/stores`, und nicht für die gRPC-Schnittstelle von Query. Store Gateway und Receive erzwingen selbst nichts. Ein Gateway vor Query sollte deshalb nur die geschützten Pfade durchlassen, und Store Gateway und Receive dürfen von außen gar nicht erreichbar sein.

#falle[
  *Geschachtelte Querier.* Steht eine Query vor einer anderen, erzwingt laut Thanos-Doku nur die erste, die die Anfrage bekommt. Auch die Oberfläche von Query enthält ein freies Feld für den Mandanten. Sie gehört deshalb nicht in die Hände von Kunden. Die Doku formuliert es so: „there are no authentication mechanisms in Thanos, so anyone can set an arbitrary tenant in the HTTP header.“
]

=== Das Query-Gateway

Vor die Query mit Erzwingung setzt du dieselbe Middleware. Der Ingress lässt nur den Pfad `/api/v1` durch, nicht die Oberfläche von Query.

#hinweis("Im Labor getestet", probe, probe-hell)[
  Abfragen über das Gateway, angemeldet als `kunde-a`:
  #tabelle(
    (1fr, auto),
    ([Versuch], [Ergebnis]),
    [ohne zusätzlichen Header], [nur `kunde-a`],
    [mit `THANOS-TENANT: kunde-b`], [nur `kunde-a`, Header ersetzt],
    [mit `thanos-tenant: kunde-b` (klein)], [nur `kunde-a`],
    [ohne Anmeldung, falsches Passwort], [`401`],
    [Oberfläche `/graph`], [`404`, nicht freigegeben],
    [`/api/v1/rules`], [*Antwort ohne Mandantenfilter*],
  )
  Die letzte Zeile ist die bekannte Lücke: Alles unter `/api/v1/`, was Query nicht erzwingt, reicht ein Gateway mit Pfad-Präfix ungefiltert durch. Ein Gateway für Kunden lässt deshalb nur die erzwungenen Pfade zu, also `query`, `query_range`, `series`, `labels` und `label/*/values`.
]

#falle[
  *Warnungen verraten andere Mandanten.* Im Labor wurde der Receiver gestoppt und `kunde-a` fragte über das Gateway ab. Query antwortete mit `success` und leerem Ergebnis, aber mit einer Warnung, die alle Mandanten des ausgefallenen Receivers aufzählte: `tenant_id="kunde-a"`, `tenant_id="kunde-b"`, `tenant_id="unbekannt"`. Grafana zeigt solche Warnungen an. Die Namen anderer Kunden sind kein Datenleck im engeren Sinn, aber eine Information, die ein Kunde nicht bekommen sollte. Ein Gateway kann das Feld `warnings` aus Antworten entfernen, oder die Mandanten heißen nicht nach Kunden, sondern nach neutralen Kennungen.
]



== Grafana für viele Kunden

In Kapitel 6 hast du eine Grafana-Instanz mit Datenquellen aus ConfigMaps gebaut, und die Loki-Datenquelle aus Kapitel 8 liest mit `obs|app1|app2` alle Mandanten. Für Kunden gibt es drei Modelle:

#tabelle(
  (auto, 1fr, 1fr, 1fr),
  ([], [Eine Instanz, gemeinsam], [Eine Instanz, eine Organisation pro Kunde], [Eine Instanz pro Kunde]),
  [Trennung], [nur über Ordnerrechte], [Organisationen sehen einander nicht: eigene Datenquellen, Dashboards, Nutzer, Alarme], [vollständig, eigener Prozess],
  [Datenquellen], [gemeinsam], [pro Organisation, jede mit ihrem Mandanten], [pro Instanz],
  [Admin-Rechte], [ein Admin sieht alles], [Org-Admin sieht nur seine Organisation, der Server-Admin alles], [Kunde kann Admin seiner Instanz sein],
  [Betrieb], [einfach], [mittel, Provisioning pro Organisation], [aufwendig, viele Instanzen],
  [Geeignet für], [ein Team, keine Kunden], [viele Kunden mit Standardbedarf], [Kunden mit eigenen Plugins oder Compliance-Vorgaben],
)

#falle[
  *Eine zentrale Thanos-Datenquelle für alle ist ein Datenleck.* Wer eine Datenquelle in Grafana benutzen darf, kann über *Explore* jede Abfrage stellen, die diese Datenquelle erlaubt, unabhängig davon, welche Dashboards er sehen darf. Liest die Datenquelle alle Mandanten, liest der Nutzer alle Mandanten. Ein Filter `cluster=~"$cluster"` im Dashboard hilft nicht, denn der Nutzer schreibt in Explore einfach eine Abfrage ohne Filter. Mandantentrennung entsteht nur dort, wo der Nutzer sie nicht umgehen kann: im Gateway vor Thanos Query.
]

Für das Modell mit Organisationen sieht die Zuordnung so aus: Jede Organisation bekommt eine eigene Thanos-Datenquelle, die auf das Query-Gateway zeigt und sich dort mit einer eigenen technischen Identität anmeldet. Das Gateway kennt die Identität und setzt den Mandanten. Selbst wenn ein Org-Admin die Datenquelle bearbeitet und einen anderen Header einträgt, ändert das nichts, denn das Gateway überschreibt ihn.

*Alarme für Kunden.* Laufen die Alarmregeln eines Kunden im Thanos Ruler oder in Grafana Alerting, müssen sie ebenfalls auf seinen Mandanten beschränkt sein, und ihre Benachrichtigungen dürfen nur an seine Kontakte gehen. Am einfachsten ist ein eigener Alertmanager-Empfänger pro Mandant mit einer Route auf das Label `tenant_id`. Plattform-Alarme laufen getrennt davon an die Bereitschaft des Betreibers, wie in Kapitel 7.

== Speicherung, Hochverfügbarkeit und die Grenzen einer gemeinsamen Plattform

Die Bausteine für eine ausfallsichere Speicherung beschreibt Kapitel 15: Receive mit Routern und Ingestoren, Hashring und `replication-factor=3`, WAL auf persistenten Volumes, hochverfügbarer Objektspeicher, Store Gateway mit mehreren Replikas und ein einziger Compactor pro Bucket. Für viele Mandanten kommen Fragen dazu, die mit Ausfallsicherheit nichts zu tun haben, sondern mit Fairness.

#tabelle(
  (auto, 1fr, 1fr),
  ([Risiko], [Was passiert], [Gegenmittel]),
  [Noisy Neighbor], [Ein Kunde schickt plötzlich zehnmal so viele Daten, Receive wird langsam für alle], [Limits pro Mandant in Receive (`--receive.limits-config-file`, Kapitel 13)],
  [Kardinalität], [Ein Label mit Nutzer-IDs erzeugt Millionen Serien, der Speicher der Ingestoren läuft voll], [Limit für Serien pro Anfrage, Beobachtung von `prometheus_tsdb_head_series` je Mandant],
  [Teure Abfragen], [Eine Abfrage über ein Jahr ohne Filter belastet Store Gateway und Query für alle], [Query-Frontend mit Aufteilung und Cache, Zeitlimits für Abfragen, eigene Query-Instanzen für große Kunden],
  [Retention], [Kunden wollen unterschiedlich lange Aufbewahrung], [Ein Compactor bearbeitet einen Bucket mit einer Retention. Unterschiedliche Retention heißt getrennte Buckets oder ein Compactor pro Bucket],
  [Datenverlust], [Ein Ausfall trifft alle Kunden gleichzeitig], [Replikation, Puffer in den Sammlern, Ausfalltests, siehe Kapitel 15],
)

#falle[
  *Ein Bucket, ein Compactor.* Auch bei vielen Mandanten in einem Bucket darf nur ein Compactor laufen. Wer pro Kunde einen eigenen Compactor will, etwa für eine eigene Retention, braucht auch einen eigenen Bucket oder muss die Compactors über `--selector.relabel-config` streng auf getrennte Blöcke aufteilen. Überlappen sich zwei, beschädigen sie die Daten.
]

== Drei Architekturen im Vergleich

#tabelle(
  (auto, 1fr, 1fr, 1fr),
  ([], [A: eine gemeinsame Plattform], [B: Thanos pro Kunde], [C: hybrid]),
  [Aufbau], [Ein Receive, ein Query, ein Bucket für alle Mandanten], [Eigener Receive, Query, Bucket für jeden Kunden], [Gemeinsame Plattform für die meisten, eigene Instanzen für Kunden mit besonderen Anforderungen],
  [Isolation], [logisch: Header, Labels, Gateways], [physisch: eigene Prozesse, eigener Speicher], [je nach Kunde],
  [Sicherheit], [hängt an korrekter Konfiguration der Gateways], [ein Fehler betrifft nur einen Kunden], [gemischt],
  [Skalierung], [ein großes System, gut ausgelastet], [viele kleine Systeme, viel Leerlauf], [gut],
  [Kosten], [niedrig pro Kunde], [hoch pro Kunde], [mittel],
  [Compliance], [schwer nachzuweisen, dass Daten nie gemischt werden], [einfach: eigener Bucket, eigener Schlüssel, eigene Region], [nach Bedarf],
  [Betrieb und Updates], [ein Update für alle, hohes Risiko pro Update], [viele Updates, gut automatisierbar], [zwei Betriebsmodelle],
)

*Die Empfehlung:* Beginne mit *C*, wobei der gemeinsame Teil nach *A* gebaut ist. Die meisten Kunden teilen sich eine Plattform mit erzwungenen Mandanten beim Schreiben und Lesen und mit Limits pro Mandant. Kunden mit gesetzlichen Vorgaben, eigener Region oder sehr großen Datenmengen bekommen eine eigene Instanz aus derselben Vorlage. Weil beides aus demselben Git-Repo und denselben Helm-Werten entsteht, kostet die zweite Variante kaum zusätzliche Arbeit.

Die Grenze dieser Empfehlung: Die logische Trennung in A hängt davon ab, dass jedes Gateway richtig konfiguriert ist und niemand an ihm vorbei auf Receive oder Query zugreift. Diese Annahme musst du laufend prüfen, nicht einmalig. Die Testfälle am Ende dieses Kapitels gehören deshalb in eine automatische Prüfung.

== GitOps mit Argo CD

Bei vielen Kunden und Clustern geht nichts mehr von Hand. Kapitel 13 hat GitOps als Ausblick erwähnt. Für eine Plattform mit Mandanten ist es Pflicht: Git ist die einzige Quelle der Wahrheit, und Argo CD bringt den Zustand aus Git in die Cluster.

#datei("Skizze: Aufbau eines Plattform-Repos (Architekturbeispiel)", ```text
plattform-repo/
├── basis/                 Helm-Werte für Alloy, gleich für alle Cluster
├── zentrale/              Receive, Query, Gateways, Store, Compactor
├── mandanten/
│   ├── kunde-a.yaml       tenant: kunde-a, limits, retention, kontakte
│   └── kunde-b.yaml
└── cluster/
    ├── production-eu.yaml tenant: kunde-a, cluster: production-eu
    ├── development-eu.yaml
    ├── production-de.yaml tenant: kunde-b
    ├── staging-de.yaml
    └── management.yaml    tenant: platform
```, erklaerung: [
  Eine Datei pro Cluster nennt Mandant und Clusternamen. Ein `ApplicationSet` in Argo CD liest das Verzeichnis `cluster/` mit dem Git-Generator und erzeugt für jede Datei eine Application, die Alloy mit genau diesen zwei Werten installiert. Ein neuer Cluster ist damit eine neue Datei.
])

Geheimnisse gehören nicht ins Repo. Die Zugangsdaten jedes Clusters für das Ingestion-Gateway liegen in einem Tresor, etwa Vault oder dem Secret Manager eines Cloud-Anbieters. Der *External Secrets Operator* holt sie von dort und legt sie als Kubernetes-Secret an. Im Repo steht nur der Verweis, nie der Wert.

*Ein Onboarding-Ablauf, Schritt für Schritt:*

+ Der neue Cluster `staging-de` ist erstellt und in Argo CD registriert.
+ Im Tresor entsteht eine technische Identität für ihn, etwa ein Client-Zertifikat oder ein OIDC-Client, und das Gateway lernt, dass diese Identität zu `kunde-b` gehört.
+ Ein Merge Request legt `cluster/staging-de.yaml` mit `tenant: kunde-b` an. Ein zweiter Blick prüft vor allem diese eine Zeile.
+ Argo CD installiert Alloy im neuen Cluster. External Secrets legt die Zugangsdaten an.
+ Die automatischen Testfälle aus dem nächsten Abschnitt laufen für `kunde-b` erneut: Der neue Cluster erscheint bei `kunde-b`, nirgends sonst.

== Verifikation: Die Trennung beweisen

Eine Mandantentrennung, die nicht getestet ist, ist eine Behauptung. Die folgenden Testfälle gehören in eine automatische Prüfung, die nach jeder Änderung an Gateway, Receive oder Query und nach jedem Onboarding läuft. Die Spalte rechts zeigt das Ergebnis aus dem Labor mit Thanos v0.42.5 und Traefik v3.7.1.

#tabelle(
  (auto, 1fr, 1fr, auto),
  ([Nr.], [Test], [Erwartung], [Labor]),
  [1], [`kunde-a` fragt `count by (cluster) (up)` über das Gateway], [nur `production-eu` und `development-eu`], [bestanden],
  [2], [`kunde-a` fragt mit `{tenant_id="kunde-b"}`, `=~".*"` oder per `or`], [nur Daten von `kunde-a`], [bestanden],
  [3], [`kunde-a` schickt beim Lesen `THANOS-TENANT: kunde-b`], [Header wird ersetzt], [bestanden],
  [4], [Cluster von `kunde-b` schickt beim Schreiben Header und Label `kunde-a`], [Daten landen bei `kunde-b`], [bestanden],
  [5], [Schreiben direkt an Receive, am Gateway vorbei], [Verbindung abgelehnt (NetworkPolicy)], [*nicht bestanden* ohne NetworkPolicy, siehe oben],
  [6], [Lesen direkt an Query, am Gateway vorbei, mit fremdem Header], [Verbindung abgelehnt], [*nicht bestanden* ohne NetworkPolicy: fremde Daten sichtbar],
  [7], [Abfrage ohne Anmeldung], [`401`], [bestanden],
  [8], [Abfrage ohne Mandanten-Header direkt an Query], [nur Standard-Mandant, also leer], [bestanden],
  [9], [`/api/v1/rules`, `/alerts`, `/metadata`, `/query_exemplars` über das Gateway], [gesperrt], [*nicht gesperrt* bei Pfad-Präfix `/api/v1`],
  [10], [Grafana: Nutzer von `kunde-a` schreibt in Explore eine Abfrage ohne Filter], [nur Daten von `kunde-a`], [Architekturbeispiel, nicht getestet],
  [11], [Limit `series_limit: 50` für `kunde-b`], [`413` nur für `kunde-b`, `kunde-a` unbeeinträchtigt], [bestanden],
  [12], [Receiver fällt aus, `kunde-a` fragt ab], [leeres Ergebnis mit Warnung, keine fremden Daten], [bestanden, aber Warnung nennt fremde Mandanten],
)

Die Tests 5, 6 und 9 zeigen, wo das Labor-Setup für Kunden nicht reicht. Sie sind kein Fehler von Thanos, sondern die Stellen, an denen Netzwerk und Gateway die Arbeit übernehmen müssen.

#datei("Skizze: NetworkPolicy, die Receive nur für Traefik öffnet (nicht getestet)", ```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: receive-nur-gateway, namespace: monitoring}
spec:
  podSelector:
    matchLabels: {app.kubernetes.io/name: thanos-receive}
  policyTypes: [Ingress]
  ingress:
    - from:   # Schreibpfad nur vom Gateway
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
          podSelector: {matchLabels: {app.kubernetes.io/name: traefik}}
      ports: [{port: 19291}]
    - from:   # Store API nur für Thanos Query
        - podSelector: {matchLabels: {app.kubernetes.io/name: thanos-query}}
      ports: [{port: 10901}]
```, erklaerung: [
  Achtung bei k3s: Das mitgelieferte Flannel setzt NetworkPolicies nicht selbst durch, das übernimmt der in k3s eingebaute Policy-Controller. Prüfe mit einem Test-Pod, ob die Policy wirklich greift, bevor du dich darauf verlässt. Prometheus auf obs schreibt im Labor direkt an Receive, er bräuchte eine weitere Regel.
])

#aufgabe[
  Baue den Teststand selbst nach, in einem eigenen Namespace, damit dein Labor unberührt bleibt: ein Receive ohne S3, eine Query mit `--query.enforce-tenancy` und drei Prometheus-Agenten im Modus `--agent` als fiktive Cluster. Führe die Tests 1 bis 4 aus. Ergänze dann die NetworkPolicy und wiederhole Test 5. Was meldet der Agent, der direkt an Receive schreiben will, und woran erkennst du in Receive, dass nichts angekommen ist?
]

#gelernt(
  [Mandant und Cluster sind zwei Dinge: Ein Kunde ist ein Mandant mit beliebig vielen Clustern.],
  [Thanos glaubt dem Header. Ein Gateway muss die Identität prüfen und den Mandanten setzen, beim Schreiben wie beim Lesen.],
  [`--query.enforce-tenancy` ersetzt jeden `tenant_id`-Selektor, schützt aber nur die Abfrage-Endpunkte, nicht Regeln, Alarme, Metadaten oder die gRPC-Schnittstelle.],
  [Traefik `headerField` überschreibt einen mitgeschickten Header zuverlässig. Wer am Gateway vorbeikommt, umgeht alles. Dagegen hilft nur das Netzwerk.],
  [In Grafana entscheidet die Datenquelle über die Sichtbarkeit, nicht das Dashboard.],
  [Eine gemeinsame Plattform braucht Limits pro Mandant und automatische Tests der Trennung.],
)

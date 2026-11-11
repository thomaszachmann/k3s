#import "lib.typ": *

#cover(
  [Kubernetes\ beobachten],
  [Monitoring, Logging, Alerting und Tracing für mehrere k3s-Cluster, Befehl für Befehl aufgebaut],
  [Thomas Zachmann],
  [Stand: 11. November 2026],
)

#show: buch

#set page(numbering: "1")
#counter(page).update(1)

#include "kapitel/00-vorwort.typ"
#include "kapitel/01-architektur.typ"
#include "kapitel/02-fundament.typ"
#include "kapitel/03-s3-cluster.typ"
#include "kapitel/04-metriken-zentral.typ"
#include "kapitel/05-metriken-cluster.typ"
#include "kapitel/06-grafana.typ"
#include "kapitel/07-alerting.typ"
#include "kapitel/08-logs.typ"
#include "kapitel/09-traces.typ"
#include "kapitel/10-dashboards.typ"
#include "kapitel/11-aws-s3.typ"
#include "kapitel/12-backup.typ"
#include "kapitel/13-ergaenzungen.typ"
#include "kapitel/14-betrieb.typ"
#include "kapitel/15-enterprise.typ"
#include "kapitel/16-multi-tenancy.typ"
#include "kapitel/17-anhang.typ"

#rueckseite(
  [Kubernetes beobachten],
  [
    Drei Ubuntu-VMs, ein Laptop und eine Frage: Was passiert gerade in meinen Clustern, und was ist vor drei Wochen passiert?

    Dieses Buch baut mit dir eine zentrale Observability-Plattform für mehrere k3s-Cluster auf. Metriken, Logs und Traces landen an einer Stelle, alte Daten liegen günstig in S3, und Alarme erreichen dich, bevor die Nutzer es merken. Jeder Befehl einzeln, mit einer Erklärung, warum er nötig ist und woran du erkennst, dass er gewirkt hat.
  ],
  (
    ([Metriken], [Prometheus und Thanos Receive für alle Cluster]),
    ([Logs], [Loki und Alloy mit einem Mandanten pro Cluster]),
    ([Traces], [Tempo und OpenTelemetry an einer Demo-App]),
    ([Alarme], [Alertmanager, Thanos Ruler und ein Dead Man's Switch]),
    ([Speicher], [S3 im Cluster mit SeaweedFS und auf AWS]),
    ([Sicherheit], [Backup und Restore mit etcd-Snapshots und Velero]),
    ([Praxis], [Fertige Dashboards, direkt aus dem Repo]),
  ),
  [Hands-on-Handbuch · Stand: 11. November 2026],
  autor: [Thomas Zachmann],
  autor-bild: "bilder/autor.jpg",
  autor-text: [Autor auf Leanpub],
)

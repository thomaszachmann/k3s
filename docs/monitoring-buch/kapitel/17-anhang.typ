#import "../lib.typ": *

#kapitel(
  [Anhang],
  ziel: [Versionen, Repo-Überblick, Spickzettel und Links zum schnellen Nachschlagen.],
)

== Versionen

Alle Angaben gelten für den Stand dieses Buches, 11. November 2026. Mit genau diesen Versionen lief der Test auf echten Clustern. Die Chart-Versionen stammen aus den offiziellen Helm-Repositories, die App-Versionen aus den Charts selbst.

#tabelle(
  (1fr, auto, auto),
  ([Komponente], [Chart], [App bzw. Image]),
  [k3s], [–], [`v1.36.6+k3s1`],
  [kube-prometheus-stack (`prometheus-community`)], [`92.18.0`], [Operator `v0.94.2`],
  [#h(1em) davon Prometheus, Alertmanager, Grafana], [–], [`v3.15.1`, `v0.34.2`, `13.3.0`],
  [Thanos], [– (Manifeste)], [`quay.io/thanos/thanos:v0.42.5`],
  [SeaweedFS], [– (Manifest)], [`chrislusf/seaweedfs:4.52`],
  [Loki (`grafana-community`)], [`21.0.0`], [`3.7.9`],
  [Tempo (`grafana-community`)], [`3.2.1`], [`3.1.1`],
  [Alloy (`grafana`)], [`1.15.0`], [`v1.21.3`],
  [kube-state-metrics (`prometheus-community`)], [`9.0.0`], [`v2.20.0`],
  [node-exporter (`prometheus-community`)], [`5.0.0`], [`v1.12.1`],
  [Velero (`vmware-tanzu`)], [`12.2.4`], [`1.18.2`],
  [#h(1em) Velero-Plugin für AWS], [–], [`velero/velero-plugin-for-aws:v1.14.4`],
  [Blackbox-Exporter (`prometheus-community`)], [`11.21.1`], [`v0.29.1`],
  [Pyroscope (`grafana`, optional)], [`2.4.3`], [`2.4.3`],
  [Mailpit], [– (Manifest)], [`axllent/mailpit:v1.33.1`],
  [HotROD (Demo-App)], [– (Manifest)], [`jaegertracing/example-hotrod:2.22.0`],
)

== Dein Repo am Ende

So sieht `observability/` aus, wenn du alle Kapitel durchgearbeitet hast. Dateien mit Geheimnissen fehlen absichtlich: Die privaten Schlüssel unter `tls/` schließt `.gitignore` aus, alle Passwörter liegen nur in Secrets.

```
observability/
├── k3s/            config-obs.yaml, config-app1.yaml, config-app2.yaml,
│                   coredns-custom.yaml                           (Kap. 2, 12)
├── tls/            openssl.cnf, ca.crt, obs.internal.crt         (Kap. 2)
├── seaweedfs/      seaweedfs.yaml, create-secrets.sh,
│                   create-buckets.sh                             (Kap. 3)
├── central/
│   ├── kps/        values.yaml (4), grafana.yaml (6), alerting.yaml (7)
│   ├── thanos/     receive.yaml, query.yaml, store.yaml, compact.yaml,
│   │               servicemonitor.yaml                           (Kap. 4)
│   ├── ingress/    middleware.yaml, receive.yaml, loki.yaml,
│   │               tempo.yaml                                    (Kap. 5, 8, 9)
│   ├── mailpit/    mailpit.yaml                                  (Kap. 7)
│   ├── loki/       values.yaml                                   (Kap. 8)
│   └── tempo/      values.yaml                                   (Kap. 9)
├── cluster/
│   ├── alloy/      values.yaml, metrics.alloy (5), logs.alloy (8),
│   │               traces.alloy (9)
│   └── exporters/  kube-state-metrics.yaml, node-exporter.yaml   (Kap. 5)
├── grafana/
│   └── datasources/ thanos.yaml, alertmanager.yaml, loki.yaml,
│                    tempo.yaml                                   (Kap. 6, 8, 9)
├── rules/          cluster.yaml, knoten.yaml, workloads.yaml,
│   │               thanos.yaml, runbooks.md                      (Kap. 7)
│   └── loki/       kustomization.yaml, log-alarme.yaml           (Kap. 8)
├── demo/           hotrod.yaml, last.yaml                        (Kap. 9)
├── dashboards/     kustomization.yaml                            (Kap. 10)
│   ├── plattform/  multi-cluster, node, workloads, alarme,
│   │               thanos-speicher (.json)
│   └── signale/    logs.json, services.json
├── aws/            iam-policy-{thanos,loki,tempo,backup}.json,
│                   lifecycle-{thanos,loki,tempo,backup}.json,
│                   bucket-policy-tls.json, encryption.json,
│                   thanos-objstore-aws.yml, loki-aws.yaml,
│                   tempo-aws.yaml                                (Kap. 11)
├── backup/         s3-ingress.yaml, k3s-etcd-s3.yaml,
│                   velero-values.yaml, velero-aws.yaml,
│                   backup.alloy, velero-rules.yaml               (Kap. 12)
└── extras/         blackbox-values.yaml, probes.yaml,
                    blackbox-rules.yaml, receive-limits.yaml,
                    slo-rules.yaml,
                    pyroscope-values.yaml,
                    pyroscope-datasource.yaml                     (Kap. 13)
```

== Spickzettel PromQL

#tabelle(
  (1fr, 1.3fr),
  ([Frage], [Abfrage]),
  [Welche Ziele sind unten?], [`up == 0`],
  [Welche Cluster liefern Daten?], [`count by (cluster) (up)`],
  [Anfragen pro Sekunde], [`sum by (cluster) (rate(http_requests_total[5m]))`],
  [Fehlerquote], [`sum(rate(x_total{code=~"5.."}[5m])) / sum(rate(x_total[5m]))`],
  [95. Perzentil aus Histogramm], [`histogram_quantile(0.95, sum by (le) (rate(x_bucket[5m])))`],
  [Speicher pro Pod], [`sum by (pod) (container_memory_working_set_bytes{container!=""})`],
  [Neustarts der letzten Stunde], [`increase(kube_pod_container_status_restarts_total[1h]) > 0`],
  [Freier Platz in Prozent], [`100 * node_filesystem_avail_bytes / node_filesystem_size_bytes`],
  [Größte Metriken], [`topk(10, count by (__name__)({__name__=~".+"}))`],
  [Serien pro Mandant], [`sum by (tenant) (prometheus_tsdb_head_series{job="thanos-receive"})`],
  [Verstummter Cluster], [`group by (cluster) (up offset 1h) unless group by (cluster) (up)`],
)

Merksätze: `rate` nur auf Zähler (`_total`), nie auf Gauges. Erst `rate`, dann `sum`. `by (...)` sagt, welche Labels übrig bleiben.

== Spickzettel LogQL

Dieselben vier Schritte wie in Kapitel 8: Streams wählen, Zeilen filtern, zerlegen, zählen.

#tabelle(
  (1fr, 1.3fr),
  ([Frage], [Abfrage]),
  [Alle Logs eines Namespaces], [`{cluster="app1", namespace="demo"}`],
  [Text suchen], [`{cluster="app1"} |= "timeout"`],
  [Regulärer Ausdruck, ohne Debug], [`{cluster="app1"} |~ "(?i)error" != "level=debug"`],
  [logfmt zerlegen und filtern], [`{app="alloy"} | logfmt | level="error"`],
  [JSON zerlegen], [`{namespace="demo"} | json | status >= 500`],
  [Strukturierte Metadaten], [`{cluster=~"app1|app2"} | level="error"`],
  [Fehler pro Namespace als Zeitreihe], [`sum by (namespace) (count_over_time({cluster="app1"} |~ "(?i)error" [5m]))`],
  [Nur ein Feld anzeigen], [`... | logfmt | line_format "{{.msg}}"`],
)

Merksatz: erst über Labels einschränken, dann über Text. Loki liest sonst alles im Zeitraum.

== Spickzettel TraceQL

Attribute tragen ihren Bereich als Präfix: `resource.` für den Dienst, `span.` für den einzelnen Span. Dazu kommen eingebaute Felder wie `name`, `duration` und `status`.

#tabelle(
  (1fr, 1.3fr),
  ([Frage], [Abfrage]),
  [Spans eines Dienstes], [`{ resource.service.name = "frontend" }`],
  [Langsame Spans], [`{ resource.service.name = "customer" && duration > 250ms }`],
  [Alle Fehler], [`{ status = error }`],
  [Fehler unterhalb eines Dienstes], [`{ resource.service.name = "frontend" } >> { status = error }`],
  [Bestimmter HTTP-Status], [`{ span.http.response.status_code >= 500 }`],
  [Traces mit vielen Spans], [`{ resource.k8s.namespace.name = "demo" } | count() > 20`],
  [Ein Cluster], [`{ resource.cluster = "app1" }`],
)

Das Attribut `resource.cluster` setzt `traces.alloy` aus Kapitel 9. Welche Attribute ein Span sonst noch trägt, zeigt Grafana beim Aufklappen.

== Offizielle Dokumentation

#tabelle(
  (auto, 1fr),
  ([Thema], [Adresse]),
  [k3s], [#link("https://docs.k3s.io")[docs.k3s.io], etcd-Snapshots unter `/cli/etcd-snapshot`],
  [Prometheus und PromQL], [#link("https://prometheus.io/docs/")[prometheus.io/docs]],
  [Prometheus-Operator], [#link("https://prometheus-operator.dev")[prometheus-operator.dev]],
  [kube-prometheus-stack], [#link("https://github.com/prometheus-community/helm-charts")[github.com/prometheus-community/helm-charts]],
  [Thanos], [#link("https://thanos.io")[thanos.io], Receive unter `/tip/components/receive.md`],
  [SeaweedFS], [#link("https://github.com/seaweedfs/seaweedfs/wiki")[github.com/seaweedfs/seaweedfs/wiki]],
  [Loki und LogQL], [#link("https://grafana.com/docs/loki/latest/")[grafana.com/docs/loki/latest]],
  [Tempo und TraceQL], [#link("https://grafana.com/docs/tempo/latest/")[grafana.com/docs/tempo/latest]],
  [Alloy], [#link("https://grafana.com/docs/alloy/latest/")[grafana.com/docs/alloy/latest]],
  [Grafana], [#link("https://grafana.com/docs/grafana/latest/")[grafana.com/docs/grafana/latest]],
  [Pyroscope], [#link("https://grafana.com/docs/pyroscope/latest/")[grafana.com/docs/pyroscope/latest]],
  [Blackbox-Exporter], [#link("https://github.com/prometheus/blackbox_exporter")[github.com/prometheus/blackbox_exporter]],
  [Velero], [#link("https://velero.io/docs/")[velero.io/docs]],
  [Velero-Plugin für AWS], [#link("https://github.com/vmware-tanzu/velero-plugin-for-aws")[github.com/vmware-tanzu/velero-plugin-for-aws]],
  [AWS S3], [#link("https://docs.aws.amazon.com/s3/")[docs.aws.amazon.com/s3], Preise unter #link("https://aws.amazon.com/s3/pricing/")[aws.amazon.com/s3/pricing]],
  [SLOs und Burn-Rate], [#link("https://sre.google/workbook/alerting-on-slos/")[sre.google/workbook/alerting-on-slos]],
)

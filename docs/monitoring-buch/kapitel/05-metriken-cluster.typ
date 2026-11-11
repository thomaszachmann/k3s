#import "../lib.typ": *

#kapitel(
  [Metriken aus den App-Clustern],
  ziel: [app1 und app2 schicken ihre Metriken über HTTPS mit Basic Auth an die Zentrale, und eine einzige PromQL-Abfrage vergleicht alle drei Cluster.],
  zeit: [75 Minuten],
  braucht: [Kapitel 2 (CoreDNS, TLS, `obs-ca`) und Kapitel 4 (Thanos Receive läuft)],
)

== Was du aufbaust

In den App-Clustern läuft kein Prometheus. Ein schlanker Sammler genügt: Grafana Alloy holt die Metriken ab und schickt sie per Remote Write an Receive. Zwei Exporter liefern die Rohdaten.

#tabelle(
  (auto, auto, 1fr),
  ([Wo], [Was], [Aufgabe]),
  [obs], [Traefik-Middleware `obs-basic-auth`], [Lässt nur bekannte Cluster durch],
  [obs], [Ingress `receive`, `loki`, `tempo`], [HTTPS-Eingänge unter `*.obs.internal`],
  [app1, app2], [kube-state-metrics], [Zustand der Kubernetes-Objekte als Metriken],
  [app1, app2], [node-exporter], [CPU, Speicher, Platte und Netz des Nodes],
  [app1, app2], [Alloy mit `metrics.alloy`], [Sammelt ein, hängt `cluster` an, schickt an Receive],
)

#warum[
  Remote Write dreht die Richtung um. Nicht die Zentrale holt ab, sondern jeder Cluster liefert. Die Zentrale muss deshalb keinen App-Cluster erreichen können, und für einen neuen Cluster änderst du auf obs nur die Benutzerliste.
]

== Ein Zugang pro Cluster

Jeder Cluster bekommt einen eigenen Benutzer mit eigenem Passwort. Der Benutzername ist der Clustername. Das Passwort entsteht mit `openssl rand` und liegt nur im Secret `obs-remote-auth` des jeweiligen Clusters.

#cmd("Mac")[```bash
for c in obs app1 app2; do
  kubectl --context $c -n monitoring create secret generic \
    obs-remote-auth \
    --from-literal=username=$c \
    --from-literal=password="$(openssl rand -hex 24)"
done
```][Legt in allen drei Clustern das Secret an. obs bekommt auch eins, denn ab Kapitel 8 schickt Alloy auf obs Logs und Traces über denselben Weg. Das Passwort erscheint weder auf dem Bildschirm noch in der Shell-Historie.]

#falle[
  Den Befehl nicht wiederholen, wenn die Secrets schon existieren. `create` bricht dann mit `already exists` ab, und das ist gut so: Ein neues Passwort im Cluster passt nicht mehr zur Benutzerliste auf obs. Willst du ein Passwort tauschen, löschst du das Secret und führst danach auch den nächsten Schritt erneut aus.
]

Auf obs braucht Traefik die Benutzerliste im htpasswd-Format. Sie enthält pro Zeile einen Namen und einen Hash des Passworts, nie das Passwort selbst.

#cmd("Mac")[```bash
for c in obs app1 app2; do
  kubectl --context $c -n monitoring get secret obs-remote-auth \
    -o jsonpath='{.data.password}' | base64 -d \
    | openssl passwd -apr1 -stdin | sed "s/^/$c:/"
done | kubectl --context obs -n monitoring create secret generic \
  obs-basic-auth-users --from-file=users=/dev/stdin
```][Liest jedes Passwort aus seinem Cluster, berechnet mit `openssl passwd -apr1` einen Hash und setzt den Clusternamen davor. Die drei Zeilen fließen direkt in das Secret `obs-basic-auth-users` auf obs. `-stdin` hält das Passwort aus der Prozessliste heraus.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring get secret obs-basic-auth-users \
  -o jsonpath='{.data.users}' | base64 -d | cut -d: -f1
```][Zeigt nur die Benutzernamen, nicht die Hashes.]

#pruefe[
  Drei Zeilen: `obs`, `app1` und `app2`.
]

== Middleware und Ingress

Die Middleware verweist auf die Benutzerliste. Jeder Ingress, der sie einbindet, verlangt Basic Auth.

#datei("observability/central/ingress/middleware.yaml", ```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: obs-basic-auth
  namespace: monitoring
spec:
  basicAuth:
    secret: obs-basic-auth-users
    removeHeader: true
```, erklaerung: [
  `removeHeader: true` entfernt den `Authorization`-Header, bevor die Anfrage an Receive geht. Das Passwort reist also nicht weiter als nötig.
])

#datei("observability/central/ingress/receive.yaml (Ausschnitt)", ```yaml
metadata:
  name: receive
  namespace: monitoring
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.middlewares: monitoring-obs-basic-auth@kubernetescrd
spec:
  tls:
    - hosts: [receive.obs.internal]
      secretName: obs-tls
  rules:
    - host: receive.obs.internal
      http:
        paths:
          - path: /api/v1/receive
            pathType: Prefix
            backend:
              service: {name: thanos-receive, port: {number: 19291}}
```, erklaerung: [
  Die Middleware nennst du in der Form `<namespace>-<name>@kubernetescrd`. Nach außen ist nur der Schreibpfad `/api/v1/receive` offen, und nur über HTTPS mit dem Zertifikat aus `obs-tls`. Abfragen laufen weiter nur im Cluster über Thanos Query.
])

`loki.yaml` und `tempo.yaml` im selben Verzeichnis sind genauso gebaut. Sie führen `loki.obs.internal` mit dem Pfad `/loki/api/v1/push` auf den Service `loki` (Port 3100) und `tempo.obs.internal` mit dem Pfad `/v1/traces` auf den Service `tempo` (Port 4318). Diese Services entstehen erst in den Kapiteln 8 und 9. Du legst alle Eingänge trotzdem jetzt an, dann ist die Tür zur Zentrale an einer Stelle beschrieben.

#cmd("Mac")[```bash
kubectl --context obs apply -f observability/central/ingress/
```][Wendet Middleware und alle drei Ingress-Objekte an.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring get ingress
```][Zeigt die drei Eingänge.]

#pruefe[
  `receive`, `loki` und `tempo` mit Klasse `traefik`, den passenden Hostnamen und Port `80, 443`. Unter `ADDRESS` steht `172.16.0.126`.
]

== Von außen prüfen

Bevor ein Cluster schreibt, prüfst du die Tür vom Mac aus. Der Name `receive.obs.internal` steht seit Kapitel 2 in deiner `/etc/hosts`.

#cmd("Mac")[```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  --cacert observability/tls/ca.crt \
  -X POST https://receive.obs.internal/api/v1/receive
```][Eine Anfrage ohne Zugangsdaten. `-w '%{http_code}'` gibt nur den HTTP-Status aus. `--cacert` prüft das Zertifikat gegen deine eigene CA.]

#pruefe[
  `401`. Traefik weist die Anfrage ab, bevor sie Receive erreicht. Meldet `curl` stattdessen einen Zertifikatsfehler, stimmt `obs-tls` nicht. Kommt `404`, fehlt der Ingress.
]

#cmd("Mac")[```bash
PW=$(kubectl --context app1 -n monitoring get secret obs-remote-auth \
  -o jsonpath='{.data.password}' | base64 -d)
```][Holt das Passwort von app1 in eine Shell-Variable, ohne es anzuzeigen.]

#cmd("Mac")[```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  --cacert observability/tls/ca.crt -u "app1:$PW" \
  -X POST https://receive.obs.internal/api/v1/receive
unset PW
```][Dieselbe Anfrage mit Benutzer und Passwort. Danach verschwindet das Passwort wieder aus der Shell.]

#pruefe[
  Nicht mehr `401`, sondern `400`. Traefik hat dich durchgelassen, und Receive lehnt den leeren Inhalt ab, weil er keine gültige Remote-Write-Nachricht ist. Genau so soll es sein.
]

#falle[
  Basic Auth beweist nur, _welcher_ Cluster schreibt. Den Mandanten wählt der Sender selbst über den Header `THANOS-TENANT`. Ein Cluster mit gültigem Zugang könnte also unter fremdem Namen schreiben. Im Labor ist das hinnehmbar, die Aufgabe am Ende des Kapitels zeigt, wie Traefik den Mandanten erzwingt.
]

== Exporter in app1 und app2

Auf obs hat kube-prometheus-stack beide Exporter mitgebracht. In den App-Clustern installierst du sie einzeln aus denselben Charts. Welche Versionen aktuell sind, fragst du Helm:

#cmd("Mac")[```bash
helm repo update prometheus-community
helm search repo prometheus-community/kube-state-metrics
helm search repo prometheus-community/prometheus-node-exporter
```][Zeigt die neueste Chart- und App-Version. Stand dieses Buches: `kube-state-metrics` Chart `9.0.0` (App `2.20.0`) und `prometheus-node-exporter` Chart `5.0.0` (App `1.12.1`). Die Befehle unten nutzen genau diese Versionen.]

#datei("observability/cluster/exporters/node-exporter.yaml (Ausschnitt)", ```yaml
prometheusScrape: false
extraArgs:
  - --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run/containerd/.+|var/lib/docker/.+|var/lib/kubelet/.+)($|/)
  - --collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|...|erofs)$
```, erklaerung: [
  Die Filter stammen aus kube-prometheus-stack. Ohne sie meldet node-exporter jeden Container-Mount als eigenes Dateisystem. `prometheusScrape: false` lässt die Annotation `prometheus.io/scrape` weg, denn Alloy sucht die Pods gezielt über ihr Label. Die Datei für kube-state-metrics enthält nur diesen Schalter und Ressourcen-Grenzen.
])

#cmd("Mac")[```bash
for c in app1 app2; do
  helm --kube-context $c upgrade --install kube-state-metrics \
    prometheus-community/kube-state-metrics \
    -n monitoring --version 9.0.0 \
    -f observability/cluster/exporters/kube-state-metrics.yaml --wait
done
```][Installiert kube-state-metrics in beiden App-Clustern.]

#cmd("Mac")[```bash
for c in app1 app2; do
  helm --kube-context $c upgrade --install node-exporter \
    prometheus-community/prometheus-node-exporter \
    -n monitoring --version 5.0.0 \
    -f observability/cluster/exporters/node-exporter.yaml --wait
done
```][Installiert node-exporter als DaemonSet. Er läuft im Netz des Hosts auf Port 9100.]

#cmd("Mac")[```bash
kubectl --context app1 -n monitoring get pods
```][Zeigt die Pods in app1.]

#pruefe[
  `kube-state-metrics-...` und `node-exporter-prometheus-node-exporter-...` stehen auf `Running` und `1/1`. In app2 sieht es genauso aus.
]

== Wie Alloy mehrere Dateien lädt

Die Konfiguration von Alloy wächst über drei Kapitel: Metriken jetzt, Logs in Kapitel 8, Traces in Kapitel 9. Jedes Thema bekommt eine eigene Datei in `observability/cluster/alloy/`. Damit das funktioniert, greifen drei Dinge ineinander.

+ *Eine ConfigMap, ein Schlüssel pro Datei.* Du legst die ConfigMap `alloy-config` selbst mit `kubectl` an. Jede `.alloy`-Datei wird ein eigener Schlüssel.
+ *Das Chart hängt die ganze ConfigMap ein.* Alle Schlüssel erscheinen als Dateien unter `/etc/alloy`, und das Chart startet `alloy run /etc/alloy/<key>`.
+ *Alloy liest ein Verzeichnis.* Laut Doku von `alloy run` lädt Alloy aus einem Verzeichnis alle `*.alloy`-Dateien als eine gemeinsame Konfiguration und ignoriert Unterverzeichnisse.

Setzt du `key` auf einen Punkt, entsteht `alloy run /etc/alloy/.`, also das Verzeichnis selbst. Die versteckten Unterverzeichnisse, mit denen Kubernetes ConfigMaps einhängt, überspringt Alloy.

#datei("observability/cluster/alloy/values.yaml (Ausschnitt)", ```yaml
alloy:
  configMap:
    create: false
    name: alloy-config
    key: "."
  extraEnv:
    - name: CLUSTER_NAME
      valueFrom:
        secretKeyRef:
          name: obs-remote-auth
          key: username
    # OBS_USER und OBS_PASSWORD ebenso aus obs-remote-auth
  mounts:
    varlog: true
    extra:
      - name: obs-ca
        mountPath: /etc/obs-ca
        readOnly: true
controller:
  type: daemonset
  volumes:
    extra:
      - name: obs-ca
        configMap:
          name: obs-ca
```, erklaerung: [
  Weil der Benutzername gleich dem Clusternamen ist, liest `CLUSTER_NAME` aus demselben Secret. So gilt eine einzige Werte-Datei für alle drei Cluster, Dateien pro Cluster brauchst du nicht. `varlog` und die OTLP-Ports im Rest der Datei sind schon für die Kapitel 8 und 9 vorbereitet, damit sich der Helm-Befehl nie mehr ändert.
])

#warum[
  Alloy verlangt, dass jeder Komponentenname über alle Dateien hinweg eindeutig ist. Deshalb beginnen alle Namen in `metrics.alloy` mit `metrics_`, in `logs.alloy` mit `logs_` und in `traces.alloy` mit `traces_`. Zwei Dateien können sich so nie in die Quere kommen.
]

== Die Datei metrics.alloy

Die Datei hat drei Teile: Kubelet und cAdvisor, die beiden Exporter und den Versand. Lies sie wie jede Alloy-Datei von unten nach oben, `forward_to` zeigt immer zum nächsten Glied der Kette.

#datei("observability/cluster/alloy/metrics.alloy (Ausschnitt)", ```hcl
discovery.kubernetes "metrics_nodes" {
  role = "node"
  selectors {
    role  = "node"
    field = "metadata.name=" + sys.env("HOSTNAME")
  }
}

prometheus.scrape "metrics_cadvisor" {
  targets           = discovery.relabel.metrics_cadvisor.output
  job_name          = "kubelet"
  metrics_path      = "/metrics/cadvisor"
  scheme            = "https"
  scrape_interval   = "30s"
  honor_labels      = true
  bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
  tls_config {
    ca_file              = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    insecure_skip_verify = true
  }
  forward_to = [prometheus.remote_write.metrics_obs.receiver]
}
```, erklaerung: [
  `HOSTNAME` setzt das Chart auf den Node-Namen. Der Feld-Selektor sorgt dafür, dass jeder Alloy-Pod nur den Kubelet seines eigenen Nodes abfragt. Ein `discovery.relabel` davor setzt die Labels `node` und `metrics_path`. Der Kubelet selbst läuft genauso, nur mit `/metrics`. Das Label `metrics_path` brauchen die Dashboards von kube-prometheus-stack, um beide Quellen zu unterscheiden. `insecure_skip_verify` entspricht der Voreinstellung von kube-prometheus-stack für den Kubelet.
])

#datei("observability/cluster/alloy/metrics.alloy (Ausschnitt)", ```hcl
discovery.kubernetes "metrics_pods" {
  role = "pod"
  namespaces {
    names = ["monitoring"]
  }
  selectors {
    role  = "pod"
    field = "spec.nodeName=" + sys.env("HOSTNAME")
  }
}

discovery.relabel "metrics_kube_state_metrics" {
  targets = discovery.kubernetes.metrics_pods.targets
  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
    regex         = "kube-state-metrics"
    action        = "keep"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_port_name"]
    regex         = "http"
    action        = "keep"
  }
}

prometheus.scrape "metrics_kube_state_metrics" {
  targets         = discovery.relabel.metrics_kube_state_metrics.output
  job_name        = "kube-state-metrics"
  scrape_interval = "30s"
  honor_labels    = true
  forward_to      = [prometheus.remote_write.metrics_obs.receiver]
}
```, erklaerung: [
  `keep` behält nur Ziele, deren Label auf `regex` passt. Übrig bleibt der Port `http` von kube-state-metrics. node-exporter folgt demselben Muster mit dem Label `prometheus-node-exporter`, dem Port `metrics` und `job_name = "node-exporter"`. `honor_labels` schützt die Labels `namespace` und `pod`, die kube-state-metrics für die beschriebenen Objekte setzt.
])

#datei("observability/cluster/alloy/metrics.alloy (Ausschnitt)", ```hcl
prometheus.remote_write "metrics_obs" {
  external_labels = {
    cluster = sys.env("CLUSTER_NAME"),
  }
  endpoint {
    url = "https://receive.obs.internal/api/v1/receive"
    headers = {
      "THANOS-TENANT" = sys.env("CLUSTER_NAME"),
    }
    basic_auth {
      username = sys.env("OBS_USER")
      password = sys.env("OBS_PASSWORD")
    }
    tls_config {
      ca_file = "/etc/obs-ca/ca.crt"
    }
  }
}
```, erklaerung: [
  `external_labels` hängt `cluster` an jede Serie, der Header bestimmt den Mandanten in Receive. Zugangsdaten und Clustername stammen aus Umgebungsvariablen, die Datei selbst enthält kein Geheimnis. Die CA aus der ConfigMap `obs-ca` prüft das Zertifikat von `receive.obs.internal`.
])

#hinweis("Nicht maschinell geprüft", warn, warn-hell)[
  Die Alloy-Dateien dieses Buches sind sorgfältig gegen die Referenz-Doku von Alloy abgeglichen, aber nicht mit dem `alloy`-Programm getestet. Ein Tippfehler zeigt sich beim Start: Der Pod wird nicht bereit, und `kubectl logs` nennt Datei und Zeile.
]

== Alloy installieren

Zuerst legst du die ConfigMap an, danach Alloy. In app1 und app2 enthält sie vorerst nur `metrics.alloy`.

#cmd("Mac")[```bash
for c in app1 app2; do
  kubectl --context $c -n monitoring create configmap alloy-config \
    --from-file=observability/cluster/alloy/metrics.alloy \
    --dry-run=client -o yaml | kubectl --context $c apply -f -
done
```][`--from-file` mit einer Datei nimmt den Dateinamen als Schlüssel, hier `metrics.alloy`. Das Muster aus `--dry-run` und `apply` funktioniert beim ersten Mal und bei jeder Änderung.]

#cmd("Mac")[```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana
```][Trägt das Grafana-Repository ein. Alloy liegt dort, nicht bei `grafana-community`.]

#cmd("Mac")[```bash
for c in app1 app2; do
  helm --kube-context $c upgrade --install alloy grafana/alloy \
    -n monitoring --version 1.15.0 \
    -f observability/cluster/alloy/values.yaml --wait
done
```][Installiert Alloy als DaemonSet in beiden App-Clustern. Das Chart bringt die Rechte für die Kubernetes-Discovery und für die Kubelet-Metriken mit.]

#cmd("Mac")[```bash
kubectl --context app1 -n monitoring logs ds/alloy -c alloy --tail=30
```][Zeigt den Start von Alloy in app1.]

#pruefe[
  Keine Zeilen mit `level=error`. Steht dort `401`, passt das Passwort nicht zur Benutzerliste. `x509: certificate signed by unknown authority` heißt, dass `/etc/obs-ca/ca.crt` fehlt oder falsch ist. `no such host` deutet auf CoreDNS (Kapitel 2).
]

Mit `kubectl port-forward svc/alloy 12345:12345` erreichst du außerdem die Oberfläche von Alloy unter #link("http://localhost:12345"). Sie zeigt alle Komponenten als Graph, gesunde sind grün.

== Die Konfiguration aktualisieren

Diesen Ablauf nutzt du jedes Mal, wenn sich eine `.alloy`-Datei ändert oder eine neue dazukommt. Die Kapitel 8 und 9 wiederholen ihn mit ihren Dateien.

#cmd("Mac")[```bash
for c in app1 app2; do
  kubectl --context $c -n monitoring create configmap alloy-config \
    --from-file=observability/cluster/alloy/metrics.alloy \
    --dry-run=client -o yaml | kubectl --context $c apply -f -
done
```][Schreibt die ConfigMap neu. Für jede weitere Datei hängst du eine eigene Zeile `--from-file=...` an. Nicht genannte Dateien verschwinden aus der ConfigMap.]

#cmd("Mac")[```bash
for c in app1 app2; do
  kubectl --context $c -n monitoring rollout restart ds/alloy
  kubectl --context $c -n monitoring rollout status ds/alloy
done
```][Startet Alloy neu und wartet, bis alle Pods wieder bereit sind.]

#warum[
  Das Chart bringt einen `config-reloader` mit, der Alloy bei Änderungen von selbst neu laden lässt. Das dauert aber bis zu einer Minute, und bei einem Fehler arbeitet Alloy still mit der alten Konfiguration weiter. Nach einem Neustart siehst du sofort, ob die neue Datei gilt: Der Pod wird bereit oder eben nicht.
]

So sieht die ConfigMap am Ende des Buches aus:

#tabelle(
  (auto, 1fr),
  ([Cluster], [`--from-file` für]),
  [app1, app2], [`metrics.alloy`, `logs.alloy` (Kapitel 8), `traces.alloy` (Kapitel 9)],
  [obs], [`logs.alloy` (Kapitel 8), `traces.alloy` (Kapitel 9), kein `metrics.alloy`],
)

== Alle Cluster in einer Abfrage

Wechsle zurück zu Thanos Query auf obs.

Öffne Thanos Query wie in Kapitel 4 per `port-forward` unter #link("http://localhost:10902").

```promql
count by (tenant_id, cluster) (up)
```

#pruefe[
  Drei Zeilen: je eine für `obs`, `app1` und `app2`, und in jeder Zeile sind `tenant_id` und `cluster` gleich. In app1 und app2 zählt jede Zeile vier Ziele: Kubelet, cAdvisor, node-exporter und kube-state-metrics.
]

Jetzt vergleichst du die Cluster. Das Muster ist immer gleich: `sum by (cluster)` fasst alles innerhalb eines Clusters zusammen und behält die Cluster getrennt.

```promql
sum by (cluster) (
  rate(container_cpu_usage_seconds_total{container!=""}[5m])
)
```

```promql
sum by (cluster) (node_memory_MemAvailable_bytes)
  / sum by (cluster) (node_memory_MemTotal_bytes)
```

```promql
sum by (cluster) (kube_pod_status_phase{phase="Running"})
```

#pruefe[
  Jede Abfrage liefert drei Kurven, eine pro Cluster. Die erste zeigt verbrauchte CPU-Kerne, die zweite den freien Anteil des Arbeitsspeichers zwischen 0 und 1, die dritte laufende Pods. obs liegt überall deutlich höher, dort läuft die ganze Zentrale.
]

#aufgabe[
  Erzwinge den Mandanten auf obs. Traefik kann den angemeldeten Benutzernamen in einen Header schreiben: Die Option `headerField` der Basic-Auth-Middleware setzt ihn und überschreibt dabei einen mitgeschickten Wert. Lege eine zweite Middleware `receive-tenant` an, die dieselbe Benutzerliste nutzt und zusätzlich `headerField: THANOS-TENANT` setzt. Ersetze am Ingress `receive` die bisherige Middleware durch die neue. Zwei Basic-Auth-Middlewares hintereinander funktionieren nicht, denn die erste entfernt den `Authorization`-Header. Ändere dann in app1 testweise den Header in `metrics.alloy` auf `"THANOS-TENANT" = "app2"` und aktualisiere die Konfiguration. Welches `tenant_id` zeigt Thanos Query für `cluster="app1"`? Stell danach alles zurück.
]

#gelernt(
  [Ein Benutzer pro Cluster in einer htpasswd-Liste trennt die Zugänge, die Passwörter leben nur in Secrets.],
  [Nach außen ist nur der Schreibpfad offen, und ein `curl` ohne Zugangsdaten muss `401` liefern.],
  [Alloy lädt mit `key: "."` alle `.alloy`-Dateien einer ConfigMap. Eindeutige Präfixe halten die Dateien auseinander.],
  [Eine Änderung an Alloy heißt: ConfigMap neu schreiben, DaemonSet neu starten.],
  [`sum by (cluster)` vergleicht alle Cluster in einer einzigen Abfrage.],
)

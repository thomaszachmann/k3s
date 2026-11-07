#import "../lib.typ": *

#kapitel(
  [Alles zusammenführen],
  ziel: [Aus Einzeltools wird eine Architektur: ein Dashboard, Alarme und eine Angriffsübung über alle Schichten.],
  zeit: [90 Minuten],
  braucht: [Kapitel 1 bis 11],
)

== Das Sicherheits-Dashboard

Ein gutes Dashboard beantwortet in zehn Sekunden: Ist gerade etwas los? Lege in Grafana unter *Dashboards > New* ein neues Dashboard an und baue diese Panels. Du lernst dabei mehr, als wenn du ein fertiges JSON importierst.

#tabelle(
  (auto, auto, 1fr),
  ([Panel], [Quelle], [Abfrage]),
  [Falco nach Regel], [Loki], [Abfrage siehe unten],
  [Blockierte Pakete], [Prometheus], [`sum by (reason) (rate(hubble_drop_total[5m]))`],
  [Kritische CVEs], [Prometheus], [`sum(trivy_image_vulnerabilities{severity="Critical"})`],
  [Fehlkonfigurationen], [Prometheus], [`sum by (severity) (trivy_resource_configaudits)`],
  [Abgelehnte API-Anfragen], [Loki], [Abfrage siehe unten],
  [Langsame Webhooks], [Tempo], [Abfrage siehe unten],
)

Falco nach Regel (Panel-Typ *Bar chart*):

```logql
sum by (rule) (
  count_over_time(
    {namespace="falco", container="falco"}
    | json | priority =~ "Warning|Error|Critical" [1h]
  )
)
```

Abgelehnte API-Anfragen (Panel-Typ *Time series*):

```logql
sum(
  count_over_time(
    {job="audit"} | json | responseStatus_code="403" [5m]
  )
)
```

Webhook-Aufrufe über 100 Millisekunden (Panel-Typ *Table*):

```traceql
{ resource.service.name = "apiserver" && name =~ ".*webhook.*"
  && duration > 100ms }
```

Menschliche Zugriffe auf Secrets (Panel-Typ *Logs*):

```logql
{job="audit"} | json
  | objectRef_resource="secrets"
  | user_username !~ "system:.*"
```

Dazu passt der Stand aus Kyverno, den du per `kubectl get polr -A` siehst. Möchtest du ihn im Dashboard, aktiviere in `kyverno/values.yaml` bei `admissionController` und `reportsController` den Wert `serviceMonitor.enabled: true`.

#warum[
  Exportiere das fertige Dashboard als JSON nach `security/dashboard.json`. So überlebt es im Repo einen Neuaufbau der VM.
]

== Alarme

Ein Dashboard hilft nur, wenn jemand hinschaut. Für die wichtigsten Fälle legst du Regeln an.

#datei("security/alerts.yaml", ```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: security
  namespace: monitoring
spec:
  groups:
    - name: security
      rules:
        - alert: KritischeSchwachstelle
          expr: sum(trivy_image_vulnerabilities{severity="Critical"}) > 0
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: Es laufen Images mit kritischen CVEs.
        - alert: VieleBlockiertePakete
          expr: sum(rate(hubble_drop_total{reason="POLICY_DENIED"}[5m])) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: Ungewöhnlich viele blockierte Verbindungen.
```, erklaerung: [
  `for: 1h` vermeidet Alarme bei kurzzeitigen Ausreißern. Dank `ruleSelectorNilUsesHelmValues: false` aus Kapitel 10 findet Prometheus die Regel.
])

#cmd("Mac")[```bash
kubectl apply -f security/alerts.yaml
```][Lädt die Regeln.]

#cmd("Mac")[```bash
kubectl port-forward -n monitoring \
  svc/kps-kube-prometheus-stack-prometheus 9090
```][Unter #link("http://localhost:9090/alerts") siehst du den Zustand der Alarme.]

#falle[
  Der Reason-Wert `POLICY_DENIED` ist ein gängiger Wert von `hubble_drop_total`, kann sich aber zwischen Versionen unterscheiden. Prüfe die echten Werte mit `sum by (reason) (hubble_drop_total)`, bevor du dich auf den Alarm verlässt.
]

Für Falco legst du einen Grafana-Alarm an: Öffne das Panel *Falco nach Regel*, wähle *More > New alert rule*, setze die Schwelle auf größer als null und speichere. Grafana prüft die LogQL-Abfrage dann regelmäßig.

== Die Angriffsübung

Jetzt spielst du einen Einbruch über alle Schichten durch. Halte dein Dashboard offen. Du übernimmst die Rolle des Angreifers, der eine Remote-Shell im `frontend` erlangt hat.

Bevor du anfängst, hol deine Aufschriebe aus Kapitel 1. Stimmen deine Erwartungen?

=== Phase 1: Umsehen

#cmd("Mac")[```bash
kubectl exec -it -n demo deploy/frontend -- sh
```][Das simuliert den Einbruch. *Falco* meldet sofort `Terminal shell in container`.]

#cmd("Pod")[```bash
id
```][Du bist Nutzer 100, nicht root. Das ist *PSA*: `restricted` verlangt `runAsNonRoot`.]

#cmd("Pod")[```bash
ls /var/run/secrets/kubernetes.io/serviceaccount/
```][Fehler: Das Verzeichnis existiert nicht. Das ist *RBAC* aus Kapitel 3: `automountServiceAccountToken: false`. Ohne Token spricht der Angreifer nicht mit dem API-Server.]

=== Phase 2: Ausbreiten

#cmd("Pod")[```bash
curl -s -m 3 -o /dev/null -w '%{http_code}\n' \
  http://kps-grafana.monitoring.svc.cluster.local/
```][Timeout (`000`). *Cilium* blockiert, weil dieser Weg nicht erlaubt ist.]

#cmd("Pod")[```bash
curl -s -m 3 -o /dev/null -w '%{http_code}\n' \
  http://backend:8080/admin
```][Erwartet: `403`. *Cilium* lässt nur `GET /` durch.]

=== Phase 3: Daten ausschleusen

#cmd("Pod")[```bash
curl -s -m 5 -o /dev/null -w '%{http_code}\n' https://example.org/
```][Timeout (`000`). *Cilium* erlaubt nur `example.com`. Der Weg nach draußen ist zu.]

=== Phase 4: Festsetzen

#cmd("Pod")[```bash
echo test > /usr/bin/hintertuer
```][`Permission denied`. Du bist kein root, das System-Verzeichnis gehört dir nicht.]

#cmd("Pod")[```bash
exit
```][Der Angreifer steckt fest.]

=== Phase 5: Der Umweg über den API-Server

Stell dir vor, der Angreifer hat Zugangsdaten von alice gestohlen. Ihr Zertifikat aus Kapitel 3 ist inzwischen abgelaufen, das zeigt schon den Nutzen kurzer Laufzeiten. Für die Übung handelst du deshalb mit `--as` als alice:

#cmd("Mac")[```bash
kubectl run ausbruch -n demo --image=busybox:1.36 \
  --privileged --as=alice --as-group=plattform
```][alice darf hier Pods erstellen, aber *PSA* lehnt den privilegierten Pod ab.]

#cmd("Mac")[```bash
kubectl get secrets -n kube-system --as=alice --as-group=plattform
```][`Forbidden`. *RBAC* gilt nur in `demo`. Der Versuch steht jetzt im *Audit-Log*.]

== Die Spurensuche

Wechsle die Rolle: Du bist jetzt die Verteidigung. Beantworte die Fragen nur aus Grafana.

#tabelle(
  (1fr, auto),
  ([Frage], [Wo du suchst]),
  [Wann begann der Vorfall, und in welchem Pod?], [Falco in Loki],
  [Welche Verbindungen wurden versucht?], [Hubble],
  [Hat jemand auf Secrets zugegriffen?], [Audit-Log in Loki],
  [Wer hat einen privilegierten Pod versucht?], [Audit-Log, `responseStatus_code="403"`],
  [Was geschah in der API-Anfrage?], [Tempo, falls erfasst],
)

#cmd("Mac")[```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --from-pod demo/frontend \
  --verdict DROPPED --last 20
```][Zeigt alle blockierten Versuche des `frontend`. Hubble hält nur die jüngsten Flüsse im Speicher, für einen längeren Zeitraum nimmst du die Metriken.]

Diese Abfrage zeigt jede Ablehnung durch alice:

```logql
{job="audit"} | json
  | user_username="alice"
  | responseStatus_code="403"
```

#pruefe[
  Du kannst die Geschichte des Angriffs erzählen: Wann er begann, was versucht wurde und wo jede Schicht eingegriffen hat. Genau das ist der Unterschied zwischen einer Sammlung von Tools und einer Architektur.
]

== Was die Übung gezeigt hat

#tabelle(
  (auto, auto, auto),
  ([Aktion], [Verhindert von], [Erkannt von]),
  [Shell im Container], [nichts], [Falco],
  [Rechte als root], [PSA], [Audit-Log],
  [Token stehlen], [RBAC, kein Mount], [nichts nötig],
  [Andere Dienste erreichen], [Cilium], [Hubble],
  [Ins Internet senden], [Cilium], [Hubble],
  [Privilegierter Pod], [PSA], [Audit-Log],
  [Secrets lesen], [RBAC], [Audit-Log],
)

Beachte die erste Zeile: Die Shell selbst hat nichts verhindert. Dass der Einbruch nichts bringt, liegt am Zusammenspiel der anderen Schichten.

#aufgabe[
  Suche die Schwächen deiner eigenen Architektur. Was wäre, wenn der Angreifer im `backend` statt im `frontend` gelandet wäre? Was erreicht jemand mit deinem Admin-Zugang auf dem Mac? Welche dieser Lücken schließt keines der Tools? Notiere drei Punkte für deine nächste Lernrunde.
]

#gelernt(
  [Einzelne Tools werden erst durch Zusammenspiel zu einer Architektur.],
  [Nicht jede Schicht verhindert, manche erkennen, und beide Rollen sind nötig.],
  [Eine Übung zeigt, ob deine Annahmen stimmen.],
  [Ein Dashboard ohne Alarm hilft nur, wenn jemand hinschaut.],
)

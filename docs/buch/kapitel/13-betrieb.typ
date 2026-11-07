#import "../lib.typ": *

#kapitel(
  [Betrieb und Fehlersuche],
  ziel: [Du hältst den Stack am Laufen, sicherst das Wichtige und findest Fehler nach einem festen Muster.],
  zeit: [30 Minuten Lesen, danach als Nachschlagewerk],
)

== Der Ablauf nach jedem Neustart

Nach einem Neustart der VM startet alles von selbst.

#cmd("Mac")[```bash
kubectl get nodes
kubectl get pods -A | grep -vE 'Running|Completed'
```][Der zweite Befehl zeigt nur Pods, die nicht in Ordnung sind. Die Liste sollte nach einigen Minuten leer sein.]

== Was du sichern musst

#tabelle(
  (auto, 1fr, 1fr),
  ([Was], [Wie], [Wo ablegen]),
  [k3s-Server-Token], [Passwort-Manager], [Nicht im Cluster],
  [etcd], [Snapshot], [Vom Node herunter],
  [Konfiguration], [Dieses Repo], [Git],
)

#cmd("Node")[```bash
sudo k3s etcd-snapshot save --name manuell
```][Erstellt einen Snapshot des Datastores. Das geht, weil du in Kapitel 2 `cluster-init` gewählt hast.]

#cmd("Node")[```bash
sudo k3s etcd-snapshot ls
```][Zeigt alle Snapshots. k3s erstellt zusätzlich alle zwölf Stunden automatisch einen.]

#falle[
  Ein etcd-Snapshot allein genügt für die Wiederherstellung nicht. Wegen `secrets-encryption` brauchst du auch das Server-Token aus `/var/lib/rancher/k3s/server/token`. Sichere es im Passwort-Manager. Eine Sicherung ist außerdem erst dann eine Sicherung, wenn du die Wiederherstellung einmal geübt hast.
]

== Das Fehlersuch-Muster

Geh bei jedem Problem von außen nach innen vor. Rate nicht, sondern schau nach.

+ *Was läuft nicht?* `kubectl get pods -A`
+ *Warum?* `kubectl describe pod <name> -n <ns>`, ganz unten stehen die Events.
+ *Was sagt die Anwendung?* `kubectl logs <pod> -n <ns> --previous`
+ *Wer hat es blockiert?* Geh die Tabelle unten durch.

#tabelle(
  (auto, 1fr, 1fr),
  ([Symptom], [Wahrscheinliche Schicht], [Prüfen mit]),
  [`Forbidden` beim Anlegen], [RBAC], [`kubectl auth can-i`],
  [`violates PodSecurity`], [PSA], [Label am Namespace],
  [`admission webhook denied`], [Kyverno], [`kubectl get polr -A`],
  [Verbindung läuft ins Timeout], [Cilium], [`hubble observe --verdict DROPPED`],
  [HTTP 403 ohne Anwendungslog], [Cilium L7], [`hubble observe --verdict DROPPED`],
  [Pod hängt in `ContainerCreating`], [Secret oder Volume fehlt], [`kubectl describe pod`],
  [Keine Logs in Grafana], [Alloy oder Loki], [`kubectl logs ds/alloy -n monitoring`],
  [Keine Traces in Grafana], [Alloy oder Tempo], [`kubectl logs statefulset/tempo -n monitoring`],
)

== Die Notbremsen

Wenn eine Sicherheitsschicht den Betrieb blockiert, kommst du so schnell heraus. Nutze das nur zum Beheben und schalte danach wieder ein.

#tabelle(
  (auto, 1fr),
  ([Schicht], [Notbremse]),
  [Kyverno], [`kubectl delete vpol <name>`, im Extremfall Webhook löschen],
  [Cilium-Policy], [`kubectl delete cnp --all -n <ns>`],
  [PSA], [Label auf `enforce=privileged` setzen],
  [Audit-Log], [Zeilen in `config.yaml` auskommentieren, k3s neu starten],
)

#cmd("Mac")[```bash
kubectl label namespace demo --overwrite \
  pod-security.kubernetes.io/enforce=privileged
```][Beispiel für PSA. `--overwrite` ist nötig, weil das Label schon existiert.]

== Updates

Halte die Reihenfolge ein, denn die Komponenten hängen voneinander ab.

+ *k3s:* immer nur eine Minor-Version auf einmal. Prüfe vorher die Kompatibilität von Cilium.
+ *Cilium:* vorher die Upgrade-Notes lesen.
+ *Kyverno:* In 1.20 fällt `ClusterPolicy` weg. Du nutzt schon `ValidatingPolicy`, bist also vorbereitet.
+ *Alles andere:* Eines nach dem anderen, dazwischen `kubectl get pods -A` prüfen.

Falls Cilium in einer späteren Version Kubernetes 1.37 unterstützt, kannst du auf den Kanal `stable` wechseln. Du änderst dazu nur `INSTALL_K3S_CHANNEL` und führst das Installationsskript erneut aus.

== Ressourcen im Blick

#cmd("Mac")[```bash
kubectl top node
kubectl top pods -A --sort-by=memory | head -15
```][Zeigt die größten Speicherverbraucher. Vergleiche mit deinem Plan aus Kapitel 1.]

Wird der Speicher knapp, geh in dieser Reihenfolge vor:

+ Das Sampling der API-Server-Traces senken oder Tempo abschalten.
+ Prometheus-Retention von zwei Tagen auf einen senken.
+ Trivy nur noch wöchentlich scannen lassen: `scannerReportTTL: 168h`.
+ Einen zweiten Node hinzufügen.

#gelernt(
  [Ein Snapshot ohne Token und ohne Wiederherstellungstest ist keine Sicherung.],
  [Jede Schicht hat ihre typische Fehlermeldung, und ihre eigene Notbremse.],
)

#heading(level: 2, numbering: none, outlined: false)[Wie es weitergehen kann]

Du hast jetzt eine vollständige Grundlage. Diese Themen bauen sinnvoll darauf auf:

- *Image-Signaturen:* Cosign und `ImageValidatingPolicy` in Kyverno.
- *GitOps:* Argo CD oder Flux wenden deine Manifeste aus dem Repo an.
- *WireGuard:* Cilium verschlüsselt den Verkehr zwischen Nodes.
- *Mutual TLS:* Cilium authentifiziert auch einzelne Pods gegeneinander.
- *Ein zweiter Node:* Damit lernst du Hochverfügbarkeit für etcd.
- *Der Zusatzteil:* TLS und ein Secrets-Tresor in den nächsten drei Kapiteln.

# Thanos auf k3s (Lern-Setup)

Prometheus-Metriken landen dauerhaft in S3 (SeaweedFS) und lassen sich über Thanos in Grafana abfragen.

Das ist ein Lern-Setup: ein Node, keine Hochverfügbarkeit. Geht die Node-Disk verloren, ist auch S3 weg.

## Aufbau

```text
Prometheus (6h Retention) ── Sidecar ──── lädt 2h-Blöcke hoch ───► SeaweedFS (Bucket thanos)
                               │                                     ▲        ▲
                               │ aktuelle Daten                      │        │ räumt auf,
                               ▼                                     │        │ 14 Tage Aufbewahrung
Grafana ──► Thanos Query ◄── alte Daten ── Store Gateway ────────────┘    Compactor
```

| Verzeichnis | Inhalt |
|---|---|
| `seaweedfs/` | S3-Speicher mit PVC, Skript für die Secrets |
| `monitoring/` | Overlay für das Helm-Release `kps` (Sidecar, Retention, Datenquelle) |
| `thanos/` | Query, Store Gateway, Compactor, ServiceMonitor |
| `grafana/` | Offizielle Thanos-Dashboards (v0.42.5) und das Beweis-Dashboard |

## Installation

Voraussetzung: Das Release `kps` (kube-prometheus-stack 92.18.0) läuft im Namespace `monitoring`.

```bash
# 1. Zugangsdaten erzeugen (nur als Kubernetes-Secrets, nie in Dateien)
./seaweedfs/create-secrets.sh

# 2. S3-Speicher
kubectl apply -f seaweedfs/seaweedfs.yaml
kubectl rollout status deploy/s3 -n monitoring

# 3. Buckets anlegen
for b in thanos loki tempo; do
  kubectl exec -n monitoring deploy/s3 -- sh -c \
    "echo 's3.bucket.create -name $b' | weed shell -master=localhost:9333"
done

# 4. Sidecar, Retention, Grafana-Datenquelle
# --reuse-values behält das Grafana-Passwort, das nur im Release liegt.
helm upgrade kps prometheus-community/kube-prometheus-stack \
  -n monitoring --version 92.18.0 --reuse-values \
  -f monitoring/kps-thanos-values.yaml --wait

# 5. Thanos und Dashboards
kubectl apply -f thanos/
kubectl apply -k grafana/ --server-side
```

## Prüfen

```bash
# Blöcke im Bucket (der erste erscheint etwa 2 bis 3 Stunden nach dem Start von Prometheus)
kubectl exec -n monitoring deploy/s3 -- sh -c \
  "echo 's3.bucket.list' | weed shell -master=localhost:9333"

# Thanos-Query-UI: http://localhost:10902 (unter "Stores" stehen Sidecar und Store)
kubectl port-forward -n monitoring svc/thanos-query 10902

# Grafana: http://localhost:3000
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
```

## Der Beweis

Dashboard **Thanos Proof: Prometheus vs. S3** in Grafana öffnen. Es zeigt dieselbe Abfrage über beide Datenquellen.

Sobald das Setup länger als 6 Stunden läuft, endet die linke Kurve (Prometheus) nach etwa 6 Stunden, die rechte (Thanos) reicht weiter zurück. Dieser ältere Teil kann nur aus S3 kommen.

## Stolperfallen

- **Service-Name `s3`:** Kubernetes setzt dadurch `S3_PORT=tcp://...`, und SeaweedFS liest das als `-s3.port` und stürzt ab. Deshalb steht im Deployment `enableServiceLinks: false`.
- **Pod von Hand löschen:** Der neue Pod startet, während der alte noch die LevelDB-Sperre hält. Das gibt ein paar harmlose Restarts.
- **Speicherplatz:** `local-path` setzt die PVC-Größe nicht durch. Das echte Limit sind die SeaweedFS-Flags (16 Volumes mit je 256 MB, also etwa 4 GB).
- **Job-Label des Sidecars:** Die Dashboards erwarten `thanos-sidecar`, deshalb setzt das Overlay das Label per Relabeling.
- **Neue S3-Konten (Loki, Tempo):** Die Buckets existieren, das Konto in `s3-config` darf aber nur auf `thanos` zugreifen. Für Loki und Tempo braucht es eigene Einträge in diesem Secret.

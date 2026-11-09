#!/usr/bin/env bash
# Erzeugt die S3-Zugangsdaten für SeaweedFS und legt sie nur als Kubernetes-Secrets
# im Namespace monitoring auf dem Cluster obs ab:
#   s3-config        Konten des S3-Gateways (Schlüssel s3.json)
#   thanos-objstore  Objektspeicher-Konfiguration für Thanos (Schlüssel objstore.yml)
#   loki-s3          AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY für Loki
#   tempo-s3         AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY für Tempo
#   velero-s3        AWS-credentials-Datei für Velero (Schlüssel cloud)
# Jedes Konto darf nur auf seinen eigenen Bucket.
#
# Idempotent: Vorhandene Schlüssel aus s3-config bleiben erhalten, fehlende Konten
# und Secrets werden ergänzt. Das Skript gibt nie Schlüssel aus.
#
# Aufruf aus der Repo-Wurzel:  ./observability/seaweedfs/create-secrets.sh
# Anderer Kontext:             KUBE_CONTEXT=mein-obs ./observability/seaweedfs/create-secrets.sh
set -euo pipefail

CONTEXT="${KUBE_CONTEXT:-obs}"
NAMESPACE=monitoring
ENDPOINT=s3.monitoring.svc.cluster.local:8333
REGION=us-east-1

# Konto:Bucket
ACCOUNTS="thanos:thanos loki:loki tempo:tempo velero:backup"

k() { kubectl --context "$CONTEXT" -n "$NAMESPACE" "$@"; }

for tool in kubectl jq openssl base64; do
  command -v "$tool" >/dev/null || { echo "Programm fehlt: $tool" >&2; exit 1; }
done

if ! kubectl --context "$CONTEXT" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "Namespace $NAMESPACE fehlt im Kontext $CONTEXT (siehe Kapitel 2)." >&2
  exit 1
fi

# Bestehende Konten lesen, damit ein erneuter Lauf keine Schlüssel austauscht.
OLD='{"identities":[]}'
if k get secret s3-config >/dev/null 2>&1; then
  OLD=$(k get secret s3-config -o jsonpath='{.data.s3\.json}' | base64 -d)
fi

NEW='{"identities":[]}'
for pair in $ACCOUNTS; do
  name=${pair%%:*}
  bucket=${pair#*:}
  AK=$(printf '%s' "$OLD" | N="$name" jq -r \
    '.identities[]? | select(.name == env.N) | .credentials[0].accessKey // empty')
  SK=$(printf '%s' "$OLD" | N="$name" jq -r \
    '.identities[]? | select(.name == env.N) | .credentials[0].secretKey // empty')
  if [ -z "$AK" ] || [ -z "$SK" ]; then
    AK=$(openssl rand -hex 16)
    SK=$(openssl rand -hex 32)
    echo "Konto $name: neu erzeugt (Bucket $bucket)"
  else
    echo "Konto $name: vorhanden, Schlüssel bleiben (Bucket $bucket)"
  fi
  # Werte über die Umgebung statt als Argument, damit sie nicht in der Prozessliste stehen.
  NEW=$(printf '%s' "$NEW" | N="$name" B="$bucket" AK="$AK" SK="$SK" jq \
    '.identities += [{
       name: env.N,
       credentials: [{accessKey: env.AK, secretKey: env.SK}],
       actions: ["Read:\(env.B)", "Write:\(env.B)", "List:\(env.B)", "Tagging:\(env.B)"]
     }]')
done

# Schlüssel eines Kontos aus NEW lesen: key <konto> accessKey|secretKey
key() {
  printf '%s' "$NEW" | N="$1" F="$2" jq -r \
    '.identities[] | select(.name == env.N) | .credentials[0][env.F]'
}

# Secret aus der Standardeingabe bauen und anwenden. Nichts landet in Dateien
# oder in der Prozessliste.
apply_secret() {
  k create secret generic "$@" --dry-run=client -o yaml | k apply -f - >/dev/null
}

printf '%s\n' "$NEW" | apply_secret s3-config --from-file=s3.json=/dev/stdin

cat <<YAML | apply_secret thanos-objstore --from-file=objstore.yml=/dev/stdin
type: S3
config:
  bucket: thanos
  endpoint: $ENDPOINT
  region: $REGION
  access_key: $(key thanos accessKey)
  secret_key: $(key thanos secretKey)
  insecure: true
  bucket_lookup_type: path
YAML

for svc in loki tempo; do
  cat <<ENV | apply_secret "$svc-s3" --from-env-file=/dev/stdin
AWS_ACCESS_KEY_ID=$(key "$svc" accessKey)
AWS_SECRET_ACCESS_KEY=$(key "$svc" secretKey)
ENV
done

cat <<INI | apply_secret velero-s3 --from-file=cloud=/dev/stdin
[default]
aws_access_key_id=$(key velero accessKey)
aws_secret_access_key=$(key velero secretKey)
INI

echo "Secrets s3-config, thanos-objstore, loki-s3, tempo-s3 und velero-s3 in $NAMESPACE (Kontext $CONTEXT) angelegt."

# SeaweedFS liest s3.json nur beim Start.
if [ "$(printf '%s' "$OLD" | jq -S -c .)" != "$(printf '%s' "$NEW" | jq -S -c .)" ] \
   && k get deploy s3 >/dev/null 2>&1; then
  echo "Konten geändert. Starte SeaweedFS neu:"
  echo "  kubectl --context $CONTEXT -n $NAMESPACE rollout restart deploy/s3"
fi

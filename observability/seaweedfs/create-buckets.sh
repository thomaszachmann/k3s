#!/usr/bin/env bash
# Legt die Buckets thanos, loki, tempo und backup in SeaweedFS an.
# Idempotent: vorhandene Buckets bleiben unberührt.
#
# Aufruf aus der Repo-Wurzel:  ./observability/seaweedfs/create-buckets.sh
set -euo pipefail

CONTEXT="${KUBE_CONTEXT:-obs}"
BUCKETS="thanos loki tempo backup"

# Ein Kommando in der SeaweedFS-Verwaltungsshell im Pod ausführen.
weed_shell() {
  kubectl --context "$CONTEXT" -n monitoring exec deploy/s3 -- \
    sh -c "echo '$1' | weed shell -master=localhost:9333"
}

existing=$(weed_shell "s3.bucket.list")

for b in $BUCKETS; do
  if printf '%s\n' "$existing" | grep -Eq "^[[:space:]]*$b([[:space:]]|$)"; then
    echo "Bucket $b: vorhanden"
  else
    weed_shell "s3.bucket.create -name $b" >/dev/null
    echo "Bucket $b: angelegt"
  fi
done

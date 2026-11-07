#!/usr/bin/env bash
# Generates the S3 credentials and stores them only as Kubernetes Secrets:
#   s3-config       - identities for the SeaweedFS S3 gateway
#   thanos-objstore - object storage config for all Thanos components
# Idempotent: existing credentials are kept. Values are never printed.
set -euo pipefail

NAMESPACE=monitoring
ENDPOINT=s3.monitoring.svc.cluster.local:8333
BUCKET=thanos

if kubectl get secret s3-config thanos-objstore -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Secrets already exist, nothing to do."
  exit 0
fi

ACCESS_KEY=$(openssl rand -hex 16)
SECRET_KEY=$(openssl rand -hex 32)

# Sent via stdin so the values do not appear in the process list.
kubectl apply -n "$NAMESPACE" -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: s3-config
type: Opaque
stringData:
  s3.json: |
    {
      "identities": [
        {
          "name": "thanos",
          "credentials": [{"accessKey": "$ACCESS_KEY", "secretKey": "$SECRET_KEY"}],
          "actions": ["Read:$BUCKET", "Write:$BUCKET", "List:$BUCKET", "Tagging:$BUCKET"]
        }
      ]
    }
---
apiVersion: v1
kind: Secret
metadata:
  name: thanos-objstore
type: Opaque
stringData:
  objstore.yml: |
    type: S3
    config:
      bucket: $BUCKET
      endpoint: $ENDPOINT
      region: us-east-1
      access_key: $ACCESS_KEY
      secret_key: $SECRET_KEY
      insecure: true
      bucket_lookup_type: path
EOF

echo "Secrets s3-config and thanos-objstore created in namespace $NAMESPACE."

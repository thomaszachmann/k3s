#import "../lib.typ": *

#kapitel(
  [Optional: External Secrets],
  ziel: [Values from OpenBao appear automatically as Kubernetes Secrets, and changes in the vault reach the cluster on their own.],
  zeit: [60 minutes],
  braucht: [Chapter 15],
)

== How the Pieces Fit Together

Your applications only know regular Kubernetes Secrets. They should not need to know anything about OpenBao. The External Secrets Operator (ESO) builds the bridge:

+ In an `ExternalSecret`, you describe which values you need.
+ ESO logs in to OpenBao with a short-lived ServiceAccount token.
+ OpenBao verifies the token with the Kubernetes API server.
+ ESO fetches the values and writes a regular Secret.
+ If the value changes in the vault, ESO updates the Secret.

#warum[
  Git now only holds the description of where a value lives, never the value itself. This means you can safely check in the entire configuration. The Secret in the cluster remains as a copy, but thanks to `secrets-encryption` from Chapter 2, it is encrypted in the datastore.
]

== Installing

#cmd("Mac")[```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
```][Registers the repository.]

#cmd("Mac")[```bash
helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --version 2.14.0 --wait
```][Installs the operator with the webhook and cert controller.]

#cmd("Mac")[```bash
kubectl get pods -n external-secrets
```][Three pods should be running.]

== The Account for Access

ESO gets its own account. OpenBao will trust exactly this account.

#cmd("Mac")[```bash
kubectl create serviceaccount eso-openbao -n external-secrets
```][This account has no permissions in Kubernetes and does not need any. It only serves as an ID card toward OpenBao.]

== OpenBao Trusts Kubernetes

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- sh
```][Shell in the pod. The vault must be unsealed.]

#cmd("Pod")[```bash
bao login
```][Log in with the root token.]

#cmd("Pod")[```bash
bao auth enable kubernetes
```][Enables login via ServiceAccount.]

#cmd("Pod")[```bash
bao write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc:443
```][Tells OpenBao where the API server is. OpenBao takes the CA certificate and the reviewer token automatically from its own pod. For this, the chart has given its account the role `system:auth-delegator`.]

#cmd("Pod")[```bash
bao write auth/kubernetes/role/eso \
  bound_service_account_names=eso-openbao \
  bound_service_account_namespaces=external-secrets \
  audience=openbao \
  policies=eso-lesen \
  ttl=1h
```][Connects everything: the account `eso-openbao` from `external-secrets` gets the policy `eso-lesen`. `audience` defines who the token must be issued for. That way, a token for a different service cannot be misused here.]

#cmd("Pod")[```bash
rm -f ~/.bao-token
exit
```][Removes the stored root token and takes you back to the Mac.]

== Describing the Connection

#datei("security/secrets/store.yaml", ```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao
spec:
  provider:
    vault:
      server: https://openbao.openbao.svc.cluster.local:8200
      path: secret
      version: v2
      caProvider:
        type: Secret
        name: openbao-tls
        namespace: openbao
        key: ca.crt
      auth:
        kubernetes:
          mountPath: kubernetes
          role: eso
          serviceAccountRef:
            name: eso-openbao
            namespace: external-secrets
            audiences:
              - openbao
```, erklaerung: [
  According to the ESO docs, OpenBao runs through the `vault` provider, because OpenBao speaks the same API. The CRDs now also have a separate `openBao` key, but this book sticks with the documented route. `caProvider` takes the trust from the certificate in Chapter 15. `audiences` must match the role in OpenBao.
])

#cmd("Mac")[```bash
kubectl apply -f security/secrets/store.yaml
kubectl get clustersecretstore openbao
```][The `STATUS` column shows `Valid`, and `READY` shows `True`.]

#falle[
  If you see `InvalidProviderConfig`, `kubectl describe clustersecretstore openbao` helps. Common causes: the vault is sealed, the `audience` does not match, or the role names the wrong account.
]

== The First External Secret

#datei("security/secrets/demo-db.yaml", ```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: demo-db
  namespace: demo
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: demo-db
  data:
    - secretKey: password
      remoteRef:
        key: apps/demo
        property: password
```, erklaerung: [
  `refreshInterval: 1m` is short for learning; in production, an hour or more is enough. `remoteRef.key` is the path in the vault, without `secret/` and without `data/`. `property` selects the value within it. `target.name` is the name of the resulting Secret.
])

#cmd("Mac")[```bash
kubectl apply -f security/secrets/demo-db.yaml
kubectl get externalsecret -n demo
```][`STATUS` should show `SecretSynced`.]

#cmd("Mac")[```bash
kubectl get secret demo-db -n demo \
  -o jsonpath='{.data.password}' | base64 -d; echo
```][Shows the value from the vault. You never created a Secret file.]

== Changing and Following Along

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- sh
```][Back into the vault.]

#cmd("Pod")[```bash
bao login
```][Log in.]

#cmd("Pod")[```bash
bao kv put secret/apps/demo \
  password="drittes-passwort" user=demo
```][Changes the value. From now on, this is the only place where it is maintained.]

#cmd("Pod")[```bash
rm -f ~/.bao-token
exit
```][Removes the token and takes you back to the Mac.]

#cmd("Mac")[```bash
kubectl get secret demo-db -n demo \
  -o jsonpath='{.data.password}' | base64 -d; echo
```][Within one minute at most, the new value appears.]

#falle[
  The Secret changes, but the pods do not necessarily. A Secret mounted as a *volume* is updated in the container after a short while, but the application has to reread the file. A Secret exposed as an *environment variable*, on the other hand, never changes in the running process. Then only `kubectl rollout restart` helps.
]

== Who May Do What Now?

Check the model once against what you have learned:

#cmd("Mac")[```bash
kubectl auth can-i get secrets -n demo \
  --as=system:serviceaccount:demo:app
```][Expected: `no`. The account `app` may only read pods. That is exactly why you scoped it so tightly in Chapter 3.]

Also try the audit view in Grafana:

```logql
{namespace="openbao"} |= "secret/data/apps/demo"
```

This shows you every read access by ESO to this path, with timestamp and account.

== Moving Loki's Credentials

Now you take over a real application. Loki's S3 Secret from Chapter 10 moves into the vault.

#cmd("Mac")[```bash
ACCESS=$(kubectl get secret loki-s3 -n monitoring \
  -o jsonpath='{.data.S3_ACCESS_KEY}' | base64 -d)
SECRET=$(kubectl get secret loki-s3 -n monitoring \
  -o jsonpath='{.data.S3_SECRET_KEY}' | base64 -d)
```][Reads the values into shell variables.]

#cmd("Mac")[```bash
kubectl exec -i openbao-0 -n openbao -- sh -c 'bao login -no-print -'
```][Reads the token from standard input. Paste it and press `Ctrl-D`. That way it does not end up in your history.]

#cmd("Mac")[```bash
printf '{"S3_ACCESS_KEY":"%s","S3_SECRET_KEY":"%s"}' "$ACCESS" "$SECRET" \
  | kubectl exec -i openbao-0 -n openbao -- \
    bao kv put secret/apps/loki-s3 -
```][Transfers the values as JSON via standard input. They show up neither in the process list nor in the log.]

#cmd("Mac")[```bash
unset ACCESS SECRET
kubectl exec openbao-0 -n openbao -- rm -f /home/openbao/.bao-token
```][Removes the values from the shell and the token from the pod. Check with `kubectl exec openbao-0 -n openbao -- sh -c 'echo $HOME'` whether the home directory has that name on your system.]

#datei("security/secrets/loki-s3.yaml", ```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: loki-s3
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: loki-s3
    creationPolicy: Merge
  dataFrom:
    - extract:
        key: apps/loki-s3
```, erklaerung: [
  `dataFrom.extract` takes over all keys of the path. `creationPolicy: Merge` writes into the existing Secret, because that Secret still belongs to you and not to ESO.
])

#cmd("Mac")[```bash
kubectl apply -f security/secrets/loki-s3.yaml
kubectl get externalsecret -n monitoring
```][From now on, OpenBao is the source of truth for this Secret.]

#aufgabe[
  Following the same pattern, migrate the Grafana password. Think about this first: what would have to happen for Grafana to actually pick up a changed password?
]

#gelernt(
  [ESO translates vault paths into regular Kubernetes Secrets.],
  [Git only holds the reference to a value, never the value itself.],
  [OpenBao verifies ServiceAccount tokens with the API server, and `audience` binds them to one service.],
  [Environment variables never change in the running process.],
  [Kubernetes Secrets are the copy; the vault remains the source.],
)

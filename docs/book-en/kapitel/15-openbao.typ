#import "../lib.typ": *

#kapitel(
  [Optional: OpenBao as a Vault],
  ziel: [You run your own secrets server with TLS and an audit log, and you understand how sealing, policies and login work.],
  zeit: [75 minutes],
  braucht: [Chapter 14],
)

== Why a Vault

So far, your secrets exist as Kubernetes objects, created by scripts. That has limits: there is no history, no fine-grained permissions per path and no record of who read which value. OpenBao is an open source fork of Vault and solves exactly that.

#tabelle(
  (auto, 1fr),
  ([Term], [Meaning]),
  [Seal/Unseal], [The vault starts sealed; the data is encrypted and inaccessible.],
  [Unseal Keys], [Key shares, a minimum number of which opens the vault.],
  [Root Token], [All-powerful initial token, only for the initial setup.],
  [Secrets Engine], [Storage location. `kv-v2` is a key-value store with versions.],
  [Auth Method], [How someone logs in, here via a Kubernetes ServiceAccount.],
  [Policy], [What a logged-in token may do, per path.],
)

#warum[
  Sealing protects the data if someone steals the disk or gets to the pod: without the unseal keys, the data is worthless. The price: after every restart, someone has to open the vault. You have to decide who does that. With a single node in your home network, that is you, by hand.
]

== Preparing the TLS Certificate

#cmd("Mac")[```bash
kubectl create namespace openbao
```][The default `baseline` is enough; OpenBao does not need host access.]

#datei("security/tls/openbao-cert.yaml", ```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: openbao-tls
  namespace: openbao
spec:
  secretName: openbao-tls
  duration: 2160h
  renewBefore: 720h
  dnsNames:
    - openbao
    - openbao.openbao
    - openbao.openbao.svc
    - openbao.openbao.svc.cluster.local
    - localhost
  ipAddresses:
    - 127.0.0.1
  issuerRef:
    name: k3s2-ca
    kind: ClusterIssuer
    group: cert-manager.io
```, erklaerung: [
  `127.0.0.1` and `localhost` are needed because the `bao` command in the pod talks to the local address `https://127.0.0.1:8200`. The chart sets it up that way.
])

#cmd("Mac")[```bash
kubectl apply -f security/tls/openbao-cert.yaml
kubectl get certificate -n openbao
```][The Secret `openbao-tls` must be ready before the pod starts.]

== Installing

#datei("openbao/values.yaml", ```yaml
global:
  tlsDisable: false

injector:
  enabled: false

server:
  standalone:
    enabled: true
    config: |
      ui = true

      listener "tcp" {
        address         = "[::]:8200"
        cluster_address = "[::]:8201"
        tls_cert_file   = "/openbao/tls/tls.crt"
        tls_key_file    = "/openbao/tls/tls.key"
      }

      storage "pebbledb" {
        path = "/openbao/data/pebbledb"
      }

      audit "file" "to-stdout" {
        description = "Audit log to standard output"
        options {
          file_path = "stdout"
        }
      }
  dataStorage:
    enabled: true
    size: 1Gi
    storageClass: local-path
  extraEnvironmentVars:
    BAO_CACERT: /openbao/tls/ca.crt
  volumes:
    - name: tls
      secret:
        secretName: openbao-tls
  volumeMounts:
    - name: tls
      mountPath: /openbao/tls
      readOnly: true
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      memory: 256Mi

ui:
  enabled: true
```, erklaerung: [
  `tlsDisable: false` turns encryption on. The injector is not needed, because External Secrets delivers the values. The audit device writes to standard output, and Alloy ships it to Loki. Values appear in the log only as hashes. The `log_raw` option from the docs would show them in plain text, so do not set it.
])

#cmd("Mac")[```bash
helm upgrade --install openbao openbao/openbao \
  -n openbao --version 0.30.7 -f openbao/values.yaml
```][The `openbao` repository is already registered on your machine; otherwise run `helm repo add openbao https://openbao.github.io/openbao-helm`.]

#falle[
  Do *not* use `--wait` here. The pod only becomes `Ready` once the vault is unsealed. Helm would wait until the timeout and report an error, even though everything is running correctly.
]

#cmd("Mac")[```bash
kubectl get pods -n openbao
```][`openbao-0` is `Running`, but `0/1`. That is the correct state here.]

== Initializing and Unsealing

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- bao operator init \
  -key-shares=3 -key-threshold=2
```][Generates the root key and splits it into three shares, two of which are enough. This command runs only once in the life of this vault.]

#falle[
  The output shows the three unseal keys and the root token *only this one time*. Store them in your password manager right away, never in the repo and never in a file in Dropbox. If you lose the keys, all data in the vault is lost for good.
]

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- bao operator unseal
```][Prompts for the first unseal key without echoing it. Do not type keys directly on the command line, or they end up in your shell history.]

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- bao operator unseal
```][Prompts for the second key. After the second of the two required shares, the vault is open.]

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- bao status
```][Shows the status.]

#pruefe[
  `Initialized` is `true`, `Sealed` is `false`. `kubectl get pods -n openbao` now shows `1/1`.
]

== First Steps in the Vault

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- sh
```][Opens a shell in the pod. The following commands run inside it.]

#cmd("Pod")[```bash
bao login
```][Prompts for the root token without echoing it and keeps it in the pod for the current session.]

#cmd("Pod")[```bash
bao secrets enable -path=secret kv-v2
```][Enables a versioned key-value store at the path `secret/`. On a real server, this is not active by default.]

#cmd("Pod")[```bash
bao kv put secret/apps/demo \
  password="erstes-passwort" user=demo
```][Stores two values under one path.]

#cmd("Pod")[```bash
bao kv get secret/apps/demo
```][Reads them back.]

#cmd("Pod")[```bash
bao kv put secret/apps/demo \
  password="zweites-passwort" user=demo
```][Writes a new version.]

#cmd("Pod")[```bash
bao kv get -version=1 secret/apps/demo
```][Retrieves the old version. That is the history a Kubernetes Secret lacks.]

== Granting Permissions: the Policy

The root token may do anything; your applications should not. In OpenBao, everything is forbidden that has not been allowed, just like with RBAC.

#cmd("Pod")[```bash
bao policy write eso-lesen - <<'EOF'
path "secret/data/apps/*" {
  capabilities = ["read"]
}
path "secret/metadata/apps/*" {
  capabilities = ["read", "list"]
}
EOF
```][Creates the policy `eso-lesen`. Important: with `kv-v2`, the values live under `secret/data/`, not under `secret/`. This is the most common source of errors.]

The policy still needs someone to use it. Chapter 16 takes care of that.

#cmd("Pod")[```bash
rm -f ~/.bao-token
exit
```][`bao login` stores the token in `~/.bao-token`. A root token does not belong in a file, so you delete it and leave the pod. At the end of every session with the root token, the rule is: delete the file.]

== Experiencing the Seal

#cmd("Mac")[```bash
kubectl delete pod openbao-0 -n openbao
```][Simulates a restart of the node.]

#cmd("Mac")[```bash
kubectl get pods -n openbao
```][After a short while, the new pod is running, but it stays at `0/1`.]

#cmd("Mac")[```bash
kubectl exec -it openbao-0 -n openbao -- bao status
```][`Sealed` is `true`. The data is still there, but inaccessible until you unseal. From now on, this procedure is part of every restart.]

Now run `bao operator unseal` twice, as above.

#cmd("Mac")[```bash
kubectl logs -n openbao openbao-0 --tail=5
```][Here you see the audit log as JSON lines. In Grafana, you find it under `{namespace="openbao"}`.]

#hinweis("Unseal Automatically?", akzent, akzent-hell)[
  In production, manual unsealing gets in the way. The solution is called auto-unseal: a cloud KMS or a second vault opens the first one. The key would then live somewhere else, though, and you need that infrastructure. For your lab, the manual approach is the more instructive choice.
]

#aufgabe[
  Log in, write a second policy `nur-lesen-demo` that may read *only* `secret/data/apps/demo`, and create a token for it with `bao token create -policy=nur-lesen-demo -ttl=1h`. Test it with `BAO_TOKEN=... bao kv get secret/apps/demo`. What happens with `secret/apps/anderes`?
]

#gelernt(
  [Sealing protects data at rest, but costs work at every restart.],
  [Unseal keys and the root token belong in the password manager, never in the repo.],
  [`kv-v2` stores versions and keeps values under `secret/data/`.],
  [The audit device shows who read what, without revealing the values.],
)

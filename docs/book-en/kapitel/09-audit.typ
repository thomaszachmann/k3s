#import "../lib.typ": *

#kapitel(
  [Audit Logs: Who Did What?],
  ziel: [The API server records every important request, and you analyze the log.],
  zeit: [30 minutes],
  braucht: [Chapter 4],
)

== The API Server's Security Camera

Every change in the cluster goes through the API server. That makes it the perfect place for a log. After an incident, the audit log answers the key questions: who performed which action on which object, when, and from where?

In k3s the API server runs inside the k3s process, not as a pod. So the audit log is a file on the host. For now you read it directly there; in Chapter 10, Alloy ships it to Loki.

== The Four Log Levels

#tabelle(
  (auto, 1fr),
  ([Level], [What gets logged]),
  [`None`], [Nothing],
  [`Metadata`], [Who, what, when, result. No content.],
  [`Request`], [Also the content of the request],
  [`RequestResponse`], [Also the content of the response],
)

#warum[
  Never use `Request` or `RequestResponse` for Secrets. Otherwise the passwords end up in plain text in the log, and your log becomes a risk itself. The first matching rule wins, so the order in the file matters.
]

== Writing the Audit Policy

#datei("security/audit-policy.yaml", ```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - RequestReceived
rules:
  # Drop the noise: health checks and metrics
  - level: None
    nonResourceURLs:
      - /healthz*
      - /readyz*
      - /livez*
      - /metrics
  # Events and leader leases fire constantly
  - level: None
    resources:
      - group: ""
        resources: [events]
      - group: coordination.k8s.io
        resources: [leases]
  # Never write the content of Secrets to the log
  - level: Metadata
    resources:
      - group: ""
        resources: [secrets, configmaps]
      - group: authentication.k8s.io
        resources: [tokenreviews]
  # Record permission changes in full
  - level: RequestResponse
    verbs: [create, update, patch, delete]
    resources:
      - group: rbac.authorization.k8s.io
  # Everything else as metadata only
  - level: Metadata
```, erklaerung: [
  Without the two `None` rules at the top, the log fills up with worthless entries. `omitStages` drops the first stage of each request; otherwise every action would appear twice in the log.
])

== Enabling It on the Node

#cmd("Mac")[```bash
scp security/audit-policy.yaml \
  <user>@172.16.0.136:/tmp/audit.yaml
```][Copies the policy to the node.]

Now open `k3s/config.yaml` and uncomment the audit lines as well. The `admission-control` line has been active since Chapter 4.

#datei("k3s/config.yaml (excerpt)", ```yaml
kube-apiserver-arg:
  - "admission-control-config-file=/var/lib/rancher/k3s/server/psa.yaml"
  - "audit-policy-file=/var/lib/rancher/k3s/server/audit.yaml"
  - "audit-log-path=/var/lib/rancher/k3s/server/logs/audit.log"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
```, erklaerung: [
  `maxsize` rotates the file at 100 MB, `maxbackup` keeps ten old files, `maxage` deletes them after 30 days. That limits the disk usage to about 1.1 GB.
])

#cmd("Mac")[```bash
scp k3s/config.yaml <user>@172.16.0.136:/tmp/config.yaml
ssh <user>@172.16.0.136
```][Copies the changed configuration to the node and opens the session.]

#cmd("Node")[```bash
sudo install -m 600 -o root -g root /tmp/audit.yaml \
  /var/lib/rancher/k3s/server/audit.yaml
```][The policy must be in place before the restart, otherwise the API server won't start.]

#cmd("Node")[```bash
sudo install -m 600 -o root -g root /tmp/config.yaml \
  /etc/rancher/k3s/config.yaml
rm /tmp/audit.yaml /tmp/config.yaml
```][Puts the new configuration in place and cleans up `/tmp`.]

#cmd("Node")[```bash
sudo systemctl restart k3s
```][k3s reads `config.yaml` only at startup. The pods keep running during the restart.]

#cmd("Node")[```bash
sudo tail -n 1 /var/lib/rancher/k3s/server/logs/audit.log | jq .
```][Shows the last entry in readable form. Read it all the way through once: `user`, `verb`, `objectRef`, `sourceIPs`, `responseStatus`.]

#falle[
  If k3s no longer starts, the policy file is usually to blame. `sudo journalctl -u k3s -n 50` names the error. If all else fails, comment out the lines in `/etc/rancher/k3s/config.yaml` and restart.
]

== Analyzing the Log

Keep the SSH session open and open a second terminal on your laptop.

#cmd("Mac")[```bash
kubectl create secret generic audit-test \
  --from-literal=wert=streng-geheim
```][Creates a test Secret that you will look for in the log in a moment.]

#cmd("Mac")[```bash
kubectl get secret audit-test -o yaml
```][Reads it, so that a read access shows up in the log too.]

#cmd("Node")[```bash
sudo jq -c 'select(.objectRef.name == "audit-test")
  | {verb, user: .user.username, code: .responseStatus.code}' \
  /var/lib/rancher/k3s/server/logs/audit.log
```][`jq` reads the log as a stream of JSON objects. `select` filters, and the second stage builds a short line.]

#pruefe[
  You see entries with `create` and `get` and your admin user.
]

#cmd("Node")[```bash
sudo grep -c streng-geheim \
  /var/lib/rancher/k3s/server/logs/audit.log
```][Must print `0`: the secret value is *not* in the log. That is exactly what the `Metadata` rule did.]

#cmd("Mac")[```bash
kubectl delete secret audit-test
```][Cleans up the test object.]

== Useful Queries

Who besides system components has read Secrets?

#cmd("Node")[```bash
sudo jq -c 'select(.objectRef.resource == "secrets"
    and (.verb == "get" or .verb == "list")
    and (.user.username | startswith("system:") | not))
  | {verb, user: .user.username, name: .objectRef.name}' \
  /var/lib/rancher/k3s/server/logs/audit.log
```][The most important query for everyday use. In Chapter 10 you rewrite it in LogQL.]

Which requests were denied?

#cmd("Node")[```bash
sudo jq -c 'select(.responseStatus.code == 403)
  | {verb, user: .user.username, res: .objectRef.resource}' \
  /var/lib/rancher/k3s/server/logs/audit.log
```][Denied requests often point to misconfigurations, but sometimes also to an attacker looking around.]

#cmd("Node")[```bash
exit
```][Ends the SSH session.]

#aufgabe[
  Run `kubectl get secrets -A --as=system:anonymous`. What does the cluster answer, and what shows up in the audit log afterwards? Then start a plain `nginx` pod in a new namespace and search the log for the annotation `pod-security.kubernetes.io/audit-violations`. That is the PSA audit mode from Chapter 4.
]

#gelernt(
  [After an incident, the audit log answers: who, what, when, from where.],
  [The first matching rule wins, so the `None` rules go at the top.],
  [Secrets belong in the log only at the `Metadata` level.],
  [In k3s the audit log is a host file. As long as it only lives there, an attacker can delete it.],
)

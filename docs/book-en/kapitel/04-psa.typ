#import "../lib.typ": *

#kapitel(
  [Pod Security Admission],
  ziel: [You decide which pods are allowed to start at all: a cluster-wide default, plus stricter or looser rules per namespace.],
  zeit: [45 minutes],
  braucht: [Chapter 3],
)

== The Bouncer

Pod Security Admission (PSA) checks every new pod before it is created. It is built into Kubernetes. You choose a level and a mode per namespace.

#tabelle(
  (auto, 1fr),
  ([Level], [Meaning]),
  [`privileged`], [No restrictions. For system components.],
  [`baseline`], [Blocks known dangers such as `privileged`, `hostNetwork`, `hostPath`.],
  [`restricted`], [The strictest: no root, capabilities dropped, seccomp required.],
)

#tabelle(
  (auto, 1fr),
  ([Mode], [Effect of a violation]),
  [`enforce`], [The pod is rejected.],
  [`audit`], [The pod starts, and the violation goes to the audit log.],
  [`warn`], [The pod starts, and `kubectl` shows a warning.],
)

#warum[
  PSA only checks *at creation time*. Running pods stay untouched, even if you tighten the level. A problem only shows up at the next restart. So check beforehand who a change would affect.
]

== Who Needs Which Level?

Falco has to watch the kernel and needs a privileged container with many `hostPath` mounts. `restricted` would reject it right away. The same goes for anything that inspects the node itself.

#tabelle(
  (auto, auto, 1fr),
  ([Namespace], [Level], [Reason]),
  [`kube-system`], [exempt], [Cilium, Traefik, CoreDNS need host access],
  [`monitoring`], [`privileged`], [node-exporter uses `hostNetwork` and `hostPID`, Alloy uses `hostPath`],
  [`falco`], [`privileged`], [eBPF driver, many `hostPath` mounts],
  [`trivy-system`], [`privileged`], [The node collector checks host files],
  [`demo`], [`restricted`], [Your applications],
  [all others], [`baseline`], [Cluster-wide default],
)

The default also applies to new namespaces. Anyone who needs an exemption has to ask for it explicitly. That is the principle of *secure by default*.

== Test the Effect Before It Hits

#cmd("Mac")[```bash
kubectl label --dry-run=server --overwrite ns --all \
  pod-security.kubernetes.io/enforce=baseline
```][`--dry-run=server` lets the API server check the change without saving it. It warns you about every running pod that violates `baseline`.]

#pruefe[
  You get warnings for `kube-system`, for example because of `hostPath` or `hostNetwork`. This namespace needs its exemption. No other host-level services are running yet; they come later.
]

== Set the Exemptions

Set the exemptions *first*, including for services that only arrive later. Otherwise the new default rejects them as soon as they try to start.

#cmd("Mac")[```bash
kubectl create namespace monitoring
kubectl create namespace falco
kubectl create namespace trivy-system
```][Creates the three namespaces now, so they have their level before the first pods start in them.]

#cmd("Mac")[```bash
kubectl label namespace monitoring \
  pod-security.kubernetes.io/enforce=privileged
```][Allows everything in `monitoring`. Labels on the namespace override the cluster-wide default.]

#cmd("Mac")[```bash
kubectl label namespace monitoring \
  pod-security.kubernetes.io/warn=baseline \
  pod-security.kubernetes.io/audit=baseline
```][Blocks nothing, but makes violations visible. That keeps the exemption traceable.]

#cmd("Mac")[```bash
kubectl label namespace falco trivy-system \
  pod-security.kubernetes.io/enforce=privileged
```][Gives both the level they need.]

== Set the Cluster Default

#datei("security/psa.yaml", ```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: baseline
        enforce-version: latest
        audit: restricted
        audit-version: latest
        warn: restricted
        warn-version: latest
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces:
          - kube-system
```, erklaerung: [
  The default enforces `baseline` and reports everything that would not meet `restricted`. Only `kube-system` is fully exempt. Exemptions apply to whole namespaces, so keep the list short.
])

#cmd("Mac")[```bash
scp security/psa.yaml <user>@172.16.0.136:/tmp/psa.yaml
```][Copies the file to the node.]

Now uncomment these two lines in `k3s/config.yaml`. The `audit-` lines stay commented out; they are for Chapter 9.

#datei("k3s/config.yaml (excerpt)", ```yaml
kube-apiserver-arg:
  - "admission-control-config-file=/var/lib/rancher/k3s/server/psa.yaml"
```)

#cmd("Mac")[```bash
scp k3s/config.yaml <user>@172.16.0.136:/tmp/config.yaml
ssh <user>@172.16.0.136
```][Transfers the configuration and opens the session.]

#cmd("Node")[```bash
sudo install -m 600 -o root -g root /tmp/psa.yaml \
  /var/lib/rancher/k3s/server/psa.yaml
```][The file has to be in place before the restart.]

#cmd("Node")[```bash
sudo install -m 600 -o root -g root /tmp/config.yaml \
  /etc/rancher/k3s/config.yaml
rm /tmp/psa.yaml /tmp/config.yaml
sudo systemctl restart k3s
```][Installs the configuration and restarts k3s.]

#cmd("Node")[```bash
exit
```][Back to the Mac.]

== Test the Default

#cmd("Mac")[```bash
kubectl create namespace psa-test
```][A fresh namespace without a label, so the cluster default applies here.]

#datei("security/psa-boese.yaml", ```yaml
apiVersion: v1
kind: Pod
metadata:
  name: boese
  namespace: psa-test
spec:
  hostNetwork: true
  containers:
    - name: c
      image: busybox:1.36
      command: [sleep, "3600"]
      securityContext:
        privileged: true
```)

#cmd("Mac")[```bash
kubectl apply -f security/psa-boese.yaml
```][Expected: `Forbidden`. The message names both violations, `hostNetwork` and `privileged`.]

#cmd("Mac")[```bash
kubectl delete namespace psa-test
```][Cleans up.]

== Set `demo` to `restricted`

#cmd("Mac")[```bash
kubectl label namespace demo \
  pod-security.kubernetes.io/enforce=restricted
```][From now on, `demo` only runs pods that follow every rule of the strictest level.]

#cmd("Mac")[```bash
kubectl run test --image=nginx:1.29-alpine -n demo
```][Expected: `Forbidden`. Read the message carefully, because it tells you which fields are missing.]

#tabelle(
  (auto, 1fr),
  ([Field in the pod], [Purpose]),
  [`allowPrivilegeEscalation: false`], [Processes cannot gain extra privileges],
  [`capabilities.drop: [ALL]`], [Removes all special Linux privileges],
  [`runAsNonRoot: true`], [The container does not start as root],
  [`seccompProfile.type: RuntimeDefault`], [Blocks rare, dangerous system calls],
)

Standard `nginx` starts as root and therefore does not run here. You need an image that works without root:

#datei("security/psa-gut.yaml", ```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gut
  namespace: demo
  labels:
    team: plattform
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: web
      image: nginxinc/nginx-unprivileged:1.29-alpine
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
      resources:
        limits:
          memory: 64Mi
```)

#cmd("Mac")[```bash
kubectl apply -f security/psa-gut.yaml
kubectl get pod gut -n demo
```][This pod meets all the rules and runs.]

#cmd("Mac")[```bash
kubectl delete pod gut -n demo
```][Cleans up.]

#aufgabe[
  Start a standard `nginx` pod in a new namespace. It passes `baseline` but violates `restricted`. Which warning does `kubectl` show? The `audit` mode writes the same violation to the audit log, which you enable in Chapter 9.
]

#gelernt(
  [PSA only checks at creation time; running pods stay untouched.],
  [`--dry-run=server` shows in advance who a tighter level would affect.],
  [Set the exemptions first, then tighten the default.],
  [The `baseline` default makes new namespaces safer automatically.],
  [`restricted` needs four settings and an image that runs without root.],
)

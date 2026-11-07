#import "../lib.typ": *

#kapitel(
  [Kyverno: Your Own Rules],
  ziel: [You write policies that PSA does not know about, test them locally and roll them out step by step.],
  zeit: [60 minutes],
  braucht: [Chapter 4],
)

== Why Kyverno When You Have PSA?

PSA only knows three fixed levels and says nothing about *what* should apply in your cluster. Kyverno fills exactly that gap, for example:

- Images need a fixed tag, not `latest`.
- Every container needs a memory limit.
- Every pod carries the `team` label.

Kyverno is an admission webhook: the API server asks it for permission before saving. A rule is a `ValidatingPolicy` with a CEL expression. CEL is the expression language that Kubernetes itself uses as well.

#falle[
  Many guides still use `kind: ClusterPolicy`. That has been deprecated since Kyverno 1.19 and will be removed in 1.20. Use `ValidatingPolicy` with `apiVersion: policies.kyverno.io/v1`.
]

== Installing

#datei("kyverno/values.yaml", ```yaml
admissionController:
  replicas: 1
backgroundController:
  replicas: 1
cleanupController:
  replicas: 1
reportsController:
  replicas: 1
```, erklaerung: [
  One node, so one instance each. That saves RAM, but it also means: if the pod fails, Kyverno is briefly unreachable.
])

#cmd("Mac")[```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
```][Adds the repository.]

#cmd("Mac")[```bash
helm upgrade --install kyverno kyverno/kyverno \
  -n kyverno --create-namespace --version 3.9.2 \
  -f kyverno/values.yaml --wait --timeout 5m
```][Chart 3.9.2 contains Kyverno 1.19.2. The new namespace automatically gets the `baseline` level.]

#cmd("Mac")[```bash
kubectl get pods -n kyverno
```][Four controllers should be running.]

== Writing the Policies

#datei("security/kyverno/policies.yaml", ```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationActions: [Audit]
  matchConstraints:
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values: [kube-system, kyverno]
    resourceRules:
      - apiGroups: ['']
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
  validations:
    - message: Images need a fixed tag, not latest.
      expression: >-
        object.spec.containers.all(c,
          c.image.contains(':') && !c.image.endsWith(':latest'))
---
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: require-memory-limit
spec:
  validationActions: [Audit]
  matchConstraints:
    namespaceSelector:
      matchLabels:
        security.k3s2/tier: app
    resourceRules:
      - apiGroups: ['']
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
  validations:
    - message: Every container needs a memory limit.
      expression: >-
        object.spec.containers.all(c,
          c.?resources.?limits.?memory.orValue('') != '')
---
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: require-team-label
spec:
  validationActions: [Audit]
  matchConstraints:
    namespaceSelector:
      matchLabels:
        security.k3s2/tier: app
    resourceRules:
      - apiGroups: ['']
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
  validations:
    - message: The team label is missing.
      expression: >-
        object.metadata.?labels.team.orValue('') != ''
```)

Here is how to read the rule:

- `validationActions: [Audit]` only reports. `Deny` would block.
- `matchConstraints` defines who the rule applies to. The first rule applies almost everywhere, the others only in namespaces with the label `security.k3s2/tier=app`.
- `expression` is the CEL expression. It must evaluate to `true` for the pod to pass.
- `.all(c, ...)` checks every container, and `?.` safely accesses fields that may be missing. `orValue('')` then provides a fallback value.

#falle[
  The `disallow-latest-tag` rule checks for a colon. An image like `registry:5000/app` does have a colon, but no tag, and would slip through. That is fine for a lab; in production you would check for digests right away.
]

== Testing Locally, Without a Cluster

The Kyverno CLI runs policies without a cluster. That way you find mistakes before they bother anyone.

#datei("security/kyverno/test/gut.yaml", ```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gut
  namespace: demo
  labels:
    team: plattform
spec:
  containers:
    - name: web
      image: nginxinc/nginx-unprivileged:1.29-alpine
      resources:
        limits:
          memory: 64Mi
```)

#datei("security/kyverno/test/schlecht.yaml", ```yaml
apiVersion: v1
kind: Pod
metadata:
  name: schlecht
  namespace: demo
spec:
  containers:
    - name: web
      image: nginx:latest
```)

#datei("security/kyverno/test/values.yaml", ```yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Values
namespaceSelector:
  - name: demo
    labels:
      kubernetes.io/metadata.name: demo
      security.k3s2/tier: app
```, erklaerung: [
  Offline, the CLI knows nothing about namespaces. This file tells it which labels `demo` has.
])

#cmd("Mac")[```bash
kyverno apply security/kyverno/policies.yaml \
  --resource security/kyverno/test/gut.yaml \
  --values-file security/kyverno/test/values.yaml
```][Checks the good pod. You already installed the CLI (`brew install kyverno`).]

#pruefe[
  The result is `pass: 3, fail: 0`. For the `schlecht.yaml` example it is `pass: 0, fail: 3`, each with your error message. That is exactly what came out when this book was tested.
]

#cmd("Mac")[```bash
kyverno apply security/kyverno/policies.yaml \
  --resource security/kyverno/test/schlecht.yaml \
  --values-file security/kyverno/test/values.yaml
```][Checks the bad pod. All three rules should fire.]

== Starting in Audit Mode

#cmd("Mac")[```bash
kubectl apply -f security/kyverno/policies.yaml
```][Loads the three rules. They do not block anything yet.]

#cmd("Mac")[```bash
kubectl get vpol
```][`vpol` is the short form of `validatingpolicies`. All three should be ready.]

#cmd("Mac")[```bash
kubectl get polr -A
```][`polr` stands for `policyreports`. Kyverno also checks existing pods in the background and writes the result here. The `PASS` and `FAIL` columns show the status per resource.]

#cmd("Mac")[```bash
kubectl get polr -A -o json | jq -r '
  .items[].results[]?
  | select(.result == "fail")
  | "\(.policy): \(.message)"' | sort | uniq -c
```][Summarizes all violations. This is your to-do list before you enforce anything.]

== Enforcing

If the report looks good, you switch over. Nothing is running in `demo` right now, so you can start safely.

In `security/kyverno/policies.yaml`, change the line for `require-memory-limit` and `require-team-label` to `validationActions: [Deny]`. The `latest` tag rule stays on `Audit` for now, because it affects almost the entire cluster.

#cmd("Mac")[```bash
kubectl apply -f security/kyverno/policies.yaml
```][Turns on enforcement.]

#cmd("Mac")[```bash
kubectl run verboten -n demo \
  --image=nginxinc/nginx-unprivileged:1.29-alpine
```][Expect a rejection, probably from PSA first, because the `restricted` fields are missing here too. This nicely shows that both layers check independently.]

#cmd("Mac")[```bash
kubectl apply --dry-run=server -f security/kyverno/test/gut.yaml
```][Checks the pod from the test without creating it. PSA rejects it, because the file does not meet `restricted`. Kyverno alone would have let it through.]

#falle[
  The rules apply to pods. A deployment with a violation is often accepted at first, and only its pods fail. The deployment then shows `0/1`, and the cause is in the events: `kubectl get events -n demo`. Whether Kyverno also rejects the deployment directly is controlled by `spec.autogen`; see the docs.
]

== When Kyverno Fails

A webhook can get in the cluster's way: if it is set to reject requests and is unreachable, no pod starts anymore. So remember the emergency exit:

#cmd("Mac")[```bash
kubectl get validatingwebhookconfigurations
```][Lists all webhooks. In an emergency, you delete the affected entry with `kubectl delete`. Kyverno recreates it on its next start.]

#aufgabe[
  Write a fourth rule, `disallow-default-sa`: pods in app namespaces must not use the `default` ServiceAccount. Hint: the field is called `object.spec.serviceAccountName`, and it may also be missing entirely. Test it with the CLI first and extend your test pods.
]

#gelernt(
  [PSA provides the foundation, Kyverno the rules for your cluster.],
  [`ValidatingPolicy` replaces the deprecated `ClusterPolicy`.],
  [With the CLI you test policies locally, without a cluster.],
  [Policy reports show you in advance what `Deny` would hit.],
  [Admission webhooks are critical for the cluster, so know your emergency exit.],
)

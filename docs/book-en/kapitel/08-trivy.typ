#import "../lib.typ": *

#kapitel(
  [Trivy Operator: Scanning Regularly],
  ziel: [The cluster checks itself for known vulnerabilities and misconfigurations, and you analyze the reports.],
  zeit: [45 minutes],
  braucht: [Chapter 4],
)

== Finding Known Weaknesses

An image that is clean today can be vulnerable tomorrow, because a new flaw becomes known. So scanning once is not enough. The Trivy Operator watches the cluster and scans everything that runs. It stores the results as Kubernetes objects.

#tabelle(
  (auto, auto, 1fr),
  ([Report], [Short name], [Content]),
  [`VulnerabilityReport`], [`vuln`], [Known CVEs in images],
  [`ConfigAuditReport`], [`configaudit`], [Insecure pod settings],
  [`ExposedSecretReport`], [`exposedsecret`], [Passwords stored in the image],
  [`RbacAssessmentReport`], [`rbacassessment`], [Roles that are too broad],
  [`InfraAssessmentReport`], [`infraassessment`], [Node settings],
  [`ClusterComplianceReport`], [`compliance`], [Checks against standards such as CIS],
)

#warum[
  Because the reports are Kubernetes objects, RBAC, `kubectl` and Prometheus apply to them. You don't need a separate scan server, and each team sees the reports for its own namespace.
]

== Installing

#datei("trivy/values.yaml", ```yaml
# Chapter 10 turns this on once Prometheus is running.
serviceMonitor:
  enabled: false

trivy:
  # Only show vulnerabilities that have a fix
  ignoreUnfixed: true
  severity: HIGH,CRITICAL

operator:
  # Only one scan at a time, to spare the node
  scanJobsConcurrentLimit: 1
  # Recreate reports after 24 hours
  scannerReportTTL: 24h
```, erklaerung: [
  `ignoreUnfixed` hides findings you can't do anything about right now. `scanJobsConcurrentLimit: 1` matters on 8 GB of RAM: the default of 10 could overload your node. `scannerReportTTL` makes sure a new scan runs every day.
])

#cmd("Mac")[```bash
helm repo add aqua https://aquasecurity.github.io/helm-charts/
helm repo update
```][Adds the repository.]

#cmd("Mac")[```bash
helm upgrade --install trivy-operator aqua/trivy-operator \
  -n trivy-system --version 0.38.1 \
  -f trivy/values.yaml --wait --timeout 5m
```][Installs the operator into the prepared namespace. `trivy-system` has had the `privileged` level since Chapter 4, because the node collector checks host files.]

#cmd("Mac")[```bash
kubectl get jobs -n trivy-system
```][The operator creates a short-lived scan job for each workload. On a fresh start it takes a while until all of them are done, and the vulnerability database is downloaded once.]

== Letting It Find an Old Image

#cmd("Mac")[```bash
kubectl create deployment altlast -n falco-lab --image=nginx:1.21.6
```][Starts an image from 2022. It contains plenty of known vulnerabilities. The `falco-lab` namespace allows root.]

#cmd("Mac")[```bash
kubectl get vuln -n falco-lab -o wide
```][After a few minutes a report appears. The columns show the count per severity. As long as the list is empty, the scan is still running.]

#cmd("Mac")[```bash
kubectl get vuln -n falco-lab -o json | jq -r '
  .items[].report.vulnerabilities[]
  | select(.severity == "CRITICAL")
  | "\(.vulnerabilityID)  \(.resource)  fix: \(.fixedVersion)"
' | sort -u | head -20
```][Shows the critical vulnerabilities with the package and the version that fixes them.]

#pruefe[
  You see a list of CVE numbers, for example for `openssl` or `zlib`, each with a `fix:` version. The exact list changes with the database.
]

#aufgabe[
  Update the deployment: `kubectl set image deploy/altlast -n falco-lab altlast=nginx:1.29-alpine`. How many critical vulnerabilities does the new report show? In practice this is the most common way to close vulnerabilities: don't patch, roll out a new image.
]

== Finding Misconfigurations

#cmd("Mac")[```bash
kubectl get configaudit -A -o wide
```][Shows the number of findings per workload. Your pod in `demo` should score much better than `opfer` in `falco-lab`, because it meets `restricted`.]

#cmd("Mac")[```bash
kubectl get configaudit -n falco-lab -o json | jq -r '
  .items[].report.checks[]
  | select(.success == false)
  | "\(.severity)  \(.checkID)  \(.title)"
' | sort -u
```][Lists all failed checks. Many of them match exactly the rules you know from Chapter 4.]

#cmd("Mac")[```bash
kubectl get rbacassessment -A -o wide
```][Rates your roles. Here you see how Trivy assesses the permissions from Chapter 3.]

#cmd("Mac")[```bash
kubectl get exposedsecret -A
```][Shows secrets that someone baked into an image. This list should be empty.]

#falle[
  The infra checks often expect the standard paths of `kubeadm`. In k3s the API server runs inside the k3s process, so `infraassessment` produces some false positives. Check such findings before you act, and compare them with the #link("https://docs.k3s.io/security/hardening-guide")[k3s hardening guide].
]

== The Rule That Ties It All Together

Chapter 5 and this chapter fit together: Trivy reports that an image is vulnerable, and Kyverno can use an `ImageValidatingPolicy` to require that only verified images start. That leads to signed images and makes a good next learning project.

#gelernt(
  [Scanning is not a one-time event, because new vulnerabilities affect old images too.],
  [Trivy stores reports as Kubernetes objects, so RBAC and `kubectl` apply.],
  [On small nodes, `scanJobsConcurrentLimit` limits the load.],
  [You usually close vulnerabilities with a new image, not with a patch inside the container.],
)

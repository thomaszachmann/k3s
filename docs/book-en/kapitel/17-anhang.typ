#import "../lib.typ": *
#set heading(numbering: none)

#pagebreak(to: "odd")
#heading(level: 1, numbering: none)[Appendix]

== Versions

As of November 6, 2026. Update deliberately and one at a time, not everything at once.

#tabelle(
  (1fr, auto, auto),
  ([Component], [Helm chart], [App version]),
  [k3s (channel `v1.36`)], [–], [v1.36.6+k3s1],
  [Cilium], [1.20.4], [1.20.4],
  [kube-prometheus-stack], [92.18.0], [from your README],
  [Loki (`grafana-community/loki`)], [21.0.0], [3.7.9],
  [Tempo (`grafana-community/tempo`)], [3.2.1], [3.1.1],
  [Alloy (`grafana/alloy`)], [1.15.0], [v1.21.3],
  [Kyverno], [3.9.2], [v1.19.2],
  [Falco], [9.2.2], [0.45.2],
  [Trivy Operator], [0.38.1], [0.36.1],
  [cert-manager (optional)], [v1.21.3], [v1.21.3],
  [OpenBao (optional)], [0.30.7], [v2.7.2],
  [External Secrets Operator (optional)], [2.14.0], [v2.14.0],
)

== Your Repo at the End

```text
k3s/
├── k3s/config.yaml               Node configuration
├── cilium/
│   ├── values.yaml
│   └── metrics-values.yaml
├── monitoring/
│   ├── kps-k3s-values.yaml
│   ├── loki-values.yaml
│   ├── tempo-values.yaml
│   ├── alloy-values.yaml
│   └── config.alloy
├── seaweedfs/                    Existing
├── kyverno/values.yaml
├── falco/values.yaml
├── trivy/values.yaml
├── openbao/values.yaml
└── security/
    ├── audit-policy.yaml
    ├── psa.yaml
    ├── alerts.yaml
    ├── tracing.yaml
    ├── rbac/       ServiceAccounts
    ├── kyverno/    Policies and tests
    ├── netpol/     Cilium policies
    ├── demo/       Lab application
    ├── tls/        Optional: CA, certificates
    └── secrets/    Optional: ExternalSecrets
```

No unseal keys, tokens or private keys may be stored in this repo. Check this before every commit.

== Cheat Sheet

#tabelle(
  (1fr, 1fr),
  ([Question], [Command]),
  [May X do this?], [`kubectl auth can-i <verb> <res> --as=<X>`],
  [What may X do?], [`kubectl auth can-i --list --as=<X>`],
  [Who would a PSA change affect?], [`kubectl label --dry-run=server ...`],
  [Which policies exist?], [`kubectl get vpol`],
  [Which violations exist?], [`kubectl get polr -A`],
  [What was blocked?], [`hubble observe --verdict DROPPED`],
  [Which CVEs exist?], [`kubectl get vuln -A -o wide`],
)

For `hubble` and `cilium-dbg`, always use the prefix:

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent --
```

== LogQL Cheat Sheet

#tabelle(
  (1fr, 1fr),
  ([Goal], [Query]),
  [Logs of a namespace], [`{namespace="demo"}`],
  [Contains text], [`{namespace="demo"} |= "error"`],
  [Excludes text], [`{namespace="demo"} != "health"`],
  [Parse JSON], [`{job="audit"} | json`],
  [Filter a field], [`... | json | verb="delete"`],
  [Count], [`count_over_time({...}[5m])`],
)

== Official Documentation

- Cilium: #link("https://docs.cilium.io/en/stable/")
- k3s hardening: #link("https://docs.k3s.io/security/hardening-guide")
- Kubernetes Pod Security: #link("https://kubernetes.io/docs/concepts/security/pod-security-standards/")
- Kubernetes audit: #link("https://kubernetes.io/docs/tasks/debug-application-cluster/audit/")
- Kubernetes traces: #link("https://kubernetes.io/docs/concepts/cluster-administration/system-traces/")
- Kubernetes RBAC: #link("https://kubernetes.io/docs/reference/access-authn-authz/rbac/")
- Kyverno: #link("https://kyverno.io/docs/")
- Falco: #link("https://falco.org/docs/")
- Trivy Operator: #link("https://aquasecurity.github.io/trivy-operator/")
- cert-manager: #link("https://cert-manager.io/docs/")
- OpenBao: #link("https://openbao.org/docs/")
- External Secrets: #link("https://external-secrets.io/")
- Loki: #link("https://grafana.com/docs/loki/latest/")
- Tempo: #link("https://grafana.com/docs/tempo/latest/")
- Alloy: #link("https://grafana.com/docs/alloy/latest/")

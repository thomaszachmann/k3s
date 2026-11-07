#import "../lib.typ": *
#set heading(numbering: none)

#pagebreak(to: "odd")
#heading(level: 1, numbering: none)[Anhang]

== Versionen

Stand 6. November 2026. Aktualisiere bewusst und einzeln, nicht alles gleichzeitig.

#tabelle(
  (1fr, auto, auto),
  ([Komponente], [Helm-Chart], [App-Version]),
  [k3s (Kanal `v1.36`)], [–], [v1.36.6+k3s1],
  [Cilium], [1.20.4], [1.20.4],
  [kube-prometheus-stack], [92.18.0], [aus deinem README],
  [Loki (`grafana-community/loki`)], [21.0.0], [3.7.9],
  [Tempo (`grafana-community/tempo`)], [3.2.1], [3.1.1],
  [Alloy (`grafana/alloy`)], [1.15.0], [v1.21.3],
  [Kyverno], [3.9.2], [v1.19.2],
  [Falco], [9.2.2], [0.45.2],
  [Trivy Operator], [0.38.1], [0.36.1],
  [cert-manager (Zusatz)], [v1.21.3], [v1.21.3],
  [OpenBao (Zusatz)], [0.30.7], [v2.7.2],
  [External Secrets Operator (Zusatz)], [2.14.0], [v2.14.0],
)

== Dein Repo am Ende

```text
k3s/
├── k3s/config.yaml               Node-Konfiguration
├── cilium/
│   ├── values.yaml
│   └── metrics-values.yaml
├── monitoring/
│   ├── kps-k3s-values.yaml
│   ├── loki-values.yaml
│   ├── tempo-values.yaml
│   ├── alloy-values.yaml
│   └── config.alloy
├── seaweedfs/                    Bestehend
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
    ├── kyverno/    Policies und Tests
    ├── netpol/     Cilium-Policies
    ├── demo/       Lab-Anwendung
    ├── tls/        Zusatz: CA, Zertifikate
    └── secrets/    Zusatz: ExternalSecrets
```

In diesem Repo dürfen keine Unseal Keys, Tokens oder privaten Schlüssel liegen. Prüfe das vor jedem Commit.

== Spickzettel

#tabelle(
  (1fr, 1fr),
  ([Frage], [Befehl]),
  [Darf X das?], [`kubectl auth can-i <verb> <res> --as=<X>`],
  [Was darf X alles?], [`kubectl auth can-i --list --as=<X>`],
  [Wen träfe eine PSA-Änderung?], [`kubectl label --dry-run=server ...`],
  [Welche Policies gibt es?], [`kubectl get vpol`],
  [Welche Verstöße gibt es?], [`kubectl get polr -A`],
  [Was wurde blockiert?], [`hubble observe --verdict DROPPED`],
  [Welche CVEs gibt es?], [`kubectl get vuln -A -o wide`],
)

Für `hubble` und `cilium-dbg` gilt jeweils das Präfix:

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent --
```

== LogQL-Spickzettel

#tabelle(
  (1fr, 1fr),
  ([Ziel], [Abfrage]),
  [Logs eines Namespace], [`{namespace="demo"}`],
  [Text enthalten], [`{namespace="demo"} |= "error"`],
  [Text ausschließen], [`{namespace="demo"} != "health"`],
  [JSON zerlegen], [`{job="audit"} | json`],
  [Feld filtern], [`... | json | verb="delete"`],
  [Zählen], [`count_over_time({...}[5m])`],
)

== Offizielle Dokumentation

- Cilium: #link("https://docs.cilium.io/en/stable/")
- k3s Hardening: #link("https://docs.k3s.io/security/hardening-guide")
- Kubernetes Pod Security: #link("https://kubernetes.io/docs/concepts/security/pod-security-standards/")
- Kubernetes Audit: #link("https://kubernetes.io/docs/tasks/debug-application-cluster/audit/")
- Kubernetes Traces: #link("https://kubernetes.io/docs/concepts/cluster-administration/system-traces/")
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

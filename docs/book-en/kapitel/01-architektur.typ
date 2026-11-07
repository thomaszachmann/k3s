#import "../lib.typ": *

#kapitel(
  [The Architecture at a Glance],
  ziel: [You understand which layer stops which attack and why the build follows exactly this order.],
  zeit: [20 minutes of reading],
)

== The Core Principle: Defense in Layers

No single measure is perfect. An attacker might find a hole in your web application, and suddenly there is code running in your cluster. Then the question is no longer whether something happened, but how far the attacker gets and whether you notice.

That is why you build several independent layers. Each one assumes that the one before it has failed. The journey of an attack shows how they work together:

#tabelle(
  (auto, 1fr, auto),
  ([Phase], [What the attacker tries], [Who steps in]),
  [Prepare], [A vulnerable image runs in the cluster], [Trivy, Kyverno],
  [Break in], [They exploit the hole and land in the pod], [Falco reports it],
  [Spread], [They call other services or the internet], [Cilium blocks],
  [Escalate privileges], [They use the service account token], [RBAC limits],
  [Break out], [They start a privileged pod], [PSA, Kyverno],
  [Grab the loot], [They search for passwords], [RBAC, audit log],
  [Cover tracks], [They delete local logs], [Loki keeps them elsewhere],
)

== The Four Levels of Your Architecture

It helps to order the tools by the point in time at which they act:

#tabelle(
  (auto, 1fr, 1fr),
  ([Level], [Question], [Tools]),
  [*Before start*], [Is this allowed into the cluster at all?], [RBAC, PSA, Kyverno],
  [*At runtime*], [What may it do while it runs?], [Cilium, Falco],
  [*Continuously*], [Where are known weaknesses?], [Trivy],
  [*Evidence*], [What actually happened?], [Audit logs, Grafana, Loki, Tempo],
)

This also shows you where tools overlap and where they do not:

- *PSA and Kyverno* both check at creation time. PSA knows only three fixed levels, Kyverno understands any custom rules you write. PSA is the simple foundation, Kyverno the addition.
- *Falco and Cilium* both act at runtime. Falco observes and reports, Cilium blocks. So Falco cannot prevent anything, but it sees things that never show up on the network.
- *Trivy and Kyverno* complement each other. Trivy finds weaknesses, Kyverno can prevent certain images from starting at all.
- *Loki and Tempo* store different things: Loki the log lines, Tempo the path of a single request through the system.

== How This Book Is Structured

You work from the inside out: first the permissions, then the rules, then the network, then detection, and at the end you bring everything together in one place.

#tabelle(
  (auto, 1fr, auto),
  ([Ch.], [Building block], [Role]),
  [2], [k3s and Cilium on the Ubuntu VM, kubeconfig], [Foundation],
  [3], [RBAC], [Access],
  [4], [Pod Security Admission], [Admission],
  [5], [Kyverno], [Admission],
  [6], [Cilium default deny], [Runtime],
  [7], [Falco], [Runtime],
  [8], [Trivy Operator], [Continuous],
  [9], [Kubernetes audit logs], [Evidence],
  [10], [Grafana, Prometheus, Loki], [Central view],
  [11], [Tempo], [Central view],
  [12], [Dashboard and attack exercise], [Bringing it together],
  [13], [Operations and troubleshooting], [Ongoing operations],
)

Chapters 14 to 16 are an optional part on TLS and secrets with cert-manager, OpenBao and External Secrets. You do not need them for the main part.

=== Does This Work Without Monitoring at the Start?

Yes. When you lock things down, you need to see what is being blocked right now, and you can do that from the start:

#tabelle(
  (auto, 1fr),
  ([Chapter], [Your view while Grafana is still missing]),
  [RBAC], [`kubectl auth can-i`],
  [PSA], [Warnings from `kubectl`, `--dry-run=server`],
  [Kyverno], [`kubectl get polr -A`],
  [Cilium], [`hubble observe --verdict DROPPED`],
  [Falco], [`kubectl logs`],
  [Trivy], [`kubectl get vuln -A`],
  [Audit logs], [`jq` directly on the node],
)

There is one thing you have to plan ahead for: monitoring services need host access, so the `monitoring` namespace already gets its PSA exemption in Chapter 4, long before anything runs there.

=== The Rule in Every Chapter

Regardless of the tool, the same sequence always applies:

+ *Report.* Rules run in audit mode and block nothing.
+ *Evaluate.* You read the reports and adjust the rules.
+ *Enforce.* Only now is anything actually blocked.

== The Resource Plan

Your VM has 8 GB of RAM. The table shows rough estimates of memory usage, not measurements. Compare them with `kubectl top pods -A` once everything is running.

#tabelle(
  (1fr, auto),
  ([Component], [RAM (estimated)]),
  [k3s itself, CoreDNS, Traefik, Metrics Server], [1.0 GB],
  [Cilium, Hubble], [0.5 GB],
  [Kyverno], [0.4 GB],
  [Falco], [0.3 GB],
  [Trivy Operator (more for short periods during scans)], [0.3 GB],
  [Prometheus, Grafana, Alertmanager, exporters], [1.5 GB],
  [SeaweedFS, Loki, Alloy], [0.8 GB],
  [Tempo], [0.3 GB],
  [*Total main part*], [*about 5.4 GB*],
)

That leaves room for your lab application, but not much. The optional part needs about 0.3 GB more. You let Trivy run only one scan at a time; this is already configured in Chapter 8.

#aufgabe[
  Take your own scenario: an attacker has a remote shell in the `frontend` pod. Write down three things they would try next, and note which layer should react in each case. In Chapter 12 you play through exactly this and compare.
]

#gelernt(
  [Every layer assumes that the previous one has failed.],
  [Tools can be ordered by when they act: before start, at runtime, continuously and after the fact.],
  [Visibility does not start with Grafana: `kubectl` and Hubble are enough at the beginning.],
  [Report first, then evaluate, and enforce last.],
)

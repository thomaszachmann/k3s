#import "../lib.typ": *
#set heading(numbering: none)

#heading(level: 1, numbering: none, outlined: false)[Contents]

#{
  show outline.entry.where(level: 1): it => {
    v(0.55em, weak: true)
    strong(it)
  }
  outline(title: none, depth: 2, indent: 1.2em)
}

#pagebreak(to: "odd")
#heading(level: 1, numbering: none)[How to Use This Book]

Installing individual security tools is quick. The hard part is something else: understanding which tool closes which gap, where they overlap, and what happens when one of them fails. That is exactly what you learn here, on your own cluster `k3s2`.

You build the architecture layer by layer. Every chapter follows the same flow: first you learn which problem is being solved. Then you type command after command, check the result, and try something yourself. There are no long scripts.

== First, Clone the Repo

Every configuration file this book refers to lives in a public repository on GitHub: #link("https://github.com/thomaszachmann/k3s")[github.com/thomaszachmann/k3s]. Get it before you start chapter 2.

#cmd("Mac")[```bash
git clone https://github.com/thomaszachmann/k3s.git
```][Downloads the repo with all its files into the new folder `k3s`.]

#cmd("Mac")[```bash
cd k3s
```][Switches to the root directory of the repo. All commands labeled *Mac* run from here.]

== Where You Run a Command

Every command carries a colored label. It tells you where you are right now:

#tabelle(
  (auto, 1fr),
  ([Label], [Meaning]),
  [#etikett(akzent, "Mac")], [Your terminal on the laptop, in the root directory of this repo.],
  [#etikett(warn, "Node")], [An SSH session on the VM `k3s2` (172.16.0.136).],
  [#etikett(lila, "Pod")], [A shell in a container that you opened beforehand with `kubectl exec`.],
)

Replace `<user>` with your SSH login each time. All paths like `security/psa.yaml` are relative to the repo.

== The Boxes

#warum[This is the background that helps you with the next problem.]
#falle[This is what typically goes wrong and how you recognize it.]
#pruefe[This is the expected result. If your output differs, do not move on. Clear up the difference first.]
#aufgabe[This is your turn. Think it through yourself first before you look things up.]

== What Was Tested and What Was Not

A book full of commands is only as good as its testing. So here is an honest account of how far that testing went.

*Tested on November 6, 2026:*
- All chart versions come from the official Helm repositories.
- All Helm values in this book were rendered with `helm template` against exactly these chart versions.
- The three Kyverno policies from Chapter 5 ran with the Kyverno CLI 1.19.1 against good and bad example pods.
- `ValidatingPolicy`, `ClusterSecretStore` and `ExternalSecret` were checked against the CRD schemas of the charts.
- The image tags of the lab workloads were looked up in the registry.

*Not tested:*
- The book was *not* run through end to end on a real cluster. The test cluster used while writing was still running Flannel and Kubernetes 1.37.
- The Alloy configuration, the Falco rules, the `CiliumNetworkPolicy` manifests, the TraceQL queries and the `bao` commands follow the official documentation, but did not run against the real programs.

So expect something to differ at some point. That is no reason to worry. It is practice: troubleshooting is part of learning, and Chapter 13 helps you with it.

== What You Need

- A fresh Ubuntu 24.04 VM with 4 CPUs, 8 GB RAM and at least 40 GB of disk. Nothing besides Ubuntu is installed.
- On the laptop: `kubectl`, `helm`, `jq`, `openssl`, `curl` and the Kyverno CLI.
- The cloned repo with `k3s/config.yaml` and `cilium/values.yaml`, plus `git` on your laptop.
- About two weekends of time, or one chapter per evening.

#hinweis("A Word on the Order", akzent, akzent-hell)[
  The book follows your plan: first RBAC and PSA, then Kyverno and network policies, then Falco, then Trivy, and finally audit logs with Grafana, Loki and Tempo. Chapter 1 explains why this works well even without early monitoring. cert-manager, OpenBao and External Secrets come at the end as an optional part.
]

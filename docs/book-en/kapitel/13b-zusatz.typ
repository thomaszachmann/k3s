#import "../lib.typ": *
#set heading(numbering: none)

#pagebreak(to: "odd")
#heading(level: 1, numbering: none)[Optional Part]

This is where the main part ends. The following three chapters are optional; you do not need them for anything before this point.

They close two gaps that the main part leaves open: services talk to each other unencrypted, and secrets are created by scripts, with no history and no record of who read them.

#tabelle(
  (auto, 1fr),
  ([Chapter], [Contents]),
  [14], [cert-manager: your own CA and automatic certificates],
  [15], [OpenBao: a vault with sealing, permissions and an audit log],
  [16], [External Secrets: vault values become Kubernetes secrets],
)

The chapters build on each other and require Chapter 10. After every restart of the VM you have to unseal OpenBao by hand; Chapter 15 explains this.

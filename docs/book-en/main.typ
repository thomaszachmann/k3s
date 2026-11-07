#import "lib.typ": *

#cover(
  [Securing\ Kubernetes],
  [An end-to-end security architecture on k3s, built one command at a time],
  [Thomas Zachmann],
  [As of November 6, 2026],
)

#show: buch

#set page(numbering: "1")
#counter(page).update(1)

#include "kapitel/00-vorwort.typ"
#include "kapitel/01-architektur.typ"
#include "kapitel/02-fundament.typ"
#include "kapitel/03-rbac.typ"
#include "kapitel/04-psa.typ"
#include "kapitel/05-kyverno.typ"
#include "kapitel/06-netzwerk.typ"
#include "kapitel/07-falco.typ"
#include "kapitel/08-trivy.typ"
#include "kapitel/09-audit.typ"
#include "kapitel/10-beobachten.typ"
#include "kapitel/11-tempo.typ"
#include "kapitel/12-zusammenfuehren.typ"
#include "kapitel/13-betrieb.typ"
#include "kapitel/13b-zusatz.typ"
#include "kapitel/14-cert-manager.typ"
#include "kapitel/15-openbao.typ"
#include "kapitel/16-eso.typ"
#include "kapitel/17-anhang.typ"

#rueckseite(
  [Securing Kubernetes],
  [
    An empty Ubuntu server, a laptop and one goal: a Kubernetes cluster you can trust.

    This book walks you through building an end-to-end security architecture on k3s, layer by layer. No long script to copy, but every command on its own, with an explanation of why it is needed and how you can tell that it worked.
  ],
  (
    ([Foundation], [k3s with Cilium instead of Flannel and kube-proxy]),
    ([Access], [RBAC and Pod Security Admission]),
    ([Policy], [Kyverno and Cilium default deny]),
    ([Runtime], [Falco detects suspicious behavior]),
    ([Vulnerabilities], [Trivy Operator scans continuously]),
    ([Evidence], [Audit logs, Grafana, Loki and Tempo]),
    ([Practice], [An attack drill against your own cluster]),
  ),
  [Hands-on guide · As of November 6, 2026],
  autor: [Thomas Zachmann],
  autor-bild: "bilder/autor.jpg",
  autor-text: [Author on Leanpub],
)

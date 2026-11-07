#import "lib.typ": *

#cover(
  [Kubernetes\ absichern],
  [Eine durchgängige Security-Architektur auf k3s, Befehl für Befehl aufgebaut],
  [Für Thomas Zachmann],
  [Stand: 6. November 2026],
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

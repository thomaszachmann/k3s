#import "../lib.typ": *

#kapitel(
  [Kyverno: Eigene Regeln],
  ziel: [Du schreibst Richtlinien, die PSA nicht kennt, testest sie lokal und führst sie stufenweise ein.],
  zeit: [60 Minuten],
  braucht: [Kapitel 4],
)

== Wofür Kyverno, wenn es PSA gibt?

PSA kennt nur drei feste Stufen und sagt nichts dazu, *was* in deinem Cluster gelten soll. Kyverno ergänzt genau das, zum Beispiel:

- Images brauchen einen festen Tag, kein `latest`.
- Jeder Container braucht ein Memory-Limit.
- Jeder Pod trägt das Label `team`.

Kyverno ist ein Admission-Webhook: Der API-Server fragt ihn vor dem Speichern um Erlaubnis. Eine Regel ist eine `ValidatingPolicy` mit einem CEL-Ausdruck. CEL ist die Ausdruckssprache, die auch Kubernetes selbst verwendet.

#falle[
  In vielen Anleitungen findest du noch `kind: ClusterPolicy`. Das ist seit Kyverno 1.19 veraltet und wird in 1.20 entfernt. Nutze `ValidatingPolicy` mit `apiVersion: policies.kyverno.io/v1`.
]

== Installieren

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
  Ein Node, also je eine Instanz. Das spart RAM, heißt aber auch: Fällt der Pod aus, ist Kyverno kurz nicht erreichbar.
])

#cmd("Mac")[```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
```][Trägt das Repository ein.]

#cmd("Mac")[```bash
helm upgrade --install kyverno kyverno/kyverno \
  -n kyverno --create-namespace --version 3.9.2 \
  -f kyverno/values.yaml --wait --timeout 5m
```][Chart 3.9.2 enthält Kyverno 1.19.2. Der neue Namespace bekommt automatisch die Stufe `baseline`.]

#cmd("Mac")[```bash
kubectl get pods -n kyverno
```][Vier Controller sollten laufen.]

== Die Richtlinien schreiben

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
    - message: Images brauchen einen festen Tag, nicht latest.
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
    - message: Jeder Container braucht ein Memory-Limit.
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
    - message: Das Label team fehlt.
      expression: >-
        object.metadata.?labels.team.orValue('') != ''
```)

So liest du die Regel:

- `validationActions: [Audit]` meldet nur. `Deny` würde blockieren.
- `matchConstraints` legt fest, wen die Regel betrifft. Die erste Regel gilt fast überall, die anderen nur in Namespaces mit dem Label `security.k3s2/tier=app`.
- `expression` ist der CEL-Ausdruck. Er muss `true` ergeben, damit der Pod besteht.
- `.all(c, ...)` prüft jeden Container, und `?.` greift sicher auf Felder zu, die fehlen dürfen. `orValue('')` liefert dann einen Ersatzwert.

#falle[
  Die Regel `disallow-latest-tag` prüft auf einen Doppelpunkt. Ein Image wie `registry:5000/app` hat zwar einen Doppelpunkt, aber keinen Tag, und würde durchrutschen. Für ein Lab reicht das, in Produktion würdest du gleich auf Digests prüfen.
]

== Lokal testen, ohne Cluster

Die Kyverno-CLI führt Policies ohne Cluster aus. So findest du Fehler, bevor sie jemanden stören.

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
  Offline kennt die CLI keine Namespaces. Diese Datei sagt ihr, welche Labels `demo` hat.
])

#cmd("Mac")[```bash
kyverno apply security/kyverno/policies.yaml \
  --resource security/kyverno/test/gut.yaml \
  --values-file security/kyverno/test/values.yaml
```][Prüft den guten Pod. Du hast die CLI bereits installiert (`brew install kyverno`).]

#pruefe[
  Das Ergebnis lautet `pass: 3, fail: 0`. Beim Beispiel `schlecht.yaml` lautet es `pass: 0, fail: 3`, jeweils mit deiner Fehlermeldung. Genau das kam bei der Prüfung dieses Buches heraus.
]

#cmd("Mac")[```bash
kyverno apply security/kyverno/policies.yaml \
  --resource security/kyverno/test/schlecht.yaml \
  --values-file security/kyverno/test/values.yaml
```][Prüft den schlechten Pod. Alle drei Regeln sollten anschlagen.]

== Im Audit-Modus starten

#cmd("Mac")[```bash
kubectl apply -f security/kyverno/policies.yaml
```][Lädt die drei Regeln. Sie blockieren noch nichts.]

#cmd("Mac")[```bash
kubectl get vpol
```][`vpol` ist die Kurzform für `validatingpolicies`. Alle drei sollten bereit sein.]

#cmd("Mac")[```bash
kubectl get polr -A
```][`polr` steht für `policyreports`. Kyverno prüft auch bestehende Pods im Hintergrund und schreibt das Ergebnis hierher. Die Spalten `PASS` und `FAIL` zeigen den Stand pro Ressource.]

#cmd("Mac")[```bash
kubectl get polr -A -o json | jq -r '
  .items[].results[]?
  | select(.result == "fail")
  | "\(.policy): \(.message)"' | sort | uniq -c
```][Fasst alle Verstöße zusammen. Das ist deine Arbeitsliste, bevor du irgendetwas durchsetzt.]

== Durchsetzen

Sieht der Bericht gut aus, stellst du um. Im Moment läuft in `demo` nichts, du kannst also gefahrlos beginnen.

Ändere in `security/kyverno/policies.yaml` bei `require-memory-limit` und `require-team-label` die Zeile auf `validationActions: [Deny]`. Die Regel zum `latest`-Tag bleibt vorerst auf `Audit`, weil sie fast den ganzen Cluster betrifft.

#cmd("Mac")[```bash
kubectl apply -f security/kyverno/policies.yaml
```][Aktiviert die Durchsetzung.]

#cmd("Mac")[```bash
kubectl run verboten -n demo \
  --image=nginxinc/nginx-unprivileged:1.29-alpine
```][Erwartet wird eine Ablehnung, zuerst vermutlich von PSA, denn hier fehlen auch die `restricted`-Felder. Das zeigt schön, dass beide Schichten unabhängig prüfen.]

#cmd("Mac")[```bash
kubectl apply --dry-run=server -f security/kyverno/test/gut.yaml
```][Prüft den Pod aus dem Test, ohne ihn anzulegen. PSA lehnt ihn ab, denn die Datei erfüllt `restricted` nicht. Kyverno allein hätte ihn durchgelassen.]

#falle[
  Die Regeln greifen bei Pods. Ein Deployment mit Verstoß wird oft erst einmal angenommen, und nur seine Pods scheitern. Das Deployment zeigt dann `0/1`, und die Ursache steht in den Events: `kubectl get events -n demo`. Ob Kyverno auch das Deployment direkt ablehnt, regelt `spec.autogen`, siehe Doku.
]

== Wenn Kyverno ausfällt

Ein Webhook kann den Cluster behindern: Ist er eingestellt, Anfragen abzulehnen, und nicht erreichbar, startet kein Pod mehr. Merke dir daher den Notausgang:

#cmd("Mac")[```bash
kubectl get validatingwebhookconfigurations
```][Listet alle Webhooks. Im Notfall löschst du den betroffenen Eintrag mit `kubectl delete`. Kyverno legt ihn beim nächsten Start wieder an.]

#aufgabe[
  Schreibe eine vierte Regel `disallow-default-sa`: Pods in App-Namespaces dürfen nicht den ServiceAccount `default` verwenden. Tipp: Das Feld heißt `object.spec.serviceAccountName`, und es darf auch ganz fehlen. Teste sie zuerst mit der CLI und ergänze deine Test-Pods.
]

#gelernt(
  [PSA liefert die Grundlage, Kyverno die Regeln deines Clusters.],
  [`ValidatingPolicy` ersetzt die veraltete `ClusterPolicy`.],
  [Mit der CLI testest du Policies lokal, ohne Cluster.],
  [Policy Reports zeigen dir vorab, was `Deny` treffen würde.],
  [Admission-Webhooks sind kritisch für den Cluster, kenne deinen Notausgang.],
)

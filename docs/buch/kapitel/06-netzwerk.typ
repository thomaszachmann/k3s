#import "../lib.typ": *

#kapitel(
  [Default-Deny mit Cilium],
  ziel: [Pods dürfen nur noch das, was du ausdrücklich erlaubst, und Hubble zeigt dir jede blockierte Verbindung.],
  zeit: [75 Minuten],
  braucht: [Kapitel 5],
)

== Warum Default-Deny

Standardmäßig darf in Kubernetes jeder Pod mit jedem anderen reden und ins Internet gehen. Für einen Angreifer ist das ideal: Ein Pod reicht, und er erreicht von dort alles. Bei *Default-Deny* drehst du das um: Nichts geht, außer dem, was du erlaubst.

Cilium arbeitet mit Identitäten statt IP-Adressen. Eine Regel sagt „Pods mit Label `app=frontend`“, nicht „10.42.0.7“. Das passt zu Kubernetes, wo sich IP-Adressen ständig ändern.

#warum[
  Sobald eine Policy einen Pod auswählt, gilt für die betroffene Richtung automatisch Default-Deny. Eine `ingress`-Regel sperrt also allen anderen eingehenden Verkehr. Das ist mächtig, aber auch die häufigste Ursache für Überraschungen.
]

== Die Lab-Anwendung

Deine Anwendung hat zwei Teile: Ein `backend` (Webserver) und ein `frontend`, das es aufruft. Beide erfüllen `restricted` und deine Kyverno-Regeln.

#datei("security/demo/app.yaml", ```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
        team: plattform
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: nginxinc/nginx-unprivileged:1.29-alpine
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          resources:
            limits:
              memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: demo
spec:
  selector:
    app: backend
  ports:
    - port: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
        team: plattform
    spec:
      serviceAccountName: frontend
      securityContext:
        runAsNonRoot: true
        runAsUser: 100
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: curl
          image: curlimages/curl:8.17.0
          command: [sleep, "86400"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          resources:
            limits:
              memory: 32Mi
```)

#cmd("Mac")[```bash
kubectl apply -f security/demo/app.yaml
kubectl get pods -n demo
```][Beide Pods sollten auf `Running` stehen. Falls nicht, zeigt `kubectl get events -n demo` den Grund.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://backend:8080/
```][Ruft das Backend auf. `-m 3` bricht nach drei Sekunden ab, `-w` gibt nur den Statuscode aus. Erwartet: `200`.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' https://example.com/
```][Auch das Internet ist erreichbar. Erwartet: `200`. Noch gibt es keine Regeln.]

== Schritt 1: Alles sperren außer DNS

#datei("security/netpol/01-default-deny.yaml", ```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: demo
spec:
  description: Alles sperren, nur DNS bleibt erlaubt
  endpointSelector: {}
  ingress:
    - {}
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
```, erklaerung: [
  `endpointSelector: {}` wählt alle Pods im Namespace. `ingress: [{}]` ist eine leere Regel: Sie erlaubt nichts, schaltet aber Default-Deny für eingehenden Verkehr ein. Beim `egress` bleibt nur DNS erlaubt, sonst könnte kein Pod mehr Namen auflösen. Die `dns`-Regel lässt Cilium die Anfragen mitlesen, das brauchst du gleich für Hostnamen.
])

#cmd("Mac")[```bash
kubectl apply -f security/netpol/01-default-deny.yaml
```][Ab sofort ist `demo` abgeriegelt.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://backend:8080/
```][Erwartet: `000` und ein Timeout. Der Name wird aufgelöst, die Verbindung aber still verworfen.]

#cmd("Mac")[```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --namespace demo --verdict DROPPED --last 10
```][Hubble zeigt dir genau, was blockiert wurde: Quelle, Ziel, Port und Grund.]

#pruefe[
  Eine Zeile zeigt `demo/frontend-... -> demo/backend-...:8080`, dazu `Policy denied` und `DROPPED`. Das ist dein wichtigstes Werkzeug bei Netzwerkproblemen: Statt zu raten, schaust du einfach nach.
]

== Schritt 2: Gezielt freigeben

Für eine Verbindung braucht es zwei Regeln: Das Frontend muss senden dürfen, und das Backend muss empfangen dürfen.

#datei("security/netpol/02-frontend-backend.yaml", ```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: frontend-darf-senden
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  egress:
    - toEndpoints:
        - matchLabels:
            app: backend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: backend-darf-empfangen
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
```, erklaerung: [
  Policies addieren sich. Die Sperre bleibt bestehen, diese Regeln fügen nur Ausnahmen hinzu. Ohne Namespace-Angabe gelten die Labels nur im eigenen Namespace.
])

#cmd("Mac")[```bash
kubectl apply -f security/netpol/02-frontend-backend.yaml
```][Öffnet genau diese eine Verbindung.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://backend:8080/
```][Erwartet: `200`.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' https://example.com/
```][Erwartet: `000`. Das Internet bleibt gesperrt.]

== Schritt 3: Regeln auf HTTP-Ebene

Cilium kann auch HTTP verstehen. Damit erlaubst du nicht nur einen Port, sondern konkrete Pfade. Ändere dafür die Regel `backend-darf-empfangen`:

#datei("security/netpol/03-http-regel.yaml", ```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: backend-darf-empfangen
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: "/"
```)

#cmd("Mac")[```bash
kubectl apply -f security/netpol/03-http-regel.yaml
```][Der Name ist gleich, also ersetzt dieser Befehl die Regel.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://backend:8080/
```][Erwartet: `200`.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://backend:8080/admin
```][Erwartet: `403`. Der Unterschied zu vorher ist wichtig: Die Verbindung kommt zustande, aber Ciliums Proxy lehnt die Anfrage ab.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 3 -o /dev/null -w '%{http_code}\n' \
  -X DELETE http://backend:8080/
```][Erwartet: `403`. Nur `GET` ist erlaubt.]

== Schritt 4: Ausgang nach Hostname erlauben

Oft muss eine Anwendung einen bestimmten Dienst im Internet erreichen. IP-Adressen ändern sich, deshalb gibst du den Namen an.

#datei("security/netpol/04-fqdn.yaml", ```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: frontend-darf-example
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  egress:
    - toFQDNs:
        - matchName: example.com
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```, erklaerung: [
  Das funktioniert nur dank der `dns`-Regel aus Schritt 1: Cilium liest die DNS-Antwort mit und merkt sich die IP-Adressen zu `example.com`.
])

#cmd("Mac")[```bash
kubectl apply -f security/netpol/04-fqdn.yaml
```][Lädt die Regel.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' https://example.com/
```][Erwartet: `200`.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' https://example.org/
```][Erwartet: `000`. Nur der genannte Host ist erlaubt.]

== Was weiterhin durchkommt

#falle[
  Der Kubelet prüft Pods weiter per Health-Check, obwohl alles gesperrt ist. Cilium erlaubt Verkehr vom eigenen Node standardmäßig. Pods, die den API-Server brauchen, musst du aber ausdrücklich freigeben: mit `egress` und `toEntities: [kube-apiserver]`. Ohne diese Regel scheitern Operatoren still.
]

== Wie du das auf echte Namespaces überträgst

Sperre nie einen ganzen Cluster auf einen Schlag. Gehe Namespace für Namespace vor:

+ Lass den Dienst unter Last laufen.
+ Schaue in Hubble oder Grafana, welche Verbindungen es wirklich gibt.
+ Schreibe die Regeln passend dazu.
+ Schalte Default-Deny ein und beobachte `--verdict DROPPED`.

Die Datei `01-default-deny.yaml` kann als Vorlage dienen. `kube-system` bleibt dabei außen vor, denn dort läuft die Grundversorgung.

#aufgabe[
  Sichere den Namespace `falco-lab` aus Kapitel 7, sobald du ihn hast: nur DNS und Ausgang zu `dl-cdn.alpinelinux.org`. Dann funktioniert `apk add` weiter, aber sonst nichts.
]

#gelernt(
  [Sobald eine Policy einen Pod auswählt, gilt für diese Richtung Default-Deny.],
  [Eine Verbindung braucht beide Seiten: Egress beim Sender, Ingress beim Empfänger.],
  [`hubble observe --verdict DROPPED` ersetzt das Raten.],
  [Cilium versteht auch HTTP und Hostnamen, nicht nur Ports.],
  [Ein Timeout (`000`) und `403` bedeuten verschiedene Dinge: Sperre auf Netzwerk- oder auf Anwendungsebene.],
)

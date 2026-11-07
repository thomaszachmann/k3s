#import "../lib.typ": *

#kapitel(
  [Default Deny with Cilium],
  ziel: [Pods can only do what you explicitly allow, and Hubble shows you every blocked connection.],
  zeit: [75 minutes],
  braucht: [Chapter 5],
)

== Why Default Deny

By default, in Kubernetes every pod can talk to every other pod and reach the internet. For an attacker, that is ideal: one pod is enough, and from there they can reach everything. With *default deny* you turn this around: nothing works except what you allow.

Cilium works with identities instead of IP addresses. A rule says “pods with label `app=frontend`”, not “10.42.0.7”. That fits Kubernetes, where IP addresses change all the time.

#warum[
  As soon as a policy selects a pod, default deny automatically applies to that direction. An `ingress` rule therefore blocks all other incoming traffic. That is powerful, but it is also the most common cause of surprises.
]

== The Lab Application

Your application has two parts: a `backend` (web server) and a `frontend` that calls it. Both meet `restricted` and your Kyverno rules.

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
```][Both pods should show `Running`. If not, `kubectl get events -n demo` shows the reason.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://backend:8080/
```][Calls the backend. `-m 3` gives up after three seconds, `-w` prints only the status code. Expected: `200`.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' https://example.com/
```][The internet is reachable too. Expected: `200`. There are no rules yet.]

== Step 1: Block Everything Except DNS

#datei("security/netpol/01-default-deny.yaml", ```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: demo
spec:
  description: Block everything, only DNS stays allowed
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
  `endpointSelector: {}` selects all pods in the namespace. `ingress: [{}]` is an empty rule: it allows nothing, but it turns on default deny for incoming traffic. For `egress`, only DNS stays allowed; otherwise no pod could resolve names anymore. The `dns` rule lets Cilium read along with the queries, which you will need shortly for hostnames.
])

#cmd("Mac")[```bash
kubectl apply -f security/netpol/01-default-deny.yaml
```][From now on, `demo` is locked down.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://backend:8080/
```][Expected: `000` and a timeout. The name resolves, but the connection is silently dropped.]

#cmd("Mac")[```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --namespace demo --verdict DROPPED --last 10
```][Hubble shows you exactly what was blocked: source, destination, port and reason.]

#pruefe[
  One line shows `demo/frontend-... -> demo/backend-...:8080`, along with `Policy denied` and `DROPPED`. This is your most important tool for network problems: instead of guessing, you just look.
]

== Step 2: Allow Specific Traffic

A connection needs two rules: the frontend must be allowed to send, and the backend must be allowed to receive.

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
  Policies add up. The block stays in place; these rules only add exceptions. Without a namespace, the labels only apply within the policy's own namespace.
])

#cmd("Mac")[```bash
kubectl apply -f security/netpol/02-frontend-backend.yaml
```][Opens exactly this one connection.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://backend:8080/
```][Expected: `200`.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' https://example.com/
```][Expected: `000`. The internet stays blocked.]

== Step 3: Rules at the HTTP Level

Cilium can also understand HTTP. That lets you allow specific paths, not just a port. To do this, change the `backend-darf-empfangen` rule:

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
```][The name is the same, so this command replaces the rule.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://backend:8080/
```][Expected: `200`.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://backend:8080/admin
```][Expected: `403`. The difference from before matters: the connection is established, but Cilium's proxy rejects the request.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 3 -o /dev/null -w '%{http_code}\n' \
  -X DELETE http://backend:8080/
```][Expected: `403`. Only `GET` is allowed.]

== Step 4: Allow Egress by Hostname

Often an application needs to reach a specific service on the internet. IP addresses change, so you specify the name instead.

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
  This only works thanks to the `dns` rule from Step 1: Cilium reads the DNS response and remembers the IP addresses for `example.com`.
])

#cmd("Mac")[```bash
kubectl apply -f security/netpol/04-fqdn.yaml
```][Loads the rule.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' https://example.com/
```][Expected: `200`.]

#cmd("Mac")[```bash
kubectl exec -n demo deploy/frontend -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' https://example.org/
```][Expected: `000`. Only the named host is allowed.]

== What Still Gets Through

#falle[
  The kubelet keeps checking pods with health checks, even though everything is blocked. Cilium allows traffic from the pod's own node by default. Pods that need the API server, however, have to be allowed explicitly: with `egress` and `toEntities: [kube-apiserver]`. Without this rule, operators fail silently.
]

== How to Apply This to Real Namespaces

Never lock down a whole cluster in one go. Work namespace by namespace:

+ Let the service run under load.
+ Look in Hubble or Grafana to see which connections actually exist.
+ Write the rules to match.
+ Turn on default deny and watch `--verdict DROPPED`.

The file `01-default-deny.yaml` can serve as a template. `kube-system` stays out of this, because that is where the core services run.

#aufgabe[
  Secure the `falco-lab` namespace from Chapter 7 once you have it: only DNS and egress to `dl-cdn.alpinelinux.org`. Then `apk add` keeps working, but nothing else does.
]

#gelernt(
  [As soon as a policy selects a pod, default deny applies to that direction.],
  [A connection needs both sides: egress at the sender, ingress at the receiver.],
  [`hubble observe --verdict DROPPED` replaces guessing.],
  [Cilium also understands HTTP and hostnames, not just ports.],
  [A timeout (`000`) and `403` mean different things: a block at the network level or at the application level.],
)

#import "../lib.typ": *

#kapitel(
  [Optional: cert-manager],
  ziel: [You run your own certificate authority in the cluster and have certificates issued and renewed automatically.],
  zeit: [45 minutes],
  braucht: [Chapter 10],
)

== Why Automation

Certificates expire, usually at night and on weekends. cert-manager renews them on its own. You only describe which certificate you want, and it ends up as a Secret in the namespace.

#tabelle(
  (auto, 1fr),
  ([Object], [Meaning]),
  [`Issuer`, `ClusterIssuer`], [Who issues? In the namespace or cluster-wide],
  [`Certificate`], [What do you want? Names, lifetime, target Secret],
  [`Secret`], [The result: `tls.crt`, `tls.key`, `ca.crt`],
)

Your cluster sits in your home network, so Let's Encrypt cannot reach it. That is why you build your own private CA. The process is the same as with a public one.

== Installing

#cmd("Mac")[```bash
helm upgrade --install cert-manager \
  oci://quay.io/jetstack/charts/cert-manager \
  --version v1.21.3 -n cert-manager --create-namespace \
  --set crds.enabled=true --wait
```][`crds.enabled=true` installs the required object types along with it. Without the flag they are missing, and `Certificate` would be unknown.]

#cmd("Mac")[```bash
kubectl get pods -n cert-manager
```][Three pods should be running: controller, CA injector and webhook.]

== Building Your Own CA

The chain comes together in three steps: a self-signed issuer creates the root certificate, and that certificate then becomes the CA that signs everything else.

#datei("security/tls/ca.yaml", ```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: k3s2-root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: k3s2 Root CA
  secretName: k3s2-root-ca
  duration: 87600h
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: k3s2-ca
spec:
  ca:
    secretName: k3s2-root-ca
```, erklaerung: [
  `isCA: true` turns the certificate into a CA, and `duration: 87600h` makes it valid for ten years. For a `ClusterIssuer`, cert-manager looks for the Secret in the `cert-manager` namespace, which is why the root certificate lives there.
])

#cmd("Mac")[```bash
kubectl apply -f security/tls/ca.yaml
```][Builds the CA.]

#cmd("Mac")[```bash
kubectl get clusterissuer
kubectl get certificate -n cert-manager
```][All entries should show `READY True`.]

#warum[
  The Secret `k3s2-root-ca` contains your CA's private key. Whoever has it can issue valid certificates for any name in your cluster. It is a good example of an object whose read access you must restrict tightly with RBAC.
]

== The First Certificate

#datei("security/tls/demo-cert.yaml", ```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: backend-tls
  namespace: demo
spec:
  secretName: backend-tls
  duration: 2160h
  renewBefore: 720h
  dnsNames:
    - backend
    - backend.demo.svc
    - backend.demo.svc.cluster.local
  issuerRef:
    name: k3s2-ca
    kind: ClusterIssuer
    group: cert-manager.io
```, erklaerung: [
  The certificate is valid for 90 days and is renewed 30 days before it expires. The `dnsNames` are all the names under which the Service is reachable. A mismatch leads to a certificate error on the client.
])

#cmd("Mac")[```bash
kubectl apply -f security/tls/demo-cert.yaml
kubectl get certificate -n demo
```][Should show `READY True` after a few seconds.]

#cmd("Mac")[```bash
kubectl get secret backend-tls -n demo \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```][Reads the certificate from the Secret and shows issuer, validity period and names.]

#pruefe[
  `issuer` reads `CN=k3s2 Root CA`, and `subjectAltName` lists your three DNS names.
]

== Trying Out Renewal

#cmd("Mac")[```bash
kubectl get secret backend-tls -n demo \
  -o jsonpath='{.metadata.uid}{"\n"}'
```][Write down the UID.]

#cmd("Mac")[```bash
kubectl delete secret backend-tls -n demo
```][Simulates a loss.]

#cmd("Mac")[```bash
kubectl get secret backend-tls -n demo \
  -o jsonpath='{.metadata.uid}{"\n"}'
```][After a short while, the Secret is back, with a new UID. cert-manager constantly compares desired and actual state. That is exactly what the controller principle in Kubernetes means.]

== Making Grafana Reachable over HTTPS

So far you have used `port-forward`. Now you expose Grafana on the network through Traefik, with a certificate from your CA.

#datei("security/tls/grafana-ingress.yaml", ```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: k3s2-ca
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - grafana.k3s2.local
      secretName: grafana-tls
  rules:
    - host: grafana.k3s2.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kps-grafana
                port:
                  number: 80
```, erklaerung: [
  The annotation is enough: cert-manager sees the Ingress and creates the matching `Certificate` on its own.
])

#cmd("Mac")[```bash
kubectl apply -f security/tls/grafana-ingress.yaml
kubectl get certificate -n monitoring
```][The certificate `grafana-tls` is created automatically.]

#cmd("Mac")[```bash
kubectl get secret k3s2-root-ca -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > k3s2-ca.crt
```][Fetches only the public part of the CA. You may share this file.]

#cmd("Mac")[```bash
curl --cacert k3s2-ca.crt \
  --resolve grafana.k3s2.local:443:172.16.0.136 \
  https://grafana.k3s2.local/api/health
```][`--resolve` saves you the DNS entry, and `--cacert` trusts your CA.]

#pruefe[
  The response is JSON with `"database": "ok"`. If you leave out `--cacert`, `curl` refuses the connection, because your Mac does not know the CA. That is exactly how it should be.
]

#aufgabe[
  Add `172.16.0.136 grafana.k3s2.local` to `/etc/hosts` and open the address in your browser. Which warning appears, and what would you have to do in macOS Keychain Access to make it go away? Do not delete the file `k3s2-ca.crt`; you still need it.
]

#gelernt(
  [cert-manager constantly reconciles certificates and renews them on its own.],
  [A private CA is built from a self-signed issuer and a CA issuer.],
  [The CA's key is one of the most valuable Secrets in the cluster.],
  [A single annotation on the Ingress is enough for automatic TLS.],
)

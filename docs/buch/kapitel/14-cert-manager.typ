#import "../lib.typ": *

#kapitel(
  [Zusatz: cert-manager],
  ziel: [Du betreibst deine eigene Zertifizierungsstelle im Cluster und lässt Zertifikate automatisch ausstellen und erneuern.],
  zeit: [45 Minuten],
  braucht: [Kapitel 10],
)

== Warum Automatisierung

Zertifikate laufen ab, meist nachts und am Wochenende. cert-manager erneuert sie selbstständig. Du beschreibst nur, welches Zertifikat du willst, und es landet als Secret im Namespace.

#tabelle(
  (auto, 1fr),
  ([Objekt], [Bedeutung]),
  [`Issuer`, `ClusterIssuer`], [Wer stellt aus? Im Namespace oder clusterweit],
  [`Certificate`], [Was willst du? Namen, Laufzeit, Ziel-Secret],
  [`Secret`], [Das Ergebnis: `tls.crt`, `tls.key`, `ca.crt`],
)

Dein Cluster steht im Heimnetz, Let's Encrypt kann ihn also nicht erreichen. Deshalb baust du eine eigene private CA auf. Der Ablauf ist derselbe wie bei einer öffentlichen.

== Installieren

#cmd("Mac")[```bash
helm upgrade --install cert-manager \
  oci://quay.io/jetstack/charts/cert-manager \
  --version v1.21.3 -n cert-manager --create-namespace \
  --set crds.enabled=true --wait
```][`crds.enabled=true` installiert die benötigten Objekttypen gleich mit. Ohne das Flag fehlen sie, und `Certificate` wäre unbekannt.]

#cmd("Mac")[```bash
kubectl get pods -n cert-manager
```][Drei Pods sollten laufen: Controller, CA-Injector und Webhook.]

== Die eigene CA aufbauen

Die Kette entsteht in drei Schritten: Ein selbstsignierter Aussteller erstellt das Wurzelzertifikat, und dieses wird dann zur CA, die alles Weitere signiert.

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
  `isCA: true` macht das Zertifikat zur CA, `duration: 87600h` lässt sie zehn Jahre gelten. Bei einem `ClusterIssuer` sucht cert-manager das Secret im Namespace `cert-manager`, deshalb liegt das Wurzelzertifikat dort.
])

#cmd("Mac")[```bash
kubectl apply -f security/tls/ca.yaml
```][Baut die CA auf.]

#cmd("Mac")[```bash
kubectl get clusterissuer
kubectl get certificate -n cert-manager
```][Alle Einträge sollten `READY True` zeigen.]

#warum[
  Das Secret `k3s2-root-ca` enthält den privaten Schlüssel deiner CA. Wer ihn hat, kann für jeden Namen in deinem Cluster gültige Zertifikate ausstellen. Das ist ein gutes Beispiel für ein Objekt, dessen Lesezugriff du per RBAC streng begrenzen musst.
]

== Das erste Zertifikat

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
  Das Zertifikat gilt 90 Tage und wird 30 Tage vor Ablauf erneuert. Die `dnsNames` sind alle Namen, unter denen der Service erreichbar ist. Eine Abweichung führt zu einem Zertifikatsfehler beim Client.
])

#cmd("Mac")[```bash
kubectl apply -f security/tls/demo-cert.yaml
kubectl get certificate -n demo
```][Sollte nach wenigen Sekunden `READY True` zeigen.]

#cmd("Mac")[```bash
kubectl get secret backend-tls -n demo \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```][Liest das Zertifikat aus dem Secret und zeigt Aussteller, Laufzeit und Namen an.]

#pruefe[
  `issuer` lautet `CN=k3s2 Root CA`, `subjectAltName` nennt deine drei DNS-Namen.
]

== Erneuerung ausprobieren

#cmd("Mac")[```bash
kubectl get secret backend-tls -n demo \
  -o jsonpath='{.metadata.uid}{"\n"}'
```][Notiere dir die UID.]

#cmd("Mac")[```bash
kubectl delete secret backend-tls -n demo
```][Simuliert einen Verlust.]

#cmd("Mac")[```bash
kubectl get secret backend-tls -n demo \
  -o jsonpath='{.metadata.uid}{"\n"}'
```][Nach kurzer Zeit gibt es wieder ein Secret, mit neuer UID. cert-manager gleicht ständig Soll und Ist ab. Genau das meint das Controller-Prinzip in Kubernetes.]

== Grafana per HTTPS erreichbar machen

Bisher nutzt du `port-forward`. Jetzt bringst du Grafana über Traefik ans Netz, mit einem Zertifikat deiner CA.

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
  Die Annotation genügt: cert-manager sieht den Ingress und legt das passende `Certificate` selbst an.
])

#cmd("Mac")[```bash
kubectl apply -f security/tls/grafana-ingress.yaml
kubectl get certificate -n monitoring
```][Das Zertifikat `grafana-tls` entsteht automatisch.]

#cmd("Mac")[```bash
kubectl get secret k3s2-root-ca -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > k3s2-ca.crt
```][Holt nur den öffentlichen Teil der CA. Diese Datei darfst du weitergeben.]

#cmd("Mac")[```bash
curl --cacert k3s2-ca.crt \
  --resolve grafana.k3s2.local:443:172.16.0.136 \
  https://grafana.k3s2.local/api/health
```][`--resolve` spart den DNS-Eintrag, und `--cacert` vertraut deiner CA.]

#pruefe[
  Die Antwort ist JSON mit `"database": "ok"`. Lässt du `--cacert` weg, verweigert `curl` die Verbindung, weil dein Mac die CA nicht kennt. Genau so soll es sein.
]

#aufgabe[
  Trage `172.16.0.136 grafana.k3s2.local` in `/etc/hosts` ein und öffne die Adresse im Browser. Welche Warnung erscheint, und was müsstest du in der macOS-Schlüsselbundverwaltung tun, damit sie verschwindet? Lösche die Datei `k3s2-ca.crt` nicht, du brauchst sie noch.
]

#gelernt(
  [cert-manager gleicht Zertifikate ständig ab und erneuert sie selbst.],
  [Eine private CA entsteht aus einem selbstsignierten Aussteller und einem CA-Issuer.],
  [Der Schlüssel der CA ist eines der wertvollsten Secrets im Cluster.],
  [Eine einzige Annotation am Ingress reicht für automatisches TLS.],
)

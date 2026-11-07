#import "../lib.typ": *

#kapitel(
  [RBAC: Wer darf was?],
  ziel: [Du vergibst minimale Rechte an Menschen und an Workloads und prüfst sie mit `kubectl auth can-i`.],
  zeit: [60 Minuten],
  braucht: [Kapitel 2],
)

== Das Modell

RBAC (Role-Based Access Control) besteht aus vier Objekten:

#tabelle(
  (auto, 1fr),
  ([Objekt], [Bedeutung]),
  [`Role`], [Rechte innerhalb eines Namespace],
  [`ClusterRole`], [Rechte clusterweit oder als wiederverwendbare Vorlage],
  [`RoleBinding`], [Vergibt eine Rolle in einem Namespace],
  [`ClusterRoleBinding`], [Vergibt eine Rolle im ganzen Cluster],
)

Der Grundsatz lautet: Alles ist verboten, was nicht ausdrücklich erlaubt ist. Rollen können nur Rechte hinzufügen, nie wegnehmen.

Rechte bekommen drei Arten von Subjekten: *User*, *Group* und *ServiceAccount*. Kubernetes kennt keine Benutzerdatenbank. User und Gruppen ergeben sich aus dem Zertifikat oder Token, mit dem sich jemand anmeldet. ServiceAccounts dagegen sind echte Objekte im Cluster.

== Den Lab-Namespace anlegen

#cmd("Mac")[```bash
kubectl create namespace demo
```][In diesem Namespace übst du für den Rest des Buches.]

#cmd("Mac")[```bash
kubectl label namespace demo security.k3s2/tier=app
```][Dieses Label nutzt Kyverno in Kapitel 5, um Anwendungs-Namespaces zu erkennen.]

== Rechte eines ServiceAccounts

Jeder Pod läuft unter einem ServiceAccount. Ohne Angabe ist das `default`.

#cmd("Mac")[```bash
kubectl auth can-i --list \
  --as=system:serviceaccount:demo:default -n demo
```][`--as` lässt dich als dieses Konto fragen, ohne dich anzumelden. Das nennt sich Impersonation. Du siehst fast nur Rechte zum Selbst-Erkennen.]

#cmd("Mac")[```bash
kubectl create serviceaccount app -n demo
```][Ein eigenes Konto für deine Anwendung. So teilt sie ihre Rechte mit niemandem.]

#cmd("Mac")[```bash
kubectl create role pod-leser -n demo \
  --verb=get,list,watch --resource=pods
```][Erlaubt nur Lesen von Pods in `demo`.]

#cmd("Mac")[```bash
kubectl create rolebinding app-liest-pods -n demo \
  --role=pod-leser --serviceaccount=demo:app
```][Vergibt die Rolle an das Konto `app`. Erst das Binding macht die Rolle wirksam.]

#cmd("Mac")[```bash
kubectl auth can-i list pods -n demo \
  --as=system:serviceaccount:demo:app
```][Erwartet: `yes`.]

#cmd("Mac")[```bash
kubectl auth can-i delete pods -n demo \
  --as=system:serviceaccount:demo:app
```][Erwartet: `no`. Lesen war erlaubt, Löschen nicht.]

#cmd("Mac")[```bash
kubectl auth can-i list pods -n kube-system \
  --as=system:serviceaccount:demo:app
```][Erwartet: `no`. Die Rolle gilt nur in `demo`.]

== Das Token gar nicht erst mounten

Kubernetes legt das Token des ServiceAccounts automatisch in jeden Pod. Die meisten Anwendungen sprechen aber nie mit dem API-Server. Für sie ist das Token nur ein Geschenk an den Angreifer.

#datei("security/rbac/sa-ohne-token.yaml", ```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend
  namespace: demo
automountServiceAccountToken: false
```, erklaerung: [
  Pods dieses Kontos bekommen kein Token. Du kannst das pro Pod überschreiben, wenn einer es wirklich braucht.
])

#cmd("Mac")[```bash
kubectl apply -f security/rbac/sa-ohne-token.yaml
```][Dieses Konto nutzt das `frontend` in Kapitel 6.]

== Ein echter Mensch: alice

Jetzt gibst du einem Menschen Zugang, und zwar über ein Client-Zertifikat. `CN` wird dabei zum Benutzernamen, `O` zur Gruppe.

#cmd("Mac")[```bash
mkdir -p ~/k3s2-alice && cd ~/k3s2-alice
```][Ein eigener Ordner außerhalb des Repos, denn hier liegt gleich ein privater Schlüssel.]

#cmd("Mac")[```bash
openssl genrsa -out alice.key 2048
```][Erzeugt alices privaten Schlüssel. Er verlässt ihren Rechner nie.]

#cmd("Mac")[```bash
openssl req -new -key alice.key -out alice.csr \
  -subj "/CN=alice/O=plattform"
```][Erstellt einen Zertifikatsantrag für Benutzer `alice` in Gruppe `plattform`.]

Lege den Antrag als Kubernetes-Objekt an:

#datei("~/k3s2-alice/csr.yaml", ```yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alice
spec:
  request: HIER_BASE64
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
    - client auth
```, erklaerung: [
  `expirationSeconds: 86400` begrenzt das Zertifikat auf einen Tag. Das ist wichtig, weil Kubernetes Client-Zertifikate *nicht widerrufen* kann.
])

#cmd("Mac")[```bash
base64 < alice.csr | tr -d '\n'
```][Gibt den Antrag als eine Base64-Zeile aus. Setze sie in `csr.yaml` anstelle von `HIER_BASE64` ein.]

#cmd("Mac")[```bash
kubectl apply -f csr.yaml
kubectl certificate approve alice
```][Reicht den Antrag ein und genehmigt ihn. Jetzt signiert der Cluster.]

#cmd("Mac")[```bash
kubectl get csr alice \
  -o jsonpath='{.status.certificate}' | base64 -d > alice.crt
```][Holt das fertige Zertifikat.]

#cmd("Mac")[```bash
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > k3s2-ca.crt
```][Speichert das CA-Zertifikat des Clusters. Damit prüft alice, dass sie wirklich mit deinem API-Server spricht. Es ist öffentlich und nicht geheim.]

#cmd("Mac")[```bash
kubectl config set-cluster k3s2 --kubeconfig=alice.kubeconfig \
  --server=https://172.16.0.136:6443 \
  --certificate-authority=k3s2-ca.crt --embed-certs
```][Trägt den Cluster in eine neue Kubeconfig ein. Deine eigene bleibt unberührt.]

#cmd("Mac")[```bash
kubectl config set-credentials alice \
  --kubeconfig=alice.kubeconfig \
  --client-certificate=alice.crt --client-key=alice.key \
  --embed-certs
```][Trägt alices Identität ein.]

#cmd("Mac")[```bash
kubectl config set-context alice --kubeconfig=alice.kubeconfig \
  --cluster=k3s2 --user=alice --namespace=demo
kubectl config use-context alice --kubeconfig=alice.kubeconfig
```][Verbindet Cluster und Nutzer zu einem Kontext.]

#cmd("Mac")[```bash
kubectl --kubeconfig=alice.kubeconfig get pods
```][Erwartet: `Forbidden`. Das ist richtig, denn alice ist angemeldet, hat aber noch keine Rechte. Authentifizierung (wer bist du?) und Autorisierung (was darfst du?) sind zwei Schritte.]

#cmd("Mac")[```bash
kubectl create rolebinding plattform-edit -n demo \
  --clusterrole=edit --group=plattform
```][Vergibt die eingebaute Rolle `edit` an die *Gruppe*. So bekommt jede Person dieser Gruppe die Rechte, und du musst Bindings nicht pro Person pflegen.]

#cmd("Mac")[```bash
kubectl --kubeconfig=alice.kubeconfig get pods
kubectl --kubeconfig=alice.kubeconfig get nodes
```][Pods gehen jetzt. Nodes sind weiter verboten, denn sie sind clusterweit, und das Binding gilt nur in `demo`.]

#cmd("Mac")[```bash
cd -
```][Zurück ins Repo.]

== Gefährliche Rechte erkennen

Manche Rechte sehen harmlos aus, kommen aber einem Vollzugriff gleich:

#tabelle(
  (auto, 1fr),
  ([Recht], [Warum es gefährlich ist]),
  [`get secrets`], [Liest alle Tokens und Passwörter des Namespace],
  [`create pods`], [Startet Pods mit jedem ServiceAccount des Namespace],
  [`pods/exec`], [Öffnet eine Shell in fremden Containern],
  [`escalate`, `bind`], [Vergibt Rechte, die man selbst nicht besitzt],
  [`impersonate`], [Handelt als beliebiger anderer Nutzer],
)

#cmd("Mac")[```bash
kubectl get clusterrolebindings -o json | jq -r '
  .items[]
  | select(.roleRef.name == "cluster-admin")
  | .metadata.name'
```][Listet alle Bindings mit vollen Admin-Rechten. Das ist deine wichtigste Prüfliste: Was hier steht, hat die Kontrolle über alles.]

#aufgabe[
  Warum ist `create pods` so gefährlich? Stell dir vor, im Namespace liegt ein ServiceAccount mit hohen Rechten. Wie käme ein Nutzer, der nur Pods erstellen darf, an dessen Rechte? Der Abschnitt zum Token im Pod hilft dir dabei.
]

#gelernt(
  [Rollen fügen nur Rechte hinzu, alles andere ist verboten.],
  [Authentifizierung und Autorisierung sind getrennte Schritte.],
  [`kubectl auth can-i --as` prüft Rechte, ohne sich anzumelden.],
  [Bindings an Gruppen sind besser als Bindings an Personen.],
  [Client-Zertifikate lassen sich nicht widerrufen, also halte sie kurzlebig.],
)

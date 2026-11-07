#import "../lib.typ": *

#kapitel(
  [RBAC: Who May Do What?],
  ziel: [You grant minimal rights to people and to workloads and check them with `kubectl auth can-i`.],
  zeit: [60 minutes],
  braucht: [Chapter 2],
)

== The Model

RBAC (Role-Based Access Control) consists of four objects:

#tabelle(
  (auto, 1fr),
  ([Object], [Meaning]),
  [`Role`], [Rights within a namespace],
  [`ClusterRole`], [Rights cluster-wide or as a reusable template],
  [`RoleBinding`], [Grants a role in a namespace],
  [`ClusterRoleBinding`], [Grants a role in the whole cluster],
)

The principle is: everything that is not explicitly allowed is forbidden. Roles can only add rights, never take them away.

Three kinds of subjects receive rights: *User*, *Group* and *ServiceAccount*. Kubernetes has no user database. Users and groups come from the certificate or token someone logs in with. ServiceAccounts, on the other hand, are real objects in the cluster.

== Creating the Lab Namespace

#cmd("Mac")[```bash
kubectl create namespace demo
```][You practice in this namespace for the rest of the book.]

#cmd("Mac")[```bash
kubectl label namespace demo security.k3s2/tier=app
```][Kyverno uses this label in Chapter 5 to recognize application namespaces.]

== The Rights of a ServiceAccount

Every pod runs under a ServiceAccount. If none is specified, that is `default`.

#cmd("Mac")[```bash
kubectl auth can-i --list \
  --as=system:serviceaccount:demo:default -n demo
```][`--as` lets you ask as this account without logging in. This is called impersonation. You see almost nothing but rights for self-discovery.]

#cmd("Mac")[```bash
kubectl create serviceaccount app -n demo
```][A dedicated account for your application. That way it shares its rights with nobody.]

#cmd("Mac")[```bash
kubectl create role pod-leser -n demo \
  --verb=get,list,watch --resource=pods
```][Allows only reading pods in `demo`.]

#cmd("Mac")[```bash
kubectl create rolebinding app-liest-pods -n demo \
  --role=pod-leser --serviceaccount=demo:app
```][Grants the role to the `app` account. Only the binding makes the role effective.]

#cmd("Mac")[```bash
kubectl auth can-i list pods -n demo \
  --as=system:serviceaccount:demo:app
```][Expected: `yes`.]

#cmd("Mac")[```bash
kubectl auth can-i delete pods -n demo \
  --as=system:serviceaccount:demo:app
```][Expected: `no`. Reading was allowed, deleting is not.]

#cmd("Mac")[```bash
kubectl auth can-i list pods -n kube-system \
  --as=system:serviceaccount:demo:app
```][Expected: `no`. The role only applies in `demo`.]

== Not Mounting the Token in the First Place

Kubernetes automatically puts the ServiceAccount token into every pod. But most applications never talk to the API server. For them, the token is just a gift to the attacker.

#datei("security/rbac/sa-ohne-token.yaml", ```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend
  namespace: demo
automountServiceAccountToken: false
```, erklaerung: [
  Pods using this account get no token. You can override this per pod if one really needs it.
])

#cmd("Mac")[```bash
kubectl apply -f security/rbac/sa-ohne-token.yaml
```][The `frontend` uses this account in Chapter 6.]

== A Real Person: alice

Now you give a person access, through a client certificate. `CN` becomes the user name, `O` the group.

#cmd("Mac")[```bash
mkdir -p ~/k3s2-alice && cd ~/k3s2-alice
```][A separate folder outside the repo, because a private key will be stored here in a moment.]

#cmd("Mac")[```bash
openssl genrsa -out alice.key 2048
```][Creates alice's private key. It never leaves her machine.]

#cmd("Mac")[```bash
openssl req -new -key alice.key -out alice.csr \
  -subj "/CN=alice/O=plattform"
```][Creates a certificate signing request for user `alice` in group `plattform`.]

Create the request as a Kubernetes object:

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
  `expirationSeconds: 86400` limits the certificate to one day. This matters because Kubernetes *cannot revoke* client certificates.
])

#cmd("Mac")[```bash
base64 < alice.csr | tr -d '\n'
```][Prints the request as a single Base64 line. Put it into `csr.yaml` in place of `HIER_BASE64`.]

#cmd("Mac")[```bash
kubectl apply -f csr.yaml
kubectl certificate approve alice
```][Submits the request and approves it. Now the cluster signs it.]

#cmd("Mac")[```bash
kubectl get csr alice \
  -o jsonpath='{.status.certificate}' | base64 -d > alice.crt
```][Fetches the finished certificate.]

#cmd("Mac")[```bash
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 -d > k3s2-ca.crt
```][Saves the cluster's CA certificate. alice uses it to verify that she is really talking to your API server. It is public, not secret.]

#cmd("Mac")[```bash
kubectl config set-cluster k3s2 --kubeconfig=alice.kubeconfig \
  --server=https://172.16.0.136:6443 \
  --certificate-authority=k3s2-ca.crt --embed-certs
```][Adds the cluster to a new kubeconfig. Your own stays untouched.]

#cmd("Mac")[```bash
kubectl config set-credentials alice \
  --kubeconfig=alice.kubeconfig \
  --client-certificate=alice.crt --client-key=alice.key \
  --embed-certs
```][Adds alice's identity.]

#cmd("Mac")[```bash
kubectl config set-context alice --kubeconfig=alice.kubeconfig \
  --cluster=k3s2 --user=alice --namespace=demo
kubectl config use-context alice --kubeconfig=alice.kubeconfig
```][Connects cluster and user into a context.]

#cmd("Mac")[```bash
kubectl --kubeconfig=alice.kubeconfig get pods
```][Expected: `Forbidden`. That is correct, because alice is logged in but has no rights yet. Authentication (who are you?) and authorization (what may you do?) are two steps.]

#cmd("Mac")[```bash
kubectl create rolebinding plattform-edit -n demo \
  --clusterrole=edit --group=plattform
```][Grants the built-in `edit` role to the *group*. That way every person in this group gets the rights, and you do not have to maintain bindings per person.]

#cmd("Mac")[```bash
kubectl --kubeconfig=alice.kubeconfig get pods
kubectl --kubeconfig=alice.kubeconfig get nodes
```][Pods work now. Nodes are still forbidden, because they are cluster-wide, and the binding only applies in `demo`.]

#cmd("Mac")[```bash
cd -
```][Back to the repo.]

== Recognizing Dangerous Rights

Some rights look harmless but amount to full access:

#tabelle(
  (auto, 1fr),
  ([Right], [Why it is dangerous]),
  [`get secrets`], [Reads all tokens and passwords in the namespace],
  [`create pods`], [Starts pods with any ServiceAccount in the namespace],
  [`pods/exec`], [Opens a shell in other people's containers],
  [`escalate`, `bind`], [Grants rights you do not have yourself],
  [`impersonate`], [Acts as any other user],
)

#cmd("Mac")[```bash
kubectl get clusterrolebindings -o json | jq -r '
  .items[]
  | select(.roleRef.name == "cluster-admin")
  | .metadata.name'
```][Lists all bindings with full admin rights. This is your most important checklist: whatever appears here controls everything.]

#aufgabe[
  Why is `create pods` so dangerous? Imagine there is a ServiceAccount with high privileges in the namespace. How would a user who may only create pods get hold of its rights? The section on the token in the pod helps you here.
]

#gelernt(
  [Roles only add rights; everything else is forbidden.],
  [Authentication and authorization are separate steps.],
  [`kubectl auth can-i --as` checks rights without logging in.],
  [Bindings to groups are better than bindings to individuals.],
  [Client certificates cannot be revoked, so keep them short-lived.],
)

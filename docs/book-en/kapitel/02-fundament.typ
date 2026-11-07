#import "../lib.typ": *

#kapitel(
  [The Foundation: k3s and Cilium],
  ziel: [An empty Ubuntu VM becomes a cluster with Cilium, and your laptop controls it through its own context.],
  zeit: [60 minutes],
  braucht: [An Ubuntu VM with SSH access],
)

== What You Need

This chapter starts from zero. Nothing runs on the VM except Ubuntu.

#tabelle(
  (auto, 1fr),
  ([Item], [This book assumes]),
  [Operating system], [Ubuntu 24.04],
  [Size], [4 CPUs, 8 GB RAM, at least 40 GB of disk],
  [Name and address], [`k3s2` with fixed IP `172.16.0.136`],
  [Laptop], [`kubectl`, `helm`, `jq`, `openssl`, `curl`, and this repo],
)

The IP address is hard-coded in `cilium/values.yaml`. If your VM has a different one, change it there and replace it in all commands in this book. It must not change later, so give the VM a fixed IP or a DHCP reservation.

#hinweis("Is k3s Already Running on the VM?", warn, warn-hell)[
  Then remove it first with `sudo /usr/local/bin/k3s-uninstall.sh`. This deletes the cluster and its data irreversibly. With k3s, the network plugin is best chosen at installation time; rebuilding a running cluster is not worth it.
]

== Preparing the VM

#cmd("Mac")[```bash
scp k3s/config.yaml <user>@172.16.0.136:/tmp/config.yaml
```][Copies your k3s configuration to the VM. It contains the flags that turn off Flannel and kube-proxy. We will look at it in a moment.]

#cmd("Mac")[```bash
ssh <user>@172.16.0.136
```][Opens the session on the VM. All following steps with the *Node* label run here.]

#cmd("Node")[```bash
sudo hostnamectl set-hostname k3s2
```][The hostname becomes the node name in the cluster. So set it before the installation.]

#cmd("Node")[```bash
sudo apt update && sudo apt -y upgrade
```][Brings the system up to date. This is the very first security measure.]

#cmd("Node")[```bash
sudo apt install -y curl jq
```][`curl` fetches the installation script in a moment, and you need `jq` later for the audit logs.]

#cmd("Node")[```bash
uname -r
```][Shows the kernel version. Cilium requires at least 5.10; Ubuntu 24.04 ships 6.8.]

#cmd("Node")[```bash
sudo ufw status
```][Ubuntu's firewall is usually inactive. If it says `inactive`, just continue.]

If the firewall is active, the API server, pods and services must get through:

#cmd("Node")[```bash
sudo ufw allow 6443/tcp
sudo ufw allow from 10.42.0.0/16 to any
sudo ufw allow from 10.43.0.0/16 to any
```][These are the rules from the k3s docs. `10.42.0.0/16` is the pod network, `10.43.0.0/16` the service network. As an alternative, the k3s docs recommend turning `ufw` off completely. Keep port 22 open, or you lock yourself out.]

== Installing k3s

#cmd("Node")[```bash
sudo install -D -m 600 -o root -g root \
  /tmp/config.yaml /etc/rancher/k3s/config.yaml
```][`install` copies the file and sets permissions in one step. `-D` creates missing directories, `-m 600` makes the file readable by root only. It must be in place *before* the installation, or k3s starts with Flannel.]

#cmd("Node")[```bash
rm /tmp/config.yaml
sudo grep -v '^#' /etc/rancher/k3s/config.yaml | grep .
```][Removes the copy and shows the active lines. Each of them has a purpose:]

#tabelle(
  (auto, 1fr),
  ([Setting], [Purpose]),
  [`flannel-backend: "none"`], [No default CNI, Cilium takes over],
  [`disable-network-policy: true`], [No second policy controller next to Cilium],
  [`disable-kube-proxy: true`], [Cilium also replaces kube-proxy],
  [`cluster-cidr`, `service-cidr`], [The networks, must match Cilium],
  [`cluster-init: true`], [etcd instead of SQLite, allows snapshots],
  [`secrets-encryption: true`], [Secrets are stored encrypted in the datastore],
)

#cmd("Node")[```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=v1.36 sh -
```][Installs k3s from the `v1.36` channel. This matters: the `stable` channel ships 1.37, but Cilium 1.20 is only tested up to 1.36.]

#cmd("Node")[```bash
sudo k3s kubectl get nodes
```][Queries the cluster directly on the VM.]

#pruefe[
  The node `k3s2` shows `NotReady`, version `v1.36.x+k3s1`. That is correct, because there is no CNI yet. If k3s does not start, `sudo journalctl -u k3s -n 50` shows the reason.
]

#cmd("Node")[```bash
sudo k3s secrets-encrypt status
```][Confirms that secrets are encrypted in the datastore.]

#cmd("Node")[```bash
sudo install -m 600 -o "$USER" \
  /etc/rancher/k3s/k3s.yaml /tmp/k3s2.yaml
```][The kubeconfig belongs to root. This creates a copy that your user may fetch with `scp`. Only you can read it, because it contains full cluster rights.]

#cmd("Node")[```bash
exit
```][Back to the laptop.]

== Merging the Kubeconfig into Your Existing One

`~/.kube/config` already contains other contexts. So you must not overwrite the file. Instead, you add the new cluster.

#cmd("Mac")[```bash
cp -p ~/.kube/config ~/.kube/config.bak-k3s2
```][Backup. If something goes wrong, you copy this file back.]

#cmd("Mac")[```bash
scp <user>@172.16.0.136:/tmp/k3s2.yaml ~/.kube/k3s2.raw
ssh <user>@172.16.0.136 'rm /tmp/k3s2.yaml'
```][Fetches the file to the laptop and deletes the admin copy on the VM.]

#cmd("Mac")[```bash
sed -e 's/127\.0\.0\.1/172.16.0.136/' \
    -e 's/: default$/: k3s2/' \
    ~/.kube/k3s2.raw > ~/.kube/k3s2.yaml
```][The file points to `127.0.0.1` and calls everything `default`. `sed` replaces the address and renames cluster, user and context to `k3s2`. That way nothing collides with your other contexts. The `$` only matches line endings, so the certificate data stays untouched.]

#cmd("Mac")[```bash
chmod 600 ~/.kube/k3s2.yaml
```][Only you may read this file.]

#cmd("Mac")[```bash
kubectl config get-contexts
```][Shows your contexts. If `k3s2` is already there from an earlier installation, you must remove the old entry:]

#cmd("Mac")[```bash
kubectl config delete-context k3s2
kubectl config delete-cluster k3s2
kubectl config delete-user k3s2
```][Only needed if `k3s2` already exists. Old entries would win during the merge, and `kubectl` would then report `x509` errors.]

#cmd("Mac")[```bash
KUBECONFIG=~/.kube/config:~/.kube/k3s2.yaml \
  kubectl config view --flatten > ~/.kube/config.neu
```][`KUBECONFIG` with two files makes `kubectl` merge both. `--flatten` writes the certificates directly into the output, so the file works on its own.]

#cmd("Mac")[```bash
chmod 600 ~/.kube/config.neu
mv ~/.kube/config.neu ~/.kube/config
```][Puts the new file in place with the right permissions.]

#cmd("Mac")[```bash
rm ~/.kube/k3s2.raw ~/.kube/k3s2.yaml
```][Cleans up the intermediate files with the admin credentials.]

== Using the New Context

#cmd("Mac")[```bash
kubectl config use-context k3s2
```][From now on, all `kubectl` and `helm` commands go to this cluster.]

#cmd("Mac")[```bash
kubectl config get-contexts
kubectl get nodes
```][The asterisk marks the active context. Your other contexts are still there.]

#pruefe[
  The asterisk is next to `k3s2`, and from the laptop you see the same `NotReady` node. From now on, always check the context before you delete anything.
]

== Installing Cilium

Your `cilium/values.yaml` already contains everything needed. The two most important lines are `k8sServiceHost` and `k8sServicePort`.

#warum[
  Without kube-proxy, at first there is nobody to translate the service IP `10.43.0.1`, since Cilium does that itself. But the Cilium agent has to reach the API server in order to start. The direct address `172.16.0.136:6443` solves this chicken-and-egg problem.
]

#cmd("Mac")[```bash
helm upgrade --install cilium \
  oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 -n kube-system \
  -f cilium/values.yaml --wait
```][`upgrade --install` works the first time and on every repeat. `--wait` only returns once all pods are ready.]

#cmd("Mac")[```bash
kubectl get nodes
```][Now the node should show `Ready`.]

#cmd("Mac")[```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg status --brief
```][Asks the agent directly. `ds/cilium` picks a pod of the DaemonSet, `-c` the container.]

#cmd("Mac")[```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg status | grep KubeProxyReplacement
```][Confirms that Cilium replaces kube-proxy. The expected value is `True`.]

#cmd("Mac")[```bash
kubectl run dns-test --rm -it --restart=Never \
  --image=busybox:1.36 -- \
  nslookup kubernetes.default.svc.cluster.local
```][Starts a throwaway pod and tests the pod network, DNS and service routing in one step. `--rm` removes it afterwards.]

#pruefe[
  `nslookup` answers with the address `10.43.0.1`. This proves that CoreDNS is reachable and the service IP works without kube-proxy.
]

== Trying Out Hubble

Hubble is Cilium's observability tool. It shows every network connection in the cluster along with the decision whether it was allowed. Until monitoring arrives in Chapter 10, it is your most important pair of eyes.

#cmd("Mac")[```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --last 10
```][Shows the last ten network flows on the node. The Hubble client is part of the agent image, so you do not need to install anything.]

#cmd("Mac")[```bash
kubectl -n kube-system port-forward svc/hubble-ui 12000:80
```][Makes the graphical interface reachable at #link("http://localhost:12000"). Stop it with `Ctrl-C`.]

#aufgabe[
  In a second terminal, open `hubble observe --follow` (with the `exec` prefix from above) and start the `dns-test` again. Can you find the DNS request to `kube-dns` in the stream of flows?
]

#gelernt(
  [You choose the CNI at installation time, not afterwards.],
  [The `config.yaml` must be on the VM before the installation.],
  [Without kube-proxy, Cilium must know the API server directly.],
  [`KUBECONFIG` with `--flatten` merges kubeconfigs without endangering other contexts.],
  [With Hubble, you now see every connection in the cluster.],
)

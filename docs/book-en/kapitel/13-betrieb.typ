#import "../lib.typ": *

#kapitel(
  [Operations and Troubleshooting],
  ziel: [You keep the stack running, back up what matters and find errors with a fixed routine.],
  zeit: [30 minutes of reading, then use it as a reference],
)

== The Routine After Every Restart

After the VM restarts, everything comes back up on its own.

#cmd("Mac")[```bash
kubectl get nodes
kubectl get pods -A | grep -vE 'Running|Completed'
```][The second command shows only pods that are not healthy. The list should be empty after a few minutes.]

== What You Need to Back Up

#tabelle(
  (auto, 1fr, 1fr),
  ([What], [How], [Where to store it]),
  [k3s server token], [Password manager], [Not in the cluster],
  [etcd], [Snapshot], [Off the node],
  [Configuration], [This repo], [Git],
)

#cmd("Node")[```bash
sudo k3s etcd-snapshot save --name manuell
```][Creates a snapshot of the datastore. This works because you chose `cluster-init` in Chapter 2.]

#cmd("Node")[```bash
sudo k3s etcd-snapshot ls
```][Shows all snapshots. k3s also creates one automatically every twelve hours.]

#falle[
  An etcd snapshot alone is not enough for a restore. Because of `secrets-encryption` you also need the server token from `/var/lib/rancher/k3s/server/token`. Store it in your password manager. Also, a backup only counts as a backup once you have practiced the restore.
]

== The Troubleshooting Routine

For every problem, work from the outside in. Don't guess, look.

+ *What isn't running?* `kubectl get pods -A`
+ *Why?* `kubectl describe pod <name> -n <ns>`; the events are at the very bottom.
+ *What does the application say?* `kubectl logs <pod> -n <ns> --previous`
+ *Who blocked it?* Go through the table below.

#tabelle(
  (auto, 1fr, 1fr),
  ([Symptom], [Likely layer], [Check with]),
  [`Forbidden` when creating], [RBAC], [`kubectl auth can-i`],
  [`violates PodSecurity`], [PSA], [Label on the namespace],
  [`admission webhook denied`], [Kyverno], [`kubectl get polr -A`],
  [Connection times out], [Cilium], [`hubble observe --verdict DROPPED`],
  [HTTP 403 without an application log], [Cilium L7], [`hubble observe --verdict DROPPED`],
  [Pod stuck in `ContainerCreating`], [Secret or volume missing], [`kubectl describe pod`],
  [No logs in Grafana], [Alloy or Loki], [`kubectl logs ds/alloy -n monitoring`],
  [No traces in Grafana], [Alloy or Tempo], [`kubectl logs statefulset/tempo -n monitoring`],
)

== The Emergency Brakes

When a security layer blocks operations, this is how you get out quickly. Use it only to fix the problem, and turn the layer back on afterwards.

#tabelle(
  (auto, 1fr),
  ([Layer], [Emergency brake]),
  [Kyverno], [`kubectl delete vpol <name>`, in the worst case delete the webhook],
  [Cilium policy], [`kubectl delete cnp --all -n <ns>`],
  [PSA], [Set the label to `enforce=privileged`],
  [Audit log], [Comment out the lines in `config.yaml`, restart k3s],
)

#cmd("Mac")[```bash
kubectl label namespace demo --overwrite \
  pod-security.kubernetes.io/enforce=privileged
```][Example for PSA. `--overwrite` is required because the label already exists.]

== Updates

Stick to the order, because the components depend on each other.

+ *k3s:* only one minor version at a time. Check Cilium compatibility first.
+ *Cilium:* read the upgrade notes first.
+ *Kyverno:* `ClusterPolicy` goes away in 1.20. You already use `ValidatingPolicy`, so you are prepared.
+ *Everything else:* one at a time, with a `kubectl get pods -A` check in between.

If a later Cilium version supports Kubernetes 1.37, you can switch to the `stable` channel. To do that, you only change `INSTALL_K3S_CHANNEL` and run the install script again.

== Keeping an Eye on Resources

#cmd("Mac")[```bash
kubectl top node
kubectl top pods -A --sort-by=memory | head -15
```][Shows the biggest memory consumers. Compare them with your plan from Chapter 1.]

If memory gets tight, work through this list in order:

+ Lower the sampling of the API server traces or turn Tempo off.
+ Lower the Prometheus retention from two days to one.
+ Have Trivy scan only weekly: `scannerReportTTL: 168h`.
+ Add a second node.

#gelernt(
  [A snapshot without the token and without a restore test is not a backup.],
  [Every layer has its typical error message, and its own emergency brake.],
)

#heading(level: 2, numbering: none, outlined: false)[Where to Go From Here]

You now have a complete foundation. These topics build on it well:

- *Image signatures:* Cosign and `ImageValidatingPolicy` in Kyverno.
- *GitOps:* Argo CD or Flux apply your manifests from the repo.
- *WireGuard:* Cilium encrypts the traffic between nodes.
- *Mutual TLS:* Cilium also authenticates individual pods to each other.
- *A second node:* this is how you learn high availability for etcd.
- *The optional part:* TLS and a secrets vault in the next three chapters.

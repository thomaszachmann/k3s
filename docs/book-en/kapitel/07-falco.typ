#import "../lib.typ": *

#kapitel(
  [Falco: Detecting Suspicious Activity],
  ziel: [Falco watches system calls on the node and reports when a container behaves suspiciously.],
  zeit: [60 minutes],
  braucht: [Chapter 4],
)

== The Alarm System in the Kernel

So far you have been preventing things. But what if someone gets through anyway? Falco sits in the kernel via eBPF and sees every system call of every container. It compares them against rules and reports matches.

#tabelle(
  (1fr, 1fr),
  ([Falco sees], [Falco does not see]),
  [A shell starts in the container], [The content of encrypted data],
  [A process reads `/etc/shadow`], [Whether an action is allowed from a business point of view],
  [A new program is executed], [What happens outside the node],
)

#warum[
  Falco blocks nothing; it only reports. That is why it complements Cilium and PSA: whatever prevention lets through, Falco sees. A rule that never fires cannot disturb anything. A noisy rule, on the other hand, makes real alerts get lost. Fine-tuning is therefore the real work.
]

== Installing

Falco writes its alerts as JSON to standard output. For now, you read them with `kubectl logs`. In Chapter 10, Alloy collects them automatically and ships them to Loki. So you do not need any extra add-on, and you save RAM.

#datei("falco/values.yaml", ```yaml
# Print lines immediately, do not buffer
tty: true

driver:
  # Modern eBPF driver, no kernel module needed
  kind: modern_ebpf

falco:
  json_output: true
  json_include_output_property: true

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    memory: 768Mi

customRules:
  eigene-regeln.yaml: |-
    - rule: Paketmanager im Container
      desc: Someone is installing software in a running container
      condition: >
        spawned_process and container
        and proc.name in (apt, apt-get, apk, dnf, yum)
      output: >
        Package manager started (user=%user.name cmd=%proc.cmdline
        pod=%k8s.pod.name ns=%k8s.ns.name
        image=%container.image.repository)
      priority: WARNING
      tags: [container, mitre_persistence]
```, erklaerung: [
  `modern_ebpf` runs on your kernel 6.8 without compiling anything. The chart already knows the k3s socket `/run/k3s/containerd/containerd.sock`, so you do not need to add it. That is how Falco gets container names and image info.
])

#cmd("Mac")[```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
```][Adds the repository.]

#cmd("Mac")[```bash
helm upgrade --install falco falcosecurity/falco \
  -n falco --version 9.2.2 \
  -f falco/values.yaml --wait --timeout 5m
```][The `falco` namespace has existed since Chapter 4 with the `privileged` level. If you had not created it, the cluster-wide default would reject Falco.]

#cmd("Mac")[```bash
kubectl logs -n falco ds/falco -c falco --tail=20
```][Checks the startup. You should see that rules were loaded and the eBPF probe is active. Errors in your own rules also show up here.]

== Simulating an Attack

You need a victim that runs as root. That is not possible in `demo` because of `restricted`. This difference is already the first lesson.

#cmd("Mac")[```bash
kubectl create namespace falco-lab
```][A namespace with the `baseline` default, where root is allowed.]

#cmd("Mac")[```bash
kubectl run opfer -n falco-lab --image=nginx:1.29-alpine
kubectl wait pod/opfer -n falco-lab --for=condition=Ready
```][Starts the victim and waits until it is ready.]

Open a second terminal and follow Falco live:

#cmd("Mac")[```bash
kubectl logs -n falco ds/falco -c falco -f --tail=0
```][`-f` follows the log, `--tail=0` shows only new lines. Leave this terminal open.]

Back in the first terminal, you perform typical attacker actions:

#cmd("Mac")[```bash
kubectl exec -it opfer -n falco-lab -- sh
```][Opens a shell in the container. That alone triggers the `Terminal shell in container` rule.]

#cmd("Pod")[```bash
cat /etc/shadow
```][Reads the password hashes. Rule: `Read sensitive file untrusted`.]

#cmd("Pod")[```bash
apk add --no-cache curl
```][Installs software. This triggers your own rule `Paketmanager im Container`.]

#cmd("Pod")[```bash
exit
```][Leaves the container.]

#pruefe[
  JSON lines with `rule`, `priority` and `output_fields` appear in the second terminal. You see the pod, namespace, image and the exact command line. A missing line for `Paketmanager` usually points to a mistake in `eigene-regeln.yaml`; in that case, check the startup logs.
]

== Silencing False Positives

Imagine your team opens shells in `falco-lab` every day. Then the `Terminal shell in container` rule turns into noise. You extend it with an exception instead of turning it off.

In `falco/values.yaml`, add a second file under `customRules`:

#datei("falco/values.yaml (excerpt)", ```yaml
customRules:
  eigene-regeln.yaml: |-
    # ... as above ...
  ausnahmen.yaml: |-
    - rule: Terminal shell in container
      condition: and not k8s.ns.name = "falco-lab"
      override:
        condition: append
```, erklaerung: [
  `override: condition: append` appends your text to the existing condition. That way the original rule stays intact, and you keep getting updates. The files are loaded in alphabetical order after the default rules.
])

#cmd("Mac")[```bash
helm upgrade falco falcosecurity/falco \
  -n falco --version 9.2.2 -f falco/values.yaml --wait
```][Loads the new rules.]

#cmd("Mac")[```bash
kubectl exec opfer -n falco-lab -it -- sh -c 'echo test'
```][Falco should stay quiet now. In all other namespaces it keeps reporting shells.]

#falle[
  Keep exceptions as narrow as possible. An exception for a whole namespace is fine for a lab. In production, a combination of image and user is the better choice. Otherwise you build the attacker a blind spot.
]

#aufgabe[
  Write a rule that fires when a container opens a connection on port 4444, the typical port for reverse shells. Hint: look at the `outbound` macro and the `fd.sport` field in the Falco docs. Test with `nc` in the `opfer` pod.
]

#gelernt(
  [Falco sees system calls, but blocks nothing.],
  [JSON on standard output is enough; Chapter 10 collects it centrally.],
  [Fine-tuning is the real work, because noisy rules hide real alerts.],
  [With `override: append` you extend rules without overwriting them.],
)

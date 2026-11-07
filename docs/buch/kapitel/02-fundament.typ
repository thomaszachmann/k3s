#import "../lib.typ": *

#kapitel(
  [Das Fundament: k3s und Cilium],
  ziel: [Aus einer leeren Ubuntu-VM wird ein Cluster mit Cilium, und dein Laptop steuert ihn über einen eigenen Kontext.],
  zeit: [60 Minuten],
  braucht: [Eine Ubuntu-VM mit SSH-Zugang],
)

== Was du brauchst

Dieses Kapitel startet bei null. Auf der VM läuft nichts außer Ubuntu.

#tabelle(
  (auto, 1fr),
  ([Punkt], [Dieses Buch nimmt an]),
  [Betriebssystem], [Ubuntu 24.04],
  [Größe], [4 CPUs, 8 GB RAM, mindestens 40 GB Disk],
  [Name und Adresse], [`k3s2` mit fester IP `172.16.0.136`],
  [Laptop], [`kubectl`, `helm`, `jq`, `openssl`, `curl`, und dieses Repo],
)

Die IP-Adresse steht fest in `cilium/values.yaml`. Hat deine VM eine andere, ändere sie dort, und ersetze sie in allen Befehlen dieses Buches. Sie darf sich später nicht mehr ändern, gib der VM also eine feste IP oder eine DHCP-Reservierung.

#hinweis("Läuft auf der VM schon k3s?", warn, warn-hell)[
  Dann entferne es zuerst mit `sudo /usr/local/bin/k3s-uninstall.sh`. Das löscht den Cluster samt Daten unwiderruflich. Das Netzwerk-Plugin legt man bei k3s am besten bei der Installation fest, ein Umbau im laufenden Cluster lohnt sich nicht.
]

== Die VM vorbereiten

#cmd("Mac")[```bash
scp k3s/config.yaml <user>@172.16.0.136:/tmp/config.yaml
```][Kopiert deine k3s-Konfiguration auf die VM. Sie enthält die Flags, die Flannel und kube-proxy abschalten. Gleich schauen wir sie an.]

#cmd("Mac")[```bash
ssh <user>@172.16.0.136
```][Öffnet die Sitzung auf der VM. Alle folgenden Schritte mit dem Etikett *Node* laufen hier.]

#cmd("Node")[```bash
sudo hostnamectl set-hostname k3s2
```][Der Hostname wird zum Node-Namen im Cluster. Lege ihn deshalb vor der Installation fest.]

#cmd("Node")[```bash
sudo apt update && sudo apt -y upgrade
```][Bringt das System auf den aktuellen Stand. Das ist die erste Sicherheitsmaßnahme überhaupt.]

#cmd("Node")[```bash
sudo apt install -y curl jq
```][`curl` holt gleich das Installationsskript, `jq` brauchst du später für die Audit-Logs.]

#cmd("Node")[```bash
uname -r
```][Zeigt die Kernel-Version. Cilium verlangt mindestens 5.10, Ubuntu 24.04 liefert 6.8.]

#cmd("Node")[```bash
sudo ufw status
```][Ubuntus Firewall ist meist inaktiv. Bei `inactive` machst du einfach weiter.]

Ist die Firewall aktiv, müssen API-Server, Pods und Services durchkommen:

#cmd("Node")[```bash
sudo ufw allow 6443/tcp
sudo ufw allow from 10.42.0.0/16 to any
sudo ufw allow from 10.43.0.0/16 to any
```][Das sind die Regeln aus der k3s-Doku. `10.42.0.0/16` ist das Pod-Netz, `10.43.0.0/16` das Service-Netz. Die k3s-Doku empfiehlt alternativ, `ufw` ganz abzuschalten. Lass Port 22 offen, sonst sperrst du dich aus.]

== k3s installieren

#cmd("Node")[```bash
sudo install -D -m 600 -o root -g root \
  /tmp/config.yaml /etc/rancher/k3s/config.yaml
```][`install` kopiert die Datei und setzt Rechte in einem Schritt. `-D` legt fehlende Verzeichnisse an, `-m 600` macht die Datei nur für root lesbar. Sie muss *vor* der Installation hier liegen, sonst startet k3s mit Flannel.]

#cmd("Node")[```bash
rm /tmp/config.yaml
sudo grep -v '^#' /etc/rancher/k3s/config.yaml | grep .
```][Entfernt die Kopie und zeigt die aktiven Zeilen. Jede davon hat einen Zweck:]

#tabelle(
  (auto, 1fr),
  ([Einstellung], [Zweck]),
  [`flannel-backend: "none"`], [Kein Standard-CNI, Cilium übernimmt],
  [`disable-network-policy: true`], [Kein zweiter Policy-Controller neben Cilium],
  [`disable-kube-proxy: true`], [Cilium ersetzt auch kube-proxy],
  [`cluster-cidr`, `service-cidr`], [Die Netze, muss zu Cilium passen],
  [`cluster-init: true`], [etcd statt SQLite, erlaubt Snapshots],
  [`secrets-encryption: true`], [Secrets liegen verschlüsselt im Datastore],
)

#cmd("Node")[```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=v1.36 sh -
```][Installiert k3s aus dem Kanal `v1.36`. Das ist wichtig: Der Kanal `stable` liefert 1.37, Cilium 1.20 ist aber nur bis 1.36 getestet.]

#cmd("Node")[```bash
sudo k3s kubectl get nodes
```][Fragt den Cluster direkt auf der VM ab.]

#pruefe[
  Der Node `k3s2` steht auf `NotReady`, Version `v1.36.x+k3s1`. Das ist richtig, denn es gibt noch kein CNI. Falls k3s nicht startet, zeigt `sudo journalctl -u k3s -n 50` den Grund.
]

#cmd("Node")[```bash
sudo k3s secrets-encrypt status
```][Bestätigt, dass Secrets im Datastore verschlüsselt werden.]

#cmd("Node")[```bash
sudo install -m 600 -o "$USER" \
  /etc/rancher/k3s/k3s.yaml /tmp/k3s2.yaml
```][Die Kubeconfig gehört root. Das legt eine Kopie an, die dein Nutzer per `scp` holen darf. Nur du kannst sie lesen, denn sie enthält volle Cluster-Rechte.]

#cmd("Node")[```bash
exit
```][Zurück zum Laptop.]

== Die Kubeconfig in deine bestehende integrieren

In `~/.kube/config` liegen schon andere Kontexte. Du darfst die Datei also nicht überschreiben, sondern fügst den neuen Cluster hinzu.

#cmd("Mac")[```bash
cp -p ~/.kube/config ~/.kube/config.bak-k3s2
```][Sicherung. Falls etwas schiefgeht, kopierst du diese Datei zurück.]

#cmd("Mac")[```bash
scp <user>@172.16.0.136:/tmp/k3s2.yaml ~/.kube/k3s2.raw
ssh <user>@172.16.0.136 'rm /tmp/k3s2.yaml'
```][Holt die Datei auf den Laptop und löscht die Admin-Kopie auf der VM.]

#cmd("Mac")[```bash
sed -e 's/127\.0\.0\.1/172.16.0.136/' \
    -e 's/: default$/: k3s2/' \
    ~/.kube/k3s2.raw > ~/.kube/k3s2.yaml
```][Die Datei zeigt auf `127.0.0.1` und nennt alles `default`. `sed` ersetzt die Adresse und benennt Cluster, Nutzer und Kontext in `k3s2` um. So kollidiert nichts mit deinen anderen Kontexten. Das `$` trifft nur Zeilenenden, die Zertifikatsdaten bleiben unberührt.]

#cmd("Mac")[```bash
chmod 600 ~/.kube/k3s2.yaml
```][Nur du darfst diese Datei lesen.]

#cmd("Mac")[```bash
kubectl config get-contexts
```][Zeigt deine Kontexte. Steht `k3s2` dort schon aus einer früheren Installation, musst du den alten Eintrag entfernen:]

#cmd("Mac")[```bash
kubectl config delete-context k3s2
kubectl config delete-cluster k3s2
kubectl config delete-user k3s2
```][Nur nötig, wenn `k3s2` schon existiert. Alte Einträge würden beim Zusammenführen gewinnen, und `kubectl` meldete dann `x509`-Fehler.]

#cmd("Mac")[```bash
KUBECONFIG=~/.kube/config:~/.kube/k3s2.yaml \
  kubectl config view --flatten > ~/.kube/config.neu
```][`KUBECONFIG` mit zwei Dateien lässt `kubectl` beide zusammenführen. `--flatten` schreibt die Zertifikate direkt in die Ausgabe, damit die Datei allein funktioniert.]

#cmd("Mac")[```bash
chmod 600 ~/.kube/config.neu
mv ~/.kube/config.neu ~/.kube/config
```][Setzt die neue Datei mit den richtigen Rechten ein.]

#cmd("Mac")[```bash
rm ~/.kube/k3s2.raw ~/.kube/k3s2.yaml
```][Räumt die Zwischendateien mit den Admin-Zugangsdaten auf.]

== Den neuen Kontext nutzen

#cmd("Mac")[```bash
kubectl config use-context k3s2
```][Ab jetzt gehen alle `kubectl`- und `helm`-Befehle an diesen Cluster.]

#cmd("Mac")[```bash
kubectl config get-contexts
kubectl get nodes
```][Der Stern markiert den aktiven Kontext. Deine anderen Kontexte sind noch da.]

#pruefe[
  Der Stern steht bei `k3s2`, und du siehst vom Laptop aus denselben `NotReady`-Node. Prüfe den Kontext künftig immer, bevor du etwas löschst.
]

== Cilium installieren

Dein `cilium/values.yaml` enthält schon alles Nötige. Die beiden wichtigsten Zeilen sind `k8sServiceHost` und `k8sServicePort`.

#warum[
  Ohne kube-proxy gibt es zunächst niemanden, der die Service-IP `10.43.0.1` übersetzt, das erledigt ja Cilium selbst. Der Cilium-Agent müsste den API-Server aber erreichen, um zu starten. Dieses Henne-Ei-Problem löst die direkte Adresse `172.16.0.136:6443`.
]

#cmd("Mac")[```bash
helm upgrade --install cilium \
  oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 -n kube-system \
  -f cilium/values.yaml --wait
```][`upgrade --install` funktioniert beim ersten Mal und bei jeder Wiederholung. `--wait` kehrt erst zurück, wenn alle Pods bereit sind.]

#cmd("Mac")[```bash
kubectl get nodes
```][Jetzt sollte der Node auf `Ready` stehen.]

#cmd("Mac")[```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg status --brief
```][Fragt den Agenten direkt. `ds/cilium` wählt einen Pod des DaemonSets, `-c` den Container.]

#cmd("Mac")[```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-dbg status | grep KubeProxyReplacement
```][Bestätigt, dass Cilium den kube-proxy ersetzt. Erwartet ist `True`.]

#cmd("Mac")[```bash
kubectl run dns-test --rm -it --restart=Never \
  --image=busybox:1.36 -- \
  nslookup kubernetes.default.svc.cluster.local
```][Startet einen Wegwerf-Pod und testet in einem Schritt Pod-Netz, DNS und Service-Routing. `--rm` entfernt ihn danach.]

#pruefe[
  `nslookup` antwortet mit der Adresse `10.43.0.1`. Das beweist: CoreDNS ist erreichbar, und die Service-IP funktioniert ohne kube-proxy.
]

== Hubble ausprobieren

Hubble ist Ciliums Beobachtungswerkzeug. Es zeigt jede Netzwerkverbindung im Cluster mit der Entscheidung, ob sie erlaubt wurde. Bis zum Monitoring in Kapitel 10 ist es dein wichtigstes Auge.

#cmd("Mac")[```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --last 10
```][Zeigt die letzten zehn Netzwerkflüsse auf dem Node. Der Hubble-Client steckt im Agent-Image, du musst nichts installieren.]

#cmd("Mac")[```bash
kubectl -n kube-system port-forward svc/hubble-ui 12000:80
```][Macht die grafische Oberfläche unter #link("http://localhost:12000") erreichbar. Beenden mit `Ctrl-C`.]

#aufgabe[
  Öffne in einem zweiten Terminal `hubble observe --follow` (mit dem `exec`-Präfix von oben) und starte erneut den `dns-test`. Findest du die DNS-Anfrage zu `kube-dns` im Strom der Flüsse?
]

#gelernt(
  [Das CNI legst du bei der Installation fest, nicht danach.],
  [Die `config.yaml` muss vor der Installation auf der VM liegen.],
  [Ohne kube-proxy muss Cilium den API-Server direkt kennen.],
  [`KUBECONFIG` mit `--flatten` führt Kubeconfigs zusammen, ohne andere Kontexte zu gefährden.],
  [Mit Hubble siehst du ab jetzt jede Verbindung im Cluster.],
)

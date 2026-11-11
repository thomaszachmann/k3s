#import "../lib.typ": *

#kapitel(
  [Drei k3s-Cluster als Fundament],
  ziel: [Aus drei leeren Ubuntu-VMs werden drei Cluster. Dein Laptop steuert sie über die Kontexte `obs`, `app1` und `app2`, und alle kennen die Namen und die CA der Zentrale.],
  zeit: [90 Minuten],
  braucht: [Drei Ubuntu-VMs mit SSH-Zugang, das geklonte Repo],
)

== Was du aufbaust

Jede VM wird ein eigenständiger Cluster mit genau einem Node. Die drei Cluster wissen nichts voneinander, sie teilen kein Netz und keine Konten. Verbunden werden sie erst später, über HTTPS zur Zentrale.

#tabelle(
  (auto, auto, auto, auto),
  ([VM], [IP], [k3s-Konfiguration], [Kontext]),
  [`k3s-obs`], [`172.16.0.126`], [`observability/k3s/config-obs.yaml`], [`obs`],
  [`k3s-app1`], [`172.16.0.228`], [`observability/k3s/config-app1.yaml`], [`app1`],
  [`k3s-app2`], [`172.16.0.83`], [`observability/k3s/config-app2.yaml`], [`app2`],
)

Du nutzt k3s so, wie es ausgeliefert wird: Flannel als Netzwerk, Traefik als Ingress, ServiceLB für die Ports 80 und 443 und `local-path` für Volumes. So bleibt der Fokus auf der Observability.

Gib jeder VM eine feste IP oder eine DHCP-Reservierung. Die Adressen stehen in den Konfigurationen und im DNS, sie dürfen sich später nicht mehr ändern.

#hinweis("Läuft auf einer VM schon k3s?", warn, warn-hell)[
  Dann entferne es zuerst mit `sudo /usr/local/bin/k3s-uninstall.sh`. Das löscht den Cluster samt Daten unwiderruflich.
]

== Die k3s-Konfiguration

Alle drei Dateien sind gleich aufgebaut, nur Name und IP unterscheiden sich:

#datei("observability/k3s/config-obs.yaml (Ausschnitt)", ```yaml
node-name: k3s-obs
node-ip: 172.16.0.126
tls-san:
  - 172.16.0.126
cluster-init: true
secrets-encryption: true
write-kubeconfig-mode: "0600"
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"
etcd-expose-metrics: true
```, erklaerung: [
  `tls-san` nimmt die IP ins Zertifikat des API-Servers auf, damit `kubectl` vom Mac aus die Verbindung prüfen kann. `cluster-init: true` startet eingebettetes etcd statt SQLite. Das brauchst du für die Snapshots in Kapitel 12. `etcd-expose-metrics` macht die etcd-Metriken auf Port 2381 der Node-IP abrufbar. Die Netze dürfen sich zwischen den Clustern wiederholen, weil keiner in den anderen hineinroutet.
])

#cmd("Mac")[```bash
scp observability/k3s/config-obs.yaml <user>@172.16.0.126:/tmp/config.yaml
scp observability/k3s/config-app1.yaml <user>@172.16.0.228:/tmp/config.yaml
scp observability/k3s/config-app2.yaml <user>@172.16.0.83:/tmp/config.yaml
```][Kopiert jeder VM ihre eigene Konfiguration. Achte darauf, dass Datei und IP zusammenpassen. Eine vertauschte Datei gibt der VM den falschen Namen und die falsche IP.]

== Die VM obs vorbereiten

Die folgenden Schritte zeigt das Buch für `obs`. Danach wiederholst du sie auf `app1` und `app2`.

#cmd("Mac")[```bash
ssh <user>@172.16.0.126
```][Öffnet die Sitzung auf der Zentrale. Alle Schritte mit dem Etikett *obs* laufen hier.]

#cmd("obs")[```bash
sudo hostnamectl set-hostname k3s-obs
```][Der Hostname sollte zum `node-name` aus der Konfiguration passen. Das erspart Verwirrung in Logs und Prompts.]

#cmd("obs")[```bash
sudo apt update && sudo apt -y upgrade
```][Bringt das System auf den aktuellen Stand.]

#cmd("obs")[```bash
sudo ufw status
```][Ubuntus Firewall ist meist inaktiv. Bei `inactive` machst du einfach weiter.]

Ist die Firewall aktiv, müssen API-Server, Pod- und Service-Netz und auf `obs` auch HTTPS durchkommen:

#cmd("obs")[```bash
sudo ufw allow 6443/tcp
sudo ufw allow 443/tcp
sudo ufw allow from 10.42.0.0/16 to any
sudo ufw allow from 10.43.0.0/16 to any
```][Port 6443 ist der API-Server für `kubectl` vom Mac. Port 443 braucht nur `obs`, denn dort nimmt Traefik die Daten der App-Cluster an. Lass Port 22 offen, sonst sperrst du dich aus.]

== k3s installieren

#cmd("obs")[```bash
sudo install -D -m 600 -o root -g root \
  /tmp/config.yaml /etc/rancher/k3s/config.yaml
rm /tmp/config.yaml
```][`install` kopiert die Datei und setzt Rechte in einem Schritt. `-D` legt das Verzeichnis an. Die Datei muss *vor* der Installation hier liegen, sonst startet k3s ohne etcd, und das lässt sich nicht einfach nachholen.]

#cmd("obs")[```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION=v1.36.6+k3s1 sh -
```][Installiert genau die Version, mit der dieses Buch arbeitet. Ohne `INSTALL_K3S_VERSION` bekämst du den Kanal `stable`, und alle drei Cluster könnten später unterschiedliche Versionen haben.]

#cmd("obs")[```bash
sudo k3s kubectl get nodes -o wide
```][Fragt den Cluster direkt auf der VM ab.]

#pruefe[
  Der Node `k3s-obs` steht nach etwa einer Minute auf `Ready`, Version `v1.36.6+k3s1`, `INTERNAL-IP` `172.16.0.126`. Startet k3s nicht, zeigt `sudo journalctl -u k3s -n 50` den Grund.
]

#cmd("obs")[```bash
sudo k3s kubectl get pods -n kube-system
```][Zeigt die mitgelieferten Komponenten.]

#pruefe[
  `coredns`, `local-path-provisioner`, `metrics-server` und `traefik` laufen, dazu ein `svclb-traefik`-Pod. Die beiden `helm-install`-Pods stehen auf `Completed`. Das ist richtig, sie haben Traefik installiert und sind fertig.
]

#cmd("obs")[```bash
sudo install -m 600 -o "$USER" \
  /etc/rancher/k3s/k3s.yaml /tmp/k3s.yaml
exit
```][Die Kubeconfig gehört root. `install` legt eine Kopie an, die dein Benutzer per `scp` holen darf, und nur er kann sie lesen. Sie enthält volle Admin-Rechte. Danach geht es zurück zum Mac.]

== Dasselbe auf app1 und app2

Wiederhole die Schritte dieses und des vorigen Abschnitts auf den beiden anderen VMs. Nur drei Dinge ändern sich:

#tabelle(
  (auto, 1fr, 1fr),
  ([], [app1], [app2]),
  [SSH], [`ssh <user>@172.16.0.228`], [`ssh <user>@172.16.0.83`],
  [Hostname], [`k3s-app1`], [`k3s-app2`],
  [Firewall], [ohne Port 443], [ohne Port 443],
)

#falle[
  Wer drei Terminals offen hat, tippt leicht in das falsche. Der Hostname im Prompt hilft. Er wechselt allerdings erst bei der nächsten Anmeldung. Prüfe nach `hostnamectl` deshalb mit `hostname`, wo du bist.
]

== Die Kubeconfigs zusammenführen

In `~/.kube/config` liegen vielleicht schon andere Kontexte. Du überschreibst die Datei deshalb nicht, sondern fügst die drei neuen Cluster hinzu.

#cmd("Mac")[```bash
mkdir -p ~/.kube
[ -f ~/.kube/config ] && cp -p ~/.kube/config ~/.kube/config.bak-obs
```][Sicherung der bestehenden Datei, falls es eine gibt. Geht etwas schief, kopierst du sie zurück.]

#cmd("Mac")[```bash
scp <user>@172.16.0.126:/tmp/k3s.yaml ~/.kube/obs.raw
scp <user>@172.16.0.228:/tmp/k3s.yaml ~/.kube/app1.raw
scp <user>@172.16.0.83:/tmp/k3s.yaml  ~/.kube/app2.raw
```][Holt die drei Kubeconfigs auf den Mac. Jede Datei bekommt den Namen ihres Clusters, damit du sie nicht verwechselst.]

#cmd("Mac")[```bash
ssh <user>@172.16.0.126 'rm /tmp/k3s.yaml'
ssh <user>@172.16.0.228 'rm /tmp/k3s.yaml'
ssh <user>@172.16.0.83  'rm /tmp/k3s.yaml'
```][Löscht die Kopien auf den VMs wieder. Sie enthalten volle Admin-Rechte und sollen nicht in `/tmp` liegen bleiben.]

#cmd("Mac")[```bash
sed -e 's/127\.0\.0\.1/172.16.0.126/' -e 's/: default$/: obs/' \
  ~/.kube/obs.raw > ~/.kube/obs.yaml
sed -e 's/127\.0\.0\.1/172.16.0.228/' -e 's/: default$/: app1/' \
  ~/.kube/app1.raw > ~/.kube/app1.yaml
sed -e 's/127\.0\.0\.1/172.16.0.83/' -e 's/: default$/: app2/' \
  ~/.kube/app2.raw > ~/.kube/app2.yaml
```][Jede Datei zeigt auf `127.0.0.1` und nennt Cluster, Benutzer und Kontext `default`. Der erste Ausdruck von `sed` setzt die IP der VM ein, der zweite benennt alles nach dem Cluster um. Ohne die Umbenennung hießen alle drei Einträge `default` und würden sich beim Zusammenführen gegenseitig überschreiben.]

#cmd("Mac")[```bash
kubectl config get-contexts
```][Zeigt deine bisherigen Kontexte. Stehen `obs`, `app1` oder `app2` schon dort, entferne sie zuerst:]

#cmd("Mac")[```bash
kubectl config delete-context obs
kubectl config delete-cluster obs
kubectl config delete-user obs
```][Nur nötig, wenn ein gleichnamiger Eintrag existiert, und dann für jeden betroffenen Namen. Alte Einträge würden beim Zusammenführen gewinnen, und `kubectl` meldete `x509`-Fehler.]

#cmd("Mac")[```bash
KUBECONFIG=~/.kube/config:~/.kube/obs.yaml:~/.kube/app1.yaml:~/.kube/app2.yaml \
  kubectl config view --flatten > ~/.kube/config.neu
```][Mehrere Dateien in `KUBECONFIG` führt `kubectl` zusammen. `--flatten` schreibt die Zertifikate direkt in die Ausgabe, damit die neue Datei allein funktioniert.]

#cmd("Mac")[```bash
chmod 600 ~/.kube/config.neu
mv ~/.kube/config.neu ~/.kube/config
rm ~/.kube/{obs,app1,app2}.{raw,yaml}
```][Setzt die neue Datei mit den richtigen Rechten ein und löscht die Zwischendateien mit den Admin-Zugangsdaten.]

#cmd("Mac")[```bash
kubectl --context obs  get nodes
kubectl --context app1 get nodes
kubectl --context app2 get nodes
```][Fragt jeden Cluster über seinen eigenen Kontext ab.]

#pruefe[
  Drei Blöcke mit je einem Node, alle `Ready`:
  ```
  NAME      STATUS   ROLES                AGE   VERSION
  k3s-obs   Ready    control-plane,etcd   5m    v1.36.6+k3s1
  NAME       STATUS   ROLES                AGE   VERSION
  k3s-app1   Ready    control-plane,etcd   5m    v1.36.6+k3s1
  NAME       STATUS   ROLES                AGE   VERSION
  k3s-app2   Ready    control-plane,etcd   5m    v1.36.6+k3s1
  ```
  Deine alten Kontexte sind weiterhin in `kubectl config get-contexts` zu sehen.
]

#warum[
  Ab hier steht in jedem Befehl `--context`. Das ist umständlicher als `kubectl config use-context`, schützt dich aber vor dem klassischen Fehler, einen Befehl für `app1` versehentlich auf der Zentrale auszuführen.
]

== Der Namespace monitoring

Alle Observability-Komponenten liegen in jedem Cluster im Namespace `monitoring`. Lege ihn jetzt an, denn TLS-Secret und CA kommen gleich hinein.

#cmd("Mac")[```bash
kubectl --context obs  create namespace monitoring
kubectl --context app1 create namespace monitoring
kubectl --context app2 create namespace monitoring
```][Legt den Namespace in jedem Cluster an. Führst du den Befehl ein zweites Mal aus, meldet `kubectl` `AlreadyExists`. Das ist harmlos, der Namespace ist dann schon da.]

#pruefe[
  Dreimal `namespace/monitoring created`.
]

== Namen für die Zentrale

Die App-Cluster erreichen die Zentrale später unter Namen wie `receive.obs.internal`. Diese Namen gibt es in keinem öffentlichen DNS. Du trägst sie an zwei Stellen ein: im CoreDNS jedes Clusters und auf dem Mac.

k3s bringt dafür einen eingebauten Haken mit. CoreDNS lädt alle Schlüssel der ConfigMap `coredns-custom` im Namespace `kube-system`, die auf `.server` enden, als eigene Server-Blöcke.

#datei("observability/k3s/coredns-custom.yaml", ```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  obs.server: |
    obs.internal:53 {
        errors
        cache 30
        hosts {
            172.16.0.126 grafana.obs.internal
            172.16.0.126 receive.obs.internal
            172.16.0.126 loki.obs.internal
            172.16.0.126 tempo.obs.internal
            172.16.0.126 alertmanager.obs.internal
            172.16.0.126 s3.obs.internal
            fallthrough
        }
    }
```, erklaerung: [
  Der Block gilt nur für die Zone `obs.internal`. Alle anderen Anfragen beantwortet CoreDNS wie bisher. Alle Namen zeigen auf die IP von `obs`, wo Traefik auf Port 443 wartet und nach Hostname weiterleitet. `s3.obs.internal` brauchst du erst in Kapitel 12 für die Backups. Er steht schon hier, damit du die Datei nur einmal anwenden musst.
])

#cmd("Mac")[```bash
kubectl --context obs  apply -f observability/k3s/coredns-custom.yaml
kubectl --context app1 apply -f observability/k3s/coredns-custom.yaml
kubectl --context app2 apply -f observability/k3s/coredns-custom.yaml
```][Wendet dieselbe Datei auf alle drei Cluster an. Auch `obs` braucht die Namen, etwa wenn Grafana später Links auf sich selbst prüft.]

#cmd("Mac")[```bash
kubectl --context obs  -n kube-system rollout restart deploy/coredns
kubectl --context app1 -n kube-system rollout restart deploy/coredns
kubectl --context app2 -n kube-system rollout restart deploy/coredns
```][CoreDNS bemerkt die neue ConfigMap zwar von selbst, das kann aber über eine Minute dauern. Der Neustart macht es sofort wirksam.]

#cmd("Mac")[```bash
kubectl --context app1 run dns-test --rm -it --restart=Never \
  --image=busybox:1.36 -- nslookup receive.obs.internal
```][Startet einen Wegwerf-Pod in `app1` und fragt den Namen ab. `--rm` entfernt den Pod danach.]

#pruefe[
  Die Antwort enthält `Name: receive.obs.internal` und `Address: 172.16.0.126`. Meldet `nslookup` dagegen `NXDOMAIN`, ist die ConfigMap noch nicht angekommen oder der Schlüssel endet nicht auf `.server`.
]

#falle[
  Der Name `coredns-custom` ist fest. Eine ConfigMap mit anderem Namen ignoriert k3s stillschweigend. Ebenso werden Schlüssel, die auf `.override` statt `.server` enden, in den Hauptblock eingefügt. Dort wäre ein eigener Zonen-Block ein Syntaxfehler, und CoreDNS startete nicht mehr.
]

Auf dem Mac genügt ein Eintrag in `/etc/hosts`:

#cmd("Mac")[```bash
echo "172.16.0.126 grafana.obs.internal receive.obs.internal" \
  "loki.obs.internal tempo.obs.internal alertmanager.obs.internal" \
  "s3.obs.internal" | sudo tee -a /etc/hosts
```][`echo` verbindet beide Teile mit einem Leerzeichen zu einer Zeile, `tee -a` hängt sie an. Ein einfaches `sudo echo ... >> /etc/hosts` würde scheitern, weil die Umleitung nicht mit root-Rechten läuft.]

#cmd("Mac")[```bash
dscacheutil -q host -a name grafana.obs.internal
```][Fragt den Namen so ab, wie macOS-Programme es tun.]

#pruefe[
  Die Ausgabe enthält `ip_address: 172.16.0.126`. Steht dort nichts, hilft `sudo dscacheutil -flushcache`.
]

== Eine eigene CA für TLS

Die App-Cluster schicken später Zugangsdaten und Messwerte über das Netz zur Zentrale. Dabei müssen zwei Dinge gelten:

- *Verschlüsselung:* Niemand im Netz soll Passwörter oder Logs mitlesen. Das leistet TLS, also HTTPS.
- *Echtheit:* Alloy in `app1` muss sicher sein, dass am anderen Ende wirklich `obs` antwortet und kein fremder Rechner, der sich die IP geschnappt hat. Dafür zeigt der Server ein Zertifikat vor, und der Client prüft, wer es unterschrieben hat.

Im Internet unterschreibt eine öffentliche Zertifizierungsstelle (CA) wie Let's Encrypt. Die stellt aber keine Zertifikate für erfundene Namen wie `obs.internal` aus. Du baust dir deshalb eine eigene kleine CA. Das sind nur zwei Dateien: ein geheimer Schlüssel, mit dem die CA unterschreibt, und ein öffentliches Zertifikat, an dem jeder ihre Unterschrift erkennt.

#datei("Die Vertrauenskette", ```text
  ca.key  (geheim, bleibt auf dem Mac)
     │ unterschreibt
     ▼
  obs.internal.crt + obs.internal.key ──► Traefik auf obs zeigt es vor
     ▲
     │ prüft die Unterschrift
  ca.crt  (öffentlich) ──► liegt in allen Clustern und auf dem Mac
```, erklaerung: [
  Ein Client vertraut dem Zertifikat von `obs`, weil es mit `ca.key` unterschrieben ist und er `ca.crt` kennt. Mehr braucht er nicht. Deshalb bekommen `app1` und `app2` nur das öffentliche `ca.crt`, nie einen Schlüssel.
])

Ein einziges Wildcard-Zertifikat für `*.obs.internal` deckt alle Namen der Zentrale ab, von `grafana` bis `s3`. Welche Eigenschaften die beiden Zertifikate bekommen, steht in einer kleinen Konfigurationsdatei:

#datei("observability/tls/openssl.cnf (Ausschnitt)", ```ini
[ v3_ca ]
basicConstraints     = critical, CA:true, pathlen:0
keyUsage             = critical, keyCertSign, cRLSign

[ v3_server ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectAltName         = @alt_names

[ alt_names ]
DNS.1 = *.obs.internal
DNS.2 = obs.internal
```, erklaerung: [
  Die Datei enthält zwei Sätze von Erweiterungen, und jeder Befehl wählt mit `-extensions` einen davon aus. `v3_ca` macht ein Zertifikat zur CA: `CA:true` erlaubt das Unterschreiben, `pathlen:0` verbietet Unter-CAs, und `keyUsage` beschränkt den Schlüssel auf genau diese Aufgabe. `v3_server` beschreibt das Server-Zertifikat: `CA:false` verhindert, dass jemand damit weitere Zertifikate ausstellt, und `serverAuth` erlaubt den Einsatz für HTTPS-Server. Entscheidend ist `subjectAltName`: Browser und Go-Programme wie Alloy prüfen nur diese Namensliste, den Common Name ignorieren sie.
])

Jetzt erzeugst du die CA. Alle Dateien landen in `observability/tls/`.

#cmd("Mac")[```bash
openssl req -x509 -new -nodes -newkey rsa:4096 -days 3650 \
  -keyout observability/tls/ca.key -out observability/tls/ca.crt \
  -config observability/tls/openssl.cnf -extensions v3_ca \
  -subj "/CN=obs-lab CA"
```][Erzeugt in einem Schritt den Schlüssel der CA und ihr Zertifikat.]

Die Optionen im Einzelnen:

#tabelle(
  (auto, 1fr),
  ([Option], [Bedeutung]),
  [`req -new`], [Erzeugt eine neue Zertifikatsanfrage. `req` ist das Werkzeug von OpenSSL für Anfragen und Zertifikate.],
  [`-x509`], [Macht aus der Anfrage sofort ein fertiges Zertifikat, das sich selbst unterschreibt. Eine CA hat niemanden über sich, der sie unterschreiben könnte.],
  [`-newkey rsa:4096`], [Erzeugt dabei einen neuen RSA-Schlüssel mit 4096 Bit. Die CA lebt lange, deshalb bekommt sie einen starken Schlüssel.],
  [`-nodes`], [„no DES“: Der Schlüssel wird ohne Passwort gespeichert. Im Labor ist das bequem, in der Produktion gehört er verschlüsselt und offline.],
  [`-days 3650`], [Gültigkeit zehn Jahre. Läuft die CA ab, musst du allen Clients ein neues `ca.crt` geben.],
  [`-keyout`, `-out`], [Wohin Schlüssel und Zertifikat geschrieben werden.],
  [`-config`, `-extensions`], [Liest die Erweiterungen aus dem Abschnitt `v3_ca` der Datei oben.],
  [`-subj`], [Der Name der CA. Er erscheint später als „Aussteller“ in jedem Zertifikat, das sie unterschreibt.],
)

Als Nächstes braucht der Server, also Traefik auf `obs`, einen eigenen Schlüssel und ein Zertifikat. Das geschieht in zwei Schritten, genau wie bei einer echten CA: Der Server stellt eine Anfrage, die CA unterschreibt sie.

#cmd("Mac")[```bash
openssl req -new -nodes -newkey rsa:2048 \
  -keyout observability/tls/obs.internal.key \
  -out observability/tls/obs.internal.csr \
  -config observability/tls/openssl.cnf -subj "/CN=*.obs.internal"
```][Erzeugt den Schlüssel für das Server-Zertifikat und eine Zertifikatsanfrage (CSR, Certificate Signing Request).]

Der Befehl ähnelt dem vorigen, nur *ohne* `-x509`. Damit entsteht kein fertiges Zertifikat, sondern eine Anfrage: „Bitte bestätige, dass dieser öffentliche Schlüssel zu `*.obs.internal` gehört.“ Der private Schlüssel `obs.internal.key` verlässt dabei nie deinen Rechner, in der Anfrage steckt nur der öffentliche Teil. 2048 Bit genügen, denn das Server-Zertifikat tauschst du ohnehin alle zwei Jahre aus.

#cmd("Mac")[```bash
openssl x509 -req -in observability/tls/obs.internal.csr \
  -CA observability/tls/ca.crt -CAkey observability/tls/ca.key \
  -set_serial "0x$(openssl rand -hex 16)" -days 825 -sha256 \
  -extfile observability/tls/openssl.cnf -extensions v3_server \
  -out observability/tls/obs.internal.crt
```][Die CA unterschreibt die Anfrage. Heraus kommt das fertige Server-Zertifikat.]

#tabelle(
  (auto, 1fr),
  ([Option], [Bedeutung]),
  [`x509 -req -in`], [Liest eine Anfrage ein, statt ein Zertifikat zu bearbeiten.],
  [`-CA`, `-CAkey`], [Wer unterschreibt: das Zertifikat und der geheime Schlüssel der CA.],
  [`-set_serial`], [Jedes Zertifikat einer CA braucht eine eindeutige Seriennummer. `openssl rand -hex 16` würfelt eine. Das erspart die Datei `ca.srl`, in der OpenSSL sonst mitzählt.],
  [`-days 825`], [Gültigkeit gut zwei Jahre. Das ist das Maximum, das macOS bei Server-Zertifikaten akzeptiert.],
  [`-sha256`], [Das Hash-Verfahren der Unterschrift. Ältere Verfahren wie SHA-1 lehnen Browser ab.],
  [`-extfile`, `-extensions`], [Fügt die Erweiterungen aus `v3_server` hinzu, vor allem die Namensliste `subjectAltName`. Ohne sie wäre das Zertifikat für Alloy und Browser wertlos.],
)

#cmd("Mac")[```bash
rm observability/tls/obs.internal.csr
chmod 600 observability/tls/*.key
```][Die Anfrage hat ihren Zweck erfüllt und kann weg. Die beiden Schlüssel darf danach nur noch dein Benutzer lesen.]

#warum[
  Wer `ca.key` besitzt, kann Zertifikate für beliebige Namen unter `obs.internal` ausstellen, und alle deine Cluster würden ihnen glauben. Wer `obs.internal.key` besitzt, kann sich als Zentrale ausgeben. Beide Schlüssel sind deshalb so wertvoll wie ein Admin-Passwort. Die `.crt`-Dateien dagegen sind öffentlich, sie dürfen ins Repo.
]

Bevor du die Dateien verteilst, prüfst du, ob alles stimmt. Ein Fehler hier zeigt sich sonst erst viel später als rätselhafter `x509`-Fehler in Alloy.

#cmd("Mac")[```bash
openssl verify -CAfile observability/tls/ca.crt observability/tls/obs.internal.crt
openssl x509 -in observability/tls/obs.internal.crt -noout -text \
  | grep -A1 "Subject Alternative Name"
```][Der erste Befehl macht genau das, was später jeder Client tut: Er prüft, ob das Server-Zertifikat von dieser CA unterschrieben und noch gültig ist. Der zweite zeigt die Namensliste, für die das Zertifikat gilt. Beide funktionieren mit dem LibreSSL von macOS und mit OpenSSL 3.]

#pruefe[
  ```
  observability/tls/obs.internal.crt: OK
              X509v3 Subject Alternative Name:
                  DNS:*.obs.internal, DNS:obs.internal
  ```
]

#cmd("Mac")[```bash
git check-ignore -v observability/tls/ca.key observability/tls/obs.internal.key
```][Fragt Git, ob die Schlüssel vom Commit ausgeschlossen sind.]

#pruefe[
  Für beide Dateien nennt Git die Regel `*.key` aus `.gitignore`:
  ```
  .gitignore:2:*.key	observability/tls/ca.key
  .gitignore:2:*.key	observability/tls/obs.internal.key
  ```
  Gibt der Befehl nichts aus, würden die Schlüssel beim nächsten Commit mitgehen. Dann ergänze die Regel, bevor du weitermachst.
]

== Zertifikat und CA in die Cluster bringen

Die Dateien liegen jetzt auf deinem Mac. Die Programme, die sie brauchen, laufen aber in den Clustern. In Kubernetes gibst du einem Pod Dateien über zwei Objekte: ein *Secret* für vertrauliche Daten und eine *ConfigMap* für alles andere. Der Pod bindet sie als Datei ein oder liest sie als Umgebungsvariable. So steht kein Schlüssel im Image oder in der Helm-Konfiguration.

Wer braucht was?

#tabelle(
  (auto, auto, 1fr),
  ([Objekt], [Cluster], [Wozu]),
  [Secret `obs-tls`], [nur `obs`], [Traefik zeigt Zertifikat und Schlüssel jedem Client vor, der `https://*.obs.internal` aufruft. Nur die Zentrale nimmt Verbindungen an, deshalb liegt der Schlüssel nur dort.],
  [ConfigMap `obs-ca`], [alle drei], [Alloy, Grafana und die anderen Clients prüfen damit das Zertifikat der Zentrale. Ohne CA bricht jede Verbindung mit `x509: certificate signed by unknown authority` ab.],
)

#cmd("Mac")[```bash
kubectl --context obs -n monitoring create secret tls obs-tls \
  --cert=observability/tls/obs.internal.crt \
  --key=observability/tls/obs.internal.key
```][Legt das Secret `obs-tls` vom Typ `kubernetes.io/tls` an. Dieser Typ hat genau zwei Schlüssel, `tls.crt` und `tls.key`, und Traefik weiß, wie er ihn liest. Die Ingress-Objekte der Zentrale verweisen ab Kapitel 4 darauf.]

#cmd("Mac")[```bash
kubectl --context obs  -n monitoring create configmap obs-ca \
  --from-file=ca.crt=observability/tls/ca.crt
kubectl --context app1 -n monitoring create configmap obs-ca \
  --from-file=ca.crt=observability/tls/ca.crt
kubectl --context app2 -n monitoring create configmap obs-ca \
  --from-file=ca.crt=observability/tls/ca.crt
```][Verteilt das öffentliche CA-Zertifikat als ConfigMap `obs-ca`. `--from-file=ca.crt=...` legt fest, dass der Schlüssel in der ConfigMap `ca.crt` heißt. Bindet Alloy die ConfigMap später unter `/etc/obs-ca` ein, entsteht daraus die Datei `/etc/obs-ca/ca.crt`. Es ist kein Geheimnis, deshalb genügt eine ConfigMap.]

#cmd("Mac")[```bash
kubectl --context obs  -n monitoring get secret obs-tls
kubectl --context obs  -n monitoring get configmap obs-ca
kubectl --context app1 -n monitoring get configmap obs-ca
kubectl --context app2 -n monitoring get configmap obs-ca
```][Kontrolliert, dass alles am richtigen Ort liegt.]

#pruefe[
  `obs-tls` hat den Typ `kubernetes.io/tls` und `DATA 2`, also Zertifikat und Schlüssel. Die ConfigMap `obs-ca` steht in allen drei Clustern mit `DATA 1`:
  ```
  NAME      TYPE                DATA   AGE
  obs-tls   kubernetes.io/tls   2      5s
  NAME     DATA   AGE
  obs-ca   1      4s
  ```
]

Ob Traefik das Zertifikat wirklich ausliefert, kannst du erst testen, wenn in Kapitel 4 der erste Ingress steht. Dort holst du das nach.

Auf dem Mac nutzen alle Befehle im Buch die CA direkt, etwa mit `curl --cacert observability/tls/ca.crt`. Möchtest du Grafana später ohne Warnung im Browser öffnen, kannst du der CA zusätzlich im Schlüsselbund vertrauen:

#cmd("Mac")[```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain observability/tls/ca.crt
```][Optional. Damit vertraut macOS allen Zertifikaten dieser CA. Hast du die CA schon einmal erzeugt, lösche den alten Eintrag „obs-lab CA“ vorher in der Schlüsselbundverwaltung unter „System“. Sonst zeigt der Browser trotzdem eine Warnung, weil er das alte Zertifikat findet.]

#falle[
  Läuft das Zertifikat ab, brechen alle Verbindungen der App-Cluster gleichzeitig ab. 825 Tage sind lang, aber nicht ewig. In Kapitel 13 baust du einen Alarm, der dich 30 Tage vorher warnt.
]

#aufgabe[
  Ein Kollege fragt, warum `app1` die CA braucht, aber kein Zertifikat. Erkläre es ihm in zwei Sätzen. Überlege dann: Was müsstest du tun, wenn ein vierter Cluster `app3` dazukommt?
]

#gelernt(
  [Die k3s-Konfiguration muss vor der Installation auf der VM liegen, und `INSTALL_K3S_VERSION` hält alle Cluster auf derselben Version.],
  [Umbenannte Kubeconfigs lassen sich mit `KUBECONFIG` und `--flatten` gefahrlos zusammenführen.],
  [`--context` in jedem Befehl schützt vor dem falschen Cluster.],
  [Die ConfigMap `coredns-custom` mit einem `.server`-Schlüssel ergänzt CoreDNS um eine eigene Zone.],
  [Eine eigene CA mit Wildcard-Zertifikat reicht für TLS im Labor. Die Clients brauchen nur das CA-Zertifikat.],
)

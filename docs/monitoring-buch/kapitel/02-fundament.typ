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
  [`k3s-obs`], [`172.16.0.150`], [`observability/k3s/config-obs.yaml`], [`obs`],
  [`k3s-app1`], [`172.16.0.151`], [`observability/k3s/config-app1.yaml`], [`app1`],
  [`k3s-app2`], [`172.16.0.152`], [`observability/k3s/config-app2.yaml`], [`app2`],
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
node-ip: 172.16.0.150
tls-san:
  - 172.16.0.150
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
scp observability/k3s/config-obs.yaml <user>@172.16.0.150:/tmp/config.yaml
scp observability/k3s/config-app1.yaml <user>@172.16.0.151:/tmp/config.yaml
scp observability/k3s/config-app2.yaml <user>@172.16.0.152:/tmp/config.yaml
```][Kopiert jeder VM ihre eigene Konfiguration. Achte darauf, dass Datei und IP zusammenpassen. Eine vertauschte Datei gibt der VM den falschen Namen und die falsche IP.]

== Die VM obs vorbereiten

Die folgenden Schritte zeigt das Buch für `obs`. Danach wiederholst du sie auf `app1` und `app2`.

#cmd("Mac")[```bash
ssh <user>@172.16.0.150
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
  Der Node `k3s-obs` steht nach etwa einer Minute auf `Ready`, Version `v1.36.6+k3s1`, `INTERNAL-IP` `172.16.0.150`. Startet k3s nicht, zeigt `sudo journalctl -u k3s -n 50` den Grund.
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
  [SSH], [`ssh <user>@172.16.0.151`], [`ssh <user>@172.16.0.152`],
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
for n in obs:150 app1:151 app2:152; do
  scp <user>@172.16.0.${n#*:}:/tmp/k3s.yaml ~/.kube/${n%%:*}.raw
  ssh <user>@172.16.0.${n#*:} 'rm /tmp/k3s.yaml'
done
```][Holt die drei Kubeconfigs und löscht die Admin-Kopien auf den VMs. `${n%%:*}` ist der Teil vor dem Doppelpunkt (der Name), `${n#*:}` der Teil danach (das Ende der IP).]

#cmd("Mac")[```bash
for n in obs:150 app1:151 app2:152; do
  sed -e "s/127\.0\.0\.1/172.16.0.${n#*:}/" \
      -e "s/: default\$/: ${n%%:*}/" \
      ~/.kube/${n%%:*}.raw > ~/.kube/${n%%:*}.yaml
done
```][Jede Datei zeigt auf `127.0.0.1` und nennt Cluster, Benutzer und Kontext `default`. `sed` setzt die richtige IP ein und benennt alles nach dem Cluster um. Ohne die Umbenennung würden sich die drei Dateien beim Zusammenführen gegenseitig überschreiben.]

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
for c in obs app1 app2; do kubectl --context $c get nodes; done
```][Fragt jeden Cluster über seinen eigenen Kontext ab.]

#pruefe[
  Drei Blöcke mit je einem Node: `k3s-obs`, `k3s-app1` und `k3s-app2`, alle `Ready`. Deine alten Kontexte sind weiterhin in `kubectl config get-contexts` zu sehen.
]

#warum[
  Ab hier steht in jedem Befehl `--context`. Das ist umständlicher als `kubectl config use-context`, schützt dich aber vor dem klassischen Fehler, einen Befehl für `app1` versehentlich auf der Zentrale auszuführen.
]

== Der Namespace monitoring

Alle Observability-Komponenten liegen in jedem Cluster im Namespace `monitoring`. Lege ihn jetzt an, denn TLS-Secret und CA kommen gleich hinein.

#cmd("Mac")[```bash
for c in obs app1 app2; do
  kubectl --context $c create namespace monitoring \
    --dry-run=client -o yaml | kubectl --context $c apply -f -
done
```][`--dry-run=client -o yaml` erzeugt nur das Manifest, `apply` legt es an. Anders als ein nacktes `create` schlägt das bei einer Wiederholung nicht fehl.]

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
            172.16.0.150 grafana.obs.internal
            172.16.0.150 receive.obs.internal
            172.16.0.150 loki.obs.internal
            172.16.0.150 tempo.obs.internal
            172.16.0.150 alertmanager.obs.internal
            fallthrough
        }
    }
```, erklaerung: [
  Der Block gilt nur für die Zone `obs.internal`. Alle anderen Anfragen beantwortet CoreDNS wie bisher. Alle Namen zeigen auf die IP von `obs`, wo Traefik auf Port 443 wartet und nach Hostname weiterleitet.
])

#cmd("Mac")[```bash
for c in obs app1 app2; do
  kubectl --context $c apply -f observability/k3s/coredns-custom.yaml
done
```][Wendet dieselbe Datei auf alle drei Cluster an. Auch `obs` braucht die Namen, etwa wenn Grafana später Links auf sich selbst prüft.]

#cmd("Mac")[```bash
for c in obs app1 app2; do
  kubectl --context $c -n kube-system rollout restart deploy/coredns
done
```][CoreDNS bemerkt die neue ConfigMap zwar von selbst, das kann aber über eine Minute dauern. Der Neustart macht es sofort wirksam.]

#cmd("Mac")[```bash
kubectl --context app1 run dns-test --rm -it --restart=Never \
  --image=busybox:1.36 -- nslookup receive.obs.internal
```][Startet einen Wegwerf-Pod in `app1` und fragt den Namen ab. `--rm` entfernt den Pod danach.]

#pruefe[
  Die Antwort enthält `Name: receive.obs.internal` und `Address: 172.16.0.150`. Meldet `nslookup` dagegen `NXDOMAIN`, ist die ConfigMap noch nicht angekommen oder der Schlüssel endet nicht auf `.server`.
]

#falle[
  Der Name `coredns-custom` ist fest. Eine ConfigMap mit anderem Namen ignoriert k3s stillschweigend. Ebenso werden Schlüssel, die auf `.override` statt `.server` enden, in den Hauptblock eingefügt. Dort wäre ein eigener Zonen-Block ein Syntaxfehler, und CoreDNS startete nicht mehr.
]

Auf dem Mac genügt ein Eintrag in `/etc/hosts`:

#cmd("Mac")[```bash
echo "172.16.0.150 grafana.obs.internal receive.obs.internal" \
  "loki.obs.internal tempo.obs.internal alertmanager.obs.internal" \
  | sudo tee -a /etc/hosts
```][`echo` verbindet beide Teile mit einem Leerzeichen zu einer Zeile, `tee -a` hängt sie an. Ein einfaches `sudo echo ... >> /etc/hosts` würde scheitern, weil die Umleitung nicht mit root-Rechten läuft.]

#cmd("Mac")[```bash
dscacheutil -q host -a name grafana.obs.internal
```][Fragt den Namen so ab, wie macOS-Programme es tun.]

#pruefe[
  Die Ausgabe enthält `ip_address: 172.16.0.150`. Steht dort nichts, hilft `sudo dscacheutil -flushcache`.
]

== Eine eigene CA für TLS

Die App-Cluster schicken Zugangsdaten und Daten über das Netz. Das soll verschlüsselt geschehen, und die Clients sollen prüfen, dass sie wirklich mit der Zentrale sprechen. Dafür erzeugst du eine kleine eigene Zertifizierungsstelle (CA) und mit ihr ein Wildcard-Zertifikat für `*.obs.internal`.

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
  Die Datei enthält zwei Sätze von Erweiterungen. `v3_ca` macht ein Zertifikat zur CA, `pathlen:0` verbietet Unter-CAs. `v3_server` beschreibt das Server-Zertifikat. Entscheidend ist `subjectAltName`: Browser und Go-Programme wie Alloy prüfen nur diese Liste, den Common Name ignorieren sie.
])

#cmd("Mac")[```bash
openssl req -x509 -new -nodes -newkey rsa:4096 -days 3650 \
  -keyout observability/tls/ca.key -out observability/tls/ca.crt \
  -config observability/tls/openssl.cnf -extensions v3_ca \
  -subj "/CN=obs-lab CA"
```][Erzeugt in einem Schritt den Schlüssel der CA und ihr selbst signiertes Zertifikat, gültig für zehn Jahre. `-nodes` speichert den Schlüssel ohne Passwort. Im Labor ist das bequem, in der Produktion gehört er verschlüsselt und offline.]

#cmd("Mac")[```bash
openssl req -new -nodes -newkey rsa:2048 \
  -keyout observability/tls/obs.internal.key \
  -out observability/tls/obs.internal.csr \
  -config observability/tls/openssl.cnf -subj "/CN=*.obs.internal"
```][Erzeugt den Schlüssel für das Server-Zertifikat und eine Zertifikatsanfrage (CSR).]

#cmd("Mac")[```bash
openssl x509 -req -in observability/tls/obs.internal.csr \
  -CA observability/tls/ca.crt -CAkey observability/tls/ca.key \
  -set_serial "0x$(openssl rand -hex 16)" -days 825 -sha256 \
  -extfile observability/tls/openssl.cnf -extensions v3_server \
  -out observability/tls/obs.internal.crt
```][Die CA signiert die Anfrage und fügt die Erweiterungen aus `v3_server` hinzu. Die zufällige Seriennummer erspart eine `.srl`-Datei. 825 Tage sind das Maximum, das macOS bei Server-Zertifikaten akzeptiert.]

#cmd("Mac")[```bash
rm observability/tls/obs.internal.csr
chmod 600 observability/tls/*.key
```][Die Anfrage brauchst du nicht mehr. Die Schlüssel darf nur noch dein Benutzer lesen.]

#cmd("Mac")[```bash
openssl verify -CAfile observability/tls/ca.crt observability/tls/obs.internal.crt
openssl x509 -in observability/tls/obs.internal.crt -noout -text \
  | grep -A1 "Subject Alternative Name"
```][Prüft die Kette und zeigt die Namen im Zertifikat. Beide Befehle funktionieren mit dem LibreSSL von macOS und mit OpenSSL 3.]

#pruefe[
  Die erste Zeile lautet `observability/tls/obs.internal.crt: OK`. Darunter stehen `DNS:*.obs.internal, DNS:obs.internal`.
]

#cmd("Mac")[```bash
git check-ignore -v observability/tls/ca.key observability/tls/obs.internal.key
```][Fragt Git, ob die Schlüssel ausgeschlossen sind.]

#pruefe[
  Für beide Dateien nennt Git die Regel `*.key` aus `.gitignore`. Gibt der Befehl nichts aus, würden die Schlüssel beim nächsten Commit mitgehen. Dann ergänze die Regel, bevor du weitermachst.
]

== Zertifikat und CA in die Cluster bringen

Das Zertifikat mit Schlüssel braucht nur Traefik auf `obs`. Die CA brauchen alle Cluster, damit Alloy und die anderen Clients dem Zertifikat vertrauen.

#cmd("Mac")[```bash
kubectl --context obs -n monitoring create secret tls obs-tls \
  --cert=observability/tls/obs.internal.crt \
  --key=observability/tls/obs.internal.key
```][Legt das Secret `obs-tls` vom Typ `kubernetes.io/tls` an. Die Ingress-Objekte der Zentrale verweisen später darauf.]

#cmd("Mac")[```bash
for c in obs app1 app2; do
  kubectl --context $c -n monitoring create configmap obs-ca \
    --from-file=ca.crt=observability/tls/ca.crt \
    --dry-run=client -o yaml | kubectl --context $c apply -f -
done
```][Verteilt nur das öffentliche CA-Zertifikat als ConfigMap `obs-ca` mit dem Schlüssel `ca.crt`. Es ist kein Geheimnis, deshalb genügt eine ConfigMap. Alloy bindet sie später unter `/etc/obs-ca/ca.crt` ein.]

#cmd("Mac")[```bash
kubectl --context obs -n monitoring get secret obs-tls
for c in obs app1 app2; do
  kubectl --context $c -n monitoring get configmap obs-ca
done
```][Kontrolliert, dass alles am richtigen Ort liegt.]

#pruefe[
  `obs-tls` hat den Typ `kubernetes.io/tls` und `DATA 2`. Die ConfigMap `obs-ca` steht in allen drei Clustern mit `DATA 1`.
]

Auf dem Mac nutzen alle Befehle im Buch die CA direkt, etwa mit `curl --cacert observability/tls/ca.crt`. Möchtest du Grafana später ohne Warnung im Browser öffnen, kannst du der CA zusätzlich im Schlüsselbund vertrauen:

#cmd("Mac")[```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain observability/tls/ca.crt
```][Optional. Damit vertraut macOS allen Zertifikaten dieser CA. Entfernen kannst du sie in der Schlüsselbundverwaltung unter „System“.]

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

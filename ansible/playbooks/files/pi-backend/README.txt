deevnet-kit - your take-home Deevnet backend
============================================

This card runs, on a Raspberry Pi of your own, the same services your app and
devices used on Deevnet at the meetup:

  MQTT broker (TLS)     port 8883   Mosquitto; your topics under <tenant>/
  Log store (TLS)       port 8427   VictoriaLogs behind vmauth, same tokens
  Device-log bridge                 <tenant>/log/<device> -> your device logs
  Dashboards (HTTPS)    port 3000   Grafana, your own organisation

Nothing on it belongs to Deevnet: no Deevnet account, key or route. The CA,
certificates, tokens and passwords are made on this card the first time it
boots, so no two cards share anything.

Full guide: the Deevnet docs, "Take It Home on a Pi" (runbook/tenant).


1. BEFORE THE FIRST BOOT (on your laptop, right after flashing)
---------------------------------------------------------------
Imager 2.x offers no OS customisation for a custom image, so set the card
up here, on this boot partition. Three things:

a) Your tenant - edit deevnet-kit.txt, next to this file:

     tenant=bench1      your Deevnet tenant's name
     index=4            your Deevnet tenant's index

   Keeping both the same as on Deevnet keeps every topic and partition
   header the same. Left empty, the tenant is "pi" with index 1. Read ONCE,
   on the first boot.

b) Your login - create userconf.txt here, one line, username:password-hash.
   The username is yours to choose; the image has no user of its own.

     echo "you:$(openssl passwd -6)" > userconf.txt

   macOS's own openssl can't make this hash. Use Homebrew's
   ($(brew --prefix openssl)/bin/openssl passwd -6), or run it on any Linux
   machine and paste the line in.

c) SSH - create an empty file named ssh here:   touch ssh

If your Imager DOES offer OS customisation for this image, you can use that
instead of b) and c).


HOW YOU SIGN IN - your choice
-----------------------------
  Password only       nothing more to do: ssh you@<pi>
  A key you have      after first boot, once:
                        ssh-copy-id -i ~/.ssh/id_ed25519.pub you@<pi>
  A new key           ssh-keygen -t ed25519 -f ~/.ssh/my-pi
                        ssh-copy-id -i ~/.ssh/my-pi.pub you@<pi>
                        ssh -i ~/.ssh/my-pi you@<pi>

ssh-copy-id asks for the password once. The name at the end of a public key
is only a label: a key made as "alice" works for a Pi user called "bench1".
Password sign-in stays on either way; turning it off is your call.


2. FIRST BOOT
-------------
First boot creates your user, grows the filesystem and reboots once. Then
deevnet-kit sets the card up, starts everything and tests it. Give it a few
minutes (Grafana's first start is the slow part). The hostname is
"raspberrypi" unless you changed it; find the Pi's address on your router,
or use raspberrypi.local from a laptop on the same network. Then:

  ssh you@<pi>
  sudo deevnet-kit status          services, endpoints, last self-test
  sudo deevnet-kit selftest        prove it works end to end (about a minute)

The self-test checks every service, TLS on 8883, 8427 and 3000, a device log
line sent over MQTT and read back, an app log line sent and read back, and
your Grafana login, data sources and dashboard. It runs by itself on every
boot; "status" shows the last result. Each run leaves two log lines marked
"deevnet-kit selftest"; they age out after 30 days.

If the Pi's address changes after first boot, the certificate no longer names
it and "status" says so: run  sudo deevnet-kit regen-certs  (same CA, so no
device needs a new one).


3. YOUR APP'S SETTINGS
----------------------
  sudo deevnet-kit export ~/deevnet-kit

writes kit.env (every endpoint, token and login, under the same names the
Deevnet guide uses) and site-ca.pem (this card's CA). Copy both to your
laptop. An app that ran on Deevnet with a kit.env runs here with this one.


4. YOUR DEVICES
---------------
Recreate each broker account you had on Deevnet. Pass the old password to
keep it, so the device needs only a new host and CA:

  sudo deevnet-kit account add pico-1 --device pico-1 \
    --publish sensors/pico-1/telemetry --publish log/pico-1 \
    --password '<the device password from Deevnet>'
  sudo deevnet-kit account list
  sudo deevnet-kit account rm NAME

Topic patterns are relative to your tenant, as on Deevnet. In the firmware,
change the broker to this Pi's IP address (a Pico W cannot resolve .local
names; give the Pi a fixed address on your router) and the CA to
site-ca.pem. Everything else stays the same.


5. SEE YOUR LOGS
----------------
In a browser:  https://bench1.local:3000

Sign in with the user and password in kit.env's GRAFANA_AUTH line
(user:password). Your browser will warn about the certificate until you trust
site-ca.pem. Open the "Start here" dashboard: a temperature graph (any device
log line like {"temp_c": 21.5} shows up there), your device logs and your app
logs. Explore -> "Device logs" searches everything.

From a shell, the same logs:

  set -a; . ~/deevnet-kit/kit.env; set +a
  curl -sS --cacert ~/deevnet-kit/site-ca.pem \
    -H "Authorization: Bearer $LOG_READ_TOKEN" \
    -H "$LOG_SELECT_HEADER: $LOG_DEVICE_PARTITION" \
    "$LOG_ENDPOINT/select/logsql/query" --data-urlencode 'query=*'

Your app ships its own logs with LOG_INGEST_TOKEN to
$LOG_ENDPOINT/insert/jsonline, and MUST send the header
"Content-Type: application/stream+json" - without it the store answers 200
and keeps nothing.


6. YOUR DASHBOARDS AS CODE
--------------------------
The Terraform you used for dashboards on Deevnet applies here unchanged: the
data sources have the same UIDs (deevnet-logs-workloads, -platform,
-devices). Load kit.env into the environment, point GRAFANA_CA_CERT at
site-ca.pem, and apply with a state of its own (not your Deevnet state).
Put org_id = var.grafana_org_id on every grafana_* resource.


7. YOUR APP ON THE PI
---------------------
  sudo deevnet-kit export /opt/my-app
  sudo cp /opt/deevnet-kit/examples/my-app.service /etc/systemd/system/
  sudoedit /etc/systemd/system/my-app.service       (set IMAGE=)
  sudo systemctl daemon-reload && sudo systemctl enable --now my-app


WHEN SOMETHING IS WRONG
-----------------------
  sudo deevnet-kit selftest            names the check that failed
  sudo journalctl -u <service> -e      mosquitto, victorialogs, vmauth,
                                       deevnet-log-bridge, grafana,
                                       deevnet-kit-dashboards
  sudo deevnet-kit regen-certs         the Pi's address changed and devices
                                       fail with a TLS error (see 2.)
  sudo deevnet-kit render              rewrite the broker and log config

You are this card's operator. Grafana's admin password is
grafana_admin_password in /etc/deevnet-kit/kit.json (root only). Keep a copy
of /etc/deevnet-kit/: it holds the CA your devices trust.

On a 512 MB Pi Zero 2 W, Grafana is too much; turn it off and read logs from
the shell:  sudo systemctl disable --now grafana deevnet-kit-dashboards
(the self-test's Grafana checks then fail; the rest still tells you the truth)

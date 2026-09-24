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
In Raspberry Pi Imager's OS customisation, set a hostname (say bench1), your
own user and password, your Wi-Fi, and enable SSH. The image has no user of
its own.

Then edit deevnet-kit.txt, next to this file on the boot partition:

  tenant=bench1      your Deevnet tenant's name
  index=4            your Deevnet tenant's index

Keeping both the same as on Deevnet keeps every topic and partition header
the same. Left empty, the tenant is "pi" with index 1. They are read ONCE,
on the first boot.


2. FIRST BOOT
-------------
Imager's own setup runs and reboots. Then deevnet-kit sets the card up, starts
everything and tests it. Give it a few minutes (Grafana's first start is the
slow part), then:

  ssh you@bench1.local
  sudo deevnet-kit status          services, endpoints, last self-test
  sudo deevnet-kit selftest        prove it works end to end (about a minute)

The self-test checks every service, TLS on 8883, 8427 and 3000, a device log
line sent over MQTT and read back, an app log line sent and read back, and
your Grafana login, data sources and dashboard. It runs by itself on every
boot; "status" shows the last result. Each run leaves two log lines marked
"deevnet-kit selftest"; they age out after 30 days.


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
                                       fail with a TLS error
  sudo deevnet-kit render              rewrite the broker and log config

You are this card's operator. Grafana's admin password is
grafana_admin_password in /etc/deevnet-kit/kit.json (root only). Keep a copy
of /etc/deevnet-kit/: it holds the CA your devices trust.

On a 512 MB Pi Zero 2 W, Grafana is too much; turn it off and read logs from
the shell:  sudo systemctl disable --now grafana deevnet-kit-dashboards
(the self-test's Grafana checks then fail; the rest still tells you the truth)

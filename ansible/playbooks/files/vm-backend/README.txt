tenant2backend - your take-home backend
============================================

This virtual machine runs, on a hypervisor of your own, the same services
your app and devices used on Deevnet at the meetup:

  MQTT broker (TLS)     port 8883   Mosquitto; your topics under <tenant>/
  Log store (TLS)       port 8427   VictoriaLogs behind vmauth, same tokens
  Device-log bridge                 <tenant>/log/<device> -> your device logs
  Dashboards (HTTPS)    port 3000   Grafana, your own organization
  Metrics (TLS)         port 8427   the same tokens as logs, METRICS_ENDPOINT
  Alerts (HTTPS)        port 443    ntfy for your phone; rules from your Terraform:
                                      terraform output -json alert_rules > rules.json
                                      sudo tenant2backend alerts import rules.json
                                      sudo tenant2backend notify
  Buckets (TLS)         port 9000   S3 buckets, once you add one:
                                      sudo tenant2backend bucket add files --quota-gb 5

Nothing on it belongs to Deevnet: no Deevnet account, key or route. The CA,
certificates, tokens and passwords are made on this machine the first time
it boots, so no two machines share anything.

It is the Raspberry Pi image's backend on amd64: the same services, the same
tenant2backend and the same self-test. Full guide: the Deevnet docs, "Convert a
Tenant to a Pi Image" (runbook/tenant).


1. BEFORE THE FIRST BOOT (on your hypervisor)
---------------------------------------------
Import the qcow2 as the VM's disk: 2 CPUs and 2 GB of memory are enough, and
the disk can be made bigger (the file system grows to fill it on each boot).

Give the VM a BRIDGED network adapter, so it has its own address on your
network. Your devices connect to it, so it cannot sit behind the
hypervisor's NAT.

On Proxmox, for example (VM 900, storage local-lvm, bridge vmbr0):

  qm create 900 --name tdemo-kit --memory 2048 --cores 2 \
    --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single \
    --agent enabled=1 --ostype l26
  qm importdisk 900 debian-bookworm-mobile-vm-backend.qcow2 local-lvm
  qm set 900 --scsi0 local-lvm:vm-900-disk-0 --boot order=scsi0

Any hypervisor that boots a qcow2 works: with plain KVM, virt-install
--import does the same.


2. FIRST BOOT: THE CONSOLE ASKS
-------------------------------
Open the VM's console. Its first boot asks, once:

  Tenant                your Deevnet tenant's name   (empty: pi)
  Tenant index          its index                    (empty: 1)
  Host name             it becomes <hostname>.local  (empty: <tenant>-kit)
  Your login name       yours to choose; the image has no user of its own
  Password              for the console, sudo and SSH
  SSH public key        optional: one line, such as the contents of
                        ~/.ssh/id_ed25519.pub. With a key, SSH takes keys only

Keeping the tenant and index the same as on Deevnet keeps every topic and
partition header the same. Find both with  terraform output.  The console
keyboard is a US layout.

Then tenant2backend sets the machine up, starts everything and tests it. Give it
a few minutes (Grafana's first start is the slow part). From a computer on
the same network:

  ssh you@<hostname>.local
  sudo tenant2backend status       services, endpoints, last self-test
  sudo tenant2backend selftest     prove it works end to end (about a minute)

The self-test checks every service, TLS on 8883, 8427 and 3000, a device log
line sent over MQTT and read back, an app log line sent and read back, and
your Grafana login, data sources and dashboard. It runs by itself on every
boot; "status" shows the last result. Each run leaves two log lines marked
"tenant2backend selftest"; they age out after 30 days.

If the machine's address changes after first boot, the certificate no longer
names it and "status" says so: run  sudo tenant2backend regen-certs  (same CA,
so no device needs a new one). A fixed address on your router avoids it.


3. YOUR APP'S SETTINGS
----------------------
Your app logs in to the broker with its own account (backend, in the tenant
guide's walkthrough). Re-create it here with
the password it had on Deevnet (MQTT_PASSWORD in your Deevnet kit.env), in a
file so it stays out of your shell history:

  sudo tenant2backend account add backend --subscribe 'sensors/+/telemetry' \
    --password-file backend.pw
  sudo tenant2backend export ~/backend --app backend --password-file backend.pw
  shred -u backend.pw

writes kit.env (every endpoint, token and login, including MQTT_USERNAME and
MQTT_PASSWORD, under the same names the Deevnet guide uses) and backend-ca.pem
(this machine's CA). The password is checked against the account before it is
written. An app that ran on Deevnet with a kit.env runs here with this one.


4. YOUR DEVICES
---------------
Recreate each broker account you had on Deevnet. Pass the old password to
keep it, so the device needs only a new host and CA:

  sudo tenant2backend account add pico-1 --device pico-1 \
    --publish sensors/pico-1/telemetry --publish log/pico-1 \
    --password-file pico-1.pw           (the device's password from Deevnet)
  sudo tenant2backend account list
  sudo tenant2backend account rm NAME

Topic patterns are relative to your tenant, as on Deevnet. In the firmware,
change the broker to this machine's IP address (a Pico W cannot resolve
.local names; give it a fixed address on your router) and the CA to
backend-ca.pem. Everything else stays the same.


5. SEE YOUR LOGS
----------------
In a browser:  https://bench1.local:3000

Sign in with the user and password in kit.env's GRAFANA_AUTH line
(user:password). Your browser will warn about the certificate until you trust
backend-ca.pem. Open the "Start here" dashboard: a temperature graph (any device
log line like {"temp_c": 21.5} shows up there), your device logs and your app
logs. Explore -> "Device logs" searches everything.

From a shell, the same logs:

  set -a; . ~/backend/kit.env; set +a
  curl -sS --cacert ~/backend/backend-ca.pem \
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
backend-ca.pem, and apply with a state of its own (not your Deevnet state).
Put org_id = var.grafana_org_id on every grafana_* resource.


7. YOUR APP ON THIS MACHINE
----------------------------
Your app runs as a container. On your computer, build it for amd64 and
copy it across - no registry needed:

  podman build --platform linux/amd64 -t my-app .
  podman save my-app | ssh you@bench1.local sudo podman load

On the machine (with backend.pw as in 3.):

  sudo tenant2backend export /opt/my-app --app backend --password-file backend.pw
  sudo cp /opt/backend/examples/my-app.service /etc/systemd/system/
  sudo systemctl daemon-reload && sudo systemctl enable --now my-app
  sudo journalctl -u my-app -f

The example unit runs localhost/my-app:latest with kit.env, pointed at the
services on localhost. Its comments say what to change for another name.


WHEN SOMETHING IS WRONG
-----------------------
  sudo tenant2backend selftest         names the check that failed
  sudo journalctl -u <service> -e      mosquitto, victorialogs, vmauth,
                                       deevnet-log-bridge, grafana,
                                       backend-dashboards
  sudo tenant2backend regen-certs      its address changed and devices
                                       fail with a TLS error (see 2.)
  sudo tenant2backend render           rewrite the broker and log config

You are this machine's operator. Grafana's admin password is
grafana_admin_password in /etc/backend/kit.json (root only). Keep a copy
of /etc/backend/: it holds the CA your devices trust.


# Common variables shared across all Packer builds
# Usage: packer build -var-file=../common/variables.pkrvars.hcl <config>.pkr.hcl

# Automation user configuration
automation_user = "a_autoprov"

# Artifact server URLs
artifact_server_url = "http://artifacts.dvntm.deevnet.net"
ssh_pubkey_url      = "http://artifacts.dvntm.deevnet.net/keys/ssh/a_autoprov_rsa.pub"

# Raspberry Pi image sources
pi_image_base_url = "http://artifacts.dvntm.deevnet.net/pi-images"

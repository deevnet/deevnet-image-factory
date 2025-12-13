# Common variables shared across all Packer builds
# Usage: packer build -var-file=../common/variables.pkrvars.hcl <config>.pkr.hcl

# Automation user configuration
automation_user = "a_autoprov"

# Artifact server URLs
artifact_server_url = "http://localhost"
ssh_pubkey_url      = "http://localhost/keys/ssh/a_autoprov_rsa.pub"

# Raspberry Pi image sources
pi_image_base_url = "http://localhost/pi-images"

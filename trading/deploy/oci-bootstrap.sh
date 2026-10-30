#!/usr/bin/env bash
# oci-bootstrap.sh - one-shot OCI setup for the A1 claim timer.
#
# Usage: sudo bash oci-bootstrap.sh <tenancy-ocid>
#
# Discovers the availability domain, a public subnet and the newest Ubuntu
# aarch64 image in the tenancy, writes /etc/oci-claim.conf, and runs the claim
# script once so an authentication or permission problem surfaces immediately
# instead of quietly failing on every timer tick.
#
# No secrets are handled here: the API key already lives in /root/.oci and the
# values written to /etc/oci-claim.conf are identifiers, not credentials.

set -uo pipefail

TENANCY=${1:-}
OCI=/opt/oci/bin/oci
CONF=/etc/oci-claim.conf
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

[ -n "$TENANCY" ] || { echo "usage: $0 <tenancy-ocid>"; exit 2; }
[ -x "$OCI" ] || { echo "error: $OCI missing"; exit 1; }

echo "=== /root/.oci/config ==="
if ! grep -q "^tenancy=" /root/.oci/config; then
    sed -i "/^region=/i tenancy=$TENANCY" /root/.oci/config
fi
sed "s/^/  /" /root/.oci/config

echo
echo "=== authentication check ==="
if ! $OCI iam user list --compartment-id "$TENANCY" --limit 1 >/tmp/oci_auth.out 2>&1; then
    echo "AUTH FAILED:"
    sed "s/^/  /" /tmp/oci_auth.out
    exit 1
fi
echo "  ok"

echo
echo "=== availability domains ==="
AD=$($OCI iam availability-domain list --compartment-id "$TENANCY" --all \
    --query 'data[0].name' --raw-output 2>/tmp/oci_ad.err)
echo "  ${AD:-<none>}"

echo
echo "=== existing instances ==="
$OCI compute instance list --compartment-id "$TENANCY" --all \
    --query 'data[].{name:"display-name",shape:shape,state:"lifecycle-state"}' \
    --output table 2>/dev/null

echo
echo "=== subnets ==="
$OCI network subnet list --compartment-id "$TENANCY" --all \
    --query 'data[].{name:"display-name",id:id,cidr:"cidr-block",noPublicIp:"prohibit-public-ip-on-vnic"}' \
    --output table 2>/dev/null
$OCI network subnet list --compartment-id "$TENANCY" --all \
    --output json >/tmp/oci_subnets.json 2>/dev/null
SUBNET=$(python3 -c '
import json
try:
    data = json.load(open("/tmp/oci_subnets.json"))["data"]
except Exception:
    data = []
public = [s for s in data if not s.get("prohibit-public-ip-on-vnic", True)]
print((public or data or [{}])[0].get("id", ""))
' 2>/dev/null)

echo
echo "=== newest Canonical Ubuntu images for VM.Standard.A1.Flex ==="
$OCI compute image list --compartment-id "$TENANCY" --shape VM.Standard.A1.Flex \
    --operating-system "Canonical Ubuntu" --sort-by TIMECREATED --sort-order DESC --all \
    --output json >/tmp/oci_images.json 2>/tmp/oci_img.err
python3 -c '
import json
try:
    data = json.load(open("/tmp/oci_images.json"))["data"]
except Exception:
    data = []
for i in data[:5]:
    print("  " + i.get("display-name", ""))
' 2>/dev/null
IMAGE=$(python3 -c '
import json
try:
    data = json.load(open("/tmp/oci_images.json"))["data"]
except Exception:
    data = []
rel = [i for i in data if "aarch64" in i.get("display-name", "").lower()]
rel.sort(key=lambda i: i.get("time-created", ""), reverse=True)
std = [i for i in rel if "minimal" not in i.get("display-name", "").lower()]
preferred = [i for i in std if "24.04" in i.get("display-name", "")]
pick = (preferred or std or rel or [None])[0]
print(pick["id"] if pick else "")
' 2>/dev/null)

echo
echo "availability domain = ${AD:-<missing>}"
echo "subnet              = ${SUBNET:-<missing>}"
echo "image               = ${IMAGE:-<missing>}"

if [ -z "$AD" ] || [ -z "$SUBNET" ] || [ -z "$IMAGE" ]; then
    echo
    echo "not writing $CONF: a required value is missing (see lines above)"
    exit 1
fi

cat >"$CONF" <<EOF
# Written by oci-bootstrap.sh. Identifiers only, no credentials.
COMPARTMENT_OCID=$TENANCY
AVAILABILITY_DOMAIN=$AD
SUBNET_OCID=$SUBNET
IMAGE_OCID=$IMAGE
SSH_PUBKEY_FILE=/home/ubuntu/.ssh/authorized_keys
EOF
chmod 600 "$CONF"
echo
echo "wrote $CONF"

echo
echo "=== first claim attempt ==="
/usr/local/bin/claim-a1.sh
tail -3 /var/log/oci-claim-a1.log

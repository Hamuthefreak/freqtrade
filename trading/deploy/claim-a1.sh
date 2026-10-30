#!/usr/bin/env bash
# claim-a1.sh - try once to claim an Always Free Ampere A1 instance.
#
# Oracle's free Arm capacity is usually "out of host capacity", so this runs from
# a systemd timer and simply retries. It stops trying the moment one instance
# exists, so it can never stack up billable machines: the shape is hard-coded to
# the smallest free-eligible size (1 OCPU / 6 GB) and never anything larger.
#
# Requires /etc/oci-claim.conf (root, mode 600) containing:
#   COMPARTMENT_OCID=ocid1.compartment.oc1..xxx
#   AVAILABILITY_DOMAIN=xxxx:EU-FRANKFURT-1-AD-1
#   SUBNET_OCID=ocid1.subnet.oc1..xxx
#   IMAGE_OCID=ocid1.image.oc1..xxx
#   SSH_PUBKEY_FILE=/home/ubuntu/.ssh/authorized_keys
# plus /root/.oci/config, created by the API key described in trading/README.md.

set -uo pipefail

CONF=/etc/oci-claim.conf
OCI=/opt/oci/bin/oci
NAME=freqtrade-a1
LOG=/var/log/oci-claim-a1.log

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }

# Keep the log bounded; this script can run for weeks.
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 2000 ]; then
    tail -n 500 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

if [ ! -r "$CONF" ]; then
    log "waiting: $CONF does not exist yet"
    exit 0
fi

# shellcheck disable=SC1090
. "$CONF"
[ -x "$OCI" ] || { log "error: oci CLI missing at $OCI"; exit 1; }

export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
export PYTHONWARNINGS=ignore

existing=$("$OCI" compute instance list \
    --compartment-id "$COMPARTMENT_OCID" --all \
    --query "length(data[?\"display-name\"=='$NAME' && \"lifecycle-state\"!='TERMINATED'])" \
    --raw-output 2>/dev/null) || existing=""

if [ -n "$existing" ] && [ "$existing" != "0" ]; then
    log "done: $existing instance(s) named $NAME already exist - stopping the timer"
    systemctl disable --now oci-claim-a1.timer >/dev/null 2>&1
    exit 0
fi

log "attempt: VM.Standard.A1.Flex 1 OCPU / 6 GB in $AVAILABILITY_DOMAIN"
out=$(mktemp)

if "$OCI" compute instance launch \
    --compartment-id "$COMPARTMENT_OCID" \
    --availability-domain "$AVAILABILITY_DOMAIN" \
    --shape VM.Standard.A1.Flex \
    --shape-config '{"ocpus": 1, "memoryInGBs": 6}' \
    --image-id "$IMAGE_OCID" \
    --subnet-id "$SUBNET_OCID" \
    --assign-public-ip true \
    --display-name "$NAME" \
    --ssh-authorized-keys-file "$SSH_PUBKEY_FILE" \
    --wait-for-state RUNNING --wait-interval-seconds 15 --max-wait-seconds 600 \
    >"$out" 2>&1; then
    instance_id=$("$OCI" compute instance list --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$NAME" --all --query 'data[0].id' --raw-output 2>/dev/null)
    ip=$("$OCI" compute instance list-vnics --instance-id "$instance_id" \
        --query 'data[0]."public-ip"' --raw-output 2>/dev/null)
    log "CLAIMED: $NAME running, public ip $ip"
    systemctl disable --now oci-claim-a1.timer >/dev/null 2>&1
    rm -f "$out"
    exit 0
fi

# Out of capacity is the expected outcome, but other failures (quota, image,
# permissions) must be readable too, so log the service error itself rather than
# the first 400 characters, which are usually Python import warnings.
code=$(grep -o '"code": "[^"]*"' "$out" | tail -1 | cut -d'"' -f4)
msg=$(grep -o '"message": "[^"]*"' "$out" | tail -1 | cut -d'"' -f4)
log "no capacity yet: ${code:-unknown}: ${msg:-$(tail -2 "$out" | tr '\n' ' ' | cut -c1-200)}"
rm -f "$out"
exit 0

#!/bin/bash
# build-templates.sh - ready-to-clone cloud-init templates for Proxmox VE 8/9.
#
# Downloads the official cloud image of each distribution, installs
# qemu-guest-agent (and Docker for the docker/n8n profiles) inside the image
# with qemu-nbd + chroot, imports it as a VM, attaches a cloud-init drive and
# a vendor snippet, and converts it into a template. Clone the template, set
# ipconfig0/cipassword/sshkeys, start.
#
# Usage:
#   ./build-templates.sh              build every template that does not exist yet
#   ./build-templates.sh tpl-debian13 build one
#   ./build-templates.sh --list       show the template table
#   STORAGE=local-zfs CPU=x86-64-v3 ./build-templates.sh   override settings
#
# Settings below can also be given as environment variables.
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin

STORAGE="${STORAGE:-local-lvm}"        # where template disks live (zfspool, lvmthin or dir storage)
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"  # dir storage with the "snippets" content type
BRIDGE="${BRIDGE:-vmbr0}"
CPU="${CPU:-host}"                     # cpu model written into the template
CPU_DEBIAN12="${CPU_DEBIAN12:-x86-64-v3}" # Debian 12's 6.1 kernel panics on some new CPUs with "host"; see docs/debian12.md
NAMESERVERS="${NAMESERVERS:-1.1.1.1 8.8.8.8}"
MEMORY="${MEMORY:-2048}"
CORES="${CORES:-2}"
ONLINK_GATEWAY="${ONLINK_GATEWAY:-auto}" # IPv4 gateway for the Debian 12 on-link fix: auto = this host's default gateway, "" = skip the fix
PERMIT_ROOT_SSH="${PERMIT_ROOT_SSH:-yes}" # vendor snippet: allow root login with the cloud-init password
MOTD_TEXT="${MOTD_TEXT:-}"             # text for /etc/motd; empty = leave the image's motd alone
ACL_USER="${ACL_USER:-}"               # Proxmox user that must be able to clone (e.g. provision@pve); grants PVETemplateUser on each template
IMG_DIR="${IMG_DIR:-/var/lib/vz/template/cloud}"
LOG="${LOG:-/var/log/build-templates.log}"

SNIPPET_DIR="/var/lib/vz/snippets"
[ "$SNIPPET_STORAGE" != "local" ] && SNIPPET_DIR="$(pvesm path "${SNIPPET_STORAGE}:snippets/x" 2>/dev/null | sed 's|/x$||')"

# VMID|NAME|IMAGE URL|FAMILY|PROFILE|DISK
# FAMILY picks the vendor snippet (debian, ubuntu, rhel). PROFILE: base, docker or n8n. DISK: resize the image, e.g. 20G.
TEMPLATES=$(cat << 'LIST'
9001|tpl-debian12|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2|debian|base|
9002|tpl-debian13|https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2|debian|base|
9003|tpl-ubuntu2204|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu|base|
9004|tpl-ubuntu2404|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu|base|
9005|tpl-ubuntu2604|https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img|ubuntu|base|
9006|tpl-alma8|https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/AlmaLinux-8-GenericCloud-latest.x86_64.qcow2|rhel|base|
9007|tpl-alma9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2|rhel|base|
9008|tpl-alma10|https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2|rhel|base|
9009|tpl-rocky8|https://dl.rockylinux.org/pub/rocky/8/images/x86_64/Rocky-8-GenericCloud.latest.x86_64.qcow2|rhel|base|
9010|tpl-rocky9|https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2|rhel|base|
9011|tpl-rocky10|https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud.latest.x86_64.qcow2|rhel|base|
9012|tpl-docker-debian13|https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2|debian|docker|20G
9013|tpl-n8n-debian13|https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2|debian|n8n|20G
LIST
)

if [ "${1:-}" = "--list" ]; then printf '%s\n' "$TEMPLATES" | column -t -s '|'; exit 0; fi

mkdir -p "$IMG_DIR" "$SNIPPET_DIR"
log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

# The vendor snippet: password SSH for root (optional) and a motd (optional).
# cloud-init reads it on first boot next to the Proxmox-generated user data.
write_snippet() {
    local family="$1" file="${SNIPPET_DIR}/vendor-$1.yaml" ssh_service="ssh"
    [ "$family" = "rhel" ] && ssh_service="sshd"
    {
        echo "#cloud-config"
        if [ "$PERMIT_ROOT_SSH" = "yes" ]; then
            cat << 'YAML'
ssh_pwauth: true
disable_root: false

write_files:
  - path: /etc/ssh/sshd_config.d/99-cloud-template.conf
    permissions: '0644'
    content: |
      PasswordAuthentication yes
      PermitRootLogin yes
YAML
            if [ -n "$MOTD_TEXT" ]; then
                printf '  - path: /etc/motd\n    permissions: %s\n    encoding: b64\n    content: %s\n' "'0644'" "$(printf '%s\n' "$MOTD_TEXT" | base64 -w0)"
            fi
            cat << YAML

runcmd:
  - [ sed, -i, 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/', /etc/ssh/sshd_config ]
  - [ sed, -i, 's/^#*PermitRootLogin.*/PermitRootLogin yes/', /etc/ssh/sshd_config ]
  - [ systemctl, restart, ${ssh_service} ]
YAML
        elif [ -n "$MOTD_TEXT" ]; then
            printf 'write_files:\n  - path: /etc/motd\n    permissions: %s\n    encoding: b64\n    content: %s\n' "'0644'" "$(printf '%s\n' "$MOTD_TEXT" | base64 -w0)"
        else
            echo "{}"
        fi
    } > "$file"
    python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null || { log "ERROR: $file is not valid YAML"; return 1; }
    log "snippet written: $file"
}

N8N_COMPOSE='services:
  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      - N8N_SECURE_COOKIE=false
    volumes:
      - n8n_data:/home/node/.n8n
volumes:
  n8n_data:'

N8N_UNIT='[Unit]
Description=n8n (docker compose)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/n8n
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
[Install]
WantedBy=multi-user.target'

# Mount the image with qemu-nbd, chroot in, install packages, drop files.
# RHEL-family images are left alone: their cloud images ship the agent.
customize_image() {
    local name="$1" img="$2" family="$3" profile="$4"
    local nbd="/dev/nbd0" m="/mnt/build-tpl-$$" part="" rc=0 pkgs="qemu-guest-agent"
    if [ "$family" = "rhel" ]; then log "customisation skipped (rhel image): $name"; return 0; fi
    [ "$profile" != "base" ] && pkgs="$pkgs docker.io docker-compose"
    modprobe nbd max_part=8 || { log "ERROR: nbd module"; return 1; }
    qemu-nbd -c "$nbd" "$img" || { log "ERROR: qemu-nbd"; return 1; }
    sleep 2
    for p in ${nbd}p*; do
        if blkid -o value -s TYPE "$p" 2>/dev/null | grep -qE "ext4|xfs"; then part="$p"; break; fi
    done
    if [ -z "$part" ]; then qemu-nbd -d "$nbd" >/dev/null; log "ERROR: root partition not found: $name"; return 1; fi
    mkdir -p "$m"
    mount "$part" "$m" || { qemu-nbd -d "$nbd" >/dev/null; log "ERROR: mount"; return 1; }
    for d in dev proc sys; do mount --bind "/$d" "$m/$d"; done
    if [ -e "$m/etc/resolv.conf" ] || [ -L "$m/etc/resolv.conf" ]; then mv "$m/etc/resolv.conf" "$m/etc/resolv.conf.buildbak"; fi
    cp /etc/resolv.conf "$m/etc/resolv.conf"
    printf '#!/bin/sh\nexit 101\n' > "$m/usr/sbin/policy-rc.d"; chmod +x "$m/usr/sbin/policy-rc.d"   # no services start in the chroot
    chroot "$m" /bin/bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get -qq update && apt-get -qq -y --no-install-recommends install $pkgs && apt-get -qq clean && rm -rf /var/lib/apt/lists/*" >> "$LOG" 2>&1 || rc=1
    if [ "$profile" = "n8n" ] && [ $rc -eq 0 ]; then
        mkdir -p "$m/opt/n8n"
        printf '%s\n' "$N8N_COMPOSE" > "$m/opt/n8n/docker-compose.yml"
        printf '%s\n' "$N8N_UNIT" > "$m/etc/systemd/system/n8n.service"
        chroot "$m" systemctl enable n8n.service >> "$LOG" 2>&1 || rc=1
    fi
    rm -f "$m/usr/sbin/policy-rc.d" "$m/etc/resolv.conf"
    if [ -e "$m/etc/resolv.conf.buildbak" ] || [ -L "$m/etc/resolv.conf.buildbak" ]; then mv "$m/etc/resolv.conf.buildbak" "$m/etc/resolv.conf"; fi
    if [ "$name" = "tpl-debian12" ] && [ -n "$ONLINK_GATEWAY" ]; then
        # cloud-init 22.4 renders gateway4 without on-link; a /32 address (failover IP) then has no route to it.
        mkdir -p "$m/etc/systemd/network/10-netplan-eth0.network.d"
        printf "%s\n" "# cloud-init 22.x renders gateway4 without on-link; a /32 address needs GatewayOnLink." "[Route]" "Gateway=${ONLINK_GATEWAY}" "GatewayOnLink=yes" > "$m/etc/systemd/network/10-netplan-eth0.network.d/onlink.conf"
    fi
    : > "$m/etc/machine-id"   # every clone gets its own
    for d in sys proc dev; do umount "$m/$d"; done
    umount "$m"; rmdir "$m"; qemu-nbd -d "$nbd" >/dev/null
    [ $rc -eq 0 ] && log "customised: $name ($pkgs)" || log "ERROR: customisation failed: $name"
    return $rc
}

build_one() {
    local vmid="$1" name="$2" url="$3" family="$4" profile="$5" disk="$6"
    local img="${IMG_DIR}/${name}.img" cpu="$CPU"
    [ "$name" = "tpl-debian12" ] && cpu="$CPU_DEBIAN12"

    if qm config "$vmid" > /dev/null 2>&1; then log "SKIPPED: $vmid ($name) exists"; return 0; fi
    log "=== $name (VMID $vmid) ==="

    if [ ! -f "$img" ]; then
        log "downloading: $url"
        wget -q --timeout=30 --tries=3 -O "$img" "$url" || { log "ERROR: download failed: $name"; rm -f "$img"; return 1; }
    fi
    customize_image "$name" "$img" "$family" "$profile" || { rm -f "$img"; return 1; }
    [ -n "$disk" ] && qemu-img resize "$img" "$disk" >> "$LOG" 2>&1

    qm create "$vmid" --name "$name" --memory "$MEMORY" --balloon "$MEMORY" --cores "$CORES" --cpu "$cpu" \
        --net0 "virtio,bridge=${BRIDGE}" --scsihw virtio-scsi-single \
        --ostype l26 --agent enabled=1 --vga std >> "$LOG" 2>&1 || { log "ERROR: qm create"; return 1; }
    qm set "$vmid" --scsi0 "${STORAGE}:0,import-from=${img},discard=on,ssd=1" >> "$LOG" 2>&1 \
        || { log "ERROR: disk import"; qm destroy "$vmid" --purge >/dev/null 2>&1; return 1; }
    qm set "$vmid" --ide2 "${STORAGE}:cloudinit" --boot order=scsi0 --ciuser root \
        --nameserver "$NAMESERVERS" \
        --cicustom "vendor=${SNIPPET_STORAGE}:snippets/vendor-${family}.yaml" >> "$LOG" 2>&1
    [ "$name" = "tpl-debian12" ] && qm set "$vmid" --serial0 socket >> "$LOG" 2>&1
    qm template "$vmid" >> "$LOG" 2>&1 || { log "ERROR: qm template"; return 1; }

    if [ -n "$ACL_USER" ]; then
        pveum acl modify "/vms/${vmid}" --users "$ACL_USER" --roles PVETemplateUser >> "$LOG" 2>&1 || log "WARNING: ACL for $ACL_USER on /vms/${vmid} failed"
    fi
    log "DONE: $name (VMID $vmid)"
    rm -f "$img"
}

# --- main -------------------------------------------------------------------
if [ "$ONLINK_GATEWAY" = "auto" ]; then
    ONLINK_GATEWAY="$(ip -4 route show default | awk '{print $3; exit}')"
    [ -n "$ONLINK_GATEWAY" ] || { log "ERROR: no default gateway found; set ONLINK_GATEWAY or ONLINK_GATEWAY=\"\""; exit 1; }
fi
cur=$(pvesh get "/storage/${SNIPPET_STORAGE}" --output-format json | python3 -c 'import sys,json;print(json.load(sys.stdin)["content"])')
case ",$cur," in *,snippets,*) ;; *) pvesm set "$SNIPPET_STORAGE" --content "$cur,snippets" ;; esac
for f in debian ubuntu rhel; do write_snippet "$f" || exit 1; done

FILTER="${1:-}"; OK=0; FAIL=0
while IFS='|' read -r vmid name url family profile disk; do
    [ -z "$vmid" ] && continue
    [ -n "$FILTER" ] && [ "$name" != "$FILTER" ] && continue
    if build_one "$vmid" "$name" "$url" "$family" "$profile" "$disk"; then OK=$((OK+1)); else FAIL=$((FAIL+1)); fi
done <<< "$TEMPLATES"

log "=== finished: $OK built, $FAIL failed ==="
qm list | grep -E "^\s+90[0-9][0-9]" || true

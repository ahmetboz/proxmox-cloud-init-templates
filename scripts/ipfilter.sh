#!/bin/bash
# ipfilter.sh <vmid> <address> [<address> ...]
# Creates or replaces the per-VM ipset "ipfilter-net0" with the given
# addresses. With the set in place, Proxmox's firewall drops anything net0
# sends from another source address. Run on the node that hosts the VM.
set -euo pipefail
vmid="${1:?usage: ipfilter.sh <vmid> <address> [<address> ...]}"; shift
[ $# -ge 1 ] || { echo "give at least one address" >&2; exit 1; }
node="$(hostname)"
base="/nodes/${node}/qemu/${vmid}/firewall"
if ! pvesh get "${base}/ipset" --output-format json | grep -q '"name":"ipfilter-net0"'; then
    pvesh create "${base}/ipset" --name ipfilter-net0 --comment "addresses this VM may send from" >/dev/null
fi
# drop entries that are not wanted any more
pvesh get "${base}/ipset/ipfilter-net0" --output-format json \
  | python3 -c 'import sys,json; [print(e["cidr"]) for e in json.load(sys.stdin)]' \
  | while read -r cidr; do
        keep=0; for a in "$@"; do [ "$cidr" = "$a" ] && keep=1; done
        [ $keep -eq 1 ] || pvesh delete "${base}/ipset/ipfilter-net0/${cidr}" >/dev/null
    done
for a in "$@"; do
    pvesh create "${base}/ipset/ipfilter-net0" --cidr "$a" >/dev/null 2>&1 || true   # already present
done
echo "ipfilter-net0 on VM ${vmid}:"; pvesh get "${base}/ipset/ipfilter-net0" --output-format json | python3 -c 'import sys,json; [print(" ", e["cidr"]) for e in json.load(sys.stdin)]'

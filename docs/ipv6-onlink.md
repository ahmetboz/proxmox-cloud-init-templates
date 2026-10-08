# IPv6 with a gateway outside the /64

Dedicated servers at OVH (and some other providers) come with one /64 whose gateway sits outside the block, for example block `2001:db8:a:7213::/64` and gateway `2001:db8:a:72ff:ff:ff:ff:ff`. VMs on a bridge can use addresses from the block when:

- the VM's MAC is one the provider accepts on your port (at OVH, a virtual MAC bound to a failover IP),
- the address is configured with the /64 prefix and the gateway with an on-link route.

Proxmox cloud-init does this with one setting:

```
qm set <vmid> --ipconfig0 "ip=203.0.113.10/32,gw=198.51.100.254,ip6=2001:db8:a:7213::1000/64,gw6=2001:db8:a:72ff:ff:ff:ff:ff"
```

Debian 13, Ubuntu 22.04 to 26.04 and AlmaLinux/Rocky 8 to 10 render the on-link route themselves. Debian 12 gets its default route from router advertisements where the provider sends them; see [debian12.md](debian12.md).

## Adding IPv6 to a VM that is already in use

Changing `ipconfig0` changes the cloud-init drive, and cloud-init treats the guest as a **new instance** at the next cold start: it resets the root password to `cipassword`, regenerates SSH host keys, rewrites the hostname and runs the vendor data again. On Debian 13 that is exactly what happens.

To change only the network, replace the generated user data with [`snippets/keep-user.yaml`](../snippets/keep-user.yaml) for that VM:

```
cp snippets/keep-user.yaml /var/lib/vz/snippets/
qm set <vmid> --ipconfig0 "ip=…,gw=…,ip6=…/64,gw6=…" --cicustom "user=local:snippets/keep-user.yaml"
qm shutdown <vmid> && qm start <vmid>
```

With that user data the new-instance run configures the network and leaves passwords, host keys, hostname, sshd configuration, users and package sources untouched (tested on Debian 12 and 13, Ubuntu 22.04 to 26.04, AlmaLinux 8 to 10). A later reinstall from the template returns the VM to the normal vendor snippet.

## Keep neighbours out of each other's addresses

Every VM on the bridge shares the /64, so a guest could configure a neighbour's address. Proxmox's firewall has a per-VM ipset for exactly this: if `ipfilter-net0` exists, net0 may only send from the addresses in it (plus the link-local address derived from its MAC). [`scripts/ipfilter.sh`](../scripts/ipfilter.sh) creates the set for a VM with its IPv4 and IPv6:

```
scripts/ipfilter.sh <vmid> 203.0.113.10 2001:db8:a:7213::1000
```

Requires the VM firewall to be enabled (`qm set <vmid> --net0 virtio=…,bridge=vmbr0,firewall=1` and `enable: 1` in the VM's firewall options). In testing, a second address added inside the guest cannot send a packet; the listed ones work, including neighbour discovery.

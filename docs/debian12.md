# Debian 12 notes

Debian 12 ships cloud-init 22.4 and kernel 6.1. Two things bite on a cloud-image template that work fine on Debian 13 and current Ubuntu.

## 1. A /32 address has no route to its gateway

Failover and additional IPs at providers such as OVH are handed to the VM as a single address with a gateway outside that address (`ipconfig0: ip=203.0.113.10/32,gw=198.51.100.254`). Current cloud-init renders `routes: [{to: default, via: …, on-link: true}]` and systemd-networkd installs the route. cloud-init 22.4 renders `gateway4: …` instead, networkd rejects a gateway that is not on-link, and the guest boots without a default route.

The fix in the image is a networkd drop-in next to the file netplan generates:

```
/etc/systemd/network/10-netplan-eth0.network.d/onlink.conf
[Route]
Gateway=198.51.100.254
GatewayOnLink=yes
```

`build-templates.sh` writes it with the host's default gateway (`ONLINK_GATEWAY=auto`), which is right when the VMs use the same gateway as the host. Set `ONLINK_GATEWAY` explicitly otherwise, or to an empty string if your VMs get addresses inside a routed subnet with an on-link gateway.

## 2. `cpu: host` panics on recent AMD CPUs

With `cpu: host` on a Zen 5 host (Ryzen 9000) the Debian 12 kernel panicked at boot while Debian 13 and Ubuntu booted. `x86-64-v3` boots on every tested host. The script writes `CPU_DEBIAN12=x86-64-v3` for this template only, and adds a serial console (`serial0: socket`) so the panic is at least visible.

## 3. The first boot after a network change loses IPv4

Only relevant when you add IPv6 to a running Debian 12 VM (see [ipv6-onlink.md](ipv6-onlink.md)). On the boot that renders the new netplan, networkd stays in "configuring" for two minutes and the IPv4 default route is missing; the next boot is clean. Restart once more after the change.

# Proxmox cloud-init templates

One script that builds ready-to-clone cloud-init templates on Proxmox VE 8 or 9 from the official cloud images: Debian 12 and 13, Ubuntu 22.04, 24.04 and 26.04, AlmaLinux 8, 9 and 10, Rocky Linux 8, 9 and 10, plus Debian 13 with Docker and Debian 13 with n8n already installed. The images are customised offline with `qemu-nbd` and a chroot (guest agent, Docker, service units), so a clone boots with everything in place and no first-boot installs.

Written and used by [VPSPioneer](https://vpspioneer.com), a UK hosting company whose VPS platform clones these templates for every order. The fixes under `docs/` are the ones we needed in production: Debian 12 without a default route on a /32 address, Debian 12 panicking on `cpu: host`, and adding IPv6 to a running VM without cloud-init resetting the customer's password.

## Quick start

On a Proxmox node, as root:

```bash
git clone https://github.com/ahmetboz/proxmox-cloud-init-templates.git
cd proxmox-cloud-init-templates
STORAGE=local-zfs ./build-templates.sh            # every template
STORAGE=local-zfs ./build-templates.sh tpl-debian13   # just one
./build-templates.sh --list
```

Then clone and configure as usual:

```bash
qm clone 9002 201 --name web-01 --full 1 --storage local-zfs
qm set 201 --ipconfig0 "ip=203.0.113.10/24,gw=203.0.113.1" --cipassword "$(openssl rand -base64 18)" --sshkeys ~/.ssh/id_ed25519.pub
qm start 201
```

The whole set takes about 20 minutes on a 1 Gbps line; a template that already exists is skipped, so the script is safe to re-run.

## What a template contains

| | |
| --- | --- |
| Disk | The official cloud image, imported with `discard=on,ssd=1`; `docker`/`n8n` profiles resized to 20 GB |
| Packages | `qemu-guest-agent` on Debian and Ubuntu (RHEL-family images ship it); Docker and Compose on the `docker` and `n8n` profiles |
| n8n profile | `/opt/n8n/docker-compose.yml` and a systemd unit that brings n8n up on boot on port 5678 |
| cloud-init | Drive on `ide2`, `ciuser root`, nameservers from settings, vendor snippet per family |
| Vendor snippet | Root login with the cloud-init password over SSH (switch off with `PERMIT_ROOT_SSH=no`), optional `/etc/motd` |
| Hardware | 2 cores, 2048 MB with balloon, `virtio-scsi-single`, `vga std`, guest agent enabled, `cpu: host` (Debian 12: `x86-64-v3`) |
| Identity | `/etc/machine-id` emptied so every clone gets its own |

## Settings

Environment variables, all optional:

| Variable | Default | Meaning |
| --- | --- | --- |
| `STORAGE` | `local-lvm` | Storage for template disks |
| `SNIPPET_STORAGE` | `local` | Dir storage that holds the snippets (the `snippets` content type is added if missing) |
| `BRIDGE` | `vmbr0` | Bridge for net0 |
| `CPU` | `host` | CPU model; `CPU_DEBIAN12` (default `x86-64-v3`) overrides it for Debian 12 |
| `NAMESERVERS` | `1.1.1.1 8.8.8.8` | Resolvers written to cloud-init |
| `MEMORY`, `CORES` | `2048`, `2` | Template size; set the real size on the clone |
| `ONLINK_GATEWAY` | `auto` | IPv4 gateway for the Debian 12 on-link fix; `auto` = the node's default gateway; empty = no fix |
| `PERMIT_ROOT_SSH` | `yes` | Allow root password login through the vendor snippet |
| `MOTD_TEXT` | empty | Text for `/etc/motd` |
| `ACL_USER` | empty | Proxmox user that gets `PVETemplateUser` on each template, for API-driven cloning |
| `IMG_DIR`, `LOG` | `/var/lib/vz/template/cloud`, `/var/log/build-templates.log` | Scratch and log locations |

To add or change a template, edit the `TEMPLATES` table at the top of the script: `VMID|name|image URL|family|profile|disk`.

## Docs

- [docs/debian12.md](docs/debian12.md): why Debian 12 needs the on-link drop-in and `x86-64-v3`, and the first-boot quirk after a network change.
- [docs/ipv6-onlink.md](docs/ipv6-onlink.md): IPv6 with a gateway outside the /64, adding IPv6 to a VM that already has a customer without resetting it (`snippets/keep-user.yaml`), and the per-VM source filter (`scripts/ipfilter.sh`).

## Requirements

Proxmox VE 8 or 9 with `qemu-utils` (for `qemu-nbd`, present on every node), `python3-yaml` (present), outbound HTTPS to the distribution mirrors, and about 4 GB of free space in `IMG_DIR` while an image is being processed. The script needs root on the node.

## License

MIT, see [LICENSE](LICENSE). Proxmox is a trademark of Proxmox Server Solutions GmbH; distribution names belong to their projects. This project is not affiliated with any of them.

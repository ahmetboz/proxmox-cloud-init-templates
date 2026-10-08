# Snippets

`build-templates.sh` writes `vendor-debian.yaml`, `vendor-ubuntu.yaml` and `vendor-rhel.yaml` into the snippets storage from the settings at the top of the script (root password login, motd). They are not kept here because they are generated.

`keep-user.yaml` is copied by hand: it is the user data to attach when you change the network configuration of a VM that already has a customer on it. Details in [docs/ipv6-onlink.md](../docs/ipv6-onlink.md).

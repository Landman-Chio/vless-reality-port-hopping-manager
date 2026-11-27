# VLESS + REALITY TCP Port-Hopping Manager

A standalone Bash manager for deploying an Xray-core **VLESS + TCP + REALITY** inbound with server-side TCP destination-port redirection using nftables.

> **Status: early development (v0.1.0).** Test on a disposable VPS before production use. This is not yet a feature-complete replacement for the Hysteria 2 manager.

## Features in this first version

- Install Xray-core using the official XTLS/Xray-install script.
- Generate a UUID, REALITY X25519 key pair and short ID.
- Configure one VLESS + TCP + REALITY inbound (Vision flow).
- Use nftables to redirect a configurable TCP port range to the Xray listening port.
- Persist the nftables rule with a systemd oneshot service.
- Display client parameters and a VLESS share URI.
- View service status/logs, restart and back up configuration.

## Requirements

- Debian/Ubuntu VPS with root access and systemd.
- A public IPv4/IPv6 address or DNS name pointing to the VPS.
- A reachable REALITY SNI domain. Choose an SNI that is appropriate for your network environment.
- TCP access to the selected hop-port range in the provider firewall/security group.

## Install

```bash
apt-get update && apt-get install -y curl
bash <(curl -fsSL https://raw.githubusercontent.com/Landman-Chio/vless-reality-port-hopping-manager/main/vless_reality_port_hopping_manager.sh)
```

Or clone the repository:

```bash
git clone https://github.com/Landman-Chio/vless-reality-port-hopping-manager.git
cd vless-reality-port-hopping-manager
chmod +x vless_reality_port_hopping_manager.sh
sudo ./vless_reality_port_hopping_manager.sh
```

## Important: what “port hopping” means here

This release implements **server-side TCP port mapping**: inbound TCP connections arriving at any port in the configured range are redirected by nftables to the local Xray inbound port.

The generated URI uses the first port in the range as an example. A client can use another port from that range by changing the URI's port. **Automatic client-side port rotation is not implemented in v0.1.0**; a client must select/change the destination port itself. Do not assume that a standard VLESS client automatically hops ports.

This project currently configures direct outbound traffic only. A landing-IP / upstream proxy outbound, multi-user management, QR-code output, automated client profiles and IPv6-specific firewall tuning are planned, not included in this initial release.

## Firewall

Open the configured TCP hop-port range in your VPS provider firewall/security group. The script does not modify UFW/firewalld policies. Ensure the Xray listening port is not inside the hop range.

## Security notes

- Keep `/etc/vless-reality/config.env` private; it contains the REALITY private key.
- Backups contain secrets. Store them securely.
- The script replaces `/usr/local/etc/xray/config.json` when configuring this inbound. Back up any existing Xray configuration first.
- Review the generated config and firewall rules before exposing the service publicly.
- Use only on systems and networks you own or are authorized to administer.

## Roadmap

- [ ] Client-side port rotation helper and generated client profiles
- [ ] Optional upstream SOCKS5 / HTTP outbound (landing IP)
- [ ] Multi-user CRUD and per-user share links
- [ ] QR-code generation
- [ ] Safer config migration and rollback
- [ ] Debian/Ubuntu release testing and automated shell checks

## License

MIT

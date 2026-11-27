# VLESS + REALITY / TLS TCP Port-Hopping Manager

Standalone Bash manager for Xray-core VLESS + TCP, with two selectable security / camouflage modes.

> **Development status: v0.2.0 (early / not production validated).** Test on a disposable Debian/Ubuntu VPS first. Review the script before running it as root.

## Modes

### 1. REALITY camouflage

- Uses a third-party TLS website as the REALITY handshake destination/SNI.
- Generates UUID, X25519 key pair and short ID.
- Does **not** require a certificate for the node domain.
- The chosen SNI/destination must be reachable and correctly configured for REALITY.

### 2. Own domain + Let's Encrypt TLS + website camouflage

- Uses your own DNS name and obtains a certificate with Certbot / Let's Encrypt using HTTP-01 webroot validation.
- Installs an Nginx static website on TCP 80 and a loopback-only website on 127.0.0.1:8080.
- Xray terminates TLS on its configured inbound port and sends non-VLESS TLS fallback traffic to the local Nginx website.
- Cert renewal is handled by the distribution's Certbot timer; after renewal, Xray should be restarted to load renewed certificate files. Verify the timer and renewal on your host.

## TCP port mapping

The manager installs an nftables rule redirecting incoming TCP connections on a configurable port range to the Xray inbound port. Open the full range in your VPS provider firewall/security group.

This is **server-side port mapping**, not client-side automatic port rotation. The user/client must select a port from the range; a standard VLESS client does not automatically hop ports just because the server maps a range.

## Install

```bash
apt-get update && apt-get install -y curl
bash <(curl -fsSL https://raw.githubusercontent.com/Landman-Chio/vless-reality-port-hopping-manager/main/vless_reality_port_hopping_manager.sh)
```

Or clone and run:

```bash
git clone https://github.com/Landman-Chio/vless-reality-port-hopping-manager.git
cd vless-reality-port-hopping-manager
chmod +x vless_reality_port_hopping_manager.sh
sudo ./vless_reality_port_hopping_manager.sh
```

## TLS mode prerequisites

- A registered domain with A/AAAA records pointing to this VPS. Remove incorrect AAAA records if IPv6 is not configured.
- TCP port 80 reachable from the public internet for HTTP-01 certificate issuance and renewal.
- TCP port 443 (or the selected Xray listener port) and the complete hop range allowed by the VPS firewall.
- No other service may already occupy the selected Xray listener port.

## Security / operational notes

- Keep `/etc/vless-reality/config.env` private; it contains the REALITY private key in REALITY mode.
- Backups contain credentials and private keys. Store them securely.
- The installer writes `/usr/local/etc/xray/config.json`; back up existing Xray configuration before installing.
- TLS mode configures Nginx and Certbot. It does not remove existing unrelated Nginx sites intentionally, but it disables the packaged default site.
- Uninstalling this project does not revoke Let's Encrypt certificates or remove system packages.
- Use only on servers and networks you own or are authorized to administer.

## Known limitations

- No client-side automatic port hopping yet.
- No upstream SOCKS5 / HTTP landing-IP outbound yet.
- No multi-user management or QR-code generation yet.
- No automatic Xray reload hook after Certbot renewal in this release; schedule/reload integration is planned.
- The first release targets Debian/Ubuntu with systemd, nftables and apt.

## License

MIT

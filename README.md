# UniFi OS Server â€” Trusted SSL Certificate via Nginx Port Hijack

A setup script that gives your self-hosted **UniFi OS Server** a fully trusted Let's Encrypt SSL certificate â€” including on the **guest captive portal** â€” without modifying any UniFi internal files.

> **Note:** This script targets [UniFi OS Server](https://ui.com/download/software/unifi-os-server) â€” Ubiquiti's new containerized self-hosting platform (running via Podman on Linux). It is **not** intended for the legacy UniFi Network Server or hardware consoles like the Dream Machine or Cloud Key.

## Background

UniFi OS Server is Ubiquiti's modern replacement for the legacy self-hosted UniFi Network Server. It runs the full UniFi OS stack inside a Podman container on your own Linux host, bringing features like Site Magic VPN, UniFi Identity, and Organizations to self-hosted deployments â€” previously only available on Ubiquiti hardware.

Like its hardware counterparts, it uses a self-signed certificate by default, causing browser SSL warnings on both the admin console and the guest captive portal.

## The Problem

Getting a trusted certificate onto UniFi OS Server has two layers:

**Layer 1 â€” The self-signed cert warning** is the obvious one. Browsers complain when hitting the admin console at `https://<server>:11443`.

**Layer 2 â€” The guest portal port** is the harder problem, and the one most guides ignore. UniFi hardcodes port `8444` in the redirect response it sends to captive portal clients. This port is not configurable in the UniFi UI. So:

- Clients are always redirected to `https://<server>:8444/guest/...`
- You cannot point clients to a different nginx port
- Any SSL solution that doesn't handle port `8444` directly will still show a certificate warning right on the guest login page

## The Solution

This script uses an **iptables PREROUTING + nginx reverse proxy** pattern to intercept traffic on UniFi's own ports *before* it reaches UniFi, terminate it with a trusted Let's Encrypt certificate, and forward it back to UniFi via localhost.

```
Client â†’ :8444 (external)
  â””â”€â–º iptables PREROUTING intercepts
      â””â”€â–º redirects to :8445 (nginx)
          â””â”€â–º nginx terminates TLS with Let's Encrypt cert
              â””â”€â–º proxies to 127.0.0.1:8444 (UniFi OS Server, via localhost)
```

The key insight is that iptables `PREROUTING` only affects **externally incoming** packets. Traffic originating from localhost â€” nginx's outbound proxy connection â€” bypasses the rule entirely, preventing an infinite redirect loop.

This is applied to both services:

| Service | Public Port | Nginx Trap Port |
|---|---|---|
| Guest Captive Portal | `8444` | `8445` |
| Admin Console | `11443` | `11442` |

## Why Not Direct Certificate Injection?

The common workaround for hardware UniFi consoles â€” replacing cert files under `/data/unifi-core/config/` â€” does not cleanly apply to UniFi OS Server because the controller runs inside a Podman container. Injecting certs into the container is fragile and breaks on updates.

More importantly, it still doesn't solve the guest portal port problem. This script's approach never touches UniFi's internal files at all â€” nginx and iptables run independently on the host, so UniFi OS Server updates have no effect on the SSL setup.

## Requirements

- A Linux host running **UniFi OS Server** (Ubuntu 23.04+, Debian 12+, or equivalent)
- Root / sudo access on the host
- A **public domain name** pointed at your server's IP address
- Port `80` reachable from the internet (required for Let's Encrypt certificate issuance only)

## Installation

Copy the script to your server and run it:

```bash
chmod +x setup-unifi-ssl.sh
sudo ./setup-unifi-ssl.sh
```

You will be prompted for:
- **Domain name** â€” the public domain pointing to your server
- **Email address** â€” used by Let's Encrypt for renewal notices

Defaults are pre-filled in the script and can be edited before running.

## What the Script Does

1. **Detects** your active network interface automatically
2. **Installs** nginx, certbot, and iptables-persistent via apt
3. **Requests** a Let's Encrypt certificate for your domain (skips if one already exists)
4. **Configures nginx** with two SSL reverse proxy server blocks using the trusted cert
5. **Applies iptables rules** to redirect incoming traffic on UniFi's ports to nginx
6. **Persists** iptables rules across reboots via `netfilter-persistent`
7. **Adds** a certbot post-renewal hook to reload nginx automatically on certificate renewal

## After Setup

| URL | Description |
|---|---|
| `https://yourdomain.com:11443` | UniFi OS Server Admin Console |
| `https://yourdomain.com:8444` | Guest Captive Portal |

Both will present a valid, browser-trusted SSL certificate with no warnings.

## Caveats

- The script flushes the `PREROUTING` nat chain before applying rules. If you have existing custom PREROUTING rules, back them up first.
- Port `80` must be reachable for initial certificate issuance. It is not needed after that.
- The iptables redirect applies to the interface detected via your default route. If your server has multiple interfaces, review the detected interface before proceeding.

## License

MIT

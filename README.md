# Elastic at Home

Protect your home and devices using Elastic Security by deploying Elastic at home.

## Table of Contents

- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Overview](#overview)
- [Certificate Modes](#certificate-modes)
- [Bill of Materials](#bill-of-materials)
- [Guide](#guide)
  - [Prerequisites](#pre-requisites)
  - [Install Docker](#install-docker--docker-compose)
  - [Deploy Elastic Cluster](#deploy-elastic-cluster)
- [Access Your Stack](#access-your-stack)
- [Local LLM (Optional)](#local-llm-optional)
- [Project Structure](#project-structure)
- [Concepts](#concepts)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

Get a running Elastic Stack in under 5 minutes (assumes Docker is already installed):

```bash
# 1. Clone the repository
git clone https://github.com/jamesagarside/elastic-at-home.git
cd elastic-at-home

# 2. Create your environment file
cp .env.example .env

# 3. Edit .env and set your passwords
#    - ELASTIC_PASSWORD: Your main admin password
#    - KIBANA_PASSWORD: Internal Kibana password
#    - INGRESS_MODE: selfsigned (default), letsencrypt, or direct

# 4. Start the stack
docker compose up -d

# 5. Wait for services to be healthy (~3-5 minutes)
docker compose ps

# 6. Access Kibana
#    Self-signed mode: https://kibana.yourdomain.com (or https://<ip>:5601 for direct mode)
#    Username: elastic
#    Password: <your ELASTIC_PASSWORD from .env>
```

> **First time?** Start with `INGRESS_MODE=selfsigned` - it works without any DNS configuration. You'll see browser certificate warnings (click "Advanced" → "Proceed") but everything works.

For detailed instructions, see the [full guide](#guide) below.

---

## Architecture

![Elastic at Home Architecture](images/architecture/architecture.png)

> Data flows: Blue = User Access | Teal = Agent Management | Orange = Telemetry | Pink = Syslog Pipeline

## Overview

> [!NOTE]
> For this guide we will be using a Raspberry Pi 5 16GB with RaspiOS Trixie Lite, while some commands given may be specific to the Raspberry Pi family, the majority of the guide is system agnostic as we will use Docker. Podman may also be used and should have function parity.

In this guide we will walk through deploying a fully functioning SIEM (Security Incident and Events Management) platform along with Endpoint Protection giving full XDR (Extended Detection and Response) capability on consumer hardware such as the Raspberry Pi family, a laptop, an old Desktop or in a Home Lab.

What we'll cover in this Guide:

- Configuring host dependencies
- Installing Docker
- Deploying and Configuring Traefik along with Let's Encrypt Certificates using Cloudflare DNS Challenge
- Deploying and Configuring an Elastic Stack
- Installing Elastic Agent for Endpoint Protection
- Setup Threat Intelligence
- Shipping Network Flow Logs from Ubiquiti (or other Netflow exporting appliance)
- Enabling Security Rules

> [!IMPORTANT]
> The following require a licence but can be used for 30 days with a trial licence.
> When [Local LLM](#local-llm-optional) is enabled, the trial is activated automatically.

- Setting up anomaly detection for Network Traffic and DNS
- Configure Alerting via Slack
- Kibana AI Assistant (via GenAI connector — see [Local LLM](#local-llm-optional))

### Certificate Modes

Elastic at Home supports three certificate modes to accommodate different deployment scenarios - from fully air-gapped environments to internet-connected setups with publicly trusted certificates.

| Mode                        | Use Case                    | Internet Required | Certificate Trust                         |
| --------------------------- | --------------------------- | ----------------- | ----------------------------------------- |
| **Let's Encrypt**           | Production, external agents | Yes (for ACME)    | Publicly trusted (automatic)              |
| **Self-Signed (Hostname)**  | Air-gapped, internal only   | No                | Browser: click through / Agents: CA trust |
| **Direct Access (IP:Port)** | Development, testing        | No                | Browser: click through / Agents: CA trust |

#### Switching Between Modes

Certificate mode is controlled by a single environment variable. The correct Traefik config file is automatically selected based on `INGRESS_MODE`:

| INGRESS_MODE value | Config file loaded        | Access Method         |
| ------------------ | ------------------------- | --------------------- |
| `selfsigned`       | `traefik-selfsigned.yml`  | Hostname via port 443 |
| `letsencrypt`      | `traefik-letsencrypt.yml` | Hostname via port 443 |
| `direct`           | `traefik-direct.yml`      | IP via service ports  |

##### Mode-Specific Configuration Architecture

**Design Philosophy**

Elastic at Home uses mode-specific environment files to automatically configure certificate handling and CA validation based on your chosen `INGRESS_MODE`. This approach ensures:

- **Single Variable Switching**: Only `INGRESS_MODE` needs to change - all other configuration adjusts automatically
- **Zero Manual Configuration**: No need to edit multiple files or remember mode-specific settings
- **Error Prevention**: Eliminates common misconfigurations like missing CA certs or wrong trust chains

**How It Works**

Mode-specific env files are located in `configurations/elastic/env_files/`:

```
configurations/elastic/env_files/
├── .env.selfsigned    # Self-signed mode variables
├── .env.letsencrypt   # Let's Encrypt mode variables
└── .env.direct        # Direct access mode variables
```

Services automatically load the correct file via Docker Compose's `env_file` directive:

```yaml
env_file:
  - configurations/elastic/env_files/.env.${INGRESS_MODE:-selfsigned}
```

**Mode-Specific Variables**

Each mode configures different CA certificate paths and validation settings:

| Variable           | selfsigned/direct  | letsencrypt | Purpose                                    |
| ------------------ | ------------------ | ----------- | ------------------------------------------ |
| `FLEET_CA`         | `/certs/ca/ca.crt` | (unset)     | Fleet Server - Elasticsearch CA validation |
| `ELASTICSEARCH_CA` | `/certs/ca/ca.crt` | (unset)     | Agent - Elasticsearch CA validation        |
| `KIBANA_FLEET_CA`  | `/certs/ca/ca.crt` | (unset)     | Kibana - Fleet Server CA validation        |

**Why Different CA Settings Per Mode?**

- **selfsigned/direct modes**: Traefik serves certificates signed by Elasticsearch's CA
  - Agents and services need `/certs/ca/ca.crt` to validate these self-signed certificates
  - Without the CA cert, connections fail with "certificate signed by unknown authority"

- **letsencrypt mode**: Traefik serves publicly trusted Let's Encrypt certificates
  - System trust store already contains Let's Encrypt CA
  - Specifying custom CA cert would break validation (wrong trust chain)
  - CA variables are empty or unset to use system defaults

**Configuration Example**

`.env.selfsigned`:

```bash
FLEET_CA=/certs/ca/ca.crt
ELASTICSEARCH_CA=/certs/ca/ca.crt
KIBANA_FLEET_CA=/certs/ca/ca.crt
```

`.env.letsencrypt`:

```bash
# Let's Encrypt mode - uses system CAs, no custom CA needed
# CA variables are intentionally omitted
```

**When Variables Are Used**

Mode-specific variables are substituted into:

- Fleet configuration: `configurations/elastic/fleet-configuration.yaml`
- Container environment via `env_file` directive
- Agent enrolment and communication settings

This ensures the entire stack uses the correct certificate validation for your chosen mode.

**Self-Signed Mode (Default)**

Self-signed mode works out of the box with no changes required:

```bash
# .env file - default value
INGRESS_MODE=selfsigned
```

**Let's Encrypt Mode**

To switch to Let's Encrypt with Cloudflare DNS challenge, update your `.env` file:

```bash
INGRESS_MODE=letsencrypt
ACME_EMAIL=your-email@example.com
CF_DNS_API_TOKEN=your-cloudflare-api-token
```

Then restart the stack:

```bash
docker compose down && docker compose up -d
```

##### Direct Access Mode

For IP-based access without DNS configuration:

```bash
INGRESS_MODE=direct
```

Access services via IP and port:

- Kibana: `https://<host-ip>:5601`
- Elasticsearch: `https://<host-ip>:9200`
- Fleet Server: `https://<host-ip>:8220`
- APM Server: `https://<host-ip>:8200`

##### Switching Back to Self-Signed

```bash
# Edit .env: set INGRESS_MODE to selfsigned
INGRESS_MODE=selfsigned
docker compose down && docker compose up -d
```

#### Option 1: Let's Encrypt with Cloudflare DNS Challenge (Recommended)

**Best for:** Production deployments where agents/clients need to trust the stack without manual certificate distribution.

This mode uses Traefik as a reverse proxy with Let's Encrypt certificates obtained via Cloudflare DNS challenge. Certificates are automatically renewed and publicly trusted - no CA distribution required.

**Requirements:**

- A domain registered with a [supported DNS provider](https://go-acme.github.io/lego/dns/index.html)
- API token for DNS provider (e.g., Cloudflare)
- Internet access for ACME certificate requests

#### Option 2: Self-Signed with Traefik

**Best for:** Air-gapped environments or internal networks where you control all clients.

This mode uses Traefik as a reverse proxy with ES CA-signed certificates. All domain names are included as SANs (Subject Alternative Names) in a single certificate.

Traefik properly validates backend service certificates using the internal CA (no `insecureSkipVerify`).

**Requirements:**

- **Browser users:** Click "proceed to site" when prompted about the untrusted certificate. Use incognito/private browsing if you encounter cached certificate issues.
- **Elastic Agents:** Distribute `ca.crt` and configure agents to trust the CA
- No internet access required

**Agent CA Certificate**

For Elastic Agents connecting to Fleet/ES, extract and distribute the CA:

```bash
docker cp $(docker compose ps -q setup):/certs/ca/ca.crt ./ca.crt
```

#### Option 3: Direct Access (IP:Port)

**Best for:** Development, testing, or environments without DNS.

This mode uses Traefik with port-based routing instead of hostname routing. Each service is accessible on its dedicated port via the host IP address. No DNS configuration required.

**Access URLs:**

- Kibana: `https://<host-ip>:5601`
- Elasticsearch: `https://<host-ip>:9200`
- Fleet Server: `https://<host-ip>:8220`
- APM Server: `https://<host-ip>:8200`

**Requirements:**

- **Browser users:** Click "proceed to site" when prompted about the untrusted certificate
- **Elastic Agents:** Distribute `ca.crt` and configure agents to trust the CA
- No DNS configuration required

Extract and distribute the CA for Elastic Agents:

```bash
docker cp $(docker compose ps -q setup):/certs/ca/ca.crt ./ca.crt
```

#### Expected Log Messages

> [!NOTE]
> In **selfsigned** and **direct** modes, you may see errors in the Traefik logs like:
>
> `ERR Router uses a nonexistent certificate resolver certificateResolver=selfsigned routerName=kibana@docker`
>
> **These errors are expected and can be safely ignored.** They occur because Docker labels reference a certificate resolver that only exists in Let's Encrypt mode. Traefik falls back to the TLS certificates configured in the dynamic config file.

---

### SSL/TLS using Let's Encrypt Certificates

This guide covers deploying Traefik, a popular reverse proxy technology which includes a bunch of extra functionality including layer 4 (TCP/UDP) routing, Certificate Management and middlewares. In this guide we will use all of this extra functionality with Certificate Management requiring a publicly registered domain address. We do this to easily create trust relationships between Clients/Agents and our Elastic Stack, without this we would need to manage and distribute self-signed certificates to anything consuming our Elastic components over TLS or disable certificate authority verification which would reduce the security of the stack.

> [!IMPORTANT]
> We DO NOT need to expose our Elastic Stack or Traefik to the public internet to be able to use Letsencrypt certificates. [This guide uses DNS challenge](https://doc.traefik.io/traefik/reference/install-configuration/tls/certificate-resolvers/acme/#dnschallenge) to prove ownership/control of the domain through a process called ACME.
>
> Traefik uses LEGO for ACME which supports many DNS Providers to programmatically issue Certificates. [The entire list can be found here](https://go-acme.github.io/lego/dns/index.html)

This method does mean that internal DNS records will need to be configured within your network which clients are able to resolve. This can either be local to each client/agent or can be configured using common home services like [PiHole](https://pi-hole.net/), [Unifi Network Controllers](https://ui.com/), [PfSense](https://www.pfsense.org/) and even some ISP routers support custom internal records DNS.

> [!IMPORTANT] Using Let's Encrypt with `/etc/hosts` for local DNS resolution
>
> If you're using `/etc/hosts` on your local machine for DNS resolution (instead of a local DNS server like Pi-hole or Unifi), the ACME DNS challenge will fail with errors like `could not find zone for domain`.
>
> **Why this happens:** Traefik uses [Lego](https://go-acme.github.io/lego/) for ACME certificate requests. Before creating the DNS challenge TXT record, Lego performs an SOA (Start of Authority) lookup against **public DNS servers** to determine which zone the domain belongs to. Your local `/etc/hosts` file is not consulted - only public DNS is queried.
>
> **The fix:** Create a placeholder DNS record in your DNS provider (e.g., Cloudflare) for your subdomain. For example, if your services use `*.siem.example.com`, add an A record for `*.siem` pointing to any IP address (e.g., `127.0.0.1`). The actual IP doesn't matter - Lego just needs to find the zone via public DNS. Your local `/etc/hosts` will still handle the actual traffic routing.
> ![Example Cloudflare record](images/screenshots/cloudflare-locahost-record.png)

This guide will use Unifi for providing internal DNS resolution. A wildcard A record is a good way of providing all the Elastic services under a subdomain which mitigates the need to configure a new record each time you add a new service to Traefik.

![Unifi Wildcard A-record](images/screenshots/internal-dns-record.png)

#### Elastic at Home Traefik Ingress Architecture including Cloudflare DNS Challenge

Below is a flow diagram of how ingress is handled for Elastic at Home via Traefik using Cloudflare as the DNS Challenge provider to issue Letsencrypt certs.

```
                                              ┌─────────────────────────────────────────────────────────────────┐
                                              │                         CLOUDFLARE DNS                          │
                                              │  A Records: elastic.*, kibana.*, fleet.* → <Host IP>           │
                                              │  TXT Records: _acme-challenge.* (auto-created for ACME)        │
                                              └──────────────────────────────┬──────────────────────────────────┘
                                                                             │
                                                                             ▼
┌────────────────────┐     ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                    │     │                                              TRAEFIK                                                                    │
│     INTERNET       │     │  ┌───────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐  │
│                    │     │  │ ENTRYPOINTS                               ROUTERS                                    SERVICES                     │  │
│  ┌──────────────┐  │     │  │                                                                                                                   │  │
│  │   Clients    │  │     │  │  ┌─────────────┐    ┌────────────────────────────────────────┐    ┌─────────────────────────────────────────┐     │  │
│  │  (Browsers,  │──┼────►│  │  │ websecure   │───►│ elastic.* ──► TLS:letsencrypt ─────────┼───►│ es01:9200 (Elasticsearch)               │     │  │
│  │   Agents)    │  │ 443 │  │  │ :443        │    │ kibana.*  ──► TLS:letsencrypt ─────────┼───►│ kibana:5601 (Kibana)                    │     │  │
│  └──────────────┘  │     │  │  └─────────────┘    │ fleet.*   ──► TLS:letsencrypt ─────────┼───►│ fleet-server:8220 (Fleet Server)        │     │  │
│                    │     │  │                     │ apm.*     ──► TLS:letsencrypt ─────────┼───►│ fleet-server:8200 (APM)                 │     │  │
│  ┌──────────────┐  │     │  │                     └────────────────────────────────────────┘    └─────────────────────────────────────────┘     │  │
│  │   Syslog     │  │     │  │                                                                                                                   │  │
│  │   Sources    │──┼────►│  │  ┌─────────────┐    ┌────────────────────────────────────────┐    ┌─────────────────────────────────────────┐     │  │
│  │  (Routers,   │  │5514 │  │  │ syslog-tcp  │───►│ ClientIP(`192.168.0.0/16`) ────────────┼───►│ elastic-agent:5514/tcp                  │     │  │
│  │  Firewalls)  │  │     │  │  │ :5514/tcp   │    └────────────────────────────────────────┘    └─────────────────────────────────────────┘     │  │
│  └──────────────┘  │     │  │  └─────────────┘                                                                                                  │  │
│                    │     │  │                                                                                                                   │  │
│  ┌──────────────┐  │     │  │  ┌─────────────┐    ┌────────────────────────────────────────┐    ┌─────────────────────────────────────────┐     │  │
│  │   Syslog     │──┼────►│  │  │ syslog-udp  │───►│ HostSNI(`*`) ──────────────────────────┼───►│ elastic-agent:5514/udp                  │     │  │
│  │   (UDP)      │  │5514 │  │  │ :5514/udp   │    └────────────────────────────────────────┘    └─────────────────────────────────────────┘     │  │
│  └──────────────┘  │     │  │  └─────────────┘                                                                                                  │  │
│                    │     │  └───────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘  │
└────────────────────┘     │                                                                                                                         │
                           │  ┌───────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐  │
                           │  │ CERTIFICATE RESOLVER (Let's Encrypt via DNS-01 Challenge)                                                         │  │
                           │  │                                                                                                                   │  │
                           │  │  1. Request cert ──► 2. DNS-01 challenge ──► 3. Create TXT via Cloudflare API ──► 4. Verify ──► 5. Issue cert     │  │
                           │  │                                                                                                                   │  │
                           │  │  Environment: CF_DNS_API_TOKEN=<token>                                    Storage: /letsencrypt/acme.json         │  │
                           │  └───────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘  │
                           └─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
                                                                             │
                                                                             ▼
                           ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
                           │                                          DOCKER NETWORK (elastic)                                                       │
                           │                                                                                                                         │
                           │  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐                     │
                           │  │    Elasticsearch    │  │       Kibana        │  │    Fleet Server     │  │    Elastic Agent    │                     │
                           │  │       (es01)        │  │                     │  │                     │  │                     │                     │
                           │  │      :9200/tcp      │  │     :5601/tcp       │  │  :8220/tcp (Fleet)  │  │  :5514/tcp (Syslog) │                     │
                           │  │                     │  │                     │  │  :8200/tcp (APM)    │  │  :5514/udp (Syslog) │                     │
                           │  └─────────────────────┘  └─────────────────────┘  └─────────────────────┘  └─────────────────────┘                     │
                           └─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

#### Cloudflare as ACME

In this guide we use Cloudflare as our DNS Provider which is supported by Traefiks DNS Challenge domain verification. For other providers please refer to the LEGO documentation for [supported DNS providers](https://go-acme.github.io/lego/dns/index.html)

## Bill of Materials

> [!NOTE]
> You do not need to use this hardware, the details are provided for context and guidance if you wish to follow along like for like.
> The Raspberry Pi 5 platform is a very good choice for this home Security Operations Centre because it's got enough compute, relatively cheap, power efficient, and available in most countries.
>
> This setup uses Power over Ethernet to power the Raspberry Pi via a POE Hat so you will therefore need a PoE compatible switch or injector.

- [Raspberry Pi 5 (16GB)](https://thepihut.com/products/raspberry-pi-5?variant=53972414431617)
- [GeeekPi P31 M.2 NVMe PoE+ Hat](https://www.amazon.co.uk/dp/B0D7BXGLH8?ref=ppx_yo2ov_dt_b_fed_asin_title)
- [Crucial P310 SSD 1TB M.2 2230 NVMe](https://www.amazon.co.uk/dp/B0D61Z8R1W?ref=ppx_yo2ov_dt_b_fed_asin_title&th=1)

## Guide

### Pre-requisites

> [!NOTE]
> Some of these pre-requisites come from the [Running Elasticsearch in Production](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-prod) guide.

1.  Set `vm.max_map_count` to at least `262144`

    > [!TIP]
    > Each Lucene segment (and Elasticsearch shards contain multiple segments) uses memory-mapped files for efficient I/O. A single shard can easily require dozens of memory mappings, and a busy node with many shards can exhaust the default limit quickly. If this is too low Elasticsearch will throw errors like `max virtual memory areas vm.max_map_count [65530] is too low, increase to at least [262144]`.

    For Raspberry Pi you set this with the following command:

    ```bash
    echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf && sudo sysctl -p
    ```

2.  Disable Swapping - [Elastic Guide here](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/setup-configuration-memory)

    > [!TIP]
    > We disable swapping on hosts running Elasticsearch for performance reasons. When enabled the operating system uses the filesystem as 'extra memory' by moving memory pages to disk. For less memory dependent applications this is a good way to get more out of a system's resources, however for Elasticsearch which heavily relies on memory to be performant, needing to fetch memory pages from disk mid-operation turns an event which should take nanoseconds into milliseconds. Elasticsearch also heavily uses Java Garbage Collection to clean up unneeded memory usage, while this happens all other Elasticsearch operations are blocked so it's important to make this as quick as possible by not moving data from disk to memory.

    For Raspberry Pi swap can be disabled using:

    `sudo dphys-swapfile swapoff && sudo dphys-swapfile uninstall && sudo systemctl disable dphys-swapfile`

3.  **For Raspberry Pi only** Enable the Linux kernel's control group (cgroup) memory controller.

    ```bash
    sudo sed -i 's/$/ cgroup_enable=memory cgroup_memory=1/' /boot/firmware/cmdline.txt && sudo reboot
    ```

4.  **For Raspberry Pi 5 using NVMe over PCIe only** we want to ensure we can get the most out of the storage. For this guide the [52pi POE+NVMe](https://wiki.52pi.com/index.php?title=EP-0241) is used.

    ```bash
    sudo rpi-eeprom-config --edit
    ```

    adding following line: `PSU_MAX_CURRENT=5000`
    Save it and reboot your Raspberry Pi.

    Ensure PCIe is enabled on Raspberry Pi 5

    Modify /boot/firmware/config.txt

    ```bash
    sudo vi /boot/firmware/config.txt
    ```

    and add the following parameters:

    ```bash
    dtparam=pciex1

    # The connection is certified for Gen 2.0 speed (5 GT/sec), but you can force it to Gen 3.0 (10 GT/sec) by adding the following line after:

    dtparam=pciex1_gen=3
    ```

### Install Docker & Docker Compose

> [!TIP]
> The Official Docker install instructions can be [found here](https://docs.docker.com/engine/install/linux-postinstall/) if you aren't using Debian/RaspOS.

1. Add the Official Docker GPG Key & APT repository

   ```bash
   #Add Docker's official GPG key:
   sudo apt update
   sudo apt install ca-certificates curl
   sudo install -m 0755 -d /etc/apt/keyrings
   sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
   sudo chmod a+r /etc/apt/keyrings/docker.asc

   # Add the repository to Apt sources:
   sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
   Types: deb
   URIs: https://download.docker.com/linux/debian
   Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
   Components: stable
   Signed-By: /etc/apt/keyrings/docker.asc
   EOF

   sudo apt update
   ```

2. Install the required Docker Packages

   ```bash
   sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
   ```

3. Post-install we need to create a docker group and add the current user. We do this to avoid the need for using `sudo` when running `docker` commands.

   ```bash
   sudo groupadd docker
   sudo usermod -aG docker $USER
   newgrp docker
   ```

### Deploy Elastic Cluster

> [!IMPORTANT]
> The Official Elastic guide for deploying an Elastic Stack using Docker Compose can be found here but is slightly out of date and doesn't include Fleet. As part of this guide we will use a modified version of the Official Guide which brings functionality up to date and adds Fleet & Agent. A PR will be made to update the Official guide based off this modified version. [You can find the official guide here](https://www.elastic.co/docs/deploy-manage/deploy/self-managed/install-elasticsearch-docker-compose)

1. Clone Elastic at Home repository

   On the device you will be running Elastic on, clone the Elastic at Home repo and `cd` into it.

   ```bash
   git clone https://github.com/jamesagarside/elastic-at-home.git
   cd elastic-at-home
   ```

2. Copy the `.env.example` file to `.env` by running: `cp .env.example .env`

3. Modify the new .env file: `vi .env`

   **Required settings:**

   ```bash
   # Security credentials (change these!)
   ELASTIC_PASSWORD=YourSecurePassword123!
   KIBANA_PASSWORD=AnotherSecurePassword456!

   # Choose your certificate mode
   INGRESS_MODE=selfsigned  # Options: selfsigned, letsencrypt, direct

   # Domain names (for selfsigned/letsencrypt modes)
   ES_DOMAIN_NAME=es.yourdomain.com
   KIBANA_DOMAIN_NAME=kibana.yourdomain.com
   FLEET_DOMAIN_NAME=fleet.yourdomain.com
   ```

   > **Tip:** For local testing, use `INGRESS_MODE=direct` to access services via IP:port without DNS.

4. Start the Elastic Stack

   ```bash
   docker compose up -d
   ```

   The first startup takes 3-5 minutes as it:
   - Generates TLS certificates
   - Initializes Elasticsearch
   - Configures Kibana and Fleet
   - Enrols the SIEM agent

5. Verify all services are healthy

   ```bash
   docker compose ps
   ```

   All services should show `healthy` status:

   ```text
   NAME                            STATUS
   elastic-at-home-es01-1          Up (healthy)
   elastic-at-home-kibana-1        Up (healthy)
   elastic-at-home-fleet-server-1  Up (healthy)
   elastic-at-home-agent-1         Up
   elastic-at-home-traefik-1       Up
   elastic-at-home-setup-1         Up (healthy)
   ```

   > If services show `unhealthy`, check the [Troubleshooting](#troubleshooting) section.

---

## Access Your Stack

Once all services are healthy, access your Elastic Stack:

### Default Credentials

| Setting      | Value                               |
| ------------ | ----------------------------------- |
| **Username** | `elastic`                           |
| **Password** | Your `ELASTIC_PASSWORD` from `.env` |

### Access URLs by Mode

**Self-Signed Mode** (`INGRESS_MODE=selfsigned`):

| Service       | URL                            |
| ------------- | ------------------------------ |
| Kibana        | `https://<KIBANA_DOMAIN_NAME>` |
| Elasticsearch | `https://<ES_DOMAIN_NAME>`     |
| Fleet         | `https://<FLEET_DOMAIN_NAME>`  |

> Requires DNS or `/etc/hosts` entries pointing domains to your host IP.

**Let's Encrypt Mode** (`INGRESS_MODE=letsencrypt`):
Same as self-signed mode, but with publicly trusted certificates (no browser warnings).

**Direct Mode** (`INGRESS_MODE=direct`):

| Service       | URL                      |
| ------------- | ------------------------ |
| Kibana        | `https://<host-ip>:5601` |
| Elasticsearch | `https://<host-ip>:9200` |
| Fleet         | `https://<host-ip>:8220` |

> No DNS required - access directly via IP and port.

### First Login

1. Navigate to Kibana in your browser
2. Accept the certificate warning (self-signed/direct modes only)
3. Log in with username `elastic` and your `ELASTIC_PASSWORD`
4. You'll land on the Kibana home page - explore **Security** → **Overview** to see your SIEM dashboard

### Verify Fleet Agent

1. In Kibana, go to **Management** → **Fleet**
2. You should see the `siem-agent` enrolled and showing as **Healthy**
3. The agent is already collecting system logs and metrics

---

## Local LLM (Optional)

The stack includes optional support for a local Large Language Model via [Ollama](https://ollama.com), serving Google [Gemma 4 E2B](https://deepmind.google/models/gemma/gemma-4/) (2B parameters). This enables Elasticsearch's AI features — AI Assistant, semantic search, and inference pipelines — without sending data to external providers.

> [!IMPORTANT]
> **Trial License (30-day limit):** When the LLM is enabled, the setup container automatically activates an Elasticsearch **trial license**. This is required because GenAI connectors (which wire Kibana AI Assistant to the local model) are an Enterprise feature. The trial provides full Enterprise functionality free for **30 days**. After the trial expires, the cluster downgrades to Basic and the following features will **stop working**:
>
> | Feature | Status after trial expires |
> | ------- | ------------------------- |
> | Kibana AI Assistant (GenAI connector) | Disabled |
> | Machine Learning anomaly detection | Disabled |
> | Watcher / Advanced alerting | Disabled |
> | Graph exploration | Disabled |
> | Field-level & document-level security | Disabled |
>
> **Features that continue working on Basic license:**
> - Elastic Security SIEM (detection rules, alerts, timelines)
> - Fleet & Elastic Agent management
> - Elasticsearch search & aggregations
> - Kibana dashboards & visualisations
> - Ollama container & inference endpoint (direct API use)
> - Syslog ingestion
>
> To continue using Enterprise features after 30 days, you will need a paid Elastic license. See the [Elastic subscriptions page](https://www.elastic.co/subscriptions) for options.

### Hardware Requirements

Gemma 4 E2B requires ~7.2 GB of RAM at runtime. With the LLM enabled, the recommended memory allocation for a **16 GB host** is:

| Service | RAM |
| ------- | --- |
| Elasticsearch | 4 GB |
| Ollama (Gemma 4 E2B) | 8 GB |
| Kibana | 1 GB |
| Fleet Server | 1 GB |
| Agent | 1 GB |
| **Total** | **~15 GB** |

| Resource | Requirement |
| -------- | ----------- |
| Host RAM | 16 GB recommended |
| Disk | 2 GB (model download) |
| GPU | Not required (CPU inference) |

> [!NOTE]
> When enabling the LLM, reduce `ES_MEM_LIMIT` to `4294967296` (4 GB) in your `.env` to free memory for Ollama. The default without LLM is 8 GB.

### Enable the LLM

Set the following in your `.env` file:

```bash
ENABLE_LLM=true
ES_MEM_LIMIT=4294967296    # Reduce ES to 4GB to make room for Ollama
LLM_MEM_LIMIT=8589934592   # 8GB for Ollama (Gemma 4 E2B needs ~7.2GB)
LLM_API_KEY=               # Optional: set an API key for Ollama authentication
```

Then start the stack as normal:

```bash
docker compose up -d
```

On first start, the model is downloaded from the Ollama registry (~1.5 GB). Subsequent starts use the cached model.

### What Gets Configured

When `ENABLE_LLM=true`, the setup container automatically configures everything:

1. **Ollama container** starts and pulls the configured model
2. **Elasticsearch inference endpoint** (`local-llm`) is created, pointing at Ollama's OpenAI-compatible API
3. **Trial license** is activated to enable Enterprise features (required for GenAI connectors)
4. **Kibana GenAI connector** (`Local LLM (Ollama)`) is created so the AI Assistant can use the local model
5. **Kibana AI Assistant** is ready to use for chat, analysis, and investigation assistance

If `LLM_API_KEY` is set in your `.env`, it is used for both the Elasticsearch inference endpoint and the Kibana connector, and passed to Ollama as `OLLAMA_API_KEY` for authentication.

> [!TIP]
> **Redeployment-safe:** The setup container uses a two-phase design. Certificate generation (Phase 1) is skipped if certs already exist in the volume, but post-startup configuration — passwords, trial license, inference endpoint, and GenAI connector — runs on every startup. This means you can remove data volumes and redeploy without losing certificates or needing to re-issue Let's Encrypt certs.

### Verify It's Working

```bash
# Check Ollama is healthy
docker compose ps ollama

# Check the inference endpoint exists
curl -s --cacert ./ca.crt -u elastic:$ELASTIC_PASSWORD \
  https://<ES_DOMAIN_NAME>/_inference/completion/local-llm | jq

# Test a completion
curl -s --cacert ./ca.crt -u elastic:$ELASTIC_PASSWORD \
  -H "Content-Type: application/json" \
  https://<ES_DOMAIN_NAME>/_inference/completion/local-llm \
  -d '{"input":"What is Elasticsearch?"}' | jq

# Verify the GenAI connector exists in Kibana
curl -s --cacert ./ca.crt -u elastic:$ELASTIC_PASSWORD \
  -H "kbn-xsrf: true" \
  https://<KIBANA_DOMAIN_NAME>/api/actions/connectors \
  | jq '.[] | select(.connector_type_id == ".gen-ai")'

# Check trial license status
curl -s --cacert ./ca.crt -u elastic:$ELASTIC_PASSWORD \
  https://<ES_DOMAIN_NAME>/_license | jq '.license | {type, status, expiry_date}'
```

### Network Access (Optional)

To access the LLM API from other devices on your network (e.g., for use with other applications), also set `ENABLE_LLM_INGRESS=true`:

```bash
# In .env
ENABLE_LLM=true
ENABLE_LLM_INGRESS=true
LLM_DOMAIN_NAME=llm.example.com
```

Remember to add the `LLM_DOMAIN_NAME` to your DNS or `/etc/hosts` (selfsigned mode).

**Access URLs by mode:**

| Mode | URL |
| ---- | --- |
| Self-Signed | `https://<LLM_DOMAIN_NAME>` |
| Let's Encrypt | `https://<LLM_DOMAIN_NAME>` |
| Direct | `https://<host-ip>:11434` |

The Ollama API is OpenAI-compatible. External applications can use it as a drop-in replacement:

```bash
curl https://<LLM_DOMAIN_NAME>/v1/chat/completions \
  --cacert ./ca.crt \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -d '{"model":"gemma4:e2b","messages":[{"role":"user","content":"Hello!"}]}'
```

Omit the `Authorization` header if `LLM_API_KEY` is not set.

---

## Project Structure

The stack uses modular Docker Compose files for maintainability and clarity:

| File                                  | Purpose                                       |
| ------------------------------------- | --------------------------------------------- |
| `docker-compose.yaml`                 | Main orchestrator (includes all module files) |
| `docker-compose.1.traefik.yaml`       | Reverse proxy & TLS termination               |
| `docker-compose.2.setup.yaml`         | Certificate generation & initial setup        |
| `docker-compose.3.elasticsearch.yaml` | Search & analytics engine                     |
| `docker-compose.4.kibana.yaml`        | Web UI & Fleet configuration                  |
| `docker-compose.5.fleet.yaml`         | Elastic Agent management                      |
| `docker-compose.6.agent.yaml`         | SIEM agent & syslog ingestion                 |
| `docker-compose.7.ollama.yaml`        | Local LLM via Ollama (optional, profile-gated) |

Configuration files are organised in `configurations/`:

```
configurations/
├── elastic/
│   ├── fleet-configuration.yaml    # Fleet Server & Agent policies
│   └── env_files/
│       ├── .env.selfsigned         # Self-signed mode variables
│       ├── .env.letsencrypt        # Let's Encrypt mode variables
│       └── .env.direct             # Direct access mode variables
└── traefik/
    ├── traefik-selfsigned.yml           # Traefik static config for self-signed
    ├── traefik-selfsigned-dynamic.yaml  # TLS certs & backend transports
    ├── traefik-letsencrypt.yml          # Traefik static config for Let's Encrypt
    ├── traefik-letsencrypt-dynamic.yaml # Backend transports
    ├── traefik-direct.yml               # Traefik static config for direct access
    └── traefik-direct-dynamic.yaml      # TLS, routers & backend transports
```

> ⚠️ **Changing Modes Requires Redeployment**
>
> The ingress mode is configured into Kibana's Fleet settings at first startup. To switch modes:
>
> 1. Stop containers and remove **data** volumes (preserves certificates):
>    ```bash
>    docker compose down --remove-orphans
>    docker volume rm elastic-at-home_esdata01 elastic-at-home_kibanadata \
>      elastic-at-home_fleetserverdata elastic-at-home_agentdata \
>      elastic-at-home_ollama_data 2>/dev/null
>    ```
> 2. Change `INGRESS_MODE` in your `.env` file
> 3. Redeploy: `docker compose up -d`
>
> This preserves your TLS certificates (`certs` volume) and Let's Encrypt ACME state (`letsencrypt` volume) to avoid unnecessary re-issuance and [Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/).
>
> For a **full reset** including certificates: `docker compose down -v --remove-orphans`
>
> Simply changing `INGRESS_MODE` and restarting will not update Fleet's internal configuration.
> This is a destructive process and will require a brand new Elastic stack.

---

## Concepts

This section explains key concepts for those new to SIEM, networking, or Docker.

### What is TLS/SSL?

TLS (Transport Layer Security) encrypts data between your browser/agents and the Elastic Stack. When you see the padlock icon in your browser, TLS is protecting your connection.

**How it works:** Your browser and the server exchange certificates to establish a secure, encrypted channel. Without TLS, anyone on your network could read your passwords and data.

**In Elastic at Home:** All services communicate over HTTPS (HTTP + TLS). Certificates are either:

- **Self-signed:** Generated by Elasticsearch's built-in CA (Certificate Authority)
- **Let's Encrypt:** Publicly trusted certificates obtained automatically

### What is a Certificate Authority (CA)?

A Certificate Authority is a trusted entity that issues digital certificates. Think of it like a passport office - browsers trust certificates signed by known CAs.

**Why browsers trust Let's Encrypt but not self-signed:**

- Let's Encrypt is a public CA included in every browser's trust store
- Self-signed certificates are signed by your own CA, which browsers don't recognise

**In Elastic at Home:** In self-signed mode, you'll need to either click through browser warnings or distribute the CA certificate (`ca.crt`) to devices that need to trust your stack.

### What is a Reverse Proxy?

A reverse proxy sits between the internet and your services, routing incoming requests to the correct container. Think of it as a receptionist directing visitors to the right office.

**Benefits:**

- Single entry point (one IP/port for multiple services)
- TLS termination (handle certificates in one place)
- Security (hide internal service details)

**In Elastic at Home:** Traefik acts as the reverse proxy, routing requests based on hostname (e.g., `kibana.example.com`) or port (e.g., `:5601`).

### Layer 4 vs Layer 7 Routing

Traefik supports two types of routing:

| Layer       | Protocol   | Use Case                | Example                     |
| ----------- | ---------- | ----------------------- | --------------------------- |
| **Layer 4** | TCP/UDP    | Raw connections, syslog | Syslog from routers → Agent |
| **Layer 7** | HTTP/HTTPS | Web traffic, APIs       | Browser → Kibana            |

**Why it matters:** Syslog uses Layer 4 (TCP/UDP) routing because it's not HTTP traffic. Web services use Layer 7 routing with hostname-based rules.

### What is Syslog?

Syslog is a standard protocol for sending log messages across a network. Most network devices (routers, firewalls, switches) support syslog.

**Protocol options:**

- **UDP (port 514):** Fast, no guaranteed delivery - suitable for high-volume logs
- **TCP (port 514):** Reliable delivery - better for important security events

**In Elastic at Home:** The Elastic Agent receives syslog messages via Traefik and indexes them into Elasticsearch for analysis.

### What is Fleet?

Fleet is Elastic's centralized agent management system. Instead of configuring each agent individually, you define policies in Fleet and agents automatically receive updates.

**Key concepts:**

- **Agent Policy:** A collection of integrations (data sources) assigned to agents
- **Integration:** A pre-built data collection module (e.g., System, Syslog, Network)
- **Enrolment:** The process of connecting an agent to Fleet Server

### Docker Networking

Docker containers run in isolated networks. In Elastic at Home, all containers share a network called `elastic`.

**Internal vs External access:**

- **Internal:** Containers can reach each other by name (e.g., `es01`, `kibana`)
- **External:** Traffic comes through Traefik on published ports (443, 514)

**Why `es01` works inside Docker:** Docker's internal DNS resolves container names to their IP addresses within the same network.

---

## Troubleshooting

### Container Health Check Failures

**Symptom:** Services show as "unhealthy" in `docker compose ps`

**Debug:**

```bash
# Check logs for the failing service
docker compose logs <service-name>

# Check health status details
docker inspect --format='{{json .State.Health}}' elastic-at-home-<service>-1
```

**Common causes:**

- Insufficient memory (check `docker stats`)
- Certificate generation still in progress (wait for setup container to complete)
- Elasticsearch not ready (Kibana/Fleet depend on it)

### Certificate Validation Errors

**Symptom:** "certificate signed by unknown authority" errors

**For self-signed/direct modes:**

1. Extract the CA certificate: `docker cp $(docker compose ps -q setup):/certs/ca/ca.crt ./ca.crt`
2. Distribute `ca.crt` to agents and configure them to trust it
3. For browsers: add the CA to your system trust store or click through warnings

**For Let's Encrypt mode:**

- Ensure DNS records point to your host IP
- Check Traefik logs for ACME errors: `docker compose logs traefik`
- Verify `CF_DNS_API_TOKEN` has correct permissions

### Fleet Enrolment Issues

**Symptom:** Agents fail to enrol or show as "Offline"

**Debug:**

```bash
# Check Fleet Server logs
docker compose logs fleet-server

# Check agent logs
docker compose logs agent
```

**Common causes:**

- Fleet Server not healthy yet (wait for green health)
- Incorrect `FLEET_URL` in agent configuration
- Certificate trust issues (see above)

### Syslog Not Receiving Data

**Symptom:** No syslog data appearing in Elasticsearch

**Checklist:**

1. Verify port 514 is accessible: `nc -zv <host-ip> 514`
2. Check agent logs for syslog input status
3. Ensure sending device points to correct IP and port
4. For TCP: verify `ALLOWED_SYSLOG_IPS` includes your source network

### Memory/Resource Issues

**Symptom:** Containers crashing or slow performance

**Solutions:**

- Adjust memory limits in `.env` (KB_MEM_LIMIT, ES_MEM_LIMIT, etc.)
- Ensure `vm.max_map_count` is set: `sysctl vm.max_map_count`
- Check total usage: `docker stats`

**Recommended minimums:**

- Elasticsearch: 2GB
- Kibana: 1GB
- Fleet Server: 1GB
- Agent: 512MB

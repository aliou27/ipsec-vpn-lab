# Site-to-site IPsec VPN lab (strongSwan)

[![lab](https://github.com/aliou27/ipsec-vpn-lab/actions/workflows/lab.yml/badge.svg)](https://github.com/aliou27/ipsec-vpn-lab/actions/workflows/lab.yml)

Three company sites connected over an untrusted WAN, first **without** a VPN,
then with **IPsec tunnels** built with strongSwan. Every claim in this README
is checked by an automated test that runs on each push.

Based on my IPSL engineering school cryptography project (exercise 1),
originally done on Cisco routers in GNS3, rebuilt here with Linux so that
anyone can run it.

## Topology

```
                          web1 (.10)   web2 (.20)
                              \          /
                           [br0] 203.0.113.0/24      public web servers
                                  |
                                [wan]                untrusted network
           62.59.1.0/30  /        |        \  59.62.1.0/30
                        /    80.59.62.0/30   \
                  [site-a]     [site-c]      [site-b]    site gateways
                     |            |             |
             192.168.1.0/24  192.168.3.0/24  192.168.2.0/24
                  host-a        host-c         host-b    employees
```

Each box is a Linux **network namespace**: an isolated network stack with its
own interfaces, IP addresses and routes. It is the building block Docker uses
for container networking. No VM, no container image needed.

## Progress

- [x] **Step 1. Baseline without VPN**: routing works, and the WAN can read everything
- [x] **Step 2. IPsec tunnels A↔B, A↔C, B↔C with strongSwan (IKEv2)**
- [ ] Step 3. Only HTTP, HTTPS and ping allowed in the tunnels, fail-closed firewall
- [ ] Step 4. Certificates instead of pre-shared keys
- [ ] Step 5. Write-up: theory, design choices, lessons from the Cisco version

## Step 1 result: why a VPN is needed

With plain routing, a capture on the WAN link shows host-a downloading a
page from host-b. The private addresses **and** the page content are visible:

```
IP 192.168.1.10 > 192.168.2.10: ICMP echo request, id 1614, seq 1, length 64
IP 192.168.1.10.47594 > 192.168.2.10.80: Flags [S], ...
...
Hello from host-b (site B). CONFIDENTIAL: site B payroll 2026
```

Anyone on the path (an ISP, a compromised router) sees who talks to whom
and what they say. Step 2 fixes this.

## Step 2 result: site-to-site IPsec

Each site gateway runs strongSwan and builds a tunnel to the two other sites
(full mesh: A↔B, A↔C, B↔C). Same capture point, same traffic:

```
IP 62.59.1.2.4500 > 59.62.1.2.4500: UDP-encap: ESP(spi=0x4ab23d98,seq=0x8), length 120
IP 59.62.1.2.4500 > 62.59.1.2.4500: UDP-encap: ESP(spi=0x38496fe2,seq=0x8), length 120
```

The WAN now only sees the two gateways exchanging ESP packets. The private
addresses and the page content are inside the encrypted payload. Traffic to
the public web servers is not a VPN destination and stays unchanged.

| Setting | Choice | Why |
|---|---|---|
| Key exchange protocol | IKEv2 | Current standard, 4 messages instead of 9 for IKEv1 |
| IKE SA | AES-256-GCM, PRF SHA-256, Curve25519 | Authenticated encryption, modern and fast elliptic-curve DH |
| ESP (data) | AES-256-GCM + Curve25519 on rekey | Encryption and integrity in one pass, perfect forward secrecy |
| Authentication | Pre-shared key, one per tunnel | Random 256-bit keys generated at startup, never stored in git (certificates in step 4) |
| Traffic selectors | Site LAN ↔ remote site LAN | Only site-to-site traffic enters the tunnel |
| Dead Peer Detection | 10 s, restart on failure | The tunnel comes back on its own if a peer reboots |

The configuration of each gateway is in [`vpn/site-a/swanctl.conf`](vpn/site-a/swanctl.conf)
(commented line by line, with the Cisco IOS equivalent of each block).

## Run it

Nothing to install on your computer:

1. Click **Code → Codespaces → Create codespace** on this repo.
2. In the terminal, run:

```bash
sudo bash run.sh
```

This builds the network, tests it without VPN, starts the VPN, tests it
again, and tears everything down.

To explore by hand: `sudo bash run.sh up` (network + VPN), then for example
`sudo ip netns exec host-a ping 192.168.2.10`, then `sudo bash run.sh down`.

On any Ubuntu/Debian machine: `sudo apt-get install -y iproute2 tcpdump curl
iputils-ping python3 strongswan-charon strongswan-swanctl` then `sudo bash run.sh`.

## Repository layout

| Path | Role |
|---|---|
| `run.sh` | Entry point |
| `lab/up.sh` | Builds the machines, cables, addresses and routes |
| `lab/vpn-up.sh` | Generates the keys and starts strongSwan on the 3 gateways |
| `lab/down.sh` | Destroys everything |
| `vpn/site-*/swanctl.conf` | strongSwan configuration of each gateway |
| `lab/common.sh` | Addressing plan and helpers shared by all scripts |
| `tests/` | One test script per step |
| `results/` | Packet captures from the last run (open the `.pcap` in Wireshark) |
| `.github/workflows/lab.yml` | Runs the lab and the tests on every push |

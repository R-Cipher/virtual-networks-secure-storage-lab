# Azure Private Networking & Secure Storage — Terraform, Private Endpoints & DNS

Provisioning a private Azure network with Terraform and locking a storage account away from the
public internet entirely: **public network access disabled**, reachable **only** through a
**private endpoint** with **private DNS resolution**, and verified end-to-end from inside vs.
outside the network. Built as part of my AZ-104 preparation and Azure engineering portfolio.

---

## What this project demonstrates

- **Infrastructure as Code** — full network + storage topology defined in Terraform (`azurerm` + `random` providers), deployed and destroyed repeatably from a single `terraform apply`.
- **Azure networking** — VNet split into purpose-built subnets (workload + private-endpoint), NSG with least-privilege rules, and the full VM → NIC → subnet dependency chain.
- **Storage isolation** — storage account created with `public_network_access_enabled = false`; the public door is shut at creation, not after the fact.
- **Private Endpoint + Private Link** — a private IP inside the VNet maps to the storage account's blob service, routing traffic over the Microsoft backbone instead of the public internet.
- **Private DNS integration** — a `privatelink.blob.core.windows.net` zone linked to the VNet makes the storage hostname resolve to the private IP from inside the network, and the public IP from outside.
- **Least-privilege network access** — NSG allows inbound SSH only from my own public IP, associated at the subnet level.
- **Verification, not assumption** — proved the isolation works by contrasting DNS resolution and connection paths from inside the VM vs. from my laptop.

---

## Architecture

```
                         Internet
                            │
              SSH (port 22, my IP only — enforced by NSG)
                            │
        ┌───────────────────▼─────────────────────┐
        │        VNet  10.0.0.0/16                 │
        │                                          │
        │   workload subnet 10.0.1.0/24            │
        │   ┌──────────────────────────┐           │
        │   │  Test VM (10.0.1.4)       │           │
        │   │  + Public IP (SSH only)   │           │
        │   └───────────┬──────────────┘           │
        │               │ private path             │
        │   endpoints subnet 10.0.2.0/24           │
        │   ┌───────────▼──────────────┐           │
        │   │ Private Endpoint          │           │
        │   │ (10.0.2.4) ──► Storage    │           │
        │   └──────────────────────────┘           │
        └──────────────────────────────────────────┘
                            │
              Storage Account (public access DISABLED)
                reachable ONLY via the private endpoint
```

---

## Resources deployed

| Resource | Terraform address | Purpose |
|---|---|---|
| Resource group | `azurerm_resource_group.rg` | Container / governance scope |
| Virtual network | `azurerm_virtual_network.vnet` | Private `10.0.0.0/16` address space |
| Workload subnet | `azurerm_subnet.workload` | VM placement (`10.0.1.0/24`) |
| Endpoints subnet | `azurerm_subnet.endpoints` | Dedicated to private endpoints (`10.0.2.0/24`) |
| Network security group | `azurerm_network_security_group.nsg` | Stateful firewall — SSH from my IP only |
| NSG association | `azurerm_subnet_network_security_group_association.assoc` | Binds NSG to the workload subnet |
| Random suffix | `random_string.s` | Globally-unique storage account name |
| Storage account | `azurerm_storage_account.sa` | Blob storage, **public access disabled** |
| Private DNS zone | `azurerm_private_dns_zone.blob` | `privatelink.blob.core.windows.net` |
| DNS zone link | `azurerm_private_dns_zone_virtual_network_link.link` | Links the zone to the VNet |
| Private endpoint | `azurerm_private_endpoint.pe` | Private IP into the endpoints subnet for the storage account |
| Public IP | `azurerm_public_ip.vm_pip` | External SSH entrance for the test VM |
| Network interface | `azurerm_network_interface.nic` | Wires the VM into the workload subnet |
| Linux VM | `azurerm_linux_virtual_machine.vm` | Ubuntu 22.04 LTS, `Standard_E2s_v3`, SSH-key auth |

---

## Troubleshooting log

I built this into a real subscription and wired the connectivity test together myself rather than
pasting a finished config, so several things had to be reasoned through. Each one came down to
understanding *how Azure actually models the relationship between resources* — which is the part
that transfers to real operational work.

### 1. VM has no `subnet` / `virtual_network` argument — the wiring lives on the NIC

My first instinct was to place the VM into the subnet by adding a `subnet_id` (or similar) to the
VM block. Those arguments don't exist on `azurerm_linux_virtual_machine`. In Azure's model a VM
never attaches to a subnet directly — the chain is:

```
VM ──► Network Interface (NIC) ──► ip_configuration ──► Subnet
```

The VM only references `network_interface_ids`; the subnet association lives inside the NIC's
`ip_configuration` block.

**Fix:** created a dedicated NIC resource and pointed the VM at it:

```hcl
network_interface_ids = [azurerm_network_interface.nic.id]
```

### 2. NIC referenced a subnet that didn't exist in this lab

The reusable NIC block referenced `azurerm_subnet.subnet.id`, but this lab defines **two** subnets
with different local names — `workload` and `endpoints` — and no subnet named `subnet`. Terraform
would have failed with an unresolved reference.

**Fix:** pointed the NIC at the correct subnet for VM placement:

```hcl
subnet_id = azurerm_subnet.workload.id
```

### 3. VM unreachable for SSH — no public IP existed

With `public_network_access_enabled = false` on the storage account, it's easy to assume *nothing*
should have a public IP. But the storage account and the test VM are two separate boundaries: the
storage account must be private, while the VM needs a narrowly-scoped public entrance so I can get
*inside* the VNet to run the test at all. The NSG already restricted SSH to my IP — but with no
public IP on the NIC, there was no external address to connect to.

**Fix:** added a public IP and attached it on the NIC's `ip_configuration` (not the VM, not the
subnet):

```hcl
resource "azurerm_public_ip" "vm_pip" {
  name                = "pip-${var.prefix}"
  allocation_method   = "Static"
  sku                 = "Standard"
  # ...
}

# inside the NIC ip_configuration:
public_ip_address_id = azurerm_public_ip.vm_pip.id
```

### 4. `400 InvalidQueryParameterValue` on both sides — a misleading "both worked" result

Testing with a bare `curl https://<account>.blob.core.windows.net/` returned the **same 400** from
both the VM and my laptop, which looked like the isolation had failed. It hadn't: a bare `GET /`
isn't a valid blob operation, so Azure rejects it on request *format* before network or auth is
ever evaluated. The identical error was a red herring — the network layer was never reached in
either case.

**Diagnosis:** switched to a valid operation (`?comp=list`, List Containers) so the request would
actually reach the network/auth layer instead of bouncing on a format check.

### 5. Reading the real responses — `403` vs `404` is the whole story

With a valid operation, the two locations finally diverged:

| Where | Request | Response | Meaning |
|---|---|---|---|
| Laptop (public path) | `GET /?comp=list` | `403 AuthorizationFailure` | Hit the public endpoint; unauthenticated request rejected. |
| VM (private path) | `GET /?comp=list` | `404 ResourceNotFound` | Reached the blob service over the private endpoint; account simply has no containers yet. |

**Takeaway:** Azure processes request format → authentication → the actual operation in that order,
and returns a *different* error code at each stage. A `400` means the request itself was malformed;
a `403` means it reached the service but wasn't authorized; a `404` means it got all the way through
to a valid-but-empty resource. Reading *which* code you got tells you exactly how far the request
traveled — which, in an isolation test, is the entire point.

### 6. The real proof was in DNS resolution, not the HTTP status

The decisive evidence isn't the curl status code — it's that the **same hostname resolved to
different IPs depending on location**, confirming the private DNS zone was doing its job:

```
# From the VM (inside the VNet):
staaz104net...blob.core.windows.net  ->  10.0.2.4        (private endpoint)

# From my laptop (outside the VNet):
staaz104net...blob.core.windows.net  ->  52.239.221.36   (storage public IP)
```

The VM's `curl -v` confirmed it connected to `10.0.2.4:443` and completed a TLS handshake against a
valid `*.blob.core.windows.net` certificate — traffic that never left the VNet.

**Next hardening step:** an authenticated `az storage container list --auth-mode login` from each
location would isolate the network layer even more cleanly (auth succeeds in both, but the public
path is blocked at the network boundary). Documented as the natural follow-up.

---

## How to run

**Prerequisites:** Terraform, Azure CLI (logged in via `az login`), and an SSH keypair at
`~/.ssh/id_rsa`.

```powershell
terraform init      # download the azurerm + random providers
terraform fmt       # format check
terraform validate  # syntax / config validation
terraform plan      # preview
terraform apply     # deploy
```

Then verify the isolation from the VM and from your own machine:

```powershell
terraform output vm_public_ip
ssh -i ~/.ssh/id_rsa azureuser@<vm_public_ip>

# from the VM, then repeat from your laptop:
nslookup <storage_account_name>.blob.core.windows.net
curl -v "https://<storage_account_name>.blob.core.windows.net/?comp=list"
```

```powershell
terraform destroy   # tear down (avoid idle spend from the private endpoint + VM)
```

> `terraform.tfvars` is not committed. Copy `terraform.tfvars.example` and set your own values
> (`my_ip_cidr` = your public IP in CIDR form, e.g. `203.0.113.7/32` — find it with `curl ifconfig.me`).

Verified clean teardown — **14 resources destroyed** with no leftovers.

---

## Outputs

```
vnet_name            = "vnet-az104net"
storage_account_name = "staaz104net..."
private_endpoint_id  = "/subscriptions/.../privateEndpoints/pe-storage"
vm_public_ip         = "<VM public IP>"
```

---

## Skills mapped to AZ-104

| AZ-104 domain | Demonstrated by |
|---|---|
| Configure and manage virtual networking | VNet, dual subnets, NSG + subnet association, private endpoint, private DNS zone + VNet link |
| Implement and manage storage | Storage account with public access disabled, private-endpoint-only access, blob subresource |
| Deploy and manage compute | Linux VM provisioning, VM → NIC → subnet wiring, SSH-key auth |
| Manage identities and governance | Least-privilege NSG rule scoped to a single source IP |
| Monitor and maintain resources | Verified connectivity contrast (inside vs. outside), clean `terraform destroy` |
| (Cross-cutting) Automation | Entire environment as Terraform IaC |

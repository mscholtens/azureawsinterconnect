# Architecture

Audience: this document is written for an AI coding agent (or a very
detail-oriented human) that needs to implement, modify, or debug this
project without additional context. It follows the same structure and
philosophy as the sibling `aws-gcp-interconnect-experiment/ARCHITECTURE.md`
— confirmed facts are marked as such; unverified assumptions are marked
as such, explicitly, so they're never silently treated as settled.

## Goal

Establish private-IP connectivity between an Azure VM and an AWS EC2
instance, using **Azure Multicloud Interconnect** and **AWS Interconnect
– multicloud** — the same underlying AWS service used in the sibling GCP
project, now paired with Azure instead. Direction of initiation: **Azure
initiated** (Azure creates the ExpressRoute circuit and generates an
activation key; AWS accepts it) — the reverse of the GCP project, where
AWS initiated.

Both services were announced 2026-08-31. This document will accumulate
corrections as the project is actually built and run, the same way the
GCP project's did.

## Outcome of the first full run (CONFIRMED)

The experiment worked end to end (AWS `us-east-1` <-> Azure `eastus`,
peering location `useast`, 1 Gbps circuit):

- `03-status.sh`: circuit `Enabled`, gateway connection `Succeeded`, AWS
  connection `available`.
- Azure VM -> EC2 (`10.0.1.131`): TCP/22 open, 4/4 pings, avg 3.57 ms
  (min 3.32, max 3.76).
- EC2 -> Azure VM (`10.2.1.4`): TCP/22 open, 4/4 pings, avg 4.07 ms
  (min 3.31, max 5.73; one outlier at 5.73 ms).
- Path trace: the interconnect is mostly invisible to traceroute. From
  Azure, hop 1 is the ExpressRoute gateway (`10.2.255.x`, in the
  GatewaySubnet), hop 2 is a link-local `169.254.255.x` address, and
  nothing answers after that (hops 3-30 "no reply"). From AWS, hop 1 is the
  VPC router, hop 2 a link-local `169.254.255.x` address, then the Azure VM
  after 3 hops. Path MTU on the AWS side drops from 9001 (in-VPC) to 1500
  over the interconnect.
- No Azure route-table changes and no extra Azure routing resource were
  needed: BGP-learned routes propagated into the VNet by default (this
  settles open question 2). The AWS side needed `aws_vpn_gateway_route_propagation`
  as in the GCP project.
- Teardown: `06-down-aws.sh` clean. Azure resource group deletion took
  about 18.5 minutes (1110 s) with direct RG deletion; `terraform destroy`
  had previously burned its entire 30 minute timeout on the gateway
  connection and still failed (item 12).

Biggest practical lessons, in order of time lost: (1) the activation key is
only in ARM api-version 2026-05-01 (item 11); (2) the gateway connection
cannot be created until the circuit reports `Provisioned`, and a premature
attempt leaves an untracked stub (item 11); (3) VM size restrictions and
region capacity (item 5); (4) teardown reliability (item 12).

## Key structural fact: no new Azure resource type

Unlike GCP's Partner Cross-Cloud Interconnect (a genuinely new resource
type, `network-connectivity transports`), **Azure Multicloud Interconnect
is an existing resource type with a new SKU** — confirmed via a working
Bicep example:

```bicep
resource circuit1 'Microsoft.Network/expressRouteCircuits@2024-07-01' = {
  name: 'multi'
  location: 'westus2'
  sku: {
    name: 'MultiCloud_MeteredData'
    tier: 'MultiCloud'
    family: 'MeteredData'
  }
  properties: {
    serviceProviderProperties: {
      serviceProviderName: 'AWS'
      peeringLocation: 'useast'
      bandwidthInMbps: 1000
    }
    partnerAccountId: '<AWS_ACCOUNT_ID>'
  }
}
```

This is `Microsoft.Network/expressRouteCircuits` — the same resource
type used for classic ExpressRoute — with `sku.tier = "MultiCloud"` and
a new `partnerAccountId` property. Creating it generates an activation
key (confirmed via Microsoft's own FAQ: "Either side generates it. Azure
can generate a key that you redeem with your cloud service provider, or
your provider can generate a key that you redeem in Azure.").

## CONFIRMED Terraform/tooling gap

CONFIRMED via a real `terraform apply` error (not just documentation
research):
```
Error: Unsupported argument
  on circuit.tf line 57, in resource "azurerm_express_route_circuit" "this":
  57:   partner_account_id = var.aws_account_id
An argument named "partner_account_id" is not expected here.
```
This settles the question raised during initial research: the typed
`azurerm_express_route_circuit` resource genuinely does not support the
property needed to target a specific AWS account. **Resolution**:
`circuit.tf` now uses `azurerm_resource_group_template_deployment` to
deploy the raw ARM JSON shape directly, bypassing the typed resource's
schema entirely — mirrors the confirmed-working Bicep example below
exactly. The original typed-resource attempt is preserved in `circuit.tf`
as a comment, for the record.

Everything else on the Azure side (VNet, subnet, NSG, VM, ExpressRoute
Gateway, Gateway Connection) uses long-established, non-preview resource
types and continues to work fine with plain typed `azurerm_*` resources.

Original research (kept for context — this is what led to writing the
empirical test that produced the confirmation above):

- **`azurerm_express_route_circuit`'s documented `sku.tier` only lists
  `Basic | Local | Standard | Premium`** — no `MultiCloud`. This is a
  *documentation* fact, not yet a confirmed *behavioral* fact — enum
  validation in `azurerm` is typically enforced via Go-level
  `ValidateFunc` checks, which don't show up in
  `terraform providers schema -json`. The only way to know for certain
  whether the provider accepts `"MultiCloud"` is to actually write the
  config and run `terraform plan` (validation errors surface here,
  before touching any real API — safe to test).
- **No `partner_account_id` (or equivalent) attribute found anywhere in
  `azurerm_express_route_circuit`'s documented argument list.** This is
  a stronger signal than the enum question — if the field doesn't exist
  in the resource schema at all, no enum-acceptance workaround will
  help; the typed resource structurally cannot express this circuit
  type.
- **`az network express-route create --sku-tier` (GA CLI) only accepts
  the same four values** (`Basic, Local, Premium, Standard`) — the CLI
  hasn't caught up either, as of the documentation checked.

**Planned approach** (per the user's explicit direction): attempt the
typed `azurerm_express_route_circuit` resource first — check
`terraform providers schema -json` for `partner_account_id` presence
as the first, free, structural test; if present, attempt `terraform
plan`/`apply` with `sku.tier = "MultiCloud"` as the next, still-cheap
test. **Fallback**: `azurerm_resource_group_template_deployment`,
deploying the raw ARM JSON shape shown above — this bypasses the typed
resource's schema entirely and mirrors the working Bicep example
structurally. This is the same "escape hatch" pattern as `awscc`
(schema-driven generic provider) for AWS and `gcloud` CLI for GCP in the
sibling project — a way to reach functionality the typed/mainline
tooling hasn't caught up to yet.

Everything else on the Azure side (VNet, subnet, NSG, VM, ExpressRoute
Gateway, Gateway Connection) uses long-established, non-preview resource
types and should work fine with plain typed `azurerm_*` resources
regardless of how the circuit resource itself is created.

## Component inventory

### Azure side

| Component | Role |
|---|---|
| Resource Group | Container for all Azure resources in this project |
| VNet + subnet | Network home for the Azure VM |
| **GatewaySubnet** | A second, dedicated subnet — **must be named literally `GatewaySubnet`** (Azure-enforced naming requirement, not a project convention) — required for the ExpressRoute Gateway |
| Network Security Group (NSG) | Azure NSGs default-deny inbound — must explicitly allow SSH (22) from the local machine's IP and ICMP from the AWS CIDR, unlike AWS's security-group-per-instance model which we also had to configure explicitly, and GCP's firewall rules which likewise needed explicit rules |
| ExpressRoute Gateway (`azurerm_virtual_network_gateway`, type=ExpressRoute) | The entry point for traffic arriving via the interconnect into the VNet — confirmed required per Microsoft's FAQ ("Traffic entering Azure over the interconnect uses an ExpressRoute virtual network gateway") |
| ExpressRoute Gateway Connection (`azurerm_virtual_network_gateway_connection`, type=ExpressRoute) | Links the ExpressRoute Gateway to the Circuit — the Azure-side equivalent of AWS's DX Gateway Association, or GCP's mandatory VPC Network Peering step |
| **ExpressRoute Circuit, `sku.tier = MultiCloud`** | The actual cross-cloud link — see the confirmed Terraform gap above. Generates the activation key that crosses to AWS. |
| VM | The test instance |

### AWS side

Identical component set to the sibling GCP project's AWS side — same
service, same resource types:

| Component | Role |
|---|---|
| VPC + subnet, IGW, route table, Security Group | Same as GCP project |
| Virtual Private Gateway (VGW) + DX Gateway + DX Gateway Association | Same as GCP project — mandatory, not a design choice (AWS's attach point is always a DX Gateway) |
| **VPN Gateway Route Propagation** (`aws_vpn_gateway_route_propagation`) | CONFIRMED required in the GCP project (without it, routes never reach the route table even with every other component healthy) — apply proactively from the start this time rather than rediscovering it |
| **AWS Interconnect Connection** (`awscc_interconnect_connection`) | This time created with **`activation_key` set, NOT `environment_id`/`remote_account`** — the sibling branch of the same mutually-exclusive pair used in the GCP project. `attach_point` (the DX Gateway) is still required regardless of which branch is used — confirmed unconditionally required in the schema, not tied to the environment_id/activation_key choice. |
| EC2 instance | The test instance |

## Open questions to resolve empirically (like the GCP project's list)

1. **RESOLVED:** the Terraform/ARM question above. The raw ARM template
   deployment works; see items 6 and 11 for its quirks (create-once, no outputs).
2. **RESOLVED (not needed):** whether an Azure equivalent of the AWS VGW
   route-propagation fix is needed. Pings worked in both directions with no
   extra Azure routing configuration. Original question: Azure ExpressRoute Gateway Connections typically propagate
   BGP-learned routes into the VNet automatically (Azure's default
   "Virtual network gateway route propagation" setting on route tables
   is enabled unless explicitly disabled) — but this is an assumption
   carried over from general ExpressRoute knowledge, not confirmed for
   this specific MultiCloud circuit type. Treat as unconfirmed until a
   real ping test either works or reveals a missing routing piece, the
   same way the AWS-GCP project's routing gap was only found empirically.
3. **RESOLVED:** exact `AZURE_PEERING_LOCATION` accepted value/format (`useast` works with `eastus`/`us-east-1`; the valid list comes from `az network express-route list-service-providers`). Original question: for the
   MultiCloud tier specifically. The one working example used `'useast'`
   — an unusual, lowercase, non-standard-looking string compared to
   classic ExpressRoute peering location names like `"Silicon Valley"`
   or `"Washington DC"`. This might be a MultiCloud-specific naming
   scheme tied to preview region availability, not a normal peering
   location. Verify directly (portal picker, or API list call) before
   trusting any value here.

   **Region pairing itself, however, IS confirmed.** The project now uses
   AWS `us-east-1` ↔ Azure `eastus` (peering location `useast`); it
   originally used AWS `eu-central-1` ↔ Azure `germanywestcentral` (both Frankfurt),
   directly confirmed via a German tech outlet reporting on the launch:
   *"a connection via Azure Germany West Central and AWS Europe
   (Frankfurt) is planned."* Full confirmed pairing list:

   | AWS region | Azure region |
   |---|---|
   | US East (N. Virginia) | East US |
   | US West (N. California) | West US |
   | Asia Pacific (Sydney) | Australia East |
   | Europe (Frankfurt) | Germany West Central |

   Notably, the `'useast'` example value doesn't cleanly derive from
   either side of the US East (N. Virginia) ↔ East US pairing (Azure's
   region code is `eastus`, reversed from `useast`) — so don't assume
   the Frankfurt equivalent is a simple transformation of
   `germanywestcentral` or `eu-central-1`. Genuinely unconfirmed; check
   the Portal directly.

   **Follow-up research**: checked Microsoft's official ExpressRoute
   peering-location mapping. Confirmed: peering locations map
   many-to-many within a whole geopolitical region, not 1:1 to a single
   Azure region. For the "Europe & Africa" region (which includes
   Germany West Central), the valid classic ExpressRoute peering
   locations include both `Frankfurt` and `Copenhagen` (among many
   others). This led to a best guess of `Frankfurt`, which was then
   **CONFIRMED WRONG via a real deployment error**:
   ```
   ExpressRouteCircuitLocationDoesNotExistForServiceProvider: The
   Location Frankfurt specified in Express Route Circuit ... does not
   exist for Service Provider AWS.
   ```
   This settles it: the MultiCloud tier does NOT use classic ExpressRoute
   city names, at least not for the AWS provider — consistent with the
   `'useast'` example's odd non-standard format. The correct, reliable
   way to find valid values: `az network express-route
   list-service-providers -o table`, filtered for AWS's entries.

   **RESOLVED** — ran that exact command:
   ```
   az network express-route list-service-providers \
     --query "[?name=='AWS'].{Provider:name,PeeringLocations:peeringLocations,Bandwidths:bandwidthsOffered}" \
     -o yaml
   ```
   Confirmed AWS's valid `peeringLocations`: exactly
   `[australiaeast, germanywc, useast, useast2euap, uswest]` — a bespoke
   abbreviated scheme unique to this list, not consistently matching
   Azure's own region codes either (`useast`/`uswest` are reversed from
   Azure's actual `eastus`/`westus`). **`germanywc` is the confirmed
   value** for Frankfurt/Germany West Central, and **`useast`** for the
   current us-east-1 ↔ eastus pairing — set in `config/credentials.env`.

4. **CONFIRMED via real deployment error**: an ExpressRoute-type
   `azurerm_virtual_network_gateway` does not accept a public IP —
   `ip_configuration.0.public_ip_address_id cannot be set when type is
   set to ExpressRoute`. Fixed by removing the `azurerm_public_ip` for
   the gateway entirely. Makes architectural sense: ExpressRoute
   gateways connect via the Microsoft backbone through the circuit, not
   over the public internet, unlike VPN-type gateways.

5. **CONFIRMED: Germany West Central was unusable for VMs — two
   independent gates, never both open. Region switched to East US.**
   Every VM size tried failed at one of two separate checks:

   *Gate 1 — live capacity (`SkuNotAvailable`):* `Standard_B1s`,
   `Standard_B2s`, `Standard_D2s_v3`, `Standard_D2s_v4`,
   `Standard_A2_v2`, and `Standard_F2s_v2` all failed this way (a Spot
   attempt did too). These families all had non-zero subscription quota.

   *Gate 2 — subscription quota (`OperationNotAllowed`):*
   `Standard_D2s_v5` failed with `Current Limit: 0` for the whole
   `standardDSv5Family`. Cross-referencing `az vm list-usage` showed the
   sizes that passed `az vm list-skus` as regionally available
   (`Standard_D2as_v5`, `Standard_D2_v5`, `Standard_B2als_v2`) all had
   `0/0` quota too.

   **Lesson: `az vm list-skus` (regional availability) and `az vm
   list-usage` (your subscription's per-family quota) are two different
   gates, and a size needs BOTH open.** Neither command reveals live
   stock — `B2s` and `D2s_v3` showed as unrestricted and still failed.
   Also found along the way: legacy A-series (`Standard_A2_v2`) can only
   boot Hypervisor Generation 1, so it needs the non-`gen2` Ubuntu image
   (`22_04-lts`) — a compatibility error that surfaced only because that
   size briefly passed the capacity check.

   **Decision**: after six sizes across five families, moved the whole
   experiment to the **AWS `us-east-1` ↔ Azure `eastus`** pairing
   (peering location `useast`), a much larger region. This is a
   legitimate finding in its own right for the write-up: the Frankfurt
   pairing is announced for preview, but at least this subscription
   couldn't actually provision a VM there. Spot pricing was also tried
   as a workaround and did not help; it has been removed.

   Quota increases were considered and rejected for this use case:
   they're generally not instant (often manual review on
   pay-as-you-go/trial subscriptions), so automating one inside a
   script would either hang or silently fail to unblock the session.

   **Third gate, found in eastus:** `Standard_D2s_v3` was regionally
   listed with quota 10, but `az vm list-skus` showed `restrictions:
   NotAvailableForSubscription` (location and zones 1,2,3) — the
   subscription itself is blocked from that SKU. Filtering with
   `--query "[?length(restrictions)==\`0\` && ...]"` yields the usable
   sizes; `Standard_D2s_v4` (DSv4 quota 10, unrestricted) was chosen.
   `scripts/01-azure-up.sh` now preflights this restriction check before
   creating anything. It cannot detect live capacity shortages. Germany
   West Central was not re-tested with the restriction filter; its
   earlier failures were live-capacity ones that no static check predicts.

6. **CONFIRMED provider limitation**: destroying/replacing a tainted
   `azurerm_resource_group_template_deployment` can fail with
   `removing items provisioned by this Template Deployment:
   properties.OutputResources was nil` when the previous deployment
   attempt failed early (e.g. a request-validation error like the
   `"Frankfurt"` rejection, likely before Azure ever created a real
   underlying resource) — Terraform's destroy logic depends on that
   field to know what to clean up, and a deployment that never
   completed doesn't populate it. Fix: verify no real resource actually
   exists (`az network express-route list --resource-group <rg> -o
   table`), then `terraform state rm
   azurerm_resource_group_template_deployment.circuit` to clear
   Terraform's stuck bookkeeping (this only touches local state, not
   Azure) and let the next apply recreate it cleanly. Confirmed working
   in practice: the circuit list was empty, `state rm` was run, and a
   subsequent full teardown via `07-down-azure.sh` completed
   successfully.

7. **CONFIRMED sequencing dependency, found via a real deployment
   error**: the Gateway Connection
   (`azurerm_virtual_network_gateway_connection`) cannot be created
   until AWS has actually redeemed the circuit's activation key.
   Attempting it too early fails with:
   ```
   ServiceProviderNotProvisioned: The current cross connection
   provisioning state 'NotProvisioned' of this service key ... prevents
   this operation.
   ```
   This is a genuine architectural constraint: the circuit's "cross
   connection provisioning state" only transitions once the remote party
   accepts. **Resolution**: `01-azure-up.sh` now applies everything
   except the Gateway Connection (via explicit `-target` flags excluding
   just that resource). `02-aws-up.sh` does its normal AWS work, then
   finishes the job as a final step — applying `terraform/azure` again
   (no target) to create the now-unblocked Gateway Connection, with a
   retry loop (6 attempts, 30s apart) to absorb any brief propagation
   delay between AWS's API call returning success and Azure's circuit
   state actually reflecting it. This keeps the script count at two
   (`01`, `02`) rather than introducing new numbered scripts for what is
   really a 3-phase dependency — a deliberate choice, made explicitly at
   the person's preference, to keep the project's script structure
   stable and predictable, at the cost of `02-aws-up.sh` doing slightly
   more than its name implies.

8. **RESOLVED:** `attach_point` (the DX gateway) plus `activation_key` is
   accepted by AWS; no `remote_account`/`environment_id` needed on the
   activation-key branch.
9. **NSG rule specifics** — confirmed conceptually required (default-deny
   inbound), exact rule shape (priority, direction, protocol fields for
   `azurerm_network_security_rule`) to be worked out during
   implementation.

10. **CONFIRMED ordering flaw in the original design: Azure serializes
    VNet changes behind gateway provisioning.** While the ExpressRoute
    gateway is being provisioned into a VNet's `GatewaySubnet` (~26-30
    minutes), any other change to that VNet — the VM's NIC, the
    subnet/NSG association — queues behind it. Observed directly:
    `azurerm_network_interface` and
    `azurerm_subnet_network_security_group_association` both sat at
    "Still creating..." for the full gateway duration and only completed
    at (or after) the moment the gateway did. Two consequences:

    - **Timeout:** when the gateway ran to ~30 minutes, the NIC hit
      Terraform's default create timeout:
      `creating Network Interface: polling after CreateOrUpdate:
      context deadline exceeded`.
    - **Every VM failure was delayed by the full gateway wait.** The VM
      can't be attempted until its NIC exists, so errors Azure could
      have returned in seconds (capacity, quota, hypervisor generation)
      only appeared after ~28 minutes, repeatedly.

    **Resolution**: `gateway.tf` now has
    `depends_on = [azurerm_linux_virtual_machine.this]` on the gateway,
    inverting the order: the cheap, failure-prone resource goes first,
    and because Terraform won't start a resource whose dependency
    failed, a failed VM attempt never triggers the gateway at all.
    `depends_on` is graph ordering only — adding it to a gateway that
    already exists does not force recreation. General principle for this
    project: **create cheap, likely-to-fail resources before slow,
    expensive ones.**

11. **CONFIRMED: the Multicloud activation key is not available via API,
    and the ARM-deployment outputs are unreliable on re-apply.**
    - `serviceKey` (and every property returned by api-versions
      2024-07-01 … 2025-07-01, which is all the CLI exposes) is only the
      classic ExpressRoute GUID. AWS rejected it: "activation key is not
      valid base64". **RESOLVED:** the real key (~360 base64 chars) is
      returned as `properties.activationKey` by ARM **api-version
      2026-05-01** (found via the portal's JSON View, which offers newer
      versions than the CLI). `01-azure-up.sh` reads it with
      `az rest --method get --url .../expressRouteCircuits/<name>?api-version=2026-05-01
      --query properties.activationKey`, with a manual-paste fallback;
      `02-aws-up.sh` refuses GUIDs / non-base64 before creating anything.
    - The key encodes the target AWS region (`us-east-1`): applying with
      `AWS_REGION=eu-central-1` failed with "Region mismatch: URI region
      'us-east-1' does not match current region".
    - Re-applying `azurerm_resource_group_template_deployment.circuit`
      re-PUT the circuit and returned EMPTY outputs (`"{}"`), breaking
      `jsondecode(output_content).circuitId`. Fixed by computing the
      circuit ID from the deployment ID (`replace(...)`) and setting
      `lifecycle { ignore_changes = [template_content] }`.
    - The gateway connection returns `ServiceProviderNotProvisioned`
      while the circuit's cross-connection state is `Provisioning`
      (right after AWS accepts). **Worse:** that failed attempt still
      creates a `Failed` stub connection in Azure that Terraform does not
      track, so every retry then fails with "a resource with the ID ...
      already exists" and plain retrying can never succeed. `02-aws-up.sh`
      therefore (1) waits until the circuit's `serviceProviderProvisioningState`
      is `Provisioned` (up to 30 min) and (2) deletes any untracked stub
      before each attempt.

12. **CONFIRMED: teardown must not trust a crashing CLI or Terraform's
    ARM-deployment cleanup.**
    - `terraform destroy` fails on the circuit's ARM deployment with
      "`properties.OutputResources` was nil - insufficient data to clean up
      this Template Deployment" (same root cause as item 6). The resource
      group (with a Failed circuit inside) is left behind.
    - `az group exists` crashed on one install ("No module named
      'azure.mgmt.resource.resources.v2024_11_01'") and printed nothing; the
      first version of `07-down-azure.sh` read the empty output as "gone"
      and reported success while the group still existed. Fixed: resource
      group existence/deletion now go through `az rest` (helpers in
      `lib/common.sh`: `azure_rg_state` returns present/absent/unknown, and
      "unknown" aborts instead of being treated as gone). `08` and `03` use
      the same approach.
    - `terraform destroy` also spent its whole 30 minute timeout on the
      gateway connection delete ("polling after Delete: context deadline
      exceeded") in a real run and then errored. `07-down-azure.sh` now
      deletes the resource group directly by default (Azure orders the child
      deletions itself) and prints the remaining resource types while it
      waits; `USE_TERRAFORM_DESTROY=1` restores the old path.

13. **Operational notes from the first full run.**
    - AWS CLI v2 opens a pager (`less`) for some output in small terminals;
      `load_config` now exports `AWS_PAGER=""` so scripts never block.
    - `08` previously showed `None` for gateway connections because
      `connectionStatus` is empty for ExpressRoute connections; it now
      prints `provisioningState`.
    - `09` listed no Interconnect connections although one existed (the
      `list-connections` JSON shape is undocumented). It now matches any
      `mcc-*` ID in the response and falls back to the ID in `state/aws.json`.
    - **AMI filter picked the minimal image.** `al2023-ami-*-x86_64` also
      matches `al2023-ami-minimal-*`; in the run above the instance got the
      minimal AMI, where `rpm -q ec2-instance-connect` reports "not
      installed", so the console's EC2 Instance Connect failed ("Error
      establishing SSH connection to your instance"). Terminal SSH with the
      Terraform key pair was unaffected. Filter is now `al2023-ami-2023.*-x86_64`.
      The experiment's tests never depended on this; it only matters for
      console access.
    - `07` progress lines now read `[mm:ss] still deleting — left: <types>`.

## Design decisions carried over from the GCP project

- Single `config/credentials.env` for all credentials (AWS + Azure),
  rather than a separate credential file for Azure — Azure Service
  Principal auth is a handful of flat strings, unlike GCP's downloadable
  multi-field JSON service account key, so there's no PEM-key-shaped
  reason to split it out. This is a simplification relative to the GCP
  project's two-file (`credentials.env` + `gcp-sa-key.json`) approach.
- `.terraform.lock.hcl` committed, not ignored — same reasoning as the
  GCP project (reproducibility, no secrets).
- `screenshots/` gitignored by default — same reasoning (real IPs/
  identifiers in captured output).
- Script numbering reflects initiation direction: the initiator's
  up-script is always `01`. This project: `01-azure-up.sh`,
  `02-aws-up.sh` (reversed from the GCP project's `01-aws-up.sh`,
  `02-gcp-up.sh`).
# Executive Summary

## What this is

A hands-on test of **Azure Multicloud Interconnect** and its AWS
counterpart, **AWS Interconnect – multicloud** — announced jointly by
Microsoft and AWS on August 31, 2026. This is the follow-up to an
earlier experiment connecting AWS and Google Cloud the same way; this
time the two clouds are AWS and Azure, and the connection is initiated
from the **Azure** side instead.

## Why it matters

The pitch is the same as it was for AWS↔GCP: private, managed,
on-demand connectivity between two clouds, provisioned through each
provider's own console/CLI/Terraform rather than the traditional
approach of leasing physical cross-connects at a shared datacenter and
hand-configuring BGP. Microsoft's own framing: this replaces a "build it
yourself" stack of ExpressRoute, Direct Connect, a colocation partner,
customer-managed routers, and manual BGP sessions with "one managed
resource."

Notable specifics for this pairing:
- Preview bandwidth cap: 1 Gbps (matches the AWS↔GCP pairing's cap).
- General availability target: up to 100 Gbps.
- MACsec encryption at the physical layer, included by default.
- Preview region list is narrow: only four Azure regions
  (Australia East, East US, Germany West Central, West US), with no
  cross-region connectivity supported during preview.

## What we did

1. Stand up a minimal environment on each cloud — one VM, one private
   network — using Terraform where possible.
2. Initiate the connection from Azure (create an ExpressRoute circuit
   with the new `MultiCloud` SKU), generating an activation key.
3. Redeem that key on the AWS side to complete the connection.
4. Log into both machines and ping/trace/TCP-check each other using only
   private IP addresses.
5. Tear the whole thing down afterward.

## What we found

**It works.** An Azure VM and an AWS EC2 instance reached each other over
private IPs, in both directions, with no public internet involved
(AWS `us-east-1` <-> Azure `eastus`, 1 Gbps preview circuit):

- Round-trip latency of about 3.6 ms (Azure to AWS) and 4.1 ms (AWS to
  Azure), 0% packet loss, SSH port reachable both ways.
- No manual routing work was needed on the Azure side.

What it took, and what to know before trying it yourself:

- **The tooling is not ready yet.** The standard Terraform resource for the
  Azure circuit cannot set the AWS account, so we deployed it as a raw ARM
  template. The activation key that AWS needs is not returned by the CLI or
  by any API version it uses; it only appears in the newest API version
  (2026-05-01), which we found by looking at the portal's JSON view.
- **It is slow.** The Azure gateway takes about 30 minutes to build, and
  the link only becomes usable once Azure reports the circuit as
  provisioned after AWS accepts. Creating the gateway connection too early
  fails and leaves a broken leftover resource behind.
- **Capacity and quota matter.** Our first region (Frankfurt) had no usable
  VM capacity for this subscription, so we moved to US East.
- **Teardown needs care.** Deleting the Azure resources through Terraform
  hung and failed; deleting the whole resource group directly works and
  takes about 20 minutes. Always verify that nothing is left, since the
  gateway and circuit are billed while they exist.

## Caveats

- This ran against preview infrastructure announced days before work
  started; details may change.
- The Terraform provider gap was confirmed: the standard
  `azurerm_express_route_circuit` resource does not support the `MultiCloud`
  SKU's `partnerAccountId`, so a raw ARM template deployment is used for that
  one resource.
- As with the GCP project, this is a disposable, one-off test
  environment, not a production reference architecture.
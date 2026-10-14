# Azure ↔ AWS Interconnect Experiment

A test setup that provisions an Azure VM and an AWS EC2 instance,
connects them privately using **Azure Multicloud Interconnect** (Azure
side) and **AWS Interconnect – multicloud** (AWS side), and verifies
private-IP connectivity by pinging between them. This is the sibling
project to `aws-gcp-interconnect-experiment`, but with two differences:
the other cloud is Azure instead of GCP, and **Azure initiates the
connection** this time (AWS accepts via activation key), reversed from
the AWS-initiated GCP project.

Both services were announced August 31, 2026 and are in preview. **The
experiment has been run successfully end to end** (AWS `us-east-1` ↔ Azure
`eastus`): private pings work in both directions at roughly 3–4 ms. Getting
there needed several workarounds (Terraform provider gap, hidden activation
key API version, ordering constraints) — ARCHITECTURE.md documents each one.

See `ARCHITECTURE.md` for a detailed technical breakdown, and
`EXECUTIVE_SUMMARY.md` for a short human-readable overview.

## Directory structure

```
aws-azure-interconnect-experiment/
├── README.md
├── ARCHITECTURE.md
├── EXECUTIVE_SUMMARY.md
├── .gitignore
│
├── config/
│   └── credentials.env       # AWS + Azure + SSH config — YOU fill this in (see below)
│
├── terraform/
│   ├── azure/                 # VNet, subnet, GatewaySubnet, VM, NSG,
│   │                          # ExpressRoute Gateway + Gateway Connection,
│   │                          # ExpressRoute Circuit (MultiCloud SKU —
│   │                          # likely via ARM template deployment, not
│   │                          # a typed resource; see ARCHITECTURE.md)
│   └── aws/                   # VPC, subnet, EC2, security group, DX Gateway,
│                              # awscc_interconnect_connection (this time
│                              # created via activation_key, not
│                              # environment_id — Azure initiates)
│
├── scripts/
│   ├── lib/common.sh          # shared helpers (logging, state I/O, polling)
│   ├── 01-azure-up.sh         # bring up Azure half, initiate connection
│   ├── 02-aws-up.sh           # bring up AWS half, accept connection via activation key
│   ├── 03-status.sh           # check status of both sides
│   ├── 04-test-azure-to-aws.sh # ping + path trace + TCP port check
│   ├── 05-test-aws-to-azure.sh # ping + path trace + TCP port check
│   ├── 06-down-aws.sh         # tear down AWS half
│   ├── 07-down-azure.sh       # tear down Azure half
│   ├── 08-azure-inventory.sh  # troubleshooting: comprehensive read-only Azure resource check
│   └── 09-aws-inventory.sh    # troubleshooting: comprehensive read-only AWS resource check
│
├── state/                     # runtime hand-off data (gitignored)
├── keys/                      # generated SSH keypairs (gitignored)
└── screenshots/               # captured output for the article
```

Note the script numbering: Azure's up-script is `01` and AWS's is `02`
this time, reflecting that Azure initiates — the initiator's script
always runs first, matching the convention from the GCP project (where
AWS initiated and was `01`).

## Prerequisites

- Terraform >= 1.7
- AWS CLI v2, authenticated access to an AWS account
- Azure CLI (`az`), authenticated access to an Azure subscription
- `jq`
- An SSH client

## Things you need to provide manually

There are **no manual portal steps** in the flow: the activation key is
fetched automatically from the Azure API (ARM api-version 2026-05-01) and the
Azure gateway connection is created automatically once AWS has accepted. Only
credentials and region settings are yours to provide.

Before running any script, fill in `config/credentials.env`:

1. **AWS credentials** — `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` from
   an IAM user/role with permissions for VPC, EC2, Direct Connect, and
   Interconnect (`interconnect:*`) actions. `AWS_REGION` must pair with
   your chosen Azure region (see below — preview pairing is narrow).
   `AWS_ACCOUNT_ID` is also required as a plain value — Azure's
   ExpressRoute circuit needs it as `partnerAccountId` to know which AWS
   account is allowed to redeem the activation key.

2. **Azure Service Principal** — create one and fill in the four
   `AZURE_*` credential fields:
   ```
   az ad sp create-for-rbac --name interconnect-experiment --role Contributor \
     --scopes /subscriptions/<AZURE_SUBSCRIPTION_ID>
   ```
   This needs Contributor (or equivalent) on the subscription — VNet,
   VM, NSG, ExpressRoute Circuit, and ExpressRoute Gateway all need to be
   created.

3. **Region pairing** — CONFIRMED, and already set as the defaults in
   `config/credentials.env`: this project uses **AWS `us-east-1`
   (N. Virginia) ↔ Azure `eastus`**, with peering location `useast`.
   (The project originally targeted Frankfurt / `germanywestcentral`,
   but that Azure region had no usable VM capacity or quota for this
   subscription — see ARCHITECTURE.md item 5.) The full confirmed
   preview pairing list:

   | AWS region | Azure region | `AZURE_PEERING_LOCATION` |
   |---|---|---|
   | US East (N. Virginia) | East US | `useast` |
   | US West (N. California) | West US | `uswest` |
   | Asia Pacific (Sydney) | Australia East | `australiaeast` |
   | Europe (Frankfurt) | Germany West Central | `germanywc` |

   Cross-region connectivity is explicitly **not** supported during
   preview, so don't mix rows.

   Before your first run, check that the VM size has both regional
   availability and subscription quota in the Azure region:
   `az vm list-skus --location eastus --size Standard_D2s_v4 --all -o table`
   and `az vm list-usage --location eastus -o table`.

4. **`AZURE_PEERING_LOCATION`** — valid values for AWS come from
   `az network express-route list-service-providers` (currently
   `australiaeast, germanywc, useast, useast2euap, uswest`). Classic
   city names such as `Frankfurt` are rejected.

5. Leave `SSH_KEY_NAME_AWS` / `SSH_KEY_NAME_AZURE` and the CIDR/instance-size
   defaults as-is unless you have a reason to change them — scripts
   01/02 generate the actual keypairs into `keys/` for you, and Azure's
   `GatewaySubnet` CIDR has a naming requirement baked into the Terraform
   config (the subnet must literally be named `GatewaySubnet`).

## Starting the experiment

Expect roughly 30–40 minutes for `01` (the ExpressRoute gateway alone takes
~30 min) and another 10–30 minutes for `02` (it waits for the circuit to
report `Provisioned` before creating the Azure gateway connection).

```bash
./scripts/01-azure-up.sh       # preflight (VM size), provisions Azure
                                 # VNet/VM/NSG/ExpressRoute Gateway, creates
                                 # the MultiCloud circuit, fetches the
                                 # activation key, writes state/azure.json

./scripts/02-aws-up.sh         # validates the key, accepts the connection,
                                 # provisions AWS VPC/EC2, then waits for
                                 # the circuit and creates the Azure gateway
                                 # connection; writes state/aws.json

./scripts/03-status.sh         # check status of both sides
```

Once both sides look healthy:

```bash
./scripts/04-test-azure-to-aws.sh
./scripts/05-test-aws-to-azure.sh
```

## Tearing down

```bash
./scripts/06-down-aws.sh
./scripts/07-down-azure.sh
```

`07` deletes the Azure resource group directly (not `terraform destroy`,
which hung for 30 min on the gateway connection and then failed) and prints
what is still being deleted; expect about 20 minutes. If it times out after
60 minutes, just re-run it. `USE_TERRAFORM_DESTROY=1 ./scripts/07-down-azure.sh`
restores the old behavior. If a run fails partway, always tear everything
down before retrying.

Run `./scripts/03-status.sh` once more afterward to confirm nothing is
left active. Also run the inventory scripts (`08`/`09`) — given this is
day-old preview infrastructure, don't assume teardown left nothing
behind without checking directly.

## Troubleshooting

This project is being built against infrastructure announced days ago.
Expect rough edges beyond what's already documented in ARCHITECTURE.md.
Use `08-azure-inventory.sh` / `09-aws-inventory.sh` for a real,
region-flexible read of what actually exists in each cloud — don't trust
`state/*.json` alone, for the same reasons documented in the sibling
GCP project (state files reflect what a script *thinks* happened, not
necessarily ground truth if a script died partway through).

## Before pushing this repo anywhere

1. **Reset `config/credentials.env`** — every value back to `REPLACE_ME`,
   including all four `AZURE_*` credential fields, not just the AWS ones.
2. **Check `state/azure.json` and `state/aws.json`** — should be `{}`.
3. **Check `keys/`** — should contain only `.gitkeep`.
4. **Check `screenshots/`** — gitignored by default; review before
   committing any manually.
5. **Run `git status` and `git diff --cached` before your first commit.**
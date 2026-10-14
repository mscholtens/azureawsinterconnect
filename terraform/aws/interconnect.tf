# -----------------------------------------------------------------------
# Direct Connect Gateway — the mandatory attach point, same as the GCP
# project. Confirmed unconditionally required regardless of whether the
# connection is created via environment_id or accepted via
# activation_key (attach_point has no conditional requirement in the
# schema tied to that choice).
# -----------------------------------------------------------------------

resource "aws_vpn_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name    = "interconnect-experiment-vgw"
    Project = "aws-azure-interconnect-experiment"
  }
}

resource "aws_dx_gateway" "this" {
  name            = "interconnect-experiment-dxgw"
  amazon_side_asn = 64512
}

resource "aws_dx_gateway_association" "this" {
  dx_gateway_id         = aws_dx_gateway.this.id
  associated_gateway_id = aws_vpn_gateway.this.id
}

# -----------------------------------------------------------------------
# AWS Interconnect Connection — accepting an Azure-initiated connection.
#
# DIRECTION CHANGE from the GCP project: there, this resource set
# `environment_id` + `remote_account` (AWS-initiated), with
# `activation_key` computed as an output. Here, Azure initiated, so this
# resource sets `activation_key` as an INPUT (obtained from Azure's
# ExpressRoute circuit) and does NOT set `environment_id` or
# `remote_account` — those are mutually exclusive with activation_key
# per the provider schema confirmed in the GCP project.
#
# UNCONFIRMED for this direction specifically (flagged in
# ARCHITECTURE.md's open questions):
#   - Whether `bandwidth` should/can still be set explicitly when
#     redeeming an activation key, or whether it's determined entirely
#     by the key itself (the circuit on the Azure side already specifies
#     bandwidthInMbps). Deliberately OMITTED here as a first attempt —
#     add back only if `terraform plan`/`apply` indicates it's required.
#   - Whether `attach_point` behaves identically in this branch. Kept
#     here since the schema shows it as unconditionally required.
# -----------------------------------------------------------------------

resource "awscc_interconnect_connection" "this" {
  activation_key = var.activation_key

  attach_point = {
    direct_connect_gateway = aws_dx_gateway.this.id
  }

  description = "aws-azure-interconnect-experiment"

  tags = [
    {
      key   = "Project"
      value = "aws-azure-interconnect-experiment"
    }
  ]

  depends_on = [aws_dx_gateway_association.this]
}

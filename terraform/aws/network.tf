data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "interconnect-experiment-vpc"
    Project = "aws-azure-interconnect-experiment"
  }
}

resource "aws_subnet" "this" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name    = "interconnect-experiment-subnet"
    Project = "aws-azure-interconnect-experiment"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name    = "interconnect-experiment-igw"
    Project = "aws-azure-interconnect-experiment"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name    = "interconnect-experiment-public-rt"
    Project = "aws-azure-interconnect-experiment"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.public.id
}

# CONFIRMED REQUIRED in the sibling GCP project (found empirically —
# without this, GCP/Azure-side routes never propagate into the route
# table even when every other component reports healthy). Applied
# proactively here from the start, rather than rediscovering it.
resource "aws_vpn_gateway_route_propagation" "public" {
  vpn_gateway_id = aws_vpn_gateway.this.id
  route_table_id = aws_route_table.public.id
}

# NOTE: no custom Network ACL — default (allow-all) used deliberately,
# same reasoning as the GCP project.

resource "aws_security_group" "this" {
  name        = "interconnect-experiment-sg"
  description = "SSH from allowed_ssh_cidr, ICMP from the Azure peer CIDR"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "ICMP from Azure VNet (the actual interconnect test)"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.peer_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "interconnect-experiment-sg"
    Project = "aws-azure-interconnect-experiment"
  }
}

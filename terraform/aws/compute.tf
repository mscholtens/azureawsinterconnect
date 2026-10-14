# Amazon Linux 2023 — default SSH user is "ec2-user".
#
# The name pattern must be "al2023-ami-2023.*" (the STANDARD image). The looser
# "al2023-ami-*" also matches "al2023-ami-minimal-*", and most_recent can pick
# that one; the minimal image does not include ec2-instance-connect, so the
# console's "EC2 Instance Connect" fails ("Error establishing SSH connection").
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "this" {
  key_name   = "interconnect-experiment-ec2"
  public_key = trimspace(file(var.ssh_public_key_path))
}

resource "aws_instance" "this" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.this.id
  vpc_security_group_ids      = [aws_security_group.this.id]
  key_name                    = aws_key_pair.this.key_name
  associate_public_ip_address = true

  tags = {
    Name    = "interconnect-experiment-ec2"
    Project = "aws-azure-interconnect-experiment"
  }
}

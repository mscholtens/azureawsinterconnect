output "connection_id" {
  value = awscc_interconnect_connection.this.connection_id
}

output "connection_provider_name" {
  description = "Computed by AWS — should reflect Azure as the partner CSP once the connection is accepted."
  value       = awscc_interconnect_connection.this.provider_name
}

output "connection_state" {
  value = awscc_interconnect_connection.this.state
}

output "dxgw_id" {
  value = aws_dx_gateway.this.id
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "ec2_instance_id" {
  value = aws_instance.this.id
}

output "ec2_private_ip" {
  value = aws_instance.this.private_ip
}

output "ec2_public_ip" {
  value = aws_instance.this.public_ip
}

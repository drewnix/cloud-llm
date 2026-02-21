# -----------------------------------------------------------------------------
# EC2 GPU Module - Outputs
# -----------------------------------------------------------------------------

output "instance_id" {
  description = "ID of the GPU EC2 instance"
  value       = aws_instance.gpu.id
}

output "instance_public_ip" {
  description = "Public IP of the GPU instance (may be empty if in private subnet)"
  value       = aws_instance.gpu.public_ip
}

output "instance_private_ip" {
  description = "Private IP of the GPU instance"
  value       = aws_instance.gpu.private_ip
}

output "instance_profile_name" {
  description = "Name of the IAM instance profile for the GPU instance"
  value       = aws_iam_instance_profile.gpu_instance.name
}

output "instance_profile_arn" {
  description = "ARN of the IAM instance profile for the GPU instance"
  value       = aws_iam_instance_profile.gpu_instance.arn
}

output "role_arn" {
  description = "ARN of the IAM role for the GPU instance"
  value       = aws_iam_role.gpu_instance.arn
}

output "role_name" {
  description = "Name of the IAM role for the GPU instance"
  value       = aws_iam_role.gpu_instance.name
}

output "bucket_name" {
  description = "The name of the S3 model cache bucket"
  value       = aws_s3_bucket.model_cache.bucket
}

output "bucket_arn" {
  description = "The ARN of the S3 model cache bucket"
  value       = aws_s3_bucket.model_cache.arn
}

output "bucket_id" {
  description = "The ID of the S3 model cache bucket"
  value       = aws_s3_bucket.model_cache.id
}

output "vpc_endpoint_id" {
  description = "The ID of the S3 VPC endpoint"
  value       = aws_vpc_endpoint.s3.id
}

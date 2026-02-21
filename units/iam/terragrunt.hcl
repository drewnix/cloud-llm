# -----------------------------------------------------------------------------
# Unit: IAM
# -----------------------------------------------------------------------------
# Instance role and profile with least-privilege policies for S3, CloudWatch, SSM.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/modules//iam"
}

dependency "s3_model_cache" {
  config_path = values.s3_model_cache_path

  mock_outputs = {
    bucket_arn = "arn:aws:s3:::mock-bucket"
  }
}

inputs = {
  model_cache_bucket_arn = dependency.s3_model_cache.outputs.bucket_arn
}

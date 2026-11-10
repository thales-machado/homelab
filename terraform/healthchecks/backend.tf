terraform {
  backend "s3" {
    bucket = "terraform-state"
    key    = "healthchecks/terraform.tfstate"
    region = "auto"
    # R2 endpoint comes from the environment, so the account ID stays out of git:
    # AWS_ENDPOINT_URL_S3=https://<account-id>.r2.cloudflarestorage.com terraform init
    use_path_style              = true
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

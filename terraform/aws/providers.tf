# Credentials picked up from the environment (AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION), exported by
# scripts/lib/common.sh from config/credentials.env. No credentials
# hardcoded here.

provider "aws" {
  region = var.aws_region
}

provider "awscc" {
  region = var.aws_region
}

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    # awscc — needed for awscc_interconnect_connection, same as the
    # sibling aws-gcp-interconnect-experiment project. See that
    # project's ARCHITECTURE.md for how this was confirmed necessary.
    awscc = {
      source  = "hashicorp/awscc"
      version = ">= 1.0"
    }
  }
}

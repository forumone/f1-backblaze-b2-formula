# f1-backblaze-b2-formula

This formula installs the Backblaze B2 CLI utility, backup scripts, and crontab entries.

Links to  `b2` documentation:
https://b2-command-line-tool.readthedocs.io/en/master/

To get this running in an existing `*-infrastructure` environment...

Region must be set for `aws ssm get-parameter` commands to succeed.  We can set it via the `awscli` configuration file in `~/.aws/config` using the `[default]` profile, or set it at runtime via the `AWS_DEFAULT_REGION` environment variable.  During this testing period we're exporting the `AWS_DEFAULT_REGION` variable as part of the `crontab` expression.

The following must be added to the BuildKite pipeline for the **plan** and **apply** build steps:  
_Example:_
```
    plugins:
      - seek-oss/aws-sm#v2.0.0:
          env:
            B2_APPLICATION_KEY_ID:
              secret-id: "bk_backblaze"
              json-key: .B2_APPLICATION_KEY_ID
            B2_APPLICATION_KEY:
              secret-id: "bk_backblaze"
              json-key: .B2_APPLICATION_KEY
      - docker#v3.5.0:
          image: &tf-version hashicorp/terraform:0.13.3
          entrypoint: /bin/sh
          environment:
            - "B2_APPLICATION_KEY_ID"
            - "B2_APPLICATION_KEY"
```

1) Add a `backblaze.tf` to the `terraform` subdirectory to create the B2 bucket and B2 application key:  
_Example_:
```
resource "b2_bucket" "backups" {
  bucket_name = "f1-${var.aws_account_id}-${var.client}"
  bucket_type = "allPrivate"

  # Server-side encryption is good for you
  default_server_side_encryption {
    mode = "SSE-B2"
  }
}

resource "b2_application_key" "backup_key" {
  # Use the same bucket name for this key
  key_name = b2_bucket.backups.bucket_name

  # Limit the application key to this bucket
  bucket_id = b2_bucket.backups.bucket_id

  # Only offer these capabilities:
  capabilities = [
    # Needed for the 'b2 authorize-account' command
    "listBuckets",

    # Needed for 'b2 sync' and 'b2 upload-file'
    "listFiles",
    "readFiles",
    "writeFiles",
  ]
}

resource "aws_ssm_parameter" "b2_bucket_name" {
  name        = "/forumone/${var.project}/backblaze/bucket-name"
  description = "The friendly name of the Backblaze B2 backup bucket"

  type  = "String"
  value = b2_bucket.backups.bucket_name
  tags  = local.common_tags
}

resource "aws_ssm_parameter" "b2_key" {
  name        = "/forumone/${var.project}/backblaze/application-key"
  description = "Application access keys for the Backblaze B2 backup bucket"

  type = "SecureString"
  value = jsonencode({
    B2_APPLICATION_KEY_ID = b2_application_key.backup_key.application_key_id
    B2_APPLICATION_KEY    = b2_application_key.backup_key.application_key
  })

  tags = local.common_tags
}
```
2) Edit `providers.tf` and add the Backblaze B2 provider:

_Example:_
```
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    okta = {
      source  = "okta/okta"
      version = "~> 3.10"
    }
    b2 = {
      source  = "Backblaze/b2"
      version = "0.8.0"
    }
  }
  required_version = ">= 0.13.3"
}

provider "aws" {
  region = "us-east-2"

  assume_role {
    role_arn = "arn:aws:iam::717166192878:role/BuildkiteTerraformRole"
  }
}

provider "aws" {
  alias  = "infrastructure"
  region = "us-east-2"
}

provider "okta" {}

provider "b2" {}
```
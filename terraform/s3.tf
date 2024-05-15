###############################################################################
# s3.tf — S3 buckets for static assets, access logs, and Terraform state
#
# Architecture Decision:
#   Static assets are served via CloudFront, not directly from S3, so the
#   bucket has no public access. Presigned URLs are used for private objects.
#   All buckets have versioning and server-side encryption enabled.
#   Lifecycle rules reduce storage costs by transitioning old versions to
#   Glacier and expiring them after the retention period.
###############################################################################

###############################################################################
# Static Assets Bucket
###############################################################################

resource "aws_s3_bucket" "static_assets" {
  bucket        = "${local.name_prefix}-static-assets-${random_id.suffix.hex}"
  force_destroy = var.s3_force_destroy

  tags = {
    Name    = "${local.name_prefix}-static-assets"
    Purpose = "static-assets"
  }
}

resource "aws_s3_bucket_versioning" "static_assets" {
  bucket = aws_s3_bucket.static_assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "static_assets" {
  bucket = aws_s3_bucket.static_assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true   # Reduces KMS API call costs
  }
}

resource "aws_s3_bucket_public_access_block" "static_assets" {
  bucket = aws_s3_bucket.static_assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "static_assets" {
  bucket = aws_s3_bucket.static_assets.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }

  rule {
    id     = "expire-incomplete-multipart"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "static_assets" {
  bucket = aws_s3_bucket.static_assets.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 86400
  }
}

###############################################################################
# Access Logs Bucket (ALB + CloudFront + VPC Flow Logs)
###############################################################################

resource "aws_s3_bucket" "logs" {
  bucket        = "${local.name_prefix}-access-logs-${random_id.suffix.hex}"
  force_destroy = var.s3_force_destroy

  tags = {
    Name    = "${local.name_prefix}-access-logs"
    Purpose = "access-logs"
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365   # Comply with typical 1-year log retention policy
    }
  }
}

# Allow ALB to write access logs to this bucket
data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ALB requires the ELB service account to have PutObject permission
        Sid    = "AllowALBAccessLogs"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_elb_service_account.main.arn
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.logs.arn}/alb-access-logs/AWSLogs/${local.account_id}/*"
      },
      {
        # Deny non-HTTPS access to the bucket
        Sid    = "DenyNonHTTPS"
        Effect = "Deny"
        Principal = "*"
        Action   = "s3:*"
        Resource = [
          aws_s3_bucket.logs.arn,
          "${aws_s3_bucket.logs.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

###############################################################################
# Terraform State Bucket (reference only — managed outside this config)
#
# The state bucket and DynamoDB table are created via the bootstrap commands
# in README.md and are NOT managed by this Terraform configuration to avoid
# the chicken-and-egg problem (you need state to manage state).
#
# The resources below document what the bootstrap should create.
###############################################################################

# NOTE: The following is intentionally commented out.
# Uncomment ONLY if you are managing the bootstrap bucket from a separate
# Terraform workspace with a local backend.
#
# resource "aws_s3_bucket" "terraform_state" {
#   bucket = "your-company-terraform-state"
#
#   tags = {
#     Name    = "terraform-state"
#     Purpose = "terraform-remote-state"
#   }
# }

###############################################################################
# Bucket Notification — trigger Lambda or SQS on new objects (example)
###############################################################################

# resource "aws_s3_bucket_notification" "static_assets" {
#   bucket = aws_s3_bucket.static_assets.id
#
#   lambda_function {
#     lambda_function_arn = aws_lambda_function.image_processor.arn
#     events              = ["s3:ObjectCreated:*"]
#     filter_prefix       = "uploads/"
#     filter_suffix       = ".jpg"
#   }
# }

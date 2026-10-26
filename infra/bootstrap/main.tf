data "aws_caller_identity" "current" {}

locals {
  # Buckets in the account regional namespace: only this account can ever create these names.
  name_suffix = "${data.aws_caller_identity.current.account_id}-us-east-1-an"
}

# force_destroy lets terraform destroy empty every object version, so teardown
# needs no hand-written delete loop.
resource "aws_s3_bucket" "state" {
  bucket           = "martin-tfstate-${local.name_suffix}"
  bucket_namespace = "account-regional"
  force_destroy    = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.tls_only["state"].json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

resource "aws_s3_bucket_logging" "state" {
  bucket        = aws_s3_bucket.state.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "access/"

  depends_on = [aws_s3_bucket_policy.logs]
}

# The state's first bucket, in the shared global namespace. AWS recommends
# keeping a global bucket, emptied, instead of deleting it, so that no one else
# can take its name.
resource "aws_s3_bucket" "global_state" {
  bucket        = "martin-tfstate-686699774218-us-east-1"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "global_state" {
  bucket = aws_s3_bucket.global_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "global_state" {
  bucket = aws_s3_bucket.global_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "global_state" {
  bucket = aws_s3_bucket.global_state.id
  policy = data.aws_iam_policy_document.tls_only["global_state"].json

  depends_on = [aws_s3_bucket_public_access_block.global_state]
}

# Server access logs of the state bucket and the CloudTrail log files. It does
# not log its own access, as AWS asks of a log destination.
resource "aws_s3_bucket" "logs" {
  bucket           = "martin-tfstate-logs-${local.name_suffix}"
  bucket_namespace = "account-regional"
  force_destroy    = true
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}

data "aws_iam_policy_document" "tls_only" {
  for_each = {
    state        = aws_s3_bucket.state.arn
    global_state = aws_s3_bucket.global_state.arn
    logs         = aws_s3_bucket.logs.arn
  }

  statement {
    sid       = "DenyWithoutTLS"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value, "${each.value}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "logs" {
  source_policy_documents = [data.aws_iam_policy_document.tls_only["logs"].json]

  statement {
    sid       = "S3ServerAccessLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/access/*"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.state.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/cloudtrail/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_resourcegroups_group" "s3" {
  name        = "martin-project-2-s3"
  description = "The S3 buckets of project 2."

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::S3::Bucket"]
      TagFilters = [{
        Key    = "Owner"
        Values = ["martin"]
      }]
    })
  }
}

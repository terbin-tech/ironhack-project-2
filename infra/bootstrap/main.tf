# force_destroy lets terraform destroy empty every object version, so teardown
# needs no hand-written delete loop.
resource "aws_s3_bucket" "state" {
  bucket        = "martin-tfstate-686699774218-us-east-1"
  force_destroy = true
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

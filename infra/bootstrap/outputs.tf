output "state_bucket" {
  description = "Name of the S3 bucket that holds the state of the other roots."
  value       = aws_s3_bucket.state.id
}

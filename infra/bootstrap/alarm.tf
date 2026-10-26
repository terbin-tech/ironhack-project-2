# An alarm on requests to the state buckets made without TLS. The buckets deny
# such requests; the alarm reports that someone tried. CloudTrail logs the
# buckets' object-level requests to CloudWatch Logs, where a metric filter
# counts the events that carry no TLS details.

locals {
  trail_name = "martin-project-2-s3"
  trail_arn  = "arn:aws:cloudtrail:us-east-1:${data.aws_caller_identity.current.account_id}:trail/${local.trail_name}"
}

resource "aws_cloudwatch_log_group" "trail" {
  name = "martin-project-2-s3-trail"
}

resource "aws_iam_role" "trail" {
  name = "martin-project-2-s3-trail"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
    }]
  })
}

resource "aws_iam_role_policy" "trail" {
  name = "logs"
  role = aws_iam_role.trail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.trail.arn}:log-stream:${data.aws_caller_identity.current.account_id}_CloudTrail_us-east-1*"
    }]
  })
}

resource "aws_cloudtrail" "s3" {
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.logs.id
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = false
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.trail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.trail.arn

  advanced_event_selector {
    name = "Object-level requests to the state buckets"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    field_selector {
      field = "resources.ARN"
      starts_with = [
        "${aws_s3_bucket.state.arn}/",
        "${aws_s3_bucket.global_state.arn}/",
      ]
    }
  }

  depends_on = [aws_s3_bucket_policy.logs, aws_iam_role_policy.trail]
}

resource "aws_cloudwatch_log_metric_filter" "without_tls" {
  name           = "martin-project-2-s3-without-tls"
  log_group_name = aws_cloudwatch_log_group.trail.name
  pattern        = "{ $.tlsDetails.tlsVersion NOT EXISTS }"

  metric_transformation {
    name      = "S3RequestsWithoutTLS"
    namespace = "martin-project-2"
    value     = "1"
  }
}

resource "aws_sns_topic" "alarm" {
  name = "martin-project-2-s3-alarm"
}

resource "aws_sns_topic_subscription" "alarm" {
  count = var.alarm_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alarm.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "without_tls" {
  alarm_name          = "martin-project-2-s3-without-tls"
  alarm_description   = "A request to a Terraform state bucket was made without TLS."
  namespace           = "martin-project-2"
  metric_name         = "S3RequestsWithoutTLS"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarm.arn]
}

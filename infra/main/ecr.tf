resource "aws_ecr_repository" "this" {
  for_each = toset(["vote", "result", "worker"])

  name                 = "martin-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

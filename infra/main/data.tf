resource "aws_db_subnet_group" "this" {
  name       = "martin-project-2"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "rds" {
  name        = "martin-project-2-rds"
  description = "PostgreSQL access from the EKS cluster"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_cluster" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = module.eks.cluster_primary_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_instance" "this" {
  identifier     = "martin-project-2"
  engine         = "postgres"
  engine_version = "18.6"
  instance_class = "db.t4g.micro"
  multi_az       = true

  storage_type           = "gp3"
  allocated_storage      = 20
  storage_encrypted      = true
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  db_name                     = "voting"
  username                    = "votingadmin"
  manage_master_user_password = true

  # Daily automated backups, kept 7 days; teardown deletes them with the instance
  backup_retention_period = 7

  deletion_protection        = false
  skip_final_snapshot        = true
  delete_automated_backups   = true
  auto_minor_version_upgrade = true

  # Referring to the log groups makes them exist before the export starts and
  # go after the instance at teardown
  enabled_cloudwatch_logs_exports = keys(aws_cloudwatch_log_group.rds)

  # Apply reviewed changes at apply time, not in the next weekly maintenance window
  apply_immediately = true
}

# The groups RDS writes its exported logs to, created here so they carry the
# project's tags
resource "aws_cloudwatch_log_group" "rds" {
  for_each = toset(["postgresql", "upgrade"])

  name = "/aws/rds/instance/martin-project-2/${each.key}"
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "martin-project-2"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "valkey" {
  name        = "martin-project-2-valkey"
  description = "Valkey access from the EKS cluster"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "valkey_from_cluster" {
  security_group_id            = aws_security_group.valkey.id
  referenced_security_group_id = module.eks.cluster_primary_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "martin-project-2"
  description          = "Vote queue for the voting app"

  engine             = "valkey"
  engine_version     = "9.1"
  node_type          = "cache.t4g.micro"
  num_cache_clusters = 2
  port               = 6379
  cluster_mode       = "disabled"

  # Daily snapshots, kept 7 days; teardown deletes them with the group
  snapshot_retention_limit = 7

  automatic_failover_enabled = true
  multi_az_enabled           = true
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.valkey.id]

  # Role-based access control: only the users in this group can connect
  user_group_ids = [aws_elasticache_user_group.this.id]

  # Apply reviewed changes at apply time, not in the next weekly maintenance window
  apply_immediately = true
}

# One Valkey user per app that uses the queue (result does not), allowed only
# the commands that app runs, on the votes key alone.
locals {
  valkey_users = {
    vote = "on ~votes -@all +rpush"
    # The list commands, and the commands StackExchange.Redis needs to connect
    worker = "on ~votes -@all +lpop +lpush +client +info +echo"
  }
}

# Each password goes to Secrets Manager write-only and is read back for the
# Valkey user, so neither the state nor a plan holds it.
ephemeral "aws_secretsmanager_random_password" "valkey" {
  for_each = local.valkey_users

  password_length = 64
  # ElastiCache does not allow these in user passwords
  exclude_characters = ",\"/@"
}

resource "aws_secretsmanager_secret" "valkey" {
  for_each = local.valkey_users

  name        = "martin-project-2-valkey-${each.key}"
  description = "Valkey user and password for ${each.key}"
}

resource "aws_secretsmanager_secret_version" "valkey" {
  for_each = local.valkey_users

  secret_id = aws_secretsmanager_secret.valkey[each.key].id
  secret_string_wo = jsonencode({
    username = "martin-project-2-${each.key}"
    password = ephemeral.aws_secretsmanager_random_password.valkey[each.key].random_password
  })
  secret_string_wo_version = 1
}

ephemeral "aws_secretsmanager_secret_version" "valkey" {
  for_each = local.valkey_users

  secret_id = aws_secretsmanager_secret_version.valkey[each.key].secret_id
}

resource "aws_elasticache_user" "valkey" {
  for_each = local.valkey_users

  user_id       = "martin-project-2-${each.key}"
  user_name     = "martin-project-2-${each.key}"
  engine        = "valkey"
  access_string = each.value

  passwords_wo         = jsondecode(ephemeral.aws_secretsmanager_secret_version.valkey[each.key].secret_string).password
  passwords_wo_version = aws_secretsmanager_secret_version.valkey[each.key].secret_string_wo_version
}

# A Valkey-engine group holds no usable default user, so only the apps' own
# users can connect.
resource "aws_elasticache_user_group" "this" {
  user_group_id = "martin-project-2"
  engine        = "valkey"
  user_ids      = [for user in aws_elasticache_user.valkey : user.user_id]
}

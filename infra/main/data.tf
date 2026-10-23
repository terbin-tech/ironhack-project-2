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

  deletion_protection        = false
  skip_final_snapshot        = true
  delete_automated_backups   = true
  auto_minor_version_upgrade = false
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

  automatic_failover_enabled = true
  multi_az_enabled           = true
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.valkey.id]
}

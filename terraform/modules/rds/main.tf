terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.13"

  identifier = var.db_identifier
  apply_immediately = true
  engine               = var.db_engine
  engine_version       = var.db_engine_version
  major_engine_version = var.db_major_engine_version
  family               = "${var.db_engine}${var.db_major_engine_version}"
  instance_class       = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  port     = var.db_port

  multi_az               = var.db_multi_az
  vpc_security_group_ids = var.db_vpc_security_group_ids
  db_subnet_group_name   = var.db_subnet_group_name

  skip_final_snapshot = true
  deletion_protection = false

  tags = merge(
    {
      "Name"        = var.db_identifier
      "Environment" = "dev"
    },
    var.tags
  )
}
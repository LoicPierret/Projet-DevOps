variable "db_identifier" {
  description = "The identifier for the RDS instance."
  type        = string
}

variable "db_engine" {
  description = "The database engine to use."
  type        = string
  default     = "postgres"
}

variable "db_engine_version" {
  description = "The engine version to use."
  type        = string
  default     = "16"
}

variable "db_major_engine_version" {
  description = "The major engine version to use."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "The instance class for the RDS instance."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "The allocated storage in gigabytes."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "The maximum allocated storage in gigabytes for autoscaling."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "The name of the database to create."
  type        = string
}

variable "db_username" {
  description = "The username for the master database user."
  type        = string
}

variable "db_port" {
  description = "The port on which the DB accepts connections."
  type        = number
  default     = 5432
}

variable "db_multi_az" {
  description = "Specifies if the RDS instance is multi-AZ."
  type        = bool
  default     = false
}

variable "db_vpc_security_group_ids" {
  description = "List of VPC security groups to associate."
  type        = list(string)
  default     = []
}

variable "db_subnet_group_name" {
  description = "Name of DB subnet group. DB instance will be created in the VPC associated with the DB subnet group."
  type        = string
}

variable "tags" {
  description = "A map of tags to add to all resources."
  type        = map(string)
  default     = {}
}
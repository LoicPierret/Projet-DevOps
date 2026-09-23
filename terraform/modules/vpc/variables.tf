variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "db_subnet_cidrs" {
  description = "CIDR des sous-réseaux dédiés aux bases de données (RDS). Isolés : aucune route vers Internet (ni IGW, ni NAT), joignables uniquement depuis le reste de la VPC via la route locale."
  type        = list(string)
  default     = ["10.0.5.0/24", "10.0.6.0/24"]
}

variable "azs" {
  type = list(string)
}

variable "public_subnet_tags" {
  description = "A map of tags to assign to the public subnets."
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "A map of tags to assign to the private subnets."
  type        = map(string)
  default     = {}
}

variable "db_subnet_tags" {
  description = "A map of tags to assign to the database subnets."
  type        = map(string)
  default     = {}
}
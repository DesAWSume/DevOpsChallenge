variable "app_name" {
  description = "The name of the app"
  default = "tech-challenge-app"
}

variable "submodule" {
  description = "The submodule of the app"
  default = "TechChallengeApp"
}

variable "viper_prefix" {
  description = "The viper prefix used on environment variables"
  default = "VTT"
}

variable "app_image" {
  description = "Docker image to run in the ECS cluster"
  default     = "adongy/hostname-docker:latest"
}

variable "profile" {
  description = "Profile to inherit from AWS CLI"
  default = "default"
}

variable "aws_region" {
  description = "aws region"
  default = "ap-southeast-2"
}

variable "cidr_block" {
  description = "cidr definition for the VPC"
  default = "10.1.0.0/24"
}

variable "az_count" {
  description = "Number of AZs to cover in a given AWS region"
  default     = "2"
}

variable "rds_port" {
  description = "Port that RDS will listen for incomming database connections"
  default     = 5432
}

variable "rds_size" {
  description = "Size of RDS EBS volume to create"
  default = 5
}
variable "rds_storage" {
  description = "Type of RDS EBS volume to create"
  default = "gp2"
}

variable "rds_class" {
  description = "type of RDS instance to create"
  default = "db.t3.micro"
}

variable "rds_engine" {
  description = "Engine type of RDS instance to create"
  default = "postgres"
}

variable "rds_ver" {
  description = "Engine type of RDS Postgres instance"
  default = "13.7"
}

variable "app_port" {
  description = "Port exposed by the docker image to redirect traffic to"
  default     = 3000
}

variable "app_count" {
  description = "Number of docker containers to run"
  default     = 1
}

variable "fargate_cpu" {
  description = "Fargate instance CPU units to provision (1 vCPU = 1024 CPU units)"
  default     = "256"
}

variable "fargate_memory" {
  description = "Fargate instance memory to provision (in MiB)"
  default     = "512"
}


variable "resource_tags" {
  description = "Tags to set for all resources"
  type        = map(string)
  default     = {
    project     = "devops-tech-challenge",
    environment = "dev",
    Name        = "devops-tech-challenge"
  }
}

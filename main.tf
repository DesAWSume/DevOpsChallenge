# Inherit configuration from CLI tools.  No nice way to pull in the region from ~/.aws/config

provider "aws" {
  region = var.aws_region
  #profile = var.profile
}

### Network stack
# TL;DR
# 1. Create VPC with cidr: 10.1.0.0/24 -> Consideration to just have a small set of IPs
# 2. Create public and private subnets in the vpc using cidrsubnet function
# 3. Create igw and NAT gw for public and private subnet routing 

# Fetch AZs in the current region
data "aws_availability_zones" "available" {}

resource "aws_vpc" "vpc" {
  cidr_block = var.cidr_block
  tags = {
    Name = "devops-tech-challenge-vpc"
  }
}

# Create var.az_count private subnets, each in a different AZ
resource "aws_subnet" "private" {
  count             = var.az_count
  cidr_block        = cidrsubnet(aws_vpc.vpc.cidr_block, 3, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  vpc_id            = aws_vpc.vpc.id
  tags = {
    Name = "tech-challenge/private-subnet/${count.index+1}"
  }
  
}

# Create var.az_count public subnets, each in a different AZ
resource "aws_subnet" "public" {
  count                   = var.az_count
  cidr_block              = cidrsubnet(aws_vpc.vpc.cidr_block, 3, var.az_count + count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  vpc_id                  = aws_vpc.vpc.id
  map_public_ip_on_launch = true
    tags = {
      Name = "tech-challenge/public-subnet/${count.index+1}"
  }
}

# IGW for the public subnet
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
    tags = {
      Name = "tech-challange-igw"
  }
}

# Route the public subnet traffic through the IGW
resource "aws_route" "internet" {
  route_table_id         = aws_vpc.vpc.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

# Create a NAT gateway with an EIP for each private subnet to get internet connectivity
resource "aws_eip" "nat-eip" {
  count      = "1"
  vpc        = true
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "nat-gw" {
  count         = "1"
  subnet_id     = element(aws_subnet.public.*.id, count.index)
  allocation_id = element(aws_eip.nat-eip.*.id, count.index)
    tags = {
    Name = "tech-challange/nat-gw/${count.index+1}"
  }
}

# Create route table for the private subnets
# And make it route non-local traffic through the NAT gateway to the internet
resource "aws_route_table" "private-egress" {
  count  = var.az_count
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.nat-gw.*.id, count.index)
  }
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = element(aws_subnet.private.*.id, count.index)
  route_table_id = element(aws_route_table.private-egress.*.id, count.index)
}

# ALB Sec group
resource "aws_security_group" "alb_sg" {
  #name        = "tf-ecs-alb"
  name        = "${var.app_name}-alb"
  description = "controls access to the ALB"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS Postgres Security group
resource "aws_security_group" "rds_sg" {
  name        = "tf-ecs-rds"
  description = "allow inbound db access from ECS only"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    protocol        = "tcp"
    from_port       = var.rds_port
    to_port         = var.rds_port
    security_groups = [aws_security_group.ecs_sg.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Traffic to the ECS Cluster should only come from the ALB
resource "aws_security_group" "ecs_sg" {
  name        = "tf-ecs-tasks"
  description = "allow inbound access from the ALB only"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    protocol        = "tcp"
    from_port       = var.app_port
    to_port         = var.app_port
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

### ALB

resource "aws_alb" "alb" {
  name            = "tf-ecs"
  subnets         = aws_subnet.public.*.id
  security_groups = [aws_security_group.alb_sg.id]
}

resource "aws_alb_target_group" "alb"  {
  name        = var.app_name
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.vpc.id
  target_type = "ip"

  health_check {
    path = "/healthcheck/"
    port = var.app_port
    healthy_threshold = 2
    unhealthy_threshold = 2
    timeout = 2
    interval = 5
    matcher = "200"  # has to be HTTP 200 or fails
  }
}

# Redirect all traffic from the ALB to the target group
resource "aws_alb_listener" "alb" {
  load_balancer_arn = aws_alb.alb.id
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_alb_target_group.alb.id
    type             = "forward"
  }
}

### ECR

resource "aws_ecr_repository" "ecs" {
  name                 = lower(var.app_name)
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "null_resource" "push" {
  provisioner "local-exec" {
    command = <<EOF
aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$ecr_fqdn"
docker tag "servian/techchallengeapp:latest" "$repository"
docker push "$repository:latest"
docker logout "$ecr_fqdn"
EOF

    environment = {
      ecr_fqdn = regex("^([^/]*)/", aws_ecr_repository.ecs.repository_url).0
      region = var.aws_region
      repository = aws_ecr_repository.ecs.repository_url
    }
  }
  depends_on = [aws_ecr_repository.ecs]
}

### RDS

resource "aws_db_subnet_group" "default" {
  name       = "use private subnets for rds"
  subnet_ids = aws_subnet.private.*.id

  tags = {
    Name = "My DB subnet group"
  }
}

resource "random_password" "rds" {
  length = 16
  special = false
}

resource "aws_secretsmanager_secret" "db_cred" {
  name = "${var.app_name}-db-cred"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_cred" {
  secret_id     = aws_secretsmanager_secret.db_cred.id
  secret_string = random_password.rds.result
}

resource "aws_db_instance" "rds_db" {
  allocated_storage    = var.rds_size
  storage_type         = var.rds_storage
  engine               = var.rds_engine
  engine_version       = var.rds_ver
  instance_class       = var.rds_class
  # Database created inside rds instance
  db_name              = "DevOpsChallenge"
  identifier           = lower(var.app_name)
  username             = "DevOpsChallenge"
  port		           = var.rds_port
  db_subnet_group_name = aws_db_subnet_group.default.id
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  password             = random_password.rds.result
  skip_final_snapshot  = true
}

### ECS

# Specific policy for writing to cloudwatch logs
resource "aws_iam_policy" "ECS-CloudWatchLogs" {
  name = "${var.app_name}-ECS-CloudWatchLogs"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": [
        "arn:aws:logs:*:*:*"
      ]
    }
  ]
}
EOF
}

resource "aws_iam_policy" "secrets_access" {
  name = "${var.app_name}-secrets_access"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": [
        "arn:aws:logs:*:*:*"
      ]
    }
  ]
}
EOF
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${var.app_name}-exe-role"
 
  assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Action": "sts:AssumeRole",
     "Principal": {
       "Service": "ecs-tasks.amazonaws.com"
     },
     "Effect": "Allow",
     "Sid": ""
   }
 ]
}
EOF
}
resource "aws_iam_role" "ecs_task_role" {
  name = "${var.app_name}-task-role"
 
  assume_role_policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Action": "sts:AssumeRole",
     "Principal": {
       "Service": "ecs-tasks.amazonaws.com"
     },
     "Effect": "Allow",
     "Sid": ""
   }
 ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "secrets_access" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.secrets_access.arn
}

resource "aws_iam_role_policy_attachment" "ECS-CloudWatchLogs" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.ECS-CloudWatchLogs.arn
}

resource "aws_ecs_cluster" "ecs" {
  name = "${var.app_name}-tf-ecs-cluster"
}

locals {
  viper_DbUser = upper(format("%s_%s",var.viper_prefix,"DbUser"))
  viper_DbPassword = upper(format("%s_%s",var.viper_prefix,"DbPassword"))
  viper_DbName = upper(format("%s_%s",var.viper_prefix,"DbName"))
  viper_DbPort = upper(format("%s_%s",var.viper_prefix,"DbPort"))
  viper_DbHost = upper(format("%s_%s",var.viper_prefix,"DbHost"))
  viper_ListenHost = upper(format("%s_%s",var.viper_prefix,"ListenHost"))
  viper_ListenPort = upper(format("%s_%s",var.viper_prefix,"ListenPort"))
}

resource "aws_ecs_task_definition" "ecs" {
  family                   = var.app_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = <<EOF
[
  {
    "cpu": ${var.fargate_cpu},
    "image": "${aws_ecr_repository.ecs.repository_url}",
    "memory": ${var.fargate_memory},
    "name": "${var.app_name}",
    "networkMode": "awsvpc",
    "portMappings": [
      {
        "containerPort": ${var.app_port},
        "hostPort": ${var.app_port}
      }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-create-group": "true",
        "awslogs-group": "${var.app_name}",
        "awslogs-region": "${var.aws_region}",
        "awslogs-stream-prefix": "streaming"
      }
    },
    "command" : ["serve"],
    "environment": [
      {
        "name": "${local.viper_DbUser}",
        "value": "${var.app_name}"
      },
      {
        "name": "${local.viper_DbName}",
        "value": "${var.app_name}"
      },
      {
        "name": "${local.viper_DbPort}",
        "value": "${aws_db_instance.rds_db.port}"
      },
      {
        "name": "${local.viper_DbHost}",
        "value": "${aws_db_instance.rds_db.address}"
      },
      {
        "name": "${local.viper_ListenHost}",
        "value": "0.0.0.0"
      },
      {
        "name": "${local.viper_ListenPort}",
        "value": "${var.app_port}"
      }
    ],
    "secrets": [
      {
        "name": "${local.viper_DbPassword}",
        "valueFrom": "${aws_secretsmanager_secret_version.db_cred.arn}"
      }
    ] 
  }
]
EOF
  depends_on = [null_resource.push,aws_db_instance.rds_db]
}

resource "null_resource" "updatedb" {
  provisioner "local-exec" {
    command = <<EOF
$(echo aws ecs run-task --task-definition "$task_definition" --cluster "$cluster" --count 1 --launch-type FARGATE --network-configuration $netcfg --overrides $overrides)
EOF

    environment = {
      cluster         = aws_ecs_cluster.ecs.id
      task_definition = aws_ecs_task_definition.ecs.arn

      netcfg	      = format("awsvpcConfiguration={subnets=%#v,securityGroups=%#v}", aws_subnet.private.*.id, aws_security_group.ecs_sg.id)
      overrides       = format("containerOverrides=[{name=%#v,command=%#v}]", var.app_name, ["updatedb","-s"])
    }
  }
}

resource "aws_ecs_service" "ecs" {
  name            = "tf-ecs-service"
  cluster         = aws_ecs_cluster.ecs.id
  task_definition = aws_ecs_task_definition.ecs.arn
  desired_count   = var.app_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.ecs_sg.id]
    subnets         = aws_subnet.private.*.id
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.alb.id
    container_name   = var.app_name
    container_port   = var.app_port
  }

  depends_on = [null_resource.updatedb,aws_ecs_task_definition.ecs,aws_alb_listener.alb]
}
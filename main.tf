terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "3tier-vpc" }
}

# Subnets
resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.10.1.0/24"
  availability_zone = "ap-northeast-2a"
  tags = { Name = "public-a" }
}

resource "aws_subnet" "public_c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.10.2.0/24"
  availability_zone = "ap-northeast-2c"
  tags = { Name = "public-c" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.10.10.0/24"
  availability_zone = "ap-northeast-2a"
  tags = { Name = "private-a" }
}

resource "aws_subnet" "private_c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.10.20.0/24"
  availability_zone = "ap-northeast-2c"
  tags = { Name = "private-c" }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "3tier-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "public-rt" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}

# Security Groups
resource "aws_security_group" "alb_sg" {
  name   = "alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "alb-sg" }
}

resource "aws_security_group" "was_sg" {
  name   = "was-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "Tomcat from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "was-sg" }
}

resource "aws_security_group" "db_sg" {
  name   = "db-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from WAS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.was_sg.id]
  }

  ingress {
    description     = "Redis from WAS"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.was_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "db-sg" }
}

# ALB
resource "aws_lb" "web_alb" {
  name               = "3tier-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_c.id]
  tags = { Name = "3tier-alb" }
}

resource "aws_lb_target_group" "was_tg" {
  name     = "was-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/db.jsp"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = { Name = "was-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.was_tg.arn
  }
}

# EC2 Auto Scaling
resource "aws_launch_template" "was_lt" {
  name_prefix   = "was-"
  image_id      = "ami-0c55b159cbfafe1f0"
  instance_type = "t3.medium"

  vpc_security_group_ids = [aws_security_group.was_sg.id]

  user_data = base64encode(<<-USERDATA
    #!/bin/bash
    dnf install -y java-17-openjdk tomcat
    systemctl enable --now tomcat
  USERDATA
  )

  tags = { Name = "was-launch-template" }
}

resource "aws_autoscaling_group" "was_asg" {
  name                = "was-asg"
  desired_capacity    = 2
  min_size            = 2
  max_size            = 5
  target_group_arns   = [aws_lb_target_group.was_tg.arn]
  vpc_zone_identifier = [aws_subnet.private_a.id, aws_subnet.private_c.id]

  launch_template {
    id      = aws_launch_template.was_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "was-instance"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "scale-out"
  autoscaling_group_name = aws_autoscaling_group.was_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

# RDS PostgreSQL
resource "aws_db_subnet_group" "db_subnet" {
  name       = "db-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_c.id]
  tags       = { Name = "db-subnet-group" }
}

resource "aws_db_instance" "postgres" {
  identifier     = "appdb"
  engine         = "postgres"
  engine_version = "15"
  instance_class = "db.t3.medium"

  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "appdb"
  username = "appuser"
  password = "apppass"

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.db_subnet.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]

  skip_final_snapshot = true

  tags = { Name = "3tier-rds" }
}

# ElastiCache Redis
resource "aws_elasticache_subnet_group" "redis_subnet" {
  name       = "redis-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_c.id]
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "session-redis"
  description          = "Session store for WAS"
  node_type            = "cache.t3.micro"
  num_cache_clusters   = 2

  subnet_group_name  = aws_elasticache_subnet_group.redis_subnet.name
  security_group_ids = [aws_security_group.db_sg.id]

  engine_version = "7.0"
  port           = 6379

  tags = { Name = "3tier-redis" }
}

# Output
output "alb_dns" {
  value = aws_lb.web_alb.dns_name
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

# ---------------------------------------------------------------------------
# Networking: uses the DEFAULT VPC on purpose.
#   - No NAT Gateway (saves ~$33/month); tasks get a public IP so they can pull
#     from ECR and write logs. They are still only reachable through the ALB
#     because the task security group only allows the ALB security group.
#   - If you deleted your default VPC, create one:  aws ec2 create-default-vpc
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  # ALB needs subnets in at least 2 AZs; take the first two (sorted for stability).
  subnet_ids = slice(sort(data.aws_subnets.default.ids), 0, 2)
}

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "Public HTTP to the load balancer"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from anywhere"
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
}

resource "aws_security_group" "tasks" {
  name        = "${var.project_name}-tasks-sg"
  description = "Fargate tasks: only the ALB may connect"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "App port from ALB only"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Outbound for ECR pulls and CloudWatch Logs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

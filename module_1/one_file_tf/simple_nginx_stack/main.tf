# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# SPDX-License-Identifier: MIT-0

provider "aws" {
  region  = "us-east-1"
  profile = "dev"
}

terraform {
  backend "s3" {
  }
}

// Provision VPC Stack

data "aws_availability_zones" "all" {}

resource "aws_vpc" "vpc" {
  cidr_block = var.cidr_vpc

  enable_dns_hostnames = true
  enable_dns_support   = true
  instance_tenancy     = "default"

  tags = {
    Name = "${terraform.workspace}-nginx-vpc"
  }
}

resource "aws_subnet" "private_subnet" {
  vpc_id                  = aws_vpc.vpc.id
  count                   = var.subnet_count
  cidr_block              = cidrsubnet(var.cidr_vpc, var.cidr_network_bits, count.index)
  availability_zone       = element(data.aws_availability_zones.all.names, count.index)
  map_public_ip_on_launch = false

  tags = {
    Name = "private-${element(data.aws_availability_zones.all.names, count.index)}-subnet"
  }

  depends_on = [aws_vpc.vpc]
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.vpc.id
  count                   = var.subnet_count
  cidr_block              = cidrsubnet(var.cidr_vpc, var.cidr_network_bits, (count.index + length(split(",", lookup(var.azs, var.region)))))
  availability_zone       = element(data.aws_availability_zones.all.names, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "public-${element(data.aws_availability_zones.all.names, count.index)}-subnet"
  }

  depends_on = [aws_vpc.vpc]
}

resource "aws_internet_gateway" "internet_gateway" {
  tags = {
    Name = "nginx_igw"
  }
  vpc_id     = aws_vpc.vpc.id
  depends_on = [aws_vpc.vpc]
}

resource "aws_eip" "nat_gateway_eip" {
  count      = var.subnet_count
  vpc        = true
  depends_on = [aws_internet_gateway.internet_gateway]
}

resource "aws_nat_gateway" "nat_gateway" {
  count         = 2
  allocation_id = aws_eip.nat_gateway_eip.*.id[count.index]
  subnet_id     = aws_subnet.public_subnet.*.id[count.index]
  depends_on    = [aws_internet_gateway.internet_gateway, aws_subnet.public_subnet]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gateway.id
  }

  tags = {
    Name = "route_table_public"
  }
}

resource "aws_route_table" "private" {
  count  = var.subnet_count
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.nat_gateway.*.id, count.index)
  }

  tags = {
    Name = "route_table_private"
  }
}

resource "aws_route_table_association" "public_assoc" {
  count          = length(split(",", lookup(var.azs, var.region)))
  subnet_id      = element(aws_subnet.public_subnet.*.id, count.index)
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_assoc" {
  count          = 2
  subnet_id      = element(aws_subnet.private_subnet.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}

resource "aws_route53_zone" "main_zone" {
  name = "${var.environment}.${var.zone_name}.internal"

  vpc {
    vpc_id = aws_vpc.vpc.id
  }
}

resource "aws_security_group" "vpc_security_group" {
  name   = "aws-${terraform.workspace}-vpc-sg"
  vpc_id = aws_vpc.vpc.id
}

resource "aws_security_group_rule" "allow_ssh_internal" {
  type        = "ingress"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = [var.cidr_vpc]

  security_group_id = aws_security_group.vpc_security_group.id
}

resource "aws_security_group_rule" "egress_allow_all" {
  type        = "egress"
  from_port   = 0
  to_port     = 65535
  protocol    = "all"
  cidr_blocks = ["0.0.0.0/0"]

  security_group_id = aws_security_group.vpc_security_group.id
}

// END of VPC

// One Line terraform to provision LB + EC2 in ASG with LC and Nginx

resource "aws_security_group" "lc_sg" {
  name        = "${var.sg_name}-lc"
  description = "Managed by Terraform"
  vpc_id      = aws_vpc.vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "allow_internal_vpc" {
  type        = "ingress"
  from_port   = 80
  to_port     = 80
  protocol    = "TCP"
  cidr_blocks = ["10.5.0.0/16"]

  security_group_id = aws_security_group.lc_sg.id
}

resource "aws_launch_configuration" "my_sample_lc" {
  name_prefix     = "${var.lc_name}-"
  image_id        = data.aws_ami.amazon-linux-2.id
  instance_type   = var.instance_type
  user_data       = file("files/install_nginx.sh")
  key_name        = var.key_name
  security_groups = [aws_security_group.lc_sg.id]

  lifecycle {
    create_before_destroy = true
  }
}
# resource "aws_placement_group" "nginx" {
#   name = "nginx"
#   strategy="cluster"
# }
resource "aws_autoscaling_group" "my_sample_asg" {
  name                      = var.asg_name
  max_size                  = 6
  min_size                  = 2
  health_check_grace_period = 300
  health_check_type         = "ELB"
  desired_capacity          = 6
  force_delete              = false
  # placement_group = aws_placement_group.nginx.id
  launch_configuration = aws_launch_configuration.my_sample_lc.name // Reference from above
  vpc_zone_identifier  = aws_subnet.private_subnet.*.id
  tag {
    key                 = "Name"
    value               = "asg-nginx-test"
    propagate_at_launch = true
  }
  target_group_arns         = [
      aws_lb_target_group.nginx.arn
    ]
  lifecycle {
    create_before_destroy = true
  }
}
// LB security Group

resource "aws_security_group" "lb_sg" {
  name        = "${var.sg_name}-lb"
  description = "Managed by Terraform"
  vpc_id      = aws_vpc.vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "allow_all" {
  type        = "ingress"
  from_port   = 80
  to_port     = 80
  protocol    = "TCP"
  cidr_blocks = ["0.0.0.0/0"]

  security_group_id = aws_security_group.lb_sg.id
}

// Change away from Classic LoadBalancer for application

resource "aws_lb" "nginx_lb" {
  name               = var.lb_name
  subnets            = aws_subnet.public_subnet.*.id
  security_groups    = [aws_security_group.lb_sg.id]
  load_balancer_type = "application"
  enable_cross_zone_load_balancing = true
  idle_timeout       = 400
  internal           = false
}
resource "aws_lb_listener" "nginx_front" {
  load_balancer_arn = aws_lb.nginx_lb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nginx.arn
  }
}
resource "aws_lb_target_group" "nginx" {
  name     = "nginx-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.vpc.id
  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 2
    protocol = "HTTP"
    interval = 30
  }
  depends_on = [
    aws_lb.nginx_lb
  ]
  lifecycle {
    create_before_destroy = true
  }
}
resource "aws_autoscaling_attachment" "target" {
  autoscaling_group_name = aws_autoscaling_group.my_sample_asg.name
  alb_target_group_arn = aws_lb_target_group.nginx.arn
}

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# SPDX-License-Identifier: MIT-0

output "lb_dns_name" {
  value = aws_lb.nginx_lb.dns_name
}

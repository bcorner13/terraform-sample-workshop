#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# SPDX-License-Identifier: MIT-0

sudo yum update
sudo amazon-linux-extras install nginx1.12
sudo service nginx start
chkconfig nginx on
cat >/usr/share/nginx/html/test.html <<EOF
<h1> Blank Page </h1>
This is a blank test page.
EOF

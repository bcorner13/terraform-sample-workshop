#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# SPDX-License-Identifier: MIT-0

echo "Press enter 3 times"

ssh-keygen

aws ec2 import-key-pair --profile "dev" --key-name "nginx-demo-key" --public-key-material fileb://./id_rsa.pub

echo "Key imported!"


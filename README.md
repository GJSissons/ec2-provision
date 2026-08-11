# ec2-provision

While experimenting with open-source LLMs on AWS, I found myself repeatedly provisioning EC2 instances by hand. I wrote this script to automate the process of launching an EC2 instance using my AWS credentials while allowing me to choose the AWS region, Availability Zone (or automatically search multiple AZs), and instance type.  

GPU-backed EC2 instances are often capacity constrained. Although an instance type may be supported in a particular Availability Zone, AWS may return an InsufficientInstanceCapacity error if no physical GPU capacity is currently available. This script can automatically search multiple Availability Zones within a region to improve the chances of successfully launching an instance.

A common problem when launching GPU instances, is that they are under high-demand, and the desired instance type is often unavailable in a particular availability zone (AZ). For example, ideally I'd like to use a g6.xlarge instance to run my LLM , however I may find that only more expensive g6.12xlarge or g6.24xlarge instances are available. I'd like to start with the least expensive instance type and have the script explore all availability zones in a region.

This script performs the following steps:

* Validates the AWS CLI and other required tools.
* Authenticates using your configured AWS credentials.
* Allows the AWS Region to be selected (default ca-central-1).
* Supports automatic Availability Zone selection to improve the chances of finding GPU capacity.
* Allows any EC2 instance type to be specified.
* Creates or reuses EC2 SSH key pairs.
* Creates or reuses a security group with SSH access restricted to the current public IP.
* Uses the latest Amazon Linux 2023 AMI.
* Waits for the instance to become available and prints the SSH command.

An example of running the script is provided below:

```bash
gord@localhost:~/aws-util$ ./ec2-provision.sh

============================================================
 EC2 Instance Provisioning
============================================================

Checking required commands...
Required commands are available.

AWS Region [ca-central-1]:
Availability Zone [auto]:
EC2 Instance Type [t3.micro]: g6.xlarge

Configuration:
------------------------------------------------------------
AWS Profile:       default
AWS Region:        ca-central-1
Availability Zone: auto
Instance Type:     g6.xlarge
Instance Name:     my-linux-vm
SSH Key:           my-linux-vm-ca-central-1-key
------------------------------------------------------------

Continue? [Y/n]: Y

Checking AWS credentials...
AWS authentication successful.
AWS Account: **************

Finding the default VPC...
Using VPC: vpc-**************

Checking whether g6.xlarge is offered in ca-central-1...
g6.xlarge is offered in ca-central-1.

Availability Zone selection: automatic
Finding default subnets across ca-central-1...

Finding Availability Zones that offer g6.xlarge...

g6.xlarge is offered in:
  ca-central-1a
  ca-central-1d
  ca-central-1b

Evaluating candidate subnets...
  ca-central-1d (subnet-3071436c) - candidate
  ca-central-1a (subnet-034b8d77ba93d4d54) - candidate
  ca-central-1b (subnet-09e131c72520e9eb2) - candidate

Determining your current public IP address...
Current public IP: 99.249.106.64
SSH access will be restricted to: 99.249.106.64/32

Checking SSH key pair...
Creating AWS key pair: my-linux-vm-ca-central-1-key
Private key saved to:
    /home/gord/.ssh/my-linux-vm-ca-central-1-key.pem

Checking security group...
Using existing security group: sg-***************

Checking SSH access rule for 99.249.106.64/32...
SSH access already authorized.
Existing rule: sgr-***************

Finding latest Amazon Linux 2023 AMI...
Using AMI: ami-****************

============================================================
 Ready to launch
============================================================

AWS Account:        ************
Region:             ca-central-1
Availability Zone:  auto
Instance Type:      g6.xlarge
Instance Name:      my-linux-vm
AMI:                ami-***************
VPC:                vpc-***************
Security Group:     sg-****************
SSH Source:         **.**.**.**/32
SSH Key:            my-linux-vm-ca-central-1-key
Root Disk:          20 GB gp3

Candidate AZ count: 3

Launch this instance? [Y/n]: Y

Attempting EC2 launch...

------------------------------------------------------------
Trying:
  Instance: g6.xlarge
  AZ:       ca-central-1b
  Subnet:   subnet-**************
------------------------------------------------------------

SUCCESS: Instance launched in ca-central-1b.
Instance ID: i-***************

Waiting for instance to enter the running state...
Instance is running.

Waiting for AWS instance status checks...
AWS status checks passed.

============================================================
 EC2 instance is ready
============================================================

Instance Name:       my-linux-vm
Instance ID:         i-****************
Instance Type:       g6.xlarge

Region:              ca-central-1
Availability Zone:   ca-central-1b
Subnet:              subnet-******************

Public IP:           3.98.145.168
Private IP:          172.31.9.215
Public DNS:          ec2-**-**-**-**.ca-central-1.compute.amazonaws.com
```

## Prerequisites

Before running the script you should:

- Install the AWS CLI v2.
- Configure your AWS credentials using:

```bash
aws configure

While this repository and README were created and curated by hand, I used the OpenAI GPT-5.5 Instant model to help write and debug the ec2-provision.sh script. 
 

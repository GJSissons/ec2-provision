# ec2-provision
A general script to provision and manage EC2 instances.

While experimenting with running various open-source LLMs, I found it useful to have a generic provisioning script that would use my AWS credentials to automatically launch a user-defined AWS instance type into my chosen region and availability zone.  

A common problem when launching GPU instances, is that the desired instance type is often unavailable in a particular availability zone (AZ)

To address this shortcoming, this script performs the following steps:

* It validates that pre-requisite commands such as the AWS CLI are available
* It asks users to enter a preferred AWS region (My script defaults to the AWS Canada region, but you can over-rise this)
* The script allows "auto" to be entered as the Availability Zone which will have the script search different AZ's for avalability of the desired instance type
* Finally, users can select the instance type required to run their desired model - i.e., g6.xlarge

An example of running the script is provided below:

```bash
gord@DESKTOP-95FCMJP:~/aws-util$ ./ec2-provision.sh

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
AWS Account: 699757609476

Finding the default VPC...
Using VPC: vpc-0a9e7992ea2730f21

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
Using existing security group: sg-01741c83abcedc736

Checking SSH access rule for 99.249.106.64/32...
SSH access already authorized.
Existing rule: sgr-0997211b560ed90d3

Finding latest Amazon Linux 2023 AMI...
Using AMI: ami-06a19372fab295de9

============================================================
 Ready to launch
============================================================

AWS Account:        699757609476
Region:             ca-central-1
Availability Zone:  auto
Instance Type:      g6.xlarge
Instance Name:      my-linux-vm
AMI:                ami-06a19372fab295de9
VPC:                vpc-0a9e7992ea2730f21
Security Group:     sg-01741c83abcedc736
SSH Source:         99.249.106.64/32
SSH Key:            my-linux-vm-ca-central-1-key
Root Disk:          20 GB gp3

Candidate AZ count: 3

Launch this instance? [Y/n]: Y

Attempting EC2 launch...

------------------------------------------------------------
Trying:
  Instance: g6.xlarge
  AZ:       ca-central-1b
  Subnet:   subnet-09e131c72520e9eb2
------------------------------------------------------------

SUCCESS: Instance launched in ca-central-1b.
Instance ID: i-0fdd4d6eef9403871

Waiting for instance to enter the running state...
Instance is running.

Waiting for AWS instance status checks...
AWS status checks passed.

============================================================
 EC2 instance is ready
============================================================

Instance Name:       my-linux-vm
Instance ID:         i-0fdd4d6eef9403871
Instance Type:       g6.xlarge

Region:              ca-central-1
Availability Zone:   ca-central-1b
Subnet:              subnet-09e131c72520e9eb2

Public IP:           3.98.145.168
Private IP:          172.31.9.215
Public DNS:          ec2-3-98-145-168.ca-central-1.compute.amazonaws.com
```

 

# ec2-provision
A general script to provision and manage EC2 instances.

While experimenting with running various open-source LLMs, I found it useful to have a generic provisioning script that would use my AWS credentials to automatically launch a user-defined AWS instance type into my chosen region and availability zone.  

A common problem when launching GPU instances, is that the desired instance type is often unavailable in a particular availability zone (AZ)

To address this shortcoming, this script performs the following steps:

* It validates that pre-requisite commands such as the AWS CLI are available
* It asks users to enter a preferred AWS region (My script defaults to the AWS Canada region, but you can over-rise this)
* The script allows "auto" to be entered as the Availability Zone which will have the script search different AZ's for avalability of the desired instance type
* Finally, users can select the instance type required to run their desired model - i.e., g6.xlarge

 

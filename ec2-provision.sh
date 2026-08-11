#!/usr/bin/env bash

# ============================================================================
# ec2-provision.sh
#
# Provision an Amazon Linux 2023 EC2 instance using the AWS CLI.
#
# FEATURES
# --------
# - Selectable AWS region
# - Availability Zone defaults to "auto"
# - In auto mode, tries all compatible default subnets/AZs
# - Selectable EC2 instance type
# - Region-specific EC2 SSH key pairs
# - Reuses existing security groups
# - Avoids duplicate SSH ingress rules
# - Restricts SSH access to your current public IP
# - Uses the latest Amazon Linux 2023 x86-64 AMI
# - Handles InsufficientInstanceCapacity by trying another AZ
# - Waits for EC2 health checks
# - Prints SSH, stop, start, and terminate commands
#
# REQUIREMENTS
# ------------
# - Bash
# - AWS CLI v2
# - AWS credentials configured
# - curl
# - ssh
# - A default VPC in the selected AWS region
#
# DEFAULTS
# --------
# AWS profile:       default
# AWS region:        ca-central-1
# Availability Zone: auto
# Instance type:     t3.micro
# Instance name:     my-linux-vm
#
# ============================================================================

set -Eeuo pipefail


# ============================================================================
# DEFAULT CONFIGURATION
# ============================================================================

DEFAULT_REGION="ca-central-1"
DEFAULT_AZ="auto"
DEFAULT_INSTANCE_TYPE="t3.micro"

AWS_PROFILE="${AWS_PROFILE:-default}"
INSTANCE_NAME="${INSTANCE_NAME:-my-linux-vm}"

SSH_USER="ec2-user"

ROOT_VOLUME_SIZE="${ROOT_VOLUME_SIZE:-20}"


# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

die()
{
    echo
    echo "ERROR: $*" >&2
    exit 1
}


separator()
{
    echo "------------------------------------------------------------"
}


# ============================================================================
# CHECK LOCAL PREREQUISITES
# ============================================================================

echo
echo "============================================================"
echo " EC2 Instance Provisioning"
echo "============================================================"
echo
echo "Checking required commands..."

for COMMAND in aws curl ssh; do
    if ! command -v "$COMMAND" >/dev/null 2>&1; then
        die "'$COMMAND' is required but was not found."
    fi
done

echo "Required commands are available."


# ============================================================================
# PROMPT FOR REGION
# ============================================================================

echo
read -rp "AWS Region [$DEFAULT_REGION]: " AWS_REGION
AWS_REGION="${AWS_REGION:-$DEFAULT_REGION}"


# ============================================================================
# PROMPT FOR AVAILABILITY ZONE
#
# "auto" allows this script to try all compatible Availability Zones.
#
# You can instead enter something explicit such as:
#
#   ca-central-1a
#
# If you specify an AZ manually, only that AZ will be attempted.
# ============================================================================

read -rp "Availability Zone [$DEFAULT_AZ]: " AVAILABILITY_ZONE
AVAILABILITY_ZONE="${AVAILABILITY_ZONE:-$DEFAULT_AZ}"


# ============================================================================
# PROMPT FOR INSTANCE TYPE
# ============================================================================

read -rp "EC2 Instance Type [$DEFAULT_INSTANCE_TYPE]: " INSTANCE_TYPE
INSTANCE_TYPE="${INSTANCE_TYPE:-$DEFAULT_INSTANCE_TYPE}"


# ============================================================================
# REGION-SPECIFIC RESOURCES
#
# EC2 key pairs are regional AWS resources. Therefore each AWS region gets
# its own key name and local private-key filename.
#
# Examples:
#
#   ca-central-1:
#       my-linux-vm-ca-central-1-key
#
#   us-east-1:
#       my-linux-vm-us-east-1-key
# ============================================================================

KEY_NAME="${INSTANCE_NAME}-${AWS_REGION}-key"
KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"

SECURITY_GROUP_NAME="${INSTANCE_NAME}-ssh"


# ============================================================================
# CREATE AWS CLI COMMAND ARRAY
#
# Using an array makes every AWS command consistently use the selected
# profile and region.
# ============================================================================

AWS=(
    aws
    --profile "$AWS_PROFILE"
    --region "$AWS_REGION"
)


# ============================================================================
# SHOW CONFIGURATION
# ============================================================================

echo
echo "Configuration:"
separator
echo "AWS Profile:       $AWS_PROFILE"
echo "AWS Region:        $AWS_REGION"
echo "Availability Zone: $AVAILABILITY_ZONE"
echo "Instance Type:     $INSTANCE_TYPE"
echo "Instance Name:     $INSTANCE_NAME"
echo "SSH Key:           $KEY_NAME"
separator
echo

read -rp "Continue? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Provisioning cancelled."
    exit 0
fi


# ============================================================================
# VERIFY AWS CREDENTIALS
# ============================================================================

echo
echo "Checking AWS credentials..."

if ! "${AWS[@]}" sts get-caller-identity >/dev/null; then
    die "Unable to authenticate with AWS profile '$AWS_PROFILE'."
fi

ACCOUNT_ID=$(
    "${AWS[@]}" sts get-caller-identity \
        --query "Account" \
        --output text
)

echo "AWS authentication successful."
echo "AWS Account: $ACCOUNT_ID"


# ============================================================================
# FIND DEFAULT VPC
# ============================================================================

echo
echo "Finding the default VPC..."

VPC_ID=$(
    "${AWS[@]}" ec2 describe-vpcs \
        --filters "Name=is-default,Values=true" \
        --query "Vpcs[0].VpcId" \
        --output text
)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    die "No default VPC exists in region '$AWS_REGION'."
fi

echo "Using VPC: $VPC_ID"


# ============================================================================
# VERIFY INSTANCE TYPE EXISTS IN THE REGION
# ============================================================================

echo
echo "Checking whether $INSTANCE_TYPE is offered in $AWS_REGION..."

REGION_INSTANCE_COUNT=$(
    "${AWS[@]}" ec2 describe-instance-type-offerings \
        --location-type region \
        --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
        --query "length(InstanceTypeOfferings)" \
        --output text
)

if [[ "$REGION_INSTANCE_COUNT" == "0" ]]; then
    die "Instance type '$INSTANCE_TYPE' is not offered in region '$AWS_REGION'."
fi

echo "$INSTANCE_TYPE is offered in $AWS_REGION."


# ============================================================================
# BUILD LIST OF CANDIDATE SUBNETS
#
# AWS requires a subnet when we explicitly control the VPC/security group.
# A subnet belongs to one Availability Zone, so selecting a subnet also
# selects the Availability Zone.
#
# AUTO MODE
# ---------
# Find all default subnets in the VPC.
#
# MANUAL MODE
# -----------
# Find only the default subnet belonging to the user's requested AZ.
# ============================================================================

echo

if [[ "$AVAILABILITY_ZONE" == "auto" ]]; then

    echo "Availability Zone selection: automatic"
    echo "Finding default subnets across $AWS_REGION..."

    mapfile -t ALL_SUBNET_IDS < <(
        "${AWS[@]}" ec2 describe-subnets \
            --filters \
                "Name=vpc-id,Values=$VPC_ID" \
                "Name=default-for-az,Values=true" \
            --query "Subnets[].SubnetId" \
            --output text |
        tr '\t' '\n' |
        sed '/^$/d'
    )

else

    echo "Availability Zone selection: $AVAILABILITY_ZONE"
    echo "Checking selected Availability Zone..."

    AZ_STATE=$(
        "${AWS[@]}" ec2 describe-availability-zones \
            --zone-names "$AVAILABILITY_ZONE" \
            --query "AvailabilityZones[0].State" \
            --output text 2>/dev/null || true
    )

    if [[ "$AZ_STATE" != "available" ]]; then
        die "Availability Zone '$AVAILABILITY_ZONE' is not available in '$AWS_REGION'."
    fi

    SELECTED_SUBNET=$(
        "${AWS[@]}" ec2 describe-subnets \
            --filters \
                "Name=vpc-id,Values=$VPC_ID" \
                "Name=availability-zone,Values=$AVAILABILITY_ZONE" \
                "Name=default-for-az,Values=true" \
            --query "Subnets[0].SubnetId" \
            --output text
    )

    if [[ -z "$SELECTED_SUBNET" || "$SELECTED_SUBNET" == "None" ]]; then
        die "No default subnet exists in '$AVAILABILITY_ZONE'."
    fi

    ALL_SUBNET_IDS=("$SELECTED_SUBNET")
fi


if [[ ${#ALL_SUBNET_IDS[@]} -eq 0 ]]; then
    die "No usable default subnets were found."
fi


# ============================================================================
# DETERMINE WHICH AZs OFFER THE REQUESTED INSTANCE TYPE
#
# Important:
#
# describe-instance-type-offerings tells us whether an instance type is
# SUPPORTED in an AZ. It does NOT guarantee spare capacity at this moment.
# ============================================================================

echo
echo "Finding Availability Zones that offer $INSTANCE_TYPE..."

mapfile -t OFFERED_AZS < <(
    "${AWS[@]}" ec2 describe-instance-type-offerings \
        --location-type availability-zone \
        --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
        --query "InstanceTypeOfferings[].Location" \
        --output text |
    tr '\t' '\n' |
    sed '/^$/d'
)

if [[ ${#OFFERED_AZS[@]} -eq 0 ]]; then
    die "No Availability Zones in '$AWS_REGION' offer '$INSTANCE_TYPE'."
fi

echo
echo "$INSTANCE_TYPE is offered in:"
printf '  %s\n' "${OFFERED_AZS[@]}"


# ============================================================================
# BUILD FINAL CANDIDATE SUBNET LIST
#
# We only retain subnets whose Availability Zone offers the instance type.
# ============================================================================

CANDIDATE_SUBNETS=()

echo
echo "Evaluating candidate subnets..."

for SUBNET_ID in "${ALL_SUBNET_IDS[@]}"; do

    AZ=$(
        "${AWS[@]}" ec2 describe-subnets \
            --subnet-ids "$SUBNET_ID" \
            --query "Subnets[0].AvailabilityZone" \
            --output text
    )

    AZ_SUPPORTED=false

    for OFFERED_AZ in "${OFFERED_AZS[@]}"; do
        if [[ "$AZ" == "$OFFERED_AZ" ]]; then
            AZ_SUPPORTED=true
            break
        fi
    done

    if [[ "$AZ_SUPPORTED" == true ]]; then
        echo "  $AZ ($SUBNET_ID) - candidate"
        CANDIDATE_SUBNETS+=("$SUBNET_ID")
    else
        echo "  $AZ ($SUBNET_ID) - $INSTANCE_TYPE not offered"
    fi
done


if [[ ${#CANDIDATE_SUBNETS[@]} -eq 0 ]]; then
    die "No default subnet corresponds to an AZ offering '$INSTANCE_TYPE'."
fi


# ============================================================================
# OPTIONAL: RANDOMIZE AZ ORDER
#
# Capacity can vary frequently. Randomizing avoids always attempting the
# alphabetically/return-order first AZ.
#
# shuf is normally supplied by Ubuntu's coreutils package.
# ============================================================================

if command -v shuf >/dev/null 2>&1; then

    mapfile -t CANDIDATE_SUBNETS < <(
        printf '%s\n' "${CANDIDATE_SUBNETS[@]}" | shuf
    )

fi


# ============================================================================
# DETERMINE CURRENT PUBLIC IP
# ============================================================================

echo
echo "Determining your current public IP address..."

PUBLIC_IP=$(
    curl \
        --fail \
        --silent \
        --show-error \
        https://checkip.amazonaws.com
)

PUBLIC_IP="${PUBLIC_IP//$'\n'/}"

if [[ ! "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Unable to determine a valid public IPv4 address."
fi

SSH_CIDR="${PUBLIC_IP}/32"

echo "Current public IP: $PUBLIC_IP"
echo "SSH access will be restricted to: $SSH_CIDR"


# ============================================================================
# CREATE OR REUSE EC2 KEY PAIR
# ============================================================================

mkdir -p "$(dirname "$KEY_FILE")"

echo
echo "Checking SSH key pair..."

if "${AWS[@]}" ec2 describe-key-pairs \
    --key-names "$KEY_NAME" >/dev/null 2>&1
then

    if [[ ! -f "$KEY_FILE" ]]; then

        echo
        echo "AWS key pair exists:"
        echo "    $KEY_NAME"
        echo
        echo "but the corresponding private key is missing:"
        echo "    $KEY_FILE"
        echo
        echo "AWS cannot provide the private key again after creation."

        exit 1
    fi

    chmod 600 "$KEY_FILE"

    echo "Using existing AWS key pair: $KEY_NAME"

else

    if [[ -e "$KEY_FILE" ]]; then

        echo
        echo "A local key file already exists:"
        echo "    $KEY_FILE"
        echo
        echo "but AWS does not contain:"
        echo "    $KEY_NAME"
        echo
        echo "The script will not overwrite the existing private key."

        exit 1
    fi

    echo "Creating AWS key pair: $KEY_NAME"

    "${AWS[@]}" ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --key-type ed25519 \
        --query "KeyMaterial" \
        --output text > "$KEY_FILE"

    chmod 600 "$KEY_FILE"

    echo "Private key saved to:"
    echo "    $KEY_FILE"
fi


# ============================================================================
# CREATE OR REUSE SECURITY GROUP
# ============================================================================

echo
echo "Checking security group..."

SECURITY_GROUP_ID=$(
    "${AWS[@]}" ec2 describe-security-groups \
        --filters \
            "Name=group-name,Values=$SECURITY_GROUP_NAME" \
            "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[0].GroupId" \
        --output text
)

if [[ -z "$SECURITY_GROUP_ID" || "$SECURITY_GROUP_ID" == "None" ]]; then

    echo "Creating security group: $SECURITY_GROUP_NAME"

    SECURITY_GROUP_ID=$(
        "${AWS[@]}" ec2 create-security-group \
            --group-name "$SECURITY_GROUP_NAME" \
            --description "SSH access for $INSTANCE_NAME" \
            --vpc-id "$VPC_ID" \
            --query "GroupId" \
            --output text
    )

    echo "Created security group: $SECURITY_GROUP_ID"

else

    echo "Using existing security group: $SECURITY_GROUP_ID"

fi


# ============================================================================
# ADD SSH SECURITY GROUP RULE IF NECESSARY
#
# describe-security-group-rules is used instead of parsing the nested
# IpPermissions returned by describe-security-groups.
# ============================================================================

echo
echo "Checking SSH access rule for $SSH_CIDR..."

RULE_ID=$(
    "${AWS[@]}" ec2 describe-security-group-rules \
        --filters "Name=group-id,Values=$SECURITY_GROUP_ID" \
        --query "SecurityGroupRules[?IsEgress==\`false\` && IpProtocol=='tcp' && FromPort==\`22\` && ToPort==\`22\` && CidrIpv4=='$SSH_CIDR'].SecurityGroupRuleId | [0]" \
        --output text
)

if [[ -z "$RULE_ID" || "$RULE_ID" == "None" ]]; then

    echo "Authorizing SSH from $SSH_CIDR..."

    "${AWS[@]}" ec2 authorize-security-group-ingress \
        --group-id "$SECURITY_GROUP_ID" \
        --protocol tcp \
        --port 22 \
        --cidr "$SSH_CIDR" \
        >/dev/null

    echo "SSH rule created."

else

    echo "SSH access already authorized."
    echo "Existing rule: $RULE_ID"

fi


# ============================================================================
# GET LATEST AMAZON LINUX 2023 AMI
#
# This is the latest x86-64 Amazon Linux 2023 AMI published through AWS
# Systems Manager Parameter Store.
# ============================================================================

AMI_PARAMETER="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

echo
echo "Finding latest Amazon Linux 2023 AMI..."

AMI_ID=$(
    "${AWS[@]}" ssm get-parameter \
        --name "$AMI_PARAMETER" \
        --query "Parameter.Value" \
        --output text
)

if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
    die "Unable to determine the current Amazon Linux 2023 AMI."
fi

echo "Using AMI: $AMI_ID"


# ============================================================================
# FINAL PRE-LAUNCH SUMMARY
# ============================================================================

echo
echo "============================================================"
echo " Ready to launch"
echo "============================================================"
echo
echo "AWS Account:        $ACCOUNT_ID"
echo "Region:             $AWS_REGION"
echo "Availability Zone:  $AVAILABILITY_ZONE"
echo "Instance Type:      $INSTANCE_TYPE"
echo "Instance Name:      $INSTANCE_NAME"
echo "AMI:                $AMI_ID"
echo "VPC:                $VPC_ID"
echo "Security Group:     $SECURITY_GROUP_ID"
echo "SSH Source:         $SSH_CIDR"
echo "SSH Key:            $KEY_NAME"
echo "Root Disk:          ${ROOT_VOLUME_SIZE} GB gp3"
echo
echo "Candidate AZ count: ${#CANDIDATE_SUBNETS[@]}"
echo

read -rp "Launch this instance? [Y/n]: " LAUNCH_CONFIRM
LAUNCH_CONFIRM="${LAUNCH_CONFIRM:-Y}"

if [[ ! "$LAUNCH_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Instance launch cancelled."
    exit 0
fi


# ============================================================================
# TRY TO LAUNCH IN EACH CANDIDATE AZ
#
# If AWS returns InsufficientInstanceCapacity, move on to the next subnet/AZ.
#
# Other errors are considered real configuration errors, so the script stops
# rather than hiding them.
# ============================================================================

INSTANCE_ID=""
SUCCESSFUL_AZ=""
SUCCESSFUL_SUBNET=""

echo
echo "Attempting EC2 launch..."


for SUBNET_ID in "${CANDIDATE_SUBNETS[@]}"; do

    AZ=$(
        "${AWS[@]}" ec2 describe-subnets \
            --subnet-ids "$SUBNET_ID" \
            --query "Subnets[0].AvailabilityZone" \
            --output text
    )

    echo
    separator
    echo "Trying:"
    echo "  Instance: $INSTANCE_TYPE"
    echo "  AZ:       $AZ"
    echo "  Subnet:   $SUBNET_ID"
    separator

    set +e

    LAUNCH_OUTPUT=$(
        "${AWS[@]}" ec2 run-instances \
            --image-id "$AMI_ID" \
            --instance-type "$INSTANCE_TYPE" \
            --key-name "$KEY_NAME" \
            --subnet-id "$SUBNET_ID" \
            --security-group-ids "$SECURITY_GROUP_ID" \
            --associate-public-ip-address \
            --block-device-mappings \
                "DeviceName=/dev/xvda,Ebs={VolumeSize=$ROOT_VOLUME_SIZE,VolumeType=gp3,DeleteOnTermination=true}" \
            --tag-specifications \
                "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
                "ResourceType=volume,Tags=[{Key=Name,Value=${INSTANCE_NAME}-root}]" \
            --metadata-options \
                "HttpTokens=required,HttpEndpoint=enabled" \
            --count 1 \
            --query "Instances[0].InstanceId" \
            --output text 2>&1
    )

    LAUNCH_RC=$?

    set -e


    # ------------------------------------------------------------------------
    # SUCCESS
    # ------------------------------------------------------------------------

    if [[ $LAUNCH_RC -eq 0 ]]; then

        INSTANCE_ID="$LAUNCH_OUTPUT"
        SUCCESSFUL_AZ="$AZ"
        SUCCESSFUL_SUBNET="$SUBNET_ID"

        echo
        echo "SUCCESS: Instance launched in $AZ."
        echo "Instance ID: $INSTANCE_ID"

        break
    fi


    # ------------------------------------------------------------------------
    # CAPACITY FAILURE
    #
    # This is recoverable when Availability Zone selection is "auto".
    # ------------------------------------------------------------------------

    if grep -q "InsufficientInstanceCapacity" <<< "$LAUNCH_OUTPUT"; then

        echo
        echo "No $INSTANCE_TYPE capacity currently available in $AZ."

        if [[ "$AVAILABILITY_ZONE" == "auto" ]]; then

            echo "Trying another Availability Zone..."
            continue

        else

            echo
            echo "You selected a specific Availability Zone."
            echo "No other AZ will be attempted."

            exit 1
        fi

    fi


    # ------------------------------------------------------------------------
    # OTHER LAUNCH FAILURE
    #
    # Don't conceal problems such as IAM permissions, quota failures,
    # invalid AMIs, bad security groups, etc.
    # ------------------------------------------------------------------------

    echo
    echo "EC2 launch failed for a reason other than capacity:"
    echo
    echo "$LAUNCH_OUTPUT"

    exit "$LAUNCH_RC"

done


# ============================================================================
# HANDLE FAILURE ACROSS ALL AZs
# ============================================================================

if [[ -z "$INSTANCE_ID" ]]; then

    echo
    echo "============================================================"
    echo " Unable to launch instance"
    echo "============================================================"
    echo
    echo "AWS currently has insufficient capacity for:"
    echo
    echo "    Instance Type: $INSTANCE_TYPE"
    echo "    Region:        $AWS_REGION"
    echo
    echo "Every compatible Availability Zone was attempted."
    echo
    echo "No EC2 instance was created."
    echo
    echo "Possible next steps:"
    echo "  - Try again later."
    echo "  - Select another instance type."
    echo "  - Select another AWS region."
    echo

    exit 1
fi


# ============================================================================
# WAIT FOR INSTANCE TO RUN
# ============================================================================

echo
echo "Waiting for instance to enter the running state..."

"${AWS[@]}" ec2 wait instance-running \
    --instance-ids "$INSTANCE_ID"

echo "Instance is running."


# ============================================================================
# WAIT FOR AWS HEALTH CHECKS
# ============================================================================

echo
echo "Waiting for AWS instance status checks..."

"${AWS[@]}" ec2 wait instance-status-ok \
    --instance-ids "$INSTANCE_ID"

echo "AWS status checks passed."


# ============================================================================
# RETRIEVE INSTANCE NETWORK INFORMATION
# ============================================================================

PUBLIC_DNS=$(
    "${AWS[@]}" ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].PublicDnsName" \
        --output text
)

PUBLIC_ADDRESS=$(
    "${AWS[@]}" ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].PublicIpAddress" \
        --output text
)

PRIVATE_ADDRESS=$(
    "${AWS[@]}" ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].PrivateIpAddress" \
        --output text
)


# ============================================================================
# CHOOSE SSH DESTINATION
# ============================================================================

SSH_HOST="$PUBLIC_DNS"

if [[ -z "$SSH_HOST" || "$SSH_HOST" == "None" ]]; then
    SSH_HOST="$PUBLIC_ADDRESS"
fi


# ============================================================================
# FINISHED
# ============================================================================

echo
echo "============================================================"
echo " EC2 instance is ready"
echo "============================================================"
echo
echo "Instance Name:       $INSTANCE_NAME"
echo "Instance ID:         $INSTANCE_ID"
echo "Instance Type:       $INSTANCE_TYPE"
echo
echo "Region:              $AWS_REGION"
echo "Availability Zone:   $SUCCESSFUL_AZ"
echo "Subnet:              $SUCCESSFUL_SUBNET"
echo
echo "Public IP:           $PUBLIC_ADDRESS"
echo "Private IP:          $PRIVATE_ADDRESS"
echo "Public DNS:          $PUBLIC_DNS"
echo
echo "Private Key:"
echo "    $KEY_FILE"

echo
separator
echo "SSH command:"
separator
echo
echo "ssh -i \"$KEY_FILE\" ${SSH_USER}@${SSH_HOST}"

echo
separator
echo "Stop instance:"
separator
echo
echo "aws --profile \"$AWS_PROFILE\" --region \"$AWS_REGION\" \\"
echo "    ec2 stop-instances --instance-ids \"$INSTANCE_ID\""

echo
separator
echo "Start instance:"
separator
echo
echo "aws --profile \"$AWS_PROFILE\" --region \"$AWS_REGION\" \\"
echo "    ec2 start-instances --instance-ids \"$INSTANCE_ID\""

echo
separator
echo "TERMINATE instance:"
separator
echo
echo "aws --profile \"$AWS_PROFILE\" --region \"$AWS_REGION\" \\"
echo "    ec2 terminate-instances --instance-ids \"$INSTANCE_ID\""

echo
echo "============================================================"


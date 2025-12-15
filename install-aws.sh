#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Script Name: install-aws.sh
# Description: Launches EC2 instance and installs Appmotel on it
# Usage: bash install-aws.sh [instance-type] [region]
# -----------------------------------------------------------------------------

set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_INSTANCE_TYPE="t4g.micro"  # ARM-based instance
readonly DEFAULT_REGION="us-west-2"
readonly DEFAULT_AMI_OWNER="137112412989"  # Amazon
readonly KEY_NAME="appmotel-key"
readonly SECURITY_GROUP_NAME="appmotel-sg"
readonly INSTANCE_NAME="appmotel-server"
readonly SSH_USER="ec2-user"  # Default user for Amazon Linux 2023
readonly IAM_ROLE_NAME="appmotel-route53-role"
readonly IAM_INSTANCE_PROFILE="appmotel-instance-profile"

# -----------------------------------------------------------------------------
# Global Variables (set via command line options)
# -----------------------------------------------------------------------------
AWS_PROFILE_EC2=""
AWS_PROFILE_IAM=""
REQUESTED_HOSTED_ZONE=""
FORCE_OVERWRITE=0

# -----------------------------------------------------------------------------
# AWS CLI Profile Wrapper Functions
# -----------------------------------------------------------------------------
aws_ec2() {
  if [[ -n "${AWS_PROFILE_EC2}" ]]; then
    aws ec2 --profile="${AWS_PROFILE_EC2}" "$@"
  else
    aws ec2 "$@"
  fi
}

aws_iam() {
  if [[ -n "${AWS_PROFILE_IAM}" ]]; then
    aws iam --profile="${AWS_PROFILE_IAM}" "$@"
  else
    aws iam "$@"
  fi
}

aws_route53() {
  if [[ -n "${AWS_PROFILE_IAM}" ]]; then
    aws route53 --profile="${AWS_PROFILE_IAM}" "$@"
  else
    aws route53 "$@"
  fi
}

aws_sts() {
  if [[ -n "${AWS_PROFILE_EC2}" ]]; then
    aws sts --profile="${AWS_PROFILE_EC2}" "$@"
  else
    aws sts "$@"
  fi
}

# -----------------------------------------------------------------------------
# Function: log_msg
# Description: Prints messages with timestamp
# -----------------------------------------------------------------------------
log_msg() {
  local level="$1"
  local msg="$2"
  printf "[%(%Y-%m-%d %H:%M:%S)T] [%s] %s\n" -1 "${level}" "${msg}" >&2
}

# -----------------------------------------------------------------------------
# Function: die
# Description: Prints error message and exits
# -----------------------------------------------------------------------------
die() {
  log_msg "ERROR" "$1"
  exit 1
}

# -----------------------------------------------------------------------------
# Function: die_iam_permission_error
# Description: Prints IAM permission error with helpful guidance
# Arguments:
#   $1 - IAM action that failed
# -----------------------------------------------------------------------------
die_iam_permission_error() {
  local iam_action="$1"
  log_msg "ERROR" "Access Denied: IAM permission required"
  log_msg "ERROR" ""
  log_msg "ERROR" "The current AWS credentials do not have permission for: ${iam_action}"
  log_msg "ERROR" ""
  log_msg "ERROR" "To fix this issue, you have two options:"
  log_msg "ERROR" ""
  log_msg "ERROR" "Option 1: Use an IAM profile with higher privileges"
  log_msg "ERROR" "  Run with --iam-profile using a profile that has IAM permissions:"
  log_msg "ERROR" "  bash install-aws.sh --iam-profile <ADMIN_PROFILE>"
  log_msg "ERROR" ""
  log_msg "ERROR" "Option 2: Pre-create the IAM role manually"
  log_msg "ERROR" "  Ask your AWS administrator to create:"
  log_msg "ERROR" "  - Role: ${IAM_ROLE_NAME}"
  log_msg "ERROR" "  - Instance Profile: ${IAM_INSTANCE_PROFILE}"
  log_msg "ERROR" "  - Policy: AmazonRoute53FullAccess"
  log_msg "ERROR" ""
  if [[ -n "${AWS_PROFILE_IAM}" ]]; then
    log_msg "ERROR" "Current IAM Profile: ${AWS_PROFILE_IAM}"
  else
    log_msg "ERROR" "Current IAM Profile: default"
  fi
  exit 1
}

# -----------------------------------------------------------------------------
# Function: profile_exists
# Description: Checks if an AWS profile exists in ~/.aws/config
# Arguments:
#   $1 - Profile name
# Returns: 0 if exists, 1 if not
# -----------------------------------------------------------------------------
profile_exists() {
  local profile="$1"
  if [[ -z "${profile}" ]]; then
    return 0
  fi
  # Check both [profile name] and [name] formats in ~/.aws/config
  if grep -q "^\[profile ${profile}\]" ~/.aws/config 2>/dev/null || \
     grep -q "^\[${profile}\]" ~/.aws/config 2>/dev/null || \
     grep -q "^\[${profile}\]" ~/.aws/credentials 2>/dev/null; then
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
# Function: check_dependencies
# Description: Verifies required tools are installed
# -----------------------------------------------------------------------------
check_dependencies() {
  local deps=(aws jq ssh ssh-keygen)
  local missing=()

  for cmd in "${deps[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required commands: ${missing[*]}. Please install them first."
  fi

  # Validate AWS profiles if specified
  if [[ -n "${AWS_PROFILE_EC2}" ]]; then
    if ! profile_exists "${AWS_PROFILE_EC2}"; then
      die "EC2 profile '${AWS_PROFILE_EC2}' not found in ~/.aws/config or ~/.aws/credentials"
    fi
    log_msg "INFO" "Using AWS profile for EC2 operations: ${AWS_PROFILE_EC2}"
  fi

  if [[ -n "${AWS_PROFILE_IAM}" ]]; then
    if ! profile_exists "${AWS_PROFILE_IAM}"; then
      die "IAM profile '${AWS_PROFILE_IAM}' not found in ~/.aws/config or ~/.aws/credentials"
    fi
    log_msg "INFO" "Using AWS profile for IAM/Route53 operations: ${AWS_PROFILE_IAM}"
  fi

  # Check AWS CLI is configured
  if ! aws_sts get-caller-identity >/dev/null 2>&1; then
    die "AWS CLI is not configured. Run 'aws configure' first."
  fi

  log_msg "INFO" "All dependencies satisfied"
}

# -----------------------------------------------------------------------------
# Function: get_latest_al2023_ami
# Description: Finds the latest Amazon Linux 2023 AMI for the specified architecture
# Arguments:
#   $1 - Region
#   $2 - Architecture (arm64 or x86_64)
# Returns: AMI ID
# -----------------------------------------------------------------------------
get_latest_al2023_ami() {
  local region="$1"
  local arch="$2"

  log_msg "INFO" "Finding latest Amazon Linux 2023 ${arch} AMI in ${region}..."

  local ami_id
  ami_id=$(aws_ec2 describe-images \
    --region "${region}" \
    --owners "${DEFAULT_AMI_OWNER}" \
    --filters \
      "Name=name,Values=al2023-ami-2023.*-${arch}" \
      "Name=state,Values=available" \
      "Name=architecture,Values=${arch}" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)

  if [[ -z "${ami_id}" ]] || [[ "${ami_id}" == "None" ]]; then
    die "Could not find Amazon Linux 2023 ${arch} AMI in ${region}"
  fi

  log_msg "INFO" "Found AMI: ${ami_id}"
  echo "${ami_id}"
}

# -----------------------------------------------------------------------------
# Function: create_key_pair
# Description: Creates SSH key pair if it doesn't exist
# Arguments:
#   $1 - Region
# -----------------------------------------------------------------------------
create_key_pair() {
  local region="$1"
  local key_file="${HOME}/.ssh/${KEY_NAME}.pem"

  # Check if key already exists in AWS
  if aws_ec2 describe-key-pairs --region "${region}" --key-names "${KEY_NAME}" >/dev/null 2>&1; then
    log_msg "INFO" "Key pair '${KEY_NAME}' already exists in AWS"

    # Verify local key file exists
    if [[ ! -f "${key_file}" ]]; then
      die "Key pair exists in AWS but local file ${key_file} not found. Delete AWS key and re-run."
    fi
    return
  fi

  log_msg "INFO" "Creating key pair '${KEY_NAME}'..."

  # Create key pair and save to file
  aws_ec2 create-key-pair \
    --region "${region}" \
    --key-name "${KEY_NAME}" \
    --query 'KeyMaterial' \
    --output text > "${key_file}"

  chmod 600 "${key_file}"
  log_msg "INFO" "Key pair created and saved to ${key_file}"
}

# -----------------------------------------------------------------------------
# Function: add_security_group_rules
# Description: Adds ingress rules to security group
# Arguments:
#   $1 - Region
#   $2 - Security group ID
# -----------------------------------------------------------------------------
add_security_group_rules() {
  local region="$1"
  local sg_id="$2"

  log_msg "INFO" "Adding ingress rules to security group..."

  # SSH (22)
  aws_ec2 authorize-security-group-ingress \
    --region "${region}" \
    --group-id "${sg_id}" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 >/dev/null 2>&1 || log_msg "WARN" "SSH rule may already exist"

  # HTTP (80)
  aws_ec2 authorize-security-group-ingress \
    --region "${region}" \
    --group-id "${sg_id}" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0 >/dev/null 2>&1 || log_msg "WARN" "HTTP rule may already exist"

  # HTTPS (443)
  aws_ec2 authorize-security-group-ingress \
    --region "${region}" \
    --group-id "${sg_id}" \
    --protocol tcp \
    --port 443 \
    --cidr 0.0.0.0/0 >/dev/null 2>&1 || log_msg "WARN" "HTTPS rule may already exist"

  log_msg "INFO" "Ingress rules added successfully"
}

# -----------------------------------------------------------------------------
# Function: create_security_group
# Description: Creates security group with required ports if it doesn't exist
# Arguments:
#   $1 - Region
# Returns: Security group ID
# -----------------------------------------------------------------------------
create_security_group() {
  local region="$1"
  local sg_id

  # Check if security group already exists
  sg_id=$(aws_ec2 describe-security-groups \
    --region "${region}" \
    --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "")

  if [[ -n "${sg_id}" ]] && [[ "${sg_id}" != "None" ]]; then
    log_msg "INFO" "Security group '${SECURITY_GROUP_NAME}' already exists: ${sg_id}"

    # Check if ingress rules exist
    local rule_count
    rule_count=$(aws_ec2 describe-security-groups \
      --region "${region}" \
      --group-ids "${sg_id}" \
      --query 'length(SecurityGroups[0].IpPermissions)' \
      --output text)

    if [[ "${rule_count}" == "0" ]]; then
      log_msg "WARN" "Security group has no ingress rules, adding them now..."
      add_security_group_rules "${region}" "${sg_id}"
    else
      log_msg "INFO" "Security group has ${rule_count} ingress rule(s)"
    fi

    echo "${sg_id}"
    return
  fi

  log_msg "INFO" "Creating security group '${SECURITY_GROUP_NAME}'..."

  # Get default VPC
  local vpc_id
  vpc_id=$(aws_ec2 describe-vpcs \
    --region "${region}" \
    --filters "Name=is-default,Values=true" \
    --query 'Vpcs[0].VpcId' \
    --output text)

  if [[ -z "${vpc_id}" ]] || [[ "${vpc_id}" == "None" ]]; then
    die "No default VPC found in ${region}"
  fi

  # Create security group
  sg_id=$(aws_ec2 create-security-group \
    --region "${region}" \
    --group-name "${SECURITY_GROUP_NAME}" \
    --description "Security group for Appmotel PaaS" \
    --vpc-id "${vpc_id}" \
    --query 'GroupId' \
    --output text)

  log_msg "INFO" "Security group created: ${sg_id}"

  # Add inbound rules
  add_security_group_rules "${region}" "${sg_id}"
  echo "${sg_id}"
}

# -----------------------------------------------------------------------------
# Function: launch_instance
# Description: Launches EC2 instance
# Arguments:
#   $1 - Region
#   $2 - Instance type
#   $3 - AMI ID
#   $4 - Security group ID
# Returns: Instance ID
# -----------------------------------------------------------------------------
launch_instance() {
  local region="$1"
  local instance_type="$2"
  local ami_id="$3"
  local sg_id="$4"

  log_msg "INFO" "Launching EC2 instance (${instance_type})..."

  local instance_id
  instance_id=$(aws_ec2 run-instances \
    --region "${region}" \
    --image-id "${ami_id}" \
    --instance-type "${instance_type}" \
    --key-name "${KEY_NAME}" \
    --security-group-ids "${sg_id}" \
    --iam-instance-profile "Name=${IAM_INSTANCE_PROFILE}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

  log_msg "INFO" "Instance launched: ${instance_id}"
  log_msg "INFO" "Waiting for instance to be running..."

  aws_ec2 wait instance-running \
    --region "${region}" \
    --instance-ids "${instance_id}"

  log_msg "INFO" "Instance is running"

  echo "${instance_id}"
}

# -----------------------------------------------------------------------------
# Function: get_instance_ip
# Description: Gets public IP address of instance
# Arguments:
#   $1 - Region
#   $2 - Instance ID
# Returns: Public IP address
# -----------------------------------------------------------------------------
get_instance_ip() {
  local region="$1"
  local instance_id="$2"

  local public_ip
  public_ip=$(aws_ec2 describe-instances \
    --region "${region}" \
    --instance-ids "${instance_id}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

  if [[ -z "${public_ip}" ]] || [[ "${public_ip}" == "None" ]]; then
    die "Could not get public IP for instance ${instance_id}"
  fi

  echo "${public_ip}"
}

# -----------------------------------------------------------------------------
# Function: wait_for_ssh
# Description: Waits for SSH to be accessible
# Arguments:
#   $1 - Host IP
#   $2 - Key file path
# -----------------------------------------------------------------------------
wait_for_ssh() {
  local host="$1"
  local key_file="$2"
  local max_attempts=40
  local attempt=0

  log_msg "INFO" "Checking SSH accessibility..."

  while [[ ${attempt} -lt ${max_attempts} ]]; do
    if ssh -i "${key_file}" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR \
           -o ConnectTimeout=3 \
           -o BatchMode=yes \
           "${SSH_USER}@${host}" \
           "echo 'SSH ready'" >/dev/null 2>&1; then
      log_msg "INFO" "SSH is ready (attempt ${attempt}/${max_attempts})"
      return 0
    fi

    attempt=$((attempt + 1))
    if [[ ${attempt} -lt ${max_attempts} ]]; then
      sleep 3
    fi
  done

  die "SSH did not become accessible after ${max_attempts} attempts (2 minutes)"
}

# -----------------------------------------------------------------------------
# Function: create_iam_role
# Description: Creates IAM role for EC2 to access Route53
# Returns: Success (0) or failure (1)
# -----------------------------------------------------------------------------
create_iam_role() {
  log_msg "INFO" "Setting up IAM role for Route53 access..."

  # Check if role already exists
  local role_check_output
  role_check_output=$(aws_iam get-role --role-name "${IAM_ROLE_NAME}" 2>&1) && {
    log_msg "INFO" "IAM role '${IAM_ROLE_NAME}' already exists"
  } || {
    # Check for access denied error
    if echo "${role_check_output}" | grep -q "AccessDenied"; then
      die_iam_permission_error "iam:GetRole"
    fi

    log_msg "INFO" "Creating IAM role - this may take a few seconds..."

    # Trust policy - allows EC2 to assume this role
    local trust_policy
    trust_policy=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
)

    # Create the role
    local create_output
    create_output=$(aws_iam create-role \
      --role-name "${IAM_ROLE_NAME}" \
      --assume-role-policy-document "${trust_policy}" \
      --description "Allows Appmotel/Traefik to manage Route53 for Let's Encrypt DNS-01 challenge" \
      2>&1) || {
      if echo "${create_output}" | grep -q "AccessDenied"; then
        die_iam_permission_error "iam:CreateRole"
      fi
      die "Failed to create IAM role: ${create_output}"
    }

    log_msg "INFO" "IAM role created"
  }

  # Check if policy is attached
  if aws_iam list-attached-role-policies --role-name "${IAM_ROLE_NAME}" 2>/dev/null | grep -q "Route53FullAccess"; then
    log_msg "INFO" "Route53 policy already attached"
  else
    log_msg "INFO" "Attaching Route53 policy to role..."

    # Attach AWS managed Route53 policy
    local attach_output
    attach_output=$(aws_iam attach-role-policy \
      --role-name "${IAM_ROLE_NAME}" \
      --policy-arn "arn:aws:iam::aws:policy/AmazonRoute53FullAccess" \
      2>&1) || {
      if echo "${attach_output}" | grep -q "AccessDenied"; then
        die_iam_permission_error "iam:AttachRolePolicy"
      fi
      die "Failed to attach policy: ${attach_output}"
    }

    log_msg "INFO" "Route53 policy attached"
  fi

  # Create instance profile if it doesn't exist
  if aws_iam get-instance-profile --instance-profile-name "${IAM_INSTANCE_PROFILE}" >/dev/null 2>&1; then
    log_msg "INFO" "Instance profile '${IAM_INSTANCE_PROFILE}' already exists"
  else
    log_msg "INFO" "Creating instance profile..."

    local profile_output
    profile_output=$(aws_iam create-instance-profile \
      --instance-profile-name "${IAM_INSTANCE_PROFILE}" \
      2>&1) || {
      if echo "${profile_output}" | grep -q "AccessDenied"; then
        die_iam_permission_error "iam:CreateInstanceProfile"
      fi
      die "Failed to create instance profile: ${profile_output}"
    }

    # Add role to instance profile
    aws_iam add-role-to-instance-profile \
      --instance-profile-name "${IAM_INSTANCE_PROFILE}" \
      --role-name "${IAM_ROLE_NAME}" || die "Failed to add role to instance profile"

    log_msg "INFO" "Instance profile created"

    # Wait for instance profile to be ready
    log_msg "INFO" "Waiting for IAM resources to propagate - 10 seconds..."
    sleep 10
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Function: list_all_route53_zones
# Description: Lists all Route53 hosted zones for user selection
# -----------------------------------------------------------------------------
list_all_route53_zones() {
  log_msg "INFO" ""
  log_msg "INFO" "Available Route53 hosted zones:"
  log_msg "INFO" "================================"

  local zones
  zones=$(aws_route53 list-hosted-zones \
    --query 'HostedZones[].[Id,Name]' \
    --output text 2>/dev/null)

  if [[ -z "${zones}" ]]; then
    log_msg "INFO" "  No zones found"
    return
  fi

  while IFS=$'\t' read -r zone_id zone_name; do
    local clean_id clean_name
    clean_id="${zone_id#/hostedzone/}"
    clean_name="${zone_name%.}"
    log_msg "INFO" "  --hosted-zone ${clean_id}    # ${clean_name}"
  done <<< "${zones}"

  log_msg "INFO" ""
}

# -----------------------------------------------------------------------------
# Function: get_route53_hosted_zone
# Description: Gets hosted zone from Route53
# Arguments:
#   $1 - Region
#   $2 - Requested zone ID (optional, from --hosted-zone)
# Returns: Hosted zone ID and domain name (format: "ID DOMAIN")
# -----------------------------------------------------------------------------
get_route53_hosted_zone() {
  local region="$1"
  local requested_zone_id="${2-}"

  log_msg "INFO" "Looking for Route53 hosted zones..."

  # Get all hosted zones
  local all_zones zone_count
  all_zones=$(aws_route53 list-hosted-zones \
    --query 'HostedZones[].[Id,Name]' \
    --output text 2>/dev/null)

  if [[ -z "${all_zones}" ]] || [[ "${all_zones}" == "None" ]]; then
    log_msg "WARN" "No Route53 hosted zones found"
    return 1
  fi

  zone_count=$(echo "${all_zones}" | wc -l)

  # If a specific zone was requested, validate and use it
  if [[ -n "${requested_zone_id}" ]]; then
    local found_zone=""
    while IFS=$'\t' read -r zone_id zone_name; do
      local clean_id="${zone_id#/hostedzone/}"
      if [[ "${clean_id}" == "${requested_zone_id}" ]]; then
        local clean_name="${zone_name%.}"
        found_zone="${clean_id} ${clean_name}"
        break
      fi
    done <<< "${all_zones}"

    if [[ -z "${found_zone}" ]]; then
      log_msg "ERROR" "Hosted zone '${requested_zone_id}' not found"
      list_all_route53_zones
      die "Please use one of the zone IDs listed above with --hosted-zone"
    fi

    log_msg "INFO" "Using requested hosted zone: ${found_zone}"
    echo "${found_zone}"
    return 0
  fi

  # If only one zone exists, use it automatically
  if [[ "${zone_count}" -eq 1 ]]; then
    local zone_id zone_name
    zone_id=$(echo "${all_zones}" | awk '{print $1}' | sed 's|/hostedzone/||')
    zone_name=$(echo "${all_zones}" | awk '{print $2}' | sed 's/\.$//')
    log_msg "INFO" "Found hosted zone: ${zone_name} - ${zone_id}"
    echo "${zone_id} ${zone_name}"
    return 0
  fi

  # Multiple zones found - require user to select one
  log_msg "ERROR" "Multiple Route53 hosted zones found"
  list_all_route53_zones
  die "Please specify which zone to use with --hosted-zone <ZONE_ID>"
}

# -----------------------------------------------------------------------------
# Function: check_existing_appmotel_records
# Description: Checks if appmotel DNS records already exist in the zone
# Arguments:
#   $1 - Hosted zone ID
#   $2 - Domain name
# Returns: 0 if records exist, 1 if not
# -----------------------------------------------------------------------------
check_existing_appmotel_records() {
  local zone_id="$1"
  local domain="$2"

  log_msg "INFO" "Checking for existing appmotel DNS records..."

  local records
  records=$(aws_route53 list-resource-record-sets \
    --hosted-zone-id "${zone_id}" \
    --query "ResourceRecordSets[?Name=='appmotel.${domain}.' || Name=='*.${domain}.'].Name" \
    --output text 2>/dev/null)

  if [[ -n "${records}" ]] && [[ "${records}" != "None" ]]; then
    log_msg "WARN" ""
    log_msg "WARN" "Existing appmotel DNS records found in zone ${zone_id}:"
    for record in ${records}; do
      log_msg "WARN" "  - ${record}"
    done
    log_msg "WARN" ""
    return 0  # Records exist
  fi

  return 1  # No records
}

# -----------------------------------------------------------------------------
# Function: validate_route53_early
# Description: Validates Route53 configuration before launching EC2
# Arguments:
#   $1 - Region
#   $2 - Requested zone ID (optional)
# Returns: zone_id and domain_name via global variables
# -----------------------------------------------------------------------------
VALIDATED_ZONE_ID=""
VALIDATED_DOMAIN=""

validate_route53_early() {
  local region="$1"
  local requested_zone_id="${2-}"

  log_msg "INFO" "============================================"
  log_msg "INFO" "Phase 1: Validating Route53 configuration"
  log_msg "INFO" "============================================"

  log_msg "INFO" "Looking for Route53 hosted zones..."

  # Get all hosted zones
  local all_zones zone_count
  all_zones=$(aws_route53 list-hosted-zones \
    --query 'HostedZones[].[Id,Name]' \
    --output text 2>/dev/null)

  if [[ -z "${all_zones}" ]] || [[ "${all_zones}" == "None" ]]; then
    log_msg "INFO" "No Route53 hosted zones found - skipping DNS configuration"
    return 1
  fi

  zone_count=$(echo "${all_zones}" | wc -l)

  # If a specific zone was requested, validate it
  if [[ -n "${requested_zone_id}" ]]; then
    local found_zone=""
    while IFS=$'\t' read -r zone_id zone_name; do
      local clean_id="${zone_id#/hostedzone/}"
      if [[ "${clean_id}" == "${requested_zone_id}" ]]; then
        local clean_name="${zone_name%.}"
        VALIDATED_ZONE_ID="${clean_id}"
        VALIDATED_DOMAIN="${clean_name}"
        found_zone="yes"
        break
      fi
    done <<< "${all_zones}"

    if [[ -z "${found_zone}" ]]; then
      log_msg "ERROR" "Hosted zone '${requested_zone_id}' not found"
      list_all_route53_zones
      die "Please use one of the zone IDs listed above with --hosted-zone"
    fi

    log_msg "INFO" "Using requested hosted zone: ${VALIDATED_ZONE_ID} ${VALIDATED_DOMAIN}"

  # If only one zone exists, use it automatically
  elif [[ "${zone_count}" -eq 1 ]]; then
    VALIDATED_ZONE_ID=$(echo "${all_zones}" | awk '{print $1}' | sed 's|/hostedzone/||')
    VALIDATED_DOMAIN=$(echo "${all_zones}" | awk '{print $2}' | sed 's/\.$//')
    log_msg "INFO" "Found hosted zone: ${VALIDATED_DOMAIN} - ${VALIDATED_ZONE_ID}"

  # Multiple zones found - require user to select one (STOP HERE!)
  else
    log_msg "ERROR" "Multiple Route53 hosted zones found"
    list_all_route53_zones
    die "Please specify which zone to use with --hosted-zone <ZONE_ID>"
  fi

  # Check for existing records
  if check_existing_appmotel_records "${VALIDATED_ZONE_ID}" "${VALIDATED_DOMAIN}"; then
    if [[ "${FORCE_OVERWRITE}" -eq 1 ]]; then
      log_msg "INFO" "Existing records will be overwritten due to --force flag"
    else
      log_msg "ERROR" ""
      log_msg "ERROR" "DNS records for appmotel already exist in this zone."
      log_msg "ERROR" ""
      log_msg "ERROR" "To resolve this, you have two options:"
      log_msg "ERROR" ""
      log_msg "ERROR" "Option 1: Use --force to overwrite existing records"
      log_msg "ERROR" "  bash install-aws.sh --force"
      log_msg "ERROR" ""
      log_msg "ERROR" "Option 2: Manually remove the existing records from Route53"
      log_msg "ERROR" "  - appmotel.${VALIDATED_DOMAIN}"
      log_msg "ERROR" "  - *.${VALIDATED_DOMAIN}"
      log_msg "ERROR" ""
      die "Aborting to prevent DNS conflicts"
    fi
  fi

  log_msg "INFO" "Route53 validation passed"
  log_msg "INFO" "  Zone ID: ${VALIDATED_ZONE_ID}"
  log_msg "INFO" "  Domain: ${VALIDATED_DOMAIN}"
  return 0
}

# -----------------------------------------------------------------------------
# Function: configure_route53_dns
# Description: Configures DNS records in Route53 for appmotel
# Arguments:
#   $1 - Hosted zone ID
#   $2 - Domain name
#   $3 - Server IP address
# -----------------------------------------------------------------------------
configure_route53_dns() {
  local zone_id="$1"
  local domain="$2"
  local server_ip="$3"

  log_msg "INFO" "Configuring Route53 DNS records..."

  # Create change batch JSON for both records
  local change_batch
  change_batch=$(cat <<EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "appmotel.${domain}",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "${server_ip}"}]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "*.${domain}",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{"Value": "${server_ip}"}]
      }
    }
  ]
}
EOF
)

  # Apply changes
  local change_id
  change_id=$(aws_route53 change-resource-record-sets \
    --hosted-zone-id "${zone_id}" \
    --change-batch "${change_batch}" \
    --query 'ChangeInfo.Id' \
    --output text 2>/dev/null)

  if [[ -z "${change_id}" ]] || [[ "${change_id}" == "None" ]]; then
    log_msg "ERROR" "Failed to create DNS records"
    return 1
  fi

  log_msg "INFO" "DNS records created:"
  log_msg "INFO" "  A record: appmotel.${domain} → ${server_ip}"
  log_msg "INFO" "  Wildcard: *.${domain} → ${server_ip}"
  log_msg "INFO" "Change ID: ${change_id}"

  return 0
}

# -----------------------------------------------------------------------------
# Function: configure_base_domain
# Description: Updates BASE_DOMAIN in remote .env file
# Arguments:
#   $1 - Host IP
#   $2 - Key file path
#   $3 - Domain name
# -----------------------------------------------------------------------------
configure_base_domain() {
  local host="$1"
  local key_file="$2"
  local domain="$3"

  log_msg "INFO" "Configuring BASE_DOMAIN=${domain} on remote server..."

  ssh -i "${key_file}" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "${SSH_USER}@${host}" \
      "sudo sed -i 's|^BASE_DOMAIN=.*|BASE_DOMAIN=\"${domain}\"|' /home/appmotel/.config/appmotel/.env"

  log_msg "INFO" "BASE_DOMAIN configured successfully"
}

# -----------------------------------------------------------------------------
# Function: configure_dns01_mode
# Description: Enables Let's Encrypt DNS-01 challenge mode with Route53
# Arguments:
#   $1 - Host IP
#   $2 - Key file path
#   $3 - Hosted zone ID
#   $4 - Region
# -----------------------------------------------------------------------------
configure_dns01_mode() {
  local host="$1"
  local key_file="$2"
  local zone_id="$3"
  local region="$4"

  log_msg "INFO" "Configuring Let's Encrypt DNS-01 mode with Route53..."

  ssh -i "${key_file}" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "${SSH_USER}@${host}" \
      "sudo sed -i \
        -e 's|^USE_LETSENCRYPT=.*|USE_LETSENCRYPT=\"yes\"|' \
        -e 's|^LETSENCRYPT_MODE=.*|LETSENCRYPT_MODE=\"dns\"|' \
        -e 's|^AWS_HOSTED_ZONE_ID=.*|AWS_HOSTED_ZONE_ID=\"${zone_id}\"|' \
        -e 's|^AWS_REGION=.*|AWS_REGION=\"${region}\"|' \
        /home/appmotel/.config/appmotel/.env"

  log_msg "INFO" "DNS-01 mode configured (using IAM instance role for credentials)"
}

# -----------------------------------------------------------------------------
# Function: install_appmotel
# Description: Uploads and runs install.sh on remote instance
# Arguments:
#   $1 - Host IP
#   $2 - Key file path
# -----------------------------------------------------------------------------
install_appmotel() {
  local host="$1"
  local key_file="$2"
  local install_script="${SCRIPT_DIR}/install.sh"
  local env_default="${SCRIPT_DIR}/.env.default"

  if [[ ! -f "${install_script}" ]]; then
    die "install.sh not found at ${install_script}"
  fi

  log_msg "INFO" "Uploading install.sh to remote instance..."

  scp -i "${key_file}" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "${install_script}" \
      "${SSH_USER}@${host}:/tmp/install.sh"

  # Upload .env.default if it exists
  if [[ -f "${env_default}" ]]; then
    log_msg "INFO" "Uploading .env.default..."
    scp -i "${key_file}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "${env_default}" \
        "${SSH_USER}@${host}:/tmp/.env.default"
  fi

  log_msg "INFO" "Running system-level installation (as root)..."

  ssh -i "${key_file}" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "${SSH_USER}@${host}" \
      "sudo bash /tmp/install.sh"

  log_msg "INFO" "Installation completed successfully!"
}

# -----------------------------------------------------------------------------
# Function: display_summary
# Description: Displays connection and next steps information
# Arguments:
#   $1 - Host IP
#   $2 - Key file path
#   $3 - Instance ID
#   $4 - Region
#   $5 - Domain name (optional)
# -----------------------------------------------------------------------------
display_summary() {
  local host="$1"
  local key_file="$2"
  local instance_id="$3"
  local region="$4"
  local domain="${5:-}"

  log_msg "INFO" "======================================"
  log_msg "INFO" "Appmotel EC2 Installation Complete!"
  log_msg "INFO" "======================================"
  log_msg "INFO" ""
  log_msg "INFO" "Instance Details:"
  log_msg "INFO" "  Instance ID: ${instance_id}"
  log_msg "INFO" "  Region: ${region}"
  log_msg "INFO" "  Public IP: ${host}"
  log_msg "INFO" "  OS: Amazon Linux 2023"

  if [[ -n "${domain}" ]]; then
    log_msg "INFO" "  Base Domain: ${domain}"
    log_msg "INFO" ""
    log_msg "INFO" "DNS Configuration:"
    log_msg "INFO" "  ✓ Route53 records configured automatically"
    log_msg "INFO" "  ✓ A record: appmotel.${domain} → ${host}"
    log_msg "INFO" "  ✓ Wildcard: *.${domain} → ${host}"
    log_msg "INFO" "  ✓ BASE_DOMAIN configured in ~/.config/appmotel/.env"
    log_msg "INFO" ""
    log_msg "INFO" "Let's Encrypt Configuration:"
    log_msg "INFO" "  ✓ DNS-01 challenge mode enabled"
    log_msg "INFO" "  ✓ Route53 integration configured"
    log_msg "INFO" "  ✓ IAM instance role (no credentials needed!)"
    log_msg "INFO" "  ✓ Wildcard certificates will be issued automatically"
  fi

  log_msg "INFO" ""
  log_msg "INFO" "Connect to your instance:"
  log_msg "INFO" "  ssh -i ${key_file} ${SSH_USER}@${host}"
  log_msg "INFO" ""
  log_msg "INFO" "Next Steps:"
  log_msg "INFO" ""
  log_msg "INFO" "1. SSH into the instance:"
  log_msg "INFO" "   ssh -i ${key_file} ${SSH_USER}@${host}"
  log_msg "INFO" ""
  log_msg "INFO" "2. Switch to appmotel user:"
  log_msg "INFO" "   sudo su - appmotel"
  log_msg "INFO" ""
  log_msg "INFO" "3. Run user-level installation:"
  log_msg "INFO" "   curl -fsSL \"https://raw.githubusercontent.com/dirkpetersen/appmotel/main/install.sh?\$(date +%s)\" | bash"
  log_msg "INFO" ""

  if [[ -n "${domain}" ]]; then
    log_msg "INFO" "4. Deploy your first app (DNS already configured!):"
    log_msg "INFO" "   appmo add myapp https://github.com/username/repo main"
    log_msg "INFO" ""
    log_msg "INFO" "   Your app will be available at: https://myapp.${domain}"
  else
    log_msg "INFO" "4. Configure your domain:"
    log_msg "INFO" "   nano ~/.config/appmotel/.env"
    log_msg "INFO" "   # Set BASE_DOMAIN to your actual domain"
    log_msg "INFO" ""
    log_msg "INFO" "5. Restart Traefik:"
    log_msg "INFO" "   sudo systemctl restart traefik-appmotel"
    log_msg "INFO" ""
    log_msg "INFO" "6. Configure DNS (see documentation):"
    log_msg "INFO" "   Option 1: Wildcard A record (*.apps.yourdomain.edu → ${host})"
    log_msg "INFO" "   Option 2: Individual records per app"
    log_msg "INFO" ""
    log_msg "INFO" "7. Deploy your first app:"
    log_msg "INFO" "   appmo add myapp https://github.com/username/repo main"
  fi

  log_msg "INFO" ""
  log_msg "INFO" "AWS Management:"
  log_msg "INFO" "  Stop instance: aws ec2 stop-instances --region ${region} --instance-ids ${instance_id}"
  log_msg "INFO" "  Start instance: aws ec2 start-instances --region ${region} --instance-ids ${instance_id}"
  log_msg "INFO" "  Terminate instance: aws ec2 terminate-instances --region ${region} --instance-ids ${instance_id}"
  log_msg "INFO" ""
}

# -----------------------------------------------------------------------------
# Function: usage
# Description: Displays usage information
# -----------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Launches an EC2 instance with Amazon Linux 2023 and installs Appmotel on it.

Options:
  -t, --type INSTANCE_TYPE    EC2 instance type (default: ${DEFAULT_INSTANCE_TYPE})
  -r, --region REGION         AWS region (default: ${DEFAULT_REGION})
  --ec2-profile PROFILE       AWS profile for EC2 operations
  --iam-profile PROFILE       AWS profile for IAM/Route53 operations
  --hosted-zone ZONE_ID       Route53 hosted zone ID to use
  --force                     Overwrite existing appmotel DNS records
  -h, --help                  Show this help message

AWS Profile Options:
  Use --ec2-profile and --iam-profile when you have separate AWS profiles with
  different permissions. For example, if your default profile has EC2 access
  but not IAM permissions, use --iam-profile to specify a profile with IAM
  admin permissions for creating the instance role.

Route53 Configuration:
  If you have multiple Route53 hosted zones, use --hosted-zone to specify which
  zone to use. If only one zone exists, it will be selected automatically.

  If appmotel DNS records already exist in the zone, the script will stop.
  Use --force to overwrite existing records.

Examples:
  # Launch with defaults (t4g.micro ARM instance in us-west-2)
  bash install-aws.sh

  # Launch specific instance type
  bash install-aws.sh --type t3.small

  # Launch in different region
  bash install-aws.sh --region us-east-1

  # Use separate AWS profile for IAM operations
  bash install-aws.sh --iam-profile admin-profile

  # Specify hosted zone and force overwrite
  bash install-aws.sh --hosted-zone Z1234567890ABC --force

  # Launch x86 instance
  bash install-aws.sh --type t3.micro --region us-east-1

ARM Instance Types (aarch64):
  - t4g.micro   (2 vCPU, 1 GB RAM) - Default
  - t4g.small   (2 vCPU, 2 GB RAM)
  - t4g.medium  (2 vCPU, 4 GB RAM)

x86 Instance Types (x86_64):
  - t3.micro    (2 vCPU, 1 GB RAM)
  - t3.small    (2 vCPU, 2 GB RAM)
  - t3.medium   (2 vCPU, 4 GB RAM)

EOF
}

# -----------------------------------------------------------------------------
# Function: main
# Description: Main execution flow
# -----------------------------------------------------------------------------
main() {
  local instance_type="${DEFAULT_INSTANCE_TYPE}"
  local region="${DEFAULT_REGION}"

  # Parse command line arguments
  while :; do
    case "${1-}" in
      -h | --help)
        usage
        exit 0
        ;;
      -t | --type)
        if [[ -z "${2-}" ]]; then
          die "Option $1 requires an argument"
        fi
        instance_type="${2}"
        shift
        ;;
      -r | --region)
        if [[ -z "${2-}" ]]; then
          die "Option $1 requires an argument"
        fi
        region="${2}"
        shift
        ;;
      --ec2-profile)
        if [[ -z "${2-}" ]]; then
          die "Option $1 requires an argument"
        fi
        AWS_PROFILE_EC2="${2}"
        shift
        ;;
      --iam-profile)
        if [[ -z "${2-}" ]]; then
          die "Option $1 requires an argument"
        fi
        AWS_PROFILE_IAM="${2}"
        shift
        ;;
      --hosted-zone)
        if [[ -z "${2-}" ]]; then
          die "Option $1 requires an argument"
        fi
        REQUESTED_HOSTED_ZONE="${2}"
        shift
        ;;
      --force)
        FORCE_OVERWRITE=1
        ;;
      -?*)
        die "Unknown option: $1"
        ;;
      *)
        break
        ;;
    esac
    shift
  done

  log_msg "INFO" "Starting Appmotel AWS EC2 deployment"
  log_msg "INFO" "Instance type: ${instance_type}"
  log_msg "INFO" "Region: ${region}"

  # Check dependencies
  check_dependencies

  # Validate Route53 configuration BEFORE launching EC2
  # This prevents launching an instance only to fail at DNS config
  local route53_available=0
  if validate_route53_early "${region}" "${REQUESTED_HOSTED_ZONE}"; then
    route53_available=1
  fi

  log_msg "INFO" "============================================"
  log_msg "INFO" "Phase 2: Launching EC2 instance"
  log_msg "INFO" "============================================"

  # Determine architecture based on instance type
  local arch
  if [[ "${instance_type}" =~ ^t4g\. ]] || [[ "${instance_type}" =~ ^c7g\. ]] || [[ "${instance_type}" =~ ^m7g\. ]]; then
    arch="arm64"
  else
    arch="x86_64"
  fi

  log_msg "INFO" "Architecture: ${arch}"

  # Get latest Amazon Linux 2023 AMI
  local ami_id
  ami_id=$(get_latest_al2023_ami "${region}" "${arch}")

  # Create IAM role for Route53 access (for Let's Encrypt DNS-01)
  create_iam_role

  # Create key pair
  create_key_pair "${region}"
  local key_file="${HOME}/.ssh/${KEY_NAME}.pem"

  # Create security group
  local sg_id
  sg_id=$(create_security_group "${region}")

  # Launch instance with IAM role
  local instance_id
  instance_id=$(launch_instance "${region}" "${instance_type}" "${ami_id}" "${sg_id}")

  # Get instance IP
  local public_ip
  public_ip=$(get_instance_ip "${region}" "${instance_id}")
  log_msg "INFO" "Instance public IP: ${public_ip}"

  # Wait for SSH to be ready
  wait_for_ssh "${public_ip}" "${key_file}"

  # Install Appmotel
  install_appmotel "${public_ip}" "${key_file}"

  # Configure Route53 DNS using pre-validated zone info
  local domain_name=""
  if [[ "${route53_available}" -eq 1 ]] && [[ -n "${VALIDATED_ZONE_ID}" ]]; then
    # Configure DNS records in Route53
    if configure_route53_dns "${VALIDATED_ZONE_ID}" "${VALIDATED_DOMAIN}" "${public_ip}"; then
      domain_name="${VALIDATED_DOMAIN}"

      # Update BASE_DOMAIN on remote server
      configure_base_domain "${public_ip}" "${key_file}" "${domain_name}"

      # Configure DNS-01 mode for Let's Encrypt wildcard certificates
      configure_dns01_mode "${public_ip}" "${key_file}" "${VALIDATED_ZONE_ID}" "${region}"

      # Restart Traefik to apply new domain configuration
      log_msg "INFO" "Restarting Traefik to apply DNS configuration..."
      ssh -i "${key_file}" \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          "${SSH_USER}@${public_ip}" \
          "sudo systemctl restart traefik-appmotel" 2>/dev/null || log_msg "WARN" "Traefik not running yet - expected on first install"
    else
      log_msg "WARN" "DNS configuration failed, continuing without automatic DNS setup"
    fi
  else
    log_msg "INFO" "No Route53 hosted zones configured, skipping automatic DNS setup"
  fi

  # Display summary
  display_summary "${public_ip}" "${key_file}" "${instance_id}" "${region}" "${domain_name:-}"
}

# Execute main function
main "$@"

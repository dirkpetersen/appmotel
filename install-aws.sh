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

  # Check AWS CLI is configured
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
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
  ami_id=$(aws ec2 describe-images \
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
  if aws ec2 describe-key-pairs --region "${region}" --key-names "${KEY_NAME}" >/dev/null 2>&1; then
    log_msg "INFO" "Key pair '${KEY_NAME}' already exists in AWS"

    # Verify local key file exists
    if [[ ! -f "${key_file}" ]]; then
      die "Key pair exists in AWS but local file ${key_file} not found. Delete AWS key and re-run."
    fi
    return
  fi

  log_msg "INFO" "Creating key pair '${KEY_NAME}'..."

  # Create key pair and save to file
  aws ec2 create-key-pair \
    --region "${region}" \
    --key-name "${KEY_NAME}" \
    --query 'KeyMaterial' \
    --output text > "${key_file}"

  chmod 600 "${key_file}"
  log_msg "INFO" "Key pair created and saved to ${key_file}"
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
  sg_id=$(aws ec2 describe-security-groups \
    --region "${region}" \
    --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "")

  if [[ -n "${sg_id}" ]] && [[ "${sg_id}" != "None" ]]; then
    log_msg "INFO" "Security group '${SECURITY_GROUP_NAME}' already exists: ${sg_id}"
    echo "${sg_id}"
    return
  fi

  log_msg "INFO" "Creating security group '${SECURITY_GROUP_NAME}'..."

  # Get default VPC
  local vpc_id
  vpc_id=$(aws ec2 describe-vpcs \
    --region "${region}" \
    --filters "Name=is-default,Values=true" \
    --query 'Vpcs[0].VpcId' \
    --output text)

  if [[ -z "${vpc_id}" ]] || [[ "${vpc_id}" == "None" ]]; then
    die "No default VPC found in ${region}"
  fi

  # Create security group
  sg_id=$(aws ec2 create-security-group \
    --region "${region}" \
    --group-name "${SECURITY_GROUP_NAME}" \
    --description "Security group for Appmotel PaaS" \
    --vpc-id "${vpc_id}" \
    --output text)

  # Add inbound rules
  # SSH (22)
  aws ec2 authorize-security-group-ingress \
    --region "${region}" \
    --group-id "${sg_id}" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 >/dev/null

  # HTTP (80)
  aws ec2 authorize-security-group-ingress \
    --region "${region}" \
    --group-id "${sg_id}" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0 >/dev/null

  # HTTPS (443)
  aws ec2 authorize-security-group-ingress \
    --region "${region}" \
    --group-id "${sg_id}" \
    --protocol tcp \
    --port 443 \
    --cidr 0.0.0.0/0 >/dev/null

  log_msg "INFO" "Security group created: ${sg_id}"
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
  instance_id=$(aws ec2 run-instances \
    --region "${region}" \
    --image-id "${ami_id}" \
    --instance-type "${instance_type}" \
    --key-name "${KEY_NAME}" \
    --security-group-ids "${sg_id}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

  log_msg "INFO" "Instance launched: ${instance_id}"
  log_msg "INFO" "Waiting for instance to be running..."

  aws ec2 wait instance-running \
    --region "${region}" \
    --instance-ids "${instance_id}"

  log_msg "INFO" "Instance is running"

  # Wait additional time for SSH to be ready
  log_msg "INFO" "Waiting for SSH to be ready (60 seconds)..."
  sleep 60

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
  public_ip=$(aws ec2 describe-instances \
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
  local max_attempts=30
  local attempt=0

  log_msg "INFO" "Waiting for SSH to be accessible..."

  while [[ ${attempt} -lt ${max_attempts} ]]; do
    if ssh -i "${key_file}" \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=5 \
           -o BatchMode=yes \
           "${SSH_USER}@${host}" \
           "echo 'SSH ready'" >/dev/null 2>&1; then
      log_msg "INFO" "SSH is ready"
      return 0
    fi

    attempt=$((attempt + 1))
    log_msg "INFO" "Attempt ${attempt}/${max_attempts}..."
    sleep 10
  done

  die "SSH did not become accessible after ${max_attempts} attempts"
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
      "${install_script}" \
      "${SSH_USER}@${host}:/tmp/install.sh"

  # Upload .env.default if it exists
  if [[ -f "${env_default}" ]]; then
    log_msg "INFO" "Uploading .env.default..."
    scp -i "${key_file}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "${env_default}" \
        "${SSH_USER}@${host}:/tmp/.env.default"
  fi

  log_msg "INFO" "Running system-level installation (as root)..."

  ssh -i "${key_file}" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
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
# -----------------------------------------------------------------------------
display_summary() {
  local host="$1"
  local key_file="$2"
  local instance_id="$3"
  local region="$4"

  log_msg "INFO" "======================================"
  log_msg "INFO" "Appmotel EC2 Installation Complete!"
  log_msg "INFO" "======================================"
  log_msg "INFO" ""
  log_msg "INFO" "Instance Details:"
  log_msg "INFO" "  Instance ID: ${instance_id}"
  log_msg "INFO" "  Region: ${region}"
  log_msg "INFO" "  Public IP: ${host}"
  log_msg "INFO" "  OS: Amazon Linux 2023"
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
  -h, --help                  Show this help message

Examples:
  # Launch with defaults (t4g.micro ARM instance in us-west-2)
  bash install-aws.sh

  # Launch specific instance type
  bash install-aws.sh --type t3.small

  # Launch in different region
  bash install-aws.sh --region us-east-1

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

  # Create key pair
  create_key_pair "${region}"
  local key_file="${HOME}/.ssh/${KEY_NAME}.pem"

  # Create security group
  local sg_id
  sg_id=$(create_security_group "${region}")

  # Launch instance
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

  # Display summary
  display_summary "${public_ip}" "${key_file}" "${instance_id}" "${region}"
}

# Execute main function
main "$@"

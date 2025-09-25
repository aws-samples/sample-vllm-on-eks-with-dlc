#!/bin/bash
set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration - allow region as user input
REGION=${1:-${AWS_REGION:-"us-west-2"}}
CLUSTER_NAME="vllm-cluster-west2"
NODEGROUP_NAME="vllm-g5-nodes-west2"

# Set AWS profile for all commands
export AWS_PROFILE=vllm-profile

echo "Using region: $REGION"
echo "Using AWS profile: $AWS_PROFILE"
echo "Usage: $0 [region] (default: us-west-2)"

# Helper function for retrying commands
retry_command() {
    local max_attempts=$1
    local delay=$2
    shift 2
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            echo "Command failed (attempt $attempt/$max_attempts). Retrying in ${delay}s..."
            sleep $delay
        fi
        
        attempt=$((attempt + 1))
    done
    
    echo "Command failed after $max_attempts attempts"
    return 1
}

print_header() {
    echo -e "${BLUE}"
    echo "=================================================="
    echo "  vLLM G5 Qwen 2.5-0.5B-Instruct Deployment"
    echo "=================================================="
    echo -e "${NC}"
}

print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_section "Step 5: Create FSx Lustre"

# Get VPC info
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

PRIVATE_AZ=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=false" \
  --query "Subnets[0].AvailabilityZone" --output text)

print_success "VPC ID: $VPC_ID"
print_success "Private AZ: $PRIVATE_AZ"

# Create security group for FSx
FSX_SG_ID=$(aws ec2 create-security-group --region "$REGION" \
  --group-name fsx-lustre-qwen-sg \
  --description "Security group for FSx Lustre (Qwen)" \
  --vpc-id $VPC_ID \
  --query "GroupId" --output text 2>/dev/null || \
  aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=fsx-lustre-qwen-sg" \
  --query "SecurityGroups[0].GroupId" --output text)

print_success "FSx Security Group: $FSX_SG_ID"

# Add security group rules
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id $FSX_SG_ID \
  --protocol tcp --port 988-1023 \
  --source-group $(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text) 2>/dev/null || true

aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id $FSX_SG_ID \
  --protocol tcp --port 988-1023 \
  --source-group $FSX_SG_ID 2>/dev/null || true

# Get subnet
SUBNET_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.resourcesVpcConfig.subnetIds[0]" --output text)

# Create FSx filesystem
FSX_ID=$(aws fsx create-file-system --region "$REGION" \
  --file-system-type LUSTRE \
  --storage-capacity 1200 \
  --subnet-ids $SUBNET_ID \
  --security-group-ids $FSX_SG_ID \
  --lustre-configuration DeploymentType=SCRATCH_2 \
  --tags Key=Name,Value=vllm-qwen-model-storage \
  --query "FileSystem.FileSystemId" --output text 2>/dev/null || \
  aws fsx describe-file-systems --region "$REGION" \
  --query "FileSystems[?Tags[?Key=='Name' && Value=='vllm-qwen-model-storage']].FileSystemId" \
  --output text | head -1)

print_success "FSx Filesystem: $FSX_ID"
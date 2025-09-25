#!/bin/bash
# Cleanup script for vLLM DeepSeek 2.5B CloudFormation deployment

set -e
set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
STACK_NAME=${1:-"vllm-deepseek-2-5b-stack"}
REGION=${2:-"us-west-2"}
PROFILE=${3:-"default"}

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

# Confirm with the user
echo -e "${RED}WARNING: This will delete the entire CloudFormation stack and all resources.${NC}"
echo -e "${RED}This action is irreversible and will result in data loss.${NC}"
read -p "Are you sure you want to proceed? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

# Set your variables
export AWS_PROFILE=vllm-profile
REGION=us-west-2
CLUSTER_NAME=vllm-cluster-west2

# 1. Delete Kubernetes resources
kubectl delete ingress vllm-qwen-25b-ingress -n vllm-production --ignore-not-found
kubectl delete deployment vllm-qwen-25b -n vllm-production --ignore-not-found
kubectl delete service vllm-qwen-25b-service -n vllm-production --ignore-not-found
kubectl delete pvc fsx-lustre-pvc --force --grace-period=0 -n vllm-production --ignore-not-found
kubectl delete pv fsx-lustre-pv --force --grace-period=0 --ignore-not-found
kubectl delete sc fsx-sc --ignore-not-found

# 2. Delete FSx filesystem
FSX_ID=$(aws fsx describe-file-systems --region "$REGION" \
  --query "FileSystems[?Tags[?Key=='Name' && Value=='vllm-qwen-model-storage']].FileSystemId" \
  --output text)
if [ -n "$FSX_ID" ]; then
  aws fsx delete-file-system --file-system-id "$FSX_ID" --region "$REGION"
fi

# 3. Delete EKS cluster (this will delete the CloudFormation stacks)
eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION"

echo "All resources have been deleted."
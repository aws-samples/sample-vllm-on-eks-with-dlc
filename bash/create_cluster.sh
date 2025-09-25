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

print_section "Checking for Target Cluster"
# Check if our target cluster exists
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null; then
    print_success "Found existing cluster: $CLUSTER_NAME in $REGION"
    SKIP_CLUSTER_CREATION=true
else
    print_success "Cluster $CLUSTER_NAME not found. Will create new cluster."
    SKIP_CLUSTER_CREATION=false
fi

if [ "$SKIP_CLUSTER_CREATION" != "true" ]; then
    print_section "Step 1: Creating EKS Cluster"
    echo "This will take 15-20 minutes..."
    
    # Create cluster config - simplified for better reliability
    cat > eks-cluster-manual.yaml << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: $CLUSTER_NAME
  region: $REGION
  version: "1.31"

# Simplified configuration for better reliability
iam:
  withOIDC: true

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
EOF

    print_section "Creating EKS cluster..."
    eksctl create cluster -f eks-cluster-manual.yaml
    
    # Verify cluster was created successfully
    if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" &>/dev/null; then
        print_success "EKS cluster created successfully"
    else
        print_error "EKS cluster creation failed"
        echo "Available clusters:"
        aws eks list-clusters --region "$REGION"
        exit 1
    fi
else
    print_section "Step 1: Using Existing EKS Cluster"
    print_success "Using existing cluster: $CLUSTER_NAME"
fi
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
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

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

print_section "Step 6: Install Controllers"

# Install FSx CSI Driver
helm repo add aws-fsx-csi-driver https://kubernetes-sigs.github.io/aws-fsx-csi-driver/ 2>/dev/null || true
helm repo update
helm upgrade --install aws-fsx-csi-driver aws-fsx-csi-driver/aws-fsx-csi-driver --namespace kube-system

# Install AWS Load Balancer Controller
eksctl utils associate-iam-oidc-provider --region $REGION --cluster $CLUSTER_NAME --approve

# Create IAM policy
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json 2>/dev/null || true

# Create service account
eksctl create iamserviceaccount \
  \
  --cluster $CLUSTER_NAME \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve

# Install controller
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update
kubectl apply -f https://raw.githubusercontent.com/aws/eks-charts/master/stable/aws-load-balancer-controller/crds/crds.yaml
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# Wait for AWS Load Balancer Controller to be ready
echo "Waiting for AWS Load Balancer Controller to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n kube-system

# Wait for webhook service to have endpoints
echo "Waiting for webhook service endpoints..."
for i in {1..30}; do
    if kubectl get endpoints aws-load-balancer-webhook-service -n kube-system &>/dev/null; then
        ENDPOINTS=$(kubectl get endpoints aws-load-balancer-webhook-service -n kube-system -o jsonpath='{.subsets[*].addresses[*].ip}')
        if [ -n "$ENDPOINTS" ]; then
            print_success "Webhook service has endpoints: $ENDPOINTS"
            break
        fi
    fi
    echo "Waiting for webhook endpoints... (attempt $i/30)"
    sleep 10
done

# Install LeaderWorkerSet
echo "Installing LeaderWorkerSet controller..."
helm upgrade --install lws oci://registry.k8s.io/lws/charts/lws \
  --version=0.6.1 \
  --namespace lws-system \
  --create-namespace \
  --wait --timeout 300s

print_success "All controllers installed"
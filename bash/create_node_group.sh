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

print_section "Step 2: Creating Node Group"

echo "Debug: Using cluster name: '$CLUSTER_NAME' in region: '$REGION'"

# Get VPC info
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

PRIVATE_AZ=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=false" \
  --query "Subnets[0].AvailabilityZone" --output text)

print_success "VPC ID: $VPC_ID"
print_success "Private AZ: $PRIVATE_AZ"

# Create nodegroup config
cat > nodegroup-manual.yaml << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: $CLUSTER_NAME
  region: $REGION

managedNodeGroups:
  - name: $NODEGROUP_NAME
    instanceTypes: ["g5.xlarge", "g5.2xlarge", "g5.4xlarge"]
    minSize: 0
    maxSize: 1
    desiredCapacity: 1
    availabilityZones: ["$PRIVATE_AZ"]
    volumeSize: 100
    privateNetworking: true
    ami: ami-01f1fc27c5979ac62
    amiFamily: AmazonLinux2
    labels:
      role: small-model-worker
      nvidia.com/gpu: "true"
      k8s.amazonaws.com/accelerator: nvidia-gpu
    tags:
      nodegroup-role: small-model-worker
    iam:
      withAddonPolicies:
        autoScaler: true
        albIngress: true
        cloudWatch: true
        ebs: true
        imageBuilder: true
    overrideBootstrapCommand: |
      #!/bin/bash
      set -ex
      /etc/eks/bootstrap.sh $CLUSTER_NAME --container-runtime containerd
EOF

# Check if nodegroup exists
if eksctl get nodegroup --cluster $CLUSTER_NAME --name $NODEGROUP_NAME --region $REGION &>/dev/null; then
    print_warning "Node group already exists"
else
    print_section "Creating node group..."
    print_warning "Using simplified nodegroup creation for better reliability..."
    
    eksctl create nodegroup \
      --cluster "$CLUSTER_NAME" \
      --region "$REGION" \
      --name "$NODEGROUP_NAME" \
      --instance-types g5.xlarge \
      --nodes 1 \
      --nodes-min 0 \
      --nodes-max 1 \
      --managed \
      --node-volume-size 100 \
      --node-ami-family AmazonLinux2
      
    print_success "Node group created"
fi

print_section "Step 3: Configure kubectl"
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION
print_success "kubectl configured"

print_section "Step 3.1: Label nodes for workload scheduling"
# Wait for nodes to be ready and then label them
echo "Waiting for nodes to be ready for labeling..."
kubectl wait --for=condition=Ready nodes --all --timeout=600s

# Get the node name and add required labels
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
if [ -n "$NODE_NAME" ]; then
    kubectl label node "$NODE_NAME" role=small-model-worker --overwrite
    print_success "Labeled node $NODE_NAME with role=small-model-worker"
else
    print_warning "Could not find node to label"
fi

print_section "Step 4: Verify GPU nodes and resources"

# Check node resources to ensure deployment will fit
echo "Checking node resources..."
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$NODE_NAME" ]; then
    ALLOCATABLE_CPU=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.allocatable.cpu}' 2>/dev/null || echo "0")
    ALLOCATABLE_MEMORY=$(kubectl get node "$NODE_NAME" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null || echo "0")
    echo "Node: $NODE_NAME"
    echo "Allocatable CPU: $ALLOCATABLE_CPU"
    echo "Allocatable Memory: $ALLOCATABLE_MEMORY"
    
    # Convert CPU to numeric for comparison (handle 'm' suffix)
    if [[ "$ALLOCATABLE_CPU" == *"m" ]]; then
        CPU_MILLICORES=${ALLOCATABLE_CPU%m}
        CPU_CORES=$((CPU_MILLICORES / 1000))
    else
        CPU_CORES=${ALLOCATABLE_CPU%.*}  # Remove decimal part
    fi
    
    if [ "$CPU_CORES" -lt 2 ]; then
        print_warning "Node has less than 2 CPU cores available. vLLM deployment may fail."
        echo "Consider using a larger instance type or reducing resource requests."
    else
        print_success "Node has sufficient resources for vLLM deployment"
    fi
fi

# First check if any nodes exist
echo "Checking for nodes..."
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")

if [ "$NODE_COUNT" -eq 0 ]; then
    print_warning "No nodes found. Node group may still be creating..."
    echo "Checking node group status..."
    
    # Check node group status
    NODEGROUP_STATUS=$(eksctl get nodegroup --cluster $CLUSTER_NAME --name $NODEGROUP_NAME --region $REGION -o json 2>/dev/null | jq -r '.[0].Status' 2>/dev/null || echo "UNKNOWN")
    echo "Node group status: $NODEGROUP_STATUS"
    
    if [ "$NODEGROUP_STATUS" = "CREATING" ]; then
        echo "Node group is still creating. This can take 10-15 minutes..."
        echo "Waiting for node group to be ready..."
        
        # Wait for node group to be active
        while true; do
            STATUS=$(eksctl get nodegroup --cluster $CLUSTER_NAME --name $NODEGROUP_NAME --region $REGION -o json 2>/dev/null | jq -r '.[0].Status' 2>/dev/null || echo "UNKNOWN")
            echo "Node group status: $STATUS"
            
            if [ "$STATUS" = "ACTIVE" ]; then
                print_success "Node group is active"
                break
            elif [ "$STATUS" = "CREATE_FAILED" ] || [ "$STATUS" = "DELETE_FAILED" ]; then
                print_error "Node group creation failed with status: $STATUS"
                echo "Check the AWS Console for detailed error information"
                exit 1
            fi
            
            sleep 30
        done
    elif [ "$NODEGROUP_STATUS" = "ACTIVE" ]; then
        print_success "Node group is active, waiting for nodes to register with kubectl..."
    else
        print_error "Node group status is $NODEGROUP_STATUS"
        echo "Please check the AWS Console for node group issues"
        exit 1
    fi
fi

# Now wait for nodes to be ready
echo "Waiting for nodes to register with kubectl..."
echo "This can take 5-10 minutes after node group becomes ACTIVE..."

for i in {1..30}; do
    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$NODE_COUNT" -gt 0 ]; then
        print_success "Found $NODE_COUNT node(s)"
        kubectl get nodes
        break
    fi
    echo "Waiting for nodes to appear in kubectl... (attempt $i/30)"
    
    # Show some debug info every 5 attempts
    if [ $((i % 5)) -eq 0 ]; then
        echo "Debug: Checking node group instances..."
        aws ec2 describe-instances \
            --filters "Name=tag:eks:nodegroup-name,Values=$NODEGROUP_NAME" \
            --query "Reservations[*].Instances[*].[InstanceId,State.Name,PrivateIpAddress]" \
            --output table 2>/dev/null || echo "No instances found yet"
    fi
    
    sleep 20
done

if [ "$NODE_COUNT" -eq 0 ]; then
    print_error "No nodes found after waiting. Check node group in AWS Console"
    exit 1
fi

# Wait for nodes to be ready
kubectl wait --for=condition=Ready nodes --all --timeout=600s

echo "Checking GPU availability..."
kubectl get nodes -o json | jq '.items[].status.capacity."nvidia.com/gpu"' 2>/dev/null || echo "GPU info not available yet"

print_success "Nodes are ready"
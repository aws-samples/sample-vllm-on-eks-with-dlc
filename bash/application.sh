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
NAMESPACE="vllm-production"

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

print_section "Step 7: Deploy vLLM"

# Create namespace if it doesn't exist
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
print_success "Namespace $NAMESPACE ready"

# Wait for FSx to be available with timeout
echo "Waiting for FSx to be available (this can take 5-10 minutes)..."
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

PRIVATE_AZ=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=false" \
  --query "Subnets[0].AvailabilityZone" --output text)

FSX_ID=$(aws fsx describe-file-systems --region "$REGION" \
  --query "FileSystems[?Tags[?Key=='Name' && Value=='vllm-qwen-model-storage']].FileSystemId" \
  --output text)

FSX_WAIT_COUNT=0
FSX_MAX_WAIT=40  # 20 minutes max
while true; do
    STATUS=$(aws fsx describe-file-systems --region "$REGION" --file-system-id $FSX_ID \
        --query "FileSystems[0].Lifecycle" --output text 2>/dev/null || echo "UNKNOWN")
    echo "FSx status: $STATUS (waited $((FSX_WAIT_COUNT * 30))s)"
    
    if [ "$STATUS" = "AVAILABLE" ]; then
        print_success "FSx filesystem is ready"
        break
    elif [ "$STATUS" = "FAILED" ] || [ "$STATUS" = "MISCONFIGURED" ]; then
        print_error "FSx filesystem creation failed with status: $STATUS"
        echo "Check the AWS Console for detailed error information"
        exit 1
    fi
    
    FSX_WAIT_COUNT=$((FSX_WAIT_COUNT + 1))
    if [ $FSX_WAIT_COUNT -ge $FSX_MAX_WAIT ]; then
        print_error "FSx filesystem not ready after 20 minutes"
        echo "Current status: $STATUS"
        echo "Check the AWS Console for issues"
        exit 1
    fi
    
    sleep 30
done

# Get FSx details
FSX_DNS=$(aws fsx describe-file-systems --region "$REGION" --file-system-id $FSX_ID \
  --query "FileSystems[0].DNSName" --output text)
FSX_MOUNT=$(aws fsx describe-file-systems --region "$REGION" --file-system-id $FSX_ID \
  --query "FileSystems[0].LustreConfiguration.MountName" --output text)

# Create a simple Deployment instead of LeaderWorkerSet to avoid API issues
cat > vllm-qwen-25b-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-qwen-25b
  namespace: vllm-production
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-qwen-25b
  template:
    metadata:
      labels:
        app: vllm-qwen-25b
        role: leader
    spec:
      containers:
        - name: vllm-server
          image: 763104351884.dkr.ecr.us-east-1.amazonaws.com/vllm:0.8.5-gpu-py312-ec2
          securityContext:
            privileged: false
            capabilities:
              add: ["IPC_LOCK"]
          env:
            - name: TRANSFORMERS_CACHE
              value: "/mnt/fsx/models"
            - name: HF_HOME
              value: "/mnt/fsx/models"
          command: ["/bin/bash"]
          args:
            - "-c"
            - |
              set -x
              
              # Start vllm server directly (no Ray needed for single node)
              python -m vllm.entrypoints.openai.api_server \
                --model Qwen/Qwen2.5-0.5B-Instruct \
                --host 0.0.0.0 \
                --port 8000 \
                --tensor-parallel-size 1 \
                --download-dir /mnt/fsx/models \
                --max-model-len 8192 \
                --gpu-memory-utilization 0.85
          resources:
            limits:
              nvidia.com/gpu: "1"
              cpu: "2"
              memory: "8Gi"
            requests:
              nvidia.com/gpu: "1"
              cpu: "2"
              memory: "8Gi"
          ports:
            - containerPort: 8000
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 120
            periodSeconds: 30
            timeoutSeconds: 10
            successThreshold: 1
            failureThreshold: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 180
            periodSeconds: 60
            timeoutSeconds: 10
            failureThreshold: 3
          volumeMounts:
            - name: fsx-lustre-volume
              mountPath: /mnt/fsx
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: fsx-lustre-volume
          persistentVolumeClaim:
            claimName: fsx-lustre-pvc
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: "4Gi"
      nodeSelector:
        role: small-model-worker
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-qwen-25b-service
  namespace: vllm-production
spec:
  ports:
    - name: http
      port: 8000
      targetPort: 8000
  type: ClusterIP
  selector:
    app: vllm-qwen-25b
EOF

# Update the files with actual values
# Check if running on macOS
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS version
    sed -i '' "s|<subnet-id>|$SUBNET_ID|g" fsx-storage-class.yaml
    sed -i '' "s|<sg-id>|$FSX_SG_ID|g" fsx-storage-class.yaml
    sed -i '' "s|<fs-id>|$FSX_ID|g" fsx-lustre-pv.yaml
    sed -i '' "s|<fs-id>.fsx.us-west-2.amazonaws.com|$FSX_DNS|g" fsx-lustre-pv.yaml
    sed -i '' "s|<mount-name>|$FSX_MOUNT|g" fsx-lustre-pv.yaml
else
    # Linux version
    sed -i "s|<subnet-id>|$SUBNET_ID|g" fsx-storage-class.yaml
    sed -i "s|<sg-id>|$FSX_SG_ID|g" fsx-storage-class.yaml
    sed -i "s|<fs-id>|$FSX_ID|g" fsx-lustre-pv.yaml
    sed -i "s|<fs-id>.fsx.us-west-2.amazonaws.com|$FSX_DNS|g" fsx-lustre-pv.yaml
    sed -i "s|<mount-name>|$FSX_MOUNT|g" fsx-lustre-pv.yaml
fi

# Clean up any existing resources first
echo "Cleaning up any existing FSx resources..."
kubectl delete pvc fsx-lustre-pvc -n $NAMESPACE --ignore-not-found
kubectl delete pv fsx-lustre-pv --ignore-not-found
kubectl delete sc fsx-sc --ignore-not-found

# Wait a moment for cleanup
sleep 5

# Apply resources
kubectl apply -f fsx-storage-class.yaml
kubectl apply -f fsx-lustre-pv.yaml
kubectl apply -f fsx-lustre-pvc.yaml -n $NAMESPACE
# Clean up any existing failed deployments and ALBs
echo "Cleaning up any existing resources..."
kubectl delete deployment vllm-qwen-25b -n $NAMESPACE --ignore-not-found
kubectl delete pods -l app=vllm-qwen-25b -n $NAMESPACE --field-selector=status.phase=Pending --ignore-not-found
kubectl delete ingress vllm-qwen-25b-ingress -n $NAMESPACE --ignore-not-found

# Wait for cleanup
sleep 10

# Apply the deployment
kubectl apply -f vllm-qwen-25b-deployment.yaml -n $NAMESPACE

print_success "vLLM deployed"

# Wait for pod to start and monitor progress
echo "Waiting for vLLM pod to start (this may take 10-15 minutes)..."
echo "The pod will go through: Pending -> ContainerCreating -> Running -> Ready"

# Wait for pod to be scheduled with better error handling
if ! kubectl wait --for=condition=PodScheduled pod -l app=vllm-qwen-25b -n $NAMESPACE --timeout=300s 2>/dev/null; then
    print_warning "Pod scheduling is taking longer than expected"
    echo "Checking for scheduling issues..."
    kubectl describe pods -l app=vllm-qwen-25b -n $NAMESPACE | grep -A 10 "Events:"
fi

# Wait for pod to be ready
echo "Waiting for vLLM to be ready (downloading model and starting server)..."
if kubectl wait --for=condition=Ready pod -l app=vllm-qwen-25b -n $NAMESPACE --timeout=900s; then
    print_success "vLLM pod is ready!"
else
    print_warning "vLLM pod is taking longer than expected to be ready"
    echo "Current pod status:"
    kubectl get pods -l app=vllm-qwen-25b -n $NAMESPACE
    echo "Pod logs (last 20 lines):"
    kubectl logs -l app=vllm-qwen-25b -n $NAMESPACE --tail=20 2>/dev/null || echo "No logs available yet"
fi

# Show current status
kubectl get pods -l app=vllm-qwen-25b -n $NAMESPACE

print_section "Step 8: Create ALB Ingress"

# Get your public IP for security
USER_IP=$(curl -s https://checkip.amazonaws.com || echo "0.0.0.0")
if [ "$USER_IP" = "0.0.0.0" ]; then
    ALLOWED_CIDR="0.0.0.0/0"
    print_warning "Could not get your IP, using 0.0.0.0/0 (less secure)"
else
    ALLOWED_CIDR="${USER_IP}/32"
    print_success "Restricting ALB access to your IP: $ALLOWED_CIDR"
fi

# Create security group for ALB
ALB_SG=$(aws ec2 create-security-group \
  --group-name vllm-qwen-alb-sg \
  --description "Security group for vLLM Qwen ALB" \
  --vpc-id $VPC_ID \
  --query "GroupId" --output text 2>/dev/null || \
  aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=vllm-qwen-alb-sg" \
  --query "SecurityGroups[0].GroupId" --output text)

print_success "ALB Security Group: $ALB_SG"

# Add ALB security group rules
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG \
  --protocol tcp \
  --port 80 \
  --cidr $ALLOWED_CIDR 2>/dev/null || true

# Get node security group and allow ALB access
NODE_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:eks:nodegroup-name,Values=$NODEGROUP_NAME" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

NODE_SG=$(aws ec2 describe-instances \
  --instance-ids $NODE_INSTANCE_ID \
  --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

# Allow ALB to reach nodes on port 8000
aws ec2 authorize-security-group-ingress \
  --group-id $NODE_SG \
  --protocol tcp \
  --port 8000 \
  --source-group $ALB_SG 2>/dev/null || true

print_success "Security groups configured"

# Create ALB ingress
cat > vllm-alb-ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vllm-qwen-25b-ingress
  namespace: vllm-production
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/security-groups: $ALB_SG
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/healthcheck-port: '8000'
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
    alb.ingress.kubernetes.io/load-balancer-attributes: load_balancing.cross_zone.enabled=true
    kubernetes.io/ingress.class: alb
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: vllm-qwen-25b-service
            port:
              number: 8000
EOF

kubectl apply -f vllm-alb-ingress.yaml -n $NAMESPACE
print_success "ALB ingress created"

print_section "Waiting for ALB to be ready"
echo "This may take 2-5 minutes..."

# Wait for ingress to get an endpoint
for i in {1..30}; do
    ENDPOINT=$(kubectl get ingress vllm-qwen-25b-ingress -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$ENDPOINT" ]; then
        print_success "ALB endpoint ready: $ENDPOINT"
        break
    fi
    echo "Waiting for ALB endpoint... (attempt $i/30)"
    sleep 10
done

if [ -z "$ENDPOINT" ]; then
    print_warning "ALB endpoint not ready yet. Check with: kubectl get ingress vllm-qwen-25b-ingress -n $NAMESPACE"
    ENDPOINT="<pending>"
fi

print_section "Testing ALB Endpoint"

# Find the correct ALB endpoint
echo "Detecting ALB endpoints..."
ALB_ENDPOINTS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'LoadBalancers[?contains(LoadBalancerName, `k8s-vllmprod-vllmqwen`)].DNSName' \
  --output text 2>/dev/null || echo "")

if [ -z "$ALB_ENDPOINTS" ]; then
    print_warning "No ALB endpoints found. Checking ingress status..."
    kubectl get ingress vllm-qwen-25b-ingress -n $NAMESPACE
    ENDPOINT="<pending>"
else
    # Test each endpoint to find the working one
    WORKING_ENDPOINT=""
    for endpoint in $ALB_ENDPOINTS; do
        echo "Testing endpoint: $endpoint"
        if curl -s --max-time 10 "http://$endpoint/health" >/dev/null 2>&1; then
            WORKING_ENDPOINT="$endpoint"
            print_success "Found working endpoint: $endpoint"
            break
        else
            echo "Endpoint $endpoint not responding yet"
        fi
    done
    
    if [ -n "$WORKING_ENDPOINT" ]; then
        ENDPOINT="$WORKING_ENDPOINT"
        
        # Test the API
        echo "Testing vLLM API..."
        API_TEST=$(curl -s --max-time 30 -X POST "http://$ENDPOINT/v1/completions" \
          -H "Content-Type: application/json" \
          -d '{
              "model": "Qwen/Qwen2.5-0.5B-Instruct",
              "prompt": "Hello",
              "max_tokens": 10,
              "temperature": 0.7
          }' 2>/dev/null || echo "")
        
        if echo "$API_TEST" | grep -q "choices"; then
            print_success "vLLM API is working correctly!"
        else
            print_warning "vLLM API test failed. The service might still be starting up."
            echo "Wait a few more minutes and test manually."
        fi
    else
        ENDPOINT=$(echo $ALB_ENDPOINTS | awk '{print $1}')
        print_warning "ALB endpoints found but not responding yet. This is normal for new deployments."
        echo "Wait 2-5 minutes for ALB to be fully ready."
    fi
fi

print_section "Deployment Complete!"
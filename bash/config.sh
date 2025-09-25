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

# Auto-install missing dependencies
install_dependencies() {
    print_section "Checking and Installing Dependencies"
    
    # Detect OS
    OS=$(uname -s)
    ARCH=$(uname -m)
    
    # Check and install eksctl
    if ! command -v eksctl &> /dev/null; then
        print_warning "eksctl not found. Installing..."
        if [[ "$OS" == "Darwin" ]]; then
            # macOS
            if command -v brew &> /dev/null; then
                brew tap weaveworks/tap && brew install weaveworks/tap/eksctl
            else
                print_error "Homebrew not found. Please install Homebrew first:"
                echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                exit 1
            fi
        elif [[ "$OS" == "Linux" ]]; then
            # Linux
            curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_${OS}_amd64.tar.gz" | tar xz -C /tmp
            sudo mv /tmp/eksctl /usr/local/bin
            chmod +x /usr/local/bin/eksctl
        else
            print_error "Unsupported OS: $OS"
            exit 1
        fi
        print_success "eksctl installed successfully"
    else
        print_success "eksctl already installed"
    fi
    
    # Check and install kubectl
    if ! command -v kubectl &> /dev/null; then
        print_warning "kubectl not found. Installing..."
        if [[ "$OS" == "Darwin" ]]; then
            # macOS
            if command -v brew &> /dev/null; then
                brew install kubectl
            else
                curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
                chmod +x kubectl && sudo mv kubectl /usr/local/bin/
            fi
        elif [[ "$OS" == "Linux" ]]; then
            # Linux
            curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
            chmod +x kubectl && sudo mv kubectl /usr/local/bin/
        fi
        print_success "kubectl installed successfully"
    else
        print_success "kubectl already installed"
    fi
    
    # Check and install helm
    if ! command -v helm &> /dev/null; then
        print_warning "helm not found. Installing..."
        if [[ "$OS" == "Darwin" ]]; then
            # macOS
            if command -v brew &> /dev/null; then
                brew install helm
            else
                curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            fi
        elif [[ "$OS" == "Linux" ]]; then
            # Linux
            curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        fi
        print_success "helm installed successfully"
    else
        print_success "helm already installed"
    fi
    
    # Check and install jq
    if ! command -v jq &> /dev/null; then
        print_warning "jq not found. Installing..."
        if [[ "$OS" == "Darwin" ]]; then
            # macOS
            if command -v brew &> /dev/null; then
                brew install jq
            else
                print_error "Please install Homebrew to auto-install jq, or install jq manually"
                exit 1
            fi
        elif [[ "$OS" == "Linux" ]]; then
            # Linux - try different package managers
            if command -v apt-get &> /dev/null; then
                sudo apt-get update && sudo apt-get install -y jq
            elif command -v yum &> /dev/null; then
                sudo yum install -y jq
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y jq
            else
                print_error "Could not install jq automatically. Please install jq manually"
                exit 1
            fi
        fi
        print_success "jq installed successfully"
    else
        print_success "jq already installed"
    fi
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not found. Please install AWS CLI manually:"
        if [[ "$OS" == "Darwin" ]]; then
            echo "  macOS: brew install awscli"
            echo "  Or download from: https://awscli.amazonaws.com/AWSCLIV2.pkg"
        elif [[ "$OS" == "Linux" ]]; then
            echo "  Linux: curl \"https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip\" -o \"awscliv2.zip\""
            echo "         unzip awscliv2.zip && sudo ./aws/install"
        fi
        exit 1
    else
        print_success "AWS CLI already installed"
    fi
    
    # Verify all tools are working
    print_section "Verifying Tool Versions"
    eksctl version --output json | jq -r '.GitTag' | sed 's/^/eksctl: /'
    kubectl version --client --output json | jq -r '.clientVersion.gitVersion' | sed 's/^/kubectl: /'
    helm version --short | sed 's/^/helm: /'
    jq --version | sed 's/^/jq: /'
    aws --version | sed 's/^/aws: /'
}

print_header

print_section "Checking Prerequisites"
install_dependencies

# Validate AWS profile and credentials
print_section "Validating AWS Configuration"

# Check if the specified profile exists
if ! aws configure list-profiles 2>/dev/null | grep -q "^${AWS_PROFILE}$"; then
    print_warning "AWS profile '$AWS_PROFILE' not found"
    echo "Available profiles:"
    aws configure list-profiles 2>/dev/null || echo "No profiles found"
    echo
    
    # Offer to create the profile
    read -p "Would you like to create the '$AWS_PROFILE' profile now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_section "Creating AWS Profile: $AWS_PROFILE"
        aws configure --profile $AWS_PROFILE
        print_success "Profile '$AWS_PROFILE' created"
    else
        echo "You can either:"
        echo "1. Create the profile: aws configure --profile $AWS_PROFILE"
        echo "2. Use a different profile: export AWS_PROFILE=your-existing-profile"
        echo "3. Use default profile: export AWS_PROFILE=default"
        exit 1
    fi
fi

# Test the profile
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    print_error "AWS profile '$AWS_PROFILE' exists but credentials are invalid"
    echo "Please reconfigure: aws configure --profile $AWS_PROFILE"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CURRENT_REGION=$(aws configure get region 2>/dev/null || echo "not-set")
print_success "AWS Account: $ACCOUNT_ID"
print_success "AWS Profile: $AWS_PROFILE"
print_success "Target Region: $REGION"
if [ "$CURRENT_REGION" != "$REGION" ]; then
    print_warning "Profile default region ($CURRENT_REGION) differs from target region ($REGION)"
    echo "This is OK - using target region $REGION for all operations"
fi

# Check for required files
print_section "Checking Required Files"
REQUIRED_FILES=(
    "iam-policy.json"
    "fsx-storage-class.yaml"
    "fsx-lustre-pv.yaml"
    "fsx-lustre-pvc.yaml"
)

MISSING_FILES=()
for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$file" ]]; then
        MISSING_FILES+=("$file")
        print_error "Missing required file: $file"
    else
        print_success "Found: $file"
    fi
done

if [[ ${#MISSING_FILES[@]} -gt 0 ]]; then
    print_error "Missing ${#MISSING_FILES[@]} required files"
    echo
    echo "Please ensure you have the complete project files before running this script."
    exit 1
fi
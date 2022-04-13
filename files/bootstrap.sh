#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit

err_report() {
    echo "Exited with error on line $1"
}
trap 'err_report $LINENO' ERR

IFS=$'\n\t'

function print_help {
    echo "usage: $0 [options] <cluster-name>"
    echo "Bootstraps an instance into an EKS cluster"
    echo ""
    echo "-h,--help print this help"
    echo "--use-max-pods Sets --max-pods for the kubelet when true. (default: true)"
    echo "--b64-cluster-ca The base64 encoded cluster CA content. Only valid when used with --apiserver-endpoint. Bypasses calling \"aws eks describe-cluster\""
    echo "--apiserver-endpoint The EKS cluster API Server endpoint. Only valid when used with --b64-cluster-ca. Bypasses calling \"aws eks describe-cluster\""
    echo "--kubelet-extra-args Extra arguments to add to the kubelet. Useful for adding labels or taints."
    echo "--enable-docker-bridge Restores the docker default bridge network. (default: false)"
    echo "--aws-api-retry-attempts Number of retry attempts for AWS API call (DescribeCluster) (default: 3)"
    echo "--docker-config-json The contents of the /etc/docker/daemon.json file. Useful if you want a custom config differing from the default one in the AMI"
    echo "--dns-cluster-ip Overrides the IP address to use for DNS queries within the cluster. Defaults to 10.100.0.10 or 172.20.0.10 based on the IP address of the primary interface"
    echo "--pause-container-account The AWS account (number) to pull the pause container from"
    echo "--pause-container-version The tag of the pause container"
    echo "--container-runtime Specify a container runtime (default: dockerd)"
    echo "--ip-family Specify ip family of the cluster"
    echo "--service-ipv6-cidr ipv6 cidr range of the cluster"
}

POSITIONAL=()

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help)
            print_help
            exit 1
            ;;
        --use-max-pods)
            USE_MAX_PODS="$2"
            shift
            shift
            ;;
        --b64-cluster-ca)
            B64_CLUSTER_CA=$2
            shift
            shift
            ;;
        --apiserver-endpoint)
            APISERVER_ENDPOINT=$2
            shift
            shift
            ;;
        --kubelet-extra-args)
            KUBELET_EXTRA_ARGS=$2
            shift
            shift
            ;;
        --enable-docker-bridge)
            ENABLE_DOCKER_BRIDGE=$2
            shift
            shift
            ;;
        --aws-api-retry-attempts)
            API_RETRY_ATTEMPTS=$2
            shift
            shift
            ;;
        --docker-config-json)
            DOCKER_CONFIG_JSON=$2
            shift
            shift
            ;;
        --pause-container-account)
            PAUSE_CONTAINER_ACCOUNT=$2
            shift
            shift
            ;;
        --pause-container-version)
            PAUSE_CONTAINER_VERSION=$2
            shift
            shift
            ;;
        --dns-cluster-ip)
            DNS_CLUSTER_IP=$2
            shift
            shift
            ;;
        --container-runtime)
            CONTAINER_RUNTIME=$2
            shift
            shift
            ;;
        --ip-family)
            IP_FAMILY=$2
            shift
            shift
            ;;
        --service-ipv6-cidr)
            SERVICE_IPV6_CIDR=$2
            shift
            shift
            ;;
        *)    # unknown option
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
            ;;
    esac
done

set +u
set -- "${POSITIONAL[@]}" # restore positional parameters
CLUSTER_NAME="$1"
set -u

USE_MAX_PODS="${USE_MAX_PODS:-true}"
B64_CLUSTER_CA="${B64_CLUSTER_CA:-}"
APISERVER_ENDPOINT="${APISERVER_ENDPOINT:-}"
SERVICE_IPV4_CIDR="${SERVICE_IPV4_CIDR:-}"
DNS_CLUSTER_IP="${DNS_CLUSTER_IP:-}"
KUBELET_EXTRA_ARGS="${KUBELET_EXTRA_ARGS:-}"
ENABLE_DOCKER_BRIDGE="${ENABLE_DOCKER_BRIDGE:-false}"
API_RETRY_ATTEMPTS="${API_RETRY_ATTEMPTS:-3}"
DOCKER_CONFIG_JSON="${DOCKER_CONFIG_JSON:-}"
PAUSE_CONTAINER_VERSION="${PAUSE_CONTAINER_VERSION:-3.1-eksbuild.1}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-dockerd}"
IP_FAMILY="${IP_FAMILY:-}"
SERVICE_IPV6_CIDR="${SERVICE_IPV6_CIDR:-}"

function get_pause_container_account_for_region () {
    local region="$1"
    case "${region}" in
    ap-east-1)
        echo "${PAUSE_CONTAINER_ACCOUNT:-800184023465}";;
    me-south-1)
        echo "${PAUSE_CONTAINER_ACCOUNT:-558608220178}";;
    cn-north-1)
        echo "${PAUSE_CONTAINER_ACCOUNT:-918309763551}";;
    cn-northwest-1)
        echo "${PAUSE_CONTAINER_ACCOUNT:-961992271922}";;
    us-gov-west-1)
        echo "${PAUSE_CONTAINER_ACCOUNT:-013241004608}";;
    us-gov-east-1)
        echo "${PAUSE_CONTAINER_ACCOUNT:-151742754352}";;
    us-iso-east-1)
        echo "${PAUSE_CONTAINER_ACCOUNT:-725322719131}";;
    us-isob-east-1)
        echo "${PAUSE_CONTAINER_ACCOUNT:-187977181151}";;
    af-south-1)
        echo "${PAUSE_CONTAINER_ACCOUNT:-877085696533}";;
    eu-south-1)
        echo "${PAUSE_CONTAINER_ACCOUNT:-590381155156}";;
    ap-southeast-3)
        echo "${PAUSE_CONTAINER_ACCOUNT:-296578399912}";;
    *)
        echo "${PAUSE_CONTAINER_ACCOUNT:-602401143452}";;
    esac
}

function _get_token() {
  local token_result=
  local http_result=

  token_result=$(curl -s -w "\n%{http_code}" -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 600" "http://169.254.169.254/latest/api/token")
  http_result=$(echo "$token_result" | tail -n 1)
  if [[ "$http_result" != "200" ]]
  then
      echo -e "Failed to get token:\n$token_result"
      return 1
  else
      echo "$token_result" | head -n 1
      return 0
  fi
}

function get_token() {
  local token=
  local retries=20
  local result=1

  while [[ retries -gt 0 && $result -ne 0 ]]
  do
    retries=$[$retries-1]
    token=$(_get_token)
    result=$?
    [[ $result != 0 ]] && sleep 5
  done
  [[ $result == 0 ]] && echo "$token"
  return $result
}

function _get_meta_data() {
  local path=$1
  local metadata_result=

  metadata_result=$(curl -s -w "\n%{http_code}" -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/$path)
  http_result=$(echo "$metadata_result" | tail -n 1)
  if [[ "$http_result" != "200" ]]
  then
      echo -e "Failed to get metadata:\n$metadata_result\nhttp://169.254.169.254/$path\n$TOKEN"
      return 1
  else
      local lines=$(echo "$metadata_result" | wc -l)
      echo "$metadata_result" | head -n $(( lines - 1 ))
      return 0
  fi
}

function get_meta_data() {
  local metadata=
  local path=$1
  local retries=20
  local result=1

  while [[ retries -gt 0 && $result -ne 0 ]]
  do
    retries=$[$retries-1]
    metadata=$(_get_meta_data $path)
    result=$?
    [[ $result != 0 ]] && TOKEN=$(get_token)
  done
  [[ $result == 0 ]] && echo "$metadata"
  return $result
}

# Helper function which calculates the amount of the given resource (either CPU or memory)
# to reserve in a given resource range, specified by a start and end of the range and a percentage
# of the resource to reserve. Note that we return zero if the start of the resource range is
# greater than the total resource capacity on the node. Additionally, if the end range exceeds the total
# resource capacity of the node, we use the total resource capacity as the end of the range.
# Args:
#   $1 total available resource on the worker node in input unit (either millicores for CPU or Mi for memory)
#   $2 start of the resource range in input unit
#   $3 end of the resource range in input unit
#   $4 percentage of range to reserve in percent*100 (to allow for two decimal digits)
# Return:
#   amount of resource to reserve in input unit
get_resource_to_reserve_in_range() {
  local total_resource_on_instance=$1
  local start_range=$2
  local end_range=$3
  local percentage=$4
  resources_to_reserve="0"
  if (( $total_resource_on_instance > $start_range )); then
    resources_to_reserve=$(((($total_resource_on_instance < $end_range ? \
        $total_resource_on_instance : $end_range) - $start_range) * $percentage / 100 / 100))
  fi
  echo $resources_to_reserve
}

# Calculates the amount of memory to reserve for kubeReserved in mebibytes. KubeReserved is a function of pod
# density so we are calculating the amount of memory to reserve for Kubernetes systems daemons by
# considering the maximum number of pods this instance type supports.
# Args:
#   $1 the max number of pods per instance type (MAX_PODS) based on values from /etc/eks/eni-max-pods.txt
# Return:
#   memory to reserve in Mi for the kubelet
get_memory_mebibytes_to_reserve() {
  local max_num_pods=$1
  memory_to_reserve=$((11 * $max_num_pods + 255))
  echo $memory_to_reserve
}

# Calculates the amount of CPU to reserve for kubeReserved in millicores from the total number of vCPUs available on the instance.
# From the total core capacity of this worker node, we calculate the CPU resources to reserve by reserving a percentage
# of the available cores in each range up to the total number of cores available on the instance.
# We are using these CPU ranges from GKE (https://cloud.google.com/kubernetes-engine/docs/concepts/cluster-architecture#node_allocatable):
# 6% of the first core
# 1% of the next core (up to 2 cores)
# 0.5% of the next 2 cores (up to 4 cores)
# 0.25% of any cores above 4 cores
# Return:
#   CPU resources to reserve in millicores (m)
get_cpu_millicores_to_reserve() {
  local total_cpu_on_instance=$(($(nproc) * 1000))
  local cpu_ranges=(0 1000 2000 4000 $total_cpu_on_instance)
  local cpu_percentage_reserved_for_ranges=(600 100 50 25)
  cpu_to_reserve="0"
  for i in ${!cpu_percentage_reserved_for_ranges[@]}; do
    local start_range=${cpu_ranges[$i]}
    local end_range=${cpu_ranges[(($i+1))]}
    local percentage_to_reserve_for_range=${cpu_percentage_reserved_for_ranges[$i]}
    cpu_to_reserve=$(($cpu_to_reserve + \
        $(get_resource_to_reserve_in_range $total_cpu_on_instance $start_range $end_range $percentage_to_reserve_for_range)))
  done
  echo $cpu_to_reserve
}

if [ -z "$CLUSTER_NAME" ]; then
    echo "CLUSTER_NAME is not defined"
    exit  1
fi

if [[ ! -z "${IP_FAMILY}" ]]; then
  IP_FAMILY="$(tr [A-Z] [a-z] <<< "$IP_FAMILY")"
  if [[ "${IP_FAMILY}" != "ipv4" ]] && [[ "${IP_FAMILY}" != "ipv6" ]] ; then
        echo "Invalid IpFamily. Only ipv4 or ipv6 are allowed"
        exit 1
  fi
fi

if [[ ! -z "${SERVICE_IPV6_CIDR}" ]]; then
     if [[ "${IP_FAMILY}" == "ipv4" ]]; then
            echo "ip-family should be ipv6 when service-ipv6-cidr is specified"
            exit 1
      fi
      IP_FAMILY="ipv6"
fi

TOKEN=$(get_token)
AWS_DEFAULT_REGION=$(get_meta_data 'latest/dynamic/instance-identity/document' | jq .region -r)
AWS_SERVICES_DOMAIN=$(get_meta_data '2018-09-24/meta-data/services/domain')

MACHINE=$(uname -m)
if [[ "$MACHINE" != "x86_64" && "$MACHINE" != "aarch64" ]]; then
    echo "Unknown machine architecture '$MACHINE'" >&2
    exit 1
fi

PAUSE_CONTAINER_ACCOUNT=$(get_pause_container_account_for_region "${AWS_DEFAULT_REGION}")
PAUSE_CONTAINER_IMAGE=${PAUSE_CONTAINER_IMAGE:-$PAUSE_CONTAINER_ACCOUNT.dkr.ecr.$AWS_DEFAULT_REGION.$AWS_SERVICES_DOMAIN/eks/pause}
PAUSE_CONTAINER="$PAUSE_CONTAINER_IMAGE:$PAUSE_CONTAINER_VERSION"

### kubelet kubeconfig

CA_CERTIFICATE_DIRECTORY=/etc/kubernetes/pki
CA_CERTIFICATE_FILE_PATH=$CA_CERTIFICATE_DIRECTORY/ca.crt
mkdir -p $CA_CERTIFICATE_DIRECTORY
if [[ -z "${B64_CLUSTER_CA}" ]] || [[ -z "${APISERVER_ENDPOINT}" ]]; then
    DESCRIBE_CLUSTER_RESULT="/tmp/describe_cluster_result.txt"

    # Retry the DescribeCluster API for API_RETRY_ATTEMPTS
    for attempt in `seq 0 $API_RETRY_ATTEMPTS`; do
        rc=0
        if [[ $attempt -gt 0 ]]; then
            echo "Attempt $attempt of $API_RETRY_ATTEMPTS"
        fi

        aws eks wait cluster-active \
            --region=${AWS_DEFAULT_REGION} \
            --name=${CLUSTER_NAME}

        aws eks describe-cluster \
            --region=${AWS_DEFAULT_REGION} \
            --name=${CLUSTER_NAME} \
            --output=text \
            --query 'cluster.{certificateAuthorityData: certificateAuthority.data, endpoint: endpoint, serviceIpv4Cidr: kubernetesNetworkConfig.serviceIpv4Cidr, serviceIpv6Cidr: kubernetesNetworkConfig.serviceIpv6Cidr, clusterIpFamily: kubernetesNetworkConfig.ipFamily}' > $DESCRIBE_CLUSTER_RESULT || rc=$?
        if [[ $rc -eq 0 ]]; then
            break
        fi
        if [[ $attempt -eq $API_RETRY_ATTEMPTS ]]; then
            exit $rc
        fi
        jitter=$((1 + RANDOM % 10))
        sleep_sec="$(( $(( 5 << $((1+$attempt)) )) + $jitter))"
        sleep $sleep_sec
    done
    B64_CLUSTER_CA=$(cat $DESCRIBE_CLUSTER_RESULT | awk '{print $1}')
    APISERVER_ENDPOINT=$(cat $DESCRIBE_CLUSTER_RESULT | awk '{print $3}')
    SERVICE_IPV4_CIDR=$(cat $DESCRIBE_CLUSTER_RESULT | awk '{print $4}')
    SERVICE_IPV6_CIDR=$(cat $DESCRIBE_CLUSTER_RESULT | awk '{print $5}')

    if [[ -z "${IP_FAMILY}" ]]; then
      IP_FAMILY=$(cat $DESCRIBE_CLUSTER_RESULT | awk '{print $2}')
    fi
fi

if [[ -z "${IP_FAMILY}" ]] || [[ "${IP_FAMILY}" == "None" ]]; then
       ### this can happen when the ifFamily field is not found in describeCluster response
       ### or B64_CLUSTER_CA and APISERVER_ENDPOINT are defined but IPFamily isn't
       IP_FAMILY="ipv4"
fi

echo $B64_CLUSTER_CA | base64 -d > $CA_CERTIFICATE_FILE_PATH

sed -i s,CLUSTER_NAME,$CLUSTER_NAME,g /var/lib/kubelet/kubeconfig
sed -i s,MASTER_ENDPOINT,$APISERVER_ENDPOINT,g /var/lib/kubelet/kubeconfig
sed -i s,AWS_REGION,$AWS_DEFAULT_REGION,g /var/lib/kubelet/kubeconfig
### kubelet.service configuration

MAC=$(get_meta_data 'latest/meta-data/network/interfaces/macs/' | head -n 1 | sed 's/\/$//')

if [[ -z "${DNS_CLUSTER_IP}" ]]; then
  if [[ "${IP_FAMILY}" == "ipv6" ]]; then
    if [[ -z "${SERVICE_IPV6_CIDR}" ]]; then
      echo "Either --service-ipv6-cidr or --cluster-dns-ip must be provided when --ip-family is set to ipv6"
      exit 1
    fi
    DNS_CLUSTER_IP=$(awk -F/ '{print $1}' <<< $SERVICE_IPV6_CIDR)a
  fi

  if [[ ! -z "${SERVICE_IPV4_CIDR}" ]] && [[ "${SERVICE_IPV4_CIDR}" != "None" ]] ; then
    #Sets the DNS Cluster IP address that would be chosen from the serviceIpv4Cidr. (x.y.z.10)
    DNS_CLUSTER_IP=${SERVICE_IPV4_CIDR%.*}.10
  else
    TEN_RANGE=$(get_meta_data "latest/meta-data/network/interfaces/macs/$MAC/vpc-ipv4-cidr-blocks" | grep -c '^10\..*' || true )
    DNS_CLUSTER_IP=10.100.0.10
    if [[ "$TEN_RANGE" != "0" ]]; then
      DNS_CLUSTER_IP=172.20.0.10
    fi
  fi
else
  DNS_CLUSTER_IP="${DNS_CLUSTER_IP}"
fi

KUBELET_CONFIG=/etc/kubernetes/kubelet/kubelet-config.json
echo "$(jq ".clusterDNS=[\"$DNS_CLUSTER_IP\"]" $KUBELET_CONFIG)" > $KUBELET_CONFIG

if [[ "${IP_FAMILY}" == "ipv4" ]]; then
     INTERNAL_IP=$(get_meta_data 'latest/meta-data/local-ipv4')
else
     INTERNAL_IP_URI=latest/meta-data/network/interfaces/macs/$MAC/ipv6s
     INTERNAL_IP=$(get_meta_data $INTERNAL_IP_URI)
fi
INSTANCE_TYPE=$(get_meta_data 'latest/meta-data/instance-type')

# Sets kubeReserved and evictionHard in /etc/kubernetes/kubelet/kubelet-config.json for worker nodes. The following two function
# calls calculate the CPU and memory resources to reserve for kubeReserved based on the instance type of the worker node.
# Note that allocatable memory and CPU resources on worker nodes is calculated by the Kubernetes scheduler
# with this formula when scheduling pods: Allocatable = Capacity - Reserved - Eviction Threshold.

#calculate the max number of pods per instance type
MAX_PODS_FILE="/etc/eks/eni-max-pods.txt"
set +o pipefail
MAX_PODS=$(cat $MAX_PODS_FILE | awk "/^${INSTANCE_TYPE:-unset}/"' { print $2 }')
set -o pipefail
if [ -z "$MAX_PODS" ] || [ -z "$INSTANCE_TYPE" ]; then
    echo "No entry for type '$INSTANCE_TYPE' in $MAX_PODS_FILE. Will attempt to auto-discover value."
    # When determining the value of maxPods, we're using the legacy calculation by default since it's more restrictive than
    # the PrefixDelegation based alternative and is likely to be in-use by more customers.
    # The legacy numbers also maintain backwards compatibility when used to calculate `kubeReserved.memory`
    MAX_PODS=$(/etc/eks/max-pods-calculator.sh --instance-type-from-imds --cni-version 1.10.0 --show-max-allowed)
fi

# calculates the amount of each resource to reserve
mebibytes_to_reserve=$(get_memory_mebibytes_to_reserve $MAX_PODS)
cpu_millicores_to_reserve=$(get_cpu_millicores_to_reserve)
# writes kubeReserved and evictionHard to the kubelet-config using the amount of CPU and memory to be reserved
echo "$(jq '. += {"evictionHard": {"memory.available": "100Mi", "nodefs.available": "10%", "nodefs.inodesFree": "5%"}}' $KUBELET_CONFIG)" > $KUBELET_CONFIG
echo "$(jq --arg mebibytes_to_reserve "${mebibytes_to_reserve}Mi" --arg cpu_millicores_to_reserve "${cpu_millicores_to_reserve}m" \
    '. += {kubeReserved: {"cpu": $cpu_millicores_to_reserve, "ephemeral-storage": "1Gi", "memory": $mebibytes_to_reserve}}' $KUBELET_CONFIG)" > $KUBELET_CONFIG

if [[ "$USE_MAX_PODS" = "true" ]]; then
    echo "$(jq ".maxPods=$MAX_PODS" $KUBELET_CONFIG)" > $KUBELET_CONFIG
fi

mkdir -p /etc/systemd/system/kubelet.service.d

cat <<EOF > /etc/systemd/system/kubelet.service.d/10-kubelet-args.conf
[Service]
Environment='KUBELET_ARGS=--node-ip=$INTERNAL_IP --pod-infra-container-image=$PAUSE_CONTAINER --v=2'
EOF

if [[ -n "$KUBELET_EXTRA_ARGS" ]]; then
    cat <<EOF > /etc/systemd/system/kubelet.service.d/30-kubelet-extra-args.conf
[Service]
Environment='KUBELET_EXTRA_ARGS=$KUBELET_EXTRA_ARGS'
EOF
fi

if [[ "$CONTAINER_RUNTIME" = "containerd" ]]; then
    sudo mkdir -p /etc/containerd
    sudo mkdir -p /etc/cni/net.d
    sudo sed -i s,SANDBOX_IMAGE,$PAUSE_CONTAINER,g /etc/eks/containerd/containerd-config.toml
    sudo mv /etc/eks/containerd/containerd-config.toml /etc/containerd/config.toml
    sudo mv /etc/eks/containerd/sandbox-image.service /etc/systemd/system/sandbox-image.service
    sudo mv /etc/eks/containerd/kubelet-containerd.service /etc/systemd/system/kubelet.service
    sudo chown root:root /etc/systemd/system/kubelet.service
    sudo chown root:root /etc/systemd/system/sandbox-image.service
    ln -sf /run/containerd/containerd.sock /run/dockershim.sock
    systemctl daemon-reload
    systemctl enable containerd
    systemctl restart containerd
    systemctl enable sandbox-image
    systemctl start sandbox-image

elif [[ "$CONTAINER_RUNTIME" = "dockerd" ]]; then
    mkdir -p /etc/docker
    bash -c "/sbin/iptables-save > /etc/sysconfig/iptables"
    mv /etc/eks/iptables-restore.service /etc/systemd/system/iptables-restore.service
    sudo chown root:root /etc/systemd/system/iptables-restore.service
    systemctl daemon-reload
    systemctl enable iptables-restore

    if [[ -n "$DOCKER_CONFIG_JSON" ]]; then
        echo "$DOCKER_CONFIG_JSON" > /etc/docker/daemon.json
    fi
    if [[ "$ENABLE_DOCKER_BRIDGE" = "true" ]]; then
          # Enabling the docker bridge network. We have to disable live-restore as it
          # prevents docker from recreating the default bridge network on restart
          echo "$(jq '.bridge="docker0" | ."live-restore"=false' /etc/docker/daemon.json)" > /etc/docker/daemon.json
    fi
    systemctl daemon-reload
    systemctl enable docker
    systemctl restart docker
else
    echo "Container runtime ${CONTAINER_RUNTIME} is not supported."
    exit 1
fi


systemctl enable kubelet
systemctl start kubelet

# gpu boost clock
if  command -v nvidia-smi &>/dev/null ; then
   echo "nvidia-smi found"

   nvidia-smi -q > /tmp/nvidia-smi-check
   if [[ "$?" == "0" ]]; then
      sudo nvidia-smi -pm 1 # set persistence mode
      sudo nvidia-smi --auto-boost-default=0

      GPUNAME=$(nvidia-smi -L | head -n1)
      echo $GPUNAME

      # set application clock to maximum
      if [[ $GPUNAME == *"A100"* ]]; then
         nvidia-smi -ac 1215,1410
      elif [[ $GPUNAME == *"V100"* ]]; then
         nvidia-smi -ac 877,1530
      elif [[ $GPUNAME == *"K80"* ]]; then
         nvidia-smi -ac 2505,875
      elif [[ $GPUNAME == *"T4"* ]]; then
         nvidia-smi -ac 5001,1590
      elif [[ $GPUNAME == *"M60"* ]]; then
         nvidia-smi -ac 2505,1177
      else
         echo "unsupported gpu"
      fi
   else
      cat /tmp/nvidia-smi-check
   fi
else
    echo "nvidia-smi not found"
fi

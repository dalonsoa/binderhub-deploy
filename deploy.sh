#!/bin/bash

# Exit immediately if a pipeline returns a non-zero status
set -e

## Detection of the deploy mode 
#
# This script should handle both interactive deployment when run by a user
# on their local system, and also running as a container entrypoint when
# used either for a container-based local deployment or when deployed via an
# Azure blue button setup.
#
# Check whether BINDERHUB_CONTAINER_MODE is set, and if so assume running
# as a container-based install, checking that all required input is present
# in the form of environment variables

if [ ! -z $BINDERHUB_CONTAINER_MODE ] ; then
  # Set out a list of required variables for this script
  REQUIREDVARS=" \
          SP_APP_ID \
          SP_APP_KEY \
          SP_TENANT_ID \
          RESOURCE_GROUP_NAME \
          RESOURCE_GROUP_LOCATION \
          AZURE_SUBSCRIPTION \
          BINDERHUB_NAME \
          BINDERHUB_VERSION \
          AKS_NODE_COUNT \
          AKS_NODE_VM_SIZE \
          CONTACT_EMAIL \
          DOCKER_USERNAME \
          DOCKER_PASSWORD \
          DOCKER_IMAGE_PREFIX \
          DOCKER_ORGANISATION \
          "
  for required_var in $REQUIREDVARS ; do
    if [ -z "${!required_var}" ] ; then
      echo "${required_var} must be set for container-based setup" >&2
      exit 1
    fi
  done

else

  # Read in config file and assign variables for the non-container case
  configFile='config.json'
  
  echo "Reading configuration from ${configFile}"
  AZURE_SUBSCRIPTION=`jq -r '.azure .subscription' ${configFile}`
  BINDERHUB_NAME=`jq -r '.binderhub .name' ${configFile}`
  RESOURCE_GROUP_LOCATION=`jq -r '.azure .location' ${configFile}`
  RESOURCE_GROUP_NAME=`jq -r '.azure .res_grp_name' ${configFile}`
  AKS_NODE_COUNT=`jq -r '.azure .node_count' ${configFile}`
  AKS_NODE_VM_SIZE=`jq -r '.azure .vm_size' ${configFile}`

  # Generate resource group name
  RESOURCE_GROUP_NAME=`echo ${BINDERHUB_NAME} | tr -cd '[:alnum:]_-' | cut -c 1-87`_RG

  echo "Configuration read in:
    AZURE_SUBSCRIPTION: ${AZURE_SUBSCRIPTION}
    BINDERHUB_NAME: ${BINDERHUB_NAME}
    RESOURCE_GROUP_LOCATION: ${RESOURCE_GROUP_LOCATION}
    RESOURCE_GROUP_NAME: ${RESOURCE_GROUP_NAME}
    AKS_NODE_COUNT: ${AKS_NODE_COUNT}
    AKS_NODE_VM_SIZE: ${AKS_NODE_VM_SIZE}"

  # Ask for user's Docker credentials
  echo "If you have provided a DockerHub organisation, this Docker ID MUST be a member of that organisation"
  read -p "DockerHub ID: " DOCKER_USERNAME
  read -sp "DockerHub password: " DOCKER_PASSWORD

fi

# Generate a valid name for the AKS cluster
AKS_NAME=`echo ${BINDERHUB_NAME} | tr -cd '[:alnum:]-' | cut -c 1-59`-AKS

# Azure login will be different depending on whether this script is running
# with or without service principal details supplied.
# 
# If all the SP enironment is set, use that. Otherwise, fall back to an
# interactive login.


if [ -z $SP_APP_ID ] || [ -z $SP_APP_KEY ] || [ -z $SP_TENANT_ID ] ; then
  echo "Attempting to log in to Azure as a user"
  if ! az login -o none; then
      echo "Unable to connect to Azure" >&2
      exit 1
  fi
else
  echo "Attempting to log in to Azure with service principal"
  if ! az login --service-principal -u "${SP_APP_ID}" -p "${SP_APP_KEY}" -t "${SP_TENANT_ID}"; then
    echo "Unable to connect to Azure" >&2
    exit 1
  fi
fi

echo "Activating Azure subscription: ${AZURE_SUBSCRIPTION}"

# Activate chosen subscription
az account set -s "$AZURE_SUBSCRIPTION"

echo "Checking if resource group exists: ${RESOURCE_GROUP_NAME}"
# Create a new resource group if necessary
if [[ $(az group exists --name $RESOURCE_GROUP_NAME) == false ]] ; then
  echo "Creating new resource group: ${RESOURCE_GROUP_NAME}"
  az group create -n $RESOURCE_GROUP_NAME --location $RESOURCE_GROUP_LOCATION -o table
fi

# Create an AKS cluster
echo "Creating AKS cluster; this may take a few monutes to complete"
az aks create -n $AKS_NAME -g $RESOURCE_GROUP_NAME --generate-ssh-keys --node-count $AKS_NODE_COUNT --node-vm-size $AKS_NODE_VM_SIZE -o table

# Get kubectl credentials from Azure
echo "Fetching kubectl credentials from Azure"
az aks get-credentials -n $AKS_NAME -g $RESOURCE_GROUP_NAME -o table

# Check nodes are ready
while [[ ! x`kubectl get node | awk '{print $2}' | grep Ready | wc -l` == x${AKS_NODE_COUNT} ]] ; do echo -n $(date) ; echo " : Waiting for all cluster nodes to be ready" ; sleep 15 ; done

# Setup ServiceAccount for tiller
echo "Setting up tiller service account"
kubectl --namespace kube-system create serviceaccount tiller

# Give the ServiceAccount full permissions to manage the cluster
echo "Giving the ServiceAccount full permissions to manage the cluster"
kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller

# Initialise helm and tiller
echo "Initialising helm and tiller"
helm init --service-account tiller --wait

# Secure tiller against attacks from within the cluster
echo "Securing tiller against attacks from within the cluster"
kubectl patch deployment tiller-deploy --namespace=kube-system --type=json --patch='[{"op": "add", "path": "/spec/template/spec/containers/0/command", "value": ["/tiller", "--listen=localhost:44134"]}]'

# Check helm has been configured correctly
echo "Verify Client and Server are running the same version number:"
while [[ ! x`kubectl get pods --namespace kube-system | grep ^tiller | awk '{print $3}'` == xRunning ]] ; do echo -n $(date) ; echo " : Waiting for tiller pod to be running" ; sleep 5 ; done
helm version

# Create tokens for the secrets file:
apiToken=`openssl rand -hex 32`
secretToken=`openssl rand -hex 32`

# Get the latest helm chart for BinderHub:
helm repo add jupyterhub https://jupyterhub.github.io/helm-chart
helm repo update

# Get this script's path
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Generate the scripts paths - make sure these are found
config_script="${DIR}/create_config.py"
secret_script="${DIR}/create_secret.py"

# Install the Helm Chart using the configuration files, to deploy both a BinderHub and a JupyterHub:
echo "--> Generating initial configuration file"
python3 $config_script -id=$DOCKER_USERNAME --prefix=$DOCKER_IMAGE_PREFIX -org=$DOCKER_ORGANISATION --force

echo "--> Generating initial secrets file"

python3 $secret_script --apiToken=$apiToken \
--secretToken=$secretToken \
-id=$DOCKER_USERNAME \
--password=$DOCKER_PASSWORD \
--force

echo "--> Installing Helm chart"
helm install jupyterhub/binderhub \
--version=$BINDERHUB_VERSION \
--name=$BINDERHUB_NAME \
--namespace=$BINDERHUB_NAME \
-f ./secret.yaml \
-f ./config.yaml \
--timeout=3600

# Wait for  JupyterHub, grab its IP address, and update BinderHub to link together:
echo "--> Retrieving BinderHub IP"
jupyterhub_ip=`kubectl --namespace=$BINDERHUB_NAME get svc proxy-public | awk '{ print $4}' | tail -n 1`
while [ "$jupyterhub_ip" = '<pending>' ] || [ "$jupyterhub_ip" = "" ]
do
    echo "JupyterHub IP: $jupyterhub_ip"
    sleep 5
    jupyterhub_ip=`kubectl --namespace=$BINDERHUB_NAME get svc proxy-public | awk '{ print $4}' | tail -n 1`
done

echo "--> Finalising configurations"
python3 $config_script -id=$DOCKER_USERNAME \
--prefix=$DOCKER_IMAGE_PREFIX \
-org=$DOCKER_ORGANISATION \
--jupyterhub_ip=$jupyterhub_ip \
--force

echo "--> Updating Helm chart"
helm upgrade $BINDERHUB_NAME jupyterhub/binderhub \
--version=$BINDERHUB_VERSION \
-f secret.yaml \
-f config.yaml

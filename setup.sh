# Setup Environment Variables
RG=EphBlobNFSv3Lab2
LOC=eastus
CLUSTER_NAME=aksblob2
SA_NAME=aksblobnfsgriff2

# Create the Resource Group
az group create -n $RG -l $LOC

# Get the Resource Group ID for later
RG_ID=$(az group show -n $RG --query id -o tsv)

# Create Vnet
az network vnet create \
-g $RG \
-n demovnet \
--address-prefix 10.40.0.0/16 \
--subnet-name aks --subnet-prefix 10.40.0.0/24

az network vnet subnet update \
--resource-group $RG \
--vnet-name demovnet \
--name aks \
--service-endpoints 'Microsoft.Storage'

# Get the Vnet and Subnet IDs for later
VNET_ID=$(az network vnet show -g $RG -n demovnet --query id -o tsv)
AKS_SUBNET_ID=$VNET_ID/subnets/aks

# Create Storage Account with Blob NFS Enabled
az storage account create  \
--resource-group $RG \
--name $SA_NAME \
--sku Standard_LRS \
--kind StorageV2 \
--enable-hierarchical-namespace true \
--enable-nfs-v3 true \
--subnet $AKS_SUBNET_ID \
--default-action deny

# Create the AKS Cluster
az aks create \
--resource-group $RG \
--name $CLUSTER_NAME \
--vnet-subnet-id $AKS_SUBNET_ID -y

MC_RG_ID=$(az group show -n $(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query nodeResourceGroup) -o tsv --query id)
KUBELET_IDENTITY=$(az aks show -g $RG -n $CLUSTER_NAME -o tsv --query identityProfile.kubeletidentity.objectId)

az role assignment create \
--role "Contributor" \
--assignee $KUBELET_IDENTITY \
--scope $RG_ID

az role assignment create \
--role "Contributor" \
--assignee $KUBELET_IDENTITY \
--scope $MC_RG_ID

# Get AKS Credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME

curl -skSL https://raw.githubusercontent.com/kubernetes-sigs/blob-csi-driver/master/deploy/install-driver.sh | bash -s master blobfuse-proxy --

cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: blob-nfs
provisioner: blob.csi.azure.com
parameters:
  protocol: nfs
  resourceGroup: $RG
  storageAccount: $SA_NAME
  server: $SA_NAME.blob.core.windows.net
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - nconnect=8
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: blobnfs-pvc
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: blob-nfs
  resources:
    requests:
      storage: 5Gi
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  labels:
    run: ubuntu
  name: ubuntu
spec:
  containers:
  - image: ubuntu
    name: ubuntu
    command: [ "/bin/bash", "-c", "--" ]
    args: [ "while true; do sleep 30; done;" ]
    volumeMounts:
        - mountPath: /blobnfs
          name: blobnfs
  volumes:
    - name: blobnfs
      persistentVolumeClaim:
        claimName: blobnfs-pvc
  restartPolicy: Never
EOF
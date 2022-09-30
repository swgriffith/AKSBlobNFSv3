# AKS Blob NFS CSI Driver Example

This repo provides a walk through of the setup steps needed to create an Azure Storage Account with Blob NFSv3 support enabled, link that storage account to a subnet, create an AKS cluster with the Blob NFS storage driver installed and connect various pod examples to that Blob account over the NFS driver.

## Setup Steps

The first step is to review the documentation on the Blob Storage NFS Driver below. We'll be using static mounting. We will also need to register the provider.

* [Use Azure Blob storage Container Storage Interface (CSI) driver](https://learn.microsoft.com/en-us/azure/aks/azure-blob-csi?tabs=NFS)
* [Create and use a static volume with Azure Blob storage in Azure Kubernetes Service (AKS)](https://learn.microsoft.com/en-us/azure/aks/azure-csi-blob-storage-static?tabs=secret)

Register the feature and provider

```bash
# To install the extension
az extension add --name aks-preview

# To update the extension if you already have it installed
az extension update --name aks-preview

az feature register --name EnableBlobCSIDriver --namespace Microsoft.ContainerService

# Check the registration status
az feature show --namespace Microsoft.ContainerService -n EnableBlobCSIDriver

# Update the container service provider
az provider register -n Microsoft.ContainerService
```

Setup Environment Variables

```bash
RG=DemoAKSBlobNFS
LOC=eastus
CLUSTER_NAME=aksblobnfsdemo
# Storage Account Name must be unique
SA_NAME=aksblobnfs$RANDOM
```

Create the Resource Group and get the Resource Group ID for later

```bash
az group create -n $RG -l $LOC
RG_ID=$(az group show -n $RG --query id -o tsv)
```

Create the Vnet and Subnet

```bash
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
AKS_SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name demovnet -n aks -o tsv --query id)
```

Create Storage Account with Blob NFS Enabled and enable the users public IP to access the account.

```bash
# Create the storage account with features enabled to support NFSv3
az storage account create  \
--resource-group $RG \
--name $SA_NAME \
--sku Standard_LRS \
--kind StorageV2 \
--enable-hierarchical-namespace true \
--enable-nfs-v3 true \
--subnet $AKS_SUBNET_ID \
--default-action deny

# With default deny we will need to grant own own IP access to the account. You can do this via the portal, or as follows
az storage account network-rule add --resource-group $RG --account-name $SA_NAME --ip-address $(curl -4 icanhazip.com)

# It may take a minute for the firewall rule update to be active so we'll sleep....or you can just watch the clock
sleep 60
```

Create the storage container.

```bash
# Create the storage container. If this errors out, wait a few more seconds and try again, due to the firewall rule propagation delay.
az storage container create \
    --account-name $SA_NAME \
    --name upload 
```



Create the AKS Cluster

```bash
# Create the AKS cluster with the blob csi driver installed
az aks create \
--resource-group $RG \
--name $CLUSTER_NAME \
--vnet-subnet-id $AKS_SUBNET_ID \
--enable-blob-driver

# Get the cluster credentials
az aks get-credentials -g $RG -n $CLUSTER_NAME
```

Grant the cluster identity access to the resource groups.

>*NOTE:* We'll grant contributor access for simplicity, but you would want to adjust the permissions to your own security needs.

```bash
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
```

Now the cluster and storage account are ready. The following two examples demonstrate using the blob nfs storage class.

### Basic Ubuntu

This will create the persistent volume, persistent volume claim and pod using the PVC.

```bash
# Create the persistent volume
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-blob
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain  # If set as "Delete" container would be removed after pvc deletion
  storageClassName: azureblob-nfs-premium
  csi:
    driver: blob.csi.azure.com
    readOnly: false
    # make sure this volumeid is unique in the cluster
    # `#` is not allowed in self defined volumeHandle
    volumeHandle: $(uuidgen)
    volumeAttributes:
      resourceGroup: ${RG}
      storageAccount: ${SA_NAME}
      containerName: upload
      protocol: nfs
EOF

# Deploy the persistent volume claim and pod
kubectl apply -f basicpod/.

# Test
# Use kubectl exec to write a file and then go to the blob container in the portal to confirm the file was created
kubectl exec -it ubuntu -- touch /blobnfs/testfile

# Or, you can just exec to the pod and create the file
kubectl exec -it ubuntu -- bash
```

Clean up

```bash
kubectl delete -f basicpod/.

kubectl delete pv pv-blob
```

### SFTP Server

This example will create a persistent volume, persistent volume claim, deployment and service that run an SFTP instance.

```bash
# Create the persistent volume
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-blob
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain  # If set as "Delete" container would be removed after pvc deletion
  storageClassName: azureblob-nfs-premium
  csi:
    driver: blob.csi.azure.com
    readOnly: false
    # make sure this volumeid is unique in the cluster
    # `#` is not allowed in self defined volumeHandle
    volumeHandle: $(uuidgen)
    volumeAttributes:
      resourceGroup: ${RG}
      storageAccount: ${SA_NAME}
      containerName: upload
      protocol: nfs
EOF

kubectl apply -f sftp/.  

# Get the service public IP
kubectl get svc -n sftp

# Connect to sftp
# Password is 'reddog9876'
sftp aksuser@<service public IP>

# Once connected, go tot he upload directory
cd upload

# Then you can put a file
put <local file name>
```

Clean up

```bash
kubectl delete -f sftp/.

kubectl delete pv pv-blob
```

### Writing Random Data from Multiple Pods

This will create a persistent volume, persistent volume claim and deployment. Each pod in the deployment will use the dd tool to write random data out to a file on the storage container. You can adjust the number of pods via the deployment replica count and you can adjust the generated file size by modifying the dd command in the deployment.

```bash
# Create the persistent volume
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-blob
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain  # If set as "Delete" container would be removed after pvc deletion
  storageClassName: azureblob-nfs-premium
  csi:
    driver: blob.csi.azure.com
    readOnly: false
    # make sure this volumeid is unique in the cluster
    # `#` is not allowed in self defined volumeHandle
    volumeHandle: $(uuidgen)
    volumeAttributes:
      resourceGroup: ${RG}
      storageAccount: ${SA_NAME}
      containerName: upload
      protocol: nfs
EOF

kubectl apply -f dd-write/.

# You can watch the file creation in the portal
```

Clean up

```bash
kubectl delete -f dd-write/.

kubectl delete pv pv-blob
```

### Writing from one pod and reading from another
```bash
# Create the persistent volume
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-blob
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain  # If set as "Delete" container would be removed after pvc deletion
  storageClassName: azureblob-nfs-premium
  csi:
    driver: blob.csi.azure.com
    readOnly: false
    # make sure this volumeid is unique in the cluster
    # `#` is not allowed in self defined volumeHandle
    volumeHandle: $(uuidgen)
    volumeAttributes:
      resourceGroup: ${RG}
      storageAccount: ${SA_NAME}
      containerName: upload
      protocol: nfs
EOF

# Deploy the PVC and reader and writer pods
kubectl apply -f read-write/.

# Follow the reader pod logs
kubectl logs -f reader
```

Clean up

```bash
kubectl delete -f read-write/.

kubectl delete pv pv-blob
```

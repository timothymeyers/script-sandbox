## This scriptlet creates an AKS cluster that leverages encryption keys from an Azure Key Vault for OS and Data disk encription.
## Largely follows the instructions from these docs 
##   - https://docs.microsoft.com/en-us/azure/aks/azure-disk-customer-managed-keys
##   - https://ahmedkhamessi.com/2020-10-29-AKS-Encrypt-PV-BYOK/


oneUp=001

myKeyVaultName=test-akv-$oneUp
myKeyNameOS=test-key-aks-os
myKeyNameData=test-key-aks-data
myResourceGroupAKV=test-akv-rg-$oneUp
myResourceGroupAKS=test-aks-rg-$oneUp
myAzureRegionName=eastus
myDiskEncryptionSetNameOS=test-des-os-$oneUp
myDiskEncryptionSetNameData=test-des-data-$oneUp
myAKSCluster=test-aks-cluster-$oneUp
myAzureSubscriptionId=$(az account list --query [id] -o tsv)
# storageClass=hdd
# greater than 1.17 
KUBERNETES_VERSION=1.18.14


#Create SP for AKS
# spName=aksSP$oneUp
# spPassword=$(az ad sp create-for-rbac --skip-assignment --name $spName --query 'password' -o tsv && sleep 15) 
# spAppId=$(az ad sp show --id "http://$spName"  --query "appId" -o tsv && sleep 5) 
# echo $spName $spAppId $spPassword

#Create the resourcegroup and the Keyvault
az group create -l $myAzureRegionName -n $myResourceGroupAKV
az keyvault create -n $myKeyVaultName -g $myResourceGroupAKV -l $myAzureRegionName --enable-purge-protection true # --enable-soft-delete true

#Generate keys
az keyvault key create --vault-name $myKeyVaultName --name $myKeyNameOS --protection software
az keyvault key create --vault-name $myKeyVaultName --name $myKeyNameData --protection software

# ================== OS ==================

#Create an instance of a DiskEncryptionSet
keyVaultId=$(az keyvault show --name $myKeyVaultName --query [id] -o tsv)
keyVaultKeyUrl=$(az keyvault key show --vault-name $myKeyVaultName  --name $myKeyNameOS  --query [key.kid] -o tsv)

az disk-encryption-set create -n $myDiskEncryptionSetNameOS  -l $myAzureRegionName  -g $myResourceGroupAKV --source-vault $keyVaultId --key-url $keyVaultKeyUrl

#Grant the DiskEncryptionSet access to key vault
desIdentity=$(az disk-encryption-set show -n $myDiskEncryptionSetNameOS  -g $myResourceGroupAKV --query [identity.principalId] -o tsv)

# Update security policy settings
az keyvault set-policy -n $myKeyVaultName -g $myResourceGroupAKV --object-id $desIdentity --key-permissions wrapkey unwrapkey get

# Create the AKS cluster
diskEncryptionSetId=$(az disk-encryption-set show -n $myDiskEncryptionSetNameOS -g $myResourceGroupAKV --query [id] -o tsv)

az group create -l $myAzureRegionName -n $myResourceGroupAKS
az aks create -n $myAKSCluster -g $myResourceGroupAKS \
--node-osdisk-diskencryptionset-id $diskEncryptionSetId \
--kubernetes-version $KUBERNETES_VERSION \
--generate-ssh-keys \
--node-count 5 \
--enable-addons monitoring
# --service-principal $spAppId \
# --client-secret $spPassword

# ================== Data ==================

#Create an instance of a DiskEncryptionSet
keyVaultId=$(az keyvault show --name $myKeyVaultName --query [id] -o tsv)
keyVaultKeyUrl=$(az keyvault key show --vault-name $myKeyVaultName  --name $myKeyNameData  --query [key.kid] -o tsv)

az disk-encryption-set create -n $myDiskEncryptionSetNameData  -l $myAzureRegionName  -g $myResourceGroupAKV --source-vault $keyVaultId --key-url $keyVaultKeyUrl

#Encrypt AKS data disk
# az role assignment create --assignee $spAppId --scope /subscriptions/$myAzureSubscriptionId/resourceGroups/$myResourceGroupAKV/providers/Microsoft.Compute/diskEncryptionSets/$myDiskEncryptionSetNameData --role Contributor

az aks get-credentials -n $myAKSCluster -g $myResourceGroupAKS --output table

#create the storage class
cat << EOF | kubectl apply -f -
kind: StorageClass
apiVersion: storage.k8s.io/v1  
metadata:
  name: hdd
provisioner: kubernetes.io/azure-disk
parameters:
  skuname: Standard_LRS
  kind: managed
  diskEncryptionSetID: "/subscriptions/$myAzureSubscriptionId/resourceGroups/$myResourceGroupAKV/providers/Microsoft.Compute/diskEncryptionSets/$myDiskEncryptionSetNameData"
allowVolumeExpansion: true
EOF

#Mutate the default StorageClass
# kubectl patch storageclass default -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
# kubectl patch storageclass $storageClass -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
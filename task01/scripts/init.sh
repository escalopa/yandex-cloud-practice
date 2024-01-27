#!/usr/bin/bash

USER_ID=vvot42

echo "setting initial enviroment variables..."

ACCESS_TOKEN=$(yc iam create-token)
CLOUD_ID=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" https://resource-manager.api.cloud.yandex.net/resource-manager/v1/clouds | jq -r '.clouds | .[] | select(.name=="itis-vvot") .id')
FOLDER_ID=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" -G  https://resource-manager.api.cloud.yandex.net/resource-manager/v1/folders -d cloud_id=$CLOUD_ID | jq -r --arg USER_ID "$USER_ID" '.folders | .[] | select(.name==$USER_ID) .id')
 
echo "user_id = \"$USER_ID\"" > terraform.tfvars
echo "access_token = \"$ACCESS_TOKEN\"" >> terraform.tfvars
echo "cloud_id = \"$CLOUD_ID\"" >> terraform.tfvars
echo "folder_id = \"$FOLDER_ID\"" >> terraform.tfvars

# echo "ORGANIZATION_ID=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" https://resource-manager.api.cloud.yandex.net/resource-manager/v1/clouds | jq -r '.clouds | .[] | select(.name=="itis-vvot") .organizationId')" >> terraform.tfvars

#####################################

echo "setting  terraform provider..."
cat >~/.terraformrc <<EOF
provider_installation {
  network_mirror {
    url = "https://terraform-mirror.yandexcloud.net/"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
EOF

#####################################

echo "running terraform init..."
terraform init

#####################################

echo "done"

#!/usr/bin/bash

USER_ID=vvot42

echo "setting initial enviroment variables..."
echo "USER_ID=$USER_ID" > .env
echo "IAM_TOKEN=$(yc iam create-token)" >> .env
echo "ORGANIZATION_ID=$(curl -s -H "Authorization: Bearer ${IAM_TOKEN}" https://resource-manager.api.cloud.yandex.net/resource-manager/v1/clouds | jq -r '.clouds | .[] | select(.name=="itis-vvot") .organizationId')" >> .env
echo "CLOUD_ID=$(curl -s -H "Authorization: Bearer ${IAM_TOKEN}" https://resource-manager.api.cloud.yandex.net/resource-manager/v1/clouds | jq -r '.clouds | .[] | select(.name=="itis-vvot") .id')" >> .env
echo "FOLDER_ID=$(curl -s -H "Authorization: Bearer ${IAM_TOKEN}" -G  https://resource-manager.api.cloud.yandex.net/resource-manager/v1/folders -d cloud_id=$CLOUD_ID | jq -r --arg USER_ID "$USER_ID" '.folders | .[] | select(.name==$USER_ID) .id')" >> .env

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

echo "settting up yc docker container registry..."
yc container registry configure-docker

#####################################

echo "done"

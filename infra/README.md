# infra

テンプレート部分の置き換えは以下のコマンドで実施する。

```shell
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ssh_key_id=$(aws iam list-ssh-public-keys --user-name argocd | jq -r '.SSHPublicKeys[].SSHPublicKeyId')
find . -type f -name "*.yaml" -print0 | xargs -0 sed -i "" -e "s/XXXX_AWS_ACCOUNT_ID_XXXX/${AWS_ACCOUNT_ID}/"
find . -type f -name "*.yaml" -print0 | xargs -0 sed -i "" -e "s/XXXX_SSH_KEY_ID_XXXX/${ssh_key_id}/"
```

テンプレート化は以下のコマンドで実施する。

```shell
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ssh_key_id=$(aws iam list-ssh-public-keys --user-name argocd | jq -r '.SSHPublicKeys[].SSHPublicKeyId')
find . -type f -name "*.yaml" -print0 | xargs -0 sed -i "" -e "s/${AWS_ACCOUNT_ID}/XXXX_AWS_ACCOUNT_ID_XXXX/"
find . -type f -name "*.yaml" -print0 | xargs -0 sed -i "" -e "s/${ssh_key_id}/XXXX_SSH_KEY_ID_XXXX/"
```

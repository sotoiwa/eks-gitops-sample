# クラスターのBlue/Green切り替え

クラスターのBlue/Green切り替えを行う。

## ALBの準備

先ずALBとターゲットグループをAWS Load Balancer ControllerではなくCloudFormationで作成する。

```shell
for cluster_name in staging production; do
  vpc_id=$(aws ec2 describe-vpcs --filter "Name=tag:Name,Values=gitops-${cluster_name}-vpc-stack-VPC" --query "Vpcs[*].VpcId" --output text)
  public_subnet_01=$(aws ec2 describe-subnets --filter "Name=tag:Name,Values=gitops-${cluster_name}-vpc-stack-PublicSubnet01" --query "Subnets[*].SubnetId" --output text)
  public_subnet_02=$(aws ec2 describe-subnets --filter "Name=tag:Name,Values=gitops-${cluster_name}-vpc-stack-PublicSubnet02" --query "Subnets[*].SubnetId" --output text)
  aws cloudformation deploy \
    --stack-name gitops-${cluster_name}-alb-stack \
    --template-file cfn/alb.yaml \
    --parameter-overrides ClusterName=${cluster_name} VpcId=${vpc_id} PublicSubnet01=${public_subnet_01} PublicSubnet02=${public_subnet_02}
done
```

ターゲットグループのポートは、Serviceやコンテナのポートと一致していなくても特に問題はなさそう。

- [Application Load Balancerで設定する4種類のポート番号の意味を理解しよう](https://dev.classmethod.jp/articles/aws-alb-port/)

クラスターセキュリティグループでALBのセキュリティグループからの接続を受け入れる設定はAWS Load Balancer Controllerがやってくれる。

## クラスターの作成

`staging.yaml`をコピーして`staging-green.yaml`を作成する。クラスターの名前を変える。

staging-greenクラスターを作成する。

```sh
eksctl create cluster -f staging-green.yaml
```

同様にproduction-greenクラスターも作成する。

```
eksctl create cluster -f production-green.yaml
```

## ノードグループを作成する

`staging-ng1.yaml`をコピーして`staging-green-ng1.yaml`を作成する。クラスターの名前を変える。

staging-greenクラスターのノードグループを作成する。

```sh
eksctl create nodegroup -f staging-green-ng1.yaml
```

同様に、production-greenクラスターのノードグループを作成する。

```sh
eksctl create nodegroup -f production-green-ng1.yaml
```

## IRSA

IRSAで使用するIAMロールは共有することも考えられるが、ここでは共有しないことにする。追加のクラスター分のIAMロールを作成する。

```sh
for cluster_name in staging-green production-green; do
  oidc_provider=$(aws eks describe-cluster --name ${cluster_name} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
  aws cloudformation deploy \
    --stack-name gitops-${cluster_name}-backend-iam-stack \
    --template-file cfn/backend-iam.yaml \
    --parameter-overrides TableName=messages-${cluster_name%%-*} ClusterName=${cluster_name} NamespaceName=backend ServiceAccountName=backend OidcProvider=${oidc_provider} \
    --capabilities CAPABILITY_NAMED_IAM
  aws cloudformation deploy \
    --stack-name gitops-${cluster_name}-aws-load-balancer-controller-iam-stack \
    --template-file cfn/aws-load-balancer-controller-iam.yaml \
    --parameter-overrides ClusterName=${cluster_name} NamespaceName=kube-system ServiceAccountName=aws-load-balancer-controller OidcProvider=${oidc_provider} \
    --capabilities CAPABILITY_NAMED_IAM
  aws cloudformation deploy \
    --stack-name gitops-${cluster_name}-external-secrets-iam-stack \
    --template-file cfn/external-secrets-iam.yaml \
    --parameter-overrides ClusterName=${cluster_name} NamespaceName=external-secrets ServiceAccountName=external-secrets OidcProvider=${oidc_provider} \
    --capabilities CAPABILITY_NAMED_IAM
  aws cloudformation deploy \
    --stack-name gitops-${cluster_name}-cloudwatch-agent-iam-stack \
    --template-file cfn/cloudwatch-agent-iam.yaml \
    --parameter-overrides ClusterName=${cluster_name} NamespaceName=amazon-cloudwatch ServiceAccountName=cloudwatch-agent OidcProvider=${oidc_provider} \
    --capabilities CAPABILITY_NAMED_IAM
  aws cloudformation deploy \
    --stack-name gitops-${cluster_name}-fluent-bit-iam-stack \
    --template-file cfn/fluent-bit-iam.yaml \
    --parameter-overrides ClusterName=${cluster_name} NamespaceName=amazon-cloudwatch ServiceAccountName=fluent-bit OidcProvider=${oidc_provider} \
    --capabilities CAPABILITY_NAMED_IAM
done
```

## マニフェストの作成

`main`ブランチで以下の操作を行う。

全ての`overlays/staging`ディレクトリを`overlays/staging-green`ディレクトリにコピーする。

同様に、全ての`overlays/production`ディレクトリを`overlays/production-green`ディレクトリにコピーする。

マニフェスト書き換えを行う。書き換えるポイントは以下。

- IRSAで使用するIAMロールのARN
- ターゲットグループのARN
- App of Appsから参照する各Applicationのパス
- AWS Load Balancer Controllerで指定しているクラスター名の引数

マニフェストをmainブランチにコミットする。

mainブランチからmain-greenブランチを作成する。

```shell
git checkout -b main-green
git push origin main-green
```

productionブランチをリベースする。

```shell
git checkout production
git rebase main
git push origin production
```

productionブランチからproduction-greenブランチを作成する。

```shell
git checkout -b production-green
git push origin production-green
```

## ArgoCDのデプロイ

以降の作業はstaging、productionのクラスターで実施した作業とほぼ同じ。

kubectlのコンテキストをstaging-green、production-greenクラスターに向けほぼ同じ作業を実施するが、App of Appsのパスとブランチを変える。

```sh
cluster_name=staging-green
branch=main-green
# cluster_name=production-green
# branch=production-green
ssh_key_id=$(aws iam list-ssh-public-keys --user-name argocd | jq -r '.SSHPublicKeys[].SSHPublicKeyId')
argocd app create apps \
  --repo ssh://${ssh_key_id}@git-codecommit.ap-northeast-1.amazonaws.com/v1/repos/infra \
  --revision ${branch} \
  --path apps/overlays/${cluster_name} \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace argocd \
  --sync-policy automated \
  --auto-prune
```

これでデプロイ完了。

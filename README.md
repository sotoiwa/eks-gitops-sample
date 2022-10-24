# eks-gitops-sample

EKS で以下のスタックを使った GitOps のサンプル構成を作成する。

|役割|ツール|
|---|---|
|ソース管理|CodeCommit|
|CI|CodeBuild|
|CD|Argo CD + Kustomize|
|イメージレジストリ|ECR|

シングルアカウントの中に Staging と Production のクラスターを構成する。

![](./architecture.drawio.svg)

コンポーネントのバージョンは以下で確認。

|コンポーネント|バージョン|
|---|---|
|Kubernetes バージョン|1.24|
|Argo CD|v2.4.15|
|Cert Manager|v1.5.4|
|AWS Load Balancer Controller|v2.4.4|
|External Secrets Operator|0.6.0|

## 参考リンク

- [GitOpsで絶対に避けて通れないブランチ戦略](https://amaya382.hatenablog.jp/entry/2019/12/02/192159)
- [Argo CDによる継続的デリバリーのベストプラクティスとその実装](https://blog.cybozu.io/entry/2019/11/21/100000)

## パイプラインの構築

GitOps で CI と CD は分離するので、CI を行うパイプラインを最初に作成する。

### Docker Hub のクレデンシャル作成

Docker Hub のレートリミットを回避するため、CodeBuild では Docker Hub にログインする。そのためのユーザー名とパスワードを Secrets Manager に格納しておく。
なお、ECR 経由で Docker Hub の公式イメージをプルすることも可能なので、そちらでもよいが、imagePullSecret の使い方の確認のためこの方式とする。

```sh
aws secretsmanager create-secret \
  --region ap-northeast-1 \
  --name dockerhub \
  --secret-string '{"username":"hogehoge","password":"fugafuga"}'
```

クラスター上でも Docker Hub からのイメージ取得がレートリミットに引っかかることがあるため、imagePullSecret として使用するための dockerconfigjson を作成しておく。

```sh
dockerconfigjson=$(kubectl create secret docker-registry mysecret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username="hogehoge" \
  --docker-password="fugafuga" --dry-run=client -o json \
  | jq -r '.data.".dockerconfigjson"' | base64 --decode)
echo ${dockerconfigjson}
aws secretsmanager create-secret \
  --region ap-northeast-1 \
  --name dockerconfigjson \
  --secret-string ${dockerconfigjson}
```

### SecurityHub での Trivy の統合

SeurityHub で Trivy の結果を受け入れるように設定する。Aqua との統合を有効化する。

```shell
aws securityhub enable-import-findings-for-product --product-arn arn:aws:securityhub:ap-northeast-1::product/aquasecurity/aquasecurity
```

### Argo CD 用の IAM ユーザーの作成

Argo CD が CodeCommit にアクセスするための IAM ユーザーを作成する。クラスターごとに IAM ユーザーを分けてもよいが、今回はユーザーを共用するので、この操作は 1 回だけ実施する。

CodeCommit へのアクセスにはいくつかの選択肢がある。

- [Git 認証情報を使用する HTTPS ユーザー用のセットアップ](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-gc.html)
  - IAM ユーザーに関連付けられたユーザー名とパスワードを使用する方法
- [AWS CLI を使用していない SSH ユーザーの セットアップ](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-without-cli.html)
  - IAM ユーザーに関連付けられた SSH キーペアを使用する方法
- [git-remote-codecommit を使用した AWS CodeCommit への HTTPS 接続の設定手順](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-git-remote-codecommit.html)
  - git を拡張する CodeCommit 独自のツールで、Git 認証情報や SSH 公開鍵の登録が不要
  - リポジトリの URI が `codecommit::ap-northeast-1://your-repo-name` のようになる
- [AWS CLI 認証情報ヘルパーを使用する Linux, macOS, or Unix での AWS CodeCommit リポジトリへの HTTPS 接続のセットアップステップ](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-https-unixes.html)
  - AWS CLI に含まれている認証情報ヘルパーを使う方法

Argo CD ではパスワードによる HTTPS 接続か鍵による SSH 接続が可能。

- [Private Repositories](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/)
- [Secret Management](https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/)

Argo CD 用の IAM ユーザーを作成し、CodeCommit リポジトの参照権限を与える。

```sh
aws iam create-user --user-name argocd
cat <<EOF > argocd-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "codecommit:GitPull"
      ],
      "Resource": "*"
    }
  ]
}
EOF
aws iam create-policy \
  --policy-name argocd-policy \
  --policy-document file://argocd-policy.json
policy_arn=$(aws iam list-policies --query 'Policies[?PolicyName==`argocd-policy`].{ARN:Arn}' --output text)
aws iam attach-user-policy --user-name argocd --policy-arn ${policy_arn}
```

SSH 接続の場合はまず鍵ペアを生成する。

```sh
ssh-keygen -t rsa -b 4096 -f ./id_rsa -N '' -C ''
```

公開鍵を IAM ユーザーに登録する。

- [upload-ssh-public-key](https://docs.aws.amazon.com/cli/latest/reference/iam/upload-ssh-public-key.html)

```sh
aws iam upload-ssh-public-key \
  --user-name argocd \
  --ssh-public-key-body file://id_rsa.pub
```

 （参考）HTTPS 接続

HTTPS 接続の場合は以下コマンドで認証情報を生成する。パスワードはこのときしか表示されないので注意。

- [create-service-specific-credential](https://docs.aws.amazon.com/cli/latest/reference/iam/create-service-specific-credential.html)

```sh
aws iam create-service-specific-credential \
  --user-name argocd \
  --service-name codecommit.amazonaws.com
```

### CodeCommit

CodeCommit リポジトリを3つ作成する。

|リポジトリ名|用途|
|---|---|
|frontend|frontend アプリケーションのソースコードと Dockerfile 格納用リポジトリ|
|backend|backend アプリケーションのソースコードと Dockerfile 格納用リポジトリ|
|infra|Kubernetes マニフェストの格納用リポジトリ|

```sh
aws cloudformation deploy \
  --stack-name gitops-codecommit-stack \
  --template-file cfn/codecommit.yaml
```

### ソースを CodeCommit に登録

ローカルからのプッシュについては、[認証情報ヘルパー](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-https-unixes.html)を使うこともできるが、ここでは [git-remote-codecommit](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-git-remote-codecommit.html) を使用する。

はじめに、CodeCommit リポジトリの URI を変数に入れておく。

```sh
frontend_codecommit_http=$(aws codecommit get-repository --repository-name frontend --query 'repositoryMetadata.cloneUrlHttp' --output text)
frontend_codecommit_ssh=$(aws codecommit get-repository --repository-name frontend --query 'repositoryMetadata.cloneUrlSsh' --output text)
frontend_codecommit_grc="codecommit::ap-northeast-1://frontend"
backend_codecommit_http=$(aws codecommit get-repository --repository-name backend --query 'repositoryMetadata.cloneUrlHttp' --output text)
backend_codecommit_ssh=$(aws codecommit get-repository --repository-name backend --query 'repositoryMetadata.cloneUrlSsh' --output text)
backend_codecommit_grc="codecommit::ap-northeast-1://backend"
infra_codecommit_http=$(aws codecommit get-repository --repository-name infra --query 'repositoryMetadata.cloneUrlHttp' --output text)
infra_codecommit_ssh=$(aws codecommit get-repository --repository-name infra --query 'repositoryMetadata.cloneUrlSsh' --output text)
infra_codecommit_grc="codecommit::ap-northeast-1://infra"
for repo in frontend backend infra; do
  for protocol in http ssh grc; do
    eval echo '$'${repo}'_codecommit_'${protocol}
  done
done
```

frontend アプリケーションのソースを CodeCommit にプッシュする。`production` ブランチも作成しておく。

```sh
cd frontend/
git init
git remote add origin ${frontend_codecommit_grc}
git add .
git commit -m "first commit"
git push -u origin main
git checkout -b production
git push -u origin production
git checkout main
```

backend アプリケーションのソースを CodeCommit にプッシュする。`production` ブランチも作成しておく。

```sh
cd ../backend/
git init
git remote add origin ${backend_codecommit_grc}
git add .
git commit -m "first commit"
git push -u origin main
git checkout -b production
git push -u origin production
git checkout main
```

infra のマニフェストを CodeCommit にプッシュする。一部のマニフェストには AWS アカウント ID や SSH キー ID が含まれているので、自身の環境に合わせて一括置換する。`production` ブランチも作成しておく。

```sh
cd ../infra/
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ssh_key_id=$(aws iam list-ssh-public-keys --user-name argocd | jq -r '.SSHPublicKeys[].SSHPublicKeyId')
find . -type f -name "*.yaml" -print0 | xargs -0 sed -i "" -e "s/XXXX_AWS_ACCOUNT_ID_XXXX/${AWS_ACCOUNT_ID}/"
find . -type f -name "*.yaml" -print0 | xargs -0 sed -i "" -e "s/XXXX_SSH_KEY_ID_XXXX/${ssh_key_id}/"
git init
git remote add origin ${infra_codecommit_grc}
git add .
git commit -m "first commit"
git push -u origin main
git checkout -b production
git push -u origin production
git checkout main
cd ../
```

### ECR

ECR リポジトリを 2 つ作成する。

|リポジトリ名|用途|
|---|---|
|frontend|frontend アプリケーションの Docker イメージ格納用リポジトリ|
|backend|backend アプリケーションの Docker イメージ格納用リポジトリ|

```sh
aws cloudformation deploy \
  --stack-name gitops-ecr-stack \
  --template-file cfn/ecr.yaml
```

ECR リポジトリの URI を変数に入れておく。

```sh
frontend_ecr=$(aws ecr describe-repositories --repository-names frontend --query 'repositories[0].repositoryUri' --output text)
backend_ecr=$(aws ecr describe-repositories --repository-names backend --query 'repositories[0].repositoryUri' --output text)
for repo in frontend backend; do
  eval echo '$'${repo}'_ecr'
done
```

### イメージビルド用の CodePipeline と CodeBuild

コンテナイメージをビルドしてイメージを ECR にプッシュするパイプラインを作成する。

パイプラインは 4 つ作成する。

|パイプライン名|用途|
|---|---|
|frontend-main-pipeline|frontend リポジトリの `main` ブランチへのコミットをトリガーに起動|
|backend-main-pipeline|backend リポジトリの `main` ブランチへのコミットをトリガーに起動|
|frontend-production-pipeline|frontend リポジトリの `production` ブランチへのコミットをトリガーに起動|
|backend-procution-pipeline|backend リポジトリの `production` ブランチへのコミットをトリガーに起動|

CodeBuild プロジェクトは環境毎に共有し、2 つ作成する。

|CodeBuild プロジェクト名|用途|
|---|---|
|frontend-build|frontend アプリケーションのイメージビルド用|
|backend-build|backend アプリケーションのイメージビルド用|

以下を参考にテンプレートを作成する

- [例 1: AWS CloudFormation を使用して AWS CodeCommit パイプラインを作成する](https://docs.aws.amazon.com/ja_jp/codepipeline/latest/userguide/tutorials-cloudformation-codecommit.html)

CodePipeline 用の S3 バケットを作成する。

```sh
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
codepipeline_artifactstore_bucket="codepipeline-artifactstore-${AWS_ACCOUNT_ID}"
aws cloudformation deploy \
  --stack-name gitops-codepipeline-bucket-stack \
  --template-file cfn/codepipeline-bucket.yaml \
  --parameter-overrides CodePipelineArtifactStoreBucketName=${codepipeline_artifactstore_bucket}
```

CodeBuild プロジェクトを作成する。プロジェクトはアプリケーション毎に作成し、環境では共有する。つまり 2 つ作成する。
プロジェクトを環境毎に分けてもよいが、今回は CodePipeline から CodeBuild に `PIPELINE_BRANCH_NAME` という環境変数でブランチ名を渡すようにしている。

```sh
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
codepipeline_artifactstore_bucket="codepipeline-artifactstore-${AWS_ACCOUNT_ID}"
for app in frontend backend; do
  dockerhub_secret=$(aws secretsmanager list-secrets | jq -r '.SecretList[] | select( .Name == "dockerhub" ) | .ARN')
  aws cloudformation deploy \
    --stack-name gitops-${app}-codebuild-stack \
    --template-file cfn/codebuild.yaml \
    --parameter-overrides \
        CodeBuildProjectName=${app}-build \
        CodePipelineArtifactStoreBucketName=${codepipeline_artifactstore_bucket} \
        DockerHubSecret=${dockerhub_secret} \
    --capabilities CAPABILITY_NAMED_IAM
done
```

CodePipeline を作成する。パイプラインはアプリケーション毎かつ環境毎に作成する。つまり 4 つ作成する。

```sh
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
codepipeline_artifactstore_bucket="codepipeline-artifactstore-${AWS_ACCOUNT_ID}"
for branch in main production; do
  for app in frontend backend; do
    aws cloudformation deploy \
      --stack-name gitops-${app}-${branch}-pipeline-stack \
      --template-file cfn/codepipeline.yaml \
      --parameter-overrides \
          CodeBuildProjectName=${app}-build \
          CodePipelineArtifactStoreBucketName=${codepipeline_artifactstore_bucket} \
          CodeCommitRepositoryName=${app} \
          CodeCommitBranchName=${branch} \
      --capabilities CAPABILITY_NAMED_IAM
  done
done
```

マネジメントコンソールからパイプラインの状態を確認し、パイプラインが成功していれば infra リポジトリにはプルリクエストが作成され、マージされているはず。

ビルドパイプラインを手動実行する場合は以下のコマンドで実行できる。

```sh
aws codepipeline start-pipeline-execution --name frontend-main-pipeline
```

### (オプション) テスト用の CodeBuild

プルリクエストをトリガーとしてアプリケーションのテストを行う CodeBuild を作成する。

CodeBuild 用の S3 バケットを作成する。

```sh
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
codebuild_artifactstore_bucket="codebuild-artifactstore-${AWS_ACCOUNT_ID}"
aws cloudformation deploy \
  --stack-name gitops-codebuild-bucket-stack \
  --template-file cfn/codebuild-bucket.yaml \
  --parameter-overrides CodeBuildArtifactStoreBucketName=${codebuild_artifactstore_bucket}
```

CodeBuild プロジェクトを作成する。プロジェクトはアプリケーション (リポジトリ) 毎に作成する

```sh
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
codebuild_artifactstore_bucket="codebuild-artifactstore-${AWS_ACCOUNT_ID}"
for app in frontend backend infra; do
  dockerhub_secret=$(aws secretsmanager list-secrets | jq -r '.SecretList[] | select( .Name == "dockerhub" ) | .ARN')
  aws cloudformation deploy \
    --stack-name gitops-${app}-codebuild-test-stack \
    --template-file cfn/codebuild-test.yaml \
    --parameter-overrides \
        CodeBuildProjectName=${app}-test \
        CodeCommitRepositoryName=${app} \
        CodeBuildArtifactStoreBucketName=${codebuild_artifactstore_bucket} \
        BuildSpecPath="buildspec-test.yml" \
        DockerHubSecret=${dockerhub_secret} \
    --capabilities CAPABILITY_NAMED_IAM
done
```

## クラスターの作成

### VPC の作成

クラスターの Blue/Green 切り替えを考慮し、VPC は eksctl とは別に作成する。

以下から参照できる CloudFormation テンプレートをそのまま使う。staging と production のクラスターは接続しないので、デフォルトの同じ CIDR を使う。

- https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/create-public-private-vpc.html

テンプレートを保存する。

```sh
wget https://s3.us-west-2.amazonaws.com/amazon-eks/cloudformation/2020-10-29/amazon-eks-vpc-private-subnets.yaml -P cfn
```

staging 用の VPC を作成する。

```sh
aws cloudformation deploy \
  --stack-name gitops-staging-vpc-stack \
  --template-file cfn/amazon-eks-vpc-private-subnets.yaml
```

production 用の VPC を作成する。

```sh
aws cloudformation deploy \
  --stack-name gitops-production-vpc-stack \
  --template-file cfn/amazon-eks-vpc-private-subnets.yaml
```

### クラスターの作成

staging の VPC スタックのパラメータを確認する。

```json
$ aws cloudformation describe-stacks --stack-name gitops-staging-vpc-stack | jq -r '.Stacks[].Outputs'
[
  {
    "OutputKey": "SecurityGroups",
    "OutputValue": "sg-06e99fe06fd87bf22",
    "Description": "Security group for the cluster control plane communication with worker nodes"
  },
  {
    "OutputKey": "VpcId",
    "OutputValue": "vpc-06ca05f948c53c581",
    "Description": "The VPC Id"
  },
  {
    "OutputKey": "SubnetIds",
    "OutputValue": "subnet-00ba83d23f5cac84b,subnet-027ac364f59b41170,subnet-0732433774c76279a,subnet-08460b3c7a1cdcdcc",
    "Description": "Subnets IDs in the VPC"
  }
]
```

この出力に合わせて `staging.yaml` の VPC 定義を書き換える。サブネットの AZ とパブリックかプライベートかはマネコンから確認する。

```yaml
vpc:
  id: vpc-06ca05f948c53c581
  subnets:
    public:
      ap-northeast-1a:
          id: subnet-00ba83d23f5cac84b
      ap-northeast-1c:
          id: subnet-027ac364f59b41170
    private:
      ap-northeast-1a:
          id: subnet-0732433774c76279a
      ap-northeast-1c:
          id: subnet-08460b3c7a1cdcdcc
```

staging クラスターを作成する。

```sh
eksctl create cluster -f staging.yaml
```

同様に production クラスターも作成する。

```shell
aws cloudformation describe-stacks --stack-name gitops-production-vpc-stack | jq -r '.Stacks[].Outputs'
```

```sh
eksctl create cluster -f production.yaml
```

### ノードグループの作成

ノードグループを作成する。

```sh
eksctl create nodegroup -f staging-ng1.yaml
```

```sh
eksctl create nodegroup -f production-ng1.yaml
```

### IRSA

いくつかの Pod は IAM ロールが必要なため、IAM Roles for Service Accounts(IRSA) を設定する。

IRSA 関連の操作に eksctl を使ってもよいが、ロール名が自動生成となるため、そのロール名を Kubernetes マニフェストに反映する必要がある。
今回はなるべく eksctl を使わないことにする。使わない場合のやり方は以下にまとまっている。

- [Kubernetes サービスアカウントに対するきめ細やかな IAM ロール割り当ての紹介](https://aws.amazon.com/jp/blogs/news/introducing-fine-grained-iam-roles-service-accounts/)
- [サービスアカウントの IAM ロールとポリシーの作成](https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/create-service-account-iam-policy-and-role.html)

#### OICD プロバイダーの作成

OICD プロバイダーはクラスターの作成時に有効化済み。

#### DynamoDB

このサンプルアプリケーションは DynamoDB にアクセスするので、IRSA で `backend` のPodに適切な権限を設定する必要がある。

テーブルと IAM ロールを作成する。ServiceAccount のマニフェストではアノテーションでこの IAM ロールを指定し、Deployment のマニフェストでは ServiceAccount を指定する。

```sh
for cluster_name in staging production; do
  oidc_provider=$(aws eks describe-cluster --name ${cluster_name} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
  aws cloudformation deploy \
    --stack-name gitops-${cluster_name}-dynamodb-stack \
    --template-file cfn/dynamodb.yaml \
    --parameter-overrides ClusterName=${cluster_name}
  aws cloudformation deploy \
    --stack-name gitops-${cluster_name}-backend-iam-stack \
    --template-file cfn/backend-iam.yaml \
    --parameter-overrides TableName=messages-${cluster_name%%-*} ClusterName=${cluster_name} NamespaceName=backend ServiceAccountName=backend OidcProvider=${oidc_provider} \
    --capabilities CAPABILITY_NAMED_IAM
done
```

#### AWS Load Balancer Controller

[AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) が使用する IAM ロールを作成する。

```sh
for cluster_name in staging production; do
  oidc_provider=$(aws eks describe-cluster --name ${cluster_name} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
  aws cloudformation deploy \
    --stack-name gitops-${cluster_name}-aws-load-balancer-controller-iam-stack \
    --template-file cfn/aws-load-balancer-controller-iam.yaml \
    --parameter-overrides ClusterName=${cluster_name} NamespaceName=kube-system ServiceAccountName=aws-load-balancer-controller OidcProvider=${oidc_provider} \
    --capabilities CAPABILITY_NAMED_IAM
done
```

#### Cluster Autoscaler

[Cluster Autoscaler](https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/cluster-autoscaler.html) が使用する IAM ロールを作成する。

```sh
for cluster_name in staging production; do
  oidc_provider=$(aws eks describe-cluster --name ${cluster_name} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
  aws cloudformation deploy \
    --stack-name gitops-${cluster_name}-cluster-autoscaler-iam-stack \
    --template-file cfn/cluster-autoscaler-iam.yaml \
    --parameter-overrides ClusterName=${cluster_name} NamespaceName=kube-system ServiceAccountName=cluster-autoscaler OidcProvider=${oidc_provider} \
    --capabilities CAPABILITY_NAMED_IAM
done
```

#### External Secrets Operator

[External Secrets Operator](https://github.com/external-secrets/external-secrets) が使用する IAM ロールを作成する。

```sh
for cluster_name in staging production; do
  oidc_provider=$(aws eks describe-cluster --name ${cluster_name} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
  aws cloudformation deploy \
    --stack-name gitops-${cluster_name}-external-secrets-iam-stack \
    --template-file cfn/external-secrets-iam.yaml \
    --parameter-overrides ClusterName=${cluster_name} NamespaceName=external-secrets ServiceAccountName=external-secrets OidcProvider=${oidc_provider} \
    --capabilities CAPABILITY_NAMED_IAM
done
```

サンプルのシークレットを作成しておく。

```sh
for cluster_name in staging production; do
  aws secretsmanager create-secret \
    --region ap-northeast-1 \
    --name mydb/${cluster_name} \
    --secret-string '{"username":"admin","password":"1234"}'
done
```

#### Container Insights

[Container Insights](https://docs.aws.amazon.com/ja_jp/AmazonCloudWatch/latest/monitoring/deploy-container-insights-EKS.html) が使用する IAM ロールを作成する。

```sh
for cluster_name in staging production; do
  oidc_provider=$(aws eks describe-cluster --name ${cluster_name} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
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

### staging クラスターへのアプリケーションのデプロイ

kubectl のコンテキストを staging クラスターに切り替えてから作業すること。

#### ArgoCD のデプロイ

Argo CD をデプロイする。

- [Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/)

```sh
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

今回はポートフォワードを前提として Load Balancer は作成しない。ポートフォワードする。

```sh
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

パスワードを取得してログインする。

```sh
argocd_server=localhost:8080
argocd_pwd=$(kubectl -n argocd get secret argocd-initial-admin-secret -o json | jq -r '.data.password' | base64 --decode)
export ARGOCD_OPTS='--port-forward-namespace argocd'
argocd login ${argocd_server} --username admin --password ${argocd_pwd} --insecure
```

パスワードを確認して [http://localhost:8080](http://localhost:8080) からアクセスも可能。

```she
echo ${argocd_pwd}
```

#### CodeCommit リポジトリの登録

CodeCommit リポジトリを登録する。

プライベートリポジトリの場合は、`--insecure-skip-server-verification` フラグで SSH host key のチェックを無効化するか、あらかじめ SSH host key を追加する必要がある。ここでは CodeCommit の SSH host key を追加する。ここで追加されるものは infra/argocd/base/argocd-ssh-known-hosts-cm.yaml にも登録してある。

```sh
ssh-keyscan git-codecommit.ap-northeast-1.amazonaws.com | argocd cert add-ssh --batch
```

確認する。

```sh
argocd cert list --cert-type ssh
```

CodeCommit リポジトリを追加する。`ssh://` の後ろに SSH キー ID を指定する必要がある。

```sh
ssh_key_id=$(aws iam list-ssh-public-keys --user-name argocd | jq -r '.SSHPublicKeys[].SSHPublicKeyId')
argocd repo add ssh://${ssh_key_id}@git-codecommit.ap-northeast-1.amazonaws.com/v1/repos/infra \
  --ssh-private-key-path ./id_rsa
```

SSH host key が認識されるまでに時間がかかるのか、失敗する場合は少しだけ待ってからやると上手くいく。

確認する。

```sh
argocd repo list
```

秘密鍵は `repo-XXXXXXXXXX` という Secret に格納される。

```sh
k get secret -n argocd
```

以上で Argo CD のセットアップが完了。

（参考）HTTPS 接続の場合

```sh
argocd repo add ${infra_codecommit_http} --username <username> --password <password>
```

認証情報は `repo-XXXXXXXXXX` というSecretに格納される。

#### Argo CD の Application リソースの作成

今回 CodeCommit リポジトリはそれぞれ以下のブランチ戦略をとる。

|リポジトリ名|ブランチ戦略|
|---|---|
|frontend|`main` ブランチを staging 環境、`production` ブランチを production 環境にデプロイ|
|backend|`main` ブランチを staging 環境、`production` ブランチを production 環境にデプロイ|
|infra|`main` ブランチを staging 環境、`production` ブランチを production 環境にデプロイする。さらに各環境の差分もディレクトリ毎に保持する|

また、App of Apps 構成とし、infra リポジトリの app ディレクトリに Argo CD の Application リソースの定義を格納する。

- [Cluster Bootstrapping](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)

App of Apps の Application を作成する。

```sh
cluster_name=staging
branch=main
# cluster_name=production
# branch=production
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

確認する。

```sh
argocd app list
```

もし Sync が上手くいかなかった場合は手動 Sync を試す。

```sh
argocd app sync <App名>
```

#### 動作確認

Pod が正常に稼働していることを確認する。

```sh
$ k get po -A
NAMESPACE           NAME                                               READY   STATUS    RESTARTS      AGE
amazon-cloudwatch   cloudwatch-agent-7fvd4                             1/1     Running   2 (27h ago)   16d
amazon-cloudwatch   cloudwatch-agent-zmclk                             1/1     Running   2 (27h ago)   16d
amazon-cloudwatch   fluent-bit-jgfqm                                   1/1     Running   2 (27h ago)   16d
amazon-cloudwatch   fluent-bit-lfpgj                                   1/1     Running   2 (27h ago)   16d
argocd              argocd-application-controller-0                    1/1     Running   0             11m
argocd              argocd-applicationset-controller-bbf48bd7c-vrttz   1/1     Running   0             11m
argocd              argocd-dex-server-7d757d85d5-xfsdv                 1/1     Running   0             11m
argocd              argocd-notifications-controller-7b7c9854dd-fgdmq   1/1     Running   0             11m
argocd              argocd-redis-65596bf87-n4q98                       1/1     Running   2 (27h ago)   16d
argocd              argocd-repo-server-c996ccd4-9lc8t                  1/1     Running   0             11m
argocd              argocd-server-86576f9c7d-djh7z                     1/1     Running   0             11m
backend             backend-68b956cd54-q54kd                           1/1     Running   2 (27h ago)   16d
backend             backend-68b956cd54-rmns7                           1/1     Running   2 (27h ago)   16d
cert-manager        cert-manager-795d7f859d-q2kx7                      1/1     Running   2 (27h ago)   16d
cert-manager        cert-manager-cainjector-5fcddc948c-rjfvl           1/1     Running   2 (27h ago)   16d
cert-manager        cert-manager-webhook-5b64f87794-d8fc5              1/1     Running   2 (27h ago)   16d
external-secrets    external-secrets-8f7d97cb-g6skp                    1/1     Running   0             83s
external-secrets    external-secrets-cert-controller-bd9964f5d-rhn7f   1/1     Running   0             83s
external-secrets    external-secrets-webhook-589cfdf4f7-jfqdr          1/1     Running   0             83s
frontend            frontend-55d96fb5cf-9n4gx                          1/1     Running   2 (27h ago)   16d
frontend            frontend-55d96fb5cf-kh8w8                          1/1     Running   2 (27h ago)   16d
kube-system         aws-load-balancer-controller-6745dc6569-2nn4t      1/1     Running   2 (27h ago)   16d
kube-system         aws-node-6qjzl                                     1/1     Running   3 (27h ago)   16d
kube-system         aws-node-fltvm                                     1/1     Running   2 (27h ago)   16d
kube-system         coredns-69cfddc4b4-h7h7j                           1/1     Running   2 (27h ago)   16d
kube-system         coredns-69cfddc4b4-jb7gg                           1/1     Running   2 (27h ago)   16d
kube-system         kube-proxy-d5fvq                                   1/1     Running   2 (27h ago)   16d
kube-system         kube-proxy-xrnss                                   1/1     Running   2 (27h ago)   16d
kube-system         metrics-server-847dcc659d-frr4w                    1/1     Running   2 (27h ago)   16d
```

URL を確認する。

```sh
$ kubectl get ingress -n frontend
NAME       HOSTS   ADDRESS                                                                       PORTS   AGE
frontend   *       XXXXXXXX-frontend-frontend-XXXX-XXXXXXXXXX.ap-northeast-1.elb.amazonaws.com   80      4m37s
```

URL にアクセスしてアプリケーションが動作することを確認する。

### production クラスターへのアプリケーションのデプロイ

kubectl のコンテキストを production クラスターに切り替え、同じ作業をクラスターを実施する。

## 補足

### CodeBuild からのプルリク作成

以下が参考になる。

- [create-pull-request](https://docs.aws.amazon.com/cli/latest/reference/codecommit/create-pull-request.html)
- [ビルド環境の環境変数](https://docs.aws.amazon.com/ja_jp/codebuild/latest/userguide/build-env-ref-env-vars.html)
- [AWS CLI 認証情報ヘルパーを使用する Linux, macOS, or Unix での AWS CodeCommit リポジトリへの HTTPS 接続のセットアップステップ](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-https-unixes.html)

詳しくは `buildspec.yaml` を参照。

### Kustomize

Kustomize 流のディレクトリ構成については以下の資料を参照。

- [Introduction to kustomize](https://speakerdeck.com/spesnova/introduction-to-kustomize)

Argo CD は Kustomize かどうかは自動判別してくれる。pathの指定で `kustomize build` を実行するディレクトリを指定する。

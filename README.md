# eks-gitops-sample

EKSで以下のスタックを使ったGitOpsのサンプル構成を作成する。

|役割|ツール|
|---|---|
|ソース管理|CodeCommit|
|CI|CodeBuild|
|CD|Argo CD + Kustomize|
|イメージレジストリ|ECR|

シングルアカウントの中にStagingとProductionのクラスターを構成する。

![](./architecture.drawio.svg)

コンポーネントのバージョンは以下で確認。

|コンポーネント|バージョン|
|---|---|
|Kubernetes バージョン|1.20|
|Argo CD|v2.0.4|
|AWS Load Balancer Controller|v2.2.0|
|Kubernetes External Secrets|7.2.1|

## 参考リンク

- [GitOpsで絶対に避けて通れないブランチ戦略](https://amaya382.hatenablog.jp/entry/2019/12/02/192159)
- [Argo CDによる継続的デリバリーのベストプラクティスとその実装](https://blog.cybozu.io/entry/2019/11/21/100000)
- [https://github.com/cybozu-go/neco-apps](https://github.com/cybozu-go/neco-apps)

## パイプラインの構築

GitOpsでCIとCDは分離するので、CIを行うパイプラインを最初に作成する。

### Docker Hubのクレデンシャル作成

レートリミットを回避するため、CodeBuildではDocker Hubにログインする。そのためのユーザー名とパスワードをSecrets Managerに格納しておく。

```sh
aws secretsmanager create-secret \
  --region ap-northeast-1 \
  --name dockerhub \
  --secret-string '{"username":"hogehoge","password":"fugafuga"}'
```

クラスター上でもDocker Hubからのイメージ取得がレートリミットに引っかかることがあるため、imagePullSecretとして使用するためのdockerconfigjsonを作成しておく。

```sh
dockerconfigjson=$(kubectl create secret docker-registry mysecret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=hogehoge \
  --docker-password=fugafuga --dry-run=client -o json \
  | jq -r '.data.".dockerconfigjson"' | base64 --decode)
aws secretsmanager create-secret \
  --region ap-northeast-1 \
  --name dockerconfigjson \
  --secret-string ${dockerconfigjson}
```

### SecurityHubでのTrivyの統合

SeurityHubでTrivyの結果を受け入れるように設定する。Aquaとの統合を有効化する。

```shell
aws securityhub enable-import-findings-for-product --product-arn arn:aws:securityhub:ap-northeast-1::product/aquasecurity/aquasecurity
```

### Argo CD用のIAMユーザーの作成

Argo CDがCodeCommitにアクセスするためのIAMユーザーを作成する。クラスターごとにIAMユーザーを分けてもよいが、今回はユーザーを共用するので、この操作は1回だけ実施する。

CodeCommitへのアクセスにはいくつかの選択肢がある。

- [Git 認証情報を使用する HTTPS ユーザー用のセットアップ](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-gc.html)
  - IAMユーザーに関連付けられたユーザー名とパスワードを使用する方法
- [AWS CLI を使用していない SSH ユーザーの セットアップ](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-without-cli.html)
  - IAMユーザーに関連付けられたSSH公開鍵を使用する方法
- [git-remote-codecommit を使用した AWS CodeCommit への HTTPS 接続の設定手順](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-git-remote-codecommit.html)
  - gitを拡張するツールで、Git認証情報やSSH公開鍵に登録が不要
  - git clone codecommit::ap-northeast-1://your-repo-name
- [AWS CLI 認証情報ヘルパーを使用する Linux, macOS, or Unix での AWS CodeCommit リポジトリへの HTTPS 接続のセットアップステップ](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-https-unixes.html)
  - AWS CLIに含まれている認証情報ヘルパーを使う方法

Argo CDではパスワードによるHTTPS接続か鍵によるSSH接続が可能。

- [Private Repositories](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/)
- [Secret Management](https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/)

Argo CD用のIAMユーザーを作成し、CodeCommitリポジトの参照権限を与える。

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

SSH接続の場合はまず鍵ペアを生成する。

```sh
ssh-keygen -t rsa -f ./id_rsa -N '' -C ''
```

公開鍵をIAMユーザーに登録する。

- [upload-ssh-public-key](https://docs.aws.amazon.com/cli/latest/reference/iam/upload-ssh-public-key.html)

```sh
aws iam upload-ssh-public-key \
  --user-name argocd \
  --ssh-public-key-body file://id_rsa.pub
```

 （参考）HTTPS接続

HTTPS接続の場合は以下コマンドで認証情報を生成する。パスワードはこのときしか表示されないので注意。

- [create-service-specific-credential](https://docs.aws.amazon.com/cli/latest/reference/iam/create-service-specific-credential.html)

```sh
aws iam create-service-specific-credential \
  --user-name argocd \
  --service-name codecommit.amazonaws.com
```

### CodeCommit

CodeCommitリポジトリを3つ作成する。

|リポジトリ名|用途|
|---|---|
|frontend|frontendアプリケーションのソースコードとDockerfile格納用リポジトリ|
|backend|backendアプリケーションのソースコードとDockerfile格納用リポジトリ|
|infra|Kubernetesマニフェストの格納用リポジトリ|

```sh
aws cloudformation deploy \
  --stack-name gitops-codecommit-stack \
  --template-file cfn/codecommit.yaml
```

### ソースをCodeCommitに登録

ローカルからのpushについては、[認証情報ヘルパー](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-https-unixes.html)を使うこともできるが、ここでは[git-remote-codecommit](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-git-remote-codecommit.html)を使用する。

はじめに、CodeCommitリポジトリのURLを変数に入れておく。

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

frontendアプリケーションのソースをCodeCommitにpushする。`production`ブランチも作成しておく。

```sh
cd frontend/
git init
git add .
git commit -m "first commit"
git remote add origin ${frontend_codecommit_grc}
git push -u origin main
git checkout -b production
git push -u origin production
git checkout main
```

backendアプリケーションのソースをCodeCommitにpushする。`production`ブランチも作成しておく。

```sh
cd ../backend/
git init
git add .
git commit -m "first commit"
git remote add origin ${backend_codecommit_grc}
git push -u origin main
git checkout -b production
git push -u origin production
git checkout main
```

infraのマニフェストをCodeCommitにpushする。一部のマニフェストにはAWSアカウントIDやSSHキーIDが含まれているので、自身の環境に合わせて一括置換する。`production`ブランチも作成しておく。

```sh
cd ../infra/
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ssh_key_id=$(aws iam list-ssh-public-keys --user-name argocd | jq -r '.SSHPublicKeys[].SSHPublicKeyId')
find . -type f -name "*.yaml" -print0 | xargs -0 sed -i "" -e "s/XXXX_AWS_ACCOUNT_ID_XXXX/${AWS_ACCOUNT_ID}/"
find . -type f -name "*.yaml" -print0 | xargs -0 sed -i "" -e "s/XXXX_SSH_KEY_ID_XXXX/${ssh_key_id}/"
git init
git add .
git commit -m "first commit"
git remote add origin ${infra_codecommit_grc}
git push -u origin main
git checkout -b production
git push -u origin production
git checkout main
cd ../
```

### ECR

ECRリポジトリを2つ作成する。

|リポジトリ名|用途|
|---|---|
|frontend|frontendアプリケーションのDockerイメージ格納用リポジトリ|
|backend|backendアプリケーションのDockerイメージ格納用リポジトリ|

```sh
aws cloudformation deploy \
  --stack-name gitops-ecr-stack \
  --template-file cfn/ecr.yaml
```

ECRリポジトリのURLを変数に入れておく。

```sh
frontend_ecr=$(aws ecr describe-repositories --repository-names frontend --query 'repositories[0].repositoryUri' --output text)
backend_ecr=$(aws ecr describe-repositories --repository-names backend --query 'repositories[0].repositoryUri' --output text)
for repo in frontend backend; do
  eval echo '$'${repo}'_ecr'
done
```

### CodePipelineとCodeBuild

コンテナイメージをbuildしてイメージをECRにpushするパイプラインを作成する。

パイプラインは4つ作成する。

|パイプライン名|用途|
|---|---|
|frontend-main-pipeline|frontendリポジトリの`main`ブランチへのコミットをトリガーに起動|
|backend-main-pipeline|backendリポジトリの`main`ブランチへのコミットをトリガーに起動|
|frontend-production-pipeline|frontendリポジトリの`production`ブランチへのコミットをトリガーに起動|
|backend-procution-pipeline|backendリポジトリの`production`ブランチへのコミットをトリガーに起動|

CodeBuildプロジェクトは環境毎に共有し、2つ作成する。

|CodeBuildプロジェクト名|用途|
|---|---|
|frontend-build|frontendアプリケーションのイメージビルド|
|backend-build|backendアプリケーションのイメージビルド用|

以下を参考にテンプレートを作成。

- [例 1: AWS CloudFormation を使用して AWS CodeCommit パイプラインを作成する](https://docs.aws.amazon.com/ja_jp/codepipeline/latest/userguide/tutorials-cloudformation-codecommit.html)

CodePipeline用のS3バケットを作成する。

```sh
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
codepipeline_artifactstore_bucket="codepipeline-artifactstore-${AWS_ACCOUNT_ID}"
aws cloudformation deploy \
  --stack-name gitops-codepipeline-bucket-stack \
  --template-file cfn/codepipeline-bucket.yaml \
  --parameter-overrides CodePipelineArtifactStoreBucketName=${codepipeline_artifactstore_bucket}
```

CodeBuildプロジェクトを作成する。プロジェクトはアプリケーション毎に作成し、環境では共有する。つまり2つ作成する。
プロジェクトを環境毎に分けてもよいが、今回はCodePipelineからCodeBuildに`PIPELINE_BRANCH_NAME`という環境変数でブランチ名を渡すようにしている。

```sh
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
codepipeline_artifactstore_bucket="codepipeline-artifactstore-${AWS_ACCOUNT_ID}"
for app in frontend backend; do
  dockerhub_secret=$(aws secretsmanager list-secrets | jq -r '.SecretList[] | select( .Name == "dockerhub" ) | .ARN')
  aws cloudformation deploy \
    --stack-name gitops-${app}-codebuild-stack \
    --template-file cfn/codebuild.yaml \
    --parameter-overrides CodeBuildProjectName=${app}-build \
        CodePipelineArtifactStoreBucketName=${codepipeline_artifactstore_bucket} \
        DockerHubSecret=${dockerhub_secret} \
    --capabilities CAPABILITY_NAMED_IAM
done
```

CodePipelineを作成する。パイプラインはアプリケーション毎かつ環境毎に作成する。つまり4つ作成する。

```sh
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
codepipeline_artifactstore_bucket="codepipeline-artifactstore-${AWS_ACCOUNT_ID}"
for branch in main production; do
  for app in frontend backend; do
    aws cloudformation deploy \
      --stack-name gitops-${app}-${branch}-pipeline-stack \
      --template-file cfn/codepipeline.yaml \
      --parameter-overrides CodePipelineArtifactStoreBucketName=${codepipeline_artifactstore_bucket} CodeCommitRepositoryName=${app} CodeCommitBranchName=${branch} CodeBuildProjectName=${app}-build \
      --capabilities CAPABILITY_NAMED_IAM
  done
done
```

### イメージタグの更新

マネジメントコンソールからパイプラインの状態を確認し、パイプラインが成功していればinfraリポジトリにはプルリクエストが作成されているはずなのでマージする。

ビルドパイプラインを手動実行する場合は以下のコマンドで実行できるが、同じコミットからCodeBuildによって作成された別のブランチがinfraリポジトリにあると失敗するのでブランチを削除してから実施する。

```sh
aws codepipeline start-pipeline-execution --name frontend-main-pipeline
```

## クラスターの作成
### VPCの作成

クラスターのBlue/Green切り替えを考慮し、VPCはeksctlとは別に作成する。

以下から参照できるCloudFormationテンプレートをそのまま使う。stagingとproductionのクラスターは接続しないので、デフォルトの同じCIDRを使う。

- https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/create-public-private-vpc.html

staging用のVPCを作成する。

```sh
aws cloudformation deploy \
  --stack-name gitops-staging-vpc-stack \
  --template-file cfn/amazon-eks-vpc-private-subnets.yaml
```

production用のVPCを作成する。

```sh
aws cloudformation deploy \
  --stack-name gitops-production-vpc-stack \
  --template-file cfn/amazon-eks-vpc-private-subnets.yaml
```

### クラスターの作成

stagingのVPCスタックのパラメータを確認する。

```json
$ aws cloudformation describe-stacks --stack-name gitops-staging-vpc-stack | jq -r '.Stacks[].Outputs'
[
  {
    "OutputKey": "SecurityGroups",
    "OutputValue": "sg-01b01e539121d8d82",
    "Description": "Security group for the cluster control plane communication with worker nodes"
  },
  {
    "OutputKey": "VpcId",
    "OutputValue": "vpc-0be6ec61c0615640f",
    "Description": "The VPC Id"
  },
  {
    "OutputKey": "SubnetIds",
    "OutputValue": "subnet-0082a777db9e2c323,subnet-0557418851a60ebae,subnet-00ae15e7ef85b18f4,subnet-0990c739a11cec49c",
    "Description": "Subnets IDs in the VPC"
  }
]
```

この出力に合わせて`staging.yaml`のVPC定義を書き換える。AZとパブリックかプライベートかはマネコンから確認する。

```yaml
vpc:
  id: vpc-0be6ec61c0615640f
  subnets:
    public:
      ap-northeast-1a:
          id: subnet-0082a777db9e2c323
      ap-northeast-1c:
          id: subnet-0557418851a60ebae
    private:
      ap-northeast-1a:
          id: subnet-00ae15e7ef85b18f4
      ap-northeast-1c:
          id: subnet-0990c739a11cec49c
```

stagingクラスターを作成する。

```sh
eksctl create cluster -f staging.yaml
```

同様にproductionクラスターも作成する。

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

いくつかのPodはIAMロールが必要なため、IAM Roles for Service Accounts(IRSA)を設定する。

IRSA関連の操作にeksctlを使ってもよいが、ロール名が自動生成となりわかりにくいのと、そのロール名をKubernetesマニフェストに反映する必要がある。
今回はなるべくeksctlを使わないことにする。使わない場合のやり方は以下にまとまっている。

- [Kubernetes サービスアカウントに対するきめ細やかな IAM ロール割り当ての紹介](https://aws.amazon.com/jp/blogs/news/introducing-fine-grained-iam-roles-service-accounts/)
- [サービスアカウントの IAM ロールとポリシーの作成](https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/create-service-account-iam-policy-and-role.html)

#### OICDプロバイダー

OICDプロバイダーはクラスターの作成時に有効化済み。

#### DynamoDB

このサンプルアプリケーションはDynamoDBにアクセスするので、IRSAで`backend`のPodに適切な権限を設定する必要がある。

テーブルとIAMロールを作成する。ServiceAccountのマニフェストではアノテーションでこのIAMロールを指定し、DeploymentのマニフェストではServiceAccountを指定する。

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

[AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)が使用するIAMロールを作成する。

IAMロールを作成する。

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

#### Kubernetes External Secrets

[Kubernetes External Secrets](https://github.com/external-secrets/kubernetes-external-secrets)が使用するIAMロールを作成する。

IAMロールを作成する。

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

[Container Insights](https://docs.aws.amazon.com/ja_jp/AmazonCloudWatch/latest/monitoring/deploy-container-insights-EKS.html)が使用するIAMロールを作成する。

IAMロールを作成する。

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
### stagingクラスターへのアプリケーションのデプロイ

kubectlのコンテキストをstagingクラスターに切り替えてから作業すること。

#### ArgoCD のデプロイ

Argo CDをデプロイする。

- [Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/)

kubectlのコンテキストをstagingクラスターに切り替えてから作業すること。

```sh
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

今回はポートフォワードを前提としてLoad Balancerは作成しない。ポートフォワードする。

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

パスワードを確認して[http://localhost:8080](http://localhost:8080)からアクセスも可能。

```she
echo ${argocd_pwd}
```

#### CodeCommitリポジトリの登録

CodeCommitリポジトリを登録する。

プライベートリポジトリの場合は、`--insecure-skip-server-verification`フラグでSSH host keyのチェックを無効化するか、あらかじめSSH host keyを追加する必要がある。ここではCodeCommitのSSH host keyを追加する。

```sh
ssh-keyscan git-codecommit.ap-northeast-1.amazonaws.com | argocd cert add-ssh --batch
```

確認する。

```sh
argocd cert list --cert-type ssh
```

CodeCommitリポジトリを追加する。`ssh://`の後ろにSSHキーIDを指定する必要がある。

```sh
ssh_key_id=$(aws iam list-ssh-public-keys --user-name argocd | jq -r '.SSHPublicKeys[].SSHPublicKeyId')
argocd repo add ssh://${ssh_key_id}@git-codecommit.ap-northeast-1.amazonaws.com/v1/repos/infra \
  --ssh-private-key-path ./id_rsa
```

SSH host keyが認識されるまでに時間がかかるのか、失敗する場合は少しだけ待ってからやると上手くいく。

確認する。

```sh
argocd repo list
```

秘密鍵は`repo-XXXXXXXXXX`というSecretに格納される。

以上でArgo CDのセットアップが完了。

（参考）HTTPS接続の場合

```sh
argocd repo add ${infra_codecommit_http} --username <username> --password <password>
```

認証情報は`repo-XXXXXXXXXX`というSecretに格納される。

#### Argo CDのApplicationリソースの作成

今回CodeCommitリポジトリはそれぞれ以下のブランチ戦略をとる。

|リポジトリ名|ブランチ戦略|
|---|---|
|frontend|`main`ブランチをstaging環境、`production`ブランチをproduction環境にデプロイ|
|backend|`main`ブランチをstaging環境、`production`ブランチをproduction環境にデプロイ|
|infra|`main`ブランチをstaging環境、`production`ブランチをproduction環境にデプロイする。さらに各環境の差分もディレクトリ毎に保持する|

また、App of Apps構成とし、infraリポジトリのappディレクトリにArgo CDのApplicationリソースの定義を格納する。

- [Cluster Bootstrapping](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)

App of AppsのApplicationを作成する。

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

もしSyncが上手くいかなかった場合は手動Syncを試す。

```sh
argocd app sync <App名>
```

#### 動作確認

Podが正常に稼働していることを確認する。

```sh
$ k get po -A
NAMESPACE           NAME                                            READY   STATUS    RESTARTS   AGE
amazon-cloudwatch   cloudwatch-agent-ggspn                          1/1     Running   0          10m
amazon-cloudwatch   cloudwatch-agent-xkn9v                          1/1     Running   0          10m
amazon-cloudwatch   fluent-bit-6l4jm                                1/1     Running   0          10m
amazon-cloudwatch   fluent-bit-tbtnx                                1/1     Running   0          10m
argocd              argocd-application-controller-0                 1/1     Running   0          4m51s
argocd              argocd-dex-server-76ff776f97-v4qpt              1/1     Running   0          4m56s
argocd              argocd-redis-747b678f89-8rcn4                   1/1     Running   0          4m56s
argocd              argocd-repo-server-6fc4456c89-zhd7c             1/1     Running   0          4m56s
argocd              argocd-server-7d57bc994b-n49nf                  1/1     Running   0          4m56s
backend             backend-7d7857c7fc-6jmwv                        1/1     Running   0          6m32s
backend             backend-7d7857c7fc-7n4ck                        1/1     Running   0          6m32s
calico-system       calico-kube-controllers-57b4f8758f-f7v5s        1/1     Running   0          8m44s
calico-system       calico-node-nw99p                               1/1     Running   0          8m45s
calico-system       calico-node-p9bcg                               1/1     Running   0          8m45s
calico-system       calico-typha-578579ffdd-sbmbl                   1/1     Running   0          6m57s
calico-system       calico-typha-578579ffdd-zzvnj                   1/1     Running   0          8m45s
cert-manager        cert-manager-68ff46b886-2mp7b                   1/1     Running   0          8m37s
cert-manager        cert-manager-cainjector-7cdbb9c945-82p6q        1/1     Running   0          8m38s
cert-manager        cert-manager-webhook-67584ff488-28wcq           1/1     Running   0          8m38s
external-secrets    external-secrets-56fbfc9687-w2csf               1/1     Running   0          9m1s
frontend            frontend-697b78f6c8-bdwvv                       1/1     Running   0          9m1s
frontend            frontend-697b78f6c8-szph7                       1/1     Running   0          9m1s
gatekeeper-system   gatekeeper-audit-54b5f86d57-k49z8               1/1     Running   0          9m7s
gatekeeper-system   gatekeeper-controller-manager-5b96bd668-4vncl   1/1     Running   0          9m7s
gatekeeper-system   gatekeeper-controller-manager-5b96bd668-5qt2t   1/1     Running   0          9m7s
gatekeeper-system   gatekeeper-controller-manager-5b96bd668-psls2   1/1     Running   0          9m7s
kube-system         aws-load-balancer-controller-7b497985b6-qqtxn   1/1     Running   0          8m24s
kube-system         aws-node-2s8b6                                  1/1     Running   0          100m
kube-system         aws-node-c8dg9                                  1/1     Running   0          100m
kube-system         coredns-54bc78bc49-d8dgk                        1/1     Running   0          121m
kube-system         coredns-54bc78bc49-gnp55                        1/1     Running   0          121m
kube-system         kube-proxy-85xhh                                1/1     Running   0          100m
kube-system         kube-proxy-jf5sl                                1/1     Running   0          100m
kube-system         metrics-server-9f459d97b-b4ktf                  1/1     Running   0          10m
tigera-operator     tigera-operator-657cc89589-vvttr                1/1     Running   0          9m8s
```

URLを確認する。

```sh
$ kubectl get ingress -n frontend
NAME       HOSTS   ADDRESS                                                                       PORTS   AGE
frontend   *       XXXXXXXX-frontend-frontend-XXXX-XXXXXXXXXX.ap-northeast-1.elb.amazonaws.com   80      4m37s
```

URLにアクセスしてアプリケーションが動作することを確認する。

### productionクラスターへのアプリケーションのデプロイ

kubectlのコンテキストをproductionクラスターに切り替え、同じ作業をクラスターを実施する。

## 補足

### CodeBuildからのプルリク作成

以下が参考になる。

- [create-pull-request](https://docs.aws.amazon.com/cli/latest/reference/codecommit/create-pull-request.html)
- [ビルド環境の環境変数](https://docs.aws.amazon.com/ja_jp/codebuild/latest/userguide/build-env-ref-env-vars.html)
- [AWS CLI 認証情報ヘルパーを使用する Linux, macOS, or Unix での AWS CodeCommit リポジトリへの HTTPS 接続のセットアップステップ](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-https-unixes.html)

詳しくは`buildspec.yaml`を参照。

### Kustomize

Kustomize流のディレクトリ構成については以下の資料を参照。

- [Introduction to kustomize](https://speakerdeck.com/spesnova/introduction-to-kustomize)

Argo CDはKustomizeかどうかは自動判別してくれる。pathの指定で`kustomize build`を実行するディレクトリを指定する。

### App of Apps

Necoプロジェクトだと、以下がApp of Appsのディレクトリとなっており参考になる。

- [https://github.com/cybozu-go/neco-apps/tree/main/argocd-config/base](https://github.com/cybozu-go/neco-apps/tree/main/argocd-config/base)


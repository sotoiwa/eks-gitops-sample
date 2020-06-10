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
|eksctl|0.21.0|
|Kubernetes バージョン|1.16|
|プラットフォームのバージョン|eks.1|
|Argo CD|v1.5.6|
|Argo CD CLI|v1.5.6|

## 参考リンク

- [GitOpsで絶対に避けて通れないブランチ戦略](https://amaya382.hatenablog.jp/entry/2019/12/02/192159)
- [Argo CDによる継続的デリバリーのベストプラクティスとその実装](https://blog.cybozu.io/entry/2019/11/21/100000)
- [https://github.com/cybozu-go/neco-apps](https://github.com/cybozu-go/neco-apps)

## パイプラインの構築

GitOpsでCIとCDは分離するので、CIを行うパイプラインを最初に作成する。

### Argo CD用のIAMユーザーの作成

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

- [Private Repositories](https://argoproj.github.io/argo-cd/user-guide/private-repositories/)
- [Secret Management](https://argoproj.github.io/argo-cd/operator-manual/secret-management/)

Argo CD用のIAMユーザーを作成し、CodeCommitリポジトの参照権限を与える。

```sh
aws iam create-user --user-name argocd
policy_arn=$(aws iam list-policies --query 'Policies[?PolicyName==`AWSCodeCommitReadOnly`].{ARN:Arn}' --output text)
aws iam attach-user-policy --user-name argocd --policy-arn ${policy_arn}
```

#### （参考）HTTPS接続

HTTPS接続の場合は以下コマンドで認証情報を生成する。パスワードはこのときしか表示されないので注意。今回はSSH接続を使うのでこの手順はスキップ。

- [create-service-specific-credential](https://docs.aws.amazon.com/cli/latest/reference/iam/create-service-specific-credential.html)

```sh
aws iam create-service-specific-credential \
  --user-name argocd \
  --service-name codecommit.amazonaws.com
```

#### SSH接続

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

### CodeCommit

CodeCommitリポジトリを3つ作成する。

|リポジトリ名|用途|
|---|---|
|frontend|frontendアプリケーションのソースコードとDockerfile格納用リポジトリ|
|backend|backendアプリケーションのソースコードとDockerfile格納用リポジトリ|
|infra|Kubernetesマニフェストの格納用リポジトリ|

#### CloudFormation

```sh
aws cloudformation deploy \
  --stack-name gitops-codecommit-stack \
  --template-file cfn/codecommit.yaml
```

#### （参考）CLI

```sh
aws codecommit create-repository --repository-name frontend
aws codecommit create-repository --repository-name backend
aws codecommit create-repository --repository-name infra
```

### ソースをCodeCommitにpush

CodeCommitリポジトリのURLを変数に入れておく。

```sh
frontend_codecommit_http=$(aws codecommit get-repository --repository-name frontend --query 'repositoryMetadata.cloneUrlHttp' --output text); echo ${frontend_codecommit_http}
frontend_codecommit_ssh=$(aws codecommit get-repository --repository-name frontend --query 'repositoryMetadata.cloneUrlSsh' --output text); echo ${frontend_codecommit_ssh}
backend_codecommit_http=$(aws codecommit get-repository --repository-name backend --query 'repositoryMetadata.cloneUrlHttp' --output text); echo ${backend_codecommit_http}
backend_codecommit_ssh=$(aws codecommit get-repository --repository-name backend --query 'repositoryMetadata.cloneUrlSsh' --output text); echo ${backend_codecommit_ssh}
infra_codecommit_http=$(aws codecommit get-repository --repository-name infra --query 'repositoryMetadata.cloneUrlHttp' --output text); echo ${infra_codecommit_http}
infra_codecommit_ssh=$(aws codecommit get-repository --repository-name infra --query 'repositoryMetadata.cloneUrlSsh' --output text); echo ${infra_codecommit_ssh}
```

ローカルからのpushについては、CLI認証情報ヘルパーを使うことにして以下を設定する。

```sh
git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true
git config --global user.name "hogehoge"
git config --global user.email "hogehoge@example.com"
```

frontendアプリケーションのソースをCodeCommitにpushする。productionブランチも作成しておく。

```sh
cd frontend/
git init
git add .
git commit -m "first commit"
git remote add origin ${frontend_codecommit_http}
git push -u origin master
git checkout -b production
git push -u origin production
git checkout master
```

backendアプリケーションのソースをCodeCommitにpushする。

```sh
cd ../backend/
git init
git add .
git commit -m "first commit"
git remote add origin ${backend_codecommit_http}
git push -u origin master
git checkout -b production
git push -u origin production
git checkout master
```

infraのマニフェストをCodeCommitにpushする。一部のマニフェストにはAWSアカウントIDやSSHキーIDが含まれているので、自身の環境に合わせて一括置換する。

```sh
cd ../infra/
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ssh_key_id=$(aws iam list-ssh-public-keys --user-name argocd | jq -r '.SSHPublicKeys[].SSHPublicKeyId')
find . -type f -name "*.yaml" -print0 | xargs -0 sed -i "" -e "s/XXXX_AWS_ACCOUNT_ID_XXXX/${AWS_ACCOUNT_ID}/"
find . -type f -name "*.yaml" -print0 | xargs -0 sed -i "" -e "s/XXXX_SSH_KEY_ID_XXXX/${ssh_key_id}/"
git init
git add .
git commit -m "first commit"
git remote add origin ${infra_codecommit_http}
git push -u origin master
cd ../
```

### ECR

ECRリポジトリを2つ作成する。

|リポジトリ名|用途|
|---|---|
|frontend|frontendアプリケーションのDockerイメージ格納用リポジトリ|
|backend|backendアプリケーションのDockerイメージ格納用リポジトリ|

#### （参考）CloudFormation

```sh
aws cloudformation deploy \
  --stack-name gitops-ecr-stack \
  --template-file cfn/ecr.yaml
```

ECRリポジトリのURLを変数に入れておく。

```sh
frontend_ecr=$(aws ecr describe-repositories --repository-names frontend --query 'repositories[0].repositoryUri' --output text); echo ${frontend_ecr}
backend_ecr=$(aws ecr describe-repositories --repository-names backend --query 'repositories[0].repositoryUri' --output text); echo ${backend_ecr}
```

#### （参考）CLI

```sh
aws ecr create-repository --repository-name frontend
aws ecr create-repository --repository-name backend
```

### CodePipelineとCodeBuild

コンテナイメージをbuildしてイメージをECRにpushするパイプラインを作成する。

パイプラインは4つ作成する。

|パイプライン名|用途|
|---|---|
|frontend-master-pipeline|frontendリポジトリのmasterブランチへのコミットをトリガーに起動|
|backend-master-pipeline|backendリポジトリのmasterブランチへのコミットをトリガーに起動|
|frontend-production-pipeline|frontendリポジトリのmasterブランチへのコミットをトリガーに起動|
|backend-procution-pipeline|backendリポジトリのmasterブランチへのコミットをトリガーに起動|

CodeBuildプロジェクトは環境毎に共有し、2つ作成する。

|CodeBuildプロジェクト名|用途|
|---|---|
|frontend-build|frontendリポジトリのmasterブランチへのコミットをトリガーに起動|
|backend-build|backendリポジトリのmasterブランチへのコミットをトリガーに起動|

#### CloudFormation

以下を参考にテンプレートを作成。

- [例 1: AWS CloudFormation を使用して AWS CodeCommit パイプラインを作成する](https://docs.aws.amazon.com/ja_jp/codepipeline/latest/userguide/tutorials-cloudformation-codecommit.html)

CodePipeline用のS3バケットを作成する。

```sh
codepipeline_artifactstore_bucket="codepipeline-artifactstore-${AWS_ACCOUNT_ID}"
aws cloudformation deploy \
  --stack-name gitops-codepipeline-bucket-stack \
  --template-file cfn/codepipeline-bucket.yaml \
  --parameter-overrides CodePipelineArtifactStoreBucketName=${codepipeline_artifactstore_bucket}
```

CodeBuildプロジェクトを作成する。こちらアプリケーション毎に作成し、環境では共有する。
環境毎に分けてもよいが、今回はCodePipelineからCodeBuildに環境変数を渡すようにしている。

```sh
aws cloudformation deploy \
  --stack-name gitops-frontend-codebuild-stack \
  --template-file cfn/codebuild.yaml \
  --parameter-overrides CodeBuildProjectName=frontend-build CodePipelineArtifactStoreBucketName=${codepipeline_artifactstore_bucket} \
  --capabilities CAPABILITY_NAMED_IAM
```

```sh
aws cloudformation deploy \
  --stack-name gitops-backend-codebuild-stack \
  --template-file cfn/codebuild.yaml \
  --parameter-overrides CodeBuildProjectName=backend-build CodePipelineArtifactStoreBucketName=${codepipeline_artifactstore_bucket} \
  --capabilities CAPABILITY_NAMED_IAM
```

CodePipelineを作成する。こちらはアプリケーション毎かつ環境毎に作成する。

```sh
aws cloudformation deploy \
  --stack-name gitops-frontend-staging-pipeline-stack \
  --template-file cfn/codepipeline.yaml \
  --parameter-overrides CodePipelineArtifactStoreBucketName=${codepipeline_artifactstore_bucket} CodeCommitRepositoryName=frontend CodeCommitBranchName=master CodeBuildProjectName=frontend-build \
  --capabilities CAPABILITY_NAMED_IAM
```

```sh
aws cloudformation deploy \
  --stack-name gitops-backend-staging-pipeline-stack \
  --template-file cfn/codepipeline.yaml \
  --parameter-overrides CodePipelineArtifactStoreBucketName=${codepipeline_artifactstore_bucket} CodeCommitRepositoryName=backend CodeCommitBranchName=master CodeBuildProjectName=backend-build \
  --capabilities CAPABILITY_NAMED_IAM
```

```sh
aws cloudformation deploy \
  --stack-name gitops-frontend-production-pipeline-stack \
  --template-file cfn/codepipeline.yaml \
  --parameter-overrides CodePipelineArtifactStoreBucketName=${codepipeline_artifactstore_bucket} CodeCommitRepositoryName=frontend CodeCommitBranchName=production CodeBuildProjectName=frontend-build \
  --capabilities CAPABILITY_NAMED_IAM
```

```sh
aws cloudformation deploy \
  --stack-name gitops-backend-production-pipeline-stack \
  --template-file cfn/codepipeline.yaml \
  --parameter-overrides CodePipelineArtifactStoreBucketName=${codepipeline_artifactstore_bucket} CodeCommitRepositoryName=backend CodeCommitBranchName=production CodeBuildProjectName=backend-build \
  --capabilities CAPABILITY_NAMED_IAM
```

### イメージタグの更新

マネジメントコンソールからパイプラインの状態を確認し、パイプラインが成功していればinfraリポジトリにはプルリクエストが作成されているはずなのでマージする。

ビルドパイプラインを手動実行する場合は以下のコマンドで実行できるが、同じコミットから作成されたCodeBuildによって作成されたブランチがあると失敗するのでブランチを削除してから実施する。

```sh
aws codepipeline start-pipeline-execution --name frontend-master-pipeline
```

## stagingクラスターの作成

今回、アプリケーションのmasterブランチ＝stagingクラスター、productionブランチ＝productionクラスターという構成にする。

### クラスターの作成

stagingクラスターを作成する。

```sh
cluster_name="staging"
key_pair_name="hogehoge"
eksctl create cluster --name=${cluster_name} --nodes=3 --managed --ssh-access --ssh-public-key=${key_pair_name}
```

### IRSA

いくつかのPodはIAMロールが必要なため、IAM Roles for Service Accountを設定する。
IAM Roles for Service Account関連の操作にeksctlを使わない場合のやり方は以下にまとまっている。

- [Kubernetes サービスアカウントに対するきめ細やかな IAM ロール割り当ての紹介](https://aws.amazon.com/jp/blogs/news/introducing-fine-grained-iam-roles-service-accounts/)
- [サービスアカウントの IAM ロールとポリシーの作成](https://docs.aws.amazon.com/ja_jp/eks/latest/userguide/create-service-account-iam-policy-and-role.html)

#### OICDプロバイダー

OICDプロバイダーはK8sリソースを作っているわけではないので、eksctlで作成する。

```sh
eksctl utils associate-iam-oidc-provider \
  --cluster ${cluster_name} \
  --approve
```

#### DynamoDB

このサンプルアプリケーションはDynamoDBにアクセスするので、IRSAで`backend`のPodに適切な権限を設定する必要がある。

##### Cloudformation

テーブルとIAMロールを作成する。

```sh
oidc_provider=$(aws eks describe-cluster --name ${cluster_name} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
aws cloudformation deploy \
  --stack-name gitops-dynamodb-${cluster_name}-stack \
  --template-file cfn/dynamodb.yaml \
  --parameter-overrides ClusterName=${cluster_name} NamespaceName=backend ServiceAccountName=backend OidcProvider=${oidc_provider} \
  --capabilities CAPABILITY_NAMED_IAM
```

##### （参考）CLI

テーブルを作る。

```sh
aws dynamodb create-table --table-name "messages-${cluster_name}" \
  --attribute-definitions '[{"AttributeName":"uuid","AttributeType": "S"}]' \
  --key-schema '[{"AttributeName":"uuid","KeyType": "HASH"}]' \
  --provisioned-throughput '{"ReadCapacityUnits": 1,"WriteCapacityUnits": 1}'
```

IAMポリシーを作成する。

```sh
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
cat <<EOF > iam-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListAndDescribe",
      "Effect": "Allow",
      "Action": [
        "dynamodb:List*",
        "dynamodb:DescribeReservedCapacity*",
        "dynamodb:DescribeLimits",
        "dynamodb:DescribeTimeToLive"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SpecificTable",
      "Effect": "Allow",
      "Action": [
        "dynamodb:BatchGet*",
        "dynamodb:DescribeStream",
        "dynamodb:DescribeTable",
        "dynamodb:Get*",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:BatchWrite*",
        "dynamodb:CreateTable",
        "dynamodb:Delete*",
        "dynamodb:Update*",
        "dynamodb:PutItem"
      ],
      "Resource": "arn:aws:dynamodb:ap-northeast-1:${AWS_ACCOUNT_ID}:table/messages-${cluster_name}"
    }
  ]
}
EOF
aws iam create-policy \
  --policy-name backend-${cluster_name}-policy \
  --policy-document file://iam-policy.json
policy_arn=$(aws iam list-policies | jq -r '.Policies[] | select( .PolicyName == "backend-'"${cluster_name}"'-policy" ) | .Arn')
```

IAMロールを作成する。

```sh
role_name="backend-${cluster_name}"
NAMESPACE="backend"
SERVICE_ACCOUNT_NAME="backend"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
OIDC_PROVIDER=$(aws eks describe-cluster --name ${cluster_name} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
cat <<EOF > trust.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
        }
      }
    }
  ]
}
EOF
aws iam create-role \
  --role-name ${role_name} \
  --assume-role-policy-document file://trust.json
aws iam attach-role-policy \
  --role-name ${role_name} \
  --policy-arn ${policy_arn}
```

ServiceAccountのマニフェストではアノテーションでこのIAMロールを指定し、DeploymentのマニフェストではServiceAccountを指定する。

#### ALB Ingress Controller

ALB Ingress Controllerが使用するIAMロールを作成する。

##### Cloudformation

IAMロールを作成する。

```sh
oidc_provider=$(aws eks describe-cluster --name ${cluster_name} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
aws cloudformation deploy \
  --stack-name gitops-alb-ingress-controller-iam-${cluster_name}-stack \
  --template-file cfn/alb-ingress-controller-iam.yaml \
  --parameter-overrides ClusterName=${cluster_name} NamespaceName=kube-system ServiceAccountName=alb-ingress-controller OidcProvider=${oidc_provider} \
  --capabilities CAPABILITY_NAMED_IAM
```

##### （参考）CLI

IAMポリシーを作成する。共通のものを使用する。

```sh
wget https://kubernetes-sigs.github.io/aws-alb-ingress-controller/examples/iam-policy.json
aws iam create-policy \
  --policy-name ALBIngressControllerIAMPolicy \
  --policy-document file://iam-policy.json
policy_arn=$(aws iam list-policies --query 'Policies[?PolicyName==`ALBIngressControllerIAMPolicy`].{ARN:Arn}' --output text)
```

IAMロールを作成する。

```sh
role_name="alb-ingress-controller-${cluster_name}"
NAMESPACE="kube-system"
SERVICE_ACCOUNT_NAME="alb-ingress-controller"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
OIDC_PROVIDER=$(aws eks describe-cluster --name ${cluster_name} --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
cat <<EOF > trust.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}"
        }
      }
    }
  ]
}
EOF
aws iam create-role \
  --role-name ${role_name} \
  --assume-role-policy-document file://trust.json
aws iam attach-role-policy \
  --role-name ${role_name} \
  --policy-arn ${policy_arn}
```

### Argo CDのデプロイ

stagingクラスターにArgo CDをデプロイする。

- [Getting Started](https://argoproj.github.io/argo-cd/getting_started/)

```sh
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

今回はポートフォワードを前提としてLoad Balancerは作成しない。ポートフォワードする。

```sh
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

パスワード（＝Pod名）を取得してログインする。

```sh
argocd_server=localhost:8080
argocd_pwd=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o name | cut -d'/' -f 2)
export ARGOCD_OPTS='--port-forward-namespace argocd'
argocd login ${argocd_server} --username admin --password ${argocd_pwd} --insecure
```

### CodeCommitリポジトリを登録

CodeCommitリポジトリを登録する。

#### （参考）HTTPS接続の場合

```sh
argocd repo add ${infra_codecommit_http} --username <username> --password <password>
```

認証情報は`repo-XXXXXXXXXX`というSecretに格納される。

#### SSH接続の場合

プライベートリポジトリの場合は、`--insecure-skip-server-verification`フラグでSSH host keyのチェックを無効化するか、あらかじめSSH host keyを追加する必要がある。ここではSSH host keyを追加する。

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

確認する。

```sh
argocd repo list
```

秘密鍵は`repo-XXXXXXXXXX`というSecretに格納される。

以上でArgo CDのセットアップが完了。

### Argo CDアプリケーションの作成

今回CodeCommitリポジトリはそれぞれ以下のブランチ戦略をとる。

|リポジトリ名|ブランチ戦略|
|---|---|
|frontend|masterブランチをstaging環境、productionブランチをproduction環境にデプロイ|
|backend|masterブランチをstaging環境、productionブランチをproduction環境にデプロイ|
|infra|masterブランチのみを使用し、各環境の差分のファイルはディレクトリ毎に保持|

また、App of Apps構成とし、infraリポジトリのappディレクトリにArgo CDのApplicationリソースの定義を格納する。

- [Cluster Bootstrapping](https://argoproj.github.io/argo-cd/operator-manual/cluster-bootstrapping/)

Necoだと、以下がApp of Appsのディレクトリとなっており参考になる。

- [https://github.com/cybozu-go/neco-apps/tree/master/argocd-config/base](https://github.com/cybozu-go/neco-apps/tree/master/argocd-config/base)

App of AppsのApplicationを作成する。

```sh
ssh_key_id=$(aws iam list-ssh-public-keys --user-name argocd | jq -r '.SSHPublicKeys[].SSHPublicKeyId')
argocd app create apps \
  --repo ssh://${ssh_key_id}@git-codecommit.ap-northeast-1.amazonaws.com/v1/repos/infra \
  --path apps/overlays/${cluster_name} \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace argocd \
  --sync-policy automated
```

確認する。

```sh
argocd app list
```

### 確認

Podが正常に稼働していることを確認する。

```sh
$ kubectl get pod -A
NAMESPACE     NAME                                             READY   STATUS    RESTARTS   AGE
argocd        argocd-application-controller-6cb96c8f5b-krssw   1/1     Running   0          3h38m
argocd        argocd-dex-server-7cdf988d58-cj5jv               1/1     Running   0          3h38m
argocd        argocd-redis-8c568b5db-sfs5l                     1/1     Running   0          3h38m
argocd        argocd-repo-server-56d49b5948-4kmxc              1/1     Running   0          3h38m
argocd        argocd-server-86578b8cc6-js6hf                   1/1     Running   0          3h38m
backend       backend-6fd78bf486-nnkqk                         1/1     Running   0          116s
backend       backend-6fd78bf486-rkzhb                         1/1     Running   0          2m1s
frontend      frontend-6c99bc9969-7hl6c                        1/1     Running   0          14m
frontend      frontend-6c99bc9969-v8szj                        1/1     Running   0          14m
kube-system   alb-ingress-controller-c67974b7c-ggkt9           1/1     Running   0          101m
kube-system   aws-node-lk5dq                                   1/1     Running   0          3h43m
kube-system   aws-node-lrpql                                   1/1     Running   0          3h43m
kube-system   aws-node-rn2c5                                   1/1     Running   0          3h43m
kube-system   coredns-cdd78ff87-9vhvp                          1/1     Running   0          7h14m
kube-system   coredns-cdd78ff87-cktjp                          1/1     Running   0          7h14m
kube-system   kube-proxy-g7tlm                                 1/1     Running   0          3h43m
kube-system   kube-proxy-jhzxc                                 1/1     Running   0          3h43m
kube-system   kube-proxy-s6jnz                                 1/1     Running   0          3h43m
```

URLを確認する。

```sh
$ kubectl get ingress -n frontend
NAME       HOSTS   ADDRESS                                                                       PORTS   AGE
frontend   *       XXXXXXXX-frontend-frontend-XXXX-XXXXXXXXXX.ap-northeast-1.elb.amazonaws.com   80      4m37s
```

URLにアクセスしてアプリケーションが動作することを確認する。

## productionクラスターの作成

stagingクラスターと同じ作業をクラスター名を変えて実施する。

## 補足

### CodeBuildからプルリクを作成する

以下が参考になる。

- [create-pull-request](https://docs.aws.amazon.com/cli/latest/reference/codecommit/create-pull-request.html)
- [ビルド環境の環境変数](https://docs.aws.amazon.com/ja_jp/codebuild/latest/userguide/build-env-ref-env-vars.html)
- [AWS CLI 認証情報ヘルパーを使用する Linux, macOS, or Unix での AWS CodeCommit リポジトリへの HTTPS 接続のセットアップステップ](https://docs.aws.amazon.com/ja_jp/codecommit/latest/userguide/setting-up-https-unixes.html)

詳しくは`buildspec.yaml`を参照。

### Kustomise

Kustomize流のディレクトリ構成については以下の資料を参照。

- [Introduction to kustomize](https://speakerdeck.com/spesnova/introduction-to-kustomize)

Argo CDはKustomizeかどうかは自動判別してくれる。pathの指定で`kustomize build`を実行するディレクトリを指定する。

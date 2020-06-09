# サンプルアプリ

DynamoDBにメッセージを登録・参照するアプリ。

## 参考ドキュメント

- [FlaskでREST APIを作ってみる](https://medium.com/nyle-engineering-blog/flask%E3%81%A7rest-api%E3%82%92%E4%BD%9C%E3%81%A3%E3%81%A6%E3%81%BF%E3%82%8B-fad8ae1fde5c)
- [RestAPI using Flask and AWS DynamoDB and deploying the image to Docker Hub](https://medium.com/@janhaviC/restapi-using-flask-and-aws-dynamodb-and-deploying-the-image-to-docker-hub-eff1305c15a)

## メモ

curlでのPOSTの仕方。

```shell
curl -X POST -H "Content-Type: application/json" \
  -d '{"message":"Hello Flask"}' \
  localhost:5000/messages
```

curlでのDELETEの仕方。

```shell
curl -X DELETE localhost:5000/messages/2
```

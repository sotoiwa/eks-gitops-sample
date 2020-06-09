import os
import uuid

import boto3
from flask import Flask, request, jsonify


region_name = os.getenv('AWS_DEFAULT_REGION', 'ap-northeast-1')
table_name = os.getenv('DYNAMODB_TABLE_NAME', 'messages')

db = boto3.resource('dynamodb', region_name=region_name)
table = db.Table(table_name)

app = Flask(__name__)
app.config['JSON_AS_ASCII'] = False


@app.route('/messages', methods=['GET'])
def get_all_messages():
    db_response = table.scan()
    message_item = db_response['Items']
    return jsonify(message_item)


@app.route('/messages/<message_uuid>', methods=['GET'])
def get_message(message_uuid):
    db_response = table.get_item(
        Key={
            'uuid': message_uuid
        }
    )
    print(db_response)
    message_item = db_response['Item']
    return jsonify(message_item)


@app.route('/messages', methods=['POST'])
def create_message():
    message_uuid = str(uuid.uuid4())
    posted = request.get_json()
    posted['uuid'] = message_uuid
    print(posted)
    db_response = table.put_item(
        Item=posted
    )
    print(db_response)
    json = {
        'message': '{} created.'.format(message_uuid)
    }
    return jsonify(json)


@app.route('/messages/<message_uuid>', methods=['PUT'])
def update_message(message_uuid):
    put = request.get_json()
    put['uuid'] = message_uuid
    print(put)
    db_response = table.put_item(
        Item=put
    )
    print(db_response)
    json = {
        'message': '{} updated.'.format(message_uuid)
    }
    return jsonify(json)


@app.route('/messages/<message_uuid>', methods=['DELETE'])
def delete_message(message_uuid):
    db_response = table.delete_item(
        Key={
            'uuid': message_uuid
        }
    )
    print(db_response)
    json = {
        'message': '{} deleted'.format(message_uuid)
    }
    return jsonify(json)


@app.route('/healthz', methods=['GET'])
def health_check():
    return 'OK'


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)

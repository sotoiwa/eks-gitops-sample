import os

from flask import Flask, render_template, redirect, url_for
from flask_wtf import FlaskForm
from wtforms import StringField, SubmitField
from wtforms.validators import DataRequired, Email
import requests


# 環境変数からバックエンドサービスのURLを取得
backend_url = os.getenv('BACKEND_URL', 'http://localhost:5050/messages')

app = Flask(__name__)
app.config['SECRET_KEY'] = 'ataataaetbqtbab'


class MessageForm(FlaskForm):
    message = StringField(validators=[DataRequired()])
    submit = SubmitField()


@app.route('/', methods=['GET'])
def home_page():

    r = requests.get(backend_url)
    r.raise_for_status()
    items = r.json()

    form = MessageForm()

    return render_template('home.html', items=items, form=form)


@app.route('/', methods=['POST'])
def post_message():

    form = MessageForm()

    if form.validate_on_submit():
        json = {'message': form.message.data}
        r = requests.post(backend_url, json=json)
        r.raise_for_status()
        return redirect(url_for('home_page'))

    return render_template('home.html', form=form)


@app.route('/healthz', methods=['GET'])
def health_check():
    return 'OK'


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)

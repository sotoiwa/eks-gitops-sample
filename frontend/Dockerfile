FROM python:3.13.0a3-slim

RUN apt-get update && apt-get -y upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

RUN useradd -u 1001 default

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY templates/ ./templates/
COPY app.py ./

RUN find / -xdev -perm /6000 -type f -exec chmod a-s {} \; || true

USER default

ENV PYTHONUNBUFFERED 1
ENTRYPOINT [ "python", "./app.py" ]

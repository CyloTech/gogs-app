FROM ubuntu:18.04

ENV HOME=/home/git \
    DEBIAN_FRONTEND=noninteractive \
    GOGS_VERSION=0.11.53 \
    ADMIN_USER=gogsadmin \
    ADMIN_PASS=admin \
    ADMIN_EMAIL=admin@test.com \
    HTTP_PORT=80 \
    SSH_PORT=10022 \
    DOMAIN=localhost \
    ROOT_URL=http://localhost:80/

RUN apt update
RUN apt install -y wget \
                   curl \
                   nano \
                   git \
                   supervisor \
                   libcap2-bin \
                   pwgen

RUN adduser --system --disabled-password --home ${HOME} --shell /sbin/nologin --group --uid 1000 git

RUN cd /home/git && \
    wget https://cdn.gogs.io/${GOGS_VERSION}/gogs_${GOGS_VERSION}_linux_amd64.tar.gz && \
    tar -xvf gogs_${GOGS_VERSION}_linux_amd64.tar.gz && \
    rm -fr /home/git/gogs_*

ADD /scripts /scripts
RUN chmod -R +x /scripts

EXPOSE 80

RUN apt autoremove -y && apt clean
RUN rm -rf /var/lib/apt/lists/*

ENTRYPOINT [ "/scripts/Entrypoint.sh" ]
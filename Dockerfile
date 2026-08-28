# syntax=docker/dockerfile:1.7

ARG REDMINE_IMAGE=redmine:7.0.0@sha256:966156b9feff91511fb022b3fb5c1059c303e1c26f40baa670257c5fde0de2c7
FROM ${REDMINE_IMAGE} AS cosmosys_base

ARG COSMOSYS_REVISION=a678d44ae6bb71df9d4ac3e8274fcfd90fdbd005
ARG RSPREADSHEET_REVISION=3cf3031fc122306d09af7e503b66338c1b8ceb09

COPY config/database.yml config/database.yml

RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
      build-essential git graphviz libxml2-dev librsvg2-bin libreoffice-writer pkg-config \
    && gem install andand libxml-ruby rubyzip --no-document \
    && mkdir -p -m 0700 /root/.ssh \
    && ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --filter=blob:none https://github.com/cosmoBots/rspreadsheet.git /opt/rspreadsheet \
    && git -C /opt/rspreadsheet checkout "${RSPREADSHEET_REVISION}" \
    && test "$(git -C /opt/rspreadsheet rev-parse HEAD)" = "${RSPREADSHEET_REVISION}" \
    && rm -rf /opt/rspreadsheet/.git

RUN --mount=type=ssh git clone --filter=blob:none git@github.com:cosmoBots/cosmoSys.git plugins/cosmosys \
    && git -C plugins/cosmosys checkout "${COSMOSYS_REVISION}" \
    && test "$(git -C plugins/cosmosys rev-parse HEAD)" = "${COSMOSYS_REVISION}" \
    && rm -rf plugins/cosmosys/.git

ENV RSPREADSHEET_PATH=/opt/rspreadsheet

RUN bundle install \
    && apt-get purge -y --auto-remove build-essential libxml2-dev pkg-config \
    && rm -rf /root/.bundle/cache /usr/local/bundle/cache

FROM cosmosys_base AS cosmosys_requirements

ARG COSMOSYS_REQ_REVISION=da016a4210cdedc2d671fa7390f50e3928a2a42b

RUN --mount=type=ssh git clone --filter=blob:none git@github.com:cosmoBots/cosmoSys_Req.git plugins/cosmosys_req \
    && git -C plugins/cosmosys_req checkout "${COSMOSYS_REQ_REVISION}" \
    && test "$(git -C plugins/cosmosys_req rev-parse HEAD)" = "${COSMOSYS_REQ_REVISION}" \
    && rm -rf plugins/cosmosys_req/.git \
    && bundle install \
    && rm -rf /root/.bundle/cache /usr/local/bundle/cache

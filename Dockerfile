# syntax=docker/dockerfile:1.7

ARG REDMINE_IMAGE
FROM ${REDMINE_IMAGE} AS cosmosys_base

COPY config/database.yml config/database.yml

RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
      build-essential git graphviz libxml2-dev librsvg2-bin libreoffice-writer pkg-config \
    && gem install andand libxml-ruby rubyzip --no-document \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p -m 0700 /root/.ssh \
    && for attempt in 1 2 3 4 5; do \
         ssh-keyscan -t ed25519 github.com > /root/.ssh/known_hosts && break; \
         test "$attempt" -eq 5 && exit 1; \
         sleep 2; \
       done \
    && test -s /root/.ssh/known_hosts

ARG RSPREADSHEET_REVISION

RUN : "${RSPREADSHEET_REVISION:?Pass RSPREADSHEET_REVISION as a build argument}" \
    && git clone --filter=blob:none https://github.com/cosmoBots/rspreadsheet.git /opt/rspreadsheet \
    && git -C /opt/rspreadsheet checkout "${RSPREADSHEET_REVISION}" \
    && test "$(git -C /opt/rspreadsheet rev-parse HEAD)" = "${RSPREADSHEET_REVISION}" \
    && rm -rf /opt/rspreadsheet/.git

ARG COSMOSYS_REVISION

RUN --mount=type=ssh : "${COSMOSYS_REVISION:?Pass COSMOSYS_REVISION as a build argument}" \
    && git clone --filter=blob:none git@github.com:cosmoBots/cosmoSys.git plugins/cosmosys \
    && git -C plugins/cosmosys checkout "${COSMOSYS_REVISION}" \
    && test "$(git -C plugins/cosmosys rev-parse HEAD)" = "${COSMOSYS_REVISION}" \
    && rm -rf plugins/cosmosys/.git

ENV RSPREADSHEET_PATH=/opt/rspreadsheet

RUN bundle install \
    && apt-get purge -y --auto-remove build-essential libxml2-dev pkg-config \
    && rm -rf /root/.bundle/cache /usr/local/bundle/cache

COPY bootstrap /opt/cosmosys-deploy/bootstrap

LABEL eu.cosmobots.cosmosys.revision="${COSMOSYS_REVISION}" \
      eu.cosmobots.rspreadsheet.revision="${RSPREADSHEET_REVISION}"

FROM cosmosys_base AS cosmosys_requirements

ARG COSMOSYS_REQ_REVISION

RUN --mount=type=ssh : "${COSMOSYS_REQ_REVISION:?Pass COSMOSYS_REQ_REVISION as a build argument}" \
    && git clone --filter=blob:none git@github.com:cosmoBots/cosmoSys_Req.git plugins/cosmosys_req \
    && git -C plugins/cosmosys_req checkout "${COSMOSYS_REQ_REVISION}" \
    && test "$(git -C plugins/cosmosys_req rev-parse HEAD)" = "${COSMOSYS_REQ_REVISION}" \
    && rm -rf plugins/cosmosys_req/.git \
    && bundle install \
    && rm -rf /root/.bundle/cache /usr/local/bundle/cache

LABEL eu.cosmobots.cosmosys-req.revision="${COSMOSYS_REQ_REVISION}"

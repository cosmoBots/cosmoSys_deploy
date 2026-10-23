# syntax=docker/dockerfile:1.7

ARG REDMINE_IMAGE
# The variant the final stage builds on: base or requirements.
ARG COSMOSYS_VARIANT=base

FROM ${REDMINE_IMAGE} AS cosmosys_base

COPY config/database.yml config/database.yml

RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
      build-essential git graphviz libxml2-dev librsvg2-bin libreoffice-writer pkg-config \
    && gem install andand libxml-ruby rubyzip --no-document \
    && rm -rf /var/lib/apt/lists/*

ARG RSPREADSHEET_REVISION

RUN : "${RSPREADSHEET_REVISION:?Pass RSPREADSHEET_REVISION as a build argument}" \
    && git clone --filter=blob:none https://github.com/cosmoBots/rspreadsheet.git /opt/rspreadsheet \
    && git -C /opt/rspreadsheet checkout "${RSPREADSHEET_REVISION}" \
    && test "$(git -C /opt/rspreadsheet rev-parse HEAD)" = "${RSPREADSHEET_REVISION}" \
    && rm -rf /opt/rspreadsheet/.git

ARG COSMOSYS_REVISION

RUN : "${COSMOSYS_REVISION:?Pass COSMOSYS_REVISION as a build argument}" \
    && git clone --filter=blob:none https://github.com/cosmoBots/cosmoSys.git plugins/cosmosys \
    && git -C plugins/cosmosys checkout "${COSMOSYS_REVISION}" \
    && test "$(git -C plugins/cosmosys rev-parse HEAD)" = "${COSMOSYS_REVISION}" \
    && rm -rf plugins/cosmosys/.git

ENV RSPREADSHEET_PATH=/opt/rspreadsheet

# Optional plugins, dormant under /opt/cosmosys/plugins-available until an
# instance activates them; see plugins.conf.
COPY plugins.conf scripts/catalog-lib.sh docker/install-optional-plugins.sh /opt/cosmosys-deploy/
COPY kroki_compat /opt/cosmosys/plugins-available/redmine_kroki_compat
COPY docker/local-plugins/cosmosys_exchange_api /opt/cosmosys/plugins-available/cosmosys_exchange_api
COPY docker/additional_environment.rb config/additional_environment.rb

RUN sh /opt/cosmosys-deploy/install-optional-plugins.sh \
    && bundle install \
    && apt-get purge -y --auto-remove build-essential libxml2-dev pkg-config \
    && rm -rf /root/.bundle/cache /usr/local/bundle/cache

COPY bootstrap /opt/cosmosys-deploy/bootstrap

LABEL eu.cosmobots.cosmosys.revision="${COSMOSYS_REVISION}" \
      eu.cosmobots.rspreadsheet.revision="${RSPREADSHEET_REVISION}"

FROM cosmosys_base AS cosmosys_requirements

ARG COSMOSYS_REQ_REVISION

RUN : "${COSMOSYS_REQ_REVISION:?Pass COSMOSYS_REQ_REVISION as a build argument}" \
    && git clone --filter=blob:none https://github.com/cosmoBots/cosmoSys_Req.git plugins/cosmosys_req \
    && git -C plugins/cosmosys_req checkout "${COSMOSYS_REQ_REVISION}" \
    && test "$(git -C plugins/cosmosys_req rev-parse HEAD)" = "${COSMOSYS_REQ_REVISION}" \
    && rm -rf plugins/cosmosys_req/.git \
    && bundle install \
    && rm -rf /root/.bundle/cache /usr/local/bundle/cache

LABEL eu.cosmobots.cosmosys-req.revision="${COSMOSYS_REQ_REVISION}"

# The image an instance runs: its variant plus the tools of the options it
# uses. Everything above is shared by every instance of the same variant.
FROM cosmosys_${COSMOSYS_VARIANT} AS cosmosys

ARG COSMOSYS_TOOLS=

COPY docker/install-tools.sh /opt/cosmosys-deploy/
COPY docker/python /opt/cosmosys-deploy/python
RUN sh /opt/cosmosys-deploy/install-tools.sh "${COSMOSYS_TOOLS}"

# Where the plugins that use Python tools find them: the LaTeX plugin renders
# formulas with this interpreter, and the notebook viewer runs this jupyter and
# takes the interpreter next to it for the formulas of a notebook.
ENV LATEX_PYTHON_BIN=/opt/cosmosys-python/bin/python \
    JUPYTER_BIN=/opt/cosmosys-python/bin/jupyter \
    NOTEBOOK_CACHE_DIR=/usr/src/redmine/tmp/notebook_cache

COPY docker/cosmosys-entrypoint.sh /opt/cosmosys-deploy/

LABEL eu.cosmobots.tools="${COSMOSYS_TOOLS}"

ENTRYPOINT ["sh", "/opt/cosmosys-deploy/cosmosys-entrypoint.sh", "/docker-entrypoint.sh"]
CMD ["rails", "server", "-b", "0.0.0.0"]

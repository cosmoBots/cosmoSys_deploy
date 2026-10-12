# syntax=docker/dockerfile:1.7

ARG REDMINE_IMAGE
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

RUN bundle install \
    && apt-get purge -y --auto-remove build-essential libxml2-dev pkg-config \
    && rm -rf /root/.bundle/cache /usr/local/bundle/cache

COPY bootstrap /opt/cosmosys-deploy/bootstrap

LABEL eu.cosmobots.cosmosys.revision="${COSMOSYS_REVISION}" \
      eu.cosmobots.rspreadsheet.revision="${RSPREADSHEET_REVISION}"

FROM cosmosys_base AS cosmosys_latex_source

ARG COSMOSYS_LATEX_REVISION

RUN : "${COSMOSYS_LATEX_REVISION:?Pass COSMOSYS_LATEX_REVISION as a build argument}" \
    && git clone --filter=blob:none https://github.com/cosmoBots/redmine_cbots_latex.git /tmp/redmine_cbots_latex \
    && git -C /tmp/redmine_cbots_latex checkout "${COSMOSYS_LATEX_REVISION}" \
    && test "$(git -C /tmp/redmine_cbots_latex rev-parse HEAD)" = "${COSMOSYS_LATEX_REVISION}" \
    && cp -a /tmp/redmine_cbots_latex plugins/redmine_cbots_latex \
    && rm -rf /tmp/redmine_cbots_latex/.git

FROM cosmosys_base AS cosmosys_notebook_preview_source

ARG REDMINE_NOTEBOOK_PREVIEW_REVISION

RUN : "${REDMINE_NOTEBOOK_PREVIEW_REVISION:?Pass REDMINE_NOTEBOOK_PREVIEW_REVISION as a build argument}" \
    && git clone --filter=blob:none https://github.com/cosmoBots/redmine_notebook_preview.git /tmp/redmine_notebook_preview \
    && git -C /tmp/redmine_notebook_preview checkout "${REDMINE_NOTEBOOK_PREVIEW_REVISION}" \
    && test "$(git -C /tmp/redmine_notebook_preview rev-parse HEAD)" = "${REDMINE_NOTEBOOK_PREVIEW_REVISION}" \
    && cp -a /tmp/redmine_notebook_preview plugins/redmine_notebook_preview \
    && rm -rf /tmp/redmine_notebook_preview/.git

FROM cosmosys_base AS cosmosys_kroki

ARG REDMINE_KROKI_REVISION
ARG COSMOSYS_KROKI_REVISION

RUN : "${REDMINE_KROKI_REVISION:?Pass REDMINE_KROKI_REVISION as a build argument}" \
    && : "${COSMOSYS_KROKI_REVISION:?Pass COSMOSYS_KROKI_REVISION as a build argument}" \
    && git clone --filter=blob:none https://github.com/cosmoBots/redmine-kroki.git /tmp/redmine-kroki \
    && git -C /tmp/redmine-kroki checkout "${REDMINE_KROKI_REVISION}" \
    && test "$(git -C /tmp/redmine-kroki rev-parse HEAD)" = "${REDMINE_KROKI_REVISION}" \
    && cp -a /tmp/redmine-kroki/src plugins/redmine_kroki \
    && test -f plugins/redmine_kroki/init.rb \
    && rm -rf /tmp/redmine-kroki \
    && git clone --filter=blob:none https://github.com/cosmoBots/cosmosys_kroki.git plugins/cosmosys_kroki \
    && git -C plugins/cosmosys_kroki checkout "${COSMOSYS_KROKI_REVISION}" \
    && test "$(git -C plugins/cosmosys_kroki rev-parse HEAD)" = "${COSMOSYS_KROKI_REVISION}" \
    && test -f plugins/cosmosys_kroki/init.rb \
    && rm -rf plugins/cosmosys_kroki/.git \
    && bundle install \
    && rm -rf /root/.bundle/cache /usr/local/bundle/cache

COPY kroki_compat plugins/redmine_kroki_compat

LABEL eu.cosmobots.redmine-kroki.revision="${REDMINE_KROKI_REVISION}" \
      eu.cosmobots.cosmosys-kroki.revision="${COSMOSYS_KROKI_REVISION}"

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

FROM cosmosys_requirements AS cosmosys_requirements_kroki

ARG REDMINE_KROKI_REVISION
ARG COSMOSYS_KROKI_REVISION

RUN : "${REDMINE_KROKI_REVISION:?Pass REDMINE_KROKI_REVISION as a build argument}" \
    && : "${COSMOSYS_KROKI_REVISION:?Pass COSMOSYS_KROKI_REVISION as a build argument}" \
    && git clone --filter=blob:none https://github.com/cosmoBots/redmine-kroki.git /tmp/redmine-kroki \
    && git -C /tmp/redmine-kroki checkout "${REDMINE_KROKI_REVISION}" \
    && test "$(git -C /tmp/redmine-kroki rev-parse HEAD)" = "${REDMINE_KROKI_REVISION}" \
    && cp -a /tmp/redmine-kroki/src plugins/redmine_kroki \
    && test -f plugins/redmine_kroki/init.rb \
    && rm -rf /tmp/redmine-kroki \
    && git clone --filter=blob:none https://github.com/cosmoBots/cosmosys_kroki.git plugins/cosmosys_kroki \
    && git -C plugins/cosmosys_kroki checkout "${COSMOSYS_KROKI_REVISION}" \
    && test "$(git -C plugins/cosmosys_kroki rev-parse HEAD)" = "${COSMOSYS_KROKI_REVISION}" \
    && test -f plugins/cosmosys_kroki/init.rb \
    && rm -rf plugins/cosmosys_kroki/.git \
    && bundle install \
    && rm -rf /root/.bundle/cache /usr/local/bundle/cache

COPY kroki_compat plugins/redmine_kroki_compat

LABEL eu.cosmobots.redmine-kroki.revision="${REDMINE_KROKI_REVISION}" \
      eu.cosmobots.cosmosys-kroki.revision="${COSMOSYS_KROKI_REVISION}"

FROM cosmosys_requirements_kroki AS cosmosys_requirements_kroki_latex

ARG COSMOSYS_LATEX_REVISION

COPY --from=cosmosys_latex_source /usr/src/redmine/plugins/redmine_cbots_latex plugins/redmine_cbots_latex

RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends python3-matplotlib \
    && bundle install \
    && rm -rf /var/lib/apt/lists/* /root/.bundle/cache /usr/local/bundle/cache

LABEL eu.cosmobots.redmine-cbots-latex.revision="${COSMOSYS_LATEX_REVISION}"

FROM cosmosys_requirements_kroki_latex AS cosmosys_requirements_kroki_latex_notebook_preview

ARG REDMINE_NOTEBOOK_PREVIEW_REVISION

COPY --from=cosmosys_notebook_preview_source /usr/src/redmine/plugins/redmine_notebook_preview plugins/redmine_notebook_preview

RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends python3-venv \
    && python3 -m venv /opt/nbconvert-env \
    && /opt/nbconvert-env/bin/pip install --no-cache-dir nbconvert nbformat jupyter_core matplotlib \
    && install -d -o redmine -g redmine -m 0750 /usr/src/redmine/notebook_cache \
    && rm -rf /var/lib/apt/lists/*

ENV JUPYTER_BIN=/opt/nbconvert-env/bin/jupyter \
    NOTEBOOK_CACHE_DIR=/usr/src/redmine/notebook_cache

RUN bundle install \
    && rm -rf /root/.bundle/cache /usr/local/bundle/cache

LABEL eu.cosmobots.redmine-notebook-preview.revision="${REDMINE_NOTEBOOK_PREVIEW_REVISION}"

FROM cosmosys_requirements_kroki_latex_notebook_preview AS cosmosys_requirements_kroki_latex_notebook_preview_poris

ARG COSMOSYS_PORIS_REVISION

RUN : "${COSMOSYS_PORIS_REVISION:?Pass COSMOSYS_PORIS_REVISION as a build argument}" \
    && git clone --filter=blob:none https://github.com/cosmoBots/cosmosys_poris.git /tmp/cosmosys_poris \
    && git -C /tmp/cosmosys_poris checkout "${COSMOSYS_PORIS_REVISION}" \
    && test "$(git -C /tmp/cosmosys_poris rev-parse HEAD)" = "${COSMOSYS_PORIS_REVISION}" \
    && cp -a /tmp/cosmosys_poris plugins/cosmosys_poris \
    && rm -rf /tmp/cosmosys_poris/.git \
    && bundle install \
    && rm -rf /root/.bundle/cache /usr/local/bundle/cache

LABEL eu.cosmobots.cosmosys-poris.revision="${COSMOSYS_PORIS_REVISION}"

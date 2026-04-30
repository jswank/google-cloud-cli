FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:alpine

RUN apk add --no-cache \ 
  direnv jq yq coreutils grep gawk perl

USER cloudsdk

COPY --chown=cloudsdk:cloudsdk profile /home/cloudsdk/.profile

RUN mkdir -p $HOME/.local/bin

ENV PATH=$PATH:/home/cloudsdk/.local/bin

# Set TENV_ROOT explicitly so Cloud Build (running as root) uses the shared install
ENV TENV_ROOT=/home/cloudsdk/.tenv

# install tenv
RUN curl -sSL https://jswank.github.io/install/tenv-install.sh | bash

# install latest tofu
RUN ${HOME}/.local/bin/tenv tofu install latest && \
    ${HOME}/.local/bin/tenv tofu use latest

# install tflint
RUN curl -sSL https://jswank.github.io/install/tflint-install.sh | bash

CMD ["/bin/bash", "-l"]

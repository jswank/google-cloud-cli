FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:alpine

# Add labels for better image management
LABEL maintainer="jswank@scalene.net" \
      description="Custom Google Cloud SDK image with utilities"

RUN apk add --no-cache \
    coreutils \
    direnv \
    gawk \
    git \
    grep \
    jq \
    yq


USER cloudsdk

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

# install task
RUN curl -sSL https://jswank.github.io/install/task-install.sh | bash

COPY --chown=cloudsdk:cloudsdk profile /home/cloudsdk/.profile
ADD --chown=cloudsdk:cloudsdk inputrc /home/cloudsdk/.inputrc

CMD ["/bin/bash", "-l"]

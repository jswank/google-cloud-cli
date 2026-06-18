FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:alpine

# Add labels for better image management
LABEL maintainer="jswank@scalene.net" \
      description="Custom Google Cloud SDK image with utilities"

RUN apk add --no-cache \
    coreutils \
    direnv \
    gawk \
    git \
    github-cli \
    grep \
    jq \
    openssl \
    tmux \
    yq

RUN gcloud components update --quiet \
  && gcloud components install --quiet log-streaming beta

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
COPY --chown=cloudsdk:cloudsdk bash_aliases /home/cloudsdk/.bash_aliases
COPY --chown=cloudsdk:cloudsdk post-status.sh /home/cloudsdk/.local/bin/post-status.sh
COPY --chown=cloudsdk:cloudsdk post-step-status.sh /home/cloudsdk/.local/bin/post-step-status.sh
COPY --chown=cloudsdk:cloudsdk tofu-pr-summary.sh /home/cloudsdk/.local/bin/tofu-pr-summary.sh
COPY --chown=cloudsdk:cloudsdk tofu-runner.sh /home/cloudsdk/.local/bin/tofu-runner

RUN chmod +x /home/cloudsdk/.local/bin/post-status.sh \
             /home/cloudsdk/.local/bin/post-step-status.sh \
             /home/cloudsdk/.local/bin/tofu-pr-summary.sh \
             /home/cloudsdk/.local/bin/tofu-runner

CMD ["/bin/bash", "-l"]

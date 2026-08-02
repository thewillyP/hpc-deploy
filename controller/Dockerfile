FROM jenkins/jenkins:lts-jdk21@sha256:f4f65e6cd1405cd889b7f5ac33f9d5cdc2a099de6b87fe8a3933b9c5d53d1d02

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg unzip openssh-client jq \
 && rm -rf /var/lib/apt/lists/*

# awscli, signature-verified
RUN gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys A6310ACC4672475C && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    curl -o awscliv2.sig https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip.sig && \
    gpg --verify awscliv2.sig awscliv2.zip && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip awscliv2.sig aws

USER jenkins

ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
# NOT under /var/jenkins_home: that path is bind-mounted from the cluster at
# runtime and would shadow anything copied here.
ENV CASC_JENKINS_CONFIG=/usr/local/jenkins/casc.yaml

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli -f /usr/share/jenkins/ref/plugins.txt

COPY casc.yaml /usr/local/jenkins/casc.yaml
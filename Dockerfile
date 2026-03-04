FROM --platform=linux/amd64 eclipse-temurin:17-jdk-alpine

ARG JMETER_VERSION=5.6.3

# apt-get 대신 apk 사용, bash 추가 설치
RUN apk update && apk add --no-cache curl unzip bash \
    && curl -L https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz \
       -o /tmp/jmeter.tgz \
    && tar -xzf /tmp/jmeter.tgz -C /opt \
    && rm /tmp/jmeter.tgz

ENV JMETER_HOME=/opt/apache-jmeter-${JMETER_VERSION}
ENV PATH=$JMETER_HOME/bin:$PATH

WORKDIR /jmeter

# 기본 상태는 대기, 실험 시 docker compose run 으로 실행
CMD ["bash", "-c", "while true; do sleep 3600; done"]

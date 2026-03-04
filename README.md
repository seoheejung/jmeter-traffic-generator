# JMeter – External Abnormal Traffic Generator

> 외부 비정상 트래픽을 발생시키기 위한 JMeter 전용 구성이다.   
> 애플리케이션 성능 측정이 아닌, 운영 장애 상황 재현 및 방어 기법 검증을 목적으로 한다.

## 1. 목적

### 비정상 트래픽 유입 시 확인 대상
- 시스템 병목 발생 지점
- Rate Limit / Circuit Breaker의 실제 보호 효과
- DB Connection Pool의 임계 구간에 도달하는 수준의 동시 요청을 단계적으로 유입
  
---

## 2. 논리적 위치
- JMeter는 애플리케이션 구성 요소가 아니다.
- 독립된 컨테이너로 실행되며, 애플리케이션 코드와 분리된 외부 트래픽 생성기로 동작한다.
- 네트워크 상에서는 Docker bridge network를 통해 backend에 요청을 전달한다.
- Backend Service와는 네트워크만 공유하고, 제어·권한·코드는 분리된다.
```
jmeter container
   ↓
docker bridge network
   ↓
backend container
```

---

## 3. 동작 원리 (3 Pillars)

### What
- READ
- WRITE
```
POST /api/load/db-read?repeatCount=1
POST /api/load/db-write?repeatCount=1
```
> READ / WRITE는 서로 다른 실험 시나리오로 분리한다.   
> 하나의 실험 시나리오에서는 단일 **Target API(Endpoint)**만 측정한다.   
> 단, 해당 시나리오 내에는 부하를 유발하는 Attack-TG와 가용성을 체크하는 Normal-TG가 공존한다.

### How many
- 100 Threads = 동시에 실행되는 100명의 가상 사용자
- 동시 요청 수는 응답 시간과 Loop 설정에 따라 변한다.

### How long
- 요청 간격 및 유지 시간
- 부하의 강도는 Threads 수로 제어한다.
- 단, DB 내부 자원 고갈(Resource Exhaustion) 실험에서는 요청 1건당 자원 점유 시간을 증가시키기 위해 repeatCount를 보조적으로 사용할 수 있다.
- repeatCount는 동시성(Thread 수)을 증가시키는 수단이 아니라, 단일 요청이 점유하는 DB 작업 시간을 증가시키기 위한 파라미터이다.

---

## 4. 주요 구성 요소

### Thread Group
- Thread: 가상의 사용자(Virtual User) 1명
- Thread Group: 동일한 시나리오를 실행하는 가상 사용자 집합
- 동시 요청 수(in-flight request)는 응답 시간, Timer(delay), Loop 설정에 따라 변한다.

### HTTP Request
- 동일한 API / Method / 파라미터 사용
- X-Forwarded-For 헤더로 IP 구분하여 분리
  - 단일 IP 공격
  - 정상 사용자 트래픽

### Listener
- Non-GUI 모드로 실행
- 결과는 CSV(.jtl) 파일로 저장 후 HTML 리포트로 분석

---

## 5. 공격 트래픽 vs 정상 트래픽

| 구분       | Attack-TG   | Normal-TG                     |
| ---------- | -------- | ----------------------------- |
| 목적       | 부하 유발   | 가용성 확인                  |
| Thread 수  | 많음  | 적음                          |
| 요청 간격 | 부하 제어용 Delay 설정 | 일정 (예: 1000ms)  |
| IP         | 동일   | 다름     |
| Header     | X-Forwarded-For: 10.10.10.10  | X-Forwarded-For: 20.20.20.20 |


- 두 그룹은 같은 API, 같은 파라미터를 사용한다.
- 차이는 **동시성(Thread), 요청 간격(Delay), IP**만 존재한다.
- Delay 0ms는 허용되지만, Concurrency Stress Test에서는 과도한 RPS 폭증을 방지하기 위해 100~300ms 범위의 delay를 사용한다.

#### Attack-TG 구조
> Thread 수는 DB Connection Pool(maximum-pool-size)을 초과하는 수준으로 설정하여 Pool 대기 및 병목이 발생하는 구간을 탐색한다.

```
Attack-TG
- threads: 300 -> 500 -> 750 -> 1000
- ramp-up: 20~30
- delay:
    READ  = 100~200ms
    WRITE = 150~300ms
- loop: .jmx 기본값 또는 실행 스크립트에서 전달된 값(-JATTACK_LOOPS)을 따른다. (또는 단계별 2~3분 유지)

Normal-TG
- threads: 25
- delay: 1000ms
- loop: .jmx 기본값 또는 실행 스크립트에서 전달된 값(-JNORMAL_LOOPS)을 따른다.

```

※ Resource Exhaustion Test에서는 다음이 추가로 허용된다.
- repeatCount 증가
- Delay 0ms
- Pool Size 축소

---

## 6. 디렉터리 구조
```
services/service-a/
├── backend/          # 실험 대상 (Spring Boot)
└── jmeter/           # 외부 비정상 트래픽 발생자
    ├── Dockerfile
    └── scenarios/    # JMeter .jmx 시나리오
```

## 7. 실험 제약 조건

### Concurrency Stress Test (기본 실험)

1. 목적
   - 동시 요청 증가에 따른 임계 구간 탐색
   - Rate Limit / CircuitBreaker 보호 효과 검증
2. 제약
   - Thread 수만 단계적으로 증가
   - ON/OFF 비교는 동일 Thread 단계에서만 수행
   - 각 Thread Group은 다음 두 조건 중 먼저 만족되는 시점에 종료
     - Scheduler duration 도달
     - LoopController loops 완료

### Resource Exhaustion Test (고갈 유도 실험)
1. 목적
   - DB Connection Pool 고갈 상황 강제 재현
   - 내부 대기열 증가 및 timeout 발생 관측
   - 방어 기제의 극한 상황 보호 능력 확인
2. 허용 사항
   - repeatCount > 1 허용
   - POOL_MODE에서는 HIKARI 관련 override 값을 JVM_ARGS로 전달
   - Delay 0ms 허용
   - Ramp-up 단축 허용
3. 제약
   - Concurrency Stress Test 결과와 직접 비교하지 않는다.
   - 고갈 실험은 "임계점 재현" 목적이며 성능 비교 목적이 아니다.

---

## 8. Docker 기반 실행
### JMeter Dockerfile
```
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

CMD ["bash", "-c", "while true; do sleep 3600; done"]
```
- JMeter 컨테이너는 테스트 실행을 위해 대기 상태로 유지되며 docker exec를 통해 실제 JMeter CLI 명령을 실행한다.

---

## 9. 실행 시나리오
1. run_jmeter_test.bat 실행
2. Backend는 실험 시작 상태만 기록
3. JMeter 컨테이너 실행
4. JMeter가 외부 공격자 역할로 backend에 트래픽 유입
5. backend는 Rate Limit / Circuit Breaker로 대응

---

## 10. 로그
### CLI에서 필드 제한
- JMeter는 저장 필드를 -J 옵션으로 줄일 수 있다.

### 권장 최소 필드
1. timeStamp
2. elapsed
3. label
4. responseCode
5. success
6. threadName
7. latency
8. connectTime

### 개발 단계 시뮬레이션
1. GUI 사용 ❌
2. Response 저장 ❌
3. CSV 최소 필드 저장 ⭕
4. HTML 리포트 생성

```
docker run --rm ^
  -v "%cd%:/jmeter" ^
  spring-jmeter ^
  jmeter -g /jmeter/results/write_result_45.jtl ^
          -o /jmeter/results/report_write_45
```

- response body는 저장하지 않는다.   
- 부하 실험의 목적은 응답 시간 및 실패율 관측이며,      
- Payload 분석은 범위에 포함하지 않는다.
- throughput_rps는 JTL의 전체 샘플(Attack+Normal 합산) 기준이며,   
(timeStamp max − timeStamp min) 구간의 평균 RPS로 계산한다.
---

## 11. JMeter .jmx 파일
### attack_read_vs_normal.jmx

> DB READ 기반 부하 상황

1. 관측 요소
   - 동시 요청 증가에 따른 응답 지연
   - Thread Pool / DB Connection Pool 병목
   - CircuitBreaker OPEN 시점

2. 실험 구성
   - Attack / Normal 트래픽 동시 실행
   - API / 파라미터 완전 동일

3. 차이 요소
   - Thread 수
   - 요청 간격
   - IP

4. 비교 포인트
   - Rate Limit 적용 전·후 정상 트래픽 보호 여부
   - CircuitBreaker 동작 여부


### attack_write_vs_normal.jmx

> DB WRITE 기반 부하 상황

1. 관측 요소
   - 락 경합
   - Commit 비용 증가
   - 급격한 병목 발생 양상

2. 실험 구성
   - Attack / Normal 트래픽 동시 실행
   - API / 파라미터 완전 동일

3. 차이 요소
   - Thread 수
   - 요청 간격
   - IP

4. 비교 포인트
   - Rate Limit 적용 전·후 쓰기 병목 완화 효과
   - CircuitBreaker 동작 여부

### 두 시나리오의 차이
- Throughput(RPS)는 Thread 수, 응답 시간, Loop 설정의 영향을 받는다.
- 기본 Stress Test에서는 repeatCount를 고정값으로 유지한다.
  - 현재 실행 스크립트 기본값은 5이며, 비교 실험 시 동일 값을 유지한다.


| 항목          | READ            | WRITE         |
| ----------- | --------------- | ------------- |
| API         | `/db-read`      | `/db-write`   |
| 병목          | Connection Pool | Lock / Commit |
| 장애 양상       | 점진적 지연     | 급격한 병목     |


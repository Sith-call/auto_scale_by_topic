# 메시지 분산 시스템 (Message Distribution System)

Go와 RabbitMQ를 사용하여 구현한 Kubernetes 환경에서 동작하는 오토 스케일링 메시지 분산 시스템입니다.

## 🏗️ 시스템 아키텍처

```
[Publisher] --> [RabbitMQ Exchange] --> [Queue_consumer-0_a, Queue_consumer-0_b, ...] --> [Consumer-0]
                                    --> [Queue_consumer-1_m, Queue_consumer-1_n, ...] --> [Consumer-1]
                                    --> [Queue_consumer-2_x, Queue_consumer-2_z, ...] --> [Consumer-2]
                                    
[AutoScaler] <-- [RabbitMQ Metrics] <-- 큐 메시지 수 모니터링
     |
     v
[Kubernetes API] --> Consumer Deployment 스케일링
```

## 📋 주요 기능

### 1. **Publisher**
- 메시지 ID (알파벳/숫자 8자리)와 우선순위(1-10) 생성
- ID 첫 글자를 Routing Key로 사용하여 메시지 분산
- 부하 테스트를 위한 초당 메시지 수 조절 가능

### 2. **Consumer**
- ID 첫 글자 기준으로 파티셔닝된 메시지 처리
- 우선순위 큐를 사용하여 높은 우선순위 메시지 먼저 처리
- 1초마다 가장 높은 우선순위 메시지 하나씩 처리
- 처리 시각, 메시지 ID, 우선순위 출력

### 3. **AutoScaler**
- RabbitMQ 큐 메트릭 모니터링
- Consumer 수에 따른 동적 파티션 재할당
- Kubernetes Deployment 자동 스케일링

## 🚀 빠른 시작

### 전제 조건
- Kubernetes 클러스터 (minikube, kind, 또는 실제 클러스터)
- kubectl 설치
- Docker 설치
- Go 1.21+ (로컬 테스트용)

### 1. 의존성 설치
```bash
make deps
```

### 2. Docker 이미지 빌드
```bash
make build-all
```

### 3. Kubernetes에 배포
```bash
# RabbitMQ, Consumer, AutoScaler 배포
make deploy

# 배포 상태 확인
make status
```

### 4. Publisher 실행 (부하 테스트)
```bash
# Job으로 실행 (2분간 20 msg/sec)
make run-publisher

# 또는 지속적인 부하 테스트를 위해 Deployment 활성화
kubectl scale deployment message-publisher-deployment --replicas=1
```

### 5. 스케일링 테스트
```bash
make test-scaling
```

## 📊 모니터링 및 로그

### 로그 확인
```bash
# Consumer 로그
make logs-consumer

# AutoScaler 로그  
make logs-autoscaler

# Publisher 로그
make logs-publisher
```

### 시스템 상태 모니터링
```bash
# 전체 상태 확인
make status

# Pod 상세 조회
kubectl get pods -o wide

# RabbitMQ 관리 UI 접근
kubectl port-forward svc/rabbitmq 15672:15672
# http://localhost:15672 (guest/guest)
```

## 🎯 스케일링 동작 원리

### 파티셔닝 로직
- 총 36개 문자 (a-z: 26개 + 0-9: 10개)를 Consumer 수로 균등분할
- Consumer-0: a-i (9개), Consumer-1: j-r (9개), Consumer-2: s-z,0-9 (18개)

### 스케일링 트리거
- AutoScaler가 30초마다 큐 메트릭 조회
- 큐당 평균 10개 이상 메시지 시 스케일 아웃
- 최소 1개, 최대 10개 Consumer 유지

### 동적 재파티셔닝
- Consumer 수 변경 시 자동으로 파티션 재계산
- 기존 Consumer는 새로운 파티션으로 자동 전환
- 메시지 손실 없이 부하 재분산

## 🛠️ 설정 옵션

### 환경변수

#### Publisher
- `RABBITMQ_URL`: RabbitMQ 연결 URL (기본값: amqp://guest:guest@rabbitmq:5672/)
- `MESSAGES_PER_SECOND`: 초당 메시지 수 (기본값: 10)
- `DURATION_SECONDS`: 실행 시간 (기본값: 30)

#### Consumer  
- `RABBITMQ_URL`: RabbitMQ 연결 URL
- `CONSUMER_ID`: Consumer 식별자 (기본값: consumer-0)
- `TOTAL_CONSUMERS`: 전체 Consumer 수 (기본값: 1)

#### AutoScaler
- `RABBITMQ_URL`: RabbitMQ 연결 URL
- `NAMESPACE`: Kubernetes 네임스페이스 (기본값: default)
- `CONSUMER_DEPLOYMENT_NAME`: Consumer Deployment 이름 (기본값: message-consumer)
- `MIN_REPLICAS`: 최소 Consumer 수 (기본값: 1)
- `MAX_REPLICAS`: 최대 Consumer 수 (기본값: 10)

## 🧪 로컬 테스트

RabbitMQ를 로컬에서 실행하고 테스트:

```bash
# RabbitMQ 실행 (Docker)
docker run -d --hostname my-rabbit --name rabbitmq -p 5672:5672 -p 15672:15672 rabbitmq:3-management

# 로컬 테스트 실행
make test-local
```

## 🔧 개발 및 디버깅

### 코드 구조
```
├── cmd/
│   ├── publisher/      # Publisher 애플리케이션
│   ├── consumer/       # Consumer 애플리케이션  
│   └── autoscaler/     # AutoScaler 애플리케이션
├── pkg/
│   └── message/        # 공통 메시지 타입
├── k8s/               # Kubernetes 매니페스트
├── Dockerfile.*       # Docker 빌드 파일들
└── Makefile          # 빌드/배포 스크립트
```

### 트러블슈팅

1. **Consumer가 메시지를 받지 못하는 경우**
   - RabbitMQ 연결 상태 확인
   - Exchange와 Queue 바인딩 상태 확인
   - RBAC 권한 확인

2. **AutoScaler가 스케일링하지 않는 경우**
   - Kubernetes API 권한 확인
   - RabbitMQ 메트릭 조회 가능 여부 확인
   - Deployment 존재 여부 확인

3. **메시지 중복 처리가 발생하는 경우**
   - Consumer ID와 파티셔닝 로직 확인
   - 총 Consumer 수 환경변수 확인

## 📈 성능 최적화

- **메시지 배치 처리**: 필요시 Consumer에서 배치 단위로 처리 가능
- **연결 풀링**: RabbitMQ 연결 재사용으로 성능 향상
- **메모리 최적화**: 우선순위 큐 크기 제한 설정
- **리소스 튜닝**: Kubernetes 리소스 requests/limits 조정

## 🧹 정리

모든 리소스 삭제:
```bash
make clean
```

---

## 📝 라이센스

이 프로젝트는 학습 목적으로 제작되었습니다. 
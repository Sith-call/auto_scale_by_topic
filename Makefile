# Makefile for Message Distribution System

# 변수 정의
DOCKER_REGISTRY ?= localhost:5000
VERSION ?= latest

# Docker 이미지 이름들
PUBLISHER_IMAGE = $(DOCKER_REGISTRY)/message-publisher:$(VERSION)
CONSUMER_IMAGE = $(DOCKER_REGISTRY)/message-consumer:$(VERSION)
AUTOSCALER_IMAGE = $(DOCKER_REGISTRY)/message-autoscaler:$(VERSION)

.PHONY: all build-all build-publisher build-consumer build-autoscaler push-all deploy clean test

# 기본 타겟
all: build-all

# Go 모듈 의존성 설치
deps:
	go mod download
	go mod tidy

# 모든 이미지 빌드
build-all: build-publisher build-consumer build-autoscaler

# Publisher 이미지 빌드
build-publisher:
	@echo "🔨 Publisher 이미지 빌드 중..."
	docker build -f Dockerfile.publisher -t $(PUBLISHER_IMAGE) .
	@echo "✅ Publisher 이미지 빌드 완료"

# Consumer 이미지 빌드
build-consumer:
	@echo "🔨 Consumer 이미지 빌드 중..."
	docker build -f Dockerfile.consumer -t $(CONSUMER_IMAGE) .
	@echo "✅ Consumer 이미지 빌드 완료"

# AutoScaler 이미지 빌드
build-autoscaler:
	@echo "🔨 AutoScaler 이미지 빌드 중..."
	docker build -f Dockerfile.autoscaler -t $(AUTOSCALER_IMAGE) .
	@echo "✅ AutoScaler 이미지 빌드 완료"

# 모든 이미지 푸시
push-all: build-all
	@echo "📤 이미지들을 레지스트리에 푸시 중..."
	docker push $(PUBLISHER_IMAGE)
	docker push $(CONSUMER_IMAGE)
	docker push $(AUTOSCALER_IMAGE)
	@echo "✅ 모든 이미지 푸시 완료"

# Kubernetes 배포
deploy: deploy-rabbitmq deploy-consumer deploy-autoscaler
	@echo "🚀 모든 서비스 배포 완료"

deploy-rabbitmq:
	@echo "🐰 RabbitMQ 배포 중..."
	kubectl apply -f k8s/rabbitmq.yaml
	kubectl wait --for=condition=available --timeout=300s deployment/rabbitmq

deploy-consumer:
	@echo "🔄 Consumer 배포 중..."
	kubectl apply -f k8s/consumer.yaml
	kubectl wait --for=condition=ready --timeout=300s statefulset/message-consumer

deploy-autoscaler:
	@echo "📈 AutoScaler 배포 중..."
	kubectl apply -f k8s/autoscaler.yaml
	kubectl wait --for=condition=available --timeout=300s deployment/message-autoscaler

# Publisher Job 실행
run-publisher:
	@echo "📤 Publisher Job 실행 중..."
	kubectl apply -f k8s/publisher.yaml

# 실제 스케일링 테스트 실행
test-scaling:
	@echo "📊 실제 스케일링 테스트 실행..."
	bash scripts/test-scaling.sh

# 정리
clean:
	@echo "🧹 리소스 정리 중..."
	kubectl delete -f k8s/ --ignore-not-found=true
	docker rmi $(PUBLISHER_IMAGE) $(CONSUMER_IMAGE) $(AUTOSCALER_IMAGE) --force

# 로그 확인
logs-consumer:
	kubectl logs -l app=message-consumer -f

logs-autoscaler:
	kubectl logs -l app=message-autoscaler -f

logs-publisher:
	kubectl logs -l app=message-publisher -f

# 상태 확인
status:
	@echo "📊 시스템 상태:"
	kubectl get pods -l app=rabbitmq,app=message-consumer,app=message-autoscaler
	kubectl get svc rabbitmq

# 로컬 테스트 (Docker Compose 없이)
test-local:
	@echo "🧪 로컬 테스트 실행..."
	RABBITMQ_URL="amqp://guest:guest@localhost:5672/" go run cmd/publisher/main.go &
	sleep 2
	RABBITMQ_URL="amqp://guest:guest@localhost:5672/" CONSUMER_ID="consumer-0" TOTAL_CONSUMERS="1" go run cmd/consumer/main.go

# 헬프
help:
	@echo "사용 가능한 명령어들:"
	@echo "  deps           - Go 모듈 의존성 설치"
	@echo "  build-all      - 모든 Docker 이미지 빌드"
	@echo "  build-publisher - Publisher 이미지 빌드"
	@echo "  build-consumer  - Consumer 이미지 빌드"
	@echo "  build-autoscaler - AutoScaler 이미지 빌드"
	@echo "  push-all       - 모든 이미지를 레지스트리에 푸시"
	@echo "  deploy         - 모든 서비스를 Kubernetes에 배포"
	@echo "  run-publisher  - Publisher Job 실행"
	@echo "  test-scaling   - 스케일링 테스트"
	@echo "  clean          - 모든 리소스 정리"
	@echo "  logs-*         - 각 서비스의 로그 확인"
	@echo "  status         - 시스템 상태 확인"
	@echo "  test-local     - 로컬 테스트" 
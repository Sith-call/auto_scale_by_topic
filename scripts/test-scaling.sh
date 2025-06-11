#!/bin/bash

echo "🧪 실제 스케일링 테스트 시나리오 시작"
echo "========================================"

# 색상 정의
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 테스트 단계별 실행
test_step() {
    echo -e "${YELLOW}$1${NC}"
    echo "----------------------------------------"
}

check_pods() {
    echo -e "${GREEN}현재 Pod 상태:${NC}"
    kubectl get pods -l app=message-consumer -o wide
    echo ""
}

check_queues() {
    echo -e "${GREEN}RabbitMQ 큐 상태 확인:${NC}"
    kubectl exec -it $(kubectl get pods -l app=rabbitmq -o jsonpath='{.items[0].metadata.name}') -- rabbitmqctl list_queues name messages consumers
    echo ""
}

# 1단계: 초기 상태 확인
test_step "1단계: 초기 상태 확인 (Consumer 1개)"
check_pods
check_queues

# 2단계: 낮은 부하 메시지 발송 (스케일링 안되어야 함)
test_step "2단계: 낮은 부하 테스트 (5 msg/sec, 30초)"
kubectl delete job message-publisher --ignore-not-found=true
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: message-publisher-low
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: publisher
        image: message-publisher:latest
        imagePullPolicy: IfNotPresent
        env:
        - name: RABBITMQ_URL
          value: "amqp://guest:guest@rabbitmq:5672/"
        - name: MESSAGES_PER_SECOND
          value: "5"
        - name: DURATION_SECONDS
          value: "30"
EOF

echo "⏳ 낮은 부하 테스트 완료까지 대기..."
kubectl wait --for=condition=complete --timeout=60s job/message-publisher-low

check_pods
check_queues

# 3단계: 높은 부하 메시지 발송 (스케일 아웃 유도)
test_step "3단계: 높은 부하 테스트 (50 msg/sec, 60초) - 스케일 아웃 유도"
kubectl delete job message-publisher-low --ignore-not-found=true
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: message-publisher-high
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: publisher
        image: message-publisher:latest
        imagePullPolicy: IfNotPresent
        env:
        - name: RABBITMQ_URL
          value: "amqp://guest:guest@rabbitmq:5672/"
        - name: MESSAGES_PER_SECOND
          value: "50"
        - name: DURATION_SECONDS
          value: "60"
EOF

echo "⏳ 높은 부하 생성 중... (60초)"
sleep 30

echo -e "${GREEN}30초 후 중간 상태:${NC}"
check_pods
check_queues

echo "⏳ 추가 30초 대기 후 최종 상태..."
kubectl wait --for=condition=complete --timeout=60s job/message-publisher-high

# 4단계: 스케일링 결과 확인
test_step "4단계: 스케일링 결과 확인 (AutoScaler 동작 확인)"
check_pods
check_queues

echo -e "${GREEN}AutoScaler 로그:${NC}"
kubectl logs -l app=message-autoscaler --tail=10

# 5단계: 부하 중단 후 스케일 다운 테스트
test_step "5단계: 부하 중단 후 스케일 다운 테스트 (90초 대기)"
kubectl delete job message-publisher-high --ignore-not-found=true

echo "⏳ 스케일 다운까지 90초 대기..."
for i in {1..9}; do
    echo "  ${i}0초 경과..."
    sleep 10
    if [ $((i % 3)) -eq 0 ]; then
        echo -e "${GREEN}  중간 확인 (${i}0초):${NC}"
        kubectl get pods -l app=message-consumer --no-headers | wc -l | xargs echo "    Consumer 수:"
    fi
done

# 6단계: 최종 결과
test_step "6단계: 최종 테스트 결과"
check_pods
check_queues

echo -e "${GREEN}AutoScaler 최종 로그:${NC}"
kubectl logs -l app=message-autoscaler --tail=20

# 7단계: 메시지 처리 로그 확인
test_step "7단계: Consumer 메시지 처리 로그 확인"
echo -e "${GREEN}각 Consumer의 최근 처리 로그:${NC}"
for pod in $(kubectl get pods -l app=message-consumer -o jsonpath='{.items[*].metadata.name}'); do
    echo "=== $pod ==="
    kubectl logs $pod --tail=5
    echo ""
done

echo "========================================"
echo -e "${GREEN}✅ 스케일링 테스트 완료!${NC}"
echo "========================================"

# 정리
kubectl delete job message-publisher-low message-publisher-high --ignore-not-found=true 
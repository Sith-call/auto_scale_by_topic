#!/bin/bash

# 오토 스케일링 시나리오 테스트 스크립트
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULT_DIR="test-results/${TIMESTAMP}"
mkdir -p "${RESULT_DIR}"

echo "🚀 오토 스케일링 시나리오 테스트 시작"
echo "결과 저장 디렉토리: ${RESULT_DIR}"
echo "=================================="

# 로그 함수
log_status() {
    local scenario=$1
    local step=$2
    local file="${RESULT_DIR}/${scenario}_step${step}.log"
    
    echo "⏰ $(date)" > "$file"
    echo "시나리오: $scenario - 단계 $step" >> "$file"
    echo "=================================" >> "$file"
    
    echo "📊 StatefulSet 상태:" >> "$file"
    kubectl get statefulset message-consumer -o custom-columns="NAME:.metadata.name,DESIRED:.spec.replicas,CURRENT:.status.replicas,READY:.status.readyReplicas" >> "$file" 2>&1
    echo "" >> "$file"
    
    echo "🎯 Consumer Pods:" >> "$file"
    kubectl get pods -l app=message-consumer >> "$file" 2>&1
    echo "" >> "$file"
    
    echo "📬 RabbitMQ 큐 상태:" >> "$file"
    kubectl exec deployment/rabbitmq -- rabbitmqctl list_queues name messages consumers --timeout 10 >> "$file" 2>&1
    echo "" >> "$file"
    
    echo "📈 총 메시지 수:" >> "$file"
    TOTAL_MESSAGES=$(kubectl exec deployment/rabbitmq -- rabbitmqctl list_queues messages --timeout 10 2>/dev/null | grep -v "Timeout\|Listing\|messages" | awk '{sum += $1} END {print sum+0}')
    echo "총 ${TOTAL_MESSAGES}개 메시지" >> "$file"
    echo "" >> "$file"
    
    echo "🤖 AutoScaler 로그:" >> "$file"
    kubectl logs deployment/message-autoscaler --tail=5 >> "$file" 2>&1
    echo "" >> "$file"
    
    echo "📤 Publisher 상태:" >> "$file"
    kubectl get pods -l app=message-publisher >> "$file" 2>&1
    echo "" >> "$file"
}

# 초기 상태 기록
echo "📋 초기 상태 기록 중..."
log_status "initial" "0"

# 시나리오 1: 낮은 부하 테스트 (초당 5개 메시지 - 스케일링 안됨)
echo ""
echo "🔵 시나리오 1: 낮은 부하 테스트 (초당 5개 메시지)"
echo "예상 결과: 스케일링 없음, Consumer 1개 유지"

# Publisher 설정을 낮은 부하로 변경
kubectl patch job message-publisher --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/env/1/value", "value": "5"}]' 2>/dev/null || echo "기존 Job 없음"

# 새로운 낮은 부하 Publisher 시작
cat > /tmp/low-load-publisher.yaml << EOF
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
        image: localhost:5000/message-publisher:latest
        imagePullPolicy: Never
        env:
        - name: RABBITMQ_URL
          value: "amqp://guest:guest@rabbitmq:5672/"
        - name: MESSAGES_PER_SECOND
          value: "5"
        - name: DURATION_SECONDS
          value: "60"
EOF

kubectl apply -f /tmp/low-load-publisher.yaml
echo "낮은 부하 Publisher 시작 (초당 5개 메시지, 60초간)"
sleep 20

log_status "scenario1_low_load" "1"
sleep 30
log_status "scenario1_low_load" "2"
sleep 30
log_status "scenario1_low_load" "3"

kubectl delete job message-publisher-low 2>/dev/null

# 시나리오 2: 높은 부하 테스트 (초당 100개 메시지 - 스케일 아웃)
echo ""
echo "🔴 시나리오 2: 높은 부하 테스트 (초당 100개 메시지)"
echo "예상 결과: 자동 스케일 아웃 발생"

cat > /tmp/high-load-publisher.yaml << EOF
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
        image: localhost:5000/message-publisher:latest
        imagePullPolicy: Never
        env:
        - name: RABBITMQ_URL
          value: "amqp://guest:guest@rabbitmq:5672/"
        - name: MESSAGES_PER_SECOND
          value: "100"
        - name: DURATION_SECONDS
          value: "90"
EOF

kubectl apply -f /tmp/high-load-publisher.yaml
echo "높은 부하 Publisher 시작 (초당 100개 메시지, 90초간)"
sleep 20

log_status "scenario2_high_load" "1"
sleep 30
log_status "scenario2_high_load" "2"
sleep 40
log_status "scenario2_high_load" "3"

kubectl delete job message-publisher-high 2>/dev/null

# 시나리오 3: 부하 감소 후 스케일 다운 테스트
echo ""
echo "🟡 시나리오 3: 부하 감소 후 스케일 다운 테스트"
echo "예상 결과: 큐가 비워지면서 자동 스케일 다운"

echo "Publisher 중지하고 스케일 다운 대기 중..."
sleep 60
log_status "scenario3_scale_down" "1"
sleep 60
log_status "scenario3_scale_down" "2"
sleep 60
log_status "scenario3_scale_down" "3"

# 시나리오 4: 지속적인 중간 부하 테스트
echo ""
echo "🟠 시나리오 4: 지속적인 중간 부하 테스트 (초당 30개 메시지)"
echo "예상 결과: 적절한 스케일링 유지"

cat > /tmp/medium-load-publisher.yaml << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: message-publisher-medium
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: publisher
        image: localhost:5000/message-publisher:latest
        imagePullPolicy: Never
        env:
        - name: RABBITMQ_URL
          value: "amqp://guest:guest@rabbitmq:5672/"
        - name: MESSAGES_PER_SECOND
          value: "30"
        - name: DURATION_SECONDS
          value: "120"
EOF

kubectl apply -f /tmp/medium-load-publisher.yaml
echo "중간 부하 Publisher 시작 (초당 30개 메시지, 120초간)"
sleep 30

log_status "scenario4_medium_load" "1"
sleep 60
log_status "scenario4_medium_load" "2"
sleep 60
log_status "scenario4_medium_load" "3"

kubectl delete job message-publisher-medium 2>/dev/null

# 최종 상태 기록
echo ""
echo "📋 최종 상태 기록 중..."
log_status "final" "0"

# 결과 요약 생성
echo ""
echo "📊 테스트 결과 요약 생성 중..."
cat > "${RESULT_DIR}/test_summary.md" << EOF
# 오토 스케일링 테스트 결과 요약

**테스트 시간**: $(date)
**테스트 ID**: ${TIMESTAMP}

## 테스트 시나리오

### 시나리오 1: 낮은 부하 테스트
- **설정**: 초당 5개 메시지, 60초간
- **예상**: 스케일링 없음, Consumer 1개 유지
- **결과**: [scenario1_low_load_step*.log 참조]

### 시나리오 2: 높은 부하 테스트  
- **설정**: 초당 100개 메시지, 90초간
- **예상**: 자동 스케일 아웃 발생
- **결과**: [scenario2_high_load_step*.log 참조]

### 시나리오 3: 스케일 다운 테스트
- **설정**: Publisher 중지 후 대기
- **예상**: 큐가 비워지면서 자동 스케일 다운
- **결과**: [scenario3_scale_down_step*.log 참조]

### 시나리오 4: 지속적인 중간 부하 테스트
- **설정**: 초당 30개 메시지, 120초간  
- **예상**: 적절한 스케일링 유지
- **결과**: [scenario4_medium_load_step*.log 참조]

## 파일 구조
- \`initial_step0.log\`: 테스트 시작 전 초기 상태
- \`scenario*_step*.log\`: 각 시나리오의 단계별 상태
- \`final_step0.log\`: 테스트 완료 후 최종 상태
- \`test_summary.md\`: 이 요약 파일

## 주요 검증 항목
- ✅ 메시지 파티셔닝 (ID 첫 글자별 큐 분산)
- ✅ 우선순위 기반 메시지 처리
- ✅ 실시간 큐 모니터링 (30초 간격)
- ✅ 자동 스케일 아웃 (임계값 초과시)
- ✅ 자동 스케일 다운 (큐 비워질 때)
- ✅ StatefulSet 동적 관리

## Consumer 설정
- **처리 속도**: 3초당 1개 메시지
- **스케일링 임계값**: 큐당 10개 메시지
- **최소 replica**: 1개
- **최대 replica**: 10개

EOF

echo "✅ 모든 시나리오 테스트 완료!"
echo "📁 결과 파일 위치: ${RESULT_DIR}/"
echo "📋 요약 보기: cat ${RESULT_DIR}/test_summary.md"

# 정리
rm -f /tmp/*load-publisher.yaml

echo ""
echo "🧹 임시 파일 정리 완료"
echo "==================================" 
#!/bin/bash

# 상세 오토 스케일링 분석 스크립트

echo "🔍 실시간 오토 스케일링 상세 분석"
echo "=========================================="
echo "⏰ 분석 시작: $(date)"
echo ""

# 현재 상태 스냅샷
take_snapshot() {
    local label=$1
    local timestamp=$(date +"%H:%M:%S")
    
    echo "📸 [$timestamp] $label"
    echo "----------------------------------------"
    
    # StatefulSet 상태
    echo "🎯 Consumer StatefulSet:"
    kubectl get statefulset message-consumer -o custom-columns="DESIRED:.spec.replicas,CURRENT:.status.replicas,READY:.status.readyReplicas" --no-headers | while read desired current ready; do
        echo "   원하는 수: ${desired}개, 현재: ${current}개, 준비됨: ${ready}개"
    done
    
    # Consumer Pod 목록과 상태
    echo ""
    echo "🤖 활성 Consumer 목록:"
    kubectl get pods -l app=message-consumer --no-headers | while read name ready status restarts age; do
        if [[ "$status" == "Running" ]]; then
            echo "   ✅ $name ($ready)"
        else
            echo "   ⏳ $name ($ready, $status)"
        fi
    done
    
    # 큐별 메시지 분포
    echo ""
    echo "📬 큐별 메시지 분포 (상위 10개):"
    kubectl exec deployment/rabbitmq -- rabbitmqctl list_queues name messages --timeout 5 2>/dev/null | \
    grep -v "Timeout\|Listing\|name" | \
    awk '$2 > 0 {print $0}' | \
    sort -k2 -nr | \
    head -10 | \
    while read queue_name messages; do
        # 큐 이름에서 파티션 문자 추출
        partition=$(echo $queue_name | grep -o '_[a-z0-9]$' | tr -d '_')
        echo "   📦 파티션 '$partition': ${messages}개 메시지"
    done
    
    # 총 메시지 수
    total_messages=$(kubectl exec deployment/rabbitmq -- rabbitmqctl list_queues messages --timeout 5 2>/dev/null | \
    grep -v "Timeout\|Listing\|messages" | awk '{sum += $1} END {print sum+0}')
    echo "   📊 총 메시지: ${total_messages}개"
    
    # AutoScaler 최신 결정
    echo ""
    echo "🧠 AutoScaler 최신 결정:"
    latest_log=$(kubectl logs deployment/message-autoscaler --tail=3 | grep "📊\|📈" | tail -1)
    if [[ -n "$latest_log" ]]; then
        echo "   $latest_log"
    else
        echo "   AutoScaler 로그 없음"
    fi
    
    echo ""
    echo "=========================================="
    echo ""
}

# Consumer별 처리 현황 분석
analyze_consumer_activity() {
    echo "🔄 Consumer별 메시지 처리 현황"
    echo "----------------------------------------"
    
    # 각 Consumer Pod의 최근 처리 로그
    kubectl get pods -l app=message-consumer --no-headers | while read name ready status restarts age; do
        if [[ "$status" == "Running" ]]; then
            echo "🤖 $name:"
            
            # 최근 처리된 메시지들
            recent_messages=$(kubectl logs $name --tail=10 2>/dev/null | grep "🔄.*처리됨" | tail -3)
            if [[ -n "$recent_messages" ]]; then
                echo "$recent_messages" | while read line; do
                    # 메시지 ID와 우선순위 추출
                    id=$(echo "$line" | grep -o 'ID: [a-zA-Z0-9]*' | cut -d' ' -f2)
                    priority=$(echo "$line" | grep -o '우선순위: [0-9]*' | cut -d' ' -f2)
                    time=$(echo "$line" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]')
                    echo "     [$time] 메시지 $id (우선순위: $priority)"
                done
            else
                echo "     🕐 최근 처리 기록 없음"
            fi
            
            # 담당 파티션 확인 (최근 수신 로그에서)
            partitions=$(kubectl logs $name --tail=50 2>/dev/null | grep "📥.*수신됨" | tail -10 | grep -o 'queue_[^_]*_[a-z0-9]' | grep -o '_[a-z0-9]$' | tr -d '_' | sort | uniq | tr '\n' ' ')
            if [[ -n "$partitions" ]]; then
                echo "     📦 담당 파티션: $partitions"
            fi
            echo ""
        fi
    done
}

# 메시지 파티셔닝 분석
analyze_partitioning() {
    echo "🗂️  메시지 파티셔닝 분석"
    echo "----------------------------------------"
    
    echo "📊 파티션별 메시지 분포:"
    kubectl exec deployment/rabbitmq -- rabbitmqctl list_queues name messages --timeout 5 2>/dev/null | \
    grep "queue_message-consumer-" | \
    awk '{
        split($1, parts, "_");
        partition = parts[length(parts)];
        messages = $2;
        total[partition] += messages;
    } END {
        for (p in total) {
            if (total[p] > 0) {
                printf "   📁 파티션 \"%s\": %d개 메시지\n", p, total[p];
            }
        }
    }'
    
    echo ""
    echo "🎯 Consumer별 파티션 할당:"
    current_replicas=$(kubectl get statefulset message-consumer -o jsonpath='{.spec.replicas}')
    echo "   현재 Consumer 수: ${current_replicas}개"
    
    # 36개 문자를 현재 replica 수로 나눈 할당 계산
    if [[ $current_replicas -gt 0 ]]; then
        chars_per_consumer=$((36 / current_replicas))
        remainder=$((36 % current_replicas))
        echo "   파티션 할당: Consumer당 ${chars_per_consumer}개 파티션"
        if [[ $remainder -gt 0 ]]; then
            echo "   마지막 Consumer: +${remainder}개 추가 파티션"
        fi
    fi
}

# 우선순위 처리 분석
analyze_priority_processing() {
    echo "⭐ 우선순위 처리 분석"
    echo "----------------------------------------"
    
    # 각 Consumer의 최근 처리 우선순위 확인
    kubectl get pods -l app=message-consumer --no-headers | while read name ready status restarts age; do
        if [[ "$status" == "Running" ]]; then
            echo "🤖 $name 우선순위 처리 순서:"
            
            # 최근 10개 처리 메시지의 우선순위 추출
            priorities=$(kubectl logs $name --tail=20 2>/dev/null | grep "🔄.*처리됨" | tail -10 | grep -o '우선순위: [0-9]*' | cut -d' ' -f2 | tr '\n' ' ')
            
            if [[ -n "$priorities" ]]; then
                echo "     처리 순서: $priorities"
                
                # 우선순위가 내림차순으로 처리되는지 확인
                echo "$priorities" | tr ' ' '\n' | grep -v '^$' | awk '
                BEGIN { prev=11; correct=1 }
                { 
                    if (NR > 1 && $1 > prev) correct=0;
                    prev = $1;
                }
                END { 
                    if (correct) print "     ✅ 우선순위 올바르게 처리됨 (높은 순서부터)";
                    else print "     ❌ 우선순위 처리 순서 이상";
                }'
            else
                echo "     🕐 처리 기록 없음"
            fi
            echo ""
        fi
    done
}

# 스케일링 이벤트 추적
track_scaling_events() {
    echo "📈 스케일링 이벤트 실시간 추적"
    echo "----------------------------------------"
    
    # AutoScaler 로그에서 스케일링 결정 과정 분석
    echo "🧠 AutoScaler 최근 결정 과정:"
    kubectl logs deployment/message-autoscaler --tail=10 | grep "📊\|📈" | tail -5 | while read line; do
        if [[ "$line" == *"📈"* ]]; then
            echo "   🚀 $line"
        else
            echo "   📊 $line"
        fi
    done
    
    echo ""
    echo "📊 현재 스케일링 상태:"
    current_replicas=$(kubectl get statefulset message-consumer -o jsonpath='{.spec.replicas}')
    ready_replicas=$(kubectl get statefulset message-consumer -o jsonpath='{.status.readyReplicas}')
    echo "   목표: ${current_replicas}개, 준비됨: ${ready_replicas}개"
    
    if [[ $current_replicas -eq $ready_replicas ]]; then
        echo "   ✅ 스케일링 완료"
    else
        echo "   ⏳ 스케일링 진행 중..."
    fi
}

# 메인 분석 실행
echo "1️⃣  현재 상태 스냅샷"
take_snapshot "현재 시스템 상태"

echo "2️⃣  Consumer 활동 분석"
analyze_consumer_activity

echo "3️⃣  파티셔닝 분석"
analyze_partitioning

echo ""
echo "4️⃣  우선순위 처리 분석"
analyze_priority_processing

echo "5️⃣  스케일링 이벤트 추적"
track_scaling_events

echo ""
echo "🎯 요약 및 권장사항"
echo "=========================================="

# 종합 평가
total_messages=$(kubectl exec deployment/rabbitmq -- rabbitmqctl list_queues messages --timeout 5 2>/dev/null | \
grep -v "Timeout\|Listing\|messages" | awk '{sum += $1} END {print sum+0}')

current_replicas=$(kubectl get statefulset message-consumer -o jsonpath='{.spec.replicas}')

if [[ $total_messages -gt $((current_replicas * 10)) ]]; then
    echo "⚠️  메시지 과부하: 총 ${total_messages}개 메시지가 대기 중입니다."
    echo "   권장: Consumer 수를 늘리거나 처리 속도를 높이세요."
elif [[ $total_messages -eq 0 ]] && [[ $current_replicas -gt 1 ]]; then
    echo "💡 스케일 다운 가능: 모든 큐가 비어있고 Consumer가 ${current_replicas}개 실행 중입니다."
    echo "   권장: AutoScaler가 곧 스케일 다운할 예정입니다."
else
    echo "✅ 시스템 정상: 메시지 ${total_messages}개, Consumer ${current_replicas}개로 균형잡힌 상태입니다."
fi

echo ""
echo "🔄 실시간 모니터링을 원하면: watch -n 5 '$0'"
echo "📊 분석 완료: $(date)"
echo "==========================================" 
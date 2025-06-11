#!/bin/bash

# 메시지 처리 흐름 실시간 추적 스크립트

echo "🚀 메시지 처리 흐름 실시간 추적기"
echo "=========================================="

# 색상 코드
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 추적 시작 시간
START_TIME=$(date +%s)

print_header() {
    clear
    echo -e "${CYAN}🚀 메시지 처리 흐름 실시간 추적기${NC}"
    echo -e "${CYAN}=========================================${NC}"
    echo -e "⏰ 추적 시작: $(date)"
    echo -e "📊 실행 시간: $(($(date +%s) - START_TIME))초"
    echo ""
}

# Publisher 상태 확인
check_publisher() {
    echo -e "${YELLOW}📨 Publisher 상태:${NC}"
    
    pub_status=$(kubectl get deployment message-publisher -o jsonpath='{.status.replicas}' 2>/dev/null)
    if [[ -n "$pub_status" ]] && [[ "$pub_status" != "0" ]]; then
        echo -e "   ${GREEN}✅ 활성 - 메시지 전송 중${NC}"
        
        # 최근 전송 로그
        recent_send=$(kubectl logs deployment/message-publisher --tail=3 2>/dev/null | grep "📤" | tail -1)
        if [[ -n "$recent_send" ]]; then
            echo "   $recent_send"
        fi
    else
        echo -e "   ${RED}❌ 비활성${NC}"
    fi
    echo ""
}

# Consumer 개별 성능 분석
analyze_consumer_performance() {
    echo -e "${BLUE}🤖 Consumer 개별 성능 분석:${NC}"
    echo "----------------------------------------"
    
    # 각 Consumer Pod의 상태와 성능
    kubectl get pods -l app=message-consumer --no-headers | while read name ready status restarts age; do
        if [[ "$status" == "Running" ]]; then
            echo -e "${GREEN}✅ $name${NC}"
            
            # 최근 처리 통계
            total_processed=$(kubectl logs $name 2>/dev/null | grep -c "🔄.*처리됨")
            last_processed=$(kubectl logs $name --tail=5 2>/dev/null | grep "🔄.*처리됨" | tail -1)
            
            echo "   📊 총 처리: ${total_processed}개 메시지"
            
            if [[ -n "$last_processed" ]]; then
                # 마지막 처리 시간 추출
                last_time=$(echo "$last_processed" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]')
                last_id=$(echo "$last_processed" | grep -o 'ID: [a-zA-Z0-9]*' | cut -d' ' -f2)
                last_priority=$(echo "$last_processed" | grep -o '우선순위: [0-9]*' | cut -d' ' -f2)
                
                echo "   🕐 마지막 처리: [$last_time] $last_id (우선순위: $last_priority)"
                
                            # 처리 간격 확인 (최근 2개 메시지)
            recent_times=$(kubectl logs $name --tail=10 2>/dev/null | grep "🔄.*처리됨" | tail -2 | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]')
                if [[ $(echo "$recent_times" | wc -l) -eq 2 ]]; then
                    time1=$(echo "$recent_times" | head -1 | tr ':' ' ' | awk '{print $1*3600 + $2*60 + $3}')
                    time2=$(echo "$recent_times" | tail -1 | tr ':' ' ' | awk '{print $1*3600 + $2*60 + $3}')
                    interval=$((time2 - time1))
                    if [[ $interval -gt 0 ]]; then
                        echo "   ⏱️  처리 간격: ${interval}초"
                    fi
                fi
            fi
            
            # 현재 담당 파티션
            active_partitions=$(kubectl logs $name --tail=20 2>/dev/null | grep "📥.*수신됨" | tail -5 | grep -o 'queue_[^_]*_[a-z0-9]' | grep -o '_[a-z0-9]$' | tr -d '_' | sort | uniq | tr '\n' ' ')
            if [[ -n "$active_partitions" ]]; then
                echo "   📦 활성 파티션: $active_partitions"
            fi
            
            # 처리 중인 우선순위 범위
            priority_range=$(kubectl logs $name --tail=10 2>/dev/null | grep "🔄.*처리됨" | grep -o '우선순위: [0-9]*' | cut -d' ' -f2 | sort -nr | head -1)
            if [[ -n "$priority_range" ]]; then
                priority_min=$(kubectl logs $name --tail=10 2>/dev/null | grep "🔄.*처리됨" | grep -o '우선순위: [0-9]*' | cut -d' ' -f2 | sort -n | head -1)
                echo "   ⭐ 우선순위 범위: $priority_min ~ $priority_range"
            fi
            
        else
            echo -e "${RED}❌ $name ($status)${NC}"
        fi
        echo ""
    done
}

# 큐 상태 실시간 모니터링
monitor_queue_status() {
    echo -e "${PURPLE}📬 큐 상태 실시간 모니터링:${NC}"
    echo "----------------------------------------"
    
    # 총 메시지 수
    total_messages=$(kubectl exec deployment/rabbitmq -- rabbitmqctl list_queues messages --timeout 5 2>/dev/null | \
    grep -v "Timeout\|Listing\|messages" | awk '{sum += $1} END {print sum+0}')
    
    echo "📊 총 대기 메시지: ${total_messages}개"
    
    # 상위 활성 큐들
    echo "🔥 가장 바쁜 큐들 (Top 5):"
    kubectl exec deployment/rabbitmq -- rabbitmqctl list_queues name messages --timeout 5 2>/dev/null | \
    grep -v "Timeout\|Listing\|name" | \
    awk '$2 > 0 {print $0}' | \
    sort -k2 -nr | \
    head -5 | \
    while read queue_name messages; do
        partition=$(echo $queue_name | grep -o '_[a-z0-9]$' | tr -d '_')
        if [[ -n "$partition" ]]; then
            if [[ $messages -gt 20 ]]; then
                echo -e "   ${RED}🔴 파티션 '$partition': ${messages}개${NC}"
            elif [[ $messages -gt 10 ]]; then
                echo -e "   ${YELLOW}🟡 파티션 '$partition': ${messages}개${NC}"
            else
                echo -e "   ${GREEN}🟢 파티션 '$partition': ${messages}개${NC}"
            fi
        fi
    done
    
    # 처리 속도 vs 생성 속도 분석
    echo ""
    echo "📈 처리 효율성 분석:"
    
    # Consumer 수
    consumer_count=$(kubectl get statefulset message-consumer -o jsonpath='{.spec.replicas}')
    ready_consumers=$(kubectl get statefulset message-consumer -o jsonpath='{.status.readyReplicas}')
    
    echo "   🤖 Consumer: ${ready_consumers}/${consumer_count}개 활성"
    
    # 예상 처리율 (3초당 1개씩)
    expected_rate_per_min=$((ready_consumers * 20)) # 60초 / 3초 = 20개/분
    echo "   📊 예상 처리율: ${expected_rate_per_min}개/분"
    
    # 메시지 축적 경향
    if [[ $total_messages -gt $((ready_consumers * 15)) ]]; then
        echo -e "   ${RED}⚠️  메시지 축적 중 - 스케일 아웃 필요${NC}"
    elif [[ $total_messages -lt 5 ]] && [[ $ready_consumers -gt 1 ]]; then
        echo -e "   ${GREEN}💡 스케일 다운 가능${NC}"
    else
        echo -e "   ${GREEN}✅ 처리 균형 유지${NC}"
    fi
    
    echo ""
}

# AutoScaler 결정 과정 추적
track_autoscaler_decisions() {
    echo -e "${CYAN}🧠 AutoScaler 결정 과정:${NC}"
    echo "----------------------------------------"
    
    # 최근 AutoScaler 로그 분석
    recent_decisions=$(kubectl logs deployment/message-autoscaler --tail=5 2>/dev/null | grep -E "📊|📈|🔄")
    
    if [[ -n "$recent_decisions" ]]; then
        echo "$recent_decisions" | while read line; do
            if [[ "$line" == *"📈"* ]]; then
                echo -e "   ${GREEN}🚀 $line${NC}"
            elif [[ "$line" == *"📊"* ]]; then
                echo -e "   📊 $line"
            else
                echo -e "   🔄 $line"
            fi
        done
    else
        echo "   🕐 최근 결정 기록 없음"
    fi
    
    # 다음 스케일링 예측
    echo ""
    echo "🔮 스케일링 예측:"
    
    current_replicas=$(kubectl get statefulset message-consumer -o jsonpath='{.spec.replicas}')
    total_messages=$(kubectl exec deployment/rabbitmq -- rabbitmqctl list_queues messages --timeout 5 2>/dev/null | \
    grep -v "Timeout\|Listing\|messages" | awk '{sum += $1} END {print sum+0}')
    
    messages_per_consumer=$((total_messages / current_replicas))
    
    if [[ $messages_per_consumer -gt 10 ]]; then
        echo -e "   ${YELLOW}📈 스케일 아웃 예상 (Consumer당 ${messages_per_consumer}개 메시지)${NC}"
    elif [[ $total_messages -eq 0 ]] && [[ $current_replicas -gt 1 ]]; then
        echo -e "   ${BLUE}📉 스케일 다운 예상 (큐 비어있음)${NC}"
    else
        echo -e "   ${GREEN}✅ 현재 규모 유지 예상${NC}"
    fi
    
    echo ""
}

# 메시지 라이프사이클 추적
track_message_lifecycle() {
    echo -e "${GREEN}🔄 메시지 라이프사이클 추적 (최근 5개):${NC}"
    echo "----------------------------------------"
    
    # 최근 처리된 메시지들의 전체 흐름 추적
    kubectl get pods -l app=message-consumer --no-headers | while read name ready status restarts age; do
        if [[ "$status" == "Running" ]]; then
            echo "🤖 $name 최근 처리:"
            
            kubectl logs $name --tail=15 2>/dev/null | grep -E "📥.*수신됨|🔄.*처리됨" | tail -5 | while read line; do
                if [[ "$line" == *"📥"* ]]; then
                    time=$(echo "$line" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]')
                    id=$(echo "$line" | grep -o 'ID: [a-zA-Z0-9]*' | cut -d' ' -f2)
                    priority=$(echo "$line" | grep -o '우선순위: [0-9]*' | cut -d' ' -f2)
                    echo -e "     📥 [$time] 수신: $id (우선순위: $priority)"
                elif [[ "$line" == *"🔄"* ]]; then
                    time=$(echo "$line" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]')
                    id=$(echo "$line" | grep -o 'ID: [a-zA-Z0-9]*' | cut -d' ' -f2)
                    priority=$(echo "$line" | grep -o '우선순위: [0-9]*' | cut -d' ' -f2)
                    echo -e "     ${GREEN}🔄 [$time] 처리: $id (우선순위: $priority)${NC}"
                fi
            done
            echo ""
        fi
    done
}

# 메인 모니터링 루프
if [[ "$1" == "--once" ]]; then
    # 한 번만 실행
    print_header
    check_publisher
    analyze_consumer_performance
    monitor_queue_status
    track_autoscaler_decisions
    track_message_lifecycle
else
    # 지속적 모니터링
    echo "🔄 실시간 모니터링 시작 (Ctrl+C로 종료)"
    echo "   한 번만 실행하려면: $0 --once"
    echo ""
    
    while true; do
        print_header
        check_publisher
        analyze_consumer_performance
        monitor_queue_status
        track_autoscaler_decisions
        track_message_lifecycle
        
        echo -e "${CYAN}📊 다음 업데이트까지 5초 대기... (Ctrl+C로 종료)${NC}"
        sleep 5
    done
fi 
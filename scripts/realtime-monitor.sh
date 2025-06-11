#!/bin/bash

# 실시간 오토 스케일링 모니터링 스크립트
echo "🚀 실시간 오토 스케일링 모니터링 시작"
echo "=================================================="
echo "Ctrl+C로 종료"
echo ""

while true; do
    clear
    echo "⏰ $(date)"
    echo "=================================================="
    
    # 1. StatefulSet 상태
    echo "📊 StatefulSet 상태:"
    kubectl get statefulset message-consumer -o custom-columns="NAME:.metadata.name,DESIRED:.spec.replicas,CURRENT:.status.replicas,READY:.status.readyReplicas,AGE:.metadata.creationTimestamp" 2>/dev/null || echo "  StatefulSet을 찾을 수 없습니다."
    echo ""
    
    # 2. Consumer Pod 상태
    echo "🎯 Consumer Pod 상태:"
    kubectl get pods -l app=message-consumer -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,READY:.status.conditions[?(@.type=='Ready')].status,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp" 2>/dev/null || echo "  Consumer Pod을 찾을 수 없습니다."
    echo ""
    
    # 3. 큐 상태 (메시지가 있는 큐만)
    echo "📬 RabbitMQ 큐 상태 (메시지가 있는 큐만):"
    QUEUE_STATUS=$(kubectl exec -it deployment/rabbitmq -- rabbitmqctl list_queues name messages consumers --timeout 10 2>/dev/null | grep -v "Timeout\|Listing\|name" | awk '$2 > 0 {printf "  %s: %d개 메시지, %d개 컨슈머\n", $1, $2, $3}')
    if [ -z "$QUEUE_STATUS" ]; then
        echo "  모든 큐가 비어있습니다. ✅"
    else
        echo "$QUEUE_STATUS"
    fi
    
    # 총 메시지 수 계산
    TOTAL_MESSAGES=$(kubectl exec -it deployment/rabbitmq -- rabbitmqctl list_queues messages --timeout 10 2>/dev/null | grep -v "Timeout\|Listing\|messages" | awk '{sum += $1} END {print sum+0}')
    echo "  📈 총 메시지 수: $TOTAL_MESSAGES개"
    echo ""
    
    # 4. AutoScaler 최신 로그
    echo "🤖 AutoScaler 최신 상태:"
    AUTOSCALER_LOG=$(kubectl logs deployment/message-autoscaler --tail=3 2>/dev/null | grep "📊\|📈")
    if [ -z "$AUTOSCALER_LOG" ]; then
        echo "  AutoScaler 로그를 가져올 수 없습니다."
    else
        echo "$AUTOSCALER_LOG" | sed 's/^/  /'
    fi
    echo ""
    
    # 5. Publisher 상태
    echo "📤 Publisher 상태:"
    PUBLISHER_PODS=$(kubectl get pods -l app=message-publisher -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp" 2>/dev/null)
    if [ -z "$PUBLISHER_PODS" ] || [ "$(echo "$PUBLISHER_PODS" | wc -l)" -eq 1 ]; then
        echo "  실행 중인 Publisher가 없습니다."
    else
        echo "$PUBLISHER_PODS" | sed 's/^/  /'
    fi
    echo ""
    
    # 6. 최근 Consumer 처리 로그
    echo "🔄 최근 Consumer 메시지 처리:"
    CONSUMER_LOG=$(kubectl logs message-consumer-0 --tail=3 2>/dev/null | grep "🔄.*처리됨" | tail -2)
    if [ -z "$CONSUMER_LOG" ]; then
        echo "  최근 처리된 메시지가 없습니다."
    else
        echo "$CONSUMER_LOG" | sed 's/^/  /'
    fi
    
    echo ""
    echo "=================================================="
    echo "⏱️  5초 후 업데이트... (Ctrl+C로 종료)"
    
    sleep 5
done 
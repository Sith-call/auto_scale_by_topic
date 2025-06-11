#!/bin/bash

# 테스트 결과 분석 스크립트

if [ $# -eq 0 ]; then
    echo "사용법: $0 <test-results/TIMESTAMP>"
    echo "예시: $0 test-results/20250611_140030"
    echo ""
    echo "사용 가능한 테스트 결과:"
    ls -la test-results/ 2>/dev/null | grep "^d" | awk '{print "  " $9}' | grep -v "^\.$\|^\.\.$"
    exit 1
fi

RESULT_DIR=$1

if [ ! -d "$RESULT_DIR" ]; then
    echo "❌ 디렉토리를 찾을 수 없습니다: $RESULT_DIR"
    exit 1
fi

echo "📊 테스트 결과 분석: $RESULT_DIR"
echo "============================================"

# 요약 파일이 있으면 먼저 표시
if [ -f "$RESULT_DIR/test_summary.md" ]; then
    echo "📋 테스트 요약:"
    cat "$RESULT_DIR/test_summary.md"
    echo ""
fi

echo "============================================"
echo "📈 상세 분석 결과"
echo "============================================"

# 스케일링 이벤트 추출
echo "🔍 스케일링 이벤트 추출:"
grep -h "📈.*스케일링" "$RESULT_DIR"/*.log 2>/dev/null | sort | uniq | while read line; do
    echo "  $line"
done

if [ $? -ne 0 ]; then
    echo "  스케일링 이벤트가 발견되지 않았습니다."
fi
echo ""

# 최대 메시지 수 찾기
echo "📊 최대 메시지 수:"
MAX_MESSAGES=$(grep -h "총.*개 메시지" "$RESULT_DIR"/*.log 2>/dev/null | grep -o '[0-9]\+' | sort -n | tail -1)
if [ -n "$MAX_MESSAGES" ]; then
    echo "  최대 $MAX_MESSAGES개 메시지"
else
    echo "  메시지 수 정보를 찾을 수 없습니다."
fi
echo ""

# replica 수 변화 추적
echo "📈 Replica 수 변화:"
grep -h "DESIRED" "$RESULT_DIR"/*.log 2>/dev/null | grep -v "NAME" | awk '{print $2}' | sort | uniq -c | while read count desired; do
    echo "  $desired개 replica: $count회 관측됨"
done
echo ""

# 시나리오별 결과 요약
echo "🎯 시나리오별 결과:"
for scenario in "scenario1_low_load" "scenario2_high_load" "scenario3_scale_down" "scenario4_medium_load"; do
    if ls "$RESULT_DIR"/${scenario}_*.log 1> /dev/null 2>&1; then
        echo ""
        case $scenario in
            "scenario1_low_load")
                echo "  🔵 시나리오 1 (낮은 부하):"
                ;;
            "scenario2_high_load") 
                echo "  🔴 시나리오 2 (높은 부하):"
                ;;
            "scenario3_scale_down")
                echo "  🟡 시나리오 3 (스케일 다운):"
                ;;
            "scenario4_medium_load")
                echo "  🟠 시나리오 4 (중간 부하):"
                ;;
        esac
        
        # 각 시나리오의 replica 변화
        REPLICAS=$(grep -h "DESIRED" "$RESULT_DIR"/${scenario}_*.log 2>/dev/null | grep -v "NAME" | awk '{print $2}' | tr '\n' ' ')
        if [ -n "$REPLICAS" ]; then
            echo "    Replica 변화: $REPLICAS"
        fi
        
        # 메시지 수 변화
        MESSAGES=$(grep -h "총.*개 메시지" "$RESULT_DIR"/${scenario}_*.log 2>/dev/null | grep -o '[0-9]\+' | tr '\n' ' ')
        if [ -n "$MESSAGES" ]; then
            echo "    메시지 수 변화: $MESSAGES"
        fi
        
        # 스케일링 이벤트
        SCALING=$(grep -h "📈.*스케일링" "$RESULT_DIR"/${scenario}_*.log 2>/dev/null | wc -l)
        if [ "$SCALING" -gt 0 ]; then
            echo "    스케일링 이벤트: ${SCALING}회"
        fi
    fi
done

echo ""
echo "============================================"
echo "📁 파일 목록:"
ls -la "$RESULT_DIR"/ | grep -v "^total" | while read line; do
    echo "  $line"
done

echo ""
echo "💡 특정 로그 파일 내용 보기:"
echo "   cat $RESULT_DIR/[파일명].log"
echo ""
echo "🔍 특정 패턴 검색 예시:"
echo "   grep '스케일링' $RESULT_DIR/*.log"
echo "   grep '총.*메시지' $RESULT_DIR/*.log"
echo "============================================" 
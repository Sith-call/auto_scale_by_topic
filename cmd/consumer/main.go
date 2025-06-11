package main

import (
	"container/heap"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"auto_scaleout_by_topic_name/pkg/message"
	amqp "github.com/rabbitmq/amqp091-go"
)

// PriorityQueue 우선순위 큐 구현
type PriorityQueue []*message.Message

func (pq PriorityQueue) Len() int { return len(pq) }

func (pq PriorityQueue) Less(i, j int) bool {
	// 높은 우선순위가 먼저 처리되도록 (max heap)
	return pq[i].Priority > pq[j].Priority
}

func (pq PriorityQueue) Swap(i, j int) {
	pq[i], pq[j] = pq[j], pq[i]
}

func (pq *PriorityQueue) Push(x interface{}) {
	*pq = append(*pq, x.(*message.Message))
}

func (pq *PriorityQueue) Pop() interface{} {
	old := *pq
	n := len(old)
	item := old[n-1]
	*pq = old[0 : n-1]
	return item
}

type Consumer struct {
	conn           *amqp.Connection
	channel        *amqp.Channel
	consumerID     string
	totalConsumers int
	messageQueue   PriorityQueue
	currentQueues  []string // 현재 생성된 큐 목록
	consumerTags   []string // Consumer 태그 목록
}

func NewConsumer(rabbitmqURL, consumerID string, totalConsumers int) (*Consumer, error) {
	conn, err := amqp.Dial(rabbitmqURL)
	if err != nil {
		return nil, fmt.Errorf("RabbitMQ 연결 실패: %w", err)
	}

	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("채널 생성 실패: %w", err)
	}

	// Exchange 선언
	err = ch.ExchangeDeclare(
		"message_distribution",
		"direct",
		true,
		false,
		false,
		false,
		nil,
	)
	if err != nil {
		ch.Close()
		conn.Close()
		return nil, fmt.Errorf("Exchange 선언 실패: %w", err)
	}

	consumer := &Consumer{
		conn:           conn,
		channel:        ch,
		consumerID:     consumerID,
		totalConsumers: totalConsumers,
		messageQueue:   make(PriorityQueue, 0),
		currentQueues:  make([]string, 0),
		consumerTags:   make([]string, 0),
	}

	heap.Init(&consumer.messageQueue)

	// 초기 큐 설정
	if err := consumer.setupQueues(); err != nil {
		consumer.Close()
		return nil, err
	}

	fmt.Printf("✅ Consumer %s 초기화 완료 (총 %d개 Consumer 중)\n", consumerID, totalConsumers)
	return consumer, nil
}

func (c *Consumer) calculateRoutingKeys() []string {
	// 36개 문자 (a-z: 26개 + 0-9: 10개)를 총 Consumer 수로 나누어 분배
	allChars := "abcdefghijklmnopqrstuvwxyz0123456789"
	
	// StatefulSet Pod 이름에서 순서 번호 추출 (예: message-consumer-0)
	var consumerNum int
	if strings.Contains(c.consumerID, "-") {
		parts := strings.Split(c.consumerID, "-")
		if len(parts) > 0 {
			if num, err := strconv.Atoi(parts[len(parts)-1]); err == nil {
				consumerNum = num
			}
		}
	}
	
	charsPerConsumer := len(allChars) / c.totalConsumers
	remainder := len(allChars) % c.totalConsumers
	
	startIdx := consumerNum * charsPerConsumer
	endIdx := startIdx + charsPerConsumer
	
	// 나머지가 있으면 마지막 Consumer가 더 많이 처리
	if consumerNum == c.totalConsumers-1 {
		endIdx += remainder
	}
	
	var routingKeys []string
	for i := startIdx; i < endIdx; i++ {
		routingKeys = append(routingKeys, string(allChars[i]))
	}
	
	sort.Strings(routingKeys)
	fmt.Printf("📍 Consumer %s (번호: %d) 담당 라우팅키: %v\n", c.consumerID, consumerNum, routingKeys)
	return routingKeys
}

func (c *Consumer) cleanupOldQueues() error {
	// 기존 Consumer 취소
	for _, tag := range c.consumerTags {
		c.channel.Cancel(tag, false)
	}
	c.consumerTags = []string{}

	// 기존에 생성한 큐들을 정리 (필요시)
	// 실제 운영에서는 큐를 바로 삭제하지 않고 메시지를 다른 큐로 이동하는 것이 안전
	for _, queueName := range c.currentQueues {
		fmt.Printf("🧹 기존 큐 정리: %s\n", queueName)
		// 큐의 메시지 수 확인
		queue, err := c.channel.QueueInspect(queueName)
		if err == nil && queue.Messages > 0 {
			fmt.Printf("⚠️  큐 %s에 %d개 메시지가 남아있음 - 처리 완료 후 정리 예정\n", queueName, queue.Messages)
		}
	}
	c.currentQueues = []string{}
	
	return nil
}

func (c *Consumer) setupQueues() error {
	// 기존 큐 정리
	if err := c.cleanupOldQueues(); err != nil {
		return err
	}

	// 이 Consumer가 처리할 routing key들 계산
	routingKeys := c.calculateRoutingKeys()
	
	// 각 routing key에 대해 queue 생성 및 바인딩
	for _, routingKey := range routingKeys {
		queueName := fmt.Sprintf("queue_%s_%s", c.consumerID, routingKey)
		
		_, err := c.channel.QueueDeclare(
			queueName,
			true,  // durable
			false, // delete when unused
			false, // exclusive
			false, // no-wait
			amqp.Table{"x-max-priority": 10}, // 우선순위 큐 설정
		)
		if err != nil {
			return fmt.Errorf("큐 선언 실패: %w", err)
		}

		err = c.channel.QueueBind(
			queueName,
			routingKey,
			"message_distribution",
			false,
			nil,
		)
		if err != nil {
			return fmt.Errorf("큐 바인딩 실패: %w", err)
		}

		c.currentQueues = append(c.currentQueues, queueName)
		fmt.Printf("✅ Consumer %s가 라우팅키 '%s'에 바인딩됨 (큐: %s)\n", c.consumerID, routingKey, queueName)
	}

	return nil
}

func (c *Consumer) startConsuming() {
	// 각 큐에서 메시지 소비 시작
	for _, queueName := range c.currentQueues {
		msgs, err := c.channel.Consume(
			queueName,
			"",    // consumer
			false, // auto-ack (수동으로 ack 처리)
			false, // exclusive
			false, // no-local
			false, // no-wait
			nil,   // args
		)
		if err != nil {
			log.Printf("❌ 큐 %s 소비 실패: %v", queueName, err)
			continue
		}

		// 각 큐에 대해 별도 고루틴으로 메시지 수신
		go func(queueName string, msgs <-chan amqp.Delivery) {
			for d := range msgs {
				var msg message.Message
				if err := json.Unmarshal(d.Body, &msg); err != nil {
					log.Printf("❌ 메시지 역직렬화 실패: %v", err)
					d.Nack(false, false) // 메시지 거부
					continue
				}

				// 우선순위 큐에 메시지 추가
				heap.Push(&c.messageQueue, &msg)
				d.Ack(false) // 메시지 확인

				fmt.Printf("📥 메시지 수신됨 [%s]: ID=%s, Priority=%d (큐: %s)\n", 
					c.consumerID, msg.ID, msg.Priority, queueName)
			}
		}(queueName, msgs)
	}

	// 3초마다 가장 높은 우선순위 메시지 처리
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	fmt.Printf("🚀 Consumer %s 메시지 처리 시작\n", c.consumerID)

	// 동적 재설정 체크 (30초마다)
	reconfigTicker := time.NewTicker(30 * time.Second)
	defer reconfigTicker.Stop()

	for {
		select {
		case <-ticker.C:
			if c.messageQueue.Len() > 0 {
				// 가장 높은 우선순위 메시지 처리
				msg := heap.Pop(&c.messageQueue).(*message.Message)
				c.processMessage(msg)
			}
		case <-reconfigTicker.C:
			// 환경변수에서 총 Consumer 수 재확인
			if newTotal := os.Getenv("TOTAL_CONSUMERS"); newTotal != "" {
				if parsed, err := strconv.Atoi(newTotal); err == nil && parsed != c.totalConsumers {
					fmt.Printf("🔄 Consumer 수 변경 감지: %d -> %d\n", c.totalConsumers, parsed)
					c.totalConsumers = parsed
					
					// 큐 재설정
					if err := c.setupQueues(); err != nil {
						log.Printf("❌ 큐 재설정 실패: %v", err)
					} else {
						fmt.Printf("✅ 파티션 재할당 완료\n")
						// 새 큐에서 메시지 소비 시작
						c.startConsuming()
						return // 재귀 호출로 새로운 소비 루프 시작
					}
				}
			}
		}
	}
}

func (c *Consumer) processMessage(msg *message.Message) {
	processedTime := time.Now()
	fmt.Printf("🔄 [%s] 메시지 처리됨 - 시각: %s, ID: %s, 우선순위: %d\n",
		c.consumerID,
		processedTime.Format("2006-01-02 15:04:05"),
		msg.ID,
		msg.Priority)
}

func (c *Consumer) Close() {
	// Consumer 취소
	for _, tag := range c.consumerTags {
		c.channel.Cancel(tag, false)
	}
	
	if c.channel != nil {
		c.channel.Close()
	}
	if c.conn != nil {
		c.conn.Close()
	}
	fmt.Printf("🔌 Consumer %s 연결이 종료되었습니다\n", c.consumerID)
}

func main() {
	// 환경변수에서 설정 읽기
	rabbitmqURL := os.Getenv("RABBITMQ_URL")
	if rabbitmqURL == "" {
		rabbitmqURL = "amqp://guest:guest@localhost:5672/"
	}

	consumerID := os.Getenv("CONSUMER_ID")
	if consumerID == "" {
		consumerID = "consumer-0"
	}

	totalConsumers := 1
	if tc := os.Getenv("TOTAL_CONSUMERS"); tc != "" {
		if parsed, err := strconv.Atoi(tc); err == nil {
			totalConsumers = parsed
		}
	}

	consumer, err := NewConsumer(rabbitmqURL, consumerID, totalConsumers)
	if err != nil {
		log.Fatalf("Consumer 생성 실패: %v", err)
	}
	defer consumer.Close()

	// 메시지 소비 시작
	consumer.startConsuming()
} 
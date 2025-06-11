package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"os"
	"strconv"
	"strings"
	"time"

	"auto_scaleout_by_topic_name/pkg/message"
	amqp "github.com/rabbitmq/amqp091-go"
)

type Publisher struct {
	conn    *amqp.Connection
	channel *amqp.Channel
}

func NewPublisher(rabbitmqURL string) (*Publisher, error) {
	conn, err := amqp.Dial(rabbitmqURL)
	if err != nil {
		return nil, fmt.Errorf("RabbitMQ 연결 실패: %w", err)
	}

	ch, err := conn.Channel()
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("채널 생성 실패: %w", err)
	}

	// Exchange 선언 (direct type으로 routing key 기반 분산)
	err = ch.ExchangeDeclare(
		"message_distribution", // exchange 이름
		"direct",              // exchange 타입
		true,                  // durable
		false,                 // auto-deleted
		false,                 // internal
		false,                 // no-wait
		nil,                   // arguments
	)
	if err != nil {
		ch.Close()
		conn.Close()
		return nil, fmt.Errorf("Exchange 선언 실패: %w", err)
	}

	fmt.Println("✅ RabbitMQ에 연결되었습니다")
	return &Publisher{conn: conn, channel: ch}, nil
}

func (p *Publisher) generateMessageID() string {
	// 알파벳 또는 숫자로 시작하는 8자리 ID 생성
	chars := "abcdefghijklmnopqrstuvwxyz0123456789"
	
	var result strings.Builder
	result.WriteByte(chars[rand.Intn(len(chars))]) // 첫 글자
	
	for i := 0; i < 7; i++ {
		result.WriteByte(chars[rand.Intn(len(chars))])
	}
	
	return result.String()
}

func (p *Publisher) createMessage() message.Message {
	return message.Message{
		ID:        p.generateMessageID(),
		Priority:  rand.Intn(10) + 1, // 1-10 우선순위
		Timestamp: time.Now(),
	}
}

func (p *Publisher) publishMessage(msg message.Message) error {
	body, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("메시지 직렬화 실패: %w", err)
	}

	// ID의 첫 글자를 routing key로 사용
	routingKey := strings.ToLower(string(msg.ID[0]))

	err = p.channel.Publish(
		"message_distribution", // exchange
		routingKey,            // routing key
		false,                 // mandatory
		false,                 // immediate
		amqp.Publishing{
			Priority:     uint8(msg.Priority),
			DeliveryMode: amqp.Persistent, // 메시지 지속성
			ContentType:  "application/json",
			Body:         body,
		},
	)

	if err != nil {
		return fmt.Errorf("메시지 발송 실패: %w", err)
	}

	fmt.Printf("📤 메시지 발송됨: ID=%s, Priority=%d, RoutingKey=%s\n", 
		msg.ID, msg.Priority, routingKey)
	return nil
}

func (p *Publisher) startLoadTest(messagesPerSecond, durationSeconds int) {
	fmt.Printf("🚀 부하 테스트 시작: %d msg/sec, %d초간\n", messagesPerSecond, durationSeconds)
	
	endTime := time.Now().Add(time.Duration(durationSeconds) * time.Second)
	messageCount := 0
	
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	for time.Now().Before(endTime) {
		select {
		case <-ticker.C:
			// 1초마다 지정된 수만큼 메시지 발송
			for i := 0; i < messagesPerSecond; i++ {
				msg := p.createMessage()
				if err := p.publishMessage(msg); err != nil {
					log.Printf("❌ 메시지 발송 실패: %v", err)
				} else {
					messageCount++
				}
			}
		}
	}
	
	fmt.Printf("✅ 부하 테스트 완료: 총 %d개 메시지 발송\n", messageCount)
}

func (p *Publisher) Close() {
	if p.channel != nil {
		p.channel.Close()
	}
	if p.conn != nil {
		p.conn.Close()
	}
	fmt.Println("🔌 RabbitMQ 연결이 종료되었습니다")
}

func main() {
	// 환경변수에서 설정 읽기
	rabbitmqURL := os.Getenv("RABBITMQ_URL")
	if rabbitmqURL == "" {
		rabbitmqURL = "amqp://guest:guest@localhost:5672/"
	}

	messagesPerSecond := 10
	if mps := os.Getenv("MESSAGES_PER_SECOND"); mps != "" {
		if parsed, err := strconv.Atoi(mps); err == nil {
			messagesPerSecond = parsed
		}
	}

	durationSeconds := 30
	if ds := os.Getenv("DURATION_SECONDS"); ds != "" {
		if parsed, err := strconv.Atoi(ds); err == nil {
			durationSeconds = parsed
		}
	}

	// 랜덤 시드 설정
	rand.Seed(time.Now().UnixNano())

	publisher, err := NewPublisher(rabbitmqURL)
	if err != nil {
		log.Fatalf("Publisher 생성 실패: %v", err)
	}
	defer publisher.Close()

	// 부하 테스트 실행
	publisher.startLoadTest(messagesPerSecond, durationSeconds)
} 
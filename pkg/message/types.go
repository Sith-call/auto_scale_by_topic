package message

import "time"

// Message 메시지 구조체
type Message struct {
	ID        string    `json:"id"`
	Priority  int       `json:"priority"`
	Timestamp time.Time `json:"timestamp"`
}

// PartitionRange 파티션 범위 정의
type PartitionRange struct {
	Start string
	End   string
}

// ConsumerConfig Consumer 설정
type ConsumerConfig struct {
	ConsumerID      string
	PartitionRanges []PartitionRange
	QueueNames      []string
} 
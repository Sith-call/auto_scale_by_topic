package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strconv"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

type AutoScaler struct {
	k8sClient       kubernetes.Interface
	rabbitmqURL     string
	namespace       string
	deploymentName  string
	minReplicas     int32
	maxReplicas     int32
	currentReplicas int32
}

func NewAutoScaler() (*AutoScaler, error) {
	// Kubernetes 클라이언트 설정 (클러스터 내부에서 실행될 때)
	config, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("Kubernetes 클러스터 설정 실패: %w", err)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, fmt.Errorf("Kubernetes 클라이언트 생성 실패: %w", err)
	}

	// 환경변수에서 설정 읽기
	rabbitmqURL := os.Getenv("RABBITMQ_URL")
	if rabbitmqURL == "" {
		rabbitmqURL = "amqp://guest:guest@rabbitmq:5672/"
	}

	namespace := os.Getenv("NAMESPACE")
	if namespace == "" {
		namespace = "default"
	}

	deploymentName := os.Getenv("CONSUMER_DEPLOYMENT_NAME")
	if deploymentName == "" {
		deploymentName = "message-consumer"
	}

	minReplicas := int32(1)
	if mr := os.Getenv("MIN_REPLICAS"); mr != "" {
		if parsed, err := strconv.ParseInt(mr, 10, 32); err == nil {
			minReplicas = int32(parsed)
		}
	}

	maxReplicas := int32(10)
	if mr := os.Getenv("MAX_REPLICAS"); mr != "" {
		if parsed, err := strconv.ParseInt(mr, 10, 32); err == nil {
			maxReplicas = int32(parsed)
		}
	}

	return &AutoScaler{
		k8sClient:      clientset,
		rabbitmqURL:    rabbitmqURL,
		namespace:      namespace,
		deploymentName: deploymentName,
		minReplicas:    minReplicas,
		maxReplicas:    maxReplicas,
		currentReplicas: minReplicas,
	}, nil
}

func (as *AutoScaler) getQueueMetrics() (int, error) {
	// RabbitMQ에 연결하여 큐 메트릭 조회
	conn, err := amqp.Dial(as.rabbitmqURL)
	if err != nil {
		return 0, fmt.Errorf("RabbitMQ 연결 실패: %w", err)
	}
	defer conn.Close()

	ch, err := conn.Channel()
	if err != nil {
		return 0, fmt.Errorf("채널 생성 실패: %w", err)
	}
	defer ch.Close()

	// 전체 메시지 수 계산 (모든 라우팅키 큐의 메시지 수 합계)
	totalMessages := 0
	chars := "abcdefghijklmnopqrstuvwxyz0123456789"
	
	for i := 0; i < int(as.currentReplicas); i++ {
		consumerID := fmt.Sprintf("consumer-%d", i)
		
		// 각 Consumer가 담당하는 라우팅키 계산
		charsPerConsumer := len(chars) / int(as.currentReplicas)
		remainder := len(chars) % int(as.currentReplicas)
		
		startIdx := i * charsPerConsumer
		endIdx := startIdx + charsPerConsumer
		
		if i == int(as.currentReplicas)-1 {
			endIdx += remainder
		}
		
		for j := startIdx; j < endIdx; j++ {
			routingKey := string(chars[j])
			queueName := fmt.Sprintf("queue_%s_%s", consumerID, routingKey)
			
			queue, err := ch.QueueInspect(queueName)
			if err != nil {
				// 큐가 존재하지 않으면 0으로 처리
				continue
			}
			
			totalMessages += queue.Messages
		}
	}

	return totalMessages, nil
}

func (as *AutoScaler) scaleDeployment(replicas int32) error {
	// StatefulSet 조회 및 스케일링
	statefulSet, err := as.k8sClient.AppsV1().StatefulSets(as.namespace).Get(
		context.TODO(), as.deploymentName, metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("StatefulSet 조회 실패: %w", err)
	}

	if *statefulSet.Spec.Replicas == replicas {
		return nil // 이미 원하는 replica 수
	}

	statefulSet.Spec.Replicas = &replicas
	
	// Consumer에게 총 Consumer 수 알려주기 위한 환경변수 업데이트
	for i := range statefulSet.Spec.Template.Spec.Containers {
		container := &statefulSet.Spec.Template.Spec.Containers[i]
		
		// TOTAL_CONSUMERS 환경변수 업데이트
		for j := range container.Env {
			if container.Env[j].Name == "TOTAL_CONSUMERS" {
				container.Env[j].Value = strconv.Itoa(int(replicas))
				break
			}
		}
	}

	_, err = as.k8sClient.AppsV1().StatefulSets(as.namespace).Update(
		context.TODO(), statefulSet, metav1.UpdateOptions{})
	if err != nil {
		return fmt.Errorf("StatefulSet 업데이트 실패: %w", err)
	}

	as.currentReplicas = replicas
	fmt.Printf("📈 StatefulSet %s 스케일링: %d 복제본으로 변경\n", as.deploymentName, replicas)
	return nil
}

func (as *AutoScaler) makeScalingDecision(queueMessages int) int32 {
	// 스케일링 로직: 큐당 평균 10개 메시지를 기준으로 스케일링
	const messagesPerConsumer = 10
	
	neededReplicas := int32((queueMessages / messagesPerConsumer) + 1)
	
	// 최소/최대 범위 내에서 조정
	if neededReplicas < as.minReplicas {
		neededReplicas = as.minReplicas
	}
	if neededReplicas > as.maxReplicas {
		neededReplicas = as.maxReplicas
	}
	
	return neededReplicas
}

func (as *AutoScaler) run() {
	fmt.Printf("🚀 AutoScaler 시작: namespace=%s, deployment=%s\n", 
		as.namespace, as.deploymentName)
	
	ticker := time.NewTicker(30 * time.Second) // 30초마다 체크
	defer ticker.Stop()

	for range ticker.C {
		queueMessages, err := as.getQueueMetrics()
		if err != nil {
			log.Printf("❌ 큐 메트릭 조회 실패: %v", err)
			continue
		}

		neededReplicas := as.makeScalingDecision(queueMessages)
		
		fmt.Printf("📊 현재 상태 - 큐 메시지: %d, 현재 복제본: %d, 필요 복제본: %d\n", 
			queueMessages, as.currentReplicas, neededReplicas)

		if neededReplicas != as.currentReplicas {
			if err := as.scaleDeployment(neededReplicas); err != nil {
				log.Printf("❌ 스케일링 실패: %v", err)
			}
		}
	}
}

func main() {
	autoscaler, err := NewAutoScaler()
	if err != nil {
		log.Fatalf("AutoScaler 생성 실패: %v", err)
	}

	autoscaler.run()
} 
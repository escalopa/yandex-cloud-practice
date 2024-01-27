package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
)

const (
	YandexVisionUrl = "https://vision.api.cloud.yandex.net/vision/v1/batchAnalyze"
	RegionID        = "ru-central1"
)

func (e Event) String() string {
	return string(e)
}

type (
	Event string

	Vertices []struct {
		X string `json:"x"`
		Y string `json:"y"`
	}

	ObjectTriggerPayload struct {
		Messages []struct {
			EventMetadata struct {
				EventID        string    `json:"event_id"`
				EventType      string    `json:"event_type"`
				CreatedAt      time.Time `json:"created_at"`
				TracingContext struct {
					TraceID      string `json:"trace_id"`
					SpanID       string `json:"span_id"`
					ParentSpanID string `json:"parent_span_id"`
				} `json:"tracing_context"`
				CloudID  string `json:"cloud_id"`
				FolderID string `json:"folder_id"`
			} `json:"event_metadata"`
			Details struct {
				BucketID string `json:"bucket_id"`
				ObjectID string `json:"object_id"`
			} `json:"details"`
		} `json:"messages"`
	}

	VisionResponse struct {
		Results []struct {
			Results []struct {
				FaceDetection struct {
					Faces []struct {
						BoundingBox struct {
							Vertices Vertices `json:"vertices"`
						} `json:"boundingBox"`
					} `json:"faces"`
				} `json:"faceDetection"`
			} `json:"results"`
		} `json:"results"`
	}

	FileData struct {
		BucketID string `json:"bucket_id"`
		ObjectID string `json:"object_id"`
	}

	QueuePaylodObject struct {
		ImageUrl    FileData   `json:"file_data"`
		Coordinates []Vertices `json:"coordinates"`
	}
)

var (
	AccessToken = os.Getenv("AWS_SESSION_TOKEN")
	QueueUrl    = os.Getenv("QUEUE_URL")
	FolderID    = os.Getenv("FOLDER_ID")

	CreateEvent = Event("yandex.cloud.events.storage.ObjectCreate")
)

var (
	sqsClient *sqs.Client
	s3Client  *s3.Client

	customResolver = aws.EndpointResolverWithOptionsFunc(func(service, region string, options ...interface{}) (aws.Endpoint, error) {
		var url string

		switch service {
		case s3.ServiceID:
			url = "https://storage.yandexcloud.net"
		case sqs.ServiceID:
			url = "https://message-queue.api.cloud.yandex.net"
		default:
			return aws.Endpoint{}, fmt.Errorf("unknown service name: %s", service)
		}

		if region == RegionID {
			return aws.Endpoint{
				PartitionID:   "yc",
				URL:           url,
				SigningRegion: RegionID,
			}, nil
		}

		return aws.Endpoint{}, fmt.Errorf("unknown endpoint requested")
	})
)

func sendToQueue(ctx context.Context, images []FileData, visionOut []VisionResponse) error {
	// Append all found faces to payload
	var messageBodies []QueuePaylodObject
	for i, image := range images {
		messageBody := QueuePaylodObject{ImageUrl: image}
		for _, levelOne := range visionOut[i].Results {
			for _, levelTwo := range levelOne.Results {
				for _, face := range levelTwo.FaceDetection.Faces {
					messageBody.Coordinates = append(messageBody.Coordinates, face.BoundingBox.Vertices)
				}
			}
		}
		messageBodies = append(messageBodies, messageBody)
	}

	for _, payload := range messageBodies {
		if len(payload.Coordinates) == 0 {
			log.Printf("empty coordinates for image: %v\n", payload.ImageUrl)
			continue
		}

		body, err := json.Marshal(payload)
		if err != nil {
			return fmt.Errorf("failed to Marshal queue message: %v", err)
		}

		messageString := string(body)
		send, err := sqsClient.SendMessage(ctx, &sqs.SendMessageInput{
			QueueUrl:    &QueueUrl,
			MessageBody: &messageString,
		})
		if err != nil {
			log.Printf("message: %+v\n", messageString)
			return fmt.Errorf("failed to send message to queue: %+v", err)
		}

		log.Printf("succesfully sent message to queue: %v | %s\n", *send.MessageId, messageString)
	}

	return nil
}

func batchAnalyze(ctx context.Context, readers []io.Reader) (visionOuts []VisionResponse, err error) {
	// Send vision the image for detection
	for _, reader := range readers {
		b, err := io.ReadAll(reader)
		if err != nil {
			return nil, fmt.Errorf("failed to read reader: %v", err)
		}

		requestBody := fmt.Sprintf(`
		{
    "folderId": "%s",
    "analyze_specs": [{
        "content": "%s",
        "features": [{
            "type": "FACE_DETECTION"
        }]
    }]
		}`, FolderID, base64.RawStdEncoding.EncodeToString(b))
		requestBody = strings.Join(strings.Fields(requestBody), "")

		req, err := http.NewRequest(http.MethodPost, YandexVisionUrl, bytes.NewBuffer([]byte(requestBody)))
		if err != nil {
			return nil, fmt.Errorf("vision failed to create requeset: %v", err)
		}

		req.Header.Add("Authorization", fmt.Sprintf("Bearer %s", AccessToken))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return nil, fmt.Errorf("vision failed to do requeset: %v", err)
		}

		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("vison got unexpected status: %d", resp.StatusCode)
		}

		defer func() {
			if err := resp.Body.Close(); err != nil {
				log.Printf("failed to close body: %v\n", err)
			}
		}()

		// Read vision response
		var visionOut VisionResponse
		err = json.NewDecoder(resp.Body).Decode(&visionOut)
		if err != nil {
			return nil, fmt.Errorf("failed to Unmarshal vision response body: %v", err)
		}

		visionOuts = append(visionOuts, visionOut)
	}

	if err != nil {
		return nil, err
	}

	return
}

func getImage(ctx context.Context, payload *ObjectTriggerPayload) ([]FileData, []io.Reader, error) {
	var images []FileData
	for _, message := range payload.Messages {
		if message.EventMetadata.EventType == CreateEvent.String() {

			images = append(images, FileData{BucketID: message.Details.BucketID, ObjectID: message.Details.ObjectID})
		}
	}

	var readers []io.Reader
	for _, image := range images {
		resp, err := s3Client.GetObject(ctx, &s3.GetObjectInput{
			Bucket: &image.BucketID,
			Key:    &image.ObjectID,
		})

		if err != nil {
			err = fmt.Errorf("error fetching image with url: %v | %v)", image, err)
			return nil, nil, err
		}

		if resp.Body == nil {
			err = fmt.Errorf("got nil body for image url: %v)", image)
			return nil, nil, err
		}

		log.Printf("succesfully read image: %s/%s\n", image.BucketID, image.ObjectID)

		readers = append(readers, resp.Body)
	}

	return images, readers, nil
}

func initClients(ctx context.Context) error {
	os.Setenv("AWS_REGION", RegionID)
	os.Setenv("AWS_ENDPOINT_URL", "https://storage.yandexcloud.net")

	cfg, err := config.LoadDefaultConfig(ctx, config.WithEndpointResolverWithOptions(customResolver))
	if err != nil {
		return fmt.Errorf("failed to load aws config: %v", err)
	}

	// creds := ycsdk.InstanceServiceAccount()
	// token, err = creds.IAMToken(ctx)
	// if err != nil {
	// 	return fmt.Errorf("failed to get iam token: %v", err)
	// }

	s3Client = s3.NewFromConfig(cfg)
	sqsClient = sqs.NewFromConfig(cfg)

	return nil
}

func Handler(ctx context.Context, request *ObjectTriggerPayload) ([]byte, error) {
	if err := initClients(ctx); err != nil {
		return nil, err
	}

	imageUrl, reader, err := getImage(ctx, request)
	if err != nil {
		return nil, err
	}

	visionOut, err := batchAnalyze(ctx, reader)
	if err != nil {
		return nil, err
	}

	err = sendToQueue(ctx, imageUrl, visionOut)
	if err != nil {
		return nil, err
	}

	return []byte("OK"), nil
}

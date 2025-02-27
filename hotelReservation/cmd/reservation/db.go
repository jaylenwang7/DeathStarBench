package main

import (
	"context"
	"fmt"
	"time"
	"github.com/rs/zerolog/log"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

type Reservation struct {
	HotelId      string `bson:"hotelId"`
	CustomerName string `bson:"customerName"`
	InDate       string `bson:"inDate"`
	OutDate      string `bson:"outDate"`
	Number       int    `bson:"number"`
}

type Number struct {
	HotelId string `bson:"hotelId"`
	Number  int    `bson:"numberOfRoom"`
}

func initializeDatabase(url string) (*mongo.Client, func()) {
    log.Info().Msg("Connecting to MongoDB...")
    
    uri := fmt.Sprintf("mongodb://%s", url)
    
    // Connection parameters
    maxRetries := 10
    initialRetryDelay := 5 * time.Second
    
    // Connection options
    opts := options.Client().ApplyURI(uri)
    
    // Retry loop for connection
    var client *mongo.Client
    var err error
    retryDelay := initialRetryDelay
    
    for retry := 0; retry < maxRetries; retry++ {
        if retry > 0 {
            log.Info().Msgf("Retrying connection to MongoDB (attempt %d/%d) after %v...", 
                retry+1, maxRetries, retryDelay)
            time.Sleep(retryDelay)
            // Exponential backoff with a cap
            retryDelay = time.Duration(float64(retryDelay) * 1.5)
            if retryDelay > 30*time.Second {
                retryDelay = 30*time.Second
            }
        }
        
        log.Info().Msgf("Attempting connection to %v", uri)
        client, err = mongo.Connect(context.TODO(), opts)
        
        if err == nil {
            // Verify connection with a ping
            ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
            err = client.Ping(ctx, nil)
            cancel()
            
            if err == nil {
                log.Info().Msg("Successfully connected to MongoDB")
                break
            }
        }
        
        log.Warn().Msgf("Failed to connect to MongoDB: %v", err)
        
        // If we have a client but connection failed, try to disconnect to avoid leaks
        if client != nil {
            _ = client.Disconnect(context.TODO())
        }
    }
    
    if err != nil {
        log.Panic().Msgf("Failed to connect to MongoDB after %d attempts: %v", maxRetries, err)
    }
    
    return client, func() {
        if err := client.Disconnect(context.TODO()); err != nil {
            log.Fatal().Msg(err.Error())
        }
    }
}
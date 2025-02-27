package main

import (
	"context"
	"fmt"

	"github.com/rs/zerolog/log"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

type point struct {
	Pid  string  `bson:"hotelId"`
	Plat float64 `bson:"lat"`
	Plon float64 `bson:"lon"`
}

func initializeDatabase(url string) (*mongo.Client, func()) {
    log.Info().Msg("Connecting to MongoDB...")
    
    uri := fmt.Sprintf("mongodb://%s", url)
    log.Info().Msgf("Attempting connection to %v", uri)

    opts := options.Client().ApplyURI(uri)
    client, err := mongo.Connect(context.TODO(), opts)
    if err != nil {
        log.Panic().Msg(err.Error())
    }
    log.Info().Msg("Successfully connected to MongoDB")

    return client, func() {
        if err := client.Disconnect(context.TODO()); err != nil {
            log.Fatal().Msg(err.Error())
        }
    }
}
package main

import (
	"context"
	"fmt"

	"github.com/rs/zerolog/log"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

type RoomType struct {
	BookableRate       float64 `bson:"bookableRate"`
	Code               string  `bson:"code"`
	RoomDescription    string  `bson:"roomDescription"`
	TotalRate          float64 `bson:"totalRate"`
	TotalRateInclusive float64 `bson:"totalRateInclusive"`
}

type RatePlan struct {
	HotelId  string    `bson:"hotelId"`
	Code     string    `bson:"code"`
	InDate   string    `bson:"inDate"`
	OutDate  string    `bson:"outDate"`
	RoomType *RoomType `bson:"roomType"`
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

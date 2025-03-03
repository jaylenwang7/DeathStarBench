package reservation

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/bradfitz/gomemcache/memcache"
	"github.com/delimitrou/DeathStarBench/tree/master/hotelReservation/registry"
	pb "github.com/delimitrou/DeathStarBench/tree/master/hotelReservation/services/reservation/proto"
	"github.com/delimitrou/DeathStarBench/tree/master/hotelReservation/tls"
	"github.com/google/uuid"
	"github.com/grpc-ecosystem/grpc-opentracing/go/otgrpc"
	"github.com/opentracing/opentracing-go"
	"github.com/rs/zerolog/log"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"google.golang.org/grpc"
	"google.golang.org/grpc/keepalive"
	"github.com/delimitrou/DeathStarBench/tree/master/hotelReservation/tune"
)

const name = "srv-reservation"

// Server implements the user service
type Server struct {
	pb.UnimplementedReservationServer

	uuid string

	Tracer      opentracing.Tracer
	Port        int
	IpAddr      string
	MongoClient *mongo.Client
	Registry    *registry.Client
	MemcClient  *tune.ResilientMemcClient
}

// Run starts the server
func (s *Server) Run() error {
	opentracing.SetGlobalTracer(s.Tracer)

	if s.Port == 0 {
		return fmt.Errorf("server port must be set")
	}

	s.uuid = uuid.New().String()

	opts := []grpc.ServerOption{
		grpc.KeepaliveParams(keepalive.ServerParameters{
			Timeout: 120 * time.Second,
		}),
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
			PermitWithoutStream: true,
		}),
		grpc.UnaryInterceptor(
			otgrpc.OpenTracingServerInterceptor(s.Tracer),
		),
	}

	if tlsopt := tls.GetServerOpt(); tlsopt != nil {
		opts = append(opts, tlsopt)
	}

	srv := grpc.NewServer(opts...)

	pb.RegisterReservationServer(srv, s)

	lis, err := net.Listen("tcp", fmt.Sprintf(":%d", s.Port))
	if err != nil {
		log.Fatal().Msgf("failed to listen: %v", err)
	}

	log.Trace().Msgf("In reservation s.IpAddr = %s, port = %d", s.IpAddr, s.Port)

	err = s.Registry.Register(name, s.uuid, s.IpAddr, s.Port)
	if err != nil {
		return fmt.Errorf("failed register: %v", err)
	}
	log.Info().Msg("Successfully registered in consul")

	return srv.Serve(lis)
}

// Shutdown cleans up any processes
func (s *Server) Shutdown() {
	s.Registry.Deregister(s.uuid)
}

// MakeReservation makes a reservation based on given information
func (s *Server) MakeReservation(ctx context.Context, req *pb.Request) (*pb.Result, error) {
	res := new(pb.Result)
	res.HotelId = make([]string, 0)

	database := s.MongoClient.Database("reservation-db")
	resCollection := database.Collection("reservation")
	numCollection := database.Collection("number")

	inDate, _ := time.Parse(
		time.RFC3339,
		req.InDate+"T12:00:00+00:00")

	outDate, _ := time.Parse(
		time.RFC3339,
		req.OutDate+"T12:00:00+00:00")
	hotelId := req.HotelId[0]

	indate := inDate.String()[0:10]

	memc_date_num_map := make(map[string]int)

	for inDate.Before(outDate) {
		// check reservations
		count := 0
		inDate = inDate.AddDate(0, 0, 1)
		outdate := inDate.String()[0:10]

		// first check memc
		memc_key := hotelId + "_" + inDate.String()[0:10] + "_" + outdate
		startTime := time.Now()
		item, err := s.MemcClient.Get(memc_key)
		duration := time.Since(startTime)
		
		if err == nil {
			// memcached hit
			count, _ = strconv.Atoi(string(item.Value))
			log.Info().Str("key", memc_key).Int("count", count).Dur("duration_ms", duration).Msg("Memcached hit for reservation count")
			memc_date_num_map[memc_key] = count + int(req.RoomNumber)

		} else if err == memcache.ErrCacheMiss {
			// memcached miss
			log.Info().Str("key", memc_key).Dur("duration_ms", duration).Msg("Memcached miss for reservation count, querying database")
			var reserve []reservation

			dbStartTime := time.Now()
			filter := bson.D{{"hotelId", hotelId}, {"inDate", indate}, {"outDate", outdate}}
			curr, err := resCollection.Find(context.TODO(), filter)
			if err != nil {
				log.Error().Err(err).Str("hotelId", hotelId).Str("inDate", indate).Str("outDate", outdate).Msg("Failed to query reservation data")
				return res, fmt.Errorf("database error: %v", err)
			}
			
			err = curr.All(context.TODO(), &reserve)
			if err != nil {
				log.Error().Err(err).Str("hotelId", hotelId).Str("inDate", indate).Str("outDate", outdate).Msg("Failed to decode reservation data")
				return res, fmt.Errorf("database error: %v", err)
			}
			dbDuration := time.Since(dbStartTime)
			log.Info().Str("hotelId", hotelId).Str("inDate", indate).Str("outDate", outdate).Dur("duration_ms", dbDuration).Int("results", len(reserve)).Msg("Database query for reservations completed")

			for _, r := range reserve {
				count += r.Number
			}

			// Update memcached with the count we found
			cacheKey := hotelId + "_" + inDate.String()[0:10] + "_" + outdate
			go func(key string, value int) {
				err := s.MemcClient.Set(&memcache.Item{Key: key, Value: []byte(strconv.Itoa(value))})
				if err != nil {
					log.Warn().Err(err).Str("key", key).Int("value", value).Msg("Failed to update memcached after database query")
				} else {
					log.Info().Str("key", key).Int("value", value).Msg("Updated memcached after database query")
				}
			}(cacheKey, count)

			memc_date_num_map[memc_key] = count + int(req.RoomNumber)

		} else {
			// Log the error but don't panic
			log.Error().Err(err).Str("key", memc_key).Dur("duration_ms", duration).Msg("Memcached error, falling back to database")
			
			// Fall back to database query (similar to the memcached miss case)
			var reserve []reservation
		
			dbStartTime := time.Now()
			filter := bson.D{{"hotelId", hotelId}, {"inDate", indate}, {"outDate", outdate}}
			curr, err := resCollection.Find(context.TODO(), filter)
			if err != nil {
				log.Error().Err(err).Str("hotelId", hotelId).Str("inDate", indate).Str("outDate", outdate).Msg("Failed to query reservation data")
				return res, fmt.Errorf("database error: %v", err)
			}
			
			err = curr.All(context.TODO(), &reserve)
			if err != nil {
				log.Error().Err(err).Str("hotelId", hotelId).Str("inDate", indate).Str("outDate", outdate).Msg("Failed to decode reservation data")
				return res, fmt.Errorf("database error: %v", err)
			}
			dbDuration := time.Since(dbStartTime)
			log.Info().Str("hotelId", hotelId).Str("inDate", indate).Str("outDate", outdate).Dur("duration_ms", dbDuration).Int("results", len(reserve)).Msg("Database query for reservations completed")
			
			count := 0
			for _, r := range reserve {
				count += r.Number
			}
			
			memc_date_num_map[memc_key] = count + int(req.RoomNumber)
		}

		// check capacity
		// check memc capacity
		memc_cap_key := hotelId + "_cap"
		capStartTime := time.Now()
		item, err = s.MemcClient.Get(memc_cap_key)
		capDuration := time.Since(capStartTime)
		
		hotel_cap := 0
		if err == nil {
			// memcached hit
			hotel_cap, _ = strconv.Atoi(string(item.Value))
			log.Info().Str("key", memc_cap_key).Int("capacity", hotel_cap).Dur("duration_ms", capDuration).Msg("Memcached hit for hotel capacity")
		} else if err == memcache.ErrCacheMiss {
			// memcached miss
			log.Info().Str("key", memc_cap_key).Dur("duration_ms", capDuration).Msg("Memcached miss for hotel capacity, querying database")
			
			dbStartTime := time.Now()
			var num number
			err = numCollection.FindOne(context.TODO(), &bson.D{{"hotelId", hotelId}}).Decode(&num)
			if err != nil {
				log.Error().Err(err).Str("hotelId", hotelId).Msg("Failed to find hotel capacity in database")
				return res, fmt.Errorf("database error: %v", err)
			}
			dbDuration := time.Since(dbStartTime)
			
			hotel_cap = int(num.Number)
			log.Info().Str("hotelId", hotelId).Int("capacity", hotel_cap).Dur("duration_ms", dbDuration).Msg("Retrieved hotel capacity from database")

			// write to memcache
			go func(key string, value int) {
				err := s.MemcClient.Set(&memcache.Item{Key: key, Value: []byte(strconv.Itoa(value))})
				if err != nil {
					log.Warn().Err(err).Str("key", key).Int("value", value).Msg("Failed to cache hotel capacity in memcached")
				} else {
					log.Info().Str("key", key).Int("value", value).Msg("Cached hotel capacity in memcached")
				}
			}(memc_cap_key, hotel_cap)
		} else {
			log.Error().Err(err).Str("key", memc_cap_key).Dur("duration_ms", capDuration).Msg("Memcached error for capacity, falling back to database")
			
			// Fall back to database query for capacity
			dbStartTime := time.Now()
			var num number
			err = numCollection.FindOne(context.TODO(), &bson.D{{"hotelId", hotelId}}).Decode(&num)
			if err != nil {
				log.Error().Err(err).Str("hotelId", hotelId).Msg("Failed to find hotel capacity in database")
				return res, fmt.Errorf("database error: %v", err)
			}
			dbDuration := time.Since(dbStartTime)
			
			hotel_cap = int(num.Number)
			log.Info().Str("hotelId", hotelId).Int("capacity", hotel_cap).Dur("duration_ms", dbDuration).Msg("Retrieved hotel capacity from database")
		}

		// Check if we have enough capacity
		if count+int(req.RoomNumber) > hotel_cap {
			log.Info().Str("hotelId", hotelId).Int("requested", int(req.RoomNumber)).Int("available", hotel_cap-count).Msg("Insufficient capacity for reservation")
			return res, nil
		}
		indate = outdate
	}

	// only update reservation number cache after check succeeds
	for key, val := range memc_date_num_map {
		err := s.MemcClient.Set(&memcache.Item{Key: key, Value: []byte(strconv.Itoa(val))})
		if err != nil {
			log.Warn().Err(err).Str("key", key).Int("value", val).Msg("Failed to update reservation count in memcached")
		} else {
			log.Info().Str("key", key).Int("value", val).Msg("Updated reservation count in memcached")
		}
	}

	// Now create the actual reservations in the database
	inDate, _ = time.Parse(
		time.RFC3339,
		req.InDate+"T12:00:00+00:00")

	indate = inDate.String()[0:10]
	log.Info().Str("hotelId", hotelId).Str("customerName", req.CustomerName).Str("inDate", req.InDate).Str("outDate", req.OutDate).Int("roomNumber", int(req.RoomNumber)).Msg("Creating reservation records")

	for inDate.Before(outDate) {
		inDate = inDate.AddDate(0, 0, 1)
		outdate := inDate.String()[0:10]
		
		insertStartTime := time.Now()
		result, err := resCollection.InsertOne(
			context.TODO(),
			reservation{
				HotelId:      hotelId,
				CustomerName: req.CustomerName,
				InDate:       indate,
				OutDate:      outdate,
				Number:       int(req.RoomNumber),
			},
		)
		insertDuration := time.Since(insertStartTime)
		
		if err != nil {
			log.Error().Err(err).Str("hotelId", hotelId).Str("inDate", indate).Str("outDate", outdate).Msg("Failed to insert reservation record")
			return res, fmt.Errorf("database error: %v", err)
		}
		
		log.Info().Str("hotelId", hotelId).Str("inDate", indate).Str("outDate", outdate).Interface("insertId", result.InsertedID).Dur("duration_ms", insertDuration).Msg("Inserted reservation record")
		
		indate = outdate
	}

	res.HotelId = append(res.HotelId, hotelId)
	log.Info().Str("hotelId", hotelId).Str("customerName", req.CustomerName).Msg("Reservation completed successfully")

	return res, nil
}

// CheckAvailability checks if given information is available
func (s *Server) CheckAvailability(ctx context.Context, req *pb.Request) (*pb.Result, error) {
	res := new(pb.Result)
	res.HotelId = make([]string, 0)

	hotelMemKeys := []string{}
	keysMap := make(map[string]struct{})
	resMap := make(map[string]bool)
	// cache capacity since it will not change
	for _, hotelId := range req.HotelId {
		hotelMemKeys = append(hotelMemKeys, hotelId+"_cap")
		resMap[hotelId] = true
		keysMap[hotelId+"_cap"] = struct{}{}
	}

	capMemSpan, _ := opentracing.StartSpanFromContext(ctx, "memcached_capacity_get_multi_number")
	capMemSpan.SetTag("span.kind", "client")
	cacheMemRes, err := s.MemcClient.GetMulti(hotelMemKeys)
	capMemSpan.Finish()

	numCollection := s.MongoClient.Database("reservation-db").Collection("number")

	misKeys := []string{}
	// gather cache miss key to query in mongodb
	if err == memcache.ErrCacheMiss {
		for key := range keysMap {
			if _, ok := cacheMemRes[key]; !ok {
				misKeys = append(misKeys, key)
			}
		}
	} else if err != nil {
		log.Panic().Msgf("Tried to get memc_cap_key [%v], but got memmcached error = %s", hotelMemKeys, err)
	}
	// store whole capacity result in cacheCap
	cacheCap := make(map[string]int)
	for k, v := range cacheMemRes {
		hotelCap, _ := strconv.Atoi(string(v.Value))
		cacheCap[k] = hotelCap
	}
	if len(misKeys) > 0 {
		queryMissKeys := []string{}
		for _, k := range misKeys {
			queryMissKeys = append(queryMissKeys, strings.Split(k, "_")[0])
		}
		var nums []number
		capMongoSpan, _ := opentracing.StartSpanFromContext(ctx, "mongodb_capacity_get_multi_number")
		capMongoSpan.SetTag("span.kind", "client")
		curr, err := numCollection.Find(context.TODO(), bson.D{{"$in", queryMissKeys}})
		if err != nil {
			log.Error().Msgf("Failed get reservation number data: ", err)
		}
		curr.All(context.TODO(), &nums)
		if err != nil {
			log.Error().Msgf("Failed get reservation number data: ", err)
		}
		capMongoSpan.Finish()
		if err != nil {
			log.Panic().Msgf("Tried to find hotelId [%v], but got error", misKeys, err.Error())
		}
		for _, num := range nums {
			cacheCap[num.HotelId] = num.Number
			// we don't care set successfully or not
			go s.MemcClient.Set(&memcache.Item{Key: num.HotelId + "_cap", Value: []byte(strconv.Itoa(num.Number))})
		}
	}

	reqCommand := []string{}
	queryMap := make(map[string]map[string]string)
	for _, hotelId := range req.HotelId {
		log.Trace().Msgf("reservation check hotel %s", hotelId)
		inDate, _ := time.Parse(
			time.RFC3339,
			req.InDate+"T12:00:00+00:00")
		outDate, _ := time.Parse(
			time.RFC3339,
			req.OutDate+"T12:00:00+00:00")
		for inDate.Before(outDate) {
			indate := inDate.String()[:10]
			inDate = inDate.AddDate(0, 0, 1)
			outDate := inDate.String()[:10]
			memcKey := hotelId + "_" + outDate + "_" + outDate
			reqCommand = append(reqCommand, memcKey)
			queryMap[memcKey] = map[string]string{
				"hotelId":   hotelId,
				"startDate": indate,
				"endDate":   outDate,
			}
		}
	}

	type taskRes struct {
		hotelId  string
		checkRes bool
	}
	reserveMemSpan, _ := opentracing.StartSpanFromContext(ctx, "memcached_reserve_get_multi_number")
	ch := make(chan taskRes)
	reserveMemSpan.SetTag("span.kind", "client")
	// check capacity in memcached and mongodb
	if itemsMap, err := s.MemcClient.GetMulti(reqCommand); err != nil && err != memcache.ErrCacheMiss {
		reserveMemSpan.Finish()
		log.Panic().Msgf("Tried to get memc_key [%v], but got memmcached error = %s", reqCommand, err)
	} else {
		reserveMemSpan.Finish()
		// go through reservation count from memcached
		go func() {
			for k, v := range itemsMap {
				id := strings.Split(k, "_")[0]
				val, _ := strconv.Atoi(string(v.Value))
				var res bool
				if val+int(req.RoomNumber) <= cacheCap[id] {
					res = true
				}
				ch <- taskRes{
					hotelId:  id,
					checkRes: res,
				}
			}
			if err == nil {
				close(ch)
			}
		}()
		// use miss reservation to get data from mongo
		// rever string to indata and outdate
		if err == memcache.ErrCacheMiss {
			var wg sync.WaitGroup
			for k := range itemsMap {
				delete(queryMap, k)
			}
			wg.Add(len(queryMap))
			go func() {
				wg.Wait()
				close(ch)
			}()
			for command := range queryMap {
				go func(comm string) {
					defer wg.Done()

					var reserve []reservation

					queryItem := queryMap[comm]
					resCollection := s.MongoClient.Database("reservation-db").Collection("reservation")
					filter := bson.D{{"hotelId", queryItem["hotelId"]}, {"inDate", queryItem["startDate"]}, {"outDate", queryItem["endDate"]}}

					reserveMongoSpan, _ := opentracing.StartSpanFromContext(ctx, "mongodb_capacity_get_multi_number"+comm)
					reserveMongoSpan.SetTag("span.kind", "client")
					curr, err := resCollection.Find(context.TODO(), filter)
					if err != nil {
						log.Error().Msgf("Failed get reservation data: ", err)
					}
					curr.All(context.TODO(), &reserve)
					if err != nil {
						log.Error().Msgf("Failed get reservation data: ", err)
					}
					reserveMongoSpan.Finish()

					if err != nil {
						log.Panic().Msgf("Tried to find hotelId [%v] from date [%v] to date [%v], but got error",
							queryItem["hotelId"], queryItem["startDate"], queryItem["endDate"], err.Error())
					}
					var count int
					for _, r := range reserve {
						log.Trace().Msgf("reservation check reservation number = %d", queryItem["hotelId"])
						count += r.Number
					}
					// update memcached
					go s.MemcClient.Set(&memcache.Item{Key: comm, Value: []byte(strconv.Itoa(count))})
					var res bool
					if count+int(req.RoomNumber) <= cacheCap[queryItem["hotelId"]] {
						res = true
					}
					ch <- taskRes{
						hotelId:  queryItem["hotelId"],
						checkRes: res,
					}
				}(command)
			}
		}
	}

	for task := range ch {
		if !task.checkRes {
			resMap[task.hotelId] = false
		}
	}
	for k, v := range resMap {
		if v {
			res.HotelId = append(res.HotelId, k)
		}
	}

	return res, nil
}

type reservation struct {
	HotelId      string `bson:"hotelId"`
	CustomerName string `bson:"customerName"`
	InDate       string `bson:"inDate"`
	OutDate      string `bson:"outDate"`
	Number       int    `bson:"number"`
}

type number struct {
	HotelId string `bson:"hotelId"`
	Number  int    `bson:"numberOfRoom"`
}

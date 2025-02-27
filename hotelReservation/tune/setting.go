package tune

import (
	"fmt"
	"os"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"github.com/bradfitz/gomemcache/memcache"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

var (
	defaultGCPercent        int    = 100
	defaultMemCTimeout      int    = 2
	defaultMemCMaxIdleConns int    = 512
	defaultLogLevel         string = "info"
	defaultRetryAttempts    int    = 5
	defaultRetryDelay       int    = 1 // seconds
	defaultMaxRetryDelay    int    = 30 // seconds
)

func setGCPercent() {
	ratio := defaultGCPercent
	if val, ok := os.LookupEnv("GC"); ok {
		ratio, _ = strconv.Atoi(val)
	}

	debug.SetGCPercent(ratio)
	log.Info().Msgf("Tune: setGCPercent to %d", ratio)
}

func setLogLevel() {
	logLevel := defaultLogLevel
	if val, ok := os.LookupEnv("LOG_LEVEL"); ok {
		logLevel = val
	}
	switch strings.ToLower(logLevel) {
	case "", "error": 
		zerolog.SetGlobalLevel(zerolog.ErrorLevel)
	case "warning":
		zerolog.SetGlobalLevel(zerolog.WarnLevel)
	case "debug":
		zerolog.SetGlobalLevel(zerolog.DebugLevel)
	case "info":
		zerolog.SetGlobalLevel(zerolog.InfoLevel)
	case "trace":
		zerolog.SetGlobalLevel(zerolog.TraceLevel)
	default: // Set default log level to info
		zerolog.SetGlobalLevel(zerolog.InfoLevel)
	}

	log.Info().Msgf("Set global log level: %s", strings.ToUpper(logLevel))
}

func GetMemCTimeout() int {
	timeout := defaultMemCTimeout
	if val, ok := os.LookupEnv("MEMC_TIMEOUT"); ok {
		if parsedTimeout, err := strconv.Atoi(val); err == nil {
			timeout = parsedTimeout
		} else {
			log.Warn().Msgf("Invalid MEMC_TIMEOUT value: %s, using default: %d", val, defaultMemCTimeout)
		}
	}
	log.Info().Msgf("Tune: GetMemCTimeout %d", timeout)
	return timeout
}

func GetRetrySettings() (attempts, initialDelay, maxDelay int) {
	attempts = defaultRetryAttempts
	initialDelay = defaultRetryDelay
	maxDelay = defaultMaxRetryDelay

	// Parse retry attempts from env
	if val, ok := os.LookupEnv("RETRY_ATTEMPTS"); ok {
		if parsed, err := strconv.Atoi(val); err == nil && parsed > 0 {
			attempts = parsed
		} else {
			log.Warn().Msgf("Invalid RETRY_ATTEMPTS value: %s, using default: %d", val, defaultRetryAttempts)
		}
	}

	// Parse initial retry delay from env
	if val, ok := os.LookupEnv("RETRY_DELAY"); ok {
		if parsed, err := strconv.Atoi(val); err == nil && parsed > 0 {
			initialDelay = parsed
		} else {
			log.Warn().Msgf("Invalid RETRY_DELAY value: %s, using default: %d", val, defaultRetryDelay)
		}
	}

	// Parse max retry delay from env
	if val, ok := os.LookupEnv("MAX_RETRY_DELAY"); ok {
		if parsed, err := strconv.Atoi(val); err == nil && parsed > 0 {
			maxDelay = parsed
		} else {
			log.Warn().Msgf("Invalid MAX_RETRY_DELAY value: %s, using default: %d", val, defaultMaxRetryDelay)
		}
	}

	return
}

// Improved Memcached client creation with retry logic and proper error handling
func NewMemCClient(server ...string) *memcache.Client {
	if len(server) == 0 {
		log.Error().Msg("No Memcached servers provided")
		panic("No Memcached servers provided")
	}

	// Get retry settings
	maxRetries, initialDelay, maxDelay := GetRetrySettings()
	backoff := time.Duration(initialDelay) * time.Second

	// Create server list
	ss := new(memcache.ServerList)
	var client *memcache.Client
	var err error

	for attempt := 1; attempt <= maxRetries; attempt++ {
		log.Info().Msgf("Connecting to Memcached servers: %v (attempt %d/%d)", server, attempt, maxRetries)
		
		err = ss.SetServers(server...)
		if err != nil {
			log.Warn().Err(err).Msgf("Failed to set Memcached servers. Retrying in %v...", backoff)
			time.Sleep(backoff)
			
			// Exponential backoff with cap
			backoff *= 2
			if backoff > time.Duration(maxDelay)*time.Second {
				backoff = time.Duration(maxDelay) * time.Second
			}
			continue
		}

		// Create client
		client = memcache.NewFromSelector(ss)
		client.Timeout = time.Second * time.Duration(GetMemCTimeout())
		client.MaxIdleConns = defaultMemCMaxIdleConns

		// Validate the connection with a ping
		if err = validateMemcachedConnection(client); err != nil {
			log.Warn().Err(err).Msg("Memcached connection validation failed. Retrying...")
			time.Sleep(backoff)
			
			// Exponential backoff with cap
			backoff *= 2
			if backoff > time.Duration(maxDelay)*time.Second {
				backoff = time.Duration(maxDelay) * time.Second
			}
			continue
		}

		// Connection successful
		log.Info().Msg("Successfully connected to Memcached")
		return client
	}

	// If we've exhausted all retries
	log.Error().Err(err).Msgf("Failed to connect to Memcached after %d attempts", maxRetries)
	panic(fmt.Sprintf("Failed to connect to Memcached: %v", err))
}

// NewMemCClient2 creates a Memcached client from a comma-separated list of servers
func NewMemCClient2(servers string) *memcache.Client {
	if servers == "" {
		log.Error().Msg("No Memcached servers provided")
		panic("No Memcached servers provided")
	}

	serverList := strings.Split(servers, ",")
	return NewMemCClient(serverList...)
}

// Validate the Memcached connection by setting and getting a test key
func validateMemcachedConnection(client *memcache.Client) error {
	testKey := "connection_test_" + strconv.FormatInt(time.Now().UnixNano(), 10)
	testValue := "test_value"
	
	// Set a test item
	err := client.Set(&memcache.Item{
		Key:   testKey,
		Value: []byte(testValue),
	})
	
	if err != nil {
		return fmt.Errorf("failed to set test key: %w", err)
	}
	
	// Get the test item
	item, err := client.Get(testKey)
	if err != nil {
		return fmt.Errorf("failed to get test key: %w", err)
	}
	
	// Validate the value
	if string(item.Value) != testValue {
		return fmt.Errorf("test key value mismatch: expected %s, got %s", testValue, string(item.Value))
	}
	
	// Delete the test item
	_ = client.Delete(testKey)
	
	return nil
}

// Init initializes the tune package settings
func Init() {
	setLogLevel()
	setGCPercent()
}
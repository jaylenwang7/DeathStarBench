package tune

import (
	"fmt"
	"os"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
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
	defaultRetryDelay       int    = 1      // seconds
	defaultMaxRetryDelay    int    = 5      // seconds
	defaultOpRetryAttempts  int    = 3  	// operation retry attempts
	defaultOpRetryDelay     int    = 50     // operation retry delay (milliseconds)
)

// ResilientMemcClient is a wrapper around memcache.Client that provides resilience features
type ResilientMemcClient struct {
	client        *memcache.Client
	serverList    []string
	retryAttempts int
	retryDelay    time.Duration
	mu            sync.Mutex // protect client reset operations
}

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
        if parsedTimeout, err := strconv.Atoi(val); err == nil && parsedTimeout > 0 {
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

// Update the GetOperationRetrySettings function to use milliseconds:
func GetOperationRetrySettings() (attempts int, delay time.Duration) {
    attempts = defaultOpRetryAttempts
    delay = time.Duration(defaultOpRetryDelay) * time.Millisecond

    // Parse operation retry attempts from env
    if val, ok := os.LookupEnv("OP_RETRY_ATTEMPTS"); ok {
        if parsed, err := strconv.Atoi(val); err == nil && parsed >= 0 {
            attempts = parsed
        } else {
            log.Warn().Msgf("Invalid OP_RETRY_ATTEMPTS value: %s, using default: %d", val, defaultOpRetryAttempts)
        }
    }

    // Parse operation retry delay from env (in milliseconds)
    if val, ok := os.LookupEnv("OP_RETRY_DELAY_MS"); ok {
        if parsed, err := strconv.Atoi(val); err == nil && parsed >= 0 {
            delay = time.Duration(parsed) * time.Millisecond
        } else {
            log.Warn().Msgf("Invalid OP_RETRY_DELAY_MS value: %s, using default: %d ms", val, defaultOpRetryDelay)
        }
    }

    return
}

var resetLimiter = make(chan struct{}, 5)

// resetConnection resets the memcached client connection with DNS re-resolution
func (r *ResilientMemcClient) resetConnection() error {
	r.mu.Lock()
	defer r.mu.Unlock()

	log.Warn().Msg("Resetting memcached connection...")

	// Rate limit resets to avoid thundering herd
	select {
	case resetLimiter <- struct{}{}:
		log.Debug().Msg("Acquired reset limiter slot")
		defer func() { 
			<-resetLimiter 
			log.Debug().Msg("Released reset limiter slot")
		}() // Release when done
	case <-time.After(100 * time.Millisecond):
		// Skip if too many resets happening
		log.Warn().Msg("Skipping connection reset - too many concurrent resets")
		return nil
	}

	// Gracefully close existing client if present
	if r.client != nil {
		log.Debug().Msg("Closing existing memcached connection")
		// Only attempt to close once and ignore errors
		_ = r.client.Close()
		r.client = nil
	}
	
	// Create a fresh server selector to force DNS re-resolution
	ss := new(memcache.ServerList)
	
	// Log the servers we're connecting to
	log.Info().Strs("servers", r.serverList).Msg("Re-resolving memcached servers")
	
	// Set servers will trigger DNS resolution
	err := ss.SetServers(r.serverList...)
	if err != nil {
		log.Error().Err(err).Strs("servers", r.serverList).Msg("DNS resolution failed for memcached servers")
		return fmt.Errorf("failed to re-resolve memcached servers during reset: %w", err)
	}

	// Create client with fresh connections
	r.client = memcache.NewFromSelector(ss)
	r.client.Timeout = time.Second * time.Duration(GetMemCTimeout())
	r.client.MaxIdleConns = defaultMemCMaxIdleConns
	log.Debug().Int("timeout_seconds", GetMemCTimeout()).Int("max_idle_conns", defaultMemCMaxIdleConns).Msg("Created new memcached client")

	// Verify the new connection works
	log.Debug().Msg("Validating new memcached connection")
	if err := validateMemcachedConnection(r.client); err != nil {
		log.Error().Err(err).Msg("New memcached connection failed validation after reset")
		return fmt.Errorf("new connection failed validation: %w", err)
	}

	log.Info().Msg("Successfully reset memcached connection")
	return nil
}

// Get retrieves a memcached item with faster retry logic
func (r *ResilientMemcClient) Get(key string) (*memcache.Item, error) {
    retryAttempts, retryDelay := GetOperationRetrySettings()
    var item *memcache.Item
    var err error
    
    startTime := time.Now()
    
    for i := 0; i <= retryAttempts; i++ {
        if i > 0 {
            // Immediate reset on first retry without delay
            if i == 1 {
                log.Debug().Str("key", key).Msg("First retry - resetting connection")
                if resetErr := r.resetConnection(); resetErr != nil {
                    log.Error().Err(resetErr).Str("key", key).Msg("Failed to reset memcached connection")
                }
                // Don't sleep on first retry after reset
            } else {
                log.Warn().Msgf("Retrying memcached Get for key %s (attempt %d/%d)", key, i, retryAttempts)
                time.Sleep(retryDelay)
            }
        }
        
        opStartTime := time.Now()
        item, err = r.client.Get(key)
        opDuration := time.Since(opStartTime)
        
        // If successful or it's a cache miss (normal behavior), return immediately
        if err == nil {
            log.Debug().Str("key", key).Dur("duration_ms", opDuration).Int("attempts", i+1).Msg("Memcached Get successful")
            return item, err
        } else if err == memcache.ErrCacheMiss {
            log.Debug().Str("key", key).Dur("duration_ms", opDuration).Int("attempts", i+1).Msg("Memcached key not found")
            return item, err
        }
        
        // For connection errors, don't wait before the first retry
        if i == 0 {
            log.Warn().Err(err).Str("key", key).Dur("duration_ms", opDuration).Msg("Memcached Get failed, immediate retry")
            continue  // Skip the sleep for first retry
        }
        
        // Log the error but continue retrying
        log.Error().Err(err).Str("key", key).Dur("duration_ms", opDuration).Int("attempt", i+1).Int("max_attempts", retryAttempts+1).Msg("Memcached Get error")
    }
    
    // If we got here, all retries failed - fall back to database
    totalDuration := time.Since(startTime)
    log.Error().Err(err).Str("key", key).Dur("total_duration_ms", totalDuration).Int("attempts", retryAttempts+1).Msg("All memcached Get retries failed")
    return nil, err
}

func (r *ResilientMemcClient) Close() error {
    r.mu.Lock()
    defer r.mu.Unlock()
    
    if r.client != nil {
        err := r.client.Close()
        if err != nil {
            log.Error().Err(err).Msg("Error closing memcached client")
            return err
        }
    }
    
    log.Info().Msg("Closed memcached client connections")
    return nil
}

// GetMulti retrieves multiple memcached items with retry logic
func (r *ResilientMemcClient) GetMulti(keys []string) (map[string]*memcache.Item, error) {
	retryAttempts, retryDelay := GetOperationRetrySettings()
	var items map[string]*memcache.Item
	var err error
	
	for i := 0; i <= retryAttempts; i++ {
		if i > 0 {
			// On first retry, try resetting the connection
			if i == 1 {
				if resetErr := r.resetConnection(); resetErr != nil {
					log.Error().Err(resetErr).Msg("Failed to reset memcached connection")
				}
			}
			log.Warn().Msgf("Retrying memcached GetMulti for %d keys (attempt %d/%d)", len(keys), i, retryAttempts)
			time.Sleep(retryDelay)
		}
		
		items, err = r.client.GetMulti(keys)
		if err != nil {
			log.Error().Err(err).Msgf("Memcached GetMulti error for %d keys", len(keys))
			continue
		}
		
		// If we got some items or were looking for none, consider it successful
		if len(items) > 0 || len(keys) == 0 {
			return items, nil
		}
		
		// If we got zero items but expected some, there might be an issue
		// Check if we can ping the server
		if err = validateMemcachedConnection(r.client); err != nil {
			log.Error().Err(err).Msg("Memcached connection validation failed during GetMulti")
			err = fmt.Errorf("memcached connection error: %w", err)
			continue
		}
		
		// If connection is valid but no items found, treat as cache miss
		return items, memcache.ErrCacheMiss
	}
	
	// If we got here, all retries failed
	log.Error().Err(err).Msgf("All memcached GetMulti retries failed for %d keys", len(keys))
	return nil, err
}

// Set stores an item in memcached with retry logic
func (r *ResilientMemcClient) Set(item *memcache.Item) error {
	retryAttempts, retryDelay := GetOperationRetrySettings()
	var err error
	
	for i := 0; i <= retryAttempts; i++ {
		if i > 0 {
			// On first retry, try resetting the connection
			if i == 1 {
				if resetErr := r.resetConnection(); resetErr != nil {
					log.Error().Err(resetErr).Msg("Failed to reset memcached connection")
				}
			}
			log.Warn().Msgf("Retrying memcached Set for key %s (attempt %d/%d)", item.Key, i, retryAttempts)
			time.Sleep(retryDelay)
		}
		
		err = r.client.Set(item)
		if err == nil {
			return nil
		}
		
		log.Error().Err(err).Msgf("Memcached Set error for key %s", item.Key)
	}
	
	// If we got here, all retries failed
	log.Error().Err(err).Msgf("All memcached Set retries failed for key %s", item.Key)
	return err
}

// Add adds an item to memcached with retry logic
func (r *ResilientMemcClient) Add(item *memcache.Item) error {
	retryAttempts, retryDelay := GetOperationRetrySettings()
	var err error
	
	for i := 0; i <= retryAttempts; i++ {
		if i > 0 {
			// On first retry, try resetting the connection
			if i == 1 {
				if resetErr := r.resetConnection(); resetErr != nil {
					log.Error().Err(resetErr).Msg("Failed to reset memcached connection")
				}
			}
			log.Warn().Msgf("Retrying memcached Add for key %s (attempt %d/%d)", item.Key, i, retryAttempts)
			time.Sleep(retryDelay)
		}
		
		err = r.client.Add(item)
		if err == nil || err == memcache.ErrNotStored {
			return err // ErrNotStored is normal for Add when key exists
		}
		
		log.Error().Err(err).Msgf("Memcached Add error for key %s", item.Key)
	}
	
	// If we got here, all retries failed
	log.Error().Err(err).Msgf("All memcached Add retries failed for key %s", item.Key)
	return err
}

// Replace replaces an item in memcached with retry logic
func (r *ResilientMemcClient) Replace(item *memcache.Item) error {
	retryAttempts, retryDelay := GetOperationRetrySettings()
	var err error
	
	for i := 0; i <= retryAttempts; i++ {
		if i > 0 {
			// On first retry, try resetting the connection
			if i == 1 {
				if resetErr := r.resetConnection(); resetErr != nil {
					log.Error().Err(resetErr).Msg("Failed to reset memcached connection")
				}
			}
			log.Warn().Msgf("Retrying memcached Replace for key %s (attempt %d/%d)", item.Key, i, retryAttempts)
			time.Sleep(retryDelay)
		}
		
		err = r.client.Replace(item)
		if err == nil || err == memcache.ErrNotStored {
			return err // ErrNotStored is normal for Replace when key doesn't exist
		}
		
		log.Error().Err(err).Msgf("Memcached Replace error for key %s", item.Key)
	}
	
	// If we got here, all retries failed
	log.Error().Err(err).Msgf("All memcached Replace retries failed for key %s", item.Key)
	return err
}

// Delete deletes an item from memcached with retry logic
func (r *ResilientMemcClient) Delete(key string) error {
	retryAttempts, retryDelay := GetOperationRetrySettings()
	var err error
	
	for i := 0; i <= retryAttempts; i++ {
		if i > 0 {
			// On first retry, try resetting the connection
			if i == 1 {
				if resetErr := r.resetConnection(); resetErr != nil {
					log.Error().Err(resetErr).Msg("Failed to reset memcached connection")
				}
			}
			log.Warn().Msgf("Retrying memcached Delete for key %s (attempt %d/%d)", key, i, retryAttempts)
			time.Sleep(retryDelay)
		}
		
		err = r.client.Delete(key)
		if err == nil || err == memcache.ErrCacheMiss {
			return err // ErrCacheMiss is normal for Delete when key doesn't exist
		}
		
		log.Error().Err(err).Msgf("Memcached Delete error for key %s", key)
	}
	
	// If we got here, all retries failed
	log.Error().Err(err).Msgf("All memcached Delete retries failed for key %s", key)
	return err
}

// CreateResilientMemcClient creates a resilient memcached client with retry and recovery capabilities
func CreateResilientMemcClient(servers []string) (*ResilientMemcClient, error) {
    // Use existing retry settings
    maxRetries, initialDelay, maxDelay := GetRetrySettings()
    backoff := time.Duration(initialDelay) * time.Second
    
    log.Info().Strs("servers", servers).Int("max_retries", maxRetries).
        Int("initial_delay_sec", initialDelay).Int("max_delay_sec", maxDelay).
        Msg("Creating resilient memcached client")
    
    ss := new(memcache.ServerList)
    var client *memcache.Client
    var err error
    
    for attempt := 1; attempt <= maxRetries; attempt++ {
        log.Info().Msgf("Connecting to Memcached servers: %v (attempt %d/%d)", servers, attempt, maxRetries)
        
        err = ss.SetServers(servers...)
        if err != nil {
            log.Warn().Err(err).Strs("servers", servers).Dur("backoff", backoff).
                Int("attempt", attempt).Int("max_attempts", maxRetries).
                Msg("Failed to set Memcached servers. Retrying...")
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
        
        log.Debug().Int("timeout_seconds", GetMemCTimeout()).
            Int("max_idle_conns", defaultMemCMaxIdleConns).
            Msg("Created memcached client with configuration")
        
        // Validate the connection
        log.Debug().Msg("Validating initial memcached connection")
        if err = validateMemcachedConnection(client); err != nil {
            log.Warn().Err(err).Strs("servers", servers).Dur("backoff", backoff).
                Int("attempt", attempt).Int("max_attempts", maxRetries).
                Msg("Memcached connection validation failed. Retrying...")
            time.Sleep(backoff)
            
            // Exponential backoff with cap
            backoff *= 2
            if backoff > time.Duration(maxDelay)*time.Second {
                backoff = time.Duration(maxDelay) * time.Second
            }
            continue
        }
        
        // Connection successful - create the resilient client
        log.Info().Strs("servers", servers).Int("attempt", attempt).Msg("Successfully connected to Memcached")
        retryAttempts, retryDelay := GetOperationRetrySettings()
        
        log.Info().Int("retry_attempts", retryAttempts).Dur("retry_delay", retryDelay).
            Msg("Configured operation retry settings for memcached client")
        
        return &ResilientMemcClient{
            client:        client,
            serverList:    servers,
            retryAttempts: retryAttempts,
            retryDelay:    retryDelay,
        }, nil
    }
    
    // If we've exhausted all retries
    log.Error().Err(err).Strs("servers", servers).Int("max_retries", maxRetries).
        Msg("Failed to connect to Memcached after all attempts")
    return nil, fmt.Errorf("failed to connect to Memcached after %d attempts: %w", maxRetries, err)
}

// NewMemCClient creates a resilient memcached client from a list of servers
func NewMemCClient(server ...string) (*ResilientMemcClient, error) {
	if len(server) == 0 {
		log.Error().Msg("No Memcached servers provided")
		return nil, fmt.Errorf("No Memcached servers provided")
	}
	
	client, err := CreateResilientMemcClient(server)
	if err != nil {
		log.Error().Err(err).Msg("Failed to create resilient memcached client")
		return nil, err
	}
	
	return client, nil
}

// NewMemCClient2 creates a resilient memcached client from a comma-separated list of servers
func NewMemCClient2(servers string) *ResilientMemcClient {
	if servers == "" {
		log.Error().Msg("No Memcached servers provided")
		panic("No Memcached servers provided")
	}
	
	serverList := strings.Split(servers, ",")
	return NewMemCClient(serverList...)
}

// Validate the Memcached connection by setting and getting a test key
func validateMemcachedConnection(client *memcache.Client) error {
    startTime := time.Now()
    
    testKey := "connection_test_" + strconv.FormatInt(time.Now().UnixNano(), 10)
    testValue := "test_value"
    
    log.Debug().Str("test_key", testKey).Msg("Validating memcached connection")
    
    // Set a test item
    setStart := time.Now()
    err := client.Set(&memcache.Item{
        Key:   testKey,
        Value: []byte(testValue),
    })
    setDuration := time.Since(setStart)
    
    if err != nil {
        log.Error().Err(err).Str("test_key", testKey).Dur("duration_ms", setDuration).Msg("Failed to set test key during validation")
        return fmt.Errorf("failed to set test key: %w", err)
    }
    
    log.Debug().Str("test_key", testKey).Dur("set_duration_ms", setDuration).Msg("Set test key successful")
    
    // Get the test item
    getStart := time.Now()
    item, err := client.Get(testKey)
    getDuration := time.Since(getStart)
    
    if err != nil {
        log.Error().Err(err).Str("test_key", testKey).Dur("duration_ms", getDuration).Msg("Failed to get test key during validation")
        return fmt.Errorf("failed to get test key: %w", err)
    }
    
    // Validate the value
    if string(item.Value) != testValue {
        log.Error().Str("test_key", testKey).Str("expected", testValue).Str("actual", string(item.Value)).Msg("Test key value mismatch")
        return fmt.Errorf("test key value mismatch: expected %s, got %s", testValue, string(item.Value))
    }
    
    log.Debug().Str("test_key", testKey).Dur("get_duration_ms", getDuration).Msg("Get test key successful")
    
    // Delete the test item
    deleteStart := time.Now()
    deleteErr := client.Delete(testKey)
    deleteDuration := time.Since(deleteStart)
    
    if deleteErr != nil && deleteErr != memcache.ErrCacheMiss {
        log.Warn().Err(deleteErr).Str("test_key", testKey).Dur("duration_ms", deleteDuration).Msg("Failed to delete test key during validation")
        // Don't fail validation just because delete failed
    } else {
        log.Debug().Str("test_key", testKey).Dur("delete_duration_ms", deleteDuration).Msg("Delete test key successful")
    }
    
    totalDuration := time.Since(startTime)
    log.Debug().Str("test_key", testKey).Dur("total_duration_ms", totalDuration).Msg("Memcached connection validation successful")
    
    return nil
}

// Init initializes the tune package settings
func Init() {
	setLogLevel()
	setGCPercent()
}
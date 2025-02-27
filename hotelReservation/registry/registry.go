package registry

import (
	"fmt"
	"net"
	"os"
	"time"

	consul "github.com/hashicorp/consul/api"
	"github.com/rs/zerolog/log"
)

// Default retry settings
const (
	defaultMaxRetries = 5
	initialBackoff    = 1 * time.Second
	maxBackoff        = 30 * time.Second
)

// NewClient returns a new Client with connection to consul
func NewClient(addr string) (*Client, error) {
	cfg := consul.DefaultConfig()
	cfg.Address = addr

	c, err := consul.NewClient(cfg)
	if err != nil {
		return nil, err
	}

	return &Client{c}, nil
}

// Client provides an interface for communicating with registry
type Client struct {
	*consul.Client
}

// Look for the network device being dedicated for gRPC traffic.
// The network CDIR should be specified in os environment
// "DSB_HOTELRESERV_GRPC_NETWORK".
// If not found, return the first non loopback IP address.
func getLocalIP() (string, error) {
	var ipGrpc string
	var ips []net.IP

	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "", err
	}
	for _, a := range addrs {
		if ipnet, ok := a.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
			if ipnet.IP.To4() != nil {
				ips = append(ips, ipnet.IP)
			}
		}
	}
	if len(ips) == 0 {
		return "", fmt.Errorf("registry: can not find local ip")
	} else if len(ips) > 1 {
		// by default, return the first network IP address found.
		ipGrpc = ips[0].String()

		grpcNet := os.Getenv("DSB_GRPC_NETWORK")
		_, ipNetGrpc, err := net.ParseCIDR(grpcNet)
		if err != nil {
			log.Error().Msgf("An invalid network CIDR is set in environment DSB_HOTELRESERV_GRPC_NETWORK: %v", grpcNet)
		} else {
			for _, ip := range ips {
				if ipNetGrpc.Contains(ip) {
					ipGrpc = ip.String()
					log.Info().Msgf("gRPC traffic is routed to the dedicated network %s", ipGrpc)
					break
				}
			}
		}
	} else {
		// only one network device existed
		ipGrpc = ips[0].String()
	}

	return ipGrpc, nil
}

// Register a service with registry
func (c *Client) Register(name string, id string, ip string, port int) error {
	if ip == "" {
		var err error
		ip, err = getLocalIP()
		if err != nil {
			return err
		}
	}
	
	reg := &consul.AgentServiceRegistration{
		ID:      id,
		Name:    name,
		Port:    port,
		Address: ip,
	}
	
	var err error
	backoff := initialBackoff
	
	for attempt := 1; attempt <= defaultMaxRetries; attempt++ {
		log.Info().Msgf("Registering service [name: %s, id: %s, address: %s:%d] (attempt %d/%d)", 
			name, id, ip, port, attempt, defaultMaxRetries)
		
		err = c.Agent().ServiceRegister(reg)
		if err == nil {
			log.Info().Msg("Successfully registered service with Consul")
			return nil
		}
		
		// If this is the last attempt, return the error
		if attempt == defaultMaxRetries {
			return fmt.Errorf("failed to register service after %d attempts: %v", defaultMaxRetries, err)
		}
		
		log.Warn().Msgf("Failed to register with Consul: %v. Retrying in %v...", err, backoff)
		
		// Sleep with backoff before retrying
		time.Sleep(backoff)
		
		// Exponential backoff with cap
		backoff *= 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
	
	// This should never be reached due to the return in the loop
	return err
}

// Deregister removes the service address from registry
func (c *Client) Deregister(id string) error {
	var err error
	backoff := initialBackoff
	
	for attempt := 1; attempt <= defaultMaxRetries; attempt++ {
		log.Info().Msgf("Deregistering service [id: %s] (attempt %d/%d)", 
			id, attempt, defaultMaxRetries)
		
		err = c.Agent().ServiceDeregister(id)
		if err == nil {
			log.Info().Msg("Successfully deregistered service from Consul")
			return nil
		}
		
		// If this is the last attempt, return the error
		if attempt == defaultMaxRetries {
			// For deregistration, we'll just log the error rather than returning it
			// as deregistration failures are less critical
			log.Error().Msgf("Failed to deregister service after %d attempts: %v", defaultMaxRetries, err)
			return nil
		}
		
		log.Warn().Msgf("Failed to deregister from Consul: %v. Retrying in %v...", err, backoff)
		
		// Sleep with backoff before retrying
		time.Sleep(backoff)
		
		// Exponential backoff with cap
		backoff *= 2
		if backoff > maxBackoff {
			backoff = maxBackoff
		}
	}
	
	// This should never be reached due to the return in the loop
	return err
}

// IsConsulReachable checks if Consul is reachable
func (c *Client) IsConsulReachable() bool {
	_, err := c.Agent().Self()
	return err == nil
}
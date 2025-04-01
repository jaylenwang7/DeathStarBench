import gevent
import random
import logging
from locust import events
from typing import List, Dict, Any, Optional, Callable, Type
from locust.user.users import User

class UserPool:
    """
    A user pool that creates all users at the beginning of the test
    and then activates/deactivates them as needed.
    """
    def __init__(self, user_class: Type[User], environment=None):
        self.user_class = user_class
        self.environment = environment
        self.all_users: List[User] = []
        self.active_count = 0
        self.spawn_rate = 100
        self.target_count = 0
        self.user_greenlets: Dict[User, gevent.Greenlet] = {}
        self._setup_events()
        self.logger = logging.getLogger("locust.user_pool")
        self.adjuster_greenlet = None
        self.pool_created = False
        
    def _setup_events(self):
        """Set up event handlers"""
        events.init.add_listener(self.on_locust_init)
        events.test_start.add_listener(self.on_test_start)
        events.test_stop.add_listener(self.on_test_stop)
        
    def on_locust_init(self, environment, **kwargs):
        """Store environment when Locust initializes"""
        self.environment = environment
        self.logger.info("UserPool initialized")
        
    def on_test_start(self, **kwargs):
        """Start the user adjuster when the test starts"""
        self.logger.info("Starting user pool adjuster")
        if self.adjuster_greenlet is None:
            self.adjuster_greenlet = gevent.spawn(self.user_adjuster)
            
    def on_test_stop(self, **kwargs):
        """Stop all users when the test stops"""
        self.logger.info("Stopping all users in pool")
        self.deactivate_all_users()
        if self.adjuster_greenlet:
            self.adjuster_greenlet.kill(block=False)
            self.adjuster_greenlet = None
        
    def create_user_pool(self, count: int, spawn_rate: int = 100):
        """
        Pre-create all users needed for the test
        
        Args:
            count: Maximum number of users to pre-create
            spawn_rate: Rate at which to spawn users (users/second)
        """
        if self.pool_created:
            self.logger.warning("User pool already created. Ignoring request.")
            return
            
        self.logger.info(f"Creating user pool with {count} users at rate {spawn_rate}/s")
        self.spawn_rate = spawn_rate
        
        # Create users without starting their greenlets
        for i in range(count):
            if i > 0 and i % spawn_rate == 0:
                # Sleep to control spawn rate
                gevent.sleep(1)
                
            user = self.user_class(self.environment)
            # Store the user but don't start it
            self.all_users.append(user)
            # Call on_start to initialize the user (but don't start tasks)
            if hasattr(user, 'on_start'):
                user.on_start()
                
        self.pool_created = True
        self.logger.info(f"User pool created with {len(self.all_users)} users")
            
    def activate_users(self, count: int):
        """
        Activate a specific number of users from the pool
        
        Args:
            count: Number of users to activate
        """
        # Calculate how many more users we need to activate
        currently_active = sum(1 for user in self.all_users if user in self.user_greenlets)
        count_to_activate = max(0, count - currently_active)
        count_to_deactivate = max(0, currently_active - count)
        
        if count_to_activate > 0:
            self._activate_n_users(count_to_activate)
        elif count_to_deactivate > 0:
            self._deactivate_n_users(count_to_deactivate)
            
        self.active_count = count
            
    def _activate_n_users(self, count: int):
        """Activate n inactive users"""
        activated = 0
        for user in self.all_users:
            if user not in self.user_greenlets and activated < count:
                # Start a new greenlet for this user
                self.user_greenlets[user] = gevent.spawn(lambda: user.run())
                activated += 1
                
        self.logger.debug(f"Activated {activated} users")
                
    def _deactivate_n_users(self, count: int):
        """Deactivate n active users"""
        deactivated = 0
        users_to_deactivate = list(self.user_greenlets.keys())[:count]
        
        for user in users_to_deactivate:
            if user in self.user_greenlets:
                # Stop the user's greenlet
                self.user_greenlets[user].kill(block=False)
                del self.user_greenlets[user]
                deactivated += 1
                
                # Call on_stop if it exists
                if hasattr(user, 'on_stop'):
                    user.on_stop()
                    
        self.logger.debug(f"Deactivated {deactivated} users")
                
    def deactivate_all_users(self):
        """Deactivate all active users"""
        self._deactivate_n_users(len(self.user_greenlets))
        
    def user_adjuster(self):
        """
        Continuously adjust the number of active users based on the 
        environment's target user count
        """
        while True:
            if self.environment and hasattr(self.environment, "runner"):
                target_users = self.environment.runner.target_user_count
                
                if target_users != self.active_count:
                    self.logger.info(f"Adjusting active users from {self.active_count} to {target_users}")
                    self.activate_users(target_users)
                    
            gevent.sleep(1)
            
    def ensure_pool_created(self, max_users: int):
        """
        Ensure the user pool is created with at least max_users
        """
        if not self.pool_created:
            self.create_user_pool(max_users, self.spawn_rate)
        elif len(self.all_users) < max_users:
            current_count = len(self.all_users)
            self.logger.info(f"Pool needs more users. Adding {max_users - current_count} more.")
            self.create_user_pool(max_users - current_count, self.spawn_rate)


# Custom LoadTestShape that uses the UserPool
class PooledLoadTestShape:
    """
    Base class for load test shapes that use a UserPool.
    Implement the tick method in subclasses.
    """
    def __init__(self, user_pool: UserPool = None, max_users: int = None):
        self.user_pool = user_pool
        self.max_users = max_users
        self._pool_initialized = False
        
    def init_pool(self, environment):
        """
        Initialize the user pool if it's not already done
        """
        if not self._pool_initialized and self.user_pool and self.max_users:
            # Pre-create all users if the pool isn't created yet
            self.user_pool.ensure_pool_created(self.max_users)
            self._pool_initialized = True
            
    def get_run_time(self):
        """Return the current run time in seconds"""
        return self.runner.environment.runner.time()
        
    def tick(self):
        """
        Method that returns a tuple with the desired user count and spawn rate.
        Must be implemented by subclasses.
        
        Returns:
            tuple (user_count, spawn_rate) or None to stop the test
        """
        raise NotImplementedError("Define tick() in a subclass")
        
    def __call__(self):
        if not hasattr(self, "runner"):
            # Available when called
            from locust.runners import Runner
            self.runner: Runner = Runner
            
        if not self._pool_initialized:
            self.init_pool(self.runner.environment)
            
        return self.tick()


# RPS-based load test shape that uses pre-created users
class RPSBasedPooledShape(PooledLoadTestShape):
    """
    A load test shape that reads RPS values from a file and
    uses a pre-created user pool to achieve the desired RPS.
    """
    def __init__(self, 
                 user_pool: UserPool, 
                 rps_values: List[int], 
                 spawn_rate: int = 100,
                 request_rate_per_user: float = 1.0):
        """
        Initialize the load shape with RPS values.
        
        Args:
            user_pool: The UserPool instance
            rps_values: List of RPS values, one per time unit
            spawn_rate: Maximum rate of user spawning
            request_rate_per_user: RPS per individual user
        """
        self.rps_values = rps_values
        self.spawn_rate = spawn_rate
        self.request_rate_per_user = request_rate_per_user
        max_rps = max(rps_values) if rps_values else 0
        max_users = int(max_rps / request_rate_per_user) + 10  # Add buffer
        super().__init__(user_pool=user_pool, max_users=max_users)
        
    def tick(self):
        """
        Return the user count needed to achieve the desired RPS for the current time
        """
        run_time = int(self.get_run_time())
        
        if run_time < len(self.rps_values):
            target_rps = self.rps_values[run_time]
            # Calculate users needed to achieve target RPS
            user_count = int(target_rps / self.request_rate_per_user)
            return (user_count, self.spawn_rate)
            
        return None  # End the test


# Utility function to create a UserPool-enabled load test
def create_pooled_load_test(
    user_class: Type[User],
    rps_values: List[int],
    spawn_rate: int = 100,
    request_rate_per_user: float = 1.0
) -> tuple[UserPool, RPSBasedPooledShape]:
    """
    Create a UserPool and a load test shape for the given user class and RPS values.
    
    Args:
        user_class: The User class to use
        rps_values: List of RPS values, one per time unit
        spawn_rate: Maximum rate of user spawning
        request_rate_per_user: RPS per individual user
        
    Returns:
        Tuple of (UserPool, RPSBasedPooledShape)
    """
    pool = UserPool(user_class)
    shape = RPSBasedPooledShape(
        user_pool=pool,
        rps_values=rps_values,
        spawn_rate=spawn_rate,
        request_rate_per_user=request_rate_per_user
    )
    return pool, shape
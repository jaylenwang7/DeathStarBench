import random
from locust import FastHttpUser, LoadTestShape, task, tag, between, events
import base64
import os
from pathlib import Path
import logging
import time
import json
from locust import events
import urllib3
import gevent

import locust.stats

# Add a global lock for synchronizing user activation
activation_lock = gevent.lock.RLock()
# Global variables for tracking active users
user_registry = {}  # Maps user instances to sequential IDs
next_user_id = 0
MAX_USER_COUNT = 0
ACTIVE_USER_COUNT = 0
ENABLE_USER_POOL = False

def load_stats_config():
    """
    Load Locust stats configuration from a JSON file if it exists,
    otherwise use default values.
    """
    # Default values
    default_config = {
        # How frequently (in seconds) stats are updated in the console output
        "CONSOLE_STATS_INTERVAL_SEC": 1,
        
        # How often (in seconds) stats are aggregated for historical records
        # Used for graphs and time-series analysis
        # Records stats over a rolling window of this duration
        "HISTORY_STATS_INTERVAL_SEC": 60,
        
        # Interval (in seconds) between writes to the CSV stats file
        # Controls how frequently test results are saved to disk
        # Records the total stats for each user and the total stats for the whole test
        # but will record this data at the interval specified here
        "CSV_STATS_INTERVAL_SEC": 60,
        
        # How often (in seconds) the CSV file buffer is flushed to disk
        # Lower values reduce risk of data loss but may impact performance
        "CSV_STATS_FLUSH_INTERVAL_SEC": 60,
        
        # Size of the rolling window (in seconds) used to calculate
        # current response time percentiles in the console output
        "CURRENT_RESPONSE_TIME_PERCENTILE_WINDOW": 60,
        
        # List of percentiles to calculate and include in reports
        # 0.50 = median, 0.99 = 99th percentile, 1.0 = max value
        "PERCENTILES_TO_REPORT": [0.50, 0.75, 0.90, 0.99, 0.999, 0.9999, 0.99999, 1.0],
        
        # New config value for request rate per user (requests per second)
        "REQUEST_RATE_PER_USER": 1.0,
        
        # Add new spawn rate config with 100 as default
        "SPAWN_RATE": 100,
        
        # Add new random seed config, None means use time.time()
        "RANDOM_SEED": None,
        
        # New option to create all users at start and control RPS by activation
        "ENABLE_USER_POOL": False
    }

    # Try to load config from JSON file
    config_path = os.path.join(os.path.dirname(__file__), 'locust_stats_config.json')
    
    try:
        if os.path.exists(config_path):
            with open(config_path, 'r') as f:
                loaded_config = json.load(f)
                # Update defaults with loaded values
                default_config.update(loaded_config)
                print(f"Loaded configuration from {config_path}")
        else:
            print("No configuration file found, using defaults")
    except json.JSONDecodeError as e:
        print(f"Error reading configuration file: {e}")
        print("Using default values")
    except Exception as e:
        print(f"Unexpected error loading configuration: {e}")
        print("Using default values")

    # Apply configuration to locust.stats
    locust.stats.CONSOLE_STATS_INTERVAL_SEC = default_config["CONSOLE_STATS_INTERVAL_SEC"]
    locust.stats.HISTORY_STATS_INTERVAL_SEC = default_config["HISTORY_STATS_INTERVAL_SEC"]
    locust.stats.CSV_STATS_INTERVAL_SEC = default_config["CSV_STATS_INTERVAL_SEC"]
    locust.stats.CSV_STATS_FLUSH_INTERVAL_SEC = default_config["CSV_STATS_FLUSH_INTERVAL_SEC"]
    locust.stats.CURRENT_RESPONSE_TIME_PERCENTILE_WINDOW = default_config["CURRENT_RESPONSE_TIME_PERCENTILE_WINDOW"]
    locust.stats.PERCENTILES_TO_REPORT = default_config["PERCENTILES_TO_REPORT"]

    return default_config

def print_config(config):
    """Print the current configuration settings"""
    print("\n=== Locust Configuration ===")
    print(f"Request Rate Per User: {config['REQUEST_RATE_PER_USER']} requests/second")
    print(f"Spawn Rate: {config['SPAWN_RATE']} users/second")
    print(f"Random Seed: {config['RANDOM_SEED'] if config['RANDOM_SEED'] is not None else 'Using time.time()'}")
    print(f"Console Stats Interval: {config['CONSOLE_STATS_INTERVAL_SEC']} seconds")
    print(f"History Stats Interval: {config['HISTORY_STATS_INTERVAL_SEC']} seconds")
    print(f"CSV Stats Interval: {config['CSV_STATS_INTERVAL_SEC']} seconds")
    print(f"CSV Stats Flush Interval: {config['CSV_STATS_FLUSH_INTERVAL_SEC']} seconds")
    print(f"Response Time Percentile Window: {config['CURRENT_RESPONSE_TIME_PERCENTILE_WINDOW']} seconds")
    print(f"Percentiles to Report: {config['PERCENTILES_TO_REPORT']}")
    print(f"Enable User Pool: {config['ENABLE_USER_POOL']}")
    print("===========================\n")

# Load config and get request rate
app_config = load_stats_config()
print_config(app_config)
request_rate = app_config["REQUEST_RATE_PER_USER"]
spawn_rate = app_config["SPAWN_RATE"]  # Get spawn rate from config
wait_time_seconds = 1.0 / request_rate  # Convert RPS to interval between requests
ENABLE_USER_POOL = app_config["ENABLE_USER_POOL"]

# Add debug logging for initial state
logging.info(f"Initial config: ENABLE_USER_POOL={ENABLE_USER_POOL}, MAX_USER_COUNT={MAX_USER_COUNT}, ACTIVE_USER_COUNT={ACTIVE_USER_COUNT}")

# Initialize random seed based on config
seed = app_config["RANDOM_SEED"]
if seed is None:
    seed = time.time()
random.seed(seed)

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

script_dir = Path(__file__).resolve().parent
image_dir  = script_dir / 'base64_images'
image_data = {}
image_names = []

logging.basicConfig(level=logging.INFO)

# data
if not image_dir.exists():
    print(f"Directory does not exist. Creating {image_dir}")
    image_dir.mkdir(parents=True, exist_ok=True)

# Generate dummy base64 images if the directory is empty
if not any(image_dir.iterdir()):
    print("No images found in the directory. Generating dummy base64 images.")
    for i in range(4):  # Generate 4 images
        # Create dummy binary image data
        dummy_image_data = b"This is a dummy image for testing EcoScale " + bytes(str(i), "utf-8")
        # Encode it in base64
        encoded_image = base64.b64encode(dummy_image_data).decode('utf-8')
        # Save to a file
        image_path = image_dir / f"dummy_image_{i}.jpg"
        with open(image_path, 'w') as f:
            f.write(encoded_image)
    print(f"Generated {len(list(image_dir.iterdir()))} dummy base64 images.")

# Load images into image_data and image_names
for img in os.listdir(str(image_dir)):
    full_path = image_dir / img
    image_names.append(img)
    with open(str(full_path), 'r') as f:
        image_data[img] = f.read()

# Enhanced user registration system
def register_user(user):
    """Register a user and assign it a sequential ID"""
    global next_user_id
    with activation_lock:
        if user not in user_registry:
            user_registry[user] = next_user_id
            next_user_id += 1
    return user_registry[user]

# Check if a user is active based on its ID - with detailed logging
def is_user_active(user):
    """Check if this user should be active"""
    global ACTIVE_USER_COUNT
    
    # Force all users to be active since this is a test
    if True:  # Changed from: if not ENABLE_USER_POOL
        return True
    
    user_id = register_user(user)
    with activation_lock:
        is_active = user_id < ACTIVE_USER_COUNT
        if not is_active:
            logging.info(f"User {id(user)} (ID: {user_id}) is inactive because {user_id} >= {ACTIVE_USER_COUNT}")
        return is_active

# Utility functions
charset = ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', 'a', 's',
  'd', 'f', 'g', 'h', 'j', 'k', 'l', 'z', 'x', 'c', 'v', 'b', 'n', 'm', 'Q',
  'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', 'A', 'S', 'D', 'F', 'G', 'H',
  'J', 'K', 'L', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '1', '2', '3', '4', '5',
  '6', '7', '8', '9', '0']

decset = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']

# User ID by follower dictionaries
user_id_by_follower_num = {}
# ... [original user_id_by_follower_num content would go here] ...

def random_string(length):
    global charset
    if length > 0:
        s = ""
        for i in range(0, length):
            s += random.choice(charset)
        return s
    else:
        return ""

def random_decimal(length):
    global decset
    if length > 0:
        s = ""
        for i in range(0, length):
            s += random.choice(decset)
        return s
    else:
        return ""

def compose_random_text():
    coin = random.random() * 100
    if coin <= 30.0:
        length = random.randint(0, 50)
    elif coin <= 58.2:
        length = random.randint(51, 100)
    elif coin <= 76.5:
        length = random.randint(101, 150)
    elif coin <= 85.3:
        length = random.randint(151, 200)
    elif coin <= 92.6:
        length = random.randint(201, 250)
    else:
        length = random.randint(251, 280)
    return random_string(length)

def compose_random_user():
    """Simplified version matching Lua implementation"""
    max_user_index = 962
    return str(random.randint(0, max_user_index - 1))

# Use standard constant pacing function - the activation check will be in the task itself
def constant_pacing(wait_time):
    """
    Returns a function that will track the run time of the tasks, and for each time it's
    called it will return a wait time that will try to make the total time between task
    execution equal to the time specified by the wait_time argument.
    """
    def wait_time_func(self):
        if not hasattr(self, "_cp_last_wait_time"):
            self._cp_last_wait_time = 0
            self._cp_last_run = time.time()
        run_time = time.time() - self._cp_last_run - self._cp_last_wait_time
        self._cp_last_wait_time = max(0, wait_time - run_time)
        self._cp_last_run = time.time()
        return self._cp_last_wait_time

    return wait_time_func

class SocialMediaUser(FastHttpUser):
    # Use standard constant pacing
    wait_time = constant_pacing(wait_time_seconds)

    @task(100)
    @tag('compose_post')
    def compose_post(self):
        # Add debug logging
        logging.info(f"compose_post called for user {id(self)}")
        
        # Check if user is active
        active = is_user_active(self)
        logging.info(f"User {id(self)} active status: {active}")
        
        if not active:
            logging.info(f"User {id(self)} is inactive, skipping request")
            return
            
        global image_names
        global image_data
        #----------------- contents -------------------#
        user_id = compose_random_user()
        username = 'username_' + user_id
        text = compose_random_text()
        #---- user mentions ----#
        for i in range(0, 5):
            user_mention_id = random.randint(1, 2)
            while True:
                user_mention_id = random.randint(1, 962)
                if user_id != user_mention_id:
                    break
            text = text + " @username_" + str(user_mention_id)

        #---- urls ----#
        for i in range(0, 5):
            if random.random() <= 0.2:
                num_urls = random.randint(0, 5)
                for i in range(0, num_urls):
                    text = text + " https://www.bilibili.com/av" + random_decimal(8)

        #---- media ----#
        num_media = 0
        media_names = []
        medium = []
        media_types = []
        if random.random() < 0.25:
            num_media = random.randint(1, 4)
            # num_media = 1
        num_media = 1
        for i in range(0, num_media):
            img_name = random.choice(image_names)
            if 'jpg' in img_name:
                media_types.append('jpg')
            elif 'png' in img_name:
                media_types.append('png')
            else:
                continue
            medium.append(image_data[img_name])
            media_names.append(img_name)
        media_names = ' '.join(media_names)

        params = {}

        url = '/wrk2-api/post/compose'
        img = random.choice(image_names)
        body = {}
        if num_media > 0:
            body['username'] = username
            body['user_id'] = user_id
            body['text'] = text
            body['medium'] = json.dumps(medium)
            body['media_types'] = json.dumps(media_types)
            body['post_type'] = '0'
        else:
            body['username'] = username
            body['user_id'] = user_id
            body['text'] = text
            body['medium'] = ''
            body['media_types'] = ''
            body['post_type'] = '0'

        # Log before making the request
        logging.info(f"User {id(self)} about to make request")
        
        r = self.client.post(url, params=params,
            data=body, name='compose_post',
            context={'type': 'compose_post', 'num_media': num_media, 'text': text, 'media_names': media_names})

        # Log after making the request
        logging.info(f"User {id(self)} request completed with status {r.status_code}")

        if r.status_code > 202:
            logging.warning('compose_post resp.status = %d, text=%s' %(r.status_code,
                r.text))

# Read RPS values from the 'rps.txt' file
RPS = list(map(int, Path('rps.txt').read_text().splitlines()))

# Add more logging to trace active users
@events.init.add_listener
def on_locust_init(environment, **kwargs):
    global ACTIVE_USER_COUNT, MAX_USER_COUNT
    logging.info(f"Locust initialized with ENABLE_USER_POOL={ENABLE_USER_POOL}")
    
    if ENABLE_USER_POOL:
        MAX_USER_COUNT = max(RPS)
        ACTIVE_USER_COUNT = MAX_USER_COUNT  # Set active count initially to the max
        logging.info(f"Initial MAX_USER_COUNT={MAX_USER_COUNT}, ACTIVE_USER_COUNT={ACTIVE_USER_COUNT}")

# Improved CustomShape for user activation
class CustomShape(LoadTestShape):
    time_limit = len(RPS)
    spawn_rate = spawn_rate
    
    def __init__(self):
        super().__init__()
        global MAX_USER_COUNT, ACTIVE_USER_COUNT
        
        if ENABLE_USER_POOL:
            # When using user pool mode, find the maximum RPS needed
            MAX_USER_COUNT = max(RPS)
            # Set all users active initially
            ACTIVE_USER_COUNT = MAX_USER_COUNT
            print(f"Running in ENABLE_USER_POOL mode with {MAX_USER_COUNT} total users")
            logging.info(f"CustomShape initialized with MAX_USER_COUNT={MAX_USER_COUNT}, ACTIVE_USER_COUNT={ACTIVE_USER_COUNT}")
    
    def tick(self):
        global ACTIVE_USER_COUNT
        run_time = int(self.get_run_time())
        
        # Add start-up debug log
        logging.info(f"CustomShape tick at run_time={run_time}, ACTIVE_USER_COUNT={ACTIVE_USER_COUNT}")
        
        if run_time < self.time_limit:
            target_user_count = RPS[run_time]
            
            if ENABLE_USER_POOL:
                # In user activation mode, we update the active user count
                with activation_lock:
                    old_count = ACTIVE_USER_COUNT
                    ACTIVE_USER_COUNT = target_user_count
                    logging.info(f"Updated ACTIVE_USER_COUNT from {old_count} to {ACTIVE_USER_COUNT}")
                
                # Log the change in active users
                if old_count != ACTIVE_USER_COUNT:
                    if old_count < ACTIVE_USER_COUNT:
                        logging.info(f"Time {run_time}s: Activating users - {old_count} → {ACTIVE_USER_COUNT} of {MAX_USER_COUNT} total")
                    else:
                        logging.info(f"Time {run_time}s: Deactivating users - {old_count} → {ACTIVE_USER_COUNT} of {MAX_USER_COUNT} total")
                
                if run_time == 0:
                    # On first tick, spawn all users at once
                    return (MAX_USER_COUNT, self.spawn_rate)
                else:
                    # Keep the same total user count after first tick
                    return (MAX_USER_COUNT, self.spawn_rate)
            else:
                # Original behavior - spawn/kill users to match the target count
                logging.info(f"Time {run_time}s: Setting user count to {target_user_count}")
                return (target_user_count, self.spawn_rate)
                
        return None
from locust import FastHttpUser, LoadTestShape, task, events
import locust.stats
import random
import logging
import time
import json
import os
from pathlib import Path
import urllib3

def load_stats_config():
    """
    Load Locust stats configuration from a JSON file if it exists,
    otherwise use default values.
    """
    # Default values
    default_config = {
        "CONSOLE_STATS_INTERVAL_SEC": 1,
        "HISTORY_STATS_INTERVAL_SEC": 60,
        "CSV_STATS_INTERVAL_SEC": 60,
        "CSV_STATS_FLUSH_INTERVAL_SEC": 60,
        "CURRENT_RESPONSE_TIME_PERCENTILE_WINDOW": 60,
        "PERCENTILES_TO_REPORT": [0.50, 0.75, 0.90, 0.99, 0.999, 0.9999, 0.99999, 1.0],
        "REQUEST_RATE_PER_USER": 1.0,
        "SPAWN_RATE": 100,
        "RANDOM_SEED": None
    }

    # Try to load config from JSON file
    config_path = os.path.join(os.path.dirname(__file__), 'locust_stats_config.json')
    
    try:
        if os.path.exists(config_path):
            with open(config_path, 'r') as f:
                loaded_config = json.load(f)
                default_config.update(loaded_config)
                print(f"Loaded configuration from {config_path}")
        else:
            print("No configuration file found, using defaults")
    except Exception as e:
        print(f"Error loading configuration: {e}")
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
    print("===========================\n")

# Load config and get request rate
app_config = load_stats_config()
print_config(app_config)
request_rate = app_config["REQUEST_RATE_PER_USER"]
spawn_rate = app_config["SPAWN_RATE"]
wait_time_seconds = 1.0 / request_rate

# Initialize random seed based on config
seed = app_config["RANDOM_SEED"]
if seed is None:
    seed = time.time()
random.seed(seed)

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
logging.basicConfig(level=logging.INFO)

def get_user():
    user_id = random.randint(0, 500)
    user_name = 'Cornell_' + str(user_id)
    password = str(user_id) * 10
    return user_name, password

def constant_pacing(wait_time):
    """
    Returns a function that ensures constant pacing between task executions
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

class HotelReservationUser(FastHttpUser):
    wait_time = constant_pacing(wait_time_seconds)

    @task
    def reserve(self):
        in_date = random.randint(9, 23)
        out_date = in_date + random.randint(1, 5)

        if in_date <= 9:
            in_date = "2015-04-0" + str(in_date)
        else:
            in_date = "2015-04-" + str(in_date)

        if out_date <= 9:
            out_date = "2015-04-0" + str(out_date)
        else:
            out_date = "2015-04-" + str(out_date)

        lat = 38.0235 + (random.randint(0, 481) - 240.5)/1000.0
        lon = -122.095 + (random.randint(0, 325) - 157.0)/1000.0

        hotel_id = str(random.randint(1, 80))
        user_name, password = get_user()
        cust_name = user_name

        num_room = "1"

        path = '/reservation?inDate=' + in_date + "&outDate=" + out_date + \
            "&lat=" + str(lat) + "&lon=" + str(lon) + "&hotelId=" + hotel_id + \
            "&customerName=" + cust_name + "&username=" + user_name + \
            "&password=" + password + "&number=" + num_room

        self.client.post(path, name='reserve',
            context={'type': 'reserve'})

# Read RPS values from the 'rps.txt' file
RPS = list(map(int, Path('rps.txt').read_text().splitlines()))

class CustomShape(LoadTestShape):
    time_limit = len(RPS)
    spawn_rate = spawn_rate

    def tick(self):
        run_time = self.get_run_time()
        if run_time < self.time_limit:
            user_count = RPS[int(run_time)]
            return (user_count, self.spawn_rate)
        return None
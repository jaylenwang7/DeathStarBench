import requests
import random
import time
import urllib3

# Disable SSL warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def get_user():
    """Generate a random user ID and credentials"""
    user_id = random.randint(0, 500)
    user_name = 'Cornell_' + str(user_id)
    password = str(user_id) * 10
    return user_name, password

def send_reservation_request(base_url="http://localhost:8080"):
    """Send a single hotel reservation request and return the response"""
    # Generate random dates
    in_date = random.randint(9, 23)
    out_date = in_date + random.randint(1, 5)

    # Format dates
    if in_date <= 9:
        in_date = "2015-04-0" + str(in_date)
    else:
        in_date = "2015-04-" + str(in_date)

    if out_date <= 9:
        out_date = "2015-04-0" + str(out_date)
    else:
        out_date = "2015-04-" + str(out_date)

    # Generate random location
    lat = 38.0235 + (random.randint(0, 481) - 240.5)/1000.0
    lon = -122.095 + (random.randint(0, 325) - 157.0)/1000.0

    # Generate random hotel ID
    hotel_id = str(random.randint(1, 80))
    
    # Get user credentials
    user_name, password = get_user()
    cust_name = user_name
    num_room = "1"

    # Construct the request path
    path = '/reservation?inDate=' + in_date + "&outDate=" + out_date + \
        "&lat=" + str(lat) + "&lon=" + str(lon) + "&hotelId=" + hotel_id + \
        "&customerName=" + cust_name + "&username=" + user_name + \
        "&password=" + password + "&number=" + num_room

    # Print request details
    print("\n=== Request Details ===")
    print(f"URL: {base_url}{path}")
    print(f"Method: POST")
    print(f"Check-in Date: {in_date}")
    print(f"Check-out Date: {out_date}")
    print(f"Location: ({lat}, {lon})")
    print(f"Hotel ID: {hotel_id}")
    print(f"Customer Name: {cust_name}")
    print(f"Username: {user_name}")
    print(f"Password: {password}")
    print(f"Number of Rooms: {num_room}")
    print("=====================\n")

    # Send the request and measure time
    start_time = time.time()
    response = requests.post(f"{base_url}{path}", verify=False)
    end_time = time.time()
    elapsed_time = end_time - start_time

    # Print response details
    print("\n=== Response Details ===")
    print(f"Status Code: {response.status_code}")
    print(f"Response Time: {elapsed_time:.4f} seconds")
    print(f"Response Headers: {dict(response.headers)}")
    print(f"Response Body: {response.text}")
    print("=======================\n")

    return response

if __name__ == "__main__":
    # You can change the base URL if needed
    base_url = "http://localhost:8080"
    
    print("Sending a single hotel reservation request...")
    response = send_reservation_request(base_url)
    
    if response.status_code == 200:
        print("✅ Request successful!")
    else:
        print(f"❌ Request failed with status code: {response.status_code}") 